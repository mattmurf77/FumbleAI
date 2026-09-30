import Foundation
import PlanKit
import HomeCore

/// "Build with blocks" starting templates (HLD §4.2, FR-PLN-20/21): rectangles at typical room sizes on the right
/// number of levels, `source = .blocks`, then the editor opens on the ground floor. Deterministic.
///
/// Styles (product names → `HouseStyle`): Ranch → `.ranch`, Colonial 2-story → `.twoStory`, Split-level →
/// `.splitLevel`, Cape → `.capeCod`, Townhouse → `.townhouse`, Condo → `.apartment`. "Blank" is `blank()`.
public struct BlockTemplates: BlockTemplating {
    public init() {}

    /// Product display name for a style.
    public static func displayName(_ style: HouseStyle) -> String {
        switch style {
        case .ranch: return "Ranch"; case .twoStory: return "Colonial 2-story"; case .splitLevel: return "Split-level"
        case .capeCod: return "Cape"; case .townhouse: return "Townhouse"; case .apartment: return "Condo"
        }
    }

    public static func subtitle(_ style: HouseStyle) -> String {
        switch style {
        case .ranch: return "One floor, attached garage"
        case .twoStory: return "Living downstairs, bedrooms up"
        case .splitLevel: return "Three short levels"
        case .capeCod: return "Primary down, bedrooms under the roof"
        case .townhouse: return "Narrow and tall, shared walls"
        case .apartment: return "One floor, no yard"
        }
    }

    /// Whether exterior seeding is offered by default after this style (Condo skips it, spec 03 edge cases).
    public static func seedsExteriorByDefault(_ style: HouseStyle) -> Bool { style != .apartment }

    /// An empty ground floor for "Blank".
    public static func blank() -> PlanDraft {
        PlanDraft(levels: [LevelDraft(name: CaptureNaming.floorName(index: 0), kind: .floor, sortOrder: 0)], source: .blocks)
    }

    // MARK: Room catalog (typical sizes, feet)

    struct Block: Hashable {
        var name: String
        var type: SpaceType
        var widthFt: Double
        var depthFt: Double
        var area: Double { widthFt * depthFt }
    }

    static func living() -> Block { Block(name: "Living Room", type: .living, widthFt: 16, depthFt: 18) }
    static func family() -> Block { Block(name: "Family Room", type: .family, widthFt: 15, depthFt: 17) }
    static func kitchen() -> Block { Block(name: "Kitchen", type: .kitchen, widthFt: 12, depthFt: 14) }
    static func dining() -> Block { Block(name: "Dining Room", type: .dining, widthFt: 12, depthFt: 13) }
    static func primary() -> Block { Block(name: "Primary Bedroom", type: .bedroom, widthFt: 14, depthFt: 16) }
    static func bedroom(_ n: Int) -> Block { Block(name: "Bedroom \(n)", type: .bedroom, widthFt: 11, depthFt: 12) }
    static func bath(_ name: String) -> Block { Block(name: name, type: .bathroom, widthFt: 8, depthFt: 9) }
    static func halfBath() -> Block { Block(name: "Half Bath", type: .halfBath, widthFt: 5, depthFt: 7) }
    static func laundry() -> Block { Block(name: "Laundry", type: .laundry, widthFt: 6, depthFt: 8) }
    static func garage() -> Block { Block(name: "Garage", type: .garage, widthFt: 22, depthFt: 22) }

    struct Floor {
        var name: String
        var kind: Level.Kind
        var sortOrder: Int
        /// Rows front (bottom of screen) … back; the hall strip goes after `hallAfterRow`.
        var rows: [[Block]]
        var hallAfterRow: Int?
        var stairs: Bool
    }

    // MARK: Draft

