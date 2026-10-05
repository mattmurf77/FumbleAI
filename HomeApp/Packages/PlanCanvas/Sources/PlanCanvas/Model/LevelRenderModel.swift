import Foundation
import PlanKit
import HomeCore

/// Room fill role (mapped to theme colors by the painter). LLD §7.2 theme, mockup `--room`/`--room-alt`.
public enum RoomFill: String, Hashable, Sendable {
    case room, roomAlt, footprint, lawn, hardscape, mulch, deck, water, zone

    public static func of(_ t: SpaceType, isExterior: Bool) -> RoomFill {
        switch t {
        case .closet, .stairs, .storage, .utility: return .roomAlt
        case .footprint: return .footprint
        case .frontYard, .backyard, .sideYard, .lawn: return .lawn
        case .driveway, .sidewalk, .patio: return .hardscape
        case .gardenBed: return .mulch
        case .deck, .shed: return .deck
        case .pool: return .water
        case .customZone: return .zone
        default: return isExterior ? .zone : .room
        }
    }
}

/// One room/zone, pre-computed off the per-frame path.
public struct SpaceRender: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Abbreviation for very narrow rooms ("½ Bath", "Cl.").
    public var shortName: String
    public var spaceType: SpaceType
    public var isExterior: Bool
    public var isApproximate: Bool
    public var polygon: Polygon
    public var bbox: Rect
    /// Pole of inaccessibility (label / "+" anchor) and inscribed radius, inches.
    public var pole: Vec2
    public var poleRadius: Double
    /// `13′2″ × 11′6″`, `~12′0″ × 9′6″`.
    public var dimsText: String
    /// "13 by 11 feet" for VoiceOver.
    public var spokenDims: String
    public var areaSqIn: Double
    public var fillStyle: RoomFill
    /// No "+" on stairs (mockup).
    public var allowsAdd: Bool
    /// Stairs only: tread lines and walk line (model inches), drawn over the fill. Empty for other rooms.
    public var treads: [Segment]
    /// A closet sitting inside a room (`SpaceNesting`): the room it is in. Drawn after (on top of) that room and not
    /// counted again in the floor area.
    public var hostId: UUID?

    public init(id: UUID, name: String, shortName: String, spaceType: SpaceType, isExterior: Bool, isApproximate: Bool,
                polygon: Polygon, bbox: Rect, pole: Vec2, poleRadius: Double, dimsText: String, spokenDims: String,
                areaSqIn: Double, fillStyle: RoomFill, allowsAdd: Bool, treads: [Segment] = [], hostId: UUID? = nil) {
        self.id = id; self.name = name; self.shortName = shortName; self.spaceType = spaceType; self.isExterior = isExterior
        self.isApproximate = isApproximate; self.polygon = polygon; self.bbox = bbox; self.pole = pole; self.poleRadius = poleRadius
        self.dimsText = dimsText; self.spokenDims = spokenDims; self.areaSqIn = areaSqIn; self.fillStyle = fillStyle; self.allowsAdd = allowsAdd
        self.treads = treads; self.hostId = hostId
    }
}

/// Door/window glyph drawn in a wall gap (display only).
public struct OpeningGlyph: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: Opening.Kind
    public var segment: Segment
    /// Door: hinge jamb and the unit vector the leaf swings toward (perpendicular to the wall).
    public var hinge: Vec2
    public var swingDirection: Vec2
    public var isSliding: Bool
    public var widthIn: Double { segment.length }
    /// The jamb opposite the hinge.
    public var strike: Vec2 { hinge.distance(to: segment.a) < 1e-6 ? segment.b : segment.a }
    /// Door leaf end when fully open (hinge + swing · width).
    public var leafEnd: Vec2 { hinge + swingDirection * widthIn }

    public init(id: UUID, kind: Opening.Kind, segment: Segment, hinge: Vec2, swingDirection: Vec2, isSliding: Bool) {
        self.id = id; self.kind = kind; self.segment = segment; self.hinge = hinge; self.swingDirection = swingDirection; self.isSliding = isSliding
    }
}

