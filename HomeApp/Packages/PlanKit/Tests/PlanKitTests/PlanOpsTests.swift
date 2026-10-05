import XCTest
@testable import PlanKit

final class SnapperTests: XCTestCase {
    let ctx = SnapContext(vertices: [Vec2(100, 100), Vec2(300, 40)],
                          edges: [Segment(Vec2(0, 200), Vec2(400, 200))],
                          gridIn: 6, scale: 1, orthogonal: false)   // radius 12 in

    func testVertexWins() {
        let r = Snapper.snap(candidate: Vec2(105, 95), context: ctx)
        XCTAssertEqual(r.kind, .vertex); XCTAssertEqual(r.point, Vec2(100, 100))
    }
    func testEdge() {
        let r = Snapper.snap(candidate: Vec2(250, 192), context: ctx)
        XCTAssertEqual(r.kind, .edge); XCTAssertEqual(r.point, Vec2(250, 200))
    }
    func testAlignment() {
        let r = Snapper.snap(candidate: Vec2(104, 150), context: ctx)
        XCTAssertEqual(r.kind, .alignment)
        XCTAssertEqual(r.point.x, 100); XCTAssertEqual(r.point.y, 150)
        XCTAssertEqual(r.guides.count, 1)
    }
    func testGrid() {
        let r = Snapper.snap(candidate: Vec2(200, 130), context: ctx)
        XCTAssertEqual(r.kind, .grid); XCTAssertEqual(r.point, Vec2(198, 132))
    }
    func testOrthogonalConstraint() {
        var c = ctx; c.orthogonal = true; c.axisOrigin = Vec2(0, 0); c.vertices = []; c.edges = []
        let r = Snapper.snap(candidate: Vec2(200, 7), context: c)
        XCTAssertEqual(r.point.y, 0)
        XCTAssertEqual(r.point.x, 198)
    }
    func testEdgeOffsetSnapsToNeighbor() {
        XCTAssertEqual(Snapper.snapEdgeOffset(10, baseOffset: 100, neighborOffsets: [113], gridIn: 6, scale: 1), 13)
        XCTAssertEqual(Snapper.snapEdgeOffset(40, baseOffset: 100, neighborOffsets: [113], gridIn: 6, scale: 1), 42)
    }
}

final class WallDerivationTests: XCTestCase {
    func testTwoRoomsShareInteriorWall() throws {
        let a = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(0, 0, 120, 120)))
        // 2 in gap, within the 3 in merge tolerance.
        let b = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(122, 0, 120, 120)))
        let walls = WallDerivation.walls(spaces: [a, b])
        let interior = walls.filter { $0.kind == .interior }
        XCTAssertEqual(interior.count, 1)
        XCTAssertEqual(Set(interior[0].spaceIds), [a.id, b.id])
        XCTAssertEqual(interior[0].seg.length, 120, accuracy: 1e-6)
        XCTAssertEqual(interior[0].thicknessIn, 4.5)
        let perimeterLength = walls.filter { $0.kind == .perimeter }.reduce(0) { $0 + $1.seg.length }
        // top + bottom (each 242 total, split across the shared line) + 2 outer sides.
        XCTAssertEqual(perimeterLength, 120 + 120 + 2 * 240, accuracy: 1e-6)   // the 2 in gap span has no owner
    }

    func testPartialOverlapSplitsIntoInteriorAndPerimeter() throws {
        let a = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(0, 0, 100, 200)))
        let b = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(100, 0, 100, 100)))
        let onShared = WallDerivation.walls(spaces: [a, b]).filter { abs($0.seg.a.x - 100) < 0.01 && abs($0.seg.b.x - 100) < 0.01 }
        XCTAssertEqual(onShared.count, 2)
        XCTAssertEqual(onShared.filter { $0.kind == .interior }.first?.seg.length ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(onShared.filter { $0.kind == .perimeter }.first?.seg.length ?? 0, 100, accuracy: 1e-6)
    }

    func testOpeningCutsGap() throws {
        let a = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(0, 0, 100, 100)))
        let door = Segment(Vec2(30, 1), Vec2(66, 1))
        let top = WallDerivation.walls(spaces: [a], openings: [door]).first { abs($0.seg.a.y) < 0.01 && abs($0.seg.b.y) < 0.01 }!
        XCTAssertEqual(top.gaps.count, 1)
        XCTAssertEqual(top.gaps[0].upperBound - top.gaps[0].lowerBound, 0.36, accuracy: 1e-6)
    }

    func testCoincidentEdges() throws {
        let a = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(0, 0, 100, 100)))
        let b = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(101, 0, 100, 100)))
        let shared = WallDerivation.coincidentEdges(of: Segment(Vec2(100, 0), Vec2(100, 100)), excluding: a.id, in: [a, b])
        XCTAssertEqual(shared.count, 1); XCTAssertEqual(shared[0].spaceId, b.id)
    }
}

