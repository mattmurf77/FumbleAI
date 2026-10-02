import XCTest
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import PlanCanvas

final class OverlayTests: XCTestCase {
    func testLODThresholds() {
        XCTAssertEqual(LabelLOD.forRadius(points: 60), .full)
        XCTAssertEqual(LabelLOD.forRadius(points: 48), .full)
        XCTAssertEqual(LabelLOD.forRadius(points: 47.9), .medium)
        XCTAssertEqual(LabelLOD.forRadius(points: 30), .medium)
        XCTAssertEqual(LabelLOD.forRadius(points: 29), .nameOnly)
        XCTAssertEqual(LabelLOD.forRadius(points: 17.9), .nameOnly)
        XCTAssertEqual(LabelLOD.forRadius(points: 11), .nameOnly)
        XCTAssertEqual(LabelLOD.forRadius(points: 10.9), .hidden)
        XCTAssertFalse(LabelLOD.nameOnly.showsAddButton)
        XCTAssertTrue(LabelLOD.medium.showsAddButton)
        let full = LabelLayout.layout(radiusPoints: 60, hasChip: true)
        XCTAssertLessThan(full.nameOffsetY, full.secondLineOffsetY!)
        XCTAssertLessThan(full.secondLineOffsetY!, full.addOffsetY!)
        XCTAssertLessThan(full.addOffsetY!, full.chipOffsetY!)
        XCTAssertNil(LabelLayout.layout(radiusPoints: 60, hasChip: true, allowsAdd: false).addOffsetY)
    }

    func testOverlayLayoutAtFitAndZoomedIn() {
        let m = Fixture.model(SampleHome.firstFloorId, lens: .todos)
        let v = Viewport.fit(m.bounds, in: CGSize(width: 393, height: 500))
        let o = OverlayLayout.compute(model: m, viewport: v)
        XCTAssertFalse(o.labels.isEmpty)
        XCTAssertTrue(o.labels.contains { $0.id == SampleHome.kitchenId })
        // The kitchen (14 ft square) at ~0.76 pt/in has r ≈ 64 pt → full LOD with "+" and chip.
        XCTAssertTrue(o.addButtons.contains { $0.id == SampleHome.kitchenId })
        XCTAssertTrue(o.chips.contains { $0.spaceId == SampleHome.kitchenId && $0.chip.text == "1 due" })
        // Hall (4 ft deep) is too thin for a "+".
        XCTAssertFalse(o.addButtons.contains { $0.id == SampleHome.hallId })
        // Edit mode hides "+" and chips.
        let e = OverlayLayout.compute(model: m, viewport: v, isEditing: true)
        XCTAssertTrue(e.addButtons.isEmpty); XCTAssertTrue(e.chips.isEmpty)
        // Zoomed far into one corner: rooms off screen are culled.
        var z = v; z.zoom(by: 6, anchor: .zero)
        let oz = OverlayLayout.compute(model: m, viewport: z)
        XCTAssertLessThan(oz.labels.count, o.labels.count)
    }

    func testQuietRoomsInLensButNotInPlan() {
        let v = Viewport.fit(Rect(x: 0, y: 0, width: 480, height: 360), in: CGSize(width: 393, height: 500))
        let t = OverlayLayout.compute(model: Fixture.model(SampleHome.firstFloorId, lens: .todos), viewport: v)
        XCTAssertEqual(t.labels.first { $0.id == SampleHome.livingId }?.isQuiet, true)
        let p = OverlayLayout.compute(model: Fixture.model(SampleHome.firstFloorId, lens: .plan), viewport: v)
        XCTAssertEqual(p.labels.first { $0.id == SampleHome.livingId }?.isQuiet, false)
        XCTAssertEqual(p.labels.first { $0.id == SampleHome.kitchenId }?.secondLine, "14′0″ × 14′0″")
    }

    func testPinClustering() {
        let id = UUID()
        func pin(_ n: Int) -> PinModel { PinModel(kind: .thing, itemId: UUID(), spaceId: id, symbol: "tv", anchor: .zero) }
        let placed: [(PinModel, CGPoint)] = [(pin(1), CGPoint(x: 0, y: 0)), (pin(2), CGPoint(x: 10, y: 0)), (pin(3), CGPoint(x: 100, y: 0))]
        let c = OverlayLayout.cluster(placed, distance: 20)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.first { $0.isCluster }?.count, 2)
        XCTAssertEqual(Double(c.first { $0.isCluster }!.center.x), 5, accuracy: 1e-9)
    }

    func testHitTestingSmallestContainingThenRadius() {
        let m = Fixture.model(SampleHome.outsideId, lens: .plan)
        let v = Viewport(scale: 1, origin: CGPoint(x: 200, y: 400), size: CGSize(width: 800, height: 900), fitScale: 1)
        // Garden bed (2..14 ft, −12..−6 ft) sits inside the backyard → garden bed wins.
        let p = v.toScreen(Vec2(8 * 12, -9 * 12))
        XCTAssertEqual(CanvasHitTesting.space(at: p, model: m, viewport: v), SampleHome.id(48))
        let f = Fixture.model(SampleHome.firstFloorId, lens: .plan)
        let fv = Viewport(scale: 0.5, origin: CGPoint(x: 50, y: 50), size: CGSize(width: 400, height: 400), fitScale: 0.5)
        // 10 pt outside the plan's left wall → nearest room within 22 pt.
        let near = CGPoint(x: 40, y: Double(fv.toScreen(Vec2(0, 60)).y))
        XCTAssertEqual(CanvasHitTesting.space(at: near, model: f, viewport: fv), SampleHome.livingId)
        XCTAssertNil(CanvasHitTesting.space(at: CGPoint(x: 0, y: 0), model: f, viewport: fv))
    }

    func testAccessibilityElementsHaveMinimumSizeAndValues() {
        let m = Fixture.model(SampleHome.firstFloorId, lens: .todos)
        let v = Viewport.fit(m.bounds, in: CGSize(width: 200, height: 200))
        let rooms = AccessibilityModel.rooms(model: m, viewport: v)
        XCTAssertEqual(rooms.count, 6)
        XCTAssertTrue(rooms.allSatisfy { $0.frame.width >= 44 && $0.frame.height >= 44 })
        let k = rooms.first { $0.id == SampleHome.kitchenId }!
        XCTAssertEqual(k.label, "Kitchen")
        XCTAssertTrue(k.value.hasPrefix("14 by 14 feet, 1 chore due this week"))
        XCTAssertEqual(AccessibilityModel.listRows(model: m).count, 6)
    }
}
