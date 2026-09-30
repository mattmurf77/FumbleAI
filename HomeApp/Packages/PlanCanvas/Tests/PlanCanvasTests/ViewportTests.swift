import XCTest
import PlanKit
@testable import PlanCanvas

final class ViewportTests: XCTestCase {
    func testRoundTripMapping() {
        let v = Viewport(scale: 2, origin: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 400))
        let p = Vec2(15, 7)
        let s = v.toScreen(p)
        XCTAssertEqual(Double(s.x), 40, accuracy: 1e-9)
        XCTAssertEqual(Double(s.y), 34, accuracy: 1e-9)
        XCTAssertTrue(v.toModel(s).isApproximatelyEqual(to: p, tolerance: 1e-9))
    }

    func testFitCentersBoundsWithinInsets() {
        let b = Rect(x: 0, y: 0, width: 480, height: 360)   // 40 × 30 ft
        let v = Viewport.fit(b, in: CGSize(width: 393, height: 500), insets: ViewportInsets(all: 16))
        XCTAssertEqual(v.scale, (393 - 32) / 480, accuracy: 1e-9)
        XCTAssertEqual(v.fitScale, v.scale)
        let c = v.toScreen(b.center)
        XCTAssertEqual(Double(c.x), 393 / 2, accuracy: 1e-9)
        XCTAssertEqual(Double(c.y), 250, accuracy: 1e-9)
        let r = v.toScreen(b)
        XCTAssertGreaterThanOrEqual(Double(r.minX), 16 - 1e-9)
        XCTAssertLessThanOrEqual(Double(r.maxX), 393 - 16 + 1e-9)
    }

    func testFitEmptyBoundsIsUsable() {
        let v = Viewport.fit(.null, in: CGSize(width: 300, height: 300))
        XCTAssertGreaterThan(v.scale, 0)
        XCTAssertTrue(v.isConfigured)
    }

    func testZoomKeepsAnchorFixedAndClamps() {
        var v = Viewport.fit(Rect(x: 0, y: 0, width: 480, height: 360), in: CGSize(width: 400, height: 400))
        let anchor = CGPoint(x: 120, y: 200)
        let before = v.toModel(anchor)
        v.zoom(by: 2, anchor: anchor)
        XCTAssertTrue(v.toModel(anchor).isApproximatelyEqual(to: before, tolerance: 1e-9))
        XCTAssertEqual(v.scale, v.fitScale * 2, accuracy: 1e-9)
        v.zoom(by: 1000, anchor: anchor)
        XCTAssertEqual(v.scale, max(v.fitScale * 8, 12.5), accuracy: 1e-9)
        v.zoom(by: 0.00001, anchor: anchor)
        XCTAssertEqual(v.scale, v.fitScale * 0.8, accuracy: 1e-9)
        XCTAssertTrue(v.toModel(anchor).isApproximatelyEqual(to: before, tolerance: 1e-6))
    }

    func testZoomLimits() {
        XCTAssertEqual(Viewport.zoomLimits(fitScale: 1).upperBound, 12.5)
        XCTAssertEqual(Viewport.zoomLimits(fitScale: 2).upperBound, 16)
        XCTAssertEqual(Viewport.zoomLimits(fitScale: 1).lowerBound, 0.8, accuracy: 1e-12)
    }

    func testPanAndVisibleRect() {
        var v = Viewport(scale: 1, origin: .zero, size: CGSize(width: 100, height: 50), fitScale: 1)
        v.pan(by: CGSize(width: -10, height: 5))
        let r = v.visibleModelRect
        XCTAssertEqual(r.minX, 10, accuracy: 1e-9); XCTAssertEqual(r.minY, -5, accuracy: 1e-9)
        XCTAssertEqual(r.width, 100, accuracy: 1e-9); XCTAssertEqual(r.height, 50, accuracy: 1e-9)
    }

    func testClampKeepsContentOnScreen() {
        var v = Viewport(scale: 1, origin: .zero, size: CGSize(width: 300, height: 300), fitScale: 1)
        v.pan(by: CGSize(width: -5000, height: 0))
        let c = v.clamped(toContent: Rect(x: 0, y: 0, width: 200, height: 200), margin: 64)
        XCTAssertEqual(Double(c.toScreen(Rect(x: 0, y: 0, width: 200, height: 200)).maxX), 64, accuracy: 1e-9)
    }

    func testFocusingFitsRectAboveSheet() {
        var v = Viewport.fit(Rect(x: 0, y: 0, width: 480, height: 360), in: CGSize(width: 400, height: 600))
        v.obscuredBottom = 300
        let room = Rect(x: 192, y: 0, width: 168, height: 168)
        let f = v.focusing(on: room, padding: 20)
        let r = f.toScreen(room)
        XCTAssertLessThanOrEqual(Double(r.maxY), 300 + 1e-6)
        XCTAssertEqual(Double(r.midX), 200, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(f.scale, f.zoomLimits.upperBound)
    }

    func testRevealingPansMinimallyOrNotAtAll() {
        var v = Viewport(scale: 1, origin: .zero, size: CGSize(width: 400, height: 800), fitScale: 1)
        v.obscuredBottom = 400
        let visible = Rect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(v.revealing(visible), v)
        let hidden = Rect(x: 50, y: 600, width: 100, height: 100)
        let r = v.revealing(hidden, padding: 16).toScreen(hidden)
        XCTAssertEqual(Double(r.maxY), 400 - 16, accuracy: 1e-9)
        XCTAssertEqual(Double(r.minX), 50, accuracy: 1e-9)
    }

    func testResizedKeepsCenter() {
        let v = Viewport(scale: 2, origin: CGPoint(x: 10, y: 10), size: CGSize(width: 200, height: 200), fitScale: 2)
        let c = v.toModel(CGPoint(x: 100, y: 100))
        let r = v.resized(to: CGSize(width: 300, height: 100))
        XCTAssertTrue(r.toModel(CGPoint(x: 150, y: 50)).isApproximatelyEqual(to: c, tolerance: 1e-9))
    }
}

