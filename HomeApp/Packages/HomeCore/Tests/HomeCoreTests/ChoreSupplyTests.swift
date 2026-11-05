import XCTest
import HomeCore

final class ChoreSupplyTests: XCTestCase {
    func testReadinessMatchesOwnedToolAndSupplyBySpecificNameAndCompatibleUnits() {
        let pid = UUID(), other = UUID()
        let supply = ChoreSupply(name: " Painter’s  tape ", quantity: 3, unit: "roll")
        let stored = InventoryItem(propertyId: pid, kind: .stored, name: "Painter’s tape", scope: .property, quantity: 2, unit: "roll")
        var wrongUnit = stored; wrongUnit.unit = "box"; wrongUnit.quantity = 7
        var foreign = stored; foreign.propertyId = other; foreign.quantity = 3
        let tape = SupplyReadiness(supply, propertyId: pid, inventory: [stored, wrongUnit, foreign], things: [])
        XCTAssertEqual(tape.onHand, 2); XCTAssertEqual(tape.inventory.map(\.id), [stored.id])
        let drill = Thing(propertyId: pid, scope: .property, category: .electronic, name: "Cordless drill")
        var planned = drill; planned.id = UUID(); planned.ownership = .planned
        let found = SupplyReadiness(.init(name: "Cordless DRILL", isEquipment: true), propertyId: pid, inventory: [], things: [drill, planned])
        XCTAssertEqual(found.onHand, 1); XCTAssertEqual(found.equipment.map(\.id), [drill.id])
        XCTAssertNil(SupplyReadiness(.init(name: "Hammer drill"), propertyId: pid, inventory: [stored], things: [drill]).onHand)
    }

    func testOnlySelectedMissingSuppliesEnterShoppingAndReusableGearIsSharedAcrossTasks() {
        let pid = UUID(), date = LocalDate(2026, 11, 4)
        var task = Chore(propertyId: pid, scope: .property, title: "Prep", startOn: date)
        task.workMode = .diy
        task.supplyPlan = [.init(name: "Hose", isEquipment: true, requested: true), .init(name: "Gloves", quantity: 2, unit: "pair", requested: true), .init(name: "Unselected")]
        var another = task; another.id = UUID()
        let gloves = InventoryItem(propertyId: pid, kind: .stored, name: "Gloves", scope: .property, quantity: 3, unit: "pair", isLow: true)
        let lines = ChoreShopping.lines(property: pid, chores: [task, another], inventory: [gloves], things: [])
        XCTAssertEqual(lines.map(\.label), ["Gloves", "Hose"]); XCTAssertEqual(lines.map(\.quantity), [1, 1])
        let low = ShoppingLine(reason: .low, ref: .inventory(gloves.id), label: "Gloves", quantity: 3, unit: "pair")
        XCTAssertEqual(ChoreShopping.merged(existing: [low], supplies: lines), lines)
        task.workMode = .hirePro; another.isPaused = true
        XCTAssertTrue(ChoreShopping.lines(property: pid, chores: [task, another], inventory: [gloves], things: []).isEmpty)
    }

    func testInstalledThingsNeverCountAsSpareConsumableStock() {
        let pid = UUID()
        let filter = Thing(propertyId: pid, scope: .property, category: .fixture, name: "Filter")
        let spare = ChoreSupply(name: "Filter", quantity: 1, requested: true)
        XCTAssertNil(SupplyReadiness(spare, propertyId: pid, inventory: [], things: [filter]).onHand)
        var tool = spare; tool.isEquipment = true
        XCTAssertEqual(SupplyReadiness(tool, propertyId: pid, inventory: [], things: [filter]).onHand, 1)
        var one = Chore(propertyId: pid, scope: .property, title: "Use the fixture", startOn: LocalDate(2026,11,4))
        one.workMode = .diy; one.supplyPlan = [tool]
        var two = one; two.id = UUID(); two.supplyPlan = [spare]
        var anotherFixture = filter; anotherFixture.id = UUID()
        let request = ChoreShopping.lines(property: pid, chores: [one,two], inventory: [], things: [filter,anotherFixture])
        XCTAssertEqual(request.map(\.quantity), [1], "A separately requested consumable still needs a spare")
    }