final class WeldTests: XCTestCase {
    func testClustersNearVerticesAndStraightens() throws {
        let a = try Polygon(rect(0, 0, 120, 120))
        let b = try Polygon([Vec2(121.5, 0.8), Vec2(240, 0), Vec2(240, 120), Vec2(122, 119.5)])
        let result = Weld.weldDetailed(polygons: [a, b])
        XCTAssertTrue(result.failedIndices.isEmpty)
        let wa = result.polygons[0], wb = result.polygons[1]
        let shared = Set(wa.vertices).intersection(Set(wb.vertices))
        XCTAssertEqual(shared.count, 2, "two corners welded together")
        for v in wb.vertices { XCTAssertTrue([0.0, 120.0, 119.75, 119.88, 0.4, 0.2, 0.0].contains { abs($0 - v.y) < 1 } ) }
        // Axis-straightened: every edge horizontal or vertical.
        for e in wa.edges + wb.edges { XCTAssertTrue(abs(e.vector.x) < 1e-6 || abs(e.vector.y) < 1e-6, "\(e)") }
    }

    func testTJunctionInsertsVertex() throws {
        let big = try Polygon(rect(0, 0, 100, 200))
        let small = try Polygon(rect(101, 50, 100, 100))
        let result = Weld.weld(polygons: [big, small])
        // small's left corners move onto big's right edge. (The copies inserted into big's ring are collinear
        // and are dropped again by Validation.normalize step 2; wall derivation handles T-junctions by interval sweep.)
        XCTAssertEqual(result[1].vertices.filter { abs($0.x - 100) < 1e-9 }.count, 2)
        let walls = WallDerivation.walls(spaces: [IdentifiedPolygon(id: UUID(), polygon: result[0]),
                                                  IdentifiedPolygon(id: UUID(), polygon: result[1])])
        XCTAssertEqual(walls.filter { $0.kind == .interior }.count, 1)
    }
}

final class ClipTests: XCTestCase {
    func testIntersectionArea() throws {
        let a = try Polygon(rect(0, 0, 100, 100)), b = try Polygon(rect(50, 50, 100, 100))
        XCTAssertEqual(Clip.intersectionArea(a, b), 2500, accuracy: 1e-6)
        let l = try Polygon([Vec2(0, 0), Vec2(200, 0), Vec2(200, 100), Vec2(100, 100), Vec2(100, 200), Vec2(0, 200)])
        let c = try Polygon(rect(150, 150, 100, 100))
        XCTAssertEqual(Clip.intersectionArea(l, c), 0, accuracy: 1e-6)
        let d = try Polygon(rect(50, 50, 200, 200))
        XCTAssertEqual(Clip.intersectionArea(l, d), 150 * 50 + 50 * 100, accuracy: 1e-6)
        XCTAssertFalse(Clip.overlaps(a, try Polygon(rect(100, 0, 50, 50))))
    }

    func testSplitAndUnion() throws {
        let p = try Polygon(rect(0, 0, 200, 100))
        let (a, b) = try XCTUnwrap(Clip.split(p, linePoint: Vec2(80, 0), direction: Vec2(0, 1)))
        XCTAssertEqual(a.area + b.area, 20000, accuracy: 1e-6)
        XCTAssertEqual(min(a.area, b.area), 8000, accuracy: 1e-6)
        let u = try XCTUnwrap(Clip.unionAdjacent(a, b))
        XCTAssertEqual(u.area, 20000, accuracy: 1e-6)
        XCTAssertEqual(u.count, 4)
        // Non-adjacent rooms cannot be merged.
        XCTAssertNil(Clip.unionAdjacent(a, try Polygon(rect(500, 0, 50, 50))))
        // T-junction union: small room against a long wall → L shape.
        let big = try Polygon(rect(0, 0, 100, 200)), small = try Polygon(rect(100, 50, 100, 100))
        let lshape = try XCTUnwrap(Clip.unionAdjacent(big, small))
        XCTAssertEqual(lshape.area, 30000, accuracy: 1e-6)
        XCTAssertEqual(lshape.count, 8)
    }

    func testOffset() throws {
        let p = try Polygon(rect(0, 0, 100, 100))
        let o = try XCTUnwrap(Clip.offset(p, by: 2.25))
        XCTAssertEqual(o.area, 104.5 * 104.5, accuracy: 1e-6)
        let shrunk = try XCTUnwrap(Clip.offset(p, by: -10))
        XCTAssertEqual(shrunk.area, 80 * 80, accuracy: 1e-6)
    }

