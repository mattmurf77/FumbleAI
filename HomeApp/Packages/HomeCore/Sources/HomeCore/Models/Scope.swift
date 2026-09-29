import Foundation

/// Where an item lives: one room, floor-wide, or whole house. Stored as three columns
/// (`scope`, `space_id`, `level_id`); `level_id` is denormalized from the space. LLD §1, §4.
public enum Scope: Hashable, Sendable {
    case space(UUID, level: UUID)
    case level(UUID)
    case property

    public enum Kind: String, ForwardCompatibleEnum {
        case space, level, property, unknown
        public static var unknownCase: Kind { .unknown }
    }

    public var kind: Kind {
        switch self { case .space: return .space; case .level: return .level; case .property: return .property }
    }
    public var spaceId: UUID? { if case .space(let s, _) = self { return s }; return nil }
    public var levelId: UUID? {
        switch self { case .space(_, let l): return l; case .level(let l): return l; case .property: return nil }
    }

    public enum ScopeError: Error, Hashable, Sendable { case invalidColumns }

    /// Rebuilds a scope from its three stored columns, enforcing the LLD §3.2 CHECK.
    public init(kind: Kind, spaceId: UUID?, levelId: UUID?) throws {
        switch (kind, spaceId, levelId) {
        case (.space, let s?, let l?): self = .space(s, level: l)
        case (.level, nil, let l?): self = .level(l)
        case (.property, nil, nil): self = .property
        default: throw ScopeError.invalidColumns
        }
    }

    /// True if this scope is on `levelId` (space- or level-scoped).
    public func isOn(level levelId: UUID) -> Bool { self.levelId == levelId }
}

extension Scope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, spaceId, levelId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        do {
            try self.init(kind: kind,
                          spaceId: try c.decodeIfPresent(UUID.self, forKey: .spaceId),
                          levelId: try c.decodeIfPresent(UUID.self, forKey: .levelId))
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Invalid scope columns")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(spaceId, forKey: .spaceId)
        try c.encodeIfPresent(levelId, forKey: .levelId)
    }
}

/// Common shape of every synced domain row (15 tables). LLD §1 "Sync columns", §5.1.
public protocol SyncedModel: Identifiable, Codable, Hashable, Sendable where ID == UUID {
    /// CloudKit record type, PascalCase table name (e.g. "Chore").
    static var recordType: RecordType { get }
    var id: UUID { get }
    var propertyId: UUID { get }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
}

public extension SyncedModel {
    var isDeleted: Bool { deletedAt != nil }
}

/// The 15 synced record types (CloudKit record type == PascalCase table name). LLD §5.1.
public enum RecordType: String, Codable, Hashable, Sendable, CaseIterable {
    case property = "Property", level = "Level", space = "Space", opening = "Opening", person = "Person"
    case storageSpot = "StorageSpot", measurement = "Measurement", thing = "Thing", chore = "Chore"
    case choreCompletion = "ChoreCompletion", choreCalendarLink = "ChoreCalendarLink", project = "Project"
    case costLineItem = "CostLineItem", inventoryItem = "InventoryItem", attachment = "Attachment"

    /// SQLite table name (snake_case singular).
    public var tableName: String {
        switch self {
        case .property: return "property"; case .level: return "level"; case .space: return "space"
        case .opening: return "opening"; case .person: return "person"; case .storageSpot: return "storage_spot"
        case .measurement: return "measurement"; case .thing: return "thing"; case .chore: return "chore"
        case .choreCompletion: return "chore_completion"; case .choreCalendarLink: return "chore_calendar_link"
        case .project: return "project"; case .costLineItem: return "cost_line_item"
        case .inventoryItem: return "inventory_item"; case .attachment: return "attachment"
        }
    }
}

/// Reference to any synced row (used by Recently Deleted, sync events and diagnostics).
public struct RecordRef: Hashable, Codable, Sendable {
    public var type: RecordType
    public var id: UUID
    public init(_ type: RecordType, _ id: UUID) { self.type = type; self.id = id }
}