    func testDedupeOnlySuppressesTheExactRestockTarget() {
        let pid = UUID()
        let room = UUID()
        let tape = InventoryItem(propertyId: pid, kind: .stored, name: "Tape", scope: .level(room), quantity: 1, unit: "roll", isLow: true)
        var task = Chore(propertyId: pid, scope: .property, title: "Paint", startOn: LocalDate(2026,11,4))
        task.workMode = .diy; task.supplyPlan = [.init(name: "Tape", quantity: 4, unit: "roll", requested: true)]
        var second = tape; second.id = UUID(); second.scope = .level(UUID())
        let lines = ChoreShopping.lines(property: pid, chores: [task], inventory: [tape,second], things: [])
        XCTAssertNil(lines.first?.supplyStockID)
        let low = ShoppingLine(reason: .low, ref: .inventory(tape.id), label: "Tape", quantity: 1, unit: "roll")
        let due = ShoppingLine(reason: .replacementDue, ref: .thing(UUID()), label: "Tape", quantity: 1, unit: "roll")
        XCTAssertEqual(ChoreShopping.merged(existing: [low,due], supplies: lines), lines + [low,due])
        let unique = ChoreShopping.lines(property: pid, chores: [task], inventory: [tape], things: [])
        XCTAssertEqual(unique.first?.supplyStockID, tape.id)
        XCTAssertEqual(ChoreShopping.merged(existing: [low,due], supplies: unique), unique + [due])
        second.quantity = 0
        if let shown = unique.first {
            XCTAssertThrowsError(try ChoreShopping.purchase(shown, property: pid, chores: [task], inventory: [tape,second], things: []),
                                 "A new ambiguous location invalidates the outstanding purchase even when quantity is unchanged")
        } else { XCTFail("Expected a shortage") }
    }

    func testBuyingSecondReusableToolKeepsTheExistingOwnedToolInReadiness() throws {
        let pid = UUID()
        var job = Chore(propertyId: pid, scope: .property, title: "Work party", startOn: LocalDate(2026,11,4))
        job.workMode = .diy
        job.supplyPlan = [.init(name: "Cordless drill", quantity: 2, isEquipment: true, requested: true)]
        let tool = Thing(propertyId: pid, scope: .property, category: .electronic, name: "Cordless drill")
        let line = try XCTUnwrap(ChoreShopping.lines(property: pid, chores: [job], inventory: [], things: [tool]).first)
        XCTAssertEqual(line.quantity, 1)
        let (item, updated) = try ChoreShopping.purchase(line, property: pid, chores: [job], inventory: [], things: [tool])
        XCTAssertEqual(item.quantity, 1)
        let supply = try XCTUnwrap(updated.first?.supplyPlan?.first)
        XCTAssertFalse(supply.requested)
        XCTAssertEqual(SupplyReadiness(supply, propertyId: pid, inventory: [item], things: [tool]).onHand, 2)
    }

    func testAnUnrequestedTaskCanSupplyConflictingEvidenceButNeverAddsDemand() {
        let pid = UUID()
        var buying = Chore(propertyId: pid, scope: .property, title: "Kitchen", startOn: LocalDate(2026,11,4))
        buying.workMode = .diy
        buying.supplyPlan = [.init(name: "Tape", quantity: 3, confirmedOnHand: 1, requested: true)]
        var ready = buying; ready.id = UUID(); ready.title = "Hall"
        ready.supplyPlan = [.init(name: "Tape", quantity: 1, confirmedOnHand: 4, requested: false)]
        let conflict = ChoreShopping.lines(property: pid, chores: [buying,ready], inventory: [], things: [])
        XCTAssertEqual(conflict.count, 1)
        XCTAssertNil(conflict.first?.quantity)
        XCTAssertEqual(Set(conflict.first?.conflictingCounts?.map(\.id) ?? []), [buying.id, ready.id])
        ready.supplyPlan?[0].confirmedOnHand = 1
        let reconciled = ChoreShopping.lines(property: pid, chores: [buying,ready], inventory: [], things: [])
        XCTAssertEqual(reconciled.first?.quantity, 2)
        buying.supplyPlan?[0].requested = false
        XCTAssertTrue(ChoreShopping.lines(property: pid, chores: [buying,ready], inventory: [], things: []).isEmpty)
    }

    func testLegacyChoreAndDraftDecodeWithPreparationUnset() throws {
        let pid = UUID(), d = ChoreDraft(propertyId: pid, scope: .property, title: "Legacy", startOn: LocalDate(2024, 2, 1))
        let bytes = try HomeJSON.encoder().encode(d)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("workMode")); XCTAssertNil(try HomeJSON.decoder().decode(ChoreDraft.self, from: bytes).supplyPlan)
        XCTAssertThrowsError(try ChoreSupply.validate([.init(name: "Tape"), .init(name: " TAPE ")]))
    }
}