    func testSimplifyAndHull() {
        var ring: [Vec2] = []
        for i in 0...10 { ring.append(Vec2(Double(i) * 10, i % 2 == 0 ? 0 : 1)) }
        ring += [Vec2(100, 100), Vec2(0, 100)]
        let s = Clip.simplify(ring, tolerance: 6)
        XCTAssertEqual(s.count, 4)
        let hull = Clip.convexHull([Vec2(0, 0), Vec2(10, 0), Vec2(5, 5), Vec2(10, 10), Vec2(0, 10)])
        XCTAssertEqual(hull.count, 4)
        XCTAssertGreaterThan(Area.signedArea(hull), 0)
    }

    func testDominantOrientation() {
        let r = Transform2D.rotation(Geometry.radians(12))
        let segs = [Segment(Vec2(0, 0), Vec2(100, 0)), Segment(Vec2(100, 0), Vec2(100, 60))].map(r.apply)
        XCTAssertEqual(Geometry.degrees(Orientation.dominantAngle(of: segs)), 12, accuracy: 1)
    }
}

final class TreemapTests: XCTestCase {
    func testTilesRectInInputOrderAndIsDeterministic() {
        let r = Rect(x: 0, y: 0, width: 600, height: 400)
        let weights = [1.0, 0.7, 0.55, 0.25, 0.18]
        let rects = Treemap.squarify(weights, in: r)
        XCTAssertEqual(rects.count, 5)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, r.area, accuracy: 1e-6)
        let total = weights.reduce(0, +)
        for (w, rr) in zip(weights, rects) { XCTAssertEqual(rr.area, w / total * r.area, accuracy: 1e-6) }
        // No overlaps.
        for i in rects.indices { for j in rects.indices where j > i {
            let a = Polygon(rect: rects[i]), b = Polygon(rect: rects[j])
            XCTAssertEqual(Clip.intersectionArea(a, b), 0, accuracy: 1e-6)
        } }
        XCTAssertEqual(rects, Treemap.squarify(weights, in: r))
    }

    func testSnappedCoordinatesOnGrid() {
        let r = Rect(x: 0, y: 0, width: 606, height: 432)
        let rects = Treemap.squarify([1, 0.85, 0.6, 0.25], in: r, snap: 6)
        for rr in rects {
            for v in [rr.minX, rr.maxX, rr.minY, rr.maxY] {
                XCTAssertEqual(v.truncatingRemainder(dividingBy: 6), 0, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, r.area, accuracy: 1e-6)
    }
}

final class ContainmentTests: XCTestCase {
    func testClosetFlushAgainstWallIsContained() {
        let room = PlanKit.Polygon(rect: PlanKit.Rect(x: 0, y: 0, width: 120, height: 120))
        let flush = PlanKit.Polygon(rect: PlanKit.Rect(x: 30, y: 0, width: 60, height: 24))
        let corner = PlanKit.Polygon(rect: PlanKit.Rect(x: 0, y: 0, width: 60, height: 24))
        XCTAssertTrue(Clip.isContained(flush, in: room))
        XCTAssertTrue(Clip.isContained(corner, in: room))
        XCTAssertTrue(Clip.isContained(room, in: room))
    }

    func testPokingOutIsNotContained() {
        let room = PlanKit.Polygon(rect: PlanKit.Rect(x: 0, y: 0, width: 120, height: 120))
        let out = PlanKit.Polygon(rect: PlanKit.Rect(x: 100, y: 0, width: 60, height: 24))   // 20 in inside, 40 out
        let apart = PlanKit.Polygon(rect: PlanKit.Rect(x: 200, y: 0, width: 60, height: 24))
        XCTAssertFalse(Clip.isContained(out, in: room))
        XCTAssertFalse(Clip.isContained(apart, in: room))
        // L-shaped room: a closet across the notch is outside it.
        let l = PlanKit.Polygon(unchecked: [Vec2(0, 0), Vec2(120, 0), Vec2(120, 60), Vec2(60, 60), Vec2(60, 120), Vec2(0, 120)])
        XCTAssertFalse(Clip.isContained(PlanKit.Polygon(rect: PlanKit.Rect(x: 40, y: 50, width: 40, height: 24)), in: l))
        XCTAssertTrue(Clip.isContained(PlanKit.Polygon(rect: PlanKit.Rect(x: 0, y: 96, width: 60, height: 24)), in: l))
    }
}
