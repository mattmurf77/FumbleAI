import Foundation

/// A derived wall run. Walls are never stored; they are derived per level from the interior
/// spaces' shared polygon edges with a tolerance merge. LLD §6.4.
public struct WallSegment: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case perimeter, interior }
    public var seg: Segment
    public var kind: Kind
    /// Perimeter 6.0 in, interior 4.5 in.
    public var thicknessIn: Double
    /// Openings cutting this wall, as **fractions 0…1 along `seg`** (a → b). Draw the glyph in each gap.
    public var gaps: [ClosedRange<Double>]
    /// 1 owner (perimeter) or 2+ (interior). Sorted for determinism.
    public var spaceIds: [UUID]

    public init(seg: Segment, kind: Kind, thicknessIn: Double, gaps: [ClosedRange<Double>] = [], spaceIds: [UUID]) {
        self.seg = seg; self.kind = kind; self.thicknessIn = thicknessIn; self.gaps = gaps; self.spaceIds = spaceIds
    }

    public static let perimeterThickness: Double = 6.0
    public static let interiorThickness: Double = 4.5
}

public enum WallDerivation {
    /// Minimum elementary span length that produces a wall, inches.
    public static let minSpan: Double = 0.5

    /// Derives walls for the **interior** spaces of one level (callers pass only `is_exterior == 0`).
    /// - Parameters:
    ///   - spaces: interior space polygons with their ids.
    ///   - openings: door/window/opening segments on the level (display-only).
    ///   - tolerance: coincident-edge distance (default `Tolerance.wallMerge`, 3 in).
    public static func walls(spaces: [IdentifiedPolygon], openings: [Segment] = [],
                             tolerance: Double = Tolerance.wallMerge,
                             angleToleranceDeg: Double = Tolerance.angleDeg) -> [WallSegment] {
        let angTol = Geometry.radians(angleToleranceDeg)

        // 1–2. Collect edges and canonicalize direction into θ ∈ [−tol, π − tol).
        struct Edge { var a: Vec2; var b: Vec2; var theta: Double; var length: Double; var owner: UUID }
        var edges: [Edge] = []
        for s in spaces {
            for e in s.polygon.edges where e.length > 1e-6 {
                var a = e.a, b = e.b
                var th = atan2(b.y - a.y, b.x - a.x)
                if th < 0 { th += .pi; swap(&a, &b) }
                if th >= .pi { th -= .pi; swap(&a, &b) }
                if th >= .pi - angTol { th -= .pi; swap(&a, &b) }
                edges.append(Edge(a: a, b: b, theta: th, length: e.length, owner: s.id))
            }
        }
        guard !edges.isEmpty else { return [] }

        // 3a. Group by angle (chain while consecutive Δθ ≤ tol).
        edges.sort { $0.theta < $1.theta }
        var angleGroups: [[Edge]] = []
        for e in edges {
            if let lastTheta = angleGroups.last?.last?.theta, e.theta - lastTheta <= angTol {
                angleGroups[angleGroups.count - 1].append(e)
            } else {
                angleGroups.append([e])
            }
        }

        struct Cluster { var theta: Double; var d: Double; var u: Vec2; var n: Vec2; var edges: [Edge] }
        var clusters: [Cluster] = []
        for group in angleGroups {
            let wsum = group.reduce(0) { $0 + $1.length }
            let th = group.reduce(0) { $0 + $1.theta * $1.length } / wsum
            let u = Vec2(x: cos(th), y: sin(th)), n = Vec2(x: -sin(th), y: cos(th))
            // 3b. Cluster by offset d = n·midpoint.
            let withD = group.map { e -> (Edge, Double) in (e, n.dot(e.a.lerp(to: e.b, 0.5))) }.sorted { $0.1 < $1.1 }
            var current: [(Edge, Double)] = []
            func flush() {
                guard !current.isEmpty else { return }
                let w = current.reduce(0) { $0 + $1.0.length }
                let d = current.reduce(0) { $0 + $1.1 * $1.0.length } / w
                clusters.append(Cluster(theta: th, d: d, u: u, n: n, edges: current.map(\.0)))
                current = []
            }
            for item in withD {
                if let last = current.last, item.1 - last.1 > tolerance { flush() }
                current.append(item)
            }
            flush()
        }

        var result: [WallSegment] = []
        for c in clusters {
            // 4. Project to intervals along u.
            let intervals: [(t0: Double, t1: Double, owner: UUID)] = c.edges.map {
                let t0 = c.u.dot($0.a), t1 = c.u.dot($0.b)
                return (min(t0, t1), max(t0, t1), $0.owner)
            }
            // 5. Sweep elementary spans.
            let ts = Array(Set(intervals.flatMap { [$0.t0, $0.t1] })).sorted()
            struct Span { var t0: Double; var t1: Double; var owners: Set<UUID> }
            var spans: [Span] = []
            let eps = 1e-6
            for k in 0..<(ts.count - 1) {
                let a = ts[k], b = ts[k + 1]
                guard b - a > minSpan else { continue }
                let owners = Set(intervals.filter { $0.t0 <= a + eps && $0.t1 >= b - eps }.map(\.owner))
                guard !owners.isEmpty else { continue }
                spans.append(Span(t0: a, t1: b, owners: owners))
            }
            // 6. Merge contiguous spans of the same kind (interior: same owner set).
            var merged: [Span] = []
            for s in spans {
                if var last = merged.last, abs(last.t1 - s.t0) < eps {
                    let lastInterior = last.owners.count >= 2, sInterior = s.owners.count >= 2
                    if lastInterior == sInterior && (!sInterior || last.owners == s.owners) {
                        last.t1 = s.t1
                        last.owners.formUnion(s.owners)
                        merged[merged.count - 1] = last
                        continue
                    }
                }
                merged.append(s)
            }
            // Map back to model space and cut openings (7).
            let base = c.n * c.d
            let clusterOpenings: [(Double, Double)] = openings.compactMap { o in
                guard o.length > 1e-6 else { return nil }
                let v = o.vector
                let cross = abs(v.normalized.cross(c.u))
                guard cross <= sin(angTol) else { return nil }
                guard abs(c.n.dot(o.midpoint) - c.d) <= tolerance else { return nil }
                let t0 = c.u.dot(o.a), t1 = c.u.dot(o.b)
                return (min(t0, t1), max(t0, t1))
            }
            for s in merged {
                let seg = Segment(a: base + c.u * s.t0, b: base + c.u * s.t1)
                let interior = s.owners.count >= 2
                let len = s.t1 - s.t0
                var gaps: [ClosedRange<Double>] = []
                for (o0, o1) in clusterOpenings {
                    let lo = max(o0, s.t0), hi = min(o1, s.t1)
                    if hi - lo > 1e-6 { gaps.append(((lo - s.t0) / len)...((hi - s.t0) / len)) }
                }
                gaps.sort { $0.lowerBound < $1.lowerBound }
                result.append(WallSegment(
                    seg: seg,
                    kind: interior ? .interior : .perimeter,
                    thicknessIn: interior ? WallSegment.interiorThickness : WallSegment.perimeterThickness,
                    gaps: gaps,
                    spaceIds: s.owners.sorted { $0.uuidString < $1.uuidString }))
            }
        }
        return result
    }

