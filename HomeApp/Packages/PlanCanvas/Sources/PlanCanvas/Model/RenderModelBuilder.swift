import Foundation
import PlanKit
import HomeCore

/// Memoizes pole-of-inaccessibility results per polygon (LLD §6.7 "cached per space, keyed by polygon hash").
public final class PoleCache: @unchecked Sendable {
    private var cache: [Polygon: PolyLabel.Result] = [:]
    private let lock = NSLock()
    private let limit: Int
    public init(limit: Int = 2_000) { self.limit = limit }
    public static let shared = PoleCache()

    public func pole(of polygon: Polygon) -> PolyLabel.Result {
        lock.lock()
        if let r = cache[polygon] { lock.unlock(); return r }
        lock.unlock()
        let r = PolyLabel.pole(of: polygon, precision: 1.0)
        lock.lock()
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[polygon] = r
        lock.unlock()
        return r
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
}

/// Builds `LevelRenderModel`s from value snapshots (`LevelGeometry` + `LensStats`). Pure and synchronous so it
/// runs anywhere (tests on Linux, a detached task on device). LLD §7.2: geometry is rebuilt only when geometry
/// changes; lens decorations are rebuilt on lens/stats changes and reuse the geometry.
public enum RenderModelBuilder {

    // MARK: Geometry

    public static func geometry(_ g: LevelGeometry, unitSystem: UnitSystem = .imperial, poleCache: PoleCache = .shared) -> LevelGeometryRender {
        var spaces: [SpaceRender] = []
        var skipped: [UUID] = []
        for s in g.spaces where s.deletedAt == nil {
            let poly = s.polygon
            guard poly.count >= 3, poly.area > 1, poly.vertices.allSatisfy(\.isFinite) else { skipped.append(s.id); continue }
            let pole = poleCache.pole(of: poly)
            let bb = poly.bounds
            let dims = LensFormat.primes(HomeLengthFormatter.dimensionText(for: poly, isApproximate: s.isApproximate, system: unitSystem))
            let narrow = min(bb.width, bb.height) < ShortNames.narrowThresholdIn
            spaces.append(SpaceRender(
                id: s.id, name: s.name, shortName: narrow ? ShortNames.short(s.name) : s.name, spaceType: s.spaceType,
                isExterior: s.isExterior, isApproximate: s.isApproximate, polygon: poly, bbox: bb,
                pole: pole.point, poleRadius: pole.radius, dimsText: dims,
                spokenDims: spokenDims(poly, isApproximate: s.isApproximate, system: unitSystem),
                areaSqIn: poly.area, fillStyle: RoomFill.of(s.spaceType, isExterior: s.isExterior),
                allowsAdd: s.spaceType != .stairs,
                treads: s.spaceType == .stairs && !s.isExterior ? StairTreads.lines(for: poly) : []))
        }
        // Exterior zones draw on top of bigger zones: sort by area descending (garden bed over backyard).
        if g.level.isExterior { spaces.sort { $0.areaSqIn > $1.areaSqIn } }

        let live = g.openings.filter { $0.deletedAt == nil }
        var walls: [WallSegment] = []
        if !g.level.isExterior {
            // Closets nested inside a room draw on top of it (painter's order) and get their own thin walls.
            let hosts = SpaceNesting.hosts(spaces.filter { !$0.isExterior }.map {
                SpaceNesting.Shape(id: $0.id, spaceType: $0.spaceType, polygon: $0.polygon)
            })
            if !hosts.isEmpty {
                for i in spaces.indices { spaces[i].hostId = hosts[spaces[i].id] }
                let order = Dictionary(uniqueKeysWithValues: spaces.enumerated().map { ($1.id, $0) })
                spaces.sort { ($0.hostId == nil ? 0 : 1, order[$0.id]!) < ($1.hostId == nil ? 0 : 1, order[$1.id]!) }
            }
            let interior = spaces.filter { !$0.isExterior && $0.hostId == nil }
            walls = WallDerivation.walls(spaces: interior.map { IdentifiedPolygon(id: $0.id, polygon: $0.polygon) },
                                         openings: live.map(\.segment))
            for c in spaces where c.hostId != nil {
                if let host = spaces.first(where: { $0.id == c.hostId }) {
                    walls += nestedWalls(c, in: host, openings: live.map(\.segment))
                }
            }
        }
        let openings = live.compactMap { glyph(for: $0, spaces: spaces) }
        let bounds = spaces.reduce(Rect.null) { $0.union($1.bbox) }
        return LevelGeometryRender(levelId: g.level.id, levelName: g.level.name, isExterior: g.level.isExterior,
                                   bounds: bounds, spaces: spaces, walls: walls, openings: openings, skippedSpaceIds: skipped)
    }

    /// Interior walls of a closet nested in `host`: its edges that don't lie on one of the host's walls (those are
    /// already drawn as the room's wall), with door/window gaps.
    static func nestedWalls(_ closet: SpaceRender, in host: SpaceRender, openings: [Segment]) -> [WallSegment] {
        let hostEdges = [IdentifiedPolygon(id: host.id, polygon: host.polygon)]
        let ids = [closet.id, host.id].sorted { $0.uuidString < $1.uuidString }
        return WallDerivation.walls(spaces: [IdentifiedPolygon(id: closet.id, polygon: closet.polygon)], openings: openings)
            .filter { WallDerivation.coincidentEdges(of: $0.seg, excluding: closet.id, in: hostEdges).isEmpty }
            .map { WallSegment(seg: $0.seg, kind: .interior, thicknessIn: WallSegment.interiorThickness, gaps: $0.gaps, spaceIds: ids) }
    }

