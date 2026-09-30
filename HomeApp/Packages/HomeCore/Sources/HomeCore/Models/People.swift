import Foundation
import PlanKit

/// A housemate (assignee / owner). LLD §3.2 `person`.
public struct Person: SyncedModel {
    public static let recordType = RecordType.person
    public var id: UUID
    public var propertyId: UUID
    public var name: String
    public var colorHex: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, name: String, colorHex: String? = nil, sortOrder: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.name = name; self.colorHex = colorHex; self.sortOrder = sortOrder
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// A nested storage location inside a room ("Shelf 2", "Bin 'Winter – Matt'"). LLD §3.2 `storage_spot`, §11.
public struct StorageSpot: SyncedModel {
    public static let recordType = RecordType.storageSpot
    /// Maximum nesting depth enforced by the tree queries (§11.1).
    public static let maxDepth = 32
    public var id: UUID
    public var propertyId: UUID
    public var spaceId: UUID
    /// nil = top level in the space.
    public var parentSpotId: UUID?
    public var name: String
    public var ownerId: UUID?
    /// Optional pin on the plan (inches).
    public var pin: Vec2?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, spaceId: UUID, parentSpotId: UUID? = nil, name: String,
                ownerId: UUID? = nil, pin: Vec2? = nil, sortOrder: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.spaceId = spaceId; self.parentSpotId = parentSpotId
        self.name = name; self.ownerId = ownerId; self.pin = pin; self.sortOrder = sortOrder
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// Optional width/depth/height in inches.
public struct Dims3: Hashable, Codable, Sendable {
    public var width: Double?
    public var depth: Double?
    public var height: Double?
    public init(width: Double? = nil, depth: Double? = nil, height: Double? = nil) { self.width = width; self.depth = depth; self.height = height }
    public static let empty = Dims3()
    public var isEmpty: Bool { width == nil && depth == nil && height == nil }
    public var known: [Double] { [width, depth, height].compactMap { $0 } }
    /// "32 × 40 in" style text (known dims only).
    public func formatted(system: UnitSystem = .imperial) -> String {
        known.map { HomeLengthFormatter.formatInches($0, system: system) }.joined(separator: " × ")
    }
}

/// A measurement: an opening, wall, door, window, zone or general spot. LLD §3.2 `measurement`.
/// Named `Measurement` in the LLD; renamed because `Foundation.Measurement` makes the bare name ambiguous in every
/// module that imports both Foundation and HomeCore.
public struct HomeMeasurement: SyncedModel {
    public static let recordType = RecordType.measurement
    public enum Kind: String, ForwardCompatibleEnum {
        case opening, wall, door, window, zone, general, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public enum Source: String, ForwardCompatibleEnum {
        case manual, roomplan, planEdit = "plan_edit", measureApp = "measure_app", unknown
        public static var unknownCase: Source { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    /// "Fridge opening", "Front bed".
    public var label: String
    public var kind: Kind
    /// At least one of spaceId / openingId is set (SQL CHECK).
    public var spaceId: UUID?
    public var openingId: UUID?
    public var storageSpotId: UUID?
    public var pin: Vec2?
    /// kind == .wall: the edge it describes.
    public var segment: Segment?
    /// At least one dimension is set; each > 0.
    public var dims: Dims3
    /// Checked by pass-through fit (§10).
    public var isDeliveryPath: Bool
    public var note: String?
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, label: String, kind: Kind = .general, spaceId: UUID? = nil,
                openingId: UUID? = nil, storageSpotId: UUID? = nil, pin: Vec2? = nil, segment: Segment? = nil,
                dims: Dims3, isDeliveryPath: Bool = false, note: String? = nil, source: Source = .manual,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.label = label; self.kind = kind; self.spaceId = spaceId
        self.openingId = openingId; self.storageSpotId = storageSpotId; self.pin = pin; self.segment = segment
        self.dims = dims; self.isDeliveryPath = isDeliveryPath; self.note = note; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Validates the SQL CHECKs (anchor present, ≥ 1 positive dimension).
    public var isValid: Bool {
        (spaceId != nil || openingId != nil) && !dims.isEmpty && dims.known.allSatisfy { $0 > 0 }
    }
}
