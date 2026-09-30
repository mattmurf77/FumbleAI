import Foundation
import PlanKit
import HomeCore

/// "Rough it in" (LLD §6.10, FR-PLN-10..15): approximate rooms from floors / sq ft / beds / baths.
/// Deterministic: the same input always yields the same `PlanDraft`, including temp ids.
public struct RoughInGenerator: RoughInGenerating {
    /// Grid every coordinate snaps to.
    public static let grid: Double = 6
    /// Floor rectangle aspect ratio W : H.
    public static let aspect: Double = 1.4
    /// Hall strip height (a horizontal strip through the middle of each floor).
    public static let hallWidth: Double = 42
    /// Length of the stairs block at the right end of the hall strip on multi-floor homes.
    public static let stairsLength: Double = 120

    public struct RoomSpec: Hashable, Sendable {
        public var name: String
        public var type: SpaceType
        public var weight: Double
        public init(_ name: String, _ type: SpaceType, _ weight: Double) { self.name = name; self.type = type; self.weight = weight }
    }

    /// Room weights (§6.10 table).
    public enum Weight {
        public static let living = 1.00, kitchen = 0.70, dining = 0.55, primary = 0.85, bedroom = 0.60
        public static let fullBath = 0.25, halfBath = 0.12, laundry = 0.18, garage = 1.10
        /// Not in the LLD table: middle floors of a 3-floor home get a family room; an empty upper floor a bonus room.
        public static let family = 0.80
    }

    /// Rough bedroom capacity of a floor, used for "top floor, overflow to ground".
    static let sqFtPerBedroomSlot = 220.0

    public init() {}

    // MARK: Inputs → per-floor room lists

    /// Clamped inputs (FR-PLN-10 ranges).
    static func clamp(_ i: RoughInInput) -> RoughInInput {
        RoughInInput(floors: min(max(i.floors, 1), 3), hasBasement: i.hasBasement, approxSqFt: min(max(i.approxSqFt, 400), 10_000),
                     bedrooms: min(max(i.bedrooms, 0), 8), bathrooms: min(max((i.bathrooms * 2).rounded() / 2, 0), 6),
                     includeGarage: i.includeGarage, style: i.style)
    }

    /// Per-floor share of the above-grade area (§6.10 step 1).
    public static func floorShares(_ floors: Int) -> [Double] {
        switch floors { case 1: return [1]; case 2: return [0.5, 0.5]; default: return [0.4, 0.4, 0.2] }
    }

    /// The rooms of each above-grade floor (index 0 = ground), excluding hall / stairs / garage.
    public static func roomLists(_ input: RoughInInput) -> [[RoomSpec]] {
        let i = clamp(input)
        let shares = floorShares(i.floors)
        var floors: [[RoomSpec]] = Array(repeating: [], count: i.floors)
        let top = i.floors - 1
        floors[0] += [RoomSpec("Living Room", .living, Weight.living), RoomSpec("Kitchen", .kitchen, Weight.kitchen),
                      RoomSpec("Dining Room", .dining, Weight.dining)]
        let fullBaths = Int(i.bathrooms.rounded(.down))
        let halfBaths = i.bathrooms - Double(fullBaths) >= 0.5 ? 1 : 0

        // Bedrooms: primary on top; extras fill from the top floor down, overflowing to the ground floor.
        if i.bedrooms > 0 {
            floors[top].append(RoomSpec("Primary Bedroom", .bedroom, Weight.primary))
            var capacity = shares.map { max(1, Int((Double(i.approxSqFt) * $0 / sqFtPerBedroomSlot).rounded(.down))) }
            capacity[top] -= 1
            for extra in 0..<(i.bedrooms - 1) {
                var target = 0
                if i.floors > 1 {
                    // Highest upper floor with capacity left; ground when every upper floor is full.
                    target = (1...top).reversed().first { capacity[$0] > 0 } ?? 0
                }
                capacity[target] -= 1
                floors[target].append(RoomSpec("Bedroom \(extra + 2)", .bedroom, Weight.bedroom))
            }
        }
        // Full baths: one on ground for 1 floor, else top; extras on top.
        for b in 0..<fullBaths {
            let name = fullBaths > 1 ? "Bathroom \(b + 1)" : "Bathroom"
            floors[i.floors == 1 ? 0 : top].append(RoomSpec(name, .bathroom, Weight.fullBath))
        }
        if halfBaths > 0 { floors[0].append(RoomSpec("Half Bath", .halfBath, Weight.halfBath)) }
        floors[0].append(RoomSpec("Laundry", .laundry, Weight.laundry))
        if i.floors == 3 { floors[1].append(RoomSpec("Family Room", .family, Weight.family)) }
        for f in 1..<max(i.floors, 1) where floors[f].isEmpty { floors[f].append(RoomSpec("Bonus Room", .room, Weight.family)) }
        return floors
    }

