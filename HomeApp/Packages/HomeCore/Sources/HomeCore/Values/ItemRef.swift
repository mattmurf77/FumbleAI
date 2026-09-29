import Foundation

/// Cross-kind reference used by "+", search, room sheet and attachments. LLD §4.
public enum ItemRef: Hashable, Sendable, Codable {
    case chore(UUID), project(UUID), thing(UUID), inventory(UUID), measurement(UUID)

    public var id: UUID {
        switch self {
        case .chore(let i), .project(let i), .thing(let i), .inventory(let i), .measurement(let i): return i
        }
    }

    public var recordType: RecordType {
        switch self {
        case .chore: return .chore; case .project: return .project; case .thing: return .thing
        case .inventory: return .inventoryItem; case .measurement: return .measurement
        }
    }

    public var recordRef: RecordRef { RecordRef(recordType, id) }

    /// Attachment owner type for this item.
    public var attachmentOwnerType: Attachment.OwnerType {
        switch self {
        case .chore: return .chore; case .project: return .project; case .thing: return .thing
        case .inventory: return .inventoryItem; case .measurement: return .measurement
        }
    }

    /// Deep link `home://<kind>/<uuid>` (chores: `home://chore/<uuid>`).
    public var deepLink: URL {
        let kind: String
        switch self {
        case .chore: kind = "chore"; case .project: kind = "project"; case .thing: kind = "thing"
        case .inventory: kind = "inventory"; case .measurement: kind = "measurement"
        }
        return URL(string: "\(AppConfig.urlScheme)://\(kind)/\(id.uuidString.lowercased())")!
    }

    /// Parses `home://chore/<uuid>` etc.
    public init?(url: URL) {
        guard url.scheme == AppConfig.urlScheme, let host = url.host,
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        switch host {
        case "chore": self = .chore(id); case "project": self = .project(id); case "thing": self = .thing(id)
        case "inventory": self = .inventory(id); case "measurement": self = .measurement(id)
        default: return nil
        }
    }
}

/// The seven canvas views ("lenses"). LLD §7.4. Raw values are persisted in AppSettings.
public enum LensID: String, CaseIterable, Codable, Hashable, Sendable {
    case plan, todos, futureProjects, pastWork, things, inventory, budget

    public var title: String {
        switch self {
        case .plan: return "Plan"; case .todos: return "To-Dos"; case .futureProjects: return "Future Projects"
        case .pastWork: return "Past Work"; case .things: return "Appliances, Electronics & Furniture"
        case .inventory: return "Inventory"; case .budget: return "Budget"
        }
    }
    /// Short title for chips / segmented menus.
    public var shortTitle: String {
        switch self {
        case .things: return "Things"
        case .futureProjects: return "Future"
        case .pastWork: return "Past"
        default: return title
        }
    }
    /// SF Symbol for the lens menu.
    public var symbol: String {
        switch self {
        case .plan: return "square.split.bottomrightquarter"; case .todos: return "checklist"
        case .futureProjects: return "hammer"; case .pastWork: return "clock.arrow.circlepath"
        case .things: return "refrigerator"; case .inventory: return "shippingbox"; case .budget: return "dollarsign.circle"
        }
    }
    /// "+" preselection; nil → picker without preselection.
    public var addDefault: AddKind? {
        switch self {
        case .plan: return nil; case .todos: return .todo; case .futureProjects: return .futureProject
        case .pastWork: return .pastWork; case .things: return .thing; case .inventory: return .inventory
        case .budget: return .futureProject
        }
    }
}

/// What the "+" picker creates.
public enum AddKind: String, CaseIterable, Codable, Hashable, Sendable {
    case todo, futureProject, pastWork, thing, inventory, measurement
}
