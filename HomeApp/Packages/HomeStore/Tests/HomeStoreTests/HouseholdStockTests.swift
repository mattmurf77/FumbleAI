import Foundation
import XCTest
import HomeCore
@testable import HomeStore

final class HouseholdStockTests: XCTestCase {
    func testTwoJobsShareOnePurchaseWithoutInventingItsStorageLocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Property(name: "Fixture"), day = LocalDate(2026, 11, 4)
        let first = try HomeStore.live(directory: dir)
        try await first.plan.saveProperty(home)
        let garage = Level(propertyId: home.id, name: "Garage"), basement = Level(propertyId: home.id, name: "Basement")
        for level in [garage,basement] {
            try await first.plan.saveLevel(level)
            _ = try await first.inventory.create(.init(propertyId: home.id, kind: .stored, name: "Painter’s tape",
                                                        scope: .level(level.id), quantity: 1, unit: "roll"))
        }
        _ = try await first.inventory.create(.init(propertyId: home.id, kind: .stored, name: "Painter’s tape",
                                                    scope: .property, quantity: 5, unit: "box"))
        var draft = ChoreDraft(propertyId: home.id, scope: .property, title: "Prep trim", startOn: day)
        draft.workMode = .diy
        draft.supplyPlan = [.init(name: "Painter’s tape", quantity: 2, unit: "roll", requested: true)]
        let a = try await first.chores.create(draft)
        draft.title = "Protect tile"
        let b = try await first.chores.create(draft)
        let reopened = try HomeStore.live(directory: dir)
        var shopping = reopened.inventory.observeShoppingList(property: home.id, on: day).makeAsyncIterator()
        let initial = await shopping.next()
        let request = try XCTUnwrap(initial?.first(where: { $0.reason == .toDoSupply }))
        XCTAssertEqual(request.quantity, 2)
        try await reopened.inventory.buySelectedSupply(request, propertyId: home.id)
        do { try await reopened.inventory.buySelectedSupply(request, propertyId: home.id); XCTFail("Duplicate purchase") }
        catch is ChoreSupplyError {}
        let disk = try HomeStore.live(directory: dir)
        let stock = try await disk.inventory.items(.init(propertyId: home.id))
        let rolls = stock.filter { $0.unit == "roll" }
        XCTAssertEqual(rolls.filter { $0.scope == .level(garage.id) }.map(\.quantity), [1])
        XCTAssertEqual(rolls.filter { $0.scope == .level(basement.id) }.map(\.quantity), [1])
        XCTAssertEqual(rolls.filter { $0.scope == .property }.map(\.quantity), [2])
        XCTAssertEqual(stock.filter { $0.unit == "box" }.map(\.quantity), [5])
        for id in [a.id,b.id] {
            let row = try await disk.chores.chore(id)
            let supply = try XCTUnwrap(row?.supplyPlan?.first)
            XCTAssertFalse(supply.requested)
            XCTAssertEqual(SupplyReadiness(supply, propertyId: home.id, inventory: stock, things: []).onHand, 4)
        }
    }

    func testCheckedStockPersistsAlongsideOnlyTheUnitsActuallyBought() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Property(name: "Fixture"), day = LocalDate(2026,11,4)
        let store = try HomeStore.live(directory: dir)
        try await store.plan.saveProperty(p)
        var draft = ChoreDraft(propertyId: p.id, scope: .property, title: "Replace filters", startOn: day)
        draft.workMode = .diy
        draft.supplyPlan = [.init(name: "Filter", quantity: 3, confirmedOnHand: 2, requested: true)]
        let task = try await store.chores.create(draft)
        var stream = store.inventory.observeShoppingList(property: p.id, on: day).makeAsyncIterator()
        let list = await stream.next()
        let line = try XCTUnwrap(list?.first)
        XCTAssertEqual(line.quantity, 1)
        try await store.inventory.buySelectedSupply(line, propertyId: p.id)
        let disk = try HomeStore.live(directory: dir)
        let stored = try await disk.inventory.items(.init(propertyId: p.id))
        XCTAssertEqual(stored.map(\.quantity), [1])
        let reloaded = try await disk.chores.chore(task.id)
        let supply = try XCTUnwrap(reloaded?.supplyPlan?.first)
        XCTAssertEqual(supply.confirmedOnHand, 3)
        XCTAssertFalse(supply.requested)
        XCTAssertEqual(SupplyReadiness(supply, propertyId: p.id, inventory: stored, things: []).onHand, 3)
    }
    func testConflictingCountsAreReviewOnlyUntilTheSpecificTaskIsCorrected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Property(name: "Fixture"), day = LocalDate(2026, 11, 4)
        let first = try HomeStore.live(directory: dir)
        try await first.plan.saveProperty(p)
        var draft = ChoreDraft(propertyId: p.id, scope: .property, title: "Hall filters", startOn: day)
        draft.workMode = .diy
        draft.supplyPlan = [.init(name: "Filter", quantity: 2, confirmedOnHand: 1, requested: true)]
        let hall = try await first.chores.create(draft)
        draft.title = "Garage filters"
        let garage = try await first.chores.create(draft)
        var initial = first.inventory.observeShoppingList(property: p.id, on: day).makeAsyncIterator()
        let previous = await initial.next()
        let stale = try XCTUnwrap(previous?.first); XCTAssertEqual(stale.quantity, 3)

        var changed = garage; changed.supplyPlan?[0].confirmedOnHand = 5
        try await first.chores.update(changed)
        // Before this fix the max(1, 5) check made the request disappear entirely.
        let reopened = try HomeStore.live(directory: dir)
        var stream = reopened.inventory.observeShoppingList(property: p.id, on: day).makeAsyncIterator()
        let unresolved = await stream.next()
        let conflict = try XCTUnwrap(unresolved?.first)
        XCTAssertNil(conflict.quantity)
        XCTAssertNil(conflict.supplyStockID)
        let reports = try XCTUnwrap(conflict.conflictingCounts)
        XCTAssertEqual(reports.map(\.id), [garage.id, hall.id])
        XCTAssertEqual(reports.map(\.taskTitle), ["Garage filters", "Hall filters"])
        XCTAssertEqual(reports.map(\.count), [5, 1])
        for line in [conflict, stale] {
            do { try await reopened.inventory.buySelectedSupply(line, propertyId: p.id); XCTFail("Purchase must await reconciliation") }
            catch is ChoreSupplyError {}
        }
        let untouched = try await reopened.inventory.items(.init(propertyId: p.id))
        XCTAssertTrue(untouched.isEmpty)

        let target = try XCTUnwrap(reports.first)
        let fromStore = try await reopened.chores.chore(target.id)
        var corrected = try XCTUnwrap(fromStore)
        corrected.supplyPlan?[0].confirmedOnHand = 1
        try await reopened.chores.update(corrected)
        let resolved = await stream.next()
        let buy = try XCTUnwrap(resolved?.first)
        XCTAssertNil(buy.conflictingCounts); XCTAssertEqual(buy.quantity, 3)
        try await reopened.inventory.buySelectedSupply(buy, propertyId: p.id)
        let stored = try await reopened.inventory.items(.init(propertyId: p.id))
        XCTAssertEqual(stored.map(\.quantity), [3])
    }

}
