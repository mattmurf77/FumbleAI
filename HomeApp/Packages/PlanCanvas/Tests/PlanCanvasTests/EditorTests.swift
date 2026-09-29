import XCTest
import PlanKit
import HomeCore
@testable import PlanCanvas

final class EditorTests: XCTestCase {
    // Two 10 × 10 ft rooms sharing the wall at x = 120.
    func twoRooms() -> (PlanEditSession, UUID, UUID) {
        let a = Fixture.space("A", Fixture.rect(0, 0, 10, 10)), b = Fixture.space("B", Fixture.rect(10, 0, 10, 10))
        return (PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [a, b], openings: [])), a.id, b.id)
    }

    func testHitTestPrefersHandlesOfSelection() {
        var (s, a, _) = twoRooms()
        XCTAssertEqual(s.hitTest(Vec2(60, 60), scale: 1), .interior(a))
        s.selection = a
        XCTAssertEqual(s.hitTest(Vec2(1, 1), scale: 1), .vertex(a, 0))
        XCTAssertEqual(s.hitTest(Vec2(60, 2), scale: 1), .edge(a, 0))
        XCTAssertEqual(s.hitTest(Vec2(-500, -500), scale: 1), .none)
    }

    func testEdgeDragMovesSharedWallTogetherAndSnapsToGrid() {
        var (s, a, b) = twoRooms()
        s.selection = a
        // Edge 1 of A is the right wall (120,0)→(120,120); its normal points −x for this winding? Use translation along +x.
        s.beginDrag(.edge(a, 1))
        s.updateDrag(translation: Vec2(13, 0), scale: 1)
        XCTAssertTrue(s.endDrag())
        let ab = s.space(a)!.polygon.bounds, bb = s.space(b)!.polygon.bounds
        XCTAssertEqual(ab.maxX, 132, accuracy: 1e-6)          // 13 → snapped to 12 (6 in grid)
        XCTAssertEqual(bb.minX, 132, accuracy: 1e-6)          // neighbour moved with it
        XCTAssertTrue(s.canSave)
        XCTAssertTrue(s.canUndo)
        s.undo()
        XCTAssertEqual(s.space(a)!.polygon.bounds.maxX, 120, accuracy: 1e-6)
        s.redo()
        XCTAssertEqual(s.space(b)!.polygon.bounds.minX, 132, accuracy: 1e-6)
    }

    func testEdgeDragClampsAtLastValidPosition() {
        var (s, a, _) = twoRooms()
        s.beginDrag(.edge(a, 1))
        s.updateDrag(translation: Vec2(-60, 0), scale: 1)   // valid: 5 ft wide
        s.updateDrag(translation: Vec2(-200, 0), scale: 1)  // would invert → ignored
        s.endDrag()
        XCTAssertEqual(s.space(a)!.polygon.bounds.width, 60, accuracy: 1e-6)
    }

    func testVertexDragKeepsOrthogonality() {
        var (s, a, _) = twoRooms()
        s.selection = a
        // Vertex 2 = (120,120), bottom-right corner.
        s.beginDrag(.vertex(a, 2))
        s.updateDrag(translation: Vec2(0, 30), scale: 1)
        s.endDrag()
        let p = s.space(a)!.polygon
        XCTAssertNotNil(p.rectangleSize)
        XCTAssertEqual(p.bounds.height, 150, accuracy: 1e-6)
    }

    func testMoveRoomSnapsAndMovesOpenings() {
        let a = Fixture.space("A", Fixture.rect(0, 0, 10, 10))
        let o = Opening(propertyId: Fixture.propertyId, levelId: Fixture.levelId, spaceId: a.id, kind: .door,
                        segment: Segment(Vec2(40, 0), Vec2(72, 0)))
        var s = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [a], openings: [o]))
        s.beginDrag(.interior(a.id))
        s.updateDrag(translation: Vec2(25, 1), scale: 1)
        s.endDrag()
        XCTAssertEqual(s.space(a.id)!.polygon.bounds.minX, 24, accuracy: 1e-6)
        XCTAssertEqual(s.space(a.id)!.polygon.bounds.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(s.openings[0].segment.a.x, 64, accuracy: 1e-6)
    }

    func testOverlapBlocksSave() {
        var (s, a, _) = twoRooms()
        s.beginDrag(.interior(a))
        s.updateDrag(translation: Vec2(60, 0), scale: 1)
        s.endDrag()
        XCTAssertFalse(s.canSave)
        XCTAssertFalse(s.overlayState().invalidSpaceIds.isEmpty)
    }

    func testTypedDimensionMovesRightEdgeAndNeighbour() {
        var (s, a, b) = twoRooms()
        let edit = s.setDimension(a, axis: .width, inches: 148)   // 12'4"
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit?.lengthIn, 148)
        XCTAssertEqual(s.space(a)!.polygon.bounds.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(s.space(a)!.polygon.bounds.width, 148, accuracy: 1e-6)
        XCTAssertEqual(s.space(b)!.polygon.bounds.minX, 148, accuracy: 1e-6)
        XCTAssertEqual(s.space(b)!.polygon.bounds.maxX, 240, accuracy: 1e-6)
        XCTAssertNotNil(s.setDimension(a, axis: .depth, inches: 100))
        XCTAssertEqual(s.space(a)!.polygon.bounds.height, 100, accuracy: 1e-6)
        XCTAssertNil(s.setDimension(a, axis: .depth, inches: 3))   // below min area (4 sq ft)
    }

    func testAddSplitMergeDeleteAndDiff() {
        var (s, a, b) = twoRooms()
        let baseline = s.spaces
        let c = s.addRoom(type: .bedroom, center: Vec2(60, 60))!   // would overlap → placed to the right
        XCTAssertEqual(s.space(c)!.polygon.bounds.minX, 240, accuracy: 1e-6)
        XCTAssertEqual(s.space(c)!.name, "Bedroom")
        XCTAssertTrue(s.canSave)
        let half = s.split(b, at: Vec2(180, 60), vertical: true)!
        XCTAssertEqual(s.space(b)!.polygon.area + s.space(half)!.polygon.area, 120 * 120, accuracy: 1)
        XCTAssertEqual(s.space(half)!.name, "B 2")
        XCTAssertTrue(s.merge(b, half))
        XCTAssertNil(s.space(half))
        XCTAssertEqual(s.space(b)!.polygon.area, 120 * 120, accuracy: 1)
        s.deleteRoom(a)
        let changes = s.changes(against: baseline)
        XCTAssertTrue(changes.contains(.insert(s.space(c)!)))
        XCTAssertTrue(changes.contains(.delete(a, reassignItemsTo: .level(Fixture.levelId))))
        XCTAssertFalse(s.merge(c, c))
    }

    func testAddOpeningOnNearestWall() {
        var (s, a, _) = twoRooms()
        let id = s.addOpening(kind: .door, near: Vec2(60, 3), scale: 1)
        XCTAssertNotNil(id)
        let o = s.openings.first { $0.id == id }!
        XCTAssertEqual(o.spaceId, a)
        XCTAssertEqual(o.segment.length, 32, accuracy: 1e-6)
        XCTAssertEqual(o.segment.a.y, 0, accuracy: 1e-6)
        let (ups, dels) = s.openingChanges(against: [])
        XCTAssertEqual(ups.count, 1); XCTAssertTrue(dels.isEmpty)
        XCTAssertNil(s.addOpening(kind: .window, near: Vec2(1000, 1000), scale: 1))
    }

    func testRenameAndUndoLimit() {
        var (s, a, _) = twoRooms()
        s.rename(a, to: "  Den  ")
        XCTAssertEqual(s.space(a)!.name, "Den")
        s.rename(a, to: "   ")
        XCTAssertEqual(s.space(a)!.name, "Den")
        for i in 0..<(PlanEditSession.undoLimit + 20) { s.rename(a, to: "N\(i)") }
        var n = 0
        while s.canUndo { s.undo(); n += 1 }
        XCTAssertEqual(n, PlanEditSession.undoLimit)
    }
}
