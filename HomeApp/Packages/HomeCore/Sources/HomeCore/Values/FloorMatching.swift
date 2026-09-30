import Foundation
import PlanKit

/// A room shape on a reference floor (input to `FloorMatching`).
public struct FloorShape: Hashable, Sendable {
    public var polygon: Polygon
    public var spaceType: SpaceType
    public var isExterior: Bool
    public init(polygon: Polygon, spaceType: SpaceType, isExterior: Bool = false) {
        self.polygon = polygon; self.spaceType = spaceType; self.isExterior = isExterior
    }
    public init(_ s: Space) { self.init(polygon: s.polygon, spaceType: s.spaceType, isExterior: s.isExterior) }
    public init(_ d: SpaceDraft) { self.init(polygon: d.polygon, spaceType: d.spaceType, isExterior: d.isExterior) }
}

/// Multi-floor helpers shared by Add floor, the plan editor and the creation paths (spec 01 edge case "Stairs across
/// floors: a Stairs room on each floor"; founder feedback: new floors start from the floor below's outline).
///
/// All levels of a property share one level-local frame (inches, y down), so "the same position" on another floor
/// is the same coordinates.
public enum FloorMatching {
    /// Name of the one big room that spans a matched outline until the user splits it.
    public static let unassignedName = "Unassigned space"
    public static let stairsName = "Stairs"

    /// Interior shapes only (exterior zones and footprint never count toward a floor's outline).
    static func interior(_ shapes: [FloorShape]) -> [FloorShape] {
        shapes.filter { !$0.isExterior && !$0.spaceType.isExteriorZone }
    }

    /// The floor's true outer boundary (union of its rooms; holes dropped). Falls back to the convex hull only when
    /// the rooms don't form one connected shape. nil for a floor without rooms.
    public static func outline(of shapes: [FloorShape]) -> Polygon? {
        Clip.outerBoundary(interior(shapes).map(\.polygon))
    }

    public static func outline(of spaces: [Space]) -> Polygon? {
        outline(of: spaces.filter { $0.deletedAt == nil }.map(FloorShape.init))
    }

    public static func outline(of level: LevelDraft) -> Polygon? { outline(of: level.spaces.map(FloorShape.init)) }

    /// Stairs on the reference floor.
    public static func stairs(in shapes: [FloorShape]) -> [Polygon] {
        interior(shapes).filter { $0.spaceType == .stairs }.map(\.polygon)
    }

    /// Spaces for a new level that lines up with `reference`:
    /// - `stairs`: a copy of every stairs room at the same position ("Stairs", "Stairs 2", …),
    /// - `outline`: the rest of the reference outline as "Unassigned space" room(s) for the user to split. With
    ///   stairs inside the outline the remainder is built from the reference rooms merged together, so it tiles the
    ///   outline exactly (a stairwell in the middle leaves two pieces, since a room can't have a hole).
    /// Together they cover the reference floor's outline exactly.
    public static func matchingSpaces(reference: [FloorShape], outline: Bool, stairs: Bool,
                                      source: Space.Source = .manual) -> [SpaceDraft] {
        let rooms = interior(reference)
        guard !rooms.isEmpty else { return [] }
        let stairShapes = stairs ? rooms.filter { $0.spaceType == .stairs } : []
        var out: [SpaceDraft] = []
        for (i, s) in stairShapes.enumerated() {
            out.append(SpaceDraft(name: stairShapes.count > 1 ? "\(stairsName) \(i + 1)" : stairsName, spaceType: .stairs,
                                  polygon: s.polygon, source: source))
        }
        guard outline else { return out }
        var pieces: [Polygon]
        if stairShapes.isEmpty, let whole = Clip.outline(rooms.map(\.polygon)) {
            pieces = [whole]
        } else {
            let rest = stairShapes.isEmpty ? rooms : rooms.filter { $0.spaceType != .stairs }
            pieces = mergeAdjacent(rest.map(\.polygon))
        }
        pieces.sort { $0.area > $1.area }
        for (i, p) in pieces.enumerated() {
            out.append(SpaceDraft(name: i == 0 ? unassignedName : "\(unassignedName) \(i + 1)", spaceType: .room,
                                  polygon: p, source: source))
        }
        return out
    }

    /// A one-level draft matching `reference` (see `matchingSpaces`).
    public static func matchingLevel(reference: [FloorShape], name: String, kind: Level.Kind, sortOrder: Int,
                                     outline: Bool, stairs: Bool, source: Space.Source = .manual) -> LevelDraft {
        LevelDraft(name: name, kind: kind, sortOrder: sortOrder,
                   spaces: matchingSpaces(reference: reference, outline: outline, stairs: stairs, source: source))
    }

