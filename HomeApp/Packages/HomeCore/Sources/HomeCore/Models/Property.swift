import Foundation
import PlanKit

/// Postal address columns of `property`.
public struct PostalAddressLite: Hashable, Codable, Sendable {
    public var line: String?
    public var locality: String?
    public var region: String?
    public var postalCode: String?
    /// ISO 3166-1 alpha-2.
    public var countryCode: String?
    public init(line: String? = nil, locality: String? = nil, region: String? = nil, postalCode: String? = nil, countryCode: String? = nil) {
        self.line = line; self.locality = locality; self.region = region; self.postalCode = postalCode; self.countryCode = countryCode
    }
    public var singleLine: String { [line, locality, [region, postalCode].compactMap { $0 }.joined(separator: " ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
}

/// The home. v1 UI shows one property; the schema allows more. LLD §3.2 `property`.
public struct Property: SyncedModel {
    public static let recordType = RecordType.property
    public var id: UUID
    public var name: String
    public var address: PostalAddressLite?
    public var latitude: Double?
    public var longitude: Double?
    public var yearBuilt: Int?
    public var approxSqFt: Int?
    /// Synced default floor (HLD §9-14). Fallback: the level with sort_order 0.
    public var defaultLevelId: UUID?
    public var currencyCode: String
    public var unitSystem: UnitSystem
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var propertyId: UUID { id }

    public init(id: UUID = UUID(), name: String = "My Home", address: PostalAddressLite? = nil,
                latitude: Double? = nil, longitude: Double? = nil, yearBuilt: Int? = nil, approxSqFt: Int? = nil,
                defaultLevelId: UUID? = nil, currencyCode: String = "USD", unitSystem: UnitSystem = .imperial,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.address = address; self.latitude = latitude; self.longitude = longitude
        self.yearBuilt = yearBuilt; self.approxSqFt = approxSqFt; self.defaultLevelId = defaultLevelId
        self.currencyCode = currencyCode; self.unitSystem = unitSystem
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var coordinate: GeoCoordinate? {
        guard let latitude, let longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// CloudKit zone name for this property: `property-<uuid>`. LLD §5.1.
    public var zoneName: String { Property.zoneName(for: id) }
    public static func zoneName(for id: UUID) -> String { "property-" + id.uuidString.lowercased() }
}

/// A floor (or basement/attic/exterior). LLD §3.2 `level`.
public struct Level: SyncedModel {
    public static let recordType = RecordType.level
    public enum Kind: String, ForwardCompatibleEnum {
        case floor, basement, attic, exterior, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    /// "1st Floor", "Basement", "Outside".
    public var name: String
    public var kind: Kind
    /// Elevation index: basement -1, ground 0, 2nd 1, attic 2; exterior 100.
    public var sortOrder: Int
    public var underlayAttachmentId: UUID?
    public var underlayTransform: UnderlayTransform?
    public var underlayVisible: Bool
    /// Exterior only.
    public var georef: GeoReference?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public static let exteriorSortOrder = 100

    public init(id: UUID = UUID(), propertyId: UUID, name: String, kind: Kind = .floor, sortOrder: Int = 0,
                underlayAttachmentId: UUID? = nil, underlayTransform: UnderlayTransform? = nil, underlayVisible: Bool = true,
                georef: GeoReference? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.name = name; self.kind = kind; self.sortOrder = sortOrder
        self.underlayAttachmentId = underlayAttachmentId; self.underlayTransform = underlayTransform
        self.underlayVisible = underlayVisible; self.georef = georef
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var isExterior: Bool { kind == .exterior }
}

public extension Array where Element == Level {
    /// Levels ordered for the floor pills (by `sortOrder`, exterior last).
    var sortedForPills: [Level] { sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }

    /// Resolves the default level: `property.defaultLevelId` if it exists, else sort_order 0, else the lowest
    /// non-basement floor, else the first. (Spec 09 edge case.)
    func defaultLevel(preferred: UUID?) -> Level? {
        let live = filter { $0.deletedAt == nil }
        if let p = preferred, let l = live.first(where: { $0.id == p }) { return l }
        if let g = live.first(where: { $0.sortOrder == 0 && $0.kind != .exterior }) { return g }
        return live.filter { $0.kind == .floor }.min { $0.sortOrder < $1.sortOrder } ?? live.sortedForPills.first
    }
}