    public func draft(style: HouseStyle, beds: Int, baths: Double) -> PlanDraft {
        let beds = min(max(beds, 0), 8)
        let baths = min(max((baths * 2).rounded() / 2, 0), 6)
        var ids = DeterministicIDs(seed: DeterministicIDs.seed("blocks|\(style.rawValue)|\(beds)|\(baths)"))
        let floors = Self.floors(style: style, beds: beds, baths: baths)
        let levels = floors.map { f -> LevelDraft in
            LevelDraft(tempId: ids.next(), name: f.name, kind: f.kind, sortOrder: f.sortOrder, spaces: Self.layout(f, ids: &ids))
        }
        return PlanDraft(levels: levels, source: .blocks)
    }

    /// Bedrooms "Primary Bedroom", "Bedroom 2", …; baths "Bathroom" / "Bathroom 1…n".
    static func bedrooms(_ beds: Int, includePrimary: Bool = true, from: Int = 2) -> [Block] {
        guard beds > 0 else { return [] }
        return (includePrimary ? [primary()] : []) + (0..<max(beds - (includePrimary ? 1 : 0), 0)).map { bedroom(from + $0) }
    }

    static func fullBaths(_ baths: Double) -> [Block] {
        let n = Int(baths.rounded(.down))
        return (0..<n).map { bath(n > 1 ? "Bathroom \($0 + 1)" : "Bathroom") }
    }

    static func hasHalf(_ baths: Double) -> Bool { baths - baths.rounded(.down) >= 0.5 }

    /// Splits a list into rows of at most `perRow`.
    static func rows(_ blocks: [Block], perRow: Int) -> [[Block]] {
        guard !blocks.isEmpty else { return [] }
        return stride(from: 0, to: blocks.count, by: perRow).map { Array(blocks[$0..<min($0 + perRow, blocks.count)]) }
    }

    static func twoRows(_ blocks: [Block]) -> ([[Block]], Int?) {
        guard blocks.count > 1 else { return ([blocks], nil) }
        // Balance by area: heaviest first onto the lighter row; keep the original order inside each row.
        var a: [Int] = [], b: [Int] = []
        var wa = 0.0, wb = 0.0
        for k in blocks.indices.sorted(by: { (blocks[$0].area, -$0) > (blocks[$1].area, -$1) }) {
            if wa <= wb { a.append(k); wa += blocks[k].area } else { b.append(k); wb += blocks[k].area }
        }
        return ([a.sorted().map { blocks[$0] }, b.sorted().map { blocks[$0] }], 0)
    }

    static func floors(style: HouseStyle, beds: Int, baths: Double) -> [Floor] {
        let full = fullBaths(baths)
        let half = hasHalf(baths) ? [halfBath()] : []
        func floor(_ index: Int, _ blocks: [Block], stairs: Bool) -> Floor {
            let (r, hall) = twoRows(blocks)
            return Floor(name: CaptureNaming.floorName(index: index), kind: .floor, sortOrder: index, rows: r, hallAfterRow: hall, stairs: stairs)
        }
        switch style {
        case .ranch:
            return [floor(0, [living(), kitchen(), dining(), garage()] + bedrooms(beds) + full + half + [laundry()], stairs: false)]
        case .twoStory:
            return [floor(0, [living(), family(), kitchen(), dining(), garage(), laundry()] + half, stairs: true),
                    floor(1, bedrooms(beds) + full, stairs: true)]
        case .capeCod:
            let down = bedrooms(min(beds, 1)) + Array(full.prefix(1))
            let up = bedrooms(max(beds - 1, 0), includePrimary: false, from: 2) + Array(full.dropFirst())
            var fs = [floor(0, [living(), kitchen(), dining()] + down + half + [laundry()], stairs: true)]
            if !up.isEmpty { fs.append(floor(1, up, stairs: true)) }
            return fs
        case .splitLevel:
            var lower = floor(-1, [family(), garage(), laundry()] + half, stairs: true)
            lower.name = "Lower Level"; lower.kind = .basement
            var main = floor(0, [living(), kitchen(), dining()], stairs: true); main.name = "Main Level"
            var upper = floor(1, bedrooms(beds) + full, stairs: true); upper.name = "Upper Level"
            return upper.rows.isEmpty ? [lower, main] : [lower, main, upper]
        case .townhouse:
            // Narrow: two rooms per row, stairs along the hall.
            let ground = [living(), kitchen(), dining()] + half
            let upper = bedrooms(beds) + full + [laundry()]
            var g = Floor(name: CaptureNaming.floorName(index: 0), kind: .floor, sortOrder: 0, rows: rows(ground, perRow: 2), hallAfterRow: 0, stairs: true)
            if g.rows.count < 2 { g.hallAfterRow = nil }
            var u = Floor(name: CaptureNaming.floorName(index: 1), kind: .floor, sortOrder: 1, rows: rows(upper, perRow: 2), hallAfterRow: 0, stairs: true)
            if u.rows.count < 2 { u.hallAfterRow = nil }
            return [g, u]
        case .apartment:
            return [floor(0, [living(), kitchen()] + bedrooms(beds) + full + half + [Block(name: "Laundry", type: .laundry, widthFt: 4, depthFt: 6)], stairs: false)]
        }
    }

