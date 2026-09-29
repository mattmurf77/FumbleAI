import Foundation

/// Pure-Swift replacements for the Clipper2 operations the LLD needs:
/// overlap area (§6.2 rule 7), split along a line and union of adjacent rooms (§6.8),
/// outward offset (§6.12 step 5), simplification (§6.11) and convex hull (§6.12 step 4c).
///
/// All inputs are expected to be normalized (`Polygon` positive winding, simple).
public enum Clip {

    // MARK: Overlap

    /// Area of the intersection of two simple polygons (sq in). Exact for simple polygons:
    /// triangulates `a` by ear clipping and clips `b` against each (convex) triangle.
    public static func intersectionArea(_ a: Polygon, _ b: Polygon) -> Double {
        guard a.bounds.intersects(b.bounds) else { return 0 }
        var total = 0.0
        for tri in triangulate(a.vertices) {
            let triRect = Rect(points: tri)
            guard triRect.intersects(b.bounds) else { continue }
            let clipped = clipConvex(subject: b.vertices, by: tri)
            total += abs(Area.signedArea(clipped))
        }
        return total
    }

    /// True if the two polygons overlap by more than `maxOverlap` sq in (default 1 sq in).
    public static func overlaps(_ a: Polygon, _ b: Polygon, maxOverlap: Double = Tolerance.maxInteriorOverlap) -> Bool {
        intersectionArea(a, b) > maxOverlap
    }

    /// Ear-clipping triangulation of a simple ring (either winding). Returns CCW (positive-area) triangles.
    public static func triangulate(_ ring: [Vec2]) -> [[Vec2]] {
        var v = ring
        if Area.signedArea(v) < 0 { v.reverse() }
        var idx = Array(v.indices)
        var tris: [[Vec2]] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for k in idx.indices {
                let i0 = idx[(k - 1 + idx.count) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = v[i0], b = v[i1], c = v[i2]
                let o = Geometry.orient(a, b, c)
                if o <= 1e-12 { continue }                    // reflex or degenerate
                var inside = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if pointInTriangle(v[j], a, b, c) { inside = true; break }
                }
                if inside { continue }
                tris.append([a, b, c])
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped {
                // Degenerate remainder (collinear points): drop the flattest vertex.
                if let k = idx.indices.min(by: {
                    abs(Geometry.orient(v[idx[($0 - 1 + idx.count) % idx.count]], v[idx[$0]], v[idx[($0 + 1) % idx.count]])) <
                    abs(Geometry.orient(v[idx[($1 - 1 + idx.count) % idx.count]], v[idx[$1]], v[idx[($1 + 1) % idx.count]]))
                }) { idx.remove(at: k) } else { break }
            }
        }
        if idx.count == 3, Geometry.orient(v[idx[0]], v[idx[1]], v[idx[2]]) > 1e-12 {
            tris.append([v[idx[0]], v[idx[1]], v[idx[2]]])
        }
        return tris
    }

