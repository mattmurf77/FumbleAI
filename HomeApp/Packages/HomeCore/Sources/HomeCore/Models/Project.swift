import Foundation

/// A project: idea → planned → in progress → done (Past Work). LLD §3.2 `project`, §8.
public struct Project: SyncedModel {
    public static let recordType = RecordType.project
    public enum Status: String, ForwardCompatibleEnum {
        case idea, planned, inProgress = "in_progress", done, unknown
        public static var unknownCase: Status { .unknown }
        /// Future Projects lens statuses.
        public var isFuture: Bool { self == .idea || self == .planned || self == .inProgress }
        public var displayName: String {
            switch self {
            case .idea: return "Idea"; case .planned: return "Planned"; case .inProgress: return "In progress"
            case .done: return "Done"; case .unknown: return "Unknown"
            }
        }
    }
    public var id: UUID
    public var propertyId: UUID
    public var scope: Scope
    public var title: String
    public var notes: String?
    public var status: Status
    /// 1…3.
    public var priority: Int?
    public var estCost: Money?
    /// When set, overrides the line-item sum (§8.1).
    public var actualCost: Money?
    public var estHours: Double?
    public var actualHours: Double?
    public var targetOn: LocalDate?
    public var startedOn: LocalDate?
    /// Required when status == .done (SQL CHECK).
    public var completedOn: LocalDate?
    public var vendor: String?
    public var spawnedFromChoreId: UUID?
    public var currencyCode: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, scope: Scope, title: String, notes: String? = nil,
                status: Status = .idea, priority: Int? = nil, estCost: Money? = nil, actualCost: Money? = nil,
                estHours: Double? = nil, actualHours: Double? = nil, targetOn: LocalDate? = nil,
                startedOn: LocalDate? = nil, completedOn: LocalDate? = nil, vendor: String? = nil,
                spawnedFromChoreId: UUID? = nil, currencyCode: String = "USD",
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.scope = scope; self.title = title; self.notes = notes
        self.status = status; self.priority = priority; self.estCost = estCost; self.actualCost = actualCost
        self.estHours = estHours; self.actualHours = actualHours; self.targetOn = targetOn; self.startedOn = startedOn
        self.completedOn = completedOn; self.vendor = vendor; self.spawnedFromChoreId = spawnedFromChoreId
        self.currencyCode = currencyCode; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// A cost line on a project (material, labor, permit, other). LLD §3.2 `cost_line_item`.
public struct CostLineItem: SyncedModel {
    public static let recordType = RecordType.costLineItem
    public enum Kind: String, ForwardCompatibleEnum {
        case material, labor, permit, other, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var projectId: UUID
    public var label: String
    /// ≥ 0.
    public var amount: Money
    public var kind: Kind
    public var vendor: String?
    public var incurredOn: LocalDate?
    public var hours: Double?
    public var receiptAttachmentId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, projectId: UUID, label: String, amount: Money, kind: Kind = .other,
                vendor: String? = nil, incurredOn: LocalDate? = nil, hours: Double? = nil, receiptAttachmentId: UUID? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.projectId = projectId; self.label = label; self.amount = amount
        self.kind = kind; self.vendor = vendor; self.incurredOn = incurredOn; self.hours = hours
        self.receiptAttachmentId = receiptAttachmentId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}