    // MARK: Generate

    public func draft(_ input: RoughInInput) -> PlanDraft {
        let i = Self.clamp(input)
        if i.style == .biLevel { return Self.biLevelDraft(i) }
        var ids = DeterministicIDs(seed: DeterministicIDs.seed("rough|\(i.floors)|\(i.hasBasement)|\(i.approxSqFt)|\(i.bedrooms)|\(i.bathrooms)|\(i.includeGarage)"))
        let lists = Self.roomLists(i)
        let shares = Self.floorShares(i.floors)
        let totalSqIn = Double(i.approxSqFt) * 144
        var levels: [LevelDraft] = []

        // Garage (optional) on the ground floor's left edge, full depth; its area comes from its weight relative to
        // the ground rooms. Every floor is shifted right by the garage width so the floors stack.
        var garageWidth = 0.0
        if i.includeGarage {
            let groundArea = totalSqIn * shares[0]
            let (_, h) = Self.rectSize(area: groundArea)
            let unit = groundArea / lists[0].reduce(0) { $0 + $1.weight }
            garageWidth = max(Self.snap(Weight.garage * unit / h), 120)
        }
        // The ground floor's hall strip anchors the upper floors' halls so the stairs line up floor to floor.
        var anchor: HallAnchor?
        for f in 0..<i.floors {
            let (w, h) = Self.rectSize(area: totalSqIn * shares[f])
            var spaces: [SpaceDraft] = []
            if f == 0 && i.includeGarage {
                spaces += Self.make([RoomSpec("Garage", .garage, Weight.garage)], [Rect(x: 0, y: 0, width: garageWidth, height: h)], &ids)
            }
            let floorRect = Rect(x: garageWidth, y: 0, width: w, height: h)
            let laid = Self.layoutFloor(lists[f], in: floorRect, multiFloor: i.floors > 1, anchor: anchor, ids: &ids)
            spaces += laid.spaces
            if f == 0 { anchor = laid.anchor }
            levels.append(LevelDraft(tempId: ids.next(), name: CaptureNaming.floorName(index: f), kind: .floor, sortOrder: f, spaces: spaces))
        }

        if i.hasBasement {
            // 70 % of the ground floor, one Basement space plus Utility.
            let (w, h) = Self.rectSize(area: totalSqIn * shares[0] * 0.7)
            let rects = Treemap.squarify([0.82, 0.18], in: Rect(x: garageWidth, y: 0, width: w, height: h), snap: Self.grid)
            let spaces = Self.make([RoomSpec("Basement", .room, 0.82), RoomSpec("Utility", .utility, 0.18)], rects, &ids)
            levels.insert(LevelDraft(tempId: ids.next(), name: "Basement", kind: .basement, sortOrder: -1, spaces: spaces), at: 0)
        }
        return PlanDraft(levels: levels, source: .rough)
    }

    // MARK: Bi-level (split foyer)