    // MARK: Layout

    static let grid = 6.0
    static let hallDepth = 42.0

    /// Rows are stacked top (back) to bottom (front); each row's depth is its deepest block; widths keep each block's
    /// typical area; every row is stretched to the widest row (the last block takes the slack) so the floor tiles a
    /// rectangle. A 42 in hall (with stairs at the right end on multi-floor styles) goes after `hallAfterRow`.
    static func layout(_ f: Floor, ids: inout DeterministicIDs) -> [SpaceDraft] {
        let ft = 12.0
        func snap(_ v: Double) -> Double { max(grid, Geometry.snap(v, to: grid)) }
        struct Placed { var block: Block; var rect: Rect }
        var rowsOut: [[(Block, Double)]] = []   // (block, width in)
        var depths: [Double] = []
        for row in f.rows where !row.isEmpty {
            let depth = snap(row.map(\.depthFt).max()! * ft)
            depths.append(depth)
            rowsOut.append(row.map { ($0, snap($0.area * 144 / depth)) })
        }
        guard !rowsOut.isEmpty else { return [] }
        let width = rowsOut.map { $0.reduce(0) { $0 + $1.1 } }.max()!
        var placed: [Placed] = []
        var y = 0.0
        for (r, row) in rowsOut.enumerated() {
            var x = 0.0
            for (k, item) in row.enumerated() {
                let w = k == row.count - 1 ? width - x : item.1
                placed.append(Placed(block: item.0, rect: Rect(x: x, y: y, width: w, height: depths[r])))
                x += w
            }
            y += depths[r]
            if f.hallAfterRow == r && r < rowsOut.count - 1 {
                let stairsLen = 120.0
                if f.stairs && width > stairsLen + 60 {
                    placed.append(Placed(block: Block(name: "Hall", type: .hall, widthFt: 0, depthFt: 0),
                                         rect: Rect(x: 0, y: y, width: width - stairsLen, height: hallDepth)))
                    placed.append(Placed(block: Block(name: "Stairs", type: .stairs, widthFt: 0, depthFt: 0),
                                         rect: Rect(x: width - stairsLen, y: y, width: stairsLen, height: hallDepth)))
                } else {
                    placed.append(Placed(block: Block(name: "Hall", type: .hall, widthFt: 0, depthFt: 0),
                                         rect: Rect(x: 0, y: y, width: width, height: hallDepth)))
                }
                y += hallDepth
            }
        }
        // Single-row floors with stairs: add a stair block to the right so the floors connect.
        if f.stairs && f.hallAfterRow == nil {
            placed.append(Placed(block: Block(name: "Stairs", type: .stairs, widthFt: 0, depthFt: 0),
                                 rect: Rect(x: width, y: 0, width: hallDepth, height: 120)))
        }
        return placed.compactMap { p in
            guard let poly = try? Polygon(p.rect.corners, minArea: Tolerance.minZoneArea) else { return nil }
            return SpaceDraft(tempId: ids.next(), name: p.block.name, spaceType: p.block.type, polygon: poly, source: .blocks, isApproximate: false)
        }
    }
}