    static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = Geometry.orient(a, b, p), d2 = Geometry.orient(b, c, p), d3 = Geometry.orient(c, a, p)
        return d1 >= -1e-12 && d2 >= -1e-12 && d3 >= -1e-12
    }

    /// Sutherland–Hodgman clip of any ring against a **convex CCW** clip ring. The result may contain
    /// zero-width bridges for concave subjects, but its area is exact.
    public static func clipConvex(subject: [Vec2], by clip: [Vec2]) -> [Vec2] {
        var output = subject
        let n = clip.count
        for i in 0..<n {
            guard !output.isEmpty else { break }
            let c1 = clip[i], c2 = clip[(i + 1) % n]
            let input = output
            output = []
            for j in input.indices {
                let p = input[j], q = input[(j + 1) % input.count]
                let pin = Geometry.orient(c1, c2, p) >= 0, qin = Geometry.orient(c1, c2, q) >= 0
                if pin {
                    output.append(p)
                    if !qin, let x = lineIntersection(p, q, c1, c2) { output.append(x) }
                } else if qin, let x = lineIntersection(p, q, c1, c2) {
                    output.append(x)
                }
            }
        }
        return output
    }

    /// Intersection of segment p→q with the infinite line c1→c2.
    static func lineIntersection(_ p: Vec2, _ q: Vec2, _ c1: Vec2, _ c2: Vec2) -> Vec2? {
        let r = q - p, s = c2 - c1
        let denom = r.cross(s)
        guard abs(denom) > 1e-15 else { return nil }
        let t = (c1 - p).cross(s) / denom
        return p + r * t
    }

    // MARK: Split

    /// Splits a polygon along the infinite line through `point` with direction `direction`
    /// (the editor uses orthogonal lines). Succeeds only when the line crosses the boundary exactly twice
    /// and both pieces are valid rooms; otherwise returns nil.
    public static func split(_ polygon: Polygon, linePoint point: Vec2, direction: Vec2,
                             minArea: Double = Tolerance.minRoomArea) -> (Polygon, Polygon)? {
        let dir = direction.normalized
        guard dir != .zero else { return nil }
        let eps = 1e-6
        let side: (Vec2) -> Double = { dir.cross($0 - point) }
        var ring: [Vec2] = []
        var onLine: [Int] = []
        let v = polygon.vertices
        for i in v.indices {
            let p = v[i], q = v[(i + 1) % v.count]
            let sp = side(p), sq = side(q)
            if abs(sp) <= eps { onLine.append(ring.count) }
            ring.append(p)
            if (sp > eps && sq < -eps) || (sp < -eps && sq > eps) {
                let t = sp / (sp - sq)
                onLine.append(ring.count)
                ring.append(p.lerp(to: q, t))
            }
        }
        guard onLine.count == 2 else { return nil }
        let i1 = onLine[0], i2 = onLine[1]
        let partA = Array(ring[i1...i2])
        let partB = Array(ring[i2...] + ring[...i1])
        guard let a = try? Polygon(partA, minArea: minArea), let b = try? Polygon(partB, minArea: minArea) else { return nil }
        return (a, b)
    }

    // MARK: Union of adjacent polygons

    /// Union of two polygons that share at least one boundary sub-edge (after weld). Returns nil unless the
    /// result is a single simple polygon (no holes, no pinch points). §6.8 "Merge".
    public static func unionAdjacent(_ p: Polygon, _ q: Polygon, tolerance: Double = 0.05,
                                     minArea: Double = Tolerance.minRoomArea) -> Polygon? {
        guard intersectionArea(p, q) <= Tolerance.maxInteriorOverlap else { return nil }
        let pv = subdivide(p.vertices, at: q.vertices, tolerance: tolerance)
        let qv = subdivide(q.vertices, at: p.vertices, tolerance: tolerance)
        struct Key: Hashable { var x: Int64; var y: Int64 }
        let quantum = max(tolerance, 1e-4)
        func key(_ v: Vec2) -> Key { Key(x: Int64((v.x / quantum).rounded()), y: Int64((v.y / quantum).rounded())) }
        var coords: [Key: Vec2] = [:]
        var edges: [(Key, Key)] = []
        for ring in [pv, qv] {
            for i in ring.indices {
                let a = key(ring[i]), b = key(ring[(i + 1) % ring.count])
                if a == b { continue }
                coords[a] = coords[a] ?? ring[i]
                coords[b] = coords[b] ?? ring[(i + 1) % ring.count]
                edges.append((a, b))
            }
        }
        // Cancel opposite pairs (shared boundary).
        var counts: [[Key]: Int] = [:]
        for (a, b) in edges { counts[[a, b], default: 0] += 1 }
        var removedAny = false
        var remaining: [(Key, Key)] = []
        for (a, b) in edges {
            if let n = counts[[b, a]], n > 0 {
                removedAny = true
                continue
            }
            remaining.append((a, b))
        }
        guard removedAny, !remaining.isEmpty else { return nil }
        var next: [Key: Key] = [:]
        for (a, b) in remaining {
            if next[a] != nil { return nil }       // pinch point → not a single simple ring
            next[a] = b
        }
        guard let start = remaining.first?.0 else { return nil }
        var ring: [Vec2] = []
        var cur = start
        var steps = 0
        repeat {
            guard let c = coords[cur], let n = next[cur] else { return nil }
            ring.append(c)
            cur = n
            steps += 1
            if steps > remaining.count { return nil }
        } while cur != start
        guard steps == remaining.count else { return nil }   // more than one ring (hole or disjoint)
        return try? Polygon(ring, minArea: minArea)
    }

    /// Inserts points of `others` that lie strictly inside edges of `ring` (T-junctions).
    static func subdivide(_ ring: [Vec2], at others: [Vec2], tolerance: Double) -> [Vec2] {
        var out: [Vec2] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            out.append(a)
            let e = Segment(a: a, b: b)
            var inner: [(p: Vec2, t: Double)] = []
            for o in others {
                let t = e.projectionParameter(of: o)
                guard t > 1e-9, t < 1 - 1e-9 else { continue }
                guard e.distance(to: o) <= tolerance else { continue }
                guard o.distance(to: a) > tolerance, o.distance(to: b) > tolerance else { continue }
                inner.append((o, t))
            }
            inner.sort { $0.t < $1.t }
            out.append(contentsOf: inner.map { e.point(at: $0.t) })
        }
        return out
    }

    // MARK: Offset

    /// Offsets a polygon outward by `delta` inches (negative shrinks) with a miter join; corners whose miter
    /// would exceed `miterLimit · |delta|` are beveled. §6.12 step 5 uses delta 2.25, limit 2.
    public static func offset(_ polygon: Polygon, by delta: Double, miterLimit: Double = 2,
                              minArea: Double = Tolerance.minZoneArea) -> Polygon? {
        let v = polygon.vertices
        let n = v.count
        guard n >= 3, delta != 0 else { return polygon }
        let sign: Double = polygon.signedArea >= 0 ? 1 : -1
        func outward(_ a: Vec2, _ b: Vec2) -> Vec2 { let d = (b - a).normalized; return Vec2(x: d.y, y: -d.x) * sign }
        var out: [Vec2] = []
        for i in 0..<n {
            let prev = v[(i - 1 + n) % n], cur = v[i], next = v[(i + 1) % n]
            let n1 = outward(prev, cur), n2 = outward(cur, next)
            let dot = n1.dot(n2)
            if dot > 1 - 1e-12 { out.append(cur + n1 * delta); continue }
            let m = (n1 + n2) / (1 + dot) * delta
            if 1 + dot < 1e-9 || m.length > miterLimit * abs(delta) {
                out.append(cur + n1 * delta)
                out.append(cur + n2 * delta)
            } else {
                out.append(cur + m)
            }
        }
        return try? Polygon(out, minArea: minArea)
    }

    // MARK: Simplify / hull

    /// Douglas–Peucker simplification of a closed ring (§6.11: 6 in for footprints).
    public static func simplify(_ ring: [Vec2], tolerance: Double) -> [Vec2] {
        guard ring.count > 4 else { return ring }
        // Split the ring at vertex 0 and its farthest vertex, simplify both chains.
        let a = 0
        let b = ring.indices.max(by: { ring[$0].distanceSquared(to: ring[a]) < ring[$1].distanceSquared(to: ring[a]) }) ?? ring.count / 2
        let chain1 = Array(ring[a...b])
        let chain2 = Array(ring[b...]) + [ring[a]]
        let s1 = douglasPeucker(chain1, tolerance)
        let s2 = douglasPeucker(chain2, tolerance)
        return Array(s1.dropLast()) + Array(s2.dropLast())
    }

    static func douglasPeucker(_ pts: [Vec2], _ tol: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        let seg = Segment(a: pts.first!, b: pts.last!)
        var maxD = 0.0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = seg.distance(to: pts[i])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD <= tol { return [pts.first!, pts.last!] }
        let left = douglasPeucker(Array(pts[...idx]), tol)
        let right = douglasPeucker(Array(pts[idx...]), tol)
        return Array(left.dropLast()) + right
    }

    /// Convex hull (Andrew's monotone chain), positive (normalized) winding.
    public static func convexHull(_ points: [Vec2]) -> [Vec2] {
        let pts = Array(Set(points)).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard pts.count >= 3 else { return pts }
        var lower: [Vec2] = [], upper: [Vec2] = []
        for p in pts {
            while lower.count >= 2, Geometry.orient(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2, Geometry.orient(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
