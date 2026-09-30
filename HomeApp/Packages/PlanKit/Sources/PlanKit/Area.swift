import Foundation

/// Area and centroid (shoelace). LLD §6.3.
public enum Area {
    public static let squareInchesPerSquareFoot: Double = 144
    public static let squareMetersPerSquareInch: Double = 0.00064516

    /// Shoelace signed area: ½ Σ (xᵢ·yᵢ₊₁ − xᵢ₊₁·yᵢ). Positive for normalized polygons.
    public static func signedArea(_ v: [Vec2]) -> Double {
        let n = v.count
        guard n >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<n {
            let a = v[i], b = v[(i + 1) % n]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    public static func area(_ v: [Vec2]) -> Double { abs(signedArea(v)) }

    /// Area centroid; falls back to the vertex mean for degenerate rings.
    public static func centroid(_ v: [Vec2]) -> Vec2 {
        let n = v.count
        guard n > 0 else { return .zero }
        let a = signedArea(v)
        guard abs(a) > 1e-12 else {
            return v.reduce(.zero, +) / Double(n)
        }
        var cx = 0.0, cy = 0.0
        for i in 0..<n {
            let p = v[i], q = v[(i + 1) % n]
            let f = p.x * q.y - q.x * p.y
            cx += (p.x + q.x) * f
            cy += (p.y + q.y) * f
        }
        return Vec2(x: cx / (6 * a), y: cy / (6 * a))
    }

    public static func squareFeet(fromSquareInches a: Double) -> Double { a / squareInchesPerSquareFoot }
    public static func squareMeters(fromSquareInches a: Double) -> Double { a * squareMetersPerSquareInch }
}