    /// Main Level (sort 0: living, kitchen, dining, bedrooms, baths) over a Lower Level (sort −1, basement kind:
    /// family room, laundry, a bath, the garage when asked, and a 4th+ bedroom). The approximate square feet are split
    /// evenly and both levels share one outline; the entry foyer and stairs sit in the hall strip at the same spot.
    public static func biLevelRoomLists(_ input: RoughInInput) -> (main: [RoomSpec], lower: [RoomSpec]) {
        let i = clamp(input)
        let fullBaths = Int(i.bathrooms.rounded(.down))
        let half = i.bathrooms - Double(fullBaths) >= 0.5
        var main = [RoomSpec("Living Room", .living, Weight.living), RoomSpec("Kitchen", .kitchen, Weight.kitchen),
                    RoomSpec("Dining Room", .dining, Weight.dining)]
        var lower = [RoomSpec("Family Room", .family, Weight.family), RoomSpec("Laundry", .laundry, Weight.laundry)]
        if i.includeGarage { lower.append(RoomSpec("Garage", .garage, Weight.garage)) }
        let mainBeds = i.bedrooms >= 4 ? i.bedrooms - 1 : i.bedrooms
        if mainBeds > 0 { main.append(RoomSpec("Primary Bedroom", .bedroom, Weight.primary)) }
        if mainBeds > 1 { for b in 2...mainBeds { main.append(RoomSpec("Bedroom \(b)", .bedroom, Weight.bedroom)) } }
        if i.bedrooms >= 4 { lower.append(RoomSpec("Bedroom \(i.bedrooms)", .bedroom, Weight.bedroom)) }
        for b in 0..<fullBaths {
            let name = fullBaths > 1 ? "Bathroom \(b + 1)" : "Bathroom"
            if fullBaths >= 2 && b == fullBaths - 1 { lower.append(RoomSpec(name, .bathroom, Weight.fullBath)) }
            else { main.append(RoomSpec(name, .bathroom, Weight.fullBath)) }
        }
        if half { lower.append(RoomSpec("Half Bath", .halfBath, Weight.halfBath)) }
        return (main, lower)
    }

    static func biLevelDraft(_ i: RoughInInput) -> PlanDraft {
        var ids = DeterministicIDs(seed: DeterministicIDs.seed("rough|biLevel|\(i.approxSqFt)|\(i.bedrooms)|\(i.bathrooms)|\(i.includeGarage)"))
        let lists = biLevelRoomLists(i)
        let (w, h) = rectSize(area: Double(i.approxSqFt) * 144 / 2)
        let rect = Rect(x: 0, y: 0, width: w, height: h)
        let main = layoutFloor(lists.main, in: rect, multiFloor: true, anchor: nil, foyer: true, ids: &ids)
        let lower = layoutFloor(lists.lower, in: rect, multiFloor: true, anchor: main.anchor, ids: &ids)
        return PlanDraft(levels: [
            LevelDraft(tempId: ids.next(), name: "Lower Level", kind: .basement, sortOrder: -1, spaces: lower.spaces),
            LevelDraft(tempId: ids.next(), name: "Main Level", kind: .floor, sortOrder: 0, spaces: main.spaces),
        ], source: .rough)
    }

    // MARK: Layout

    static func snap(_ v: Double) -> Double { max(grid, Geometry.snap(v, to: grid)) }

    /// §6.10 step 3: aspect 1.4 : 1, both sides on the 6 in grid.
    static func rectSize(area: Double) -> (Double, Double) {
        let w = snap((area * aspect).squareRoot())
        return (w, snap(area / w))
    }

    /// Where the ground floor put its hall strip and stairs (absolute level coordinates).
    struct HallAnchor: Hashable {
        /// Height of the rooms above the hall.
        var topHeight: Double
        /// Left edge of the stairs block (nil: no separate stairs block).
        var stairsMinX: Double?
    }

