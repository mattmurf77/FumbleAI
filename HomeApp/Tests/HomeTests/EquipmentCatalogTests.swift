import XCTest
import HomeCore
import HomeCoreTesting
@testable import Home

final class EquipmentCatalogTests: XCTestCase {
    func testPropertyCatalogPreservesScopeAndHasOneRowPerLiveOwnedRecord() throws {
        let s = SampleHome.snapshot(), pid = SampleHome.propertyId, places = TIK.PlaceIndex(levels: s.liveLevels, spaces: s.liveSpaces)
        let room = try XCTUnwrap(s.liveSpaces.first), level = try XCTUnwrap(s.liveLevels.first { $0.id == room.levelId })
        let whole = InventoryItem(propertyId: pid, kind: .stored, name: "Garden hose", scope: .property, quantity: 2, unit: "ea")
        let floor = InventoryItem(propertyId: pid, kind: .stored, name: "Filter", scope: .level(level.id), quantity: 3, unit: "box")
        let box = InventoryItem(propertyId: pid, kind: .stored, name: "Sockets", scope: .space(room.id, level: level.id))
        let drill = Thing(propertyId: pid, scope: .property, category: .electronic, name: "Drill", model: "XR-100")
        var planned = drill; planned.id = UUID(); planned.ownership = .planned
        var discarded = whole; discarded.id = UUID(); discarded.deletedAt = Date()
        var other = drill; other.id = UUID(); other.propertyId = UUID()
        let loc = ItemLocation(itemId: box.id, name: box.name, owner: nil, room: room.name, floor: level.name, spotPath: "Tool chest › Drawer 2", levelId: level.id, spaceId: room.id, spotId: nil)
        let rows = CatalogRow.make(propertyId: pid, inventory: [whole, floor, box, discarded], owned: [drill, planned, other], places: places, locations: [box.id: loc])
        XCTAssertEqual(rows.count, 4); XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        XCTAssertEqual(rows.filter { $0.matches("whole house hose", filter: .all) }.map(\.title), ["Garden hose"])
        XCTAssertEqual(rows.filter { $0.matches("XR-100", filter: .equipment) }.map(\.title), ["Drill"])
        XCTAssertEqual(rows.filter { $0.matches("drawer 2", filter: .stock) }.map(\.title), ["Sockets"])
        let scoped = try XCTUnwrap(rows.first { $0.title == "Filter" }); XCTAssertTrue(scoped.detail.contains("3 box")); XCTAssertTrue(scoped.place.contains(level.name))
    }
    func testPropertyWithNoRoomsShowsAndFindsWholeHomeAssets() {
        let p = UUID(), driver = Thing(propertyId: p, scope: .property, category: .electronic, name: "Impact driver")
        let stock = InventoryItem(propertyId: p, kind: .stored, name: "Socket set", scope: .property, quantity: 1)
        let rows = CatalogRow.make(propertyId: p, inventory: [stock], owned: [driver], places: .init(), locations: [:])
        XCTAssertEqual(rows.map(\.title), ["Impact driver", "Socket set"]); XCTAssertTrue(rows.allSatisfy { $0.place == "Whole house" })
    }
}
