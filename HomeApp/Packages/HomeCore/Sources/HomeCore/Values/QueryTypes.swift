import Foundation
import PlanKit

// MARK: - Lens stats (LLD §7.4–7.5)

/// Per-scope counters feeding every lens (one struct so each lens reads what it needs).
public struct ScopeStats: Hashable, Codable, Sendable {
    // To-Dos
    public var overdue: Int = 0
    public var dueToday: Int = 0
    /// Due within [today, today+6].
    public var dueWeek: Int = 0
    public var openChores: Int = 0
    // Future / Past / Budget
    public var rollup: Rollup = .zero
    // Things (owned only in counts; planned counted separately)
    public var thingCount: Int = 0
    public var plannedThingCount: Int = 0
    public var warrantiesEndingSoon: Int = 0
    // Inventory
    public var inventoryCount: Int = 0
    public var lowCount: Int = 0
    public var expiringCount: Int = 0
    public init() {}
}

public struct ThingPin: Hashable, Codable, Sendable, Identifiable {
    public var thingId: UUID
    public var spaceId: UUID?
    public var templateKey: String?
    public var category: Thing.Category
    public var ownership: Thing.Ownership
    /// nil → shown in a row under the room label.
    public var pin: Vec2?
    public var symbol: String
    public var id: UUID { thingId }
    public init(thingId: UUID, spaceId: UUID?, templateKey: String?, category: Thing.Category, ownership: Thing.Ownership, pin: Vec2?, symbol: String) {
        self.thingId = thingId; self.spaceId = spaceId; self.templateKey = templateKey; self.category = category
        self.ownership = ownership; self.pin = pin; self.symbol = symbol
    }
}

public struct SpotPin: Hashable, Codable, Sendable, Identifiable {
    public var spotId: UUID
    public var spaceId: UUID
    public var pin: Vec2
    /// Items in the spot's subtree.
    public var itemCount: Int
    public var id: UUID { spotId }
    public init(spotId: UUID, spaceId: UUID, pin: Vec2, itemCount: Int) { self.spotId = spotId; self.spaceId = spaceId; self.pin = pin; self.itemCount = itemCount }
}

/// Everything the lenses need for one level on one day. Built by `LensStatsService`.
public struct LensStats: Hashable, Codable, Sendable {
    public var levelId: UUID
    public var today: LocalDate
    /// Per space on this level.
    public var spaces: [UUID: ScopeStats]
    /// Level-scope items ("This floor" chip).
    public var levelScope: ScopeStats
    /// Rooms + level scope (footer strip).
    public var floorTotal: ScopeStats
    /// Property-scope items ("Whole house" chip).
    public var propertyScope: ScopeStats
    /// Whole property (Budget footer "Home: …").
    public var propertyTotal: ScopeStats
    public var thingPins: [ThingPin]
    public var spotPins: [SpotPin]
    /// Interior rooms on the level and their total area (Plan lens footer).
    public var roomCount: Int
    public var interiorAreaSqIn: Double

    public init(levelId: UUID, today: LocalDate, spaces: [UUID: ScopeStats] = [:], levelScope: ScopeStats = .init(),
                floorTotal: ScopeStats = .init(), propertyScope: ScopeStats = .init(), propertyTotal: ScopeStats = .init(),
                thingPins: [ThingPin] = [], spotPins: [SpotPin] = [], roomCount: Int = 0, interiorAreaSqIn: Double = 0) {
        self.levelId = levelId; self.today = today; self.spaces = spaces; self.levelScope = levelScope
        self.floorTotal = floorTotal; self.propertyScope = propertyScope; self.propertyTotal = propertyTotal
        self.thingPins = thingPins; self.spotPins = spotPins; self.roomCount = roomCount; self.interiorAreaSqIn = interiorAreaSqIn
    }

    public func stats(for spaceId: UUID) -> ScopeStats { spaces[spaceId] ?? ScopeStats() }
}

// MARK: - Inventory queries (LLD §11)

/// A node of the storage-spot tree in one room.
public struct SpotNode: Hashable, Codable, Sendable, Identifiable {
    public var spot: StorageSpot
    public var depth: Int
    /// "Shelf 2 › Bin Winter – Matt" (without the room).
    public var path: String
    /// Items directly in this spot.
    public var itemCount: Int
    /// Items in this spot and all descendants.
    public var subtreeItemCount: Int
    public var children: [SpotNode]
    public var id: UUID { spot.id }
    public init(spot: StorageSpot, depth: Int, path: String, itemCount: Int, subtreeItemCount: Int, children: [SpotNode]) {
        self.spot = spot; self.depth = depth; self.path = path; self.itemCount = itemCount
        self.subtreeItemCount = subtreeItemCount; self.children = children
    }
}

