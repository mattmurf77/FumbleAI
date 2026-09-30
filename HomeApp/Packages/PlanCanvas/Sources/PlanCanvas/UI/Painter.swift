#if canImport(SwiftUI)
import SwiftUI
import PlanKit
import HomeCore

/// Draws one frame of the plan into a `GraphicsContext` (LLD §7.2 per-frame closure). All geometry is mapped to
/// screen space here so stroke widths and text sizes stay constant in points (listing-plan look).
///
/// Layers, bottom to top (`seven-views.md` §0): paper, room fills, lens tint, selection, lens edge, walls,
/// doors/windows, labels, editor grid/handles/guides.
public struct Painter {
    public var theme: PlanTheme
    public init(theme: PlanTheme) { self.theme = theme }

    // Wall widths in screen points. Perimeter follows the LLD clamp; interior walls are drawn thin like the
    // mockup's listing plan (1.3 pt at the default zoom) instead of the LLD 4.5 in so rooms read as one plan.
    public static func perimeterWidth(scale: Double) -> Double { min(max(6 * scale, 2.0), 9.0) }
    public static func interiorWidth(scale: Double) -> Double { min(max(1.7 * scale, 1.1), 4.0) }

    public func draw(_ ctx: inout GraphicsContext, size: CGSize, model: LevelRenderModel, viewport v: Viewport,
                     labels: [OverlayLayout.Label], selection: UUID?, editor: EditorOverlayState?) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.paper))
        guard v.scale > 0 else { return }
        let visible = v.visibleModelRect.insetBy(-24 / v.scale)
        let spaces = model.spaces.filter { $0.bbox.intersects(visible) }
        let perim = Painter.perimeterWidth(scale: v.scale)

        // 2–3. Fills and lens tint.
        for s in spaces {
            let p = path(s.polygon, v)
            ctx.fill(p, with: .color(theme.fill(s.fillStyle)))
            if let tint = theme.tint(model.lens.decoration(s.id).tint) { ctx.fill(p, with: .color(tint)) }
            if s.id == selection { ctx.fill(p, with: .color(theme.accentSoft)) }
        }

        // Stair treads (thin lines over the fill, under lens edges and walls).
        for s in spaces where !s.treads.isEmpty {
            var treads = Path()
            for t in s.treads {
                treads.move(to: v.toScreen(t.a))
                treads.addLine(to: v.toScreen(t.b))
            }
            ctx.stroke(treads, with: .color(theme.wall.opacity(0.45)), lineWidth: 0.8)
        }

        // Editor grid (1 ft) sits on the fills, under the walls.
        if let e = editor { drawGrid(&ctx, v, size: size, stepIn: e.gridIn) }

        // 4. Lens edges (inner stroke, inset) and selection stroke — clipped to each room so they stay inside.
        for s in spaces {
            let d = model.lens.decoration(s.id)
            let isSelected = s.id == selection
            guard d.edge != nil || isSelected else { continue }
            let p = path(s.polygon, v)
            let half = (s.isExterior ? 0 : perim / 2)
            ctx.drawLayer { layer in
                layer.clip(to: p)
                if let edge = d.edge {
                    layer.stroke(p, with: .color(theme.edge(edge.role)), lineWidth: 2 * (half + edge.insetPt + edge.widthPt))
                    let gapColor = theme.fill(s.fillStyle)
                    layer.stroke(p, with: .color(gapColor), lineWidth: 2 * (half + edge.insetPt))
                    if let tint = theme.tint(d.tint) { layer.stroke(p, with: .color(tint), lineWidth: 2 * (half + edge.insetPt)) }
                }
                if isSelected {
                    layer.stroke(p, with: .color(theme.accent), lineWidth: 2 * (half + 2))
                }
            }
        }

        // 5. Walls (interior levels) or zone outlines (exterior).
        if model.isExterior {
            for s in spaces {
                ctx.stroke(path(s.polygon, v), with: .color(theme.wall.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: s.spaceType == .footprint ? [] : [4, 3]))
            }
            for s in spaces where s.spaceType == .footprint {
                ctx.stroke(path(s.polygon, v), with: .color(theme.wall), lineWidth: 2)
            }
        } else {
            let approxIds = Set(model.spaces.filter(\.isApproximate).map(\.id))
            for w in model.walls where segmentBounds(w.seg).intersects(visible) {
                let width = w.kind == .perimeter ? perim : Painter.interiorWidth(scale: v.scale)
                let dashed = !approxIds.isEmpty && w.spaceIds.allSatisfy { approxIds.contains($0) }
                drawWall(&ctx, w, v, width: width, dashed: dashed)
            }
        }

        // 6. Doors and windows.
        for o in model.openings where segmentBounds(o.segment).intersects(visible) {
            drawOpening(&ctx, o, v, perimeterWidth: perim)
        }

        // Editor: invalid (overlapping) rooms.
        if let e = editor {
            for s in spaces where e.invalidSpaceIds.contains(s.id) {
                ctx.stroke(path(s.polygon, v), with: .color(theme.danger), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }

        // 7. Labels.
        drawLabels(&ctx, labels)

        // 8. Editor guides and handles.
        if let e = editor { drawEditor(&ctx, e, v) }
    }

    // MARK: Pieces

    // `PlanKit.` qualified: on macOS, SwiftUI pulls in Quickdraw whose C typedefs `Polygon`/`Rect` clash.
    func path(_ poly: PlanKit.Polygon, _ v: Viewport) -> Path {
        var p = Path()
        let pts = poly.vertices.map { v.toScreen($0) }
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        p.closeSubpath()
        return p
    }

    func segmentBounds(_ s: Segment) -> PlanKit.Rect { PlanKit.Rect(points: [s.a, s.b]).expanded(by: 12) }

    /// A wall as filled quads between opening gaps; the outer ends extend by half the width so corners join.
    func drawWall(_ ctx: inout GraphicsContext, _ w: WallSegment, _ v: Viewport, width: Double, dashed: Bool) {
        let a = v.toScreen(w.seg.a), b = v.toScreen(w.seg.b)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.01 else { return }
        let ux = dx / len, uy = dy / len
        // Pieces between gaps in t ∈ [0, 1].
        var pieces: [(Double, Double)] = []
        var t = 0.0
        for g in w.gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if g.lowerBound > t { pieces.append((t, g.lowerBound)) }
            t = max(t, g.upperBound)
        }
        if t < 1 { pieces.append((t, 1)) }
        let color = theme.wall
        for (t0, t1) in pieces {
            let ext0 = t0 <= 1e-9 ? width / 2 : 0, ext1 = t1 >= 1 - 1e-9 ? width / 2 : 0
            let p0 = CGPoint(x: Double(a.x) + ux * (t0 * len - ext0), y: Double(a.y) + uy * (t0 * len - ext0))
            let p1 = CGPoint(x: Double(a.x) + ux * (t1 * len + ext1), y: Double(a.y) + uy * (t1 * len + ext1))
            if dashed {
                var line = Path(); line.move(to: p0); line.addLine(to: p1)
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: max(1.2, width * 0.6), lineCap: .butt, dash: [6, 4]))
            } else {
                let nx = -uy * width / 2, ny = ux * width / 2
                var q = Path()
                q.move(to: CGPoint(x: Double(p0.x) + nx, y: Double(p0.y) + ny))
                q.addLine(to: CGPoint(x: Double(p1.x) + nx, y: Double(p1.y) + ny))
                q.addLine(to: CGPoint(x: Double(p1.x) - nx, y: Double(p1.y) - ny))
                q.addLine(to: CGPoint(x: Double(p0.x) - nx, y: Double(p0.y) - ny))
                q.closeSubpath()
                ctx.fill(q, with: .color(color))
            }
        }
    }

    func drawOpening(_ ctx: inout GraphicsContext, _ o: OpeningGlyph, _ v: Viewport, perimeterWidth: Double) {
        let a = v.toScreen(o.segment.a), b = v.toScreen(o.segment.b)
        switch o.kind {
        case .door where !o.isSliding:
            let hinge = v.toScreen(o.hinge), leaf = v.toScreen(o.leafEnd)
            var leafPath = Path(); leafPath.move(to: hinge); leafPath.addLine(to: leaf)
            ctx.stroke(leafPath, with: .color(theme.wall), lineWidth: 1)
            // Quarter arc from the open leaf back to the strike jamb (polyline; shortest rotation).
            let r = o.widthIn
            let a0 = atan2(o.swingDirection.y, o.swingDirection.x)
            let sv = o.strike - o.hinge
            var a1 = atan2(sv.y, sv.x)
            var delta = a1 - a0
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            a1 = a0 + delta
            var arc = Path()
            let steps = 14
            for i in 0...steps {
                let ang = a0 + (a1 - a0) * Double(i) / Double(steps)
                let p = v.toScreen(o.hinge + Vec2(cos(ang), sin(ang)) * r)
                if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
            }
            ctx.stroke(arc, with: .color(theme.wall.opacity(0.8)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
        case .door:
            // Sliding: two offset panels.
            let n = o.segment.direction.perpendicular * (1.5 / max(v.scale, 1e-6))
            for (s, k) in [(0.0, 0.55), (0.45, 1.0)] {
                let p0 = v.toScreen(o.segment.point(at: s) + n * (s == 0 ? 1 : -1))
                let p1 = v.toScreen(o.segment.point(at: k) + n * (s == 0 ? 1 : -1))
                var p = Path(); p.move(to: p0); p.addLine(to: p1)
                ctx.stroke(p, with: .color(theme.wall), lineWidth: 1.2)
            }
        case .window:
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let nx = -dy / len * perimeterWidth / 2, ny = dx / len * perimeterWidth / 2
            var box = Path()
            box.move(to: CGPoint(x: Double(a.x) + nx, y: Double(a.y) + ny))
            box.addLine(to: CGPoint(x: Double(b.x) + nx, y: Double(b.y) + ny))
            box.addLine(to: CGPoint(x: Double(b.x) - nx, y: Double(b.y) - ny))
            box.addLine(to: CGPoint(x: Double(a.x) - nx, y: Double(a.y) - ny))
            box.closeSubpath()
            ctx.fill(box, with: .color(theme.room))
            ctx.stroke(box, with: .color(theme.wall), lineWidth: 0.7)
            var mid = Path(); mid.move(to: a); mid.addLine(to: b)
            ctx.stroke(mid, with: .color(theme.wall), lineWidth: 0.7)
        default:
            break
        }
    }

    func drawLabels(_ ctx: inout GraphicsContext, _ labels: [OverlayLayout.Label]) {
        for l in labels {
            let nameFont = Font.system(size: l.isSmall ? 9.5 : 11, weight: .semibold).width(.condensed).smallCaps()
            let name = Text(l.name).font(nameFont).tracking(0.8).foregroundColor(l.isQuiet ? theme.ink3 : theme.ink)
            ctx.draw(name, at: l.nameAt, anchor: .center)
            if let s = l.secondLine, let at = l.secondLineAt {
                let t = Text(s).font(.system(size: 10, weight: l.secondLineIsAccent ? .semibold : .medium).width(.condensed).monospacedDigit())
                    .foregroundColor(l.secondLineIsAccent ? theme.accent : theme.dim)
                ctx.draw(t, at: at, anchor: .center)
            }
            if let at = l.budgetLinesAt {
                for (i, line) in l.budgetLines.enumerated() {
                    let t = Text(line).font(.system(size: 10.5, weight: i == 0 ? .semibold : .medium).monospacedDigit())
                        .foregroundColor(i == 0 ? theme.accent : theme.dim)
                    ctx.draw(t, at: CGPoint(x: at.x, y: at.y + CGFloat(i) * 13), anchor: .center)
                }
            }
        }
    }

    func drawGrid(_ ctx: inout GraphicsContext, _ v: Viewport, size: CGSize, stepIn: Double) {
        let stepPt = stepIn * v.scale
        guard stepPt >= 6 else { return }
        let r = v.visibleModelRect
        var p = Path()
        var x = (r.minX / stepIn).rounded(.down) * stepIn
        while x <= r.maxX {
            let sx = v.toScreen(Vec2(x, 0)).x
            p.move(to: CGPoint(x: sx, y: 0)); p.addLine(to: CGPoint(x: sx, y: size.height))
            x += stepIn
        }
        var y = (r.minY / stepIn).rounded(.down) * stepIn
        while y <= r.maxY {
            let sy = v.toScreen(Vec2(0, y)).y
            p.move(to: CGPoint(x: 0, y: sy)); p.addLine(to: CGPoint(x: size.width, y: sy))
            y += stepIn
        }
        ctx.stroke(p, with: .color(theme.grid.opacity(theme.isDark ? 1.6 : 1.8)), lineWidth: 0.5)
    }

    func drawEditor(_ ctx: inout GraphicsContext, _ e: EditorOverlayState, _ v: Viewport) {
        for g in e.guides {
            var p = Path(); p.move(to: v.toScreen(g.a)); p.addLine(to: v.toScreen(g.b))
            ctx.stroke(p, with: .color(theme.accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for m in e.edgeHandles {
            let c = v.toScreen(m)
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: r), with: .color(theme.room))
            ctx.stroke(Path(ellipseIn: r), with: .color(theme.accent), lineWidth: 1.5)
        }
        for h in e.handles {
            let c = v.toScreen(h)
            let r = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            ctx.fill(Path(r), with: .color(theme.room))
            ctx.stroke(Path(r), with: .color(theme.accent), lineWidth: 2)
        }
    }
}
#endif
