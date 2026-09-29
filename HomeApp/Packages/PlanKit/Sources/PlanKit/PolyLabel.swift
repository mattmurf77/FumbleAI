import Foundation

/// Pole of inaccessibility (Mapbox polylabel). LLD §6.7.
public enum PolyLabel {
    public struct Result: Hashable, Sendable {
        /// Label anchor (the point farthest from any edge).
        public var point: Vec2
        /// Inscribed-circle radius at `point`, inches.
        public var radius: Double
    }

    private struct Cell {
        let center: Vec2
        let half: Double
        let d: Double
        var max: Double { d + half * 2.0.squareRoot() }
        init(_ c: Vec2, _ h: Double, _ poly: Polygon) {
            center = c; half = h; d = Contains.signedDistance(poly, c)
        }
    }

    public static func pole(of polygon: Polygon, precision: Double = 1.0) -> Result {
        let bb = polygon.bounds
        guard polygon.count >= 3, bb.width > 0, bb.height > 0 else {
            return Result(point: polygon.vertices.first ?? .zero, radius: 0)
        }
        let cellSize = min(bb.width, bb.height)
        var half = cellSize / 2
        var queue = MaxHeap<Cell> { $0.max < $1.max }

        var x = bb.minX
        while x < bb.maxX {
            var y = bb.minY
            while y < bb.maxY {
                queue.push(Cell(Vec2(x: x + half, y: y + half), half, polygon))
                y += cellSize
            }
            x += cellSize
        }

        var best = Cell(polygon.centroid, 0, polygon)
        let bboxCell = Cell(bb.center, 0, polygon)
        if bboxCell.d > best.d { best = bboxCell }

        var iterations = 0
        while let cell = queue.pop() {
            iterations += 1
            if cell.d > best.d { best = cell }
            if cell.max - best.d <= precision { continue }
            if iterations > 100_000 { break }
            half = cell.half / 2
            let c = cell.center
            queue.push(Cell(Vec2(x: c.x - half, y: c.y - half), half, polygon))
            queue.push(Cell(Vec2(x: c.x + half, y: c.y - half), half, polygon))
            queue.push(Cell(Vec2(x: c.x - half, y: c.y + half), half, polygon))
            queue.push(Cell(Vec2(x: c.x + half, y: c.y + half), half, polygon))
        }
        return Result(point: best.center, radius: max(best.d, 0))
    }
}

/// Minimal binary max-heap.
struct MaxHeap<T> {
    private var items: [T] = []
    private let less: (T, T) -> Bool
    init(less: @escaping (T, T) -> Bool) { self.less = less }
    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ x: T) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if less(items[p], items[i]) { items.swapAt(p, i); i = p } else { break }
        }
    }

    mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, less(items[m], items[l]) { m = l }
            if r < items.count, less(items[m], items[r]) { m = r }
            if m == i { break }
            items.swapAt(i, m); i = m
        }
        return top
    }
}
