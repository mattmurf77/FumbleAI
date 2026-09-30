import XCTest
@testable import PlanKit

final class OutlineTests: XCTestCase {
    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PlanKit.Polygon {
        PlanKit.Polygon(rect: PlanKit.Rect(x: x, y: y, width: w, height: h))
    }

    func testTiledRectangleGivesItsBoundingRectangle() throws {
        // 2 × 2 rooms with a T-junction (the bottom row splits at a different x than the top row).
        let rooms: [PlanKit.Polygon] = [box(0, 0, 120, 100), box(120, 0, 180, 100), box(0, 100, 200, 80), box(200, 100, 100, 80)]
        let o = try XCTUnwrap(Clip.outline(rooms))
        XCTAssertEqual(o.count, 4)
        XCTAssertEqual(o.area, 300 * 180, accuracy: 0.5)
        XCTAssertEqual(o.bounds, PlanKit.Rect(x: 0, y: 0, width: 300, height: 180))
    }

    func testLShapeIsNotAHull() throws {
        // Main block plus a garage that sticks out at the bottom-left: an L, not a rectangle.
        let rooms: [PlanKit.Polygon] = [box(0, 0, 300, 200), box(0, 200, 150, 150)]
        let o = try XCTUnwrap(Clip.outline(rooms))
        XCTAssertEqual(o.count, 6)
        XCTAssertEqual(o.area, 300 * 200 + 150 * 150, accuracy: 0.5)
        XCTAssertFalse(o.contains(Vec2(250, 300)))
        let points: [Vec2] = rooms.flatMap { $0.vertices }
        let hull = try PlanKit.Polygon(Clip.convexHull(points))
        XCTAssertGreaterThan(hull.area, o.area + 1)
    }

    func testHoleIsDropped() throws {
        // Ring of four rooms around an empty middle: the outline is the outer square.
        let rooms: [PlanKit.Polygon] = [box(0, 0, 300, 100), box(0, 100, 100, 100), box(200, 100, 100, 100), box(0, 200, 300, 100)]
        let o = try XCTUnwrap(Clip.outline(rooms))
        XCTAssertEqual(o.area, 300 * 300, accuracy: 0.5)
    }

    func testDisconnectedPiecesFallBackToHull() throws {
        let rooms: [PlanKit.Polygon] = [box(0, 0, 100, 100), box(200, 0, 100, 100)]
        XCTAssertNil(Clip.outline(rooms))
        let b = try XCTUnwrap(Clip.outerBoundary(rooms))
        XCTAssertEqual(b.area, 300 * 100, accuracy: 0.5)
    }

    func testSingleAndEmpty() throws {
        XCTAssertNil(Clip.outline([]))
        XCTAssertEqual(try XCTUnwrap(Clip.outline([box(0, 0, 100, 100)])).area, 10_000, accuracy: 0.1)
    }
}
