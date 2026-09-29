import Foundation

/// Geometry tolerances (inches unless noted). LLD §6.1.
public enum Tolerance {
    /// Vertex/edge merge at import (§6.5).
    public static let weld: Double = 3.0
    /// Render-time coincident-edge tolerance (§6.4).
    public static let wallMerge: Double = 3.0
    /// Collinearity angle tolerance, degrees.
    public static let angleDeg: Double = 1.0
    /// Drop vertices closer than this to the chord of their neighbours.
    public static let collinearDrop: Double = 0.25
    /// Consecutive duplicate distance.
    public static let duplicate: Double = 0.01
    /// Coordinate rounding step.
    public static let rounding: Double = 0.01
    /// Minimum interior room area: 4 sq ft.
    public static let minRoomArea: Double = 4 * 144
    /// Minimum exterior zone area: 1 sq ft.
    public static let minZoneArea: Double = 144
    /// Maximum allowed overlap between interior spaces on one level (sq in), §6.2 rule 7.
    public static let maxInteriorOverlap: Double = 1.0
}

public enum PolygonError: Error, Hashable, Sendable {
    case tooFewVertices(Int)
    case nonFinite
    case tooSmall(area: Double)
    case selfIntersecting
}

/// A simple polygon (open ring) in inches with normalized winding: the shoelace signed
/// area in stored (y-down) coordinates is positive. LLD §6.1–6.3.
///
/// JSON form (LLD §1): `[[x,y],[x,y],...]`, ring not closed.
public struct Polygon: Hashable, Sendable {
    public private(set) var vertices: [Vec2]

    /// Validates and normalizes (`Validation.normalize`) with the interior-room minimum area.
    public init(_ v: [Vec2]) throws {
        self.vertices = try Validation.normalize(v)
    }

    /// Validates and normalizes with a custom minimum area (e.g. `Tolerance.minZoneArea` for exterior zones).
    public init(_ v: [Vec2], minArea: Double) throws {
        self.vertices = try Validation.normalize(v, minArea: minArea)
    }

    /// Wraps vertices without validation. Use only for trusted, already-normalized data
    /// (e.g. rows read back from the database) or for intermediate construction.
    public init(unchecked v: [Vec2]) { self.vertices = v }

    /// Axis-aligned rectangle polygon.
    public init(rect r: Rect) { self.vertices = r.corners }

    public var count: Int { vertices.count }

    public var edges: [Segment] {
        guard vertices.count >= 2 else { return [] }
        return vertices.indices.map { Segment(a: vertices[$0], b: vertices[($0 + 1) % vertices.count]) }
    }

    public var bounds: Rect { Rect(points: vertices) }

    /// Area in square inches, always ≥ 0.
    public var area: Double { abs(Area.signedArea(vertices)) }

    public var signedArea: Double { Area.signedArea(vertices) }

    public var centroid: Vec2 { Area.centroid(vertices) }

    public var perimeter: Double { edges.reduce(0) { $0 + $1.length } }

    public func contains(_ p: Vec2, tolerance: Double = 0.01) -> Bool {
        Contains.contains(self, p, tolerance: tolerance)
    }

    public func distanceToEdge(_ p: Vec2) -> Double { Contains.distanceToEdges(of: self, p) }

    /// If the polygon is an axis-free rectangle (4 vertices, all right angles within 1°), its side lengths
    /// `(width, height)` where width is the length of the edge closest to horizontal. Used for "12'4" × 14'0"" labels (§6.7).
    public var rectangleSize: (width: Double, height: Double)? {
        guard vertices.count == 4 else { return nil }
        let es = edges
        let tol = sin(Geometry.radians(Tolerance.angleDeg))
        for i in 0..<4 {
            let u = es[i].direction, v = es[(i + 1) % 4].direction
            if abs(u.dot(v)) > tol { return nil }
        }
        let e0 = es[0], e1 = es[1]
        let e0Horizontal = abs(e0.vector.x) >= abs(e0.vector.y)
        return e0Horizontal ? (e0.length, e1.length) : (e1.length, e0.length)
    }

    public func transformed(by t: Transform2D) -> Polygon {
        var v = vertices.map { t.apply($0) }
        if t.determinant < 0 { v.reverse() }
        return Polygon(unchecked: v)
    }

    public func translated(by d: Vec2) -> Polygon { Polygon(unchecked: vertices.map { $0 + d }) }
}

