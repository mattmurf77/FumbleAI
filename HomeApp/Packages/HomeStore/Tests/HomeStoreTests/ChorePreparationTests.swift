import Foundation
import XCTest
import GRDB
import HomeCore
@testable import HomeStore

final class ChorePreparationTests: XCTestCase {
    func testV8MigrationPreservesOldTasksAndKeepsPreparationLocal() throws {
        let db = try DatabaseQueue(configuration: AppDatabase.configuration())
        try Migrations.migrator.migrate(db, upTo: "v7_device_document_library")
        try db.write { sql in
            try sql.execute(sql: "INSERT INTO property(id,created_at,updated_at) VALUES('p','2026-11-04','2026-11-04')")
            try sql.execute(sql: "INSERT INTO chore(id,property_id,scope,title,start_on,created_at,updated_at) VALUES('c','p','property','Before upgrade','2026-11-04','2026-11-04','2026-11-04')")
        }
        try Migrations.migrator.migrate(db)
        try db.read { sql in
            XCTAssertEqual(try String.fetchOne(sql, sql: "SELECT title FROM chore WHERE id='c'"), "Before upgrade")
            XCTAssertEqual(try Int.fetchOne(sql, sql: "SELECT count(*) FROM chore_preparation"), 0)
            XCTAssertFalse(try sql.columns(in: "chore").map(\.name).contains("work_mode"))
            XCTAssertTrue(try Row.fetchAll(sql, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testSelectionPersistsWithoutInventoryWritesUntilBoughtAndPurchaseIsRetrySafe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Property(name: "House"), day = LocalDate(2026, 11, 4)
        let id: UUID
        do {
            let store = try HomeStore.live(directory: dir)
            try await store.plan.saveProperty(p)
            _ = try await store.inventory.create(.init(propertyId: p.id, kind: .stored, name: "Filter", scope: .property, quantity: 1))
            var draft = ChoreDraft(propertyId: p.id, scope: .property, title: "Filter swap", startOn: day)
            draft.workMode = .diy; draft.supplyPlan = [.init(name: "Filter", quantity: 3, requested: true), .init(name: "Screwdriver", isEquipment: true)]
            id = try await store.chores.create(draft).id
        }
        let store = try HomeStore.live(directory: dir)
        var c = try await store.chores.chore(id); XCTAssertEqual(c?.workMode, .diy); XCTAssertEqual(c?.supplyPlan?.count, 2)
        let before = try await store.inventory.items(.init(propertyId: p.id)); XCTAssertEqual(before.count, 1); XCTAssertEqual(before.first?.quantity, 1)
        var stream = store.inventory.observeShoppingList(property: p.id, on: day).makeAsyncIterator()
        let initial = await stream.next(); let request = try XCTUnwrap(initial?.first)
        XCTAssertEqual(request.label, "Filter"); XCTAssertEqual(request.quantity, 2)
        c?.supplyPlan?[0].quantity = 4; try await store.chores.update(try XCTUnwrap(c))
        let reviewed = await stream.next(); let current = try XCTUnwrap(reviewed?.first); XCTAssertEqual(current.quantity, 3)
        do { try await store.inventory.buySelectedSupply(request, propertyId: p.id); XCTFail("Stale request purchased") } catch is ChoreSupplyError {}
        try await store.inventory.buySelectedSupply(current, propertyId: p.id)
        do { try await store.inventory.buySelectedSupply(current, propertyId: p.id); XCTFail("Purchased the same request twice") } catch is ChoreSupplyError {}
        let items = try await store.inventory.items(.init(propertyId: p.id)); XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.quantity, 4)
        let after = try await store.chores.chore(id); XCTAssertEqual(after?.supplyPlan?.first?.requested, false)
        let empty = await stream.next(); XCTAssertEqual(empty?.count, 0)
    }
}
