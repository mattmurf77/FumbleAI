import Foundation
import PlanKit
import HomeCore

/// "Build with blocks" starting templates (HLD §4.2, FR-PLN-20/21): rectangles at typical room sizes on the right
/// number of levels, `source = .blocks`, then the editor opens on the ground floor. Deterministic.
///
/// Styles (product names → `HouseStyle`): Ranch → `.ranch`, Colonial 2-story → `.twoStory`, Split-level →
/// `.splitLevel`, Bi-level → `.biLevel`, Cape → `.capeCod`, Townhouse → `.townhouse`, Condo → `.apartment`.
/// "Blank" is `blank()`. `.unknown` (a style from a newer app) falls back to the Ranch layout.
///
/// Multi-level styles put a Stairs block on every level. With `matchOutlines` (the default) every level takes the
/// reference floor's outline (the largest level, normally the ground / main level) and its hall strip, so the stairs sit at the same
/// position on each level and the user only has to subdivide.
public struct BlockTemplates: BlockTemplating {
    public init() {}

    /// Product display name for a style.
    public static func displayName(_ style: HouseStyle) -> String { style.displayName }

    public static func subtitle(_ style: HouseStyle) -> String { style.subtitle }

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
    /// Split-foyer entry landing (bi-level), placed in the hall strip next to the stairs.
    static func foyer() -> Block { Block(name: "Entry Foyer", type: .hall, widthFt: 6, depthFt: 3.5) }
    /// Filler for a band of a matched outline that the style has no rooms for.
    static func unassigned() -> Block { Block(name: FloorMatching.unassignedName, type: .room, widthFt: 12, depthFt: 10) }

    struct Floor {
        var name: String
        var kind: Level.Kind
        var sortOrder: Int
        /// Rows front (bottom of screen) … back; the hall strip goes after `hallAfterRow`.
        var rows: [[Block]]
        var hallAfterRow: Int?
        var stairs: Bool
        /// Blocks placed in the hall strip just left of the stairs (bi-level entry foyer).
        var hallExtras: [Block] = []
    }

    /// The reference floor's outline, hall strip and stairs, imposed on the other levels (`matchOutlines`).
    struct Frame: Hashable {
        var width: Double
        var depth: Double
        /// Top of the hall strip, when the reference floor has one.
        var hallY: Double?
        /// Stairs block (in the hall strip, or appended to the right of a single-row floor).
        var stairs: Rect?
    }

    // MARK: Draft

    public func draft(style: HouseStyle, beds: Int, baths: Double) -> PlanDraft {
        draft(style: style, beds: beds, baths: baths, matchOutlines: true)
    }

