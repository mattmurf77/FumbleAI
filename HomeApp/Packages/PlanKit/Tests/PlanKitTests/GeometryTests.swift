import XCTest
@testable import PlanKit

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Vec2] {
    [Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)]
}

final class PolygonTests: XCTestCase {
    func testAreaAndWindingNormalized() throws {
        let cw = try Polygon(rect(0, 0, 120, 144))
        XCTAssertEqual(cw.area, 120 * 144, accuracy: 1e-9)
        XCTAssertGreaterThan(cw.signedArea, 0)
        let reversed = try Polygon(rect(0, 0, 120, 144).reversed())
        XCTAssertGreaterThan(reversed.signedArea, 0)
        XCTAssertEqual(cw.bounds, Rect(minX: 0, minY: 0, maxX: 120, maxY: 144))
    }

    func testRemovesDuplicatesAndCollinear() throws {
        let v = [Vec2(0, 0), Vec2(0.001, 0), Vec2(60, 0.1), Vec2(120, 0), Vec2(120, 120), Vec2(0, 120), Vec2(0, 0)]
        let p = try Polygon(v)
        XCTAssertEqual(p.count, 4)
    }

    func testRejectsSmallAndSelfIntersecting() {
        XCTAssertThrowsError(try Polygon(rect(0, 0, 10, 10))) { e in
            guard case PolygonError.tooSmall = e else { return XCTFail("\(e)") }
        }
        XCTAssertNoThrow(try Polygon(rect(0, 0, 13, 13), minArea: Tolerance.minZoneArea))
        let bowtie = [Vec2(0, 0), Vec2(100, 100), Vec2(100, 0), Vec2(0, 100)]
        XCTAssertThrowsError(try Polygon(bowtie)) { e in XCTAssertEqual(e as? PolygonError, .selfIntersecting) }
        XCTAssertThrowsError(try Polygon([Vec2(0, 0), Vec2(100, 0)]))
        XCTAssertThrowsError(try Polygon([Vec2(0, 0), Vec2(.nan, 0), Vec2(0, 100)]))
    }

    func testRoundsToHundredths() throws {
        let p = try Polygon([Vec2(0.004, 0), Vec2(100.126, 0), Vec2(100, 100), Vec2(0, 100)])
        XCTAssertEqual(p.vertices[1].x, 100.13, accuracy: 1e-9)
    }

    func testCodableRoundTripAsArrays() throws {
        let p = try Polygon(rect(0, 0, 120, 100))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(String(data: data, encoding: .utf8), "[[0,0],[120,0],[120,100],[0,100]]")
        XCTAssertEqual(try JSONDecoder().decode(Polygon.self, from: data), p)
    }

    func testRectangleSize() throws {
        let p = try Polygon(rect(0, 0, 148, 168))
        let s = try XCTUnwrap(p.rectangleSize)
        XCTAssertEqual(s.width, 148, accuracy: 1e-9)
        XCTAssertEqual(s.height, 168, accuracy: 1e-9)
        let l = try Polygon([Vec2(0, 0), Vec2(200, 0), Vec2(200, 100), Vec2(100, 100), Vec2(100, 200), Vec2(0, 200)])
        XCTAssertNil(l.rectangleSize)
    }

    func testCentroid() throws {
        let p = try Polygon(rect(10, 20, 100, 50))
        XCTAssertEqual(p.centroid.x, 60, accuracy: 1e-9)
        XCTAssertEqual(p.centroid.y, 45, accuracy: 1e-9)
    }
}

final class ContainsTests: XCTestCase {
    let lShape = try! Polygon([Vec2(0, 0), Vec2(200, 0), Vec2(200, 100), Vec2(100, 100), Vec2(100, 200), Vec2(0, 200)])

    func testPointInPolygon() {
        XCTAssertTrue(lShape.contains(Vec2(50, 150)))
        XCTAssertFalse(lShape.contains(Vec2(150, 150)))
        XCTAssertTrue(lShape.contains(Vec2(200, 50)), "on edge counts as inside")
        XCTAssertTrue(lShape.contains(Vec2(200.005, 50)))
        XCTAssertFalse(lShape.contains(Vec2(-1, -1)))
    }

    func testDistanceAndSignedDistance() {
        XCTAssertEqual(lShape.distanceToEdge(Vec2(50, 50)), 50, accuracy: 1e-9)
        XCTAssertEqual(Contains.signedDistance(lShape, Vec2(150, 150)), -50, accuracy: 1e-9)
    }

    func testHitTestSmallestContainingThenRadius() throws {
        let yard = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(0, 0, 1000, 1000)))
        let bed = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(100, 100, 50, 50)))
        let closet = IdentifiedPolygon(id: UUID(), polygon: try Polygon(rect(2000, 0, 30, 30)))
        XCTAssertEqual(HitTester.hit(Vec2(120, 120), in: [yard, bed, closet], hitRadius: 5), bed.id)
        XCTAssertEqual(HitTester.hit(Vec2(500, 500), in: [yard, bed, closet], hitRadius: 5), yard.id)
        XCTAssertEqual(HitTester.hit(Vec2(2035, 10), in: [yard, bed, closet], hitRadius: 10), closet.id)
        XCTAssertNil(HitTester.hit(Vec2(2100, 10), in: [yard, bed, closet], hitRadius: 10))
        XCTAssertEqual(HitTester.vertexIndex(Vec2(101, 99), in: bed.polygon, radius: 3), 0)
    }
}

