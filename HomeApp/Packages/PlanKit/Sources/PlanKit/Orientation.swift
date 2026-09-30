import Foundation

/// Dominant orientation of a set of segments (walls or footprint edges): the peak of a length-weighted
/// histogram of angles mod 90° with 1° bins and circular smoothing. LLD §6.11 step 1, §6.12 step 3.
public enum Orientation {
    /// Returns α in [0, π/2). Rotate geometry by −α to make it axis-aligned.
    public static func dominantAngle(of segments: [Segment], binDeg: Double = 1) -> Double {
        let bins = max(Int((90 / binDeg).rounded()), 1)
        var hist = Array(repeating: 0.0, count: bins)
        for s in segments {
            let len = s.length
            guard len > 1e-9 else { continue }
            var deg = Geometry.degrees(atan2(s.vector.y, s.vector.x)).truncatingRemainder(dividingBy: 90)
            if deg < 0 { deg += 90 }
            let b = Int((deg / binDeg).rounded()) % bins
            hist[b] += len
        }
        // Circular smoothing [1, 2, 1].
        var smooth = hist
        for i in 0..<bins {
            smooth[i] = hist[(i - 1 + bins) % bins] + 2 * hist[i] + hist[(i + 1) % bins]
        }
        guard let peak = smooth.indices.max(by: { smooth[$0] < smooth[$1] }), smooth[peak] > 0 else { return 0 }
        return Geometry.radians(Double(peak) * binDeg)
    }

    public static func dominantAngle(of polygon: Polygon) -> Double { dominantAngle(of: polygon.edges) }

    /// Snaps an angle to the nearest multiple of 90° if within `toleranceDeg`.
    public static func snapToRightAngle(_ radians: Double, toleranceDeg: Double) -> Double {
        let q = Double.pi / 2
        let nearest = (radians / q).rounded() * q
        return abs(radians - nearest) <= Geometry.radians(toleranceDeg) ? nearest : radians
    }
}
