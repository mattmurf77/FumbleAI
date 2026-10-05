import XCTest
import PlanKit
@testable import HomeCore
@testable import HomeCoreTesting

final class SpaceNestingTests: XCTestCase {
    func shape(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ t: SpaceType = .room) -> SpaceNesting.Shape {
        SpaceNesting.Shape(id: UUID(), spaceType: t, polygon: PlanKit.Polygon(rect: PlanKit.Rect(x: x, y: y, width: w, height: h)))
    }

    func testClosetInsideRoomIsNestedAndAllowed() {
        let room = shape(0, 0, 120, 120, .bedroom), closet = shape(30, 0, 60, 24, .closet), next = shape(120, 0, 120, 120)
        let all = [room, closet, next]
        XCTAssertEqual(SpaceNesting.hosts(all), [closet.id: room.id])
        XCTAssertTrue(SpaceNesting.overlappingPairs(all).isEmpty)
        XCTAssertEqual(SpaceNesting.floorAreaSqIn(all), 2 * 120 * 120, accuracy: 1e-6)
    }

    func testOtherOverlapsStillRejected() {
        let room = shape(0, 0, 120, 120), next = shape(120, 0, 120, 120)
        // Closet straddling the shared wall: overlaps the neighbour, nested in neither.
        let straddle = shape(100, 0, 60, 24, .closet)
        XCTAssertEqual(SpaceNesting.overlappingPairs([room, next, straddle]).count, 2)
        XCTAssertTrue(SpaceNesting.hosts([room, next, straddle]).isEmpty)
        // A non-closet inside a room, a closet inside a closet, a closet inside stairs.
        XCTAssertEqual(SpaceNesting.overlappingPairs([room, shape(0, 0, 60, 60, .office)]).count, 1)
        let c1 = shape(0, 0, 60, 48, .closet), c2 = shape(0, 0, 30, 24, .closet)
        XCTAssertEqual(SpaceNesting.overlappingPairs([room, c1, c2]).count, 1)
        XCTAssertEqual(SpaceNesting.overlappingPairs([shape(0, 0, 48, 120, .stairs), shape(0, 0, 36, 24, .closet)]).count, 1)
        // Exterior zones are not checked at all (they may overlap).
        var lawn = shape(0, 0, 60, 60, .lawn); lawn.isExterior = true
        XCTAssertTrue(SpaceNesting.overlappingPairs([room, lawn]).isEmpty)
    }

    func testFloorAreaCountsOldStyleClosetsAndNestedOnce() {
        let room = shape(0, 0, 120, 120), beside = shape(120, 0, 36, 72, .closet), inside = shape(0, 0, 60, 24, .closet)
        XCTAssertEqual(SpaceNesting.floorAreaSqIn([room, beside, inside]), 120 * 120 + 36 * 72, accuracy: 1e-6)
    }

    func testRepositoryAcceptsNestedClosetAndRejectsOverlap() async throws {
        let home = InMemoryHome.sample(clock: FixedClock(LocalDate(2026, 9, 29), minutes: 8 * 60))
        let before = try await home.plan.geometry(level: SampleHome.firstFloorId).totalAreaSqIn
        // Living Room is 16 × 18 ft at the origin: a closet against its top wall.
        let closet = Space(propertyId: SampleHome.propertyId, levelId: SampleHome.firstFloorId, name: "Coat Closet",
                           spaceType: .closet, polygon: PlanKit.Polygon(rect: PlanKit.Rect(x: 24, y: 0, width: 60, height: 24)))
        try await home.plan.updateSpaces([.insert(closet)])
        let g = try await home.plan.geometry(level: SampleHome.firstFloorId)
        XCTAssertEqual(SpaceNesting.hosts(g.spaces)[closet.id], SampleHome.livingId)
        XCTAssertEqual(g.totalAreaSqIn, before, accuracy: 1e-6)

        // The same closet straddling Living Room / Kitchen (x = 192) is still an overlap.
        var moved = closet
        moved.polygon = PlanKit.Polygon(rect: PlanKit.Rect(x: 170, y: 0, width: 60, height: 24))
        do { try await home.plan.updateSpaces([.update(moved)]); XCTFail("expected overlap") }
        catch { guard case RepositoryError.overlap = error else { return XCTFail("\(error)") } }
    }
}
