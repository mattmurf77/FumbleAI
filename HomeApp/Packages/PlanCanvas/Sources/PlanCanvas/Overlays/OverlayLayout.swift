import Foundation
import PlanKit
import HomeCore

/// Where each label/overlay goes for the current viewport (pure; the SwiftUI layer just positions views).
/// LLD §6.7 (LOD) and §7.3 (overlays).
public struct OverlayLayout: Hashable, Sendable {
    public struct Label: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var nameAt: CGPoint
        /// Caption2 (name-only LOD) vs the regular label size.
        public var isSmall: Bool
        public var secondLine: String?
        public var secondLineAt: CGPoint?
        public var secondLineIsAccent: Bool
        public var budgetLines: [String]
        public var budgetLinesAt: CGPoint?
        public var isQuiet: Bool
    }
    public struct AddButton: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var center: CGPoint
        public var isQuiet: Bool
    }
    public struct ChipPlacement: Hashable, Sendable, Identifiable {
        public var id: String
        public var spaceId: UUID
        public var chip: Chip
        public var center: CGPoint
        /// Corner chips anchor at their trailing edge.
        public var isCorner: Bool
    }
    public struct PinPlacement: Hashable, Sendable, Identifiable {
        public var id: String
        public var center: CGPoint
        public var pins: [PinModel]
        public var isCluster: Bool { pins.count > 1 }
        /// Items represented (clusters sum spot counts; things count 1 each).
        public var count: Int { pins.reduce(0) { $0 + ($1.kind == .spot ? $1.count : 1) } }
    }

    public var labels: [Label] = []
    public var addButtons: [AddButton] = []
    public var chips: [ChipPlacement] = []
    public var pins: [PinPlacement] = []

    public init() {}

    /// Chips and pins fade while pinching when more than 40 overlays are visible (the "+" buttons stay).
    public static let fadeThreshold = 40
    public var fadesDuringPinch: Bool { addButtons.count + chips.count + pins.count > OverlayLayout.fadeThreshold }

    public static let pinClusterDistance: Double = 20

    public static func compute(model: LevelRenderModel, viewport v: Viewport, isEditing: Bool = false) -> OverlayLayout {
        var out = OverlayLayout()
        guard v.scale > 0 else { return out }
        let visible = v.visibleModelRect.insetBy(-24 / v.scale)
        for s in model.spaces where s.bbox.intersects(visible) {
            let d = model.lens.decoration(s.id)
            let rPt = s.poleRadius * v.scale
            let hasChip = d.chip != nil
            let showBudgetLines = !d.budgetLines.isEmpty
            let layout = LabelLayout.layout(radiusPoints: rPt, hasChip: hasChip, hasBudgetLines: showBudgetLines,
                                            allowsAdd: s.allowsAdd && !isEditing)
            let pole = v.toScreen(s.pole)
            if layout.lod >= .nameOnly {
                let narrowOnScreen = min(s.bbox.width, s.bbox.height) * v.scale < 60
                var label = Label(id: s.id, name: (layout.lod == .nameOnly || narrowOnScreen) ? s.shortName : s.name,
                                  nameAt: LabelLayout.point(pole, dy: layout.nameOffsetY), isSmall: layout.lod == .nameOnly,
                                  secondLine: nil, secondLineAt: nil, secondLineIsAccent: false, budgetLines: [],
                                  budgetLinesAt: nil, isQuiet: d.isQuiet && model.lens.lens != .plan)
                if let dy = layout.secondLineOffsetY {
                    label.secondLine = d.secondLine ?? s.dimsText
                    label.secondLineIsAccent = d.secondLine != nil && d.secondLineIsAccent
                    label.secondLineAt = LabelLayout.point(pole, dy: dy)
                }
                if showBudgetLines, layout.lod == .full, let dy = layout.budgetLinesOffsetY {
                    label.budgetLines = d.budgetLines
                    label.budgetLinesAt = LabelLayout.point(pole, dy: dy)
                }
                out.labels.append(label)
            }
            if !isEditing, let dy = layout.addOffsetY, layout.lod.showsAddButton {
                out.addButtons.append(AddButton(id: s.id, center: LabelLayout.point(pole, dy: dy), isQuiet: d.isQuiet && model.lens.lens != .plan))
            }
            if !isEditing, let chip = d.chip, let dy = layout.chipOffsetY, layout.lod.showsChip, !(showBudgetLines && layout.lod == .full) {
                out.chips.append(ChipPlacement(id: "c:\(s.id)", spaceId: s.id, chip: chip, center: LabelLayout.point(pole, dy: dy), isCorner: false))
            }
            if !isEditing, let chip = d.cornerChip, layout.lod >= .nameOnly {
                let r = v.toScreen(s.bbox)
                out.chips.append(ChipPlacement(id: "k:\(s.id)", spaceId: s.id, chip: chip,
                                               center: CGPoint(x: Double(r.maxX) - 8, y: Double(r.minY) + 14), isCorner: true))
            }
        }
        if !isEditing {
            let placed = model.lens.pins.compactMap { p -> (PinModel, CGPoint)? in
                let base = v.toScreen(p.anchor)
                let c = CGPoint(x: Double(base.x) + p.offsetX, y: Double(base.y) + p.offsetY)
                guard c.x >= -20, c.y >= -20, Double(c.x) <= Double(v.size.width) + 20, Double(c.y) <= Double(v.size.height) + 20 else { return nil }
                return (p, c)
            }
            out.pins = cluster(placed, distance: pinClusterDistance)
        }
        return out
    }

    /// Greedy clustering: pins closer than `distance` points join the first cluster they touch.
    public static func cluster(_ placed: [(PinModel, CGPoint)], distance: Double) -> [PinPlacement] {
        var clusters: [PinPlacement] = []
        let d2 = distance * distance
        for (pin, c) in placed.sorted(by: { ($0.1.y, $0.1.x) < ($1.1.y, $1.1.x) }) {
            if let i = clusters.firstIndex(where: {
                let dx = Double($0.center.x - c.x), dy = Double($0.center.y - c.y)
                return dx * dx + dy * dy < d2
            }) {
                let n = Double(clusters[i].pins.count)
                let cc = clusters[i].center
                clusters[i].center = CGPoint(x: (Double(cc.x) * n + Double(c.x)) / (n + 1), y: (Double(cc.y) * n + Double(c.y)) / (n + 1))
                clusters[i].pins.append(pin)
                clusters[i].id += "+" + pin.id
            } else {
                clusters.append(PinPlacement(id: pin.id, center: c, pins: [pin]))
            }
        }
        return clusters
    }
}

/// Browse-mode hit testing (LLD §6.6): containment first (smallest area wins), then a 22 pt minimum radius.
public enum CanvasHitTesting {
    public static let hitRadiusPoints: Double = 22

    public static func space(at p: CGPoint, model: LevelRenderModel, viewport v: Viewport) -> UUID? {
        guard v.scale > 0 else { return nil }
        let m = v.toModel(p)
        let r = hitRadiusPoints / v.scale
        let candidates = model.spaces.filter { $0.bbox.expanded(by: r).contains(m) }
            .map { IdentifiedPolygon(id: $0.id, polygon: $0.polygon) }
        return HitTester.hit(m, in: candidates, hitRadius: r)
    }
}