    /// Hall strip through the middle; rooms split into two groups by weight above/below it; treemap each group.
    /// With an `anchor` (an upper floor) the hall and stairs go where the ground floor has them, when they fit.
    /// `foyer`: an "Entry Foyer" (72 in) in the hall strip left of the stairs (bi-level).
    static func layoutFloor(_ rooms: [RoomSpec], in rect: Rect, multiFloor: Bool, anchor: HallAnchor? = nil, foyer: Bool = false,
                            ids: inout DeterministicIDs) -> (spaces: [SpaceDraft], anchor: HallAnchor?) {
        guard !rooms.isEmpty else { return ([], nil) }
        // Too shallow for a hall strip (tiny floors): rooms only.
        guard rect.height >= hallWidth + 2 * 60, rooms.count > 1 else {
            return (make(rooms, Treemap.squarify(rooms.map(\.weight), in: rect, snap: grid), &ids), nil)
        }
        // Balanced partition: heaviest first, each to the lighter side (ties → top). Order inside a side is kept.
        var topIdx: [Int] = [], bottomIdx: [Int] = []
        var tw = 0.0, bw = 0.0
        for k in rooms.indices.sorted(by: { (rooms[$0].weight, -$0) > (rooms[$1].weight, -$1) }) {
            if tw <= bw { topIdx.append(k); tw += rooms[k].weight } else { bottomIdx.append(k); bw += rooms[k].weight }
        }
        let top = topIdx.sorted().map { rooms[$0] }, bottom = bottomIdx.sorted().map { rooms[$0] }

        let avail = rect.height - hallWidth
        var topH = anchor?.topHeight ?? Geometry.snap(avail * tw / (tw + bw), to: grid)
        topH = min(max(topH, 60), avail - 60)
        let topRect = Rect(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.minY + topH)
        let hallRect = Rect(minX: rect.minX, minY: topRect.maxY, maxX: rect.maxX, maxY: topRect.maxY + hallWidth)
        let bottomRect = Rect(minX: rect.minX, minY: hallRect.maxY, maxX: rect.maxX, maxY: rect.maxY)

        var out = make(top, Treemap.squarify(top.map(\.weight), in: topRect, snap: grid), &ids)
        var stairsMinX: Double?
        if multiFloor && hallRect.width > stairsLength + 60 {
            var split = hallRect.maxX - stairsLength
            if let a = anchor?.stairsMinX, a >= hallRect.minX + 60, a + stairsLength <= hallRect.maxX { split = a }
            stairsMinX = split
            var hallRight = split
            var extra: [(RoomSpec, Rect)] = []
            if foyer && split - hallRect.minX >= 72 + 60 {
                extra.append((RoomSpec("Entry Foyer", .hall, 0), Rect(minX: split - 72, minY: hallRect.minY, maxX: split, maxY: hallRect.maxY)))
                hallRight = split - 72
            }
            out += make([RoomSpec("Hall", .hall, 0)], [Rect(minX: hallRect.minX, minY: hallRect.minY, maxX: hallRight, maxY: hallRect.maxY)], &ids)
            out += make(extra.map(\.0), extra.map(\.1), &ids)
            out += make([RoomSpec("Stairs", .stairs, 0)], [Rect(minX: split, minY: hallRect.minY, maxX: split + stairsLength, maxY: hallRect.maxY)], &ids)
            if split + stairsLength < hallRect.maxX - 1 {
                out += make([RoomSpec("Landing", .hall, 0)], [Rect(minX: split + stairsLength, minY: hallRect.minY, maxX: hallRect.maxX, maxY: hallRect.maxY)], &ids)
            }
        } else {
            out += make([RoomSpec(multiFloor ? "Hall & Stairs" : "Hall", multiFloor ? .stairs : .hall, 0)], [hallRect], &ids)
        }
        out += make(bottom, Treemap.squarify(bottom.map(\.weight), in: bottomRect, snap: grid), &ids)
        return (out, HallAnchor(topHeight: topH, stairsMinX: stairsMinX))
    }

    static func make(_ specs: [RoomSpec], _ rects: [Rect], _ ids: inout DeterministicIDs) -> [SpaceDraft] {
        zip(specs, rects).compactMap { spec, r in
            guard let p = try? Polygon(r.corners, minArea: Tolerance.minZoneArea) else { return nil }
            return SpaceDraft(tempId: ids.next(), name: spec.name, spaceType: spec.type, polygon: p, source: .rough, isApproximate: true)
        }
    }
}