final class GestureTests: XCTestCase {
    let start = Viewport(scale: 1, origin: .zero, size: CGSize(width: 400, height: 400), fitScale: 1)

    func testPanIsRelativeToGestureStart() {
        var g = GestureController()
        var v = g.pan(translation: CGSize(width: 10, height: 0), current: start)
        v = g.pan(translation: CGSize(width: 30, height: 5), current: v)
        XCTAssertEqual(Double(v.origin.x), 30); XCTAssertEqual(Double(v.origin.y), 5)
        XCTAssertNil(g.endPan(velocity: .zero))
        XCTAssertFalse(g.isActive)
    }

    func testSimultaneousPinchAndPanFoldCorrectly() {
        var g = GestureController()
        var v = g.pinch(magnification: 2, anchor: CGPoint(x: 200, y: 200), current: start)
        v = g.pan(translation: CGSize(width: 20, height: 0), current: v)
        let combined = v
        g.endPinch()
        // After the pinch ends, the pan continues from the zoomed state without a jump.
        let after = g.pan(translation: CGSize(width: 20, height: 0), current: combined)
        XCTAssertEqual(after.scale, combined.scale, accuracy: 1e-9)
        XCTAssertEqual(Double(after.origin.x), Double(combined.origin.x), accuracy: 1e-9)
        // And the reverse: pan ends first, pinch continues.
        var g2 = GestureController()
        var w = g2.pan(translation: CGSize(width: 40, height: 10), current: start)
        w = g2.pinch(magnification: 1.5, anchor: CGPoint(x: 100, y: 100), current: w)
        let both = w
        _ = g2.endPan(velocity: .zero)
        let cont = g2.pinch(magnification: 1.5, anchor: CGPoint(x: 100, y: 100), current: both)
        XCTAssertEqual(Double(cont.origin.x), Double(both.origin.x), accuracy: 1e-9)
        XCTAssertEqual(Double(cont.origin.y), Double(both.origin.y), accuracy: 1e-9)
    }

    func testMomentumDecay() {
        let m = Momentum(velocity: CGSize(width: 1000, height: 0))
        XCTAssertTrue(m.isSignificant)
        XCTAssertEqual(Double(m.displacement(at: 0).width), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(m.displacement(at: 100).width), 325, accuracy: 1e-6)   // v·τ
        XCTAssertLessThan(Double(m.displacement(at: 0.325).width), 325)
        XCTAssertTrue(m.isFinished(at: 3))
        XCTAssertFalse(m.isFinished(at: 0.1))
        XCTAssertFalse(Momentum(velocity: CGSize(width: 50, height: 0)).isSignificant)
        var g = GestureController()
        _ = g.pan(translation: CGSize(width: 5, height: 0), current: start)
        XCTAssertNotNil(g.endPan(velocity: CGSize(width: 800, height: 0)))
    }
}
