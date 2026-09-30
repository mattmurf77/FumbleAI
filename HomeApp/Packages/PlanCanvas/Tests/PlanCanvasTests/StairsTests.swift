import XCTest
import PlanKit
import HomeCore
@testable import PlanCanvas

final class StairsTests: XCTestCase {
    func testTreadsCrossTheLongAxis() {
        // 10 ft run (x) × 3.5 ft wide: vertical tread lines + one horizontal walk line.
        let poly = Polygon(rect: Rect(x: 0, y: 0, width: 120, height: 42))
        let lines = StairTreads.lines(for: poly)
        let treads = lines.filter { abs($0.a.x - $0.b.x) < 1e-9 }
        XCTAssertEqual(treads.count, 11)
        XCTAssertTrue(treads.allSatisfy { abs($0.length - 42) < 1e-6 })
        XCTAssertEqual(lines.count - treads.count, 1)
        // Vertical run → horizontal treads.
        let tall = StairTreads.lines(for: Polygon(rect: Rect(x: 0, y: 0, width: 42, height: 120)))
        XCTAssertEqual(tall.filter { abs($0.a.y - $0.b.y) < 1e-9 }.count, 11)
    }

    func testTreadsClipToLShape() throws {
        let l = try Polygon([Vec2(0, 0), Vec2(120, 0), Vec2(120, 40), Vec2(40, 40), Vec2(40, 100), Vec2(0, 100)])
        for seg in StairTreads.lines(for: l) {
            XCTAssertTrue(l.contains(seg.midpoint, tolerance: 0.5), "\(seg) leaves the polygon")
        }
    }

    func testRenderModelGivesStairsTreadsOnly() {
        let stairs = Fixture.space("Stairs", Fixture.rect(0, 0, 10, 3.5), type: .stairs)
        let hall = Fixture.space("Hall", Fixture.rect(0, 3.5, 10, 4), type: .hall)
        let g = RenderModelBuilder.geometry(LevelGeometry(level: Fixture.level(), spaces: [stairs, hall], openings: []))
        XCTAssertFalse(g.space(stairs.id)!.treads.isEmpty)
        XCTAssertFalse(g.space(stairs.id)!.allowsAdd)
        XCTAssertTrue(g.space(hall.id)!.treads.isEmpty)
        XCTAssertEqual(g.space(stairs.id)!.fillStyle, .roomAlt)
    }

    func testInsertStairsCarvesTheRoomBelowIt() throws {
        // One big "Unassigned space" (30 × 20 ft); matching stairs from the other floor land against its right wall.
        let big = Fixture.space("Unassigned space", Fixture.rect(0, 0, 30, 20))
        var s = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [big], openings: []))
        let stairsPoly = Fixture.rect(20, 8, 10, 3.5)
        let id = try XCTUnwrap(s.insertStairs(stairsPoly))
        XCTAssertEqual(s.space(id)?.spaceType, .stairs)
        XCTAssertEqual(s.space(id)?.polygon.bounds, stairsPoly.bounds)
        XCTAssertTrue(s.canSave, "no overlaps after carving")
        XCTAssertNotNil(s.space(big.id), "the original room keeps its id")
        let total = s.spaces.reduce(0) { $0 + $1.polygon.area }
        XCTAssertEqual(total, 30 * 20 * 144, accuracy: 1)
        // Undo restores the single room.
        s.undo()
        XCTAssertEqual(s.spaces.count, 1)
        XCTAssertEqual(s.space(big.id)?.polygon, big.polygon)
        // Stairs in the middle of a room: the remainder becomes two rooms (a room can't have a hole).
        XCTAssertNotNil(s.insertStairs(Fixture.rect(10, 8, 10, 3.5)))
        XCTAssertTrue(s.canSave)
        XCTAssertEqual(s.spaces.filter { $0.spaceType == .room }.count, 2)
        // Stairs already there: refused.
        XCTAssertNil(s.insertStairs(Fixture.rect(10, 8, 10, 3.5)))
    }
}
