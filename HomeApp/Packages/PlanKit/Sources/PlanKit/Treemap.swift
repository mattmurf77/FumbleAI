import Foundation

/// Squarified treemap (Bruls, Huizing & van Wijk) used by "Rough it in". LLD §6.10.
public enum Treemap {
    /// Lays out `weights` in `rect`. Returns one rectangle per weight **in input order**.
    /// Rects tile `rect` exactly. With `snap` (e.g. 6 in), every interior coordinate is rounded to a multiple
    /// of `snap` measured from `rect`'s origin; residuals go to the last rect of each row (the outer edge is kept).
    /// Zero/negative weights produce zero-area rects.
    public static func squarify(_ weights: [Double], in rect: Rect, snap: Double? = nil) -> [Rect] {
        guard !weights.isEmpty else { return [] }
        let total = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.area > 0 else {
            return weights.map { _ in Rect(minX: rect.minX, minY: rect.minY, maxX: rect.minX, maxY: rect.minY) }
        }
        let scale = rect.area / total
        // Sort indices by descending weight (stable), keep original index.
        let order = weights.indices.sorted { (weights[$0], -$0) > (weights[$1], -$1) }
        let areas = order.map { max(weights[$0], 0) * scale }

        var result = Array(repeating: Rect.zero, count: weights.count)
        var free = rect
        var i = 0
        while i < areas.count {
            let short = min(free.width, free.height)
            var row: [Int] = [i]
            var rowSum = areas[i]
            var j = i + 1
            while j < areas.count {
                let newSum = rowSum + areas[j]
                if worst(row.map { areas[$0] } + [areas[j]], sum: newSum, side: short)
                    <= worst(row.map { areas[$0] }, sum: rowSum, side: short) {
                    row.append(j); rowSum = newSum; j += 1
                } else { break }
            }
            let isLastRow = j >= areas.count
            // Lay out the row along the short side.
            if free.width >= free.height {
                // Column on the left.
                let w = isLastRow ? free.width : rowSum / free.height
                var y = free.minY
                for (k, idx) in row.enumerated() {
                    let h = (k == row.count - 1) ? free.maxY - y : areas[idx] / w
                    result[order[idx]] = Rect(minX: free.minX, minY: y, maxX: free.minX + w, maxY: y + h)
                    y += h
                }
                free.minX += w
            } else {
                let h = isLastRow ? free.height : rowSum / free.width
                var x = free.minX
                for (k, idx) in row.enumerated() {
                    let w = (k == row.count - 1) ? free.maxX - x : areas[idx] / h
                    result[order[idx]] = Rect(minX: x, minY: free.minY, maxX: x + w, maxY: free.minY + h)
                    x += w
                }
                free.minY += h
            }
            i = j
        }

        guard let snap, snap > 0 else { return result }
        // Snap interior coordinates; the outer rect edges stay exact. Shared coordinates snap identically,
        // so the tiling is preserved.
        func sx(_ v: Double) -> Double {
            if abs(v - rect.minX) < 1e-6 || abs(v - rect.maxX) < 1e-6 { return v }
            return min(max(rect.minX + Geometry.snap(v - rect.minX, to: snap), rect.minX), rect.maxX)
        }
        func sy(_ v: Double) -> Double {
            if abs(v - rect.minY) < 1e-6 || abs(v - rect.maxY) < 1e-6 { return v }
            return min(max(rect.minY + Geometry.snap(v - rect.minY, to: snap), rect.minY), rect.maxY)
        }
        return result.map { Rect(minX: sx($0.minX), minY: sy($0.minY), maxX: sx($0.maxX), maxY: sy($0.maxY)) }
    }

    /// Worst aspect ratio of a row laid along `side`.
    private static func worst(_ row: [Double], sum: Double, side: Double) -> Double {
        guard let mx = row.max(), let mn = row.min(), sum > 0, mn > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * mx / sum2, sum2 / (s2 * mn))
    }

    /// Splits `rect` into two sub-rects by weight along its longer side (used to place rooms on either side
    /// of the rough-in hall strip).
    public static func split(_ rect: Rect, weights a: Double, _ b: Double, snap: Double? = nil) -> (Rect, Rect) {
        let t = (a + b) > 0 ? a / (a + b) : 0.5
        if rect.width >= rect.height {
            var x = rect.minX + rect.width * t
            if let snap { x = rect.minX + Geometry.snap(x - rect.minX, to: snap) }
            return (Rect(minX: rect.minX, minY: rect.minY, maxX: x, maxY: rect.maxY),
                    Rect(minX: x, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY))
        } else {
            var y = rect.minY + rect.height * t
            if let snap { y = rect.minY + Geometry.snap(y - rect.minY, to: snap) }
            return (Rect(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: y),
                    Rect(minX: rect.minX, minY: y, maxX: rect.maxX, maxY: rect.maxY))
        }
    }
}
