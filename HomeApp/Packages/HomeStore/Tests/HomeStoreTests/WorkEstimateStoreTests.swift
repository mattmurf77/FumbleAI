import Foundation
import GRDB
import Testing
import HomeCore
import HomeCoreTesting
@testable import HomeStore

struct WorkEstimateStoreTests {
    private let diy = WorkEstimate(mode: .diy, currency: "USD", lines: [.init(kind: .material, name: "Paint", quantity: 1.5, unit: "gal",
        confirmedOnHand: 0.5, packSize: 1, unitPrice: .init(cents: 3500), source: "Owner-entered price")],
        scopeQuantity: 220, scopeUnit: "sq ft", assumptions: "Walls only")
    private let pro = WorkEstimate(mode: .hirePro, currency: "USD", lines: [.init(kind: .labor, name: "Prep", quantity: 3.75, unit: "hr", unitPrice: .init(cents: 7500))])

    @Test func savedParentAndIndependentModesSurviveReopenAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try HomeStore.live(directory: directory)
        let home = Property(name: "Demo"), other = Property(name: "Other home")
        try await initial.plan.saveProperty(home)
        try await initial.plan.saveProperty(other)
        let draft = ProjectDraft(propertyId: home.id, scope: .property, title: "Paint")
        let p = try await initial.projects.create(draft, estimates: [diy, pro])
        let owner = WorkEstimateOwner.project(p.id)
        let reopened = try HomeStore.live(directory: directory)
        #expect(try await reopened.estimates.estimates(owner: owner, propertyId: home.id) == [diy, pro])
        var edited = diy
        edited.lines[0].confirmedOnHand = 1.5
        for _ in 0..<2 { try await reopened.estimates.saveEstimate(edited, owner: owner, propertyId: home.id) }
        #expect(try await reopened.estimates.estimates(owner: owner, propertyId: home.id) == [edited, pro])
        await #expect(throws: WorkEstimateError.self) { try await reopened.estimates.saveEstimate(diy, owner: owner, propertyId: other.id) }
        var editedParent = p
        editedParent.title = "Paint bedroom"
        try await reopened.projects.update(editedParent)
        let saved = try #require(try await reopened.projects.project(p.id))
        #expect(saved.estCost == nil && saved.actualCost == nil && saved.title == editedParent.title)
        #expect(try await reopened.estimates.estimates(owner: owner, propertyId: home.id) == [edited, pro])

