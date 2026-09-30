import Foundation

/// Editor snapping context. LLD §6.8.
public struct SnapContext: Hashable, Sendable {
    /// Other spaces' vertices on the level (excluding the one being dragged).
    public var vertices: [Vec2]
    /// Other spaces' edges.
    public var edges: [Segment]
    /// Grid step, inches: 6 by default, 1 while "Fine" is held.
    public var gridIn: Double
    /// Points per inch (for converting the 12 pt snap radius).
    public var scale: Double
    /// Known neighbour for the orthogonal constraint when dragging a vertex.
    public var axisOrigin: Vec2?
    /// Second neighbour (the vertex on the other side of the dragged one), optional.
    public var secondAxisOrigin: Vec2?
    public var orthogonal: Bool

    public init(vertices: [Vec2] = [], edges: [Segment] = [], gridIn: Double = 6, scale: Double,
                axisOrigin: Vec2? = nil, secondAxisOrigin: Vec2? = nil, orthogonal: Bool = true) {
        self.vertices = vertices; self.edges = edges; self.gridIn = gridIn; self.scale = scale
        self.axisOrigin = axisOrigin; self.secondAxisOrigin = secondAxisOrigin; self.orthogonal = orthogonal
    }

    public static let snapRadiusPoints: Double = 12
    /// Snap radius in inches: 12 pt / scale.
    public var radiusIn: Double { Self.snapRadiusPoints / max(scale, 1e-6) }
}

public struct SnapResult: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case vertex, edge, alignment, grid, none }
    public var point: Vec2
    public var kind: Kind
    /// Figma-style guide lines to draw (model space).
    public var guides: [Segment]
    public init(point: Vec2, kind: Kind, guides: [Segment] = []) { self.point = point; self.kind = kind; self.guides = guides }
}

/// Snapping in priority order: vertex → edge → alignment → grid, after an optional orthogonal constraint.
/// Fire a selection haptic whenever `kind` or the target changes (caller's responsibility).
public enum Snapper {
    public static func snap(candidate: Vec2, context ctx: SnapContext) -> SnapResult {
        let r = ctx.radiusIn
        var p = candidate

        // 5. Orthogonal constraint (solved first): keep the edge to `axisOrigin` axis-aligned.
        var lockedAxis: LockedAxis = .none
        if ctx.orthogonal, let o = ctx.axisOrigin {
            let d = p - o
            if abs(d.x) >= abs(d.y) { p.y = o.y; lockedAxis = .yFixed } else { p.x = o.x; lockedAxis = .xFixed }
            if let o2 = ctx.secondAxisOrigin {
                // Keep the second edge axis-aligned too: take the other coordinate from o2.
                switch lockedAxis {
                case .yFixed: p.x = o2.x; lockedAxis = .both
                case .xFixed: p.y = o2.y; lockedAxis = .both
                default: break
                }
            }
        }
        if lockedAxis == .both { return SnapResult(point: p, kind: .none) }

        // 1. Vertex.
        if let v = ctx.vertices.min(by: { $0.distanceSquared(to: p) < $1.distanceSquared(to: p) }),
           v.distance(to: p) <= r, lockedAxis.allows(from: p, to: v) {
            return SnapResult(point: v, kind: .vertex)
        }

        // 2. Edge (perpendicular projection, stays on the edge).
        var bestEdge: (Vec2, Segment, Double)?
        for e in ctx.edges {
            let q = constrainedProjection(p, onto: e, axis: lockedAxis)
            guard let q else { continue }
            let d = q.distance(to: p)
            if d <= r, d < (bestEdge?.2 ?? .infinity) { bestEdge = (q, e, d) }
        }
        if let (q, e, _) = bestEdge { return SnapResult(point: q, kind: .edge, guides: [e]) }

        // 3. Alignment, independently per axis (the free axis falls back to the grid).
        var aligned = p
        var matchX: Vec2?, matchY: Vec2?
        if lockedAxis != .xFixed,
           let vx = ctx.vertices.min(by: { abs($0.x - p.x) < abs($1.x - p.x) }), abs(vx.x - p.x) <= r {
            aligned.x = vx.x; matchX = vx
        }
        if lockedAxis != .yFixed,
           let vy = ctx.vertices.min(by: { abs($0.y - p.y) < abs($1.y - p.y) }), abs(vy.y - p.y) <= r {
            aligned.y = vy.y; matchY = vy
        }
        if matchX != nil || matchY != nil {
            if lockedAxis == .none {
                if matchX == nil { aligned.x = Geometry.snap(p.x, to: ctx.gridIn) }
                if matchY == nil { aligned.y = Geometry.snap(p.y, to: ctx.gridIn) }
            }
            let guides = [matchX, matchY].compactMap { $0.map { Segment(a: $0, b: aligned) } }
            return SnapResult(point: aligned, kind: .alignment, guides: guides)
        }

        // 4. Grid.
        var g = p
        if lockedAxis != .xFixed { g.x = Geometry.snap(p.x, to: ctx.gridIn) }
        if lockedAxis != .yFixed { g.y = Geometry.snap(p.y, to: ctx.gridIn) }
        return SnapResult(point: g, kind: ctx.gridIn > 0 ? .grid : .none)
    }

    private enum LockedAxis {
        case none, xFixed, yFixed, both
        func allows(from p: Vec2, to q: Vec2) -> Bool {
            switch self {
            case .none: return true
            case .xFixed: return abs(q.x - p.x) < 1e-6
            case .yFixed: return abs(q.y - p.y) < 1e-6
            case .both: return false
            }
        }
    }

    private static func constrainedProjection(_ p: Vec2, onto e: Segment, axis: LockedAxis) -> Vec2? {
        switch axis {
        case .none, .both:
            return e.closestPoint(to: p)
        case .xFixed:
            // Move along y only: intersect the vertical line x = p.x with the edge.
            let dx = e.b.x - e.a.x
            guard abs(dx) > 1e-9 else { return nil }
            let t = (p.x - e.a.x) / dx
            guard t >= 0, t <= 1 else { return nil }
            return e.point(at: t)
        case .yFixed:
            let dy = e.b.y - e.a.y
            guard abs(dy) > 1e-9 else { return nil }
            let t = (p.y - e.a.y) / dy
            guard t >= 0, t <= 1 else { return nil }
            return e.point(at: t)
        }
    }

    /// Edge drag (resize): snaps a normal offset δ to the grid, or to a neighbour edge offset within the radius.
    /// `neighborOffsets` are the signed offsets (along the dragged edge's normal) of parallel neighbour edges.
    public static func snapEdgeOffset(_ delta: Double, baseOffset: Double, neighborOffsets: [Double],
                                      gridIn: Double, scale: Double) -> Double {
        let r = SnapContext.snapRadiusPoints / max(scale, 1e-6)
        let target = baseOffset + delta
        if let n = neighborOffsets.min(by: { abs($0 - target) < abs($1 - target) }), abs(n - target) <= r {
            return n - baseOffset
        }
        return Geometry.snap(delta, to: gridIn)
    }
}