    /// "13 by 11 feet" / "about 12 by 9 feet" / "4 by 3 meters".
    public static func spokenDims(_ p: Polygon, isApproximate: Bool, system: UnitSystem) -> String {
        let size: (Double, Double)
        var approx = isApproximate
        if let r = p.rectangleSize { size = (r.width, r.height) } else { size = (p.bounds.width, p.bounds.height); approx = true }
        let prefix = approx ? "about " : ""
        if system == .metric {
            let a = size.0 / HomeLengthFormatter.inchesPerMeter, b = size.1 / HomeLengthFormatter.inchesPerMeter
            return "\(prefix)\(String(format: "%.1f", a)) by \(String(format: "%.1f", b)) meters"
        }
        return "\(prefix)\(Int((size.0 / 12).rounded())) by \(Int((size.1 / 12).rounded())) feet"
    }

    /// Door swing/window glyph. `*_in` swings into the opening's room, `*_out` away from it; `left*` hinges at
    /// `segment.a`, `right*` at `segment.b`.
    public static func glyph(for o: Opening, spaces: [SpaceRender]) -> OpeningGlyph? {
        guard o.segment.length > 1e-3, o.kind != .unknown else { return nil }
        let seg = o.segment
        let n = seg.direction.perpendicular
        // Which side is "in": the side where the opening's room lies (fallback: any containing space).
        var inward = n
        let probe = seg.midpoint + n * 6
        let room = o.spaceId.flatMap { id in spaces.first { $0.id == id } }
        if let room {
            inward = room.polygon.contains(probe) ? n : -n
        } else if !spaces.contains(where: { $0.polygon.contains(probe) }) {
            inward = -n
        }
        let swing = o.swing ?? .leftIn
        let hingeAtA: Bool
        var dir = inward
        switch swing {
        case .leftIn: hingeAtA = true
        case .rightIn: hingeAtA = false
        case .leftOut: hingeAtA = true; dir = -inward
        case .rightOut: hingeAtA = false; dir = -inward
        case .sliding, .none, .unknown: hingeAtA = true
        }
        let sliding = swing == .sliding || swing == .none || o.kind != .door
        return OpeningGlyph(id: o.id, kind: o.kind, segment: seg, hinge: hingeAtA ? seg.a : seg.b,
                            swingDirection: dir, isSliding: sliding)
    }

    // MARK: Lens

    /// Fills the geometry-derived fields of the context.
    public static func context(_ base: LensContext, geometry: LevelGeometryRender) -> LensContext {
        var c = base
        c.isExterior = geometry.isExterior
        if c.levelName.isEmpty { c.levelName = geometry.levelName }
        c.roomCount = geometry.roomCount
        c.interiorAreaSqIn = geometry.interiorAreaSqIn
        c.zoneCount = geometry.zoneCount
        c.lotAreaSqIn = geometry.isExterior ? geometry.bounds.area : 0
        return c
    }

    public static func decorations(lens id: LensID, stats: LensStats?, geometry: LevelGeometryRender, context base: LensContext) -> LensDecorations {
        let lens = LensRegistry.lens(for: id)
        let ctx = context(base, geometry: geometry)
        let stats = stats ?? LensStats(levelId: geometry.levelId, today: LocalDate(1970, 1, 1),
                                       roomCount: geometry.roomCount, interiorAreaSqIn: geometry.interiorAreaSqIn)
        let scale = lens.scale(stats, context: ctx)
        var per: [UUID: SpaceDecoration] = [:]
        for s in geometry.spaces {
            var d = lens.decoration(stats.stats(for: s.id), scale: scale, context: ctx)
            // VoiceOver: dimensions first, then the lens value (FR-CNV-50).
            d.accessibilityValue = [s.spokenDims, d.accessibilityValue].filter { !$0.isEmpty }.joined(separator: ", ")
            per[s.id] = d
        }
        let whole = lens.scopeCount(stats.propertyScope)
        let floor = lens.scopeCount(stats.levelScope)
        return LensDecorations(lens: id, spaces: per, pins: lens.pins(stats, geometry: geometry),
                               footer: lens.footer(stats, context: ctx),
                               wholeHouseCount: (whole ?? 0) > 0 ? whole : nil,
                               thisFloorCount: (floor ?? 0) > 0 ? floor : nil, scale: scale)
    }

    // MARK: Whole model

    public static func build(geometry g: LevelGeometry, stats: LensStats?, lens: LensID, context: LensContext,
                             unitSystem: UnitSystem? = nil, version: Int = 0, poleCache: PoleCache = .shared) -> LevelRenderModel {
        let geo = geometry(g, unitSystem: unitSystem ?? context.unitSystem, poleCache: poleCache)
        return LevelRenderModel(geometry: geo, lens: decorations(lens: lens, stats: stats, geometry: geo, context: context), version: version)
    }

    /// Lens/stats change: keep geometry, rebuild decorations.
    public static func rebuildingLens(_ model: LevelRenderModel, lens: LensID, stats: LensStats?, context: LensContext) -> LevelRenderModel {
        LevelRenderModel(geometry: model.geometry,
                         lens: decorations(lens: lens, stats: stats, geometry: model.geometry, context: context),
                         version: model.version + 1)
    }
}
