import XCTest
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import PlanCanvas

/// Founder feedback: "Closets should work like doors. Can be in rooms (rather than overlap issue) and can simply
/// click them into room (same door function)."
final class ClosetTests: XCTestCase {
    // Two 10 × 10 ft rooms sharing the wall at x = 120.
    func twoRooms() -> (PlanEditSession, UUID, UUID) {
        let a = Fixture.space("A", Fixture.rect(0, 0, 10, 10), type: .bedroom), b = Fixture.space("B", Fixture.rect(10, 0, 10, 10))
        return (PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [a, b], openings: [])), a.id, b.id)
    }

    // MARK: Placement

    func testClosetPlacedFlushInsideTappedWallCenteredOnTap() throws {
        var (s, a, _) = twoRooms()
        let id = try XCTUnwrap(s.addCloset(near: Vec2(61, 3), scale: 1))
        let c = try XCTUnwrap(s.space(id))
        XCTAssertEqual(c.spaceType, .closet)
        XCTAssertEqual(c.name, "Closet")
        XCTAssertEqual(s.selection, id)
        let b = c.polygon.bounds
        XCTAssertEqual(b.minX, 30, accuracy: 1e-6)    // 5 ft wide, centered on x = 60 (snapped)
        XCTAssertEqual(b.maxX, 90, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 0, accuracy: 1e-6)     // against the top wall, 2 ft deep into the room
        XCTAssertEqual(b.maxY, 24, accuracy: 1e-6)
        XCTAssertEqual(SpaceNesting.hosts(s.spaces)[id], a)
        XCTAssertTrue(s.canSave, "a closet inside its room is not an overlap")
        // A sliding door across the open (room) side.
        let door = try XCTUnwrap(s.openings.first { $0.spaceId == id })
        XCTAssertEqual(door.kind, .door)
        XCTAssertEqual(door.swing, .sliding)
        XCTAssertEqual(door.segment.a.y, 24, accuracy: 1e-6)
        XCTAssertEqual(door.segment.b.y, 24, accuracy: 1e-6)
        XCTAssertEqual(door.segment.length, 48, accuracy: 1e-6)
        // One undo step removes closet and door.
        s.undo()
        XCTAssertNil(s.space(id))
        XCTAssertTrue(s.openings.isEmpty)
    }

    func testClosetClampedToWallEndsAndLength() throws {
        var (s, _, _) = twoRooms()
        // Near the top-left corner: slides right so it stays on the wall.
        let c1 = try XCTUnwrap(s.addCloset(near: Vec2(8, 2), scale: 1))
        XCTAssertEqual(s.space(c1)!.polygon.bounds.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(s.space(c1)!.polygon.bounds.maxX, 60, accuracy: 1e-6)

        // A 4 ft wide, 1.5 ft deep alcove: width clamps to the wall, depth to the room.
        let nook = Fixture.space("Nook", Fixture.rect(0, 0, 4, 1.5))
        var t = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [nook], openings: []))
        let c2 = try XCTUnwrap(t.addCloset(near: Vec2(24, 1), scale: 1))
        let b = t.space(c2)!.polygon.bounds
        XCTAssertEqual(b.width, 48, accuracy: 1e-6)
        XCTAssertEqual(b.height, 18, accuracy: 1e-6)
        XCTAssertTrue(t.canSave)
    }

    func testSharedWallPicksTheRoomTapped() throws {
        var (s, a, b) = twoRooms()
        let inA = try XCTUnwrap(s.addCloset(near: Vec2(117, 60), scale: 1))
        let inB = try XCTUnwrap(s.addCloset(near: Vec2(123, 60), scale: 1))
        let hosts = SpaceNesting.hosts(s.spaces)
        XCTAssertEqual(hosts[inA], a)
        XCTAssertEqual(hosts[inB], b)
        XCTAssertEqual(s.space(inA)!.polygon.bounds.minX, 96, accuracy: 1e-6)
        XCTAssertEqual(s.space(inB)!.polygon.bounds.maxX, 144, accuracy: 1e-6)
        XCTAssertEqual(s.space(inB)!.name, "Closet 2")
        XCTAssertTrue(s.canSave)
    }

    func testNoClosetAwayFromWallsOrWhereOneIsAlready() {
        var (s, _, _) = twoRooms()
        XCTAssertNil(s.addCloset(near: Vec2(60, 60), scale: 1))        // 60 in from any wall (> 44 pt)
        XCTAssertNotNil(s.addCloset(near: Vec2(60, 2), scale: 1))
        XCTAssertNil(s.addCloset(near: Vec2(60, 2), scale: 1))         // same spot is taken
        XCTAssertEqual(s.spaces.count, 3)
        var ext = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(exterior: true),
                                                          spaces: [Fixture.space("Lawn", Fixture.rect(0, 0, 10, 10), type: .lawn)], openings: []))
        XCTAssertNil(ext.addCloset(near: Vec2(60, 2), scale: 1))
    }

    // MARK: Validation

    func testOverlapRuleStillRejectsOtherOverlaps() throws {
        var (s, a, _) = twoRooms()
        let c = try XCTUnwrap(s.addCloset(near: Vec2(60, 2), scale: 1))
        XCTAssertTrue(s.overlappingPairs().isEmpty)
        // Drag the closet across the shared wall into B: now it overlaps B (and pokes out of A).
        s.selection = c
        s.beginDrag(.interior(c))
        s.updateDrag(translation: Vec2(48, 0), scale: 1)
        s.endDrag()
        XCTAssertFalse(s.canSave)
        XCTAssertTrue(s.overlapsInvolve(c))

        // Two closets overlapping each other inside the same room.
        let room = Fixture.space("Room", Fixture.rect(0, 0, 10, 10))
        let c1 = Fixture.space("Closet", Fixture.rect(0, 0, 5, 2), type: .closet)
        let c2 = Fixture.space("Closet 2", Fixture.rect(4, 0, 5, 2), type: .closet)
        let t = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [room, c1, c2], openings: []))
        XCTAssertEqual(t.overlappingPairs().count, 1)
        XCTAssertEqual(Set([t.overlappingPairs()[0].0, t.overlappingPairs()[0].1]), [c1.id, c2.id])

        // Only closets nest: a bedroom inside a room is still an overlap; so is a closet inside stairs.
        let inner = Fixture.space("Inner", Fixture.rect(0, 0, 5, 5), type: .bedroom)
        XCTAssertFalse(PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [room, inner], openings: [])).canSave)
        let stairs = Fixture.space("Stairs", Fixture.rect(0, 0, 4, 10), type: .stairs)
        let inStairs = Fixture.space("Closet", Fixture.rect(0, 0, 3, 2), type: .closet)
        XCTAssertFalse(PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [stairs, inStairs], openings: [])).canSave)
        _ = a
    }

    func testOldStyleClosetBesideRoomStillWorks() {
        let room = Fixture.space("Room", Fixture.rect(0, 0, 10, 10))
        let closet = Fixture.space("Closet", Fixture.rect(10, 0, 3, 6), type: .closet)
        let s = PlanEditSession(geometry: LevelGeometry(level: Fixture.level(), spaces: [room, closet], openings: []))
        XCTAssertTrue(s.canSave)
        XCTAssertTrue(SpaceNesting.hosts(s.spaces).isEmpty)
        XCTAssertEqual(SpaceNesting.floorAreaSqIn(s.spaces), 120 * 120 + 36 * 72, accuracy: 1e-6)
    }

    // MARK: Selection and editing

    func testTapInsideClosetSelectsClosetElsewhereRoom() throws {
        var (s, a, _) = twoRooms()
        let c = try XCTUnwrap(s.addCloset(near: Vec2(60, 2), scale: 1))
        s.selection = nil
        XCTAssertEqual(s.hitTest(Vec2(60, 12), scale: 1), .interior(c))
        XCTAssertEqual(s.hitTest(Vec2(60, 80), scale: 1), .interior(a))
    }

    func testMovingRoomCarriesItsClosetAndDoor() throws {
        var (s, a, _) = twoRooms()
        let c = try XCTUnwrap(s.addCloset(near: Vec2(60, 2), scale: 1))
        let door = s.openings.first { $0.spaceId == c }!.segment
        s.selection = a
        s.beginDrag(.interior(a))
        s.updateDrag(translation: Vec2(0, 60), scale: 1)
        s.endDrag()
        XCTAssertEqual(s.space(a)!.polygon.bounds.minY, 60, accuracy: 1e-6)
        XCTAssertEqual(s.space(c)!.polygon.bounds.minY, 60, accuracy: 1e-6)
        XCTAssertEqual(s.openings.first { $0.spaceId == c }!.segment.a.y, door.a.y + 60, accuracy: 1e-6)
        XCTAssertEqual(SpaceNesting.hosts(s.spaces)[c], a)
    }

    func testDraggingRoomWallSlidesClosetAndClosetWallLeavesRoom() throws {
        var (s, a, _) = twoRooms()
        let c = try XCTUnwrap(s.addCloset(near: Vec2(60, 2), scale: 1))
        // Edge 0 of A is the top wall y = 0: move it up 1 ft; the closet keeps its 2 ft depth and follows.
        s.selection = a
        s.beginDrag(.edge(a, 0))
        s.updateDrag(translation: Vec2(0, -12), scale: 1)
        s.endDrag()
        XCTAssertEqual(s.space(a)!.polygon.bounds.minY, -12, accuracy: 1e-6)
        let cb = s.space(c)!.polygon.bounds
        XCTAssertEqual(cb.minY, -12, accuracy: 1e-6)
        XCTAssertEqual(cb.height, 24, accuracy: 1e-6)
        XCTAssertTrue(s.canSave)

        // Dragging the closet's own back wall resizes only the closet (the room's wall stays put).
        let back = s.space(c)!.polygon.edges.firstIndex { abs($0.a.y + 12) < 1e-6 && abs($0.b.y + 12) < 1e-6 }!
        s.selection = c
        s.beginDrag(.edge(c, back))
        s.updateDrag(translation: Vec2(0, 6), scale: 1)
        s.endDrag()
        XCTAssertEqual(s.space(a)!.polygon.bounds.minY, -12, accuracy: 1e-6)
        XCTAssertLessThan(s.space(c)!.polygon.bounds.height, 24)
        XCTAssertGreaterThan(s.space(c)!.polygon.bounds.minY, -12)
    }

    // MARK: Rendering and totals

    func testRenderModelDrawsClosetOnTopAndCountsAreaOnce() throws {
        var (s, a, b) = twoRooms()
        let c = try XCTUnwrap(s.addCloset(near: Vec2(60, 2), scale: 1))
        let m = RenderModelBuilder.build(geometry: s.geometry, stats: nil, lens: .plan, context: LensContext(levelName: "Ground"))
        let order = m.geometry.spaces.map(\.id)
        XCTAssertGreaterThan(order.firstIndex(of: c)!, order.firstIndex(of: a)!)
        XCTAssertEqual(m.geometry.space(c)?.hostId, a)
        XCTAssertNil(m.geometry.space(a)?.hostId)
        XCTAssertEqual(m.geometry.space(c)?.shortName, "Cl.")
        // 2 rooms of 100 sq ft; the closet's 10 sq ft is inside A and not added again.
        XCTAssertEqual(m.geometry.interiorAreaSqIn, 2 * 120 * 120, accuracy: 1e-6)
        XCTAssertEqual(s.geometry.totalAreaSqIn, 2 * 120 * 120, accuracy: 1e-6)
        XCTAssertEqual(SpaceNesting.floorAreaSqIn(s.spaces), 2 * 120 * 120, accuracy: 1e-6)
        // The top wall stays one run, not split by the closet; the closet gets thin walls on its 3 inner sides,
        // with a gap for its door on the front.
        let top = m.geometry.walls.filter { abs($0.seg.a.y) < 1e-6 && abs($0.seg.b.y) < 1e-6 }
        XCTAssertEqual(top.count, 1)
        XCTAssertTrue(top.allSatisfy { !$0.spaceIds.contains(c) && $0.seg.length > 239 }, "\(top)")
        let closetWalls = m.geometry.walls.filter { $0.spaceIds.contains(c) }
        XCTAssertEqual(closetWalls.count, 3, "\(closetWalls)")
        XCTAssertTrue(closetWalls.allSatisfy { $0.kind == .interior && $0.spaceIds.contains(a) })
        XCTAssertEqual(closetWalls.filter { !$0.gaps.isEmpty }.count, 1)
        _ = b
    }

    func testShortNamesForNumberedClosets() {
        XCTAssertEqual(ShortNames.short("Closet"), "Cl.")
        XCTAssertEqual(ShortNames.short("Closet 2"), "Cl. 2")
        XCTAssertEqual(ShortNames.short("Bedroom 2"), "Bedr.")
    }
}

private extension PlanEditSession {
    func overlapsInvolve(_ id: UUID) -> Bool { overlappingPairs().contains { $0.0 == id || $0.1 == id } }
}