    /// Greedily merges polygons that share walls while the result stays one simple polygon. Deterministic.
    public static func mergeAdjacent(_ polygons: [Polygon]) -> [Polygon] {
        var ps = polygons
        var merged = true
        while merged {
            merged = false
            search: for i in ps.indices {
                for j in ps.indices where j > i && ps[i].bounds.expanded(by: 0.1).intersects(ps[j].bounds) {
                    if let u = Clip.unionAdjacent(ps[i], ps[j], minArea: Tolerance.minZoneArea) {
                        ps[i] = u
                        ps.remove(at: j)
                        merged = true
                        break search
                    }
                }
            }
        }
        return ps
    }

    /// Stairs on `reference` that have no stairs overlapping them on `target` (the editor's
    /// "Add matching stairs on <floor>" and Add floor's stairwell).
    public static func missingStairs(reference: [FloorShape], target: [FloorShape]) -> [Polygon] {
        let there = interior(target).filter { $0.spaceType == .stairs }.map(\.polygon)
        return stairs(in: reference).filter { s in !there.contains { Clip.intersectionArea($0, s) > s.area * 0.5 } }
    }

    /// Target-floor rooms that a new stairs polygon would overlap (the editor refuses or asks first).
    public static func blockers(for stairs: Polygon, on target: [Space]) -> [Space] {
        target.filter { $0.deletedAt == nil && !$0.isExterior && Clip.overlaps($0.polygon, stairs) }
    }
}

// MARK: - Exterior fallback

/// Makes sure every property can get an "Outside" level even when the address, geocode, footprint lookup or
/// network fails (founder bug: "Exterior/yard is missing"). Spec 03 FR-EXT-07 fallback, sized from the ground floor.
public enum ExteriorPlanning {
    public static let levelName = "Outside"
    /// Mirrors `HomeExterior.ExteriorSeeder.networkUnavailableTag`.
    public static let footprintUnavailableTag = "footprint-unavailable"

    /// The ground floor's outline moved so its bounding-box center sits at the level origin (the geocoded pin).
    public static func houseBlock(fromFloorOutline outline: Polygon?) -> Polygon? {
        guard let outline, outline.area >= Tolerance.minZoneArea else { return nil }
        let c = outline.bounds.center
        let moved = outline.vertices.map { Vec2(x: $0.x - c.x, y: $0.y - c.y).rounded(to: 0.01) }
        return try? Polygon(moved, minArea: Tolerance.minZoneArea)
    }

    /// Outside level with default zones around `houseOutline` (a floor outline in its own coordinates, re-centered
    /// on the origin) or, without one, the 40 × 30 ft block. Warning `.footprintFallback` ("Drag the block to match").
    public static func fallbackLevel(houseOutline: Polygon?, origin: GeoCoordinate?, seeder: any YardSeeding) -> LevelDraft {
        LevelDraft(name: levelName, kind: .exterior, sortOrder: Level.exteriorSortOrder,
                   spaces: seeder.seed(footprint: houseBlock(fromFloorOutline: houseOutline), frontDir: Vec2(0, 1), roadDistanceIn: nil),
                   georef: origin.map { GeoReference(originLat: $0.latitude, originLon: $0.longitude) },
                   warnings: [.footprintFallback])
    }

    /// The ground floor of a set of levels: sort order 0 (else the lowest non-basement floor, else any) interior level.
    public static func groundLevelIndex(_ levels: [LevelDraft]) -> Int? {
        let interior = levels.indices.filter { levels[$0].kind != .exterior && !levels[$0].spaces.isEmpty }
        return interior.first { levels[$0].sortOrder == 0 }
            ?? interior.filter { levels[$0].kind == .floor }.min { levels[$0].sortOrder < levels[$1].sortOrder }
            ?? interior.first
    }
}

extension ExteriorSeeding {
    /// Always produces a usable Outside level. With an address it runs the footprint lookup; with no address, no
    /// footprint, or a failed lookup (offline, timeout, rate limit, server error) it falls back to the ground floor's
    /// outline (or the 40 × 30 ft block) with the default yard zones, keeping the address as the geo-reference.
    public func exteriorLevelOrFallback(for address: ResolvedAddress?, groundOutline: Polygon?,
                                        yard: any YardSeeding) async -> LevelDraft {
        guard let address else {
            return ExteriorPlanning.fallbackLevel(houseOutline: groundOutline, origin: nil, seeder: yard)
        }
        let level = await exteriorLevel(for: address)
        let lookupFailed = level.warnings.contains(.other(ExteriorPlanning.footprintUnavailableTag))
        let usedFallback = level.warnings.contains(.footprintFallback)
        if !level.spaces.isEmpty && !lookupFailed && !(usedFallback && groundOutline != nil) { return level }
        var fb = ExteriorPlanning.fallbackLevel(houseOutline: groundOutline, origin: address.coordinate, seeder: yard)
        if let g = level.georef { fb.georef = g }
        return fb
    }
}