    public func draft(style: HouseStyle, beds: Int, baths: Double, matchOutlines: Bool) -> PlanDraft {
        let beds = min(max(beds, 0), 8)
        let baths = min(max((baths * 2).rounded() / 2, 0), 6)
        var ids = DeterministicIDs(seed: DeterministicIDs.seed("blocks|\(style.rawValue)|\(beds)|\(baths)\(matchOutlines ? "" : "|free")"))
        let floors = Self.floors(style: style, beds: beds, baths: baths)
        // Reference floor: the largest natural layout (the ground floor for most styles), laid out with scratch ids;
        // the other levels take its frame.
        var refIndex: Int?
        var frame: Frame?
        if matchOutlines && floors.count > 1 {
            var scratch = DeterministicIDs(seed: 0)
            let natural = floors.map { Self.layout($0, frame: nil, ids: &scratch).frame }
            let best = natural.indices.max { a, b in
                let fa = natural[a].width * natural[a].depth, fb = natural[b].width * natural[b].depth
                return fa != fb ? fa < fb : abs(floors[a].sortOrder) > abs(floors[b].sortOrder)
            }
            refIndex = best
            frame = best.map { natural[$0] }
        }
        let levels = floors.enumerated().map { i, f -> LevelDraft in
            let tempId = ids.next()
            let own = i == refIndex ? nil : frame
            return LevelDraft(tempId: tempId, name: f.name, kind: f.kind, sortOrder: f.sortOrder, spaces: Self.layout(f, frame: own, ids: &ids).spaces)
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
        case .ranch, .unknown:
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
        case .biLevel:
            // Split foyer: the entry landing sits in the main level's hall strip beside the stairs; a short flight
            // goes up to the main level (living, kitchen, dining, bedrooms) and one goes down to the partly
            // below-grade lower level (family room, bath, laundry, garage; a 4th+ bedroom goes down too).
            let mainBeds = beds >= 4 ? beds - 1 : beds
            let mainBaths = full.count >= 2 ? Array(full.dropLast()) : full
            let lowerBaths = full.count >= 2 ? [full[full.count - 1]] : []
            var main = floor(0, [living(), kitchen(), dining()] + bedrooms(mainBeds) + mainBaths, stairs: true)
            main.name = "Main Level"; main.hallExtras = [foyer()]
            let lowerBed = beds >= 4 ? [bedroom(beds)] : []
            var lower = floor(-1, [family(), garage(), laundry()] + lowerBed + lowerBaths + half, stairs: true)
            lower.name = "Lower Level"; lower.kind = .basement
            return [lower, main]
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
    ///
    /// With a `frame` (another level's outline) the rows are scaled to the frame's width, the rows before the hall
    /// fill the frame down to its hall strip and the rows after it fill the rest, and the stairs are placed exactly
    /// where the frame has them. A band with no rooms gets an "Unassigned space" block.
    static func layout(_ f: Floor, frame: Frame?, ids: inout DeterministicIDs) -> (spaces: [SpaceDraft], frame: Frame) {
        let ft = 12.0
        let stairsLen = 120.0
        func snap(_ v: Double) -> Double { max(grid, Geometry.snap(v, to: grid)) }
        struct Placed { var block: Block; var rect: Rect }
        var rows: [[(Block, Double)]] = []   // (block, natural width in)
        var depths: [Double] = []
        for row in f.rows where !row.isEmpty {
            let depth = snap(row.map(\.depthFt).max()! * ft)
            depths.append(depth)
            rows.append(row.map { ($0, snap($0.area * 144 / depth)) })
        }
        guard !rows.isEmpty || frame != nil else { return ([], Frame(width: 0, depth: 0, hallY: nil, stairs: nil)) }

        // Hall position (index of the row it follows) and target sizes.
        var hallAfter: Int? = f.hallAfterRow.flatMap { $0 < rows.count - 1 ? $0 : nil }
        let width: Double
        if let fr = frame {
            width = fr.width
            if let hy = fr.hallY {
                if rows.isEmpty { rows = [[(unassigned(), width)]]; depths = [hy] }
                if rows.count == 1 { rows.append([(unassigned(), width)]); depths.append(fr.depth - hy - hallDepth) }
                let h = min(hallAfter ?? 0, rows.count - 2)
                hallAfter = h
                depths = fit(Array(depths[...h]), to: hy) + fit(Array(depths[(h + 1)...]), to: fr.depth - hy - hallDepth)
            } else {
                if rows.isEmpty { rows = [[(unassigned(), width)]]; depths = [fr.depth] }
                hallAfter = nil
                depths = fit(depths, to: fr.depth)
            }
            rows = rows.map { row in zip(row.map(\.0), fit(row.map(\.1), to: width)).map { ($0, $1) } }
        } else {
            width = rows.map { $0.reduce(0) { $0 + $1.1 } }.max()!
        }

        var placed: [Placed] = []
        var y = 0.0
        var hallY: Double?
        var stairsRect: Rect?
        for (r, row) in rows.enumerated() {
            var x = 0.0
            for (k, item) in row.enumerated() {
                let w = k == row.count - 1 ? width - x : item.1
                placed.append(Placed(block: item.0, rect: Rect(x: x, y: y, width: w, height: depths[r])))
                x += w
            }
            y += depths[r]
            if hallAfter == r {
                hallY = y
                // Right to left: stairs, hall extras (foyer), then the hall takes the rest.
                var right = width
                if f.stairs {
                    let s = frame?.stairs ?? (width > stairsLen + 60 ? Rect(x: width - stairsLen, y: y, width: stairsLen, height: hallDepth) : nil)
                    if let s {
                        placed.append(Placed(block: Block(name: "Stairs", type: .stairs, widthFt: 0, depthFt: 0), rect: s))
                        stairsRect = s
                        right = s.minX
                    }
                }
                for extra in f.hallExtras.reversed() {
                    let w = snap(extra.widthFt * ft)
                    guard right - w >= 60 else { break }
                    placed.append(Placed(block: extra, rect: Rect(x: right - w, y: y, width: w, height: hallDepth)))
                    right -= w
                }
                if right > 0 {
                    placed.append(Placed(block: Block(name: "Hall", type: .hall, widthFt: 0, depthFt: 0),
                                         rect: Rect(x: 0, y: y, width: right, height: hallDepth)))
                }
                y += hallDepth
            }
        }
        // Single-row floors with stairs: add a stair block to the right so the floors connect.
        if f.stairs && hallAfter == nil {
            let s = frame?.stairs ?? Rect(x: width, y: 0, width: hallDepth, height: 120)
            placed.append(Placed(block: Block(name: "Stairs", type: .stairs, widthFt: 0, depthFt: 0), rect: s))
            stairsRect = s
        }
        let spaces = placed.compactMap { p -> SpaceDraft? in
            guard let poly = try? Polygon(p.rect.corners, minArea: Tolerance.minZoneArea) else { return nil }
            return SpaceDraft(tempId: ids.next(), name: p.block.name, spaceType: p.block.type, polygon: poly, source: .blocks, isApproximate: false)
        }
        return (spaces, frame ?? Frame(width: width, depth: y, hallY: hallY, stairs: stairsRect))
    }

    /// Scales lengths proportionally so they sum to `total`, each on the grid (≥ 1 grid step); the last takes the slack.
    static func fit(_ lengths: [Double], to total: Double) -> [Double] {
        guard !lengths.isEmpty else { return [] }
        let sum = lengths.reduce(0, +)
        guard sum > 0 else { return lengths }
        var out: [Double] = []
        var used = 0.0
        for (i, l) in lengths.enumerated() {
            if i == lengths.count - 1 { out.append(max(total - used, grid)); break }
            let v = max(grid, Geometry.snap(l * total / sum, to: grid))
            out.append(v); used += v
        }
        return out
    }
}