    /// Spaces that share a (tolerance-merged) edge with `edge` of space `spaceId` — used by edge-drag so
    /// shared walls move together (§6.8). Returns (spaceId, edgeIndex) pairs of coincident, overlapping edges.
    public static func coincidentEdges(of edge: Segment, excluding spaceId: UUID, in spaces: [IdentifiedPolygon],
                                       tolerance: Double = Tolerance.wallMerge) -> [(spaceId: UUID, edgeIndex: Int)] {
        let u = edge.direction
        guard u != .zero else { return [] }
        let n = u.perpendicular
        let d = n.dot(edge.a)
        let t0 = u.dot(edge.a), t1 = u.dot(edge.b)
        let lo = min(t0, t1), hi = max(t0, t1)
        var out: [(UUID, Int)] = []
        for s in spaces where s.id != spaceId {
            for (i, e) in s.polygon.edges.enumerated() {
                guard e.length > 1e-6, abs(e.direction.cross(u)) <= sin(Geometry.radians(Tolerance.angleDeg)) else { continue }
                guard abs(n.dot(e.midpoint) - d) <= tolerance else { continue }
                let e0 = u.dot(e.a), e1 = u.dot(e.b)
                let olo = max(lo, min(e0, e1)), ohi = min(hi, max(e0, e1))
                if ohi - olo > minSpan { out.append((s.id, i)) }
            }
        }
        return out
    }
}
