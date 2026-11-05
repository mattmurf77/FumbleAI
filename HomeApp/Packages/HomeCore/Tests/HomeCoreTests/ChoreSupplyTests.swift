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

    func testLegacyChoreAndDraftDecodeWithPreparationUnset() throws {
        let pid = UUID(), d = ChoreDraft(propertyId: pid, scope: .property, title: "Legacy", startOn: LocalDate(2024, 2, 1))
        let bytes = try HomeJSON.encoder().encode(d)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("workMode")); XCTAssertNil(try HomeJSON.decoder().decode(ChoreDraft.self, from: bytes).supplyPlan)
        XCTAssertThrowsError(try ChoreSupply.validate([.init(name: "Tape"), .init(name: " TAPE ")]))
    }
}
