import Foundation

/// 2D affine transform, same convention as `CGAffineTransform`:
/// x' = a·x + c·y + tx,  y' = b·x + d·y + ty.  LLD §6.1.
public struct Transform2D: Hashable, Codable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Transform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ v: Vec2) -> Transform2D { Transform2D(a: 1, b: 0, c: 0, d: 1, tx: v.x, ty: v.y) }
    public static func translation(x: Double, y: Double) -> Transform2D { translation(Vec2(x: x, y: y)) }
    public static func scale(_ s: Double) -> Transform2D { Transform2D(a: s, b: 0, c: 0, d: s, tx: 0, ty: 0) }
    public static func scale(x: Double, y: Double) -> Transform2D { Transform2D(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    /// Rotation about the origin (positive = from +x toward +y).
    public static func rotation(_ radians: Double) -> Transform2D {
        let cs = cos(radians), sn = sin(radians)
        return Transform2D(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }
    public static func rotation(_ radians: Double, around p: Vec2) -> Transform2D {
        translation(-p).then(rotation(radians)).then(translation(p))
    }

    public var determinant: Double { a * d - b * c }
    public var isIdentity: Bool { self == .identity }

    public func apply(_ p: Vec2) -> Vec2 { Vec2(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }
    /// Applies only the linear part (no translation) — for direction vectors.
    public func applyToVector(_ v: Vec2) -> Vec2 { Vec2(x: a * v.x + c * v.y, y: b * v.x + d * v.y) }
    public func apply(_ s: Segment) -> Segment { Segment(a: apply(s.a), b: apply(s.b)) }

    /// `self` followed by `next` (i.e. next ∘ self).
    public func then(_ next: Transform2D) -> Transform2D {
        Transform2D(
            a: next.a * a + next.c * b,
            b: next.b * a + next.d * b,
            c: next.a * c + next.c * d,
            d: next.b * c + next.d * d,
            tx: next.a * tx + next.c * ty + next.tx,
            ty: next.b * tx + next.d * ty + next.ty
        )
    }

    public var inverse: Transform2D? {
        let det = determinant
        guard abs(det) > 1e-15 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Transform2D(a: ia, b: ib, c: ic, d: id,
                           tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// Rotation angle of the linear part (valid for similarity transforms).
    public var rotationAngle: Double { atan2(b, a) }
    /// Uniform scale of the linear part (valid for similarity transforms).
    public var uniformScale: Double { (a * a + b * b).squareRoot() }

    // MARK: Fitting

    /// Similarity transform (rotation + uniform scale + translation) mapping (p1, p2) onto (q1, q2).
    /// Used for two-point floor alignment (§6.12 step 10). Set `allowScale: false` for a rigid transform.
    public static func fitSimilarity(from p1: Vec2, _ p2: Vec2, to q1: Vec2, _ q2: Vec2, allowScale: Bool = true) -> Transform2D? {
        let vp = p2 - p1, vq = q2 - q1
        let lp = vp.length, lq = vq.length
        guard lp > 1e-9, lq > 1e-9 else { return nil }
        let angle = atan2(vq.y, vq.x) - atan2(vp.y, vp.x)
        let s = allowScale ? lq / lp : 1
        let linear = Transform2D.rotation(angle).then(.scale(s))
        let moved = linear.apply(p1)
        return linear.then(.translation(q1 - moved))
    }

    /// Least-squares affine fit mapping `from[i]` → `to[i]` (≥ 3 non-collinear points).
    /// Used for the satellite snapshot pixel ↔ model mapping (§6.11).
    public static func fitAffine(from src: [Vec2], to dst: [Vec2]) -> Transform2D? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        // Normal equations: [Σxx Σxy Σx; Σxy Σyy Σy; Σx Σy n] · [p q r]ᵀ = [Σx·u Σy·u Σu]ᵀ (and same for v).
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0
        var sxu = 0.0, syu = 0.0, su = 0.0, sxv = 0.0, syv = 0.0, sv = 0.0
        let n = Double(src.count)
        for (p, q) in zip(src, dst) {
            sxx += p.x * p.x; sxy += p.x * p.y; syy += p.y * p.y; sx += p.x; sy += p.y
            sxu += p.x * q.x; syu += p.y * q.x; su += q.x
            sxv += p.x * q.y; syv += p.y * q.y; sv += q.y
        }
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        guard let u = solve3(m, [sxu, syu, su]), let v = solve3(m, [sxv, syv, sv]) else { return nil }
        return Transform2D(a: u[0], b: v[0], c: u[1], d: v[1], tx: u[2], ty: v[2])
    }

    private static func solve3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let D = det(m)
        guard abs(D) > 1e-12 else { return nil }
        var out: [Double] = []
        for col in 0..<3 {
            var mm = m
            for row in 0..<3 { mm[row][col] = r[row] }
            out.append(det(mm) / D)
        }
        return out
    }
}
