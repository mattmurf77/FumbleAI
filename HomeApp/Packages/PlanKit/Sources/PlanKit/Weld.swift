import Foundation

/// Import-time weld (RoomPlan, trace, editor commits). LLD §6.5.
public enum Weld {
    public struct Result: Sendable {
        /// Welded polygons, same order as the input.
        public var polygons: [Polygon]
        /// Indices whose welded version failed validation; their pre-weld polygon is returned instead
        /// and should be flagged on the review screen (`DraftWarning.weldFailed`).
        public var failedIndices: [Int]
    }

    /// Convenience returning only the polygons.
    public static func weld(polygons: [Polygon], tolerance: Double = Tolerance.weld,
                            minArea: Double = Tolerance.minRoomArea) -> [Polygon] {
        weldDetailed(polygons: polygons, tolerance: tolerance, minArea: minArea).polygons
    }

    public static func weldDetailed(polygons: [Polygon], tolerance: Double = Tolerance.weld,
                                    minArea: Double = Tolerance.minRoomArea,
                                    axisSnapDeg: Double = 1.5) -> Result {
        // Shared vertex store: rings reference point ids, so shared vertices move together.
        var points: [Vec2] = []
        var owner: [Int] = []
        var rings: [[Int]] = []
        for (pi, poly) in polygons.enumerated() {
            var ring: [Int] = []
            for v in poly.vertices { ring.append(points.count); points.append(v); owner.append(pi) }
            rings.append(ring)
        }

        // 1. Vertex clustering across different polygons (grid hash + union-find).
        var uf = UnionFind(points.count)
        struct Cell: Hashable { var x: Int; var y: Int }
        var grid: [Cell: [Int]] = [:]
        func cell(_ p: Vec2) -> Cell { Cell(x: Int((p.x / tolerance).rounded(.down)), y: Int((p.y / tolerance).rounded(.down))) }
        for (i, p) in points.enumerated() { grid[cell(p), default: []].append(i) }
        for (i, p) in points.enumerated() {
            let c = cell(p)
            for dx in -1...1 { for dy in -1...1 {
                for j in grid[Cell(x: c.x + dx, y: c.y + dy)] ?? [] where j > i && owner[j] != owner[i] {
                    if p.distance(to: points[j]) <= tolerance { uf.union(i, j) }
                }
            } }
        }
        var clusterSum: [Int: (Vec2, Int)] = [:]
        for i in points.indices {
            let r = uf.find(i)
            let s = clusterSum[r] ?? (.zero, 0)
            clusterSum[r] = (s.0 + points[i], s.1 + 1)
        }
        var remapped = points
        for i in points.indices {
            let r = uf.find(i)
            if let (sum, n) = clusterSum[r] { remapped[r] = sum / Double(n) }
        }
        points = remapped
        rings = rings.map { ring in dedupeConsecutive(ring.map { uf.find($0) }) }

        // 2. T-junction snap: vertex of P near the interior of an edge of Q → move onto e and insert into Q.
        for pi in rings.indices {
            for vid in rings[pi] {
                let v = points[vid]
                for qi in rings.indices where qi != pi {
                    let ring = rings[qi]
                    if ring.contains(vid) { continue }
                    var best: (edge: Int, proj: Vec2, dist: Double)?
                    for j in ring.indices {
                        let a = points[ring[j]], b = points[ring[(j + 1) % ring.count]]
                        let e = Segment(a: a, b: b)
                        let t = e.projectionParameter(of: v)
                        let proj = e.point(at: t)
                        let dist = proj.distance(to: v)
                        guard dist < tolerance else { continue }
                        // Strictly inside, not near an endpoint (those were handled by vertex clustering).
                        guard t > 0, t < 1, proj.distance(to: a) > tolerance * 0.5, proj.distance(to: b) > tolerance * 0.5 else { continue }
                        if dist < (best?.dist ?? .infinity) { best = (j, proj, dist) }
                    }
                    if let best {
                        points[vid] = best.proj
                        rings[qi].insert(vid, at: best.edge + 1)
                    }
                }
            }
        }

        // 3. Axis straightening, one axis at a time, shared vertices moving together.
        let snapTol = Geometry.radians(axisSnapDeg)
        var yGroups = UnionFind(points.count)   // horizontal edges share y
        var xGroups = UnionFind(points.count)   // vertical edges share x
        for ring in rings where ring.count >= 2 {
            for j in ring.indices {
                let i0 = ring[j], i1 = ring[(j + 1) % ring.count]
                let d = points[i1] - points[i0]
                guard d.length > 1e-9 else { continue }
                let ang = abs(atan2(d.y, d.x))                  // [0, π]
                if ang <= snapTol || abs(ang - .pi) <= snapTol { yGroups.union(i0, i1) }
                if abs(ang - .pi / 2) <= snapTol { xGroups.union(i0, i1) }
            }
        }
        let used = Set(rings.flatMap { $0 })
        var ySum: [Int: (Double, Int)] = [:], xSum: [Int: (Double, Int)] = [:]
        for i in used {
            let ry = yGroups.find(i), rx = xGroups.find(i)
            let sy = ySum[ry] ?? (0, 0); ySum[ry] = (sy.0 + points[i].y, sy.1 + 1)
            let sx = xSum[rx] ?? (0, 0); xSum[rx] = (sx.0 + points[i].x, sx.1 + 1)
        }
        for i in used {
            if let (s, n) = ySum[yGroups.find(i)], n > 1 { points[i].y = s / Double(n) }
            if let (s, n) = xSum[xGroups.find(i)], n > 1 { points[i].x = s / Double(n) }
        }

        // 4. Re-normalize; keep pre-weld polygon on failure.
        var out: [Polygon] = []
        var failed: [Int] = []
        for (pi, ring) in rings.enumerated() {
            if let v = try? Validation.normalize(ring.map { points[$0] }, minArea: minArea) {
                out.append(Polygon(unchecked: v))
            } else {
                out.append(polygons[pi]); failed.append(pi)
            }
        }
        return Result(polygons: out, failedIndices: failed)
    }

    private static func dedupeConsecutive(_ ring: [Int]) -> [Int] {
        var out: [Int] = []
        for i in ring where out.last != i { out.append(i) }
        while out.count > 1, out.first == out.last { out.removeLast() }
        return out
    }
}

struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]
    init(_ n: Int) { parent = Array(0..<n); rank = Array(repeating: 0, count: n) }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var c = x
        while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] { parent[ra] = rb } else if rank[ra] > rank[rb] { parent[rb] = ra } else { parent[rb] = ra; rank[ra] += 1 }
    }
}
