import XCTest
import HomeCore
@testable import Home

final class HomeSupplyPickerTests: XCTestCase {
    func testDifferentlyNamedOwnedToolIsSuggestedWithItsLocationAndQuantity() throws {
        let home = UUID()
        let need = ChoreSupply(name: "Drill", isEquipment: true)
        let tool = Thing(propertyId: home, scope: .property, category: .electronic, name: "Cordless drill")
        var planned = tool
        planned.id = UUID(); planned.ownership = .planned; planned.name = "Hammer drill"
        let otherHome = Thing(propertyId: UUID(), scope: .property, category: .electronic, name: "Impact drill")
        let spare = InventoryItem(propertyId: home, kind: .stored, name: "Cordless drill", scope: .property, quantity: 1)
        var wrongUnit = spare
        wrongUnit.id = UUID(); wrongUnit.name = "Drill bits"; wrongUnit.unit = "box"
        let options = HomeSupplyOption.options(for: need, property: home, items: [spare, wrongUnit],
                                             things: [tool, planned, otherHome],
                                             locationOfItem: { _ in "Workshop" }, locationOfThing: { _ in "Workshop" })
        let result = try XCTUnwrap(options.first)
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(result.name, "Cordless drill")
        XCTAssertEqual(result.locations, ["Workshop"])
        XCTAssertEqual(result.onHand, 1)
        XCTAssertTrue(result.isEquipment)
        XCTAssertTrue(result.isPossibleMatch(for: need))
        XCTAssertNil(SupplyReadiness(need, propertyId: home, inventory: [spare], things: [tool]).onHand)
    }
}