final class PolyLabelTests: XCTestCase {
    func testSquarePoleIsCenter() throws {
        let r = PolyLabel.pole(of: try Polygon(rect(0, 0, 100, 100)), precision: 0.5)
        XCTAssertEqual(r.point.x, 50, accuracy: 1)
        XCTAssertEqual(r.point.y, 50, accuracy: 1)
        XCTAssertEqual(r.radius, 50, accuracy: 1)
    }

    func testLShapePoleIsInsideAwayFromNotch() throws {
        let l = try Polygon([Vec2(0, 0), Vec2(300, 0), Vec2(300, 100), Vec2(100, 100), Vec2(100, 300), Vec2(0, 300)])
        let r = PolyLabel.pole(of: l, precision: 1)
        XCTAssertTrue(l.contains(r.point))
        XCTAssertEqual(r.radius, 58.56, accuracy: 1.5)   // circle touching both outer walls and the notch corner
        // Centroid of this L lies outside the thick part; pole must be at least 49 in from edges.
        XCTAssertGreaterThan(l.distanceToEdge(r.point), 48)
    }
}

final class TransformTests: XCTestCase {
    func testComposeAndInverse() {
        let t = Transform2D.scale(2).then(.rotation(.pi / 2)).then(.translation(x: 10, y: 5))
        let p = t.apply(Vec2(1, 0))
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 7, accuracy: 1e-9)
        let back = t.inverse!.apply(p)
        XCTAssertEqual(back.x, 1, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0, accuracy: 1e-9)
    }

    func testFitSimilarityAndAffine() {
        let t = Transform2D.fitSimilarity(from: Vec2(0, 0), Vec2(10, 0), to: Vec2(5, 5), Vec2(5, 25))!
        let q = t.apply(Vec2(10, 0))
        XCTAssertEqual(q.x, 5, accuracy: 1e-9); XCTAssertEqual(q.y, 25, accuracy: 1e-9)
        XCTAssertEqual(t.uniformScale, 2, accuracy: 1e-9)
        let truth = Transform2D(a: 1.5, b: 0.2, c: -0.3, d: 0.9, tx: 12, ty: -4)
        let src = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)]
        let fit = Transform2D.fitAffine(from: src, to: src.map(truth.apply))!
        XCTAssertEqual(fit.a, 1.5, accuracy: 1e-6); XCTAssertEqual(fit.c, -0.3, accuracy: 1e-6)
        XCTAssertEqual(fit.ty, -4, accuracy: 1e-6)
    }

    func testPolygonTransformKeepsPositiveWinding() throws {
        let p = try Polygon(rect(0, 0, 100, 50))
        let mirrored = p.transformed(by: .scale(x: -1, y: 1))
        XCTAssertGreaterThan(mirrored.signedArea, 0)
    }
}

final class TangentPlaneTests: XCTestCase {
    func testProjectRoundTrip() {
        let origin = GeoCoordinate(latitude: 40.0, longitude: -75.0)
        let plane = TangentPlane(origin: origin)
        let north = plane.project(GeoCoordinate(latitude: 40.0001, longitude: -75.0))
        XCTAssertLessThan(north.y, 0, "north is up (negative y)")
        XCTAssertEqual(north.y, -0.0001 * 110_574 * 39.3701, accuracy: 1e-6)
        let east = plane.project(GeoCoordinate(latitude: 40, longitude: -74.9999))
        XCTAssertGreaterThan(east.x, 0)
        let back = plane.unproject(Vec2(1234, -567))
        let again = plane.project(back)
        XCTAssertEqual(again.x, 1234, accuracy: 1e-6); XCTAssertEqual(again.y, -567, accuracy: 1e-6)
    }
}

final class UnderlayTests: XCTestCase {
    func testCalibrationScaleAndStraighten() throws {
        let a = Vec2(100, 100), b = Vec2(300, 103)   // ~0.86° off horizontal
        let out = try UnderlayCalibration.calibrate(a: a, b: b, lengthIn: 144, imageSize: Vec2(1000, 800)).get()
        XCTAssertEqual(out.transform.inchesPerPixel, 144 / a.distance(to: b), accuracy: 1e-9)
        XCTAssertEqual(out.transform.rotationRad, -atan2(3, 200), accuracy: 1e-9)
        XCTAssertNil(out.warning)
        let center = out.transform.toModel(pixel: Vec2(500, 400))
        XCTAssertEqual(center.x, 0, accuracy: 1e-6); XCTAssertEqual(center.y, 0, accuracy: 1e-6)
        let mA = out.transform.toModel(pixel: a), mB = out.transform.toModel(pixel: b)
        XCTAssertEqual(mA.y, mB.y, accuracy: 1e-6, "straightened")
        XCTAssertEqual(mA.distance(to: mB), 144, accuracy: 1e-6)
    }

    func testStretchWarning() throws {
        let out = try UnderlayCalibration.calibrate(a: Vec2(0, 0), b: Vec2(100, 0), lengthIn: 100,
                                                    second: (Vec2(0, 0), Vec2(0, 100), 120), imageSize: Vec2(200, 200)).get()
        guard case .possiblyStretched = out.warning else { return XCTFail("expected warning") }
        XCTAssertEqual(out.transform.inchesPerPixel, 1.1, accuracy: 1e-9)
    }
}
