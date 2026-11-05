import Foundation
import Testing
import GRDB
import HomeCore
@testable import HomeStore

struct ProjectCSVStoreTests {
    private func store(at path: URL) throws -> ProjectStore {
        try ProjectStore(AppDatabase.open(at: path.appendingPathComponent("home.sqlite")), files: .init(directory: path))
    }

    @Test func yearOnlyAndExactCentsSurviveReopenAndReimportAfterEditing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = Property(currencyCode: "EUR")
        let sheet = try ProjectCSV(data: Data("Title,Year,Cost,Currency,Notes\nRoof,2018,12.07,EUR,Finished garage roof\nFree warranty,,0.00,EUR,".utf8))
        let rows = try sheet.review(mapping: .init(sheet), currency: "EUR").compactMap(\.item)
        do {
            let original = try store(at: directory)
            _ = try await original.db.write { try $0.save(home) }
            let outcomes = try await original.importCompletedCSV(rows, propertyID: home.id)
            #expect(outcomes.count == 2 && outcomes.allSatisfy { $0.disposition == .ready })
            var roof = try #require(try await original.projects(.past(home.id)).first { $0.title == "Roof" })
            #expect(roof.completedOn == nil && roof.completedYear == 2018 && roof.actualCost == Money(cents: 1207, currency: "EUR"))
            roof.title = "Updated after import"; try await original.update(roof)
        }
        let reopened = try store(at: directory)
        let result = try await reopened.importCompletedCSV(rows, propertyID: home.id)
        #expect(result.allSatisfy { $0.disposition == .duplicate })
        let saved = try await reopened.projects(.past(home.id))
        #expect(saved.count == 2 && saved.contains { $0.title == "Updated after import" })
        #expect(saved.contains { $0.title == "Free warranty" && $0.actualCost?.cents == 0 })
    }

    @Test func writeFailureRollsBackProjectsReceiptsAndOutbox() async throws {
        let db = try AppDatabase.inMemory()
        let home = Property()
        let repository = ProjectStore(db, files: .init(directory: FileManager.default.temporaryDirectory))
        _ = try await db.write { try $0.save(home) }
        try await db.write { tx in
            try tx.db.execute(sql: """
                CREATE TRIGGER csv_rollback_probe BEFORE INSERT ON project
                WHEN NEW.title = 'Second project' BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }
        let first = ProjectCSVItem(row: 2, title: "First project")
        let second = ProjectCSVItem(row: 3, title: "Second project")
        do {
            _ = try await repository.importCompletedCSV([first, second], propertyID: home.id)
            Issue.record("The second write should have failed")
        } catch is DatabaseError {}
        let count = try await db.read { d in
            try [Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project"),
                 Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_csv_import")]
        }
        #expect(count == [0, 0])
        try await db.write { try $0.db.execute(sql: "DROP TRIGGER csv_rollback_probe") }
        let retry = try await repository.importCompletedCSV([first, second], propertyID: home.id)
        #expect(retry.allSatisfy { $0.disposition == .ready })
    }

    @Test func foreignSourceIDsAndChangedDataDoNotOverwriteProjects() async throws {
        let db = try AppDatabase.inMemory()
        let firstHome = Property(), secondHome = Property()
        let repository = ProjectStore(db, files: .init(directory: FileManager.default.temporaryDirectory))
        try await db.write { tx in _ = try tx.save(firstHome); _ = try tx.save(secondHome) }
        let id = UUID()
        let source = ProjectCSVItem(row: 2, sourceID: id, title: "Filter", year: 2019)
        _ = try await repository.importCompletedCSV([source], propertyID: firstHome.id)
        let foreign = try await repository.importCompletedCSV([source], propertyID: secondHome.id)
        if case .conflict = foreign.first?.disposition {} else { Issue.record("Expected cross-property ID conflict") }
        var edited = source; edited.notes = "Different detail"
        let changed = try await repository.importCompletedCSV([edited], propertyID: firstHome.id)
        if case .conflict = changed.first?.disposition {} else { Issue.record("Expected changed-row conflict") }
        #expect(try await repository.project(id)?.notes == nil)
        #expect(try await repository.projects(.past(secondHome.id)).isEmpty)
    }

    @Test func v5MigrationPreservesExistingProjectAndLeavesPartialYearEmpty() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration())
        try Migrations.migrator.migrate(q, upTo: "v5_project_work_action")
        try q.write { d in
            try d.execute(sql: """
                INSERT INTO property(id,created_at,updated_at) VALUES('old','2020-01-01','2020-01-01');
                INSERT INTO project(id,property_id,scope,title,status,completed_on,created_at,updated_at)
                VALUES('p','old','property','Roof','done','2020-07-04','2020-01-01','2020-01-01')
                """)
        }
        try Migrations.migrator.migrate(q)
        try q.read { d in
            #expect(try String.fetchOne(d, sql: "SELECT completed_on FROM project WHERE id='p'") == "2020-07-04")
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project WHERE completed_year IS NOT NULL") == 0)
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_csv_import") == 0)
        }
    }
}