/// Where an item is: "Attic › Shelf 2 › Bin Winter – Matt (Matt)". §11.3.
public struct ItemLocation: Hashable, Codable, Sendable, Identifiable {
    public var itemId: UUID
    public var name: String
    public var owner: String?
    public var room: String?
    public var floor: String?
    public var spotPath: String?
    public var levelId: UUID?
    public var spaceId: UUID?
    public var spotId: UUID?
    public var id: UUID { itemId }
    public init(itemId: UUID, name: String, owner: String?, room: String?, floor: String?, spotPath: String?,
                levelId: UUID?, spaceId: UUID?, spotId: UUID?) {
        self.itemId = itemId; self.name = name; self.owner = owner; self.room = room; self.floor = floor
        self.spotPath = spotPath; self.levelId = levelId; self.spaceId = spaceId; self.spotId = spotId
    }
    /// "<room> › <spot path>" (or room, floor, "Whole house").
    public var displayPath: String {
        if let room { return [room, spotPath].compactMap { $0 }.joined(separator: " › ") }
        return floor ?? "Whole house"
    }
}

public struct SwapLine: Hashable, Codable, Sendable, Identifiable {
    public var itemId: UUID
    public var name: String
    public var category: String?
    public var owner: String?
    public var room: String?
    public var spotPath: String?
    public var id: UUID { itemId }
    public init(itemId: UUID, name: String, category: String?, owner: String?, room: String?, spotPath: String?) {
        self.itemId = itemId; self.name = name; self.category = category; self.owner = owner; self.room = room; self.spotPath = spotPath
    }
}

/// Seasonal swap (§11.4): "Get out" = upcoming season & stored; "Put away" = opposite season & in rotation.
public struct SeasonalSwap: Hashable, Codable, Sendable {
    public var upcoming: Season
    public var getOut: [SwapLine]
    public var putAway: [SwapLine]
    public init(upcoming: Season, getOut: [SwapLine], putAway: [SwapLine]) { self.upcoming = upcoming; self.getOut = getOut; self.putAway = putAway }
}

/// Shopping list line (§11.5).
public struct ShoppingLine: Hashable, Codable, Sendable, Identifiable {
    public enum Reason: String, Codable, Hashable, Sendable { case low, replacementDue = "replacement_due" }
    public var reason: Reason
    /// `.inventory(id)` for low items, `.thing(id)` for replacements due.
    public var ref: ItemRef
    public var label: String
    public var quantity: Double?
    public var unit: String?
    public var id: String { "\(reason.rawValue):\(ref.id)" }
    public init(reason: Reason, ref: ItemRef, label: String, quantity: Double? = nil, unit: String? = nil) {
        self.reason = reason; self.ref = ref; self.label = label; self.quantity = quantity; self.unit = unit
    }
}

// MARK: - Queries

/// Filter for chore lists.
public struct ChoreQuery: Hashable, Sendable {
    public var propertyId: UUID
    /// nil = any scope; `.space(s, _)` = that room; `.level(l)` = level-scope only; `.property` = property-scope only.
    public var scope: Scope?
    /// Everything on a level (rooms + level scope).
    public var levelId: UUID?
    public var includeClosed: Bool
    public var includePaused: Bool
    public var linkedThingId: UUID?
    public var assigneeId: UUID?
    public init(propertyId: UUID, scope: Scope? = nil, levelId: UUID? = nil, includeClosed: Bool = false,
                includePaused: Bool = true, linkedThingId: UUID? = nil, assigneeId: UUID? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.levelId = levelId; self.includeClosed = includeClosed
        self.includePaused = includePaused; self.linkedThingId = linkedThingId; self.assigneeId = assigneeId
    }
}

public struct ProjectQuery: Hashable, Sendable {
    public var propertyId: UUID
    public var scope: Scope?
    public var levelId: UUID?
    /// nil = all statuses.
    public var statuses: Set<Project.Status>?
    public init(propertyId: UUID, scope: Scope? = nil, levelId: UUID? = nil, statuses: Set<Project.Status>? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.levelId = levelId; self.statuses = statuses
    }
    public static func future(_ propertyId: UUID) -> ProjectQuery { ProjectQuery(propertyId: propertyId, statuses: [.idea, .planned, .inProgress]) }
    public static func past(_ propertyId: UUID) -> ProjectQuery { ProjectQuery(propertyId: propertyId, statuses: [.done]) }
}

public struct ThingQuery: Hashable, Sendable {
    public var propertyId: UUID
    public var scope: Scope?
    public var levelId: UUID?
    public var category: Thing.Category?
    public var ownership: Thing.Ownership?
    public init(propertyId: UUID, scope: Scope? = nil, levelId: UUID? = nil, category: Thing.Category? = nil, ownership: Thing.Ownership? = nil) {
        self.propertyId = propertyId; self.scope = scope; self.levelId = levelId; self.category = category; self.ownership = ownership
    }
}

