import Foundation

// MARK: - Vec2

/// A 2D point or vector in **inches**, level-local coordinates (x right, y down). LLD §1, §6.1.
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(x: 0, y: 0)

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public var isFinite: Bool { x.isFinite && y.isFinite }

    /// Unit vector in the same direction, or `.zero` for a zero vector.
    public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x: x / l, y: y / l) : .zero
    }

    /// Left-hand perpendicular in math orientation: (−y, x).
    public var perpendicular: Vec2 { Vec2(x: -y, y: x) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// z component of the 3D cross product.
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func distanceSquared(to o: Vec2) -> Double { (self - o).lengthSquared }

    /// Rotates about the origin by `radians` (positive = from +x toward +y).
    public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x: x * c - y * s, y: x * s + y * c)
    }

    public func rotated(by radians: Double, around pivot: Vec2) -> Vec2 {
        (self - pivot).rotated(by: radians) + pivot
    }

    public func lerp(to o: Vec2, _ t: Double) -> Vec2 { Vec2(x: x + (o.x - x) * t, y: y + (o.y - y) * t) }

    /// Rounds each coordinate to a multiple of `step` (e.g. 0.01 in).
    public func rounded(to step: Double) -> Vec2 {
        guard step > 0 else { return self }
        return Vec2(x: (x / step).rounded() * step, y: (y / step).rounded() * step)
    }

    public var description: String { "(\(x), \(y))" }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x / s, y: a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(x: -a.x, y: -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    /// Approximate equality within `tolerance` inches.
    public func isApproximatelyEqual(to o: Vec2, tolerance: Double = 0.01) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance
    }
}

// MARK: - Segment

/// A line segment between two points (inches). Used for edges, walls, openings and guides.
public struct Segment: Hashable, Codable, Sendable {
    public var a: Vec2
    public var b: Vec2

    public init(a: Vec2, b: Vec2) { self.a = a; self.b = b }
    public init(_ a: Vec2, _ b: Vec2) { self.a = a; self.b = b }

    public var vector: Vec2 { b - a }
    public var length: Double { vector.length }
    public var midpoint: Vec2 { a.lerp(to: b, 0.5) }
    public var direction: Vec2 { vector.normalized }
    public var reversed: Segment { Segment(a: b, b: a) }
    /// Angle of a→b in radians, in (−π, π].
    public var angle: Double { atan2(b.y - a.y, b.x - a.x) }

    /// Parameter t (unclamped) of the projection of `p` onto the infinite line through a, b.
    public func projectionParameter(of p: Vec2) -> Double {
        let v = vector
        let l2 = v.lengthSquared
        guard l2 > 0 else { return 0 }
        return (p - a).dot(v) / l2
    }

    public func point(at t: Double) -> Vec2 { a.lerp(to: b, t) }

    /// Closest point on the segment (clamped) to `p`.
    public func closestPoint(to p: Vec2) -> Vec2 {
        point(at: min(max(projectionParameter(of: p), 0), 1))
    }

    public func distance(to p: Vec2) -> Double { closestPoint(to: p).distance(to: p) }

    /// Intersection point of two segments, if they cross or touch (non-parallel).
    public func intersection(with o: Segment) -> Vec2? {
        let r = vector, s = o.vector
        let denom = r.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let qp = o.a - a
        let t = qp.cross(s) / denom
        let u = qp.cross(r) / denom
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return point(at: t)
    }

    /// True if the segments share at least one point (including collinear overlap / endpoint touch).
    public func intersects(_ o: Segment, epsilon: Double = 1e-9) -> Bool {
        Geometry.segmentsIntersect(a, b, o.a, o.b, epsilon: epsilon)
    }
}

// MARK: - Rect

/// Axis-aligned bounding rectangle (inches).
public struct Rect: Hashable, Codable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    /// Bounding box of points. Returns `.null` for an empty collection.
    public init<S: Sequence>(points: S) where S.Element == Vec2 {
        var r = Rect.null
        for p in points { r = r.including(p) }
        self = r
    }

    /// The empty rectangle (identity for `union`).
    public static let null = Rect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
    public static let zero = Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)

    public var isNull: Bool { minX > maxX || minY > maxY }
    public var width: Double { isNull ? 0 : maxX - minX }
    public var height: Double { isNull ? 0 : maxY - minY }
    public var area: Double { width * height }
    public var center: Vec2 { Vec2(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    public var origin: Vec2 { Vec2(x: minX, y: minY) }
    public var corners: [Vec2] {
        [Vec2(x: minX, y: minY), Vec2(x: maxX, y: minY), Vec2(x: maxX, y: maxY), Vec2(x: minX, y: maxY)]
    }

    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func contains(_ r: Rect) -> Bool { r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY }
    public func intersects(_ r: Rect) -> Bool {
        !(r.minX > maxX || r.maxX < minX || r.minY > maxY || r.maxY < minY) && !isNull && !r.isNull
    }

    public func including(_ p: Vec2) -> Rect {
        Rect(minX: min(minX, p.x), minY: min(minY, p.y), maxX: max(maxX, p.x), maxY: max(maxY, p.y))
    }

    public func union(_ r: Rect) -> Rect {
        Rect(minX: min(minX, r.minX), minY: min(minY, r.minY), maxX: max(maxX, r.maxX), maxY: max(maxY, r.maxY))
    }

    /// Insets by `d` on every side (negative `d` expands).
    public func insetBy(_ d: Double) -> Rect { Rect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d) }
    public func expanded(by d: Double) -> Rect { insetBy(-d) }
}

// MARK: - Helpers

public enum Geometry {
    /// Orientation of the triple (a, b, c): > 0 counter-clockwise (math orientation), < 0 clockwise, 0 collinear.
    @inlinable
    public static func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b - a).cross(c - a) }

    static func onSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2, epsilon: Double) -> Bool {
        p.x <= max(a.x, b.x) + epsilon && p.x >= min(a.x, b.x) - epsilon &&
        p.y <= max(a.y, b.y) + epsilon && p.y >= min(a.y, b.y) - epsilon
    }

    /// Segment/segment intersection test including touching and collinear overlap.
    public static func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2, epsilon: Double = 1e-9) -> Bool {
        let scale = max(1, (p2 - p1).length, (q2 - q1).length)
        let eps = epsilon * scale
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2)
        let d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) &&
            ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps)) { return true }
        if abs(d1) <= eps && onSegment(p1, q1, q2, epsilon: epsilon) { return true }
        if abs(d2) <= eps && onSegment(p2, q1, q2, epsilon: epsilon) { return true }
        if abs(d3) <= eps && onSegment(q1, p1, p2, epsilon: epsilon) { return true }
        if abs(d4) <= eps && onSegment(q2, p1, p2, epsilon: epsilon) { return true }
        return false
    }

    /// Angle of a direction folded into [0, π).
    public static func foldedAngle(_ v: Vec2) -> Double {
        var t = atan2(v.y, v.x)
        if t < 0 { t += .pi }
        if t >= .pi { t -= .pi }
        return t
    }

    public static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
    public static func radians(_ deg: Double) -> Double { deg * .pi / 180 }

    /// Rounds `value` to the nearest multiple of `step`.
    public static func snap(_ value: Double, to step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}
