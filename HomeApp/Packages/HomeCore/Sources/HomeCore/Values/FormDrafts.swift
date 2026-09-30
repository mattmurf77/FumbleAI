import Foundation
import PlanKit

/// Input for `ChoreRepository.create`. `nextDueOn` is derived with `RecurrenceEngine.firstDue`.
public struct ChoreDraft: Hashable, Codable, Sendable {
    public var propertyId: UUID
    public var scope: Scope
    public var title: String
    public var notes: String?
    public var assigneeId: UUID?
    public var repeatRule: RepeatRule?
    public var startOn: LocalDate
    public var dueMinutes: MinuteOfDay?
    public var remindEnabled: Bool
    public var remindOffsetMin: Int
    public var calendarEnabled: Bool
    public var linkedThingId: UUID?
    public init(propertyId: UUID, scope: Scope, title: String, notes: String? = nil, assigneeId: UUID? = nil,
                repeatRule: RepeatRule? = nil, startOn: LocalDate, dueMinutes: MinuteOfDay? = nil,
                remindEnabled: Bool = false, remindOffsetMin: Int = 0, calendarEnabled: Bool = false, linkedThingId: UUID? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.title = title; self.notes = notes; self.assigneeId = assigneeId
        self.repeatRule = repeatRule; self.startOn = startOn; self.dueMinutes = dueMinutes; self.remindEnabled = remindEnabled
        self.remindOffsetMin = remindOffsetMin; self.calendarEnabled = calendarEnabled; self.linkedThingId = linkedThingId
    }
}

/// Input for `ProjectRepository.create` ("Future Project" or "Past Work" — the latter uses status .done).
public struct ProjectDraft: Hashable, Codable, Sendable {
    public var propertyId: UUID
    public var scope: Scope
    public var title: String
    public var notes: String?
    public var status: Project.Status
    public var priority: Int?
    public var estCost: Money?
    public var actualCost: Money?
    public var estHours: Double?
    public var actualHours: Double?
    public var targetOn: LocalDate?
    /// Required when status == .done.
    public var completedOn: LocalDate?
    public var vendor: String?
    public var spawnedFromChoreId: UUID?
    public init(propertyId: UUID, scope: Scope, title: String, notes: String? = nil, status: Project.Status = .idea,
                priority: Int? = nil, estCost: Money? = nil, actualCost: Money? = nil, estHours: Double? = nil,
                actualHours: Double? = nil, targetOn: LocalDate? = nil, completedOn: LocalDate? = nil,
                vendor: String? = nil, spawnedFromChoreId: UUID? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.title = title; self.notes = notes; self.status = status
        self.priority = priority; self.estCost = estCost; self.actualCost = actualCost; self.estHours = estHours
        self.actualHours = actualHours; self.targetOn = targetOn; self.completedOn = completedOn; self.vendor = vendor
        self.spawnedFromChoreId = spawnedFromChoreId
    }
}

/// Input for `ThingRepository.create`.
public struct ThingDraft: Hashable, Codable, Sendable {
    public var propertyId: UUID
    public var scope: Scope
    public var category: Thing.Category
    public var name: String
    public var ownership: Thing.Ownership
    public var templateKey: String?
    public var attributes: [String: JSONValue]
    public var brand: String?
    public var model: String?
    public var serial: String?
    public var purchaseDate: LocalDate?
    public var purchasePrice: Money?
    public var warrantyEnd: LocalDate?
    public var dims: Dims3
    public var fitMeasurementId: UUID?
    public var pin: Vec2?
    public var notes: String?
    public init(propertyId: UUID, scope: Scope, category: Thing.Category, name: String, ownership: Thing.Ownership = .owned,
                templateKey: String? = nil, attributes: [String: JSONValue] = [:], brand: String? = nil, model: String? = nil,
                serial: String? = nil, purchaseDate: LocalDate? = nil, purchasePrice: Money? = nil, warrantyEnd: LocalDate? = nil,
                dims: Dims3 = .empty, fitMeasurementId: UUID? = nil, pin: Vec2? = nil, notes: String? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.category = category; self.name = name; self.ownership = ownership
        self.templateKey = templateKey; self.attributes = attributes; self.brand = brand; self.model = model; self.serial = serial
        self.purchaseDate = purchaseDate; self.purchasePrice = purchasePrice; self.warrantyEnd = warrantyEnd; self.dims = dims
        self.fitMeasurementId = fitMeasurementId; self.pin = pin; self.notes = notes
    }
}

