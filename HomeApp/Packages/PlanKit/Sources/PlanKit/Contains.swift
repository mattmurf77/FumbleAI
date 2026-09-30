import Foundation

/// Point-in-polygon, edge distance and hit-testing. LLD §6.3, §6.6.
public enum Contains {
    /// Winding-number test with a bbox pre-check. Points within `tolerance` of an edge count as inside.
    public static func contains(_ polygon: Polygon, _ p: Vec2, tolerance: Double = 0.01) -> Bool {
        contains(vertices: polygon.vertices, p, tolerance: tolerance)
    }

    public static func contains(vertices v: [Vec2], _ p: Vec2, tolerance: Double = 0.01) -> Bool {
        guard v.count >= 3 else { return false }
        let bb = Rect(points: v).expanded(by: tolerance)
        guard bb.contains(p) else { return false }
        let n = v.count
        var wn = 0
        for i in 0..<n {
            let a = v[i], b = v[(i + 1) % n]
            if Segment(a: a, b: b).distance(to: p) <= tolerance { return true }
            if a.y <= p.y {
                if b.y > p.y, Geometry.orient(a, b, p) > 0 { wn += 1 }
            } else {
                if b.y <= p.y, Geometry.orient(a, b, p) < 0 { wn -= 1 }
            }
        }
        return wn != 0
    }

    /// Minimum distance from `p` to any edge.
    public static func distanceToEdges(of polygon: Polygon, _ p: Vec2) -> Double {
        polygon.edges.reduce(Double.infinity) { min($0, $1.distance(to: p)) }
    }

    /// Signed distance: positive inside, negative outside (used by PolyLabel).
    public static func signedDistance(_ polygon: Polygon, _ p: Vec2) -> Double {
        let d = distanceToEdges(of: polygon, p)
        return contains(polygon, p, tolerance: 0) ? d : -d
    }
}

/// A polygon with an identity, used by PlanKit algorithms that must not depend on HomeCore models.
public struct IdentifiedPolygon: Hashable, Sendable {
    public var id: UUID
    public var polygon: Polygon
    public init(id: UUID, polygon: Polygon) { self.id = id; self.polygon = polygon }
}

/// Space hit-testing in model space (LLD §6.6 steps 2–4). The caller converts screen → model and
/// passes `hitRadius = 22pt / scale` (inches).
public enum HitTester {
    public static func hit(_ m: Vec2, in candidates: [IdentifiedPolygon], hitRadius: Double) -> UUID? {
        let near = candidates.filter { $0.polygon.bounds.expanded(by: hitRadius).contains(m) }
        // Containment first: smallest area wins (garden bed beats backyard).
        let containing = near.filter { $0.polygon.contains(m) }
        if let best = containing.min(by: { $0.polygon.area < $1.polygon.area }) { return best.id }
        // Minimum hit radius: nearest edge within the radius.
        var bestId: UUID?
        var bestD = Double.infinity
        for c in near {
            let d = c.polygon.distanceToEdge(m)
            if d <= hitRadius, d < bestD { bestD = d; bestId = c.id }
        }
        return bestId
    }

    /// Editor hit-test: index of the vertex within `radius` of `m`, if any (nearest wins).
    public static func vertexIndex(_ m: Vec2, in polygon: Polygon, radius: Double) -> Int? {
        var best: (Int, Double)?
        for (i, v) in polygon.vertices.enumerated() {
            let d = v.distance(to: m)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Editor hit-test: index of the edge (from vertex i to i+1) within `radius` of `m`, if any.
    public static func edgeIndex(_ m: Vec2, in polygon: Polygon, radius: Double) -> Int? {
        var best: (Int, Double)?
        for (i, e) in polygon.edges.enumerated() {
            let d = e.distance(to: m)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }
}
