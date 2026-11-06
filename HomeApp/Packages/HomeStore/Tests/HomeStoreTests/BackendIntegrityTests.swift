import Foundation
import GRDB
import Testing
import HomeCore
@testable import HomeStore

struct BackendIntegrityTests {
    @Test func partialSyncUpdatesCannotChangeHomesOrReferenceAnotherHomesRecords() async throws {
        let store = try HomeStore.inMemory()
        let first = Property(name: "First"), second = Property(name: "Second")
        try await store.plan.saveProperty(first)
        try await store.plan.saveProperty(second)
        let task = try await store.chores.create(.init(propertyId: first.id, scope: .property, title: "Paint", startOn: .init(2026, 11, 5)))
        let otherTask = try await store.chores.create(.init(propertyId: second.id, scope: .property, title: "Roof", startOn: .init(2026, 11, 5)))
        let project = try await store.projects.create(.init(propertyId: first.id, scope: .property, title: "Kitchen"))
        let results = try await store.sync.perform { st in
            [try st.apply(.init(.chore, task.id), values: ["property_id": .string(second.id.uuidString.lowercased())]),
             try st.apply(.init(.project, project.id), values: ["spawned_from_chore_id": .string(otherTask.id.uuidString.lowercased())]),
             try st.apply(.init(.project, project.id), values: ["est_cost_cents": .double(14.5)]),
             try st.apply(.init(.project, project.id), values: ["est_hours": .double(.infinity)])]
        }
        #expect(results.allSatisfy { if case .rejected = $0 { return true }; return false })
        #expect(try await store.chores.chore(task.id)?.propertyId == first.id)
        let saved = try #require(try await store.projects.project(project.id))
        #expect(saved.spawnedFromChoreId == nil && saved.estCost == nil && saved.estHours == nil)
        let valid = try await store.sync.perform { try $0.apply(.init(.project, project.id), values: ["spawned_from_chore_id": .string(task.id.uuidString.lowercased())]) }
        #expect(valid == .applied)
    }

    @Test func syncedDownloadVerifiesTheOriginalBeforeReplacingOrMarkingItLocal() async throws {
        let store = try HomeStore.inMemory()
        let home = Property(name: "Home")
        try await store.plan.saveProperty(home)
        let project = try await store.projects.create(.init(propertyId: home.id, scope: .property, title: "Roof"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.pdf")
        let corrupt = dir.appendingPathComponent("download.pdf")
        let evidence = Data("valid original".utf8)
        try evidence.write(to: original)
        let attachment = try await store.attachments.add(.init(fileURL: original, kind: .receipt, uti: "com.adobe.pdf"), ownerType: .project, ownerId: project.id, property: home.id)
        try await store.database.write(origin: .sync) { tx in
            try AttachmentStore.setLocalState(tx.db, id: attachment.id, state: "remote_only")
        }
        try Data("wrong original".utf8).write(to: corrupt)
        await #expect(throws: RepositoryError.self) { try await store.sync.adoptAttachmentFile(id: attachment.id, from: corrupt) }
        #expect(try Data(contentsOf: store.files.url(for: attachment)) == evidence)
        #expect(try await store.database.read { try String.fetchOne($0, sql: "SELECT state FROM attachment_local WHERE attachment_id=?", arguments: [attachment.id.db]) } == "remote_only")
        try evidence.write(to: corrupt)
        try await store.sync.adoptAttachmentFile(id: attachment.id, from: corrupt)
        #expect(try await store.database.read { try String.fetchOne($0, sql: "SELECT state FROM attachment_local WHERE attachment_id=?", arguments: [attachment.id.db]) } == "local")
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(throws: RepositoryError.self) { try store.files.adopt(downloaded: original, id: attachment.id, ext: "../../elsewhere") }
        #expect(try Data(contentsOf: store.files.url(for: attachment)) == evidence)
    }

    @Test func exportsBothCustomWorksheetsExactlyWithoutOtherHomesOrDeletedParents() async throws {
        let store = try HomeStore.inMemory()
        let home = Property(name: "Home"), other = Property(name: "Other")
        try await store.plan.saveProperty(home)
        try await store.plan.saveProperty(other)
        let diy = WorkEstimate(mode: .diy, currency: "USD", lines: [
            .init(kind: .material, name: "Paint", quantity: 2.5, unit: "gal", confirmedOnHand: 0.5, packSize: 1,
                  unitPrice: .init(cents: 3000), highUnitPrice: .init(cents: 4000), source: "Owner's local quote, dated today"),
            .init(kind: .labor, name: "My time", quantity: 3.5, unit: "hr"),
            .init(kind: .equipment, name: "Roller", quantity: 1)], scopeQuantity: 800, scopeUnit: "sq ft", assumptions: "Two coats\nWalls only")
        let pro = WorkEstimate(mode: .hirePro, currency: "USD", lines: [.init(kind: .wholeJob, name: "Quote", quantity: 1, unitPrice: .init(cents: 95000))])
        let task = try await store.chores.create(.init(propertyId: home.id, scope: .property, title: "Bedroom", startOn: .init(2026, 11, 5)), estimates: [diy, pro])
        _ = try await store.projects.create(.init(propertyId: other.id, scope: .property, title: "Private second home"), estimates: [pro])
        let deleted = try await store.projects.create(.init(propertyId: home.id, scope: .property, title: "Deleted"), estimates: [pro])
        try await store.projects.delete(deleted.id)
        let table = try #require(try await store.database.read { try CSVExporter.tables($0, property: home.id)["work_estimates.csv"] })
        let (header, rows) = table
        #expect(rows.count == 2)
        func column(_ name: String, _ row: [String]) throws -> String { row[try #require(header.firstIndex(of: name))] }
        let diyRow = try #require(rows.first { $0[3] == "diy" })
        #expect(try column("owner_id", diyRow) == task.id.uuidString.lowercased())
        #expect(try column("known_low", diyRow) == "60.00")
        #expect(try column("known_high", diyRow) == "80.00")
        #expect(try column("is_complete", diyRow) == "false")
        #expect(try column("unpriced_line_count", diyRow) == "1")
        #expect(try column("own_hours", diyRow) == "3.5")
        #expect(try HomeJSON.decode(WorkEstimate.self, from: column("worksheet_json", diyRow)) == diy)
        let proRow = try #require(rows.first { $0[3] == "hirePro" })
        #expect(try HomeJSON.decode(WorkEstimate.self, from: column("worksheet_json", proRow)) == pro)
        #expect(try column("is_complete", proRow) == "true")
    }
}
