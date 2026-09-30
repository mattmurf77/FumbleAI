import Foundation
import PlanKit

/// Room / zone type. Raw values match the SQL CHECK list. LLD §3.2 `space.space_type`.
public enum SpaceType: String, ForwardCompatibleEnum {
    case room, kitchen, bedroom, bathroom, halfBath = "half_bath", living, dining, family, office
    case laundry, closet, hall, stairs, garage, utility, mudroom, storage
    case footprint, frontYard = "front_yard", backyard, sideYard = "side_yard", driveway, sidewalk, patio, deck
    case gardenBed = "garden_bed", lawn, shed, pool, customZone = "custom_zone"
    case unknown
    public static var unknownCase: SpaceType { .unknown }

    /// Exterior zone types (drawn as fills with hairline outlines; may overlap).
    public var isExteriorZone: Bool {
        switch self {
        case .footprint, .frontYard, .backyard, .sideYard, .driveway, .sidewalk, .patio, .deck,
             .gardenBed, .lawn, .shed, .pool, .customZone: return true
        default: return false
        }
    }

    /// Default display name ("Half Bath", "Front Yard").
    public var displayName: String {
        switch self {
        case .halfBath: return "Half Bath"; case .frontYard: return "Front Yard"; case .sideYard: return "Side Yard"
        case .gardenBed: return "Garden Bed"; case .customZone: return "Zone"; case .living: return "Living Room"
        case .dining: return "Dining Room"; case .family: return "Family Room"; case .footprint: return "House"
        default: return rawValue.capitalized
        }
    }
}

/// A room or exterior zone: a simple polygon in level coordinates (inches). LLD §3.2 `space`.
public struct Space: SyncedModel {
    public static let recordType = RecordType.space
    public enum Source: String, ForwardCompatibleEnum {
        case roomplan, blocks, trace, rough, autoseed, manual, unknown
        public static var unknownCase: Source { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var levelId: UUID
    public var name: String
    public var spaceType: SpaceType
    public var isExterior: Bool
    public var polygon: Polygon
    public var source: Source
    /// Rough-in rooms: dashed walls and "~" dimensions until edited by hand.
    public var isApproximate: Bool
    public var colorHex: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, levelId: UUID, name: String, spaceType: SpaceType = .room,
                isExterior: Bool = false, polygon: Polygon, source: Source = .manual, isApproximate: Bool = false,
                colorHex: String? = nil, sortOrder: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.levelId = levelId; self.name = name; self.spaceType = spaceType
        self.isExterior = isExterior; self.polygon = polygon; self.source = source; self.isApproximate = isApproximate
        self.colorHex = colorHex; self.sortOrder = sortOrder
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Derived caches (not synced): area and bbox.
    public var areaSqIn: Double { polygon.area }
    public var bounds: Rect { polygon.bounds }
    public var scope: Scope { .space(id, level: levelId) }
    public var identifiedPolygon: IdentifiedPolygon { IdentifiedPolygon(id: id, polygon: polygon) }
}

/// Display-only door/window/opening segment. LLD §3.2 `opening`.
public struct Opening: SyncedModel {
    public static let recordType = RecordType.opening
    public enum Kind: String, ForwardCompatibleEnum {
        case door, window, opening, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public enum Swing: String, ForwardCompatibleEnum {
        case leftIn = "left_in", rightIn = "right_in", leftOut = "left_out", rightOut = "right_out", sliding, none, unknown
        public static var unknownCase: Swing { .unknown }
    }
    public enum Source: String, ForwardCompatibleEnum {
        case roomplan, manual, unknown
        public static var unknownCase: Source { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var levelId: UUID
    /// Primary room (for sheet listing).
    public var spaceId: UUID?
    public var kind: Kind
    /// Along the wall, inches.
    public var segment: Segment
    public var heightIn: Double?
    /// Windows.
    public var sillIn: Double?
    public var swing: Swing?
    public var isExteriorDoor: Bool
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, levelId: UUID, spaceId: UUID? = nil, kind: Kind = .door,
                segment: Segment, heightIn: Double? = nil, sillIn: Double? = nil, swing: Swing? = nil,
                isExteriorDoor: Bool = false, source: Source = .manual,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.levelId = levelId; self.spaceId = spaceId; self.kind = kind
        self.segment = segment; self.heightIn = heightIn; self.sillIn = sillIn; self.swing = swing
        self.isExteriorDoor = isExteriorDoor; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var widthIn: Double { segment.length }
}