public struct InventoryQuery: Hashable, Sendable {
    public var propertyId: UUID
    public var scope: Scope?
    public var levelId: UUID?
    /// Items in this spot's subtree.
    public var spotId: UUID?
    public var kind: InventoryItem.Kind?
    public var ownerId: UUID?
    public var lowOnly: Bool
    public init(propertyId: UUID, scope: Scope? = nil, levelId: UUID? = nil, spotId: UUID? = nil,
                kind: InventoryItem.Kind? = nil, ownerId: UUID? = nil, lowOnly: Bool = false) {
        self.propertyId = propertyId; self.scope = scope; self.levelId = levelId; self.spotId = spotId
        self.kind = kind; self.ownerId = ownerId; self.lowOnly = lowOnly
    }
}

/// Shared scope-matching helper for queries: exact scope match, or "anything on level".
public func scopeMatches(_ itemScope: Scope, scope: Scope?, levelId: UUID?) -> Bool {
    if let scope, itemScope != scope { return false }
    if let levelId, itemScope.levelId != levelId { return false }
    return true
}

// MARK: - Search (LLD §12)

public enum SearchEntityType: String, Codable, Hashable, Sendable, CaseIterable {
    case chore, project, thing, inventoryItem = "inventory_item", measurement, space, storageSpot = "storage_spot"
    public var displayName: String {
        switch self {
        case .chore: return "To-Dos"; case .project: return "Projects"; case .thing: return "Appliances, Electronics & Furniture"
        case .inventoryItem: return "Inventory"; case .measurement: return "Measurements"; case .space: return "Rooms"
        case .storageSpot: return "Storage spots"
        }
    }
}

public struct SearchHit: Hashable, Codable, Sendable, Identifiable {
    public var entityType: SearchEntityType
    public var entityId: UUID
    public var title: String
    /// "Kitchen · 1st Floor", "Attic › Shelf 2 › Bin 3 · 2nd Floor".
    public var location: String?
    public var snippet: String?
    public var people: String?
    /// bm25 rank — lower is better.
    public var rank: Double
    public var id: String { "\(entityType.rawValue):\(entityId)" }
    public init(entityType: SearchEntityType, entityId: UUID, title: String, location: String? = nil,
                snippet: String? = nil, people: String? = nil, rank: Double = 0) {
        self.entityType = entityType; self.entityId = entityId; self.title = title; self.location = location
        self.snippet = snippet; self.people = people; self.rank = rank
    }

    public var itemRef: ItemRef? {
        switch entityType {
        case .chore: return .chore(entityId); case .project: return .project(entityId); case .thing: return .thing(entityId)
        case .inventoryItem: return .inventory(entityId); case .measurement: return .measurement(entityId)
        case .space, .storageSpot: return nil
        }
    }

    /// FR-SES-05: the "where is" answer card applies when the top hit is an inventory item or storage spot with a location.
    public var qualifiesForWhereIsCard: Bool {
        (entityType == .inventoryItem || entityType == .storageSpot) && !(location ?? "").isEmpty
    }
}

/// Query normalization shared by FTS (HomeStore) and the in-memory search (LLD §12.2 steps 1–3).
public enum SearchQuery {
    /// NFKC + lowercase, strip `"*():^-+`, split on whitespace, drop empties.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
        let stripped = String(folded.map { "\"*():^-+".contains($0) ? " " : $0 })
        return stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// FTS5 MATCH expression: `"tok"*` terms joined by space (AND) or " OR ".
    public static func ftsExpression(_ text: String, any: Bool = false) -> String? {
        let t = tokens(text)
        guard !t.isEmpty else { return nil }
        return t.map { "\"\($0)\"*" }.joined(separator: any ? " OR " : " ")
    }
}

// MARK: - Fit (LLD §10)

public struct FitReport: Hashable, Sendable, Identifiable {
    public enum Role: String, Hashable, Sendable { case target, deliveryPath }
    public var measurementId: UUID
    public var label: String
    public var role: Role
    public var result: FitResult
    public var id: String { "\(role.rawValue):\(measurementId)" }
    public init(measurementId: UUID, label: String, role: Role, result: FitResult) {
        self.measurementId = measurementId; self.label = label; self.role = role; self.result = result
    }
}

// MARK: - Recently Deleted (spec 09)

public struct DeletedEntry: Hashable, Codable, Sendable, Identifiable {
    public var ref: RecordRef
    public var title: String
    /// "To-Do", "Room", "Storage spot"…
    public var kindLabel: String
    public var originalLocation: String?
    public var deletedAt: Date
    public var id: RecordRef { ref }
    public init(ref: RecordRef, title: String, kindLabel: String, originalLocation: String?, deletedAt: Date) {
        self.ref = ref; self.title = title; self.kindLabel = kindLabel; self.originalLocation = originalLocation; self.deletedAt = deletedAt
    }
    public static let retentionDays = 30
    public func daysLeft(now: Date) -> Int {
        max(0, DeletedEntry.retentionDays - Int(now.timeIntervalSince(deletedAt) / 86_400))
    }
}