/// Input for `InventoryRepository.create`. When `storageSpotId` is set the repository derives the scope
/// from the spot's room.
public struct InventoryDraft: Hashable, Codable, Sendable {
    public var propertyId: UUID
    public var kind: InventoryItem.Kind
    public var name: String
    public var category: String?
    public var ownerId: UUID?
    public var scope: Scope
    public var storageSpotId: UUID?
    public var quantity: Double
    public var unit: String?
    public var season: Season?
    public var inRotation: Bool?
    public var expiresOn: LocalDate?
    public var isLow: Bool
    public var lowThreshold: Double?
    public var linkedThingId: UUID?
    public var notes: String?
    public init(propertyId: UUID, kind: InventoryItem.Kind, name: String, category: String? = nil, ownerId: UUID? = nil,
                scope: Scope, storageSpotId: UUID? = nil, quantity: Double = 1, unit: String? = nil, season: Season? = nil,
                inRotation: Bool? = nil, expiresOn: LocalDate? = nil, isLow: Bool = false, lowThreshold: Double? = nil,
                linkedThingId: UUID? = nil, notes: String? = nil) {
        self.propertyId = propertyId; self.kind = kind; self.name = name; self.category = category; self.ownerId = ownerId
        self.scope = scope; self.storageSpotId = storageSpotId; self.quantity = quantity; self.unit = unit; self.season = season
        self.inRotation = inRotation; self.expiresOn = expiresOn; self.isLow = isLow; self.lowThreshold = lowThreshold
        self.linkedThingId = linkedThingId; self.notes = notes
    }
}

/// Input for `MeasurementRepository.create`.
public struct MeasurementInput: Hashable, Codable, Sendable {
    public var propertyId: UUID
    public var label: String
    public var kind: HomeMeasurement.Kind
    public var spaceId: UUID?
    public var openingId: UUID?
    public var storageSpotId: UUID?
    public var pin: Vec2?
    public var segment: Segment?
    public var dims: Dims3
    public var isDeliveryPath: Bool
    public var note: String?
    public var source: HomeMeasurement.Source
    public init(propertyId: UUID, label: String, kind: HomeMeasurement.Kind = .general, spaceId: UUID? = nil, openingId: UUID? = nil,
                storageSpotId: UUID? = nil, pin: Vec2? = nil, segment: Segment? = nil, dims: Dims3, isDeliveryPath: Bool = false,
                note: String? = nil, source: HomeMeasurement.Source = .manual) {
        self.propertyId = propertyId; self.label = label; self.kind = kind; self.spaceId = spaceId; self.openingId = openingId
        self.storageSpotId = storageSpotId; self.pin = pin; self.segment = segment; self.dims = dims
        self.isDeliveryPath = isDeliveryPath; self.note = note; self.source = source
    }
}

/// A geometry change for `PlanRepository.updateSpaces` (validated together, welded on commit).
public enum SpaceChange: Hashable, Sendable {
    case insert(Space)
    case update(Space)
    /// Soft-delete; items scoped to the room move to `reassignItemsTo` (FR-SES-61).
    case delete(UUID, reassignItemsTo: Scope)
}

/// Spaces + openings of one level (the canvas render input). LLD §14 `LevelGeometry`.
public struct LevelGeometry: Hashable, Sendable {
    public var level: Level
    public var spaces: [Space]
    public var openings: [Opening]
    public init(level: Level, spaces: [Space], openings: [Opening]) { self.level = level; self.spaces = spaces; self.openings = openings }
    public var interiorSpaces: [Space] { spaces.filter { !$0.isExterior } }
    public var bounds: Rect { spaces.reduce(Rect.null) { $0.union($1.bounds) } }
    public var totalAreaSqIn: Double { interiorSpaces.reduce(0) { $0 + $1.areaSqIn } }
}

public enum RepositoryError: Error, Hashable, Sendable {
    case notFound(RecordRef)
    case invalid(String)
    /// Level rule: interior spaces overlap by more than 1 sq in (§6.2 rule 7).
    case overlap([UUID])
    case invalidPolygon(PolygonError)
    /// Re-parent would create a cycle or move across rooms (§11.2).
    case cycle
}