extension Polygon: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode([[Double]].self)
        var pts: [Vec2] = []
        pts.reserveCapacity(raw.count)
        for pair in raw {
            guard pair.count >= 2 else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Polygon vertex must be [x,y]")
            }
            pts.append(Vec2(x: pair[0], y: pair[1]))
        }
        // Stored data is trusted (it was normalized on write); do not re-validate on read.
        self.init(unchecked: pts)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(vertices.map { [Self.round2($0.x), Self.round2($0.y)] })
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

// MARK: - Validation

/// `Validation.normalize` — LLD §6.2 steps 1–6. (Step 7, the level overlap rule, is checked by the
/// plan service with `Clip.intersectionArea`.)
public enum Validation {
    public static func normalize(_ input: [Vec2], minArea: Double = Tolerance.minRoomArea) throws -> [Vec2] {
        guard input.allSatisfy(\.isFinite) else { throw PolygonError.nonFinite }
        var v = input
        // Drop an explicit closing vertex.
        if v.count > 1, let f = v.first, let l = v.last, f.distance(to: l) < Tolerance.duplicate { v.removeLast() }
        v = removeDuplicates(v)
        v = removeCollinear(v, tolerance: Tolerance.collinearDrop)
        guard v.count >= 3 else { throw PolygonError.tooFewVertices(v.count) }
        if !isSimple(v) { throw PolygonError.selfIntersecting }
        let signed = Area.signedArea(v)
        if abs(signed) < minArea { throw PolygonError.tooSmall(area: abs(signed)) }
        if signed < 0 { v.reverse() }
        // Note: vertex order is preserved (apart from a winding flip) so editor handle indices stay stable.
        v = v.map { $0.rounded(to: Tolerance.rounding) }
        v = removeDuplicates(v)
        guard v.count >= 3 else { throw PolygonError.tooFewVertices(v.count) }
        return v
    }

    /// Step 1: remove consecutive duplicates (distance < 0.01 in), including last→first.
    public static func removeDuplicates(_ input: [Vec2], tolerance: Double = Tolerance.duplicate) -> [Vec2] {
        var out: [Vec2] = []
        for p in input where out.last.map({ $0.distance(to: p) >= tolerance }) ?? true { out.append(p) }
        while out.count > 1, let f = out.first, let l = out.last, f.distance(to: l) < tolerance { out.removeLast() }
        return out
    }

    /// Step 2: remove vertices whose distance to the chord (prev, next) is below `tolerance`,
    /// but only when the vertex lies between its neighbours (true collinear pass-through).
    /// Spikes (the ring doubling back) are left for the simplicity check to reject.
    public static func removeCollinear(_ input: [Vec2], tolerance: Double) -> [Vec2] {
        var v = input
        var changed = true
        while changed && v.count > 3 {
            changed = false
            var i = 0
            while i < v.count && v.count > 3 {
                let prev = v[(i - 1 + v.count) % v.count], cur = v[i], next = v[(i + 1) % v.count]
                let chord = Segment(a: prev, b: next)
                let t = chord.projectionParameter(of: cur)
                if t > 0, t < 1, chord.distance(to: cur) < tolerance {
                    v.remove(at: i)
                    changed = true
                } else {
                    i += 1
                }
            }
        }
        return v
    }

    /// Step 4: true if no two edges intersect except adjacent edges at their shared vertex,
    /// and no adjacent edges fold back onto each other.
    public static func isSimple(_ v: [Vec2]) -> Bool {
        let n = v.count
        guard n >= 3 else { return false }
        for i in 0..<n {
            let a1 = v[i], a2 = v[(i + 1) % n]
            // Adjacent fold-back (spike): next edge reverses direction along the same line.
            let a3 = v[(i + 2) % n]
            let d1 = a2 - a1, d2 = a3 - a2
            if abs(d1.cross(d2)) <= 1e-9 * max(1, d1.length * d2.length), d1.dot(d2) < 0 { return false }
            for j in (i + 1)..<n {
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = v[j], b2 = v[(j + 1) % n]
                if Geometry.segmentsIntersect(a1, a2, b1, b2, epsilon: 1e-9) { return false }
            }
        }
        return true
    }

    /// Validates an already-constructed polygon's vertex list without mutating it.
    public static func validate(_ v: [Vec2], minArea: Double = Tolerance.minRoomArea) -> PolygonError? {
        do { _ = try normalize(v, minArea: minArea); return nil } catch let e as PolygonError { return e } catch { return .nonFinite }
    }
}
