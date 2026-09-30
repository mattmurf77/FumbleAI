import Foundation
import PlanKit

/// Tread lines for a Stairs room (listing-plan look): lines across the run every `treadDepth` inches,
/// perpendicular to the room's long axis and clipped to the polygon, plus the run's center line (walk line).
/// Pure, so it is computed once per geometry build (`SpaceRender.treads`) and tested on Linux.
public enum StairTreads {
    /// Typical tread depth (10 in run per step).
    public static let treadDepth = 10.0
    /// Upper bound on lines per stair (very long "Hall & Stairs" strips).
    public static let maxTreads = 40

    public static func lines(for polygon: Polygon, treadDepth: Double = StairTreads.treadDepth) -> [Segment] {
        let b = polygon.bounds
        guard polygon.count >= 3, b.width > 1, b.height > 1, treadDepth > 0 else { return [] }
        // Treads cross the long axis. Long axis horizontal → vertical tread lines.
        let horizontalRun = b.width >= b.height
        let runLength = horizontalRun ? b.width : b.height
        let count = min(Int((runLength / treadDepth).rounded(.down)) - 1, maxTreads)
        guard count >= 1 else { return [] }
        let step = runLength / Double(count + 1)
        var out: [Segment] = []
        for k in 1...count {
            let c = (horizontalRun ? b.minX : b.minY) + step * Double(k)
            out += chords(polygon, at: c, vertical: horizontalRun)
        }
        // Walk line along the middle of the run.
        let mid = horizontalRun ? b.center.y : b.center.x
        out += chords(polygon, at: mid, vertical: !horizontalRun)
        return out
    }

    /// Pieces of the line x = c (vertical) or y = c inside the polygon (even–odd pairing of edge crossings).
    static func chords(_ polygon: Polygon, at c: Double, vertical: Bool) -> [Segment] {
        var hits: [Double] = []
        let v = polygon.vertices
        for i in v.indices {
            let p = v[i], q = v[(i + 1) % v.count]
            let (pa, qa) = vertical ? (p.x, q.x) : (p.y, q.y)
            let (pb, qb) = vertical ? (p.y, q.y) : (p.x, q.x)
            // Half-open rule so a crossing at a vertex counts once.
            if (pa <= c && qa > c) || (qa <= c && pa > c) {
                let t = (c - pa) / (qa - pa)
                hits.append(pb + (qb - pb) * t)
            }
        }
        hits.sort()
        var out: [Segment] = []
        var i = 0
        while i + 1 < hits.count {
            if hits[i + 1] - hits[i] > 0.5 {
                out.append(vertical ? Segment(a: Vec2(x: c, y: hits[i]), b: Vec2(x: c, y: hits[i + 1]))
                                    : Segment(a: Vec2(x: hits[i], y: c), b: Vec2(x: hits[i + 1], y: c)))
            }
            i += 2
        }
        return out
    }
}