        var invalid = pro
        invalid.currency = "EUR"
        editedParent.title = "Should roll back"
        await #expect(throws: WorkEstimateError.self) { try await reopened.projects.update(editedParent, estimates: [diy, invalid]) }
        #expect(try await reopened.projects.project(p.id)?.title == "Paint bedroom")
        #expect(try await reopened.estimates.estimates(owner: owner, propertyId: home.id) == [edited, pro])
        let chore = ChoreDraft(propertyId: home.id, scope: .property, title: "Tape wall", startOn: .init(2026,11,4))
        await #expect(throws: WorkEstimateError.self) { try await reopened.chores.create(chore, estimates: [invalid]) }
        #expect(try await reopened.chores.chores(.init(propertyId: home.id)).isEmpty)
        let task = try await reopened.chores.create(chore, estimates: [diy])
        #expect(try await reopened.estimates.estimates(owner: .chore(task.id), propertyId: home.id) == [diy])
        try await reopened.chores.delete(task.id)
        await #expect(throws: RepositoryError.self) { try await reopened.chores.update(task, estimates: [diy]) }
        #expect(try await reopened.chores.chore(task.id) == nil)
        await #expect(throws: WorkEstimateError.self) { try await reopened.estimates.estimates(owner: .chore(task.id), propertyId: home.id) }
    }

    @Test func existingV8ProjectsAndTasksUpgradeWithNoAssumedEstimates() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.configuration())
        try Migrations.migrator.migrate(queue, upTo: "v8_local_chore_preparation")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO property(id,created_at,updated_at) VALUES ('p','2026-10-01','2026-10-01');
                INSERT INTO chore(id,property_id,scope,title,start_on,created_at,updated_at) VALUES ('c','p','property','Existing task','2026-10-01','2026-10-01','2026-10-01');
                INSERT INTO project(id,property_id,scope,title,est_cost_cents,created_at,updated_at) VALUES ('w','p','property','Existing project',7500,'2026-10-01','2026-10-01');
                """)
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM work_estimate") == 0)
            #expect(try String.fetchOne(db, sql: "SELECT title FROM chore") == "Existing task")
            #expect(try Int.fetchOne(db, sql: "SELECT est_cost_cents FROM project") == 7500)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func demoUsesTheSameAtomicWritesAndCurrencyChecks() async throws {
        let home = Property(name: "Demo")
        let store = InMemoryStore()
        store.write { $0.properties[home.id] = home }
        let projects = InMemoryProjectRepository(store: store)
        let estimates = InMemoryWorkEstimateRepository(store: store)
        let draft = ProjectDraft(propertyId: home.id, scope: .property, title: "Retile")
        var invalid = diy; invalid.currency = "EUR"
        await #expect(throws: WorkEstimateError.self) { try await projects.create(draft, estimates: [invalid]) }
        #expect(try await projects.projects(.init(propertyId: home.id)).isEmpty)
        let p = try await projects.create(draft, estimates: [diy])
        try await estimates.saveEstimate(pro, owner: .project(p.id), propertyId: home.id)
        #expect(try await estimates.estimates(owner: .project(p.id), propertyId: home.id) == [diy, pro])
    }
    @Test func ownerCurrencyAndTaskConversionAgreeAcrossLocalStores() async throws {
        let disk = try HomeStore.inMemory()
        let home = Property(name: "US home")
        try await disk.plan.saveProperty(home)
        let memory = InMemoryStore()
        memory.write { $0.properties[home.id] = home }
        try await checkOwners(home.id, projects: disk.projects, chores: disk.chores, estimates: disk.estimates)
        try await checkOwners(home.id, projects: InMemoryProjectRepository(store: memory), chores: InMemoryChoreRepository(store: memory),
                              estimates: InMemoryWorkEstimateRepository(store: memory))
    }

    private func checkOwners(_ home: UUID, projects: any ProjectRepository, chores: any ChoreRepository,
                             estimates: any WorkEstimateRepository) async throws {
        let euros = WorkEstimate(mode: .hirePro, currency: "EUR", lines: [
            .init(kind: .labor, name: "Joinery", quantity: 3, unit: "hr", unitPrice: .init(cents: 6500, currency: "EUR"))])
        let imported = try await projects.create(.init(propertyId: home, scope: .property, title: "Overseas components",
                                                       estCost: .init(cents: 30000, currency: "EUR")), estimates: [euros])
        #expect(imported.currencyCode == "EUR")
        #expect(try await estimates.estimates(owner: .project(imported.id), propertyId: home) == [euros])
        await #expect(throws: WorkEstimateError.self) { try await estimates.saveEstimate(pro, owner: .project(imported.id), propertyId: home) }

        let chore = try await chores.create(.init(propertyId: home, scope: .property, title: "Paint den", startOn: .init(2026,11,4)), estimates: [diy, pro])
        await #expect(throws: WorkEstimateError.self) { try await estimates.saveEstimate(euros, owner: .chore(chore.id), propertyId: home) }
        let project = try await chores.turnIntoProject(chore.id)
        #expect(project.spawnedFromChoreId == chore.id && project.status == .idea)
        #expect(try await estimates.estimates(owner: .project(project.id), propertyId: home) == [diy, pro])
        var revised = diy
        revised.assumptions = "Walls and doors"
        try await estimates.saveEstimate(revised, owner: .project(project.id), propertyId: home)
        #expect(try await estimates.estimates(owner: .chore(chore.id), propertyId: home) == [diy, pro])
    }

    @Test func failedConversionRollsBackNewProjectAlongsideItsWorksheets() async throws {
        let disk = try HomeStore.inMemory(), home = Property(name: "Rollback")
        try await disk.plan.saveProperty(home)
        let task = try await disk.chores.create(.init(propertyId: home.id, scope: .property, title: "Paint den", startOn: .init(2026,11,4)), estimates: [diy, pro])
        try await disk.database.write { tx in
            try tx.db.execute(sql: """
                CREATE TRIGGER simulate_copy_failure BEFORE INSERT ON work_estimate
                WHEN NEW.project_id IS NOT NULL AND NEW.mode='hirePro' BEGIN SELECT RAISE(ABORT, 'interrupted'); END
                """)
        }
        await #expect(throws: DatabaseError.self) { try await disk.chores.turnIntoProject(task.id) }
        #expect(try await disk.projects.projects(.init(propertyId: home.id)).isEmpty)
        #expect(try await disk.estimates.estimates(owner: .chore(task.id), propertyId: home.id) == [diy, pro])
    }

}
