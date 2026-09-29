import XCTest
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import PlanCanvas

final class RenderModelTests: XCTestCase {
    func testGeometryBuildsSpacesWallsAndOpenings() {
        let g = RenderModelBuilder.geometry(Fixture.geometry(SampleHome.firstFloorId))
        XCTAssertEqual(g.spaces.count, 6)
        XCTAssertFalse(g.walls.isEmpty)
        XCTAssertTrue(g.walls.contains { $0.kind == .perimeter })
        XCTAssertTrue(g.walls.contains { $0.kind == .interior })
        XCTAssertEqual(g.openings.count, 2)
        XCTAssertEqual(g.bounds, Rect(x: 0, y: 0, width: 480, height: 360))
        let kitchen = g.space(SampleHome.kitchenId)!
        XCTAssertEqual(kitchen.dimsText, "14′0″ × 14′0″")
        XCTAssertEqual(kitchen.spokenDims, "14 by 14 feet")
        XCTAssertEqual(kitchen.pole.x, 23 * 12, accuracy: 1.5)
        XCTAssertEqual(kitchen.poleRadius, 7 * 12, accuracy: 1.5)
        XCTAssertEqual(g.roomCount, 6)
        XCTAssertEqual(g.interiorAreaSqIn, 912 * 144, accuracy: 1)   // rooms leave an unmodeled corner
    }

    func testDoorGlyphSwingsIntoItsRoom() {
        let g = RenderModelBuilder.geometry(Fixture.geometry(SampleHome.firstFloorId))
        let window = g.openings.first { $0.kind == .window }!
        XCTAssertTrue(window.isSliding)
        let door = g.openings.first { $0.kind == .door }!
        XCTAssertFalse(door.isSliding)
        XCTAssertEqual(door.widthIn, 36, accuracy: 1e-9)
        // Front door on the y = 30 ft perimeter; the room is above (smaller y), so the leaf swings toward −y.
        XCTAssertLessThan(door.swingDirection.y, 0)
    }

    func testExteriorHasNoWallsAndSortsBigZonesFirst() {
        let g = RenderModelBuilder.geometry(Fixture.geometry(SampleHome.outsideId))
        XCTAssertTrue(g.isExterior)
        XCTAssertTrue(g.walls.isEmpty)
        XCTAssertEqual(g.spaces.last?.name, "Garden Bed")
        XCTAssertEqual(g.zoneCount, 3)
        XCTAssertEqual(g.space(SampleHome.id(46))?.fillStyle, .lawn)
        XCTAssertEqual(g.space(SampleHome.id(48))?.fillStyle, .mulch)
    }

    func testNarrowRoomsGetShortNamesAndApproximateDims() {
        let lvl = Fixture.level()
        var cl = Fixture.space("Closet", Fixture.rect(0, 0, 4, 6), type: .closet)
        cl.isApproximate = true
        let l = Fixture.space("L Room", try! Polygon([Vec2(0, 0), Vec2(240, 0), Vec2(240, 120), Vec2(120, 120), Vec2(120, 240), Vec2(0, 240)]))
        let g = RenderModelBuilder.geometry(LevelGeometry(level: lvl, spaces: [cl, l], openings: []))
        let closet = g.space(cl.id)!
        XCTAssertEqual(closet.shortName, "Cl.")
        XCTAssertEqual(closet.fillStyle, .roomAlt)
        XCTAssertTrue(closet.dimsText.hasPrefix("~"))
        let lr = g.space(l.id)!
        XCTAssertEqual(lr.dimsText, "~20′0″ × 20′0″")
        XCTAssertTrue(lr.spokenDims.hasPrefix("about"))
        XCTAssertTrue(Contains.contains(l.polygon, lr.pole))
    }

    func testDegeneratePolygonIsSkipped() {
        let bad = Fixture.space("Bad", Polygon(unchecked: [Vec2(0, 0), Vec2(1, 1)]))
        let ok = Fixture.space("Ok", Fixture.rect(0, 0, 10, 10))
        let g = RenderModelBuilder.geometry(LevelGeometry(level: Fixture.level(), spaces: [bad, ok], openings: []))
        XCTAssertEqual(g.spaces.map(\.name), ["Ok"])
        XCTAssertEqual(g.skippedSpaceIds, [bad.id])
    }

    func testPoleCacheMemoizes() {
        let cache = PoleCache()
        let p = Fixture.rect(0, 0, 10, 12)
        let a = cache.pole(of: p), b = cache.pole(of: p)
        XCTAssertEqual(a, b)
        XCTAssertEqual(cache.count, 1)
    }

    func testRebuildingLensReusesGeometry() {
        let m = Fixture.model(SampleHome.firstFloorId, lens: .plan)
        let m2 = RenderModelBuilder.rebuildingLens(m, lens: .todos, stats: Fixture.stats(SampleHome.firstFloorId), context: Fixture.context(SampleHome.firstFloorId))
        XCTAssertEqual(m2.geometry, m.geometry)
        XCTAssertEqual(m2.lens.lens, .todos)
        XCTAssertEqual(m2.version, m.version + 1)
    }

    func testNilStatsStillProducesPlanFooter() {
        let geo = Fixture.geometry(SampleHome.firstFloorId)
        let m = RenderModelBuilder.build(geometry: geo, stats: nil, lens: .plan, context: LensContext(levelName: "1st Floor"))
        XCTAssertEqual(m.lens.footer.primaryText, "1st Floor · 6 rooms · 912 sq ft")
    }
}