/// Geometry part of the render model (rebuilt on geometry change only).
public struct LevelGeometryRender: Hashable, Sendable {
    public var levelId: UUID
    public var levelName: String
    public var isExterior: Bool
    public var bounds: Rect
    public var spaces: [SpaceRender]
    public var walls: [WallSegment]
    public var openings: [OpeningGlyph]
    /// Spaces that failed to render (degenerate polygon) — logged by Diagnostics.
    public var skippedSpaceIds: [UUID]

    public init(levelId: UUID, levelName: String, isExterior: Bool, bounds: Rect, spaces: [SpaceRender], walls: [WallSegment],
                openings: [OpeningGlyph], skippedSpaceIds: [UUID] = []) {
        self.levelId = levelId; self.levelName = levelName; self.isExterior = isExterior; self.bounds = bounds
        self.spaces = spaces; self.walls = walls; self.openings = openings; self.skippedSpaceIds = skippedSpaceIds
    }

    public func space(_ id: UUID) -> SpaceRender? { spaces.first { $0.id == id } }
    public var identifiedPolygons: [IdentifiedPolygon] { spaces.map { IdentifiedPolygon(id: $0.id, polygon: $0.polygon) } }
    /// Nested closets are inside their room's polygon, so they are not added again.
    public var interiorAreaSqIn: Double { spaces.filter { !$0.isExterior && $0.hostId == nil }.reduce(0) { $0 + $1.areaSqIn } }
    public var roomCount: Int { spaces.filter { !$0.isExterior }.count }
    public var zoneCount: Int { spaces.filter { $0.isExterior && $0.spaceType != .footprint }.count }
}

/// Lens part of the render model (rebuilt on lens or stats change; geometry is reused).
public struct LensDecorations: Hashable, Sendable {
    public var lens: LensID
    public var spaces: [UUID: SpaceDecoration]
    public var pins: [PinModel]
    public var footer: FooterSummary
    /// "Whole house · N" (property scope) and "This floor · N" (level scope) chips.
    public var wholeHouseCount: Int?
    public var thisFloorCount: Int?
    public var scale: LensScale

    public init(lens: LensID, spaces: [UUID: SpaceDecoration] = [:], pins: [PinModel] = [], footer: FooterSummary = FooterSummary(primary: []),
                wholeHouseCount: Int? = nil, thisFloorCount: Int? = nil, scale: LensScale = .none) {
        self.lens = lens; self.spaces = spaces; self.pins = pins; self.footer = footer
        self.wholeHouseCount = wholeHouseCount; self.thisFloorCount = thisFloorCount; self.scale = scale
    }

    public func decoration(_ id: UUID) -> SpaceDecoration { spaces[id] ?? .plain }
}

/// Immutable snapshot the canvas draws each frame. LLD §7.2.
public struct LevelRenderModel: Hashable, Sendable {
    public var geometry: LevelGeometryRender
    public var lens: LensDecorations
    public var version: Int

    public init(geometry: LevelGeometryRender, lens: LensDecorations, version: Int = 0) {
        self.geometry = geometry; self.lens = lens; self.version = version
    }

    public var levelId: UUID { geometry.levelId }
    public var bounds: Rect { geometry.bounds }
    public var spaces: [SpaceRender] { geometry.spaces }
    public var walls: [WallSegment] { geometry.walls }
    public var openings: [OpeningGlyph] { geometry.openings }
    public var isExterior: Bool { geometry.isExterior }

    public static func empty(levelId: UUID = UUID(), name: String = "") -> LevelRenderModel {
        LevelRenderModel(geometry: LevelGeometryRender(levelId: levelId, levelName: name, isExterior: false, bounds: .null,
                                                       spaces: [], walls: [], openings: []),
                         lens: LensDecorations(lens: .plan))
    }
}
