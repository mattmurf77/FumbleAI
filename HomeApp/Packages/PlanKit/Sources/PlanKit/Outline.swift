import Foundation

extension Clip {

    // MARK: Outer boundary of a floor

    /// The true outer boundary of a set of non-overlapping polygons that share walls (the rooms of one floor).
    ///
    /// Every ring is subdivided at the other rings' vertices (T-junctions), shared edges cancel against their
    /// opposite-direction twins, and the remaining directed edges are chained into rings. The ring with the largest
    /// positive area is the outer boundary; holes (a courtyard, an unassigned gap in the middle) are dropped.
    ///
    /// Returns nil when there is nothing to outline, when the boundary cannot be traced as one simple ring (pinch
    /// points), or when the rooms form several disconnected pieces (the largest ring covers < 98 % of their area).
    /// Callers that always need a shape use `outerBoundary(_:)`, which falls back to the convex hull.
    public static func outline(_ polygons: [Polygon], tolerance: Double = 0.05,
                               minArea: Double = Tolerance.minZoneArea) -> Polygon? {
        let rings: [[Vec2]] = polygons.compactMap { p in
            guard p.count >= 3, p.vertices.allSatisfy(\.isFinite) else { return nil }
            let a = Area.signedArea(p.vertices)
            guard abs(a) > 1e-9 else { return nil }
            return a > 0 ? p.vertices : Array(p.vertices.reversed())
        }
        guard !rings.isEmpty else { return nil }
        if rings.count == 1 { return try? Polygon(rings[0], minArea: minArea) }
        let totalArea = rings.reduce(0) { $0 + abs(Area.signedArea($1)) }

        let allVertices = rings.flatMap { $0 }
        struct Key: Hashable { var x: Int64; var y: Int64 }
        let quantum = max(tolerance, 1e-4)
        func key(_ v: Vec2) -> Key { Key(x: Int64((v.x / quantum).rounded()), y: Int64((v.y / quantum).rounded())) }

        var coords: [Key: Vec2] = [:]
        var counts: [[Key]: Int] = [:]
        var order: [[Key]] = []
        for ring in rings {
            let sub = subdivide(ring, at: allVertices, tolerance: tolerance)
            for i in sub.indices {
                let pa = sub[i], pb = sub[(i + 1) % sub.count]
                let a = key(pa), b = key(pb)
                if a == b { continue }
                coords[a] = coords[a] ?? pa
                coords[b] = coords[b] ?? pb
                if counts[[a, b]] == nil { order.append([a, b]) }
                counts[[a, b], default: 0] += 1
            }
        }
        // Cancel shared walls: an edge survives as many times as it outnumbers its reverse.
        var outgoing: [Key: [Key]] = [:]
        var remaining = 0
        for e in order {
            let n = (counts[e] ?? 0) - (counts[[e[1], e[0]]] ?? 0)
            guard n > 0 else { continue }
            for _ in 0..<n { outgoing[e[0], default: []].append(e[1]); remaining += 1 }
        }
        guard remaining >= 3 else { return nil }

        // Chain the directed edges into rings.
        var traced: [[Vec2]] = []
        var guardSteps = 0
        while let start = order.lazy.map({ $0[0] }).first(where: { !(outgoing[$0]?.isEmpty ?? true) }) {
            var ring: [Vec2] = []
            var cur = start
            repeat {
                guard let c = coords[cur], var outs = outgoing[cur], !outs.isEmpty else { return nil }
                ring.append(c)
                let nxt = outs.removeFirst()
                outgoing[cur] = outs
                cur = nxt
                guardSteps += 1
                if guardSteps > remaining + 1 { return nil }
            } while cur != start
            traced.append(ring)
        }
        guard let best = traced.max(by: { Area.signedArea($0) < Area.signedArea($1) }),
              Area.signedArea(best) > 0 else { return nil }
        // Disconnected pieces: the largest ring would miss part of the floor.
        guard Area.signedArea(best) >= totalArea * 0.98 else { return nil }
        return try? Polygon(best, minArea: minArea)
    }

    /// `outline(_:)` when it can be traced, else the convex hull of every vertex (nil only for no input).
    public static func outerBoundary(_ polygons: [Polygon], minArea: Double = Tolerance.minZoneArea) -> Polygon? {
        if let o = outline(polygons, minArea: minArea) { return o }
        let hull = convexHull(polygons.flatMap(\.vertices))
        return try? Polygon(hull, minArea: minArea)
    }
}
