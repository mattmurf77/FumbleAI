import Foundation

public struct HomeRecommendation: Identifiable, Equatable, Sendable {
    public enum Action: Hashable, Sendable {
        case chore(UUID), planProject(UUID), reviewWarranty(UUID), maintenance(MaintenanceIdea), firstRecord, setupPlan
    }
    public let id: String
    public let action: Action
    public let title: String
    public let reason: String
    public let button: String
    public let symbol: String
}

/// All inputs come from this home's stored records. The app never creates a task or changes a budget here.
public struct HomeRecommendationContext: Sendable {
    public let property: Property
    public var chores: [Chore] = []
    public var projects: [Project] = []
    public var things: [Thing] = []
    public var quotedProjects = Set<UUID>()
    public var documentCount = 0
    public var inventoryCount = 0
    public var hasInteriorLevel = false
    public var previouslyUsed = false
    public init(property: Property) { self.property = property }
}

public enum HomeRecommendations {
    public static func preferenceKey(propertyID: UUID) -> String { "home.next.hidden." + propertyID.uuidString }

    public static func ranked(_ context: HomeRecommendationContext, today: LocalDate, now: Date,
                              hidden: Set<String> = [], hiddenIdeas: Set<String> = []) -> [HomeRecommendation] {
        let home = context.property.id
        let chores = context.chores.filter { $0.propertyId == home && $0.deletedAt == nil }
        let projects = context.projects.filter { $0.propertyId == home && $0.deletedAt == nil }
        let things = context.things.filter { $0.propertyId == home && $0.deletedAt == nil }
        let active = chores.filter(\.isOpen)
        var choices: [HomeRecommendation] = []
        let due = active.filter { $0.nextDueOn.map { $0 <= today.adding(days: 6) } ?? false }.sorted {
            ($0.nextDueOn!, $0.dueMinutes ?? 1440, $0.title, $0.id.uuidString) <
                ($1.nextDueOn!, $1.dueMinutes ?? 1440, $1.title, $1.id.uuidString)
        }
        for chore in due {
            guard let date = chore.nextDueOn else { continue }
            let reason: String
            let days = date.daysSinceEpoch - today.daysSinceEpoch
            if days < 0 { reason = days == -1 ? "This task was due yesterday." : "This task is \(-days) days overdue." }
            else if days == 0 { reason = "You scheduled this task for today." }
            else { reason = days == 1 ? "You scheduled this task for tomorrow." : "This task is due in \(days) days." }
            choices.append(.init(id: "task-\(chore.id)-\(date)", action: .chore(chore.id), title: chore.title, reason: reason,
                                 button: "Open task", symbol: "checklist"))
        }

        // An actual upcoming warranty is more time-sensitive than a project without a target.
        let owned = things.filter { $0.ownership == .owned }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        let warranties = owned.filter { $0.warrantyEnd.map { (today...today.adding(days: 30)).contains($0) } ?? false }.sorted {
            ($0.warrantyEnd!, $0.name, $0.id.uuidString) < ($1.warrantyEnd!, $1.name, $1.id.uuidString)
        }
        for item in warranties {
            guard let date = item.warrantyEnd else { continue }
            let distance = date.daysSinceEpoch - today.daysSinceEpoch
            let remaining = distance == 0 ? "today" : (distance == 1 ? "tomorrow" : "in \(distance) days")
            choices.append(.init(id: "warranty-\(item.id)-\(date)", action: .reviewWarranty(item.id), title: "Review the warranty for \(item.name)",
                                 reason: "Your item record says the warranty ends \(remaining).", button: "Open item", symbol: "shield"))
        }

        let planned = projects.filter { $0.status == .planned || $0.status == .inProgress }.sorted {
            let distant = LocalDate(9999, 12, 31)
            return ($0.targetOn ?? distant, $0.priority ?? 4, $0.title, $0.id.uuidString) <
                   ($1.targetOn ?? distant, $1.priority ?? 4, $1.title, $1.id.uuidString)
        }
        var laterPlanning: [HomeRecommendation] = []
        for project in planned {
            let hasQuote = context.quotedProjects.contains(project.id)
            let missingBudget = project.estCost == nil
            // A recorded zero budget can deliberately represent DIY or covered work.
            guard missingBudget || (!hasQuote && (project.estCost?.cents ?? 0) > 0) else { continue }
            let detail = missingBudget ? (hasQuote ? "A quote is on file and you haven’t set a budget." : "This project has no recorded budget.")
                                       : "A budget is on file. You can add a quote to compare it with your estimate."
            let choice = HomeRecommendation(id: "project-\(project.id)-" + (missingBudget ? "budget" : "quote"), action: .planProject(project.id),
                                 title: (missingBudget ? "Budget for " : "Find a quote for ") + project.title,
                                 reason: detail, button: "Open project plan", symbol: "hammer")
            if hasQuote || project.targetOn.map({ $0 <= today.adding(days: 30) }) == true { choices.append(choice) }
            else { laterPlanning.append(choice) }
        }

        let first = chores.isEmpty && projects.isEmpty && things.isEmpty && context.inventoryCount == 0 && context.documentCount == 0
        if first && !context.previouslyUsed {
            choices.append(.init(id: "first-record", action: .firstRecord, title: "Add your first home record",
                                 reason: "Start with a project you remember, a spreadsheet you already keep, or a document on hand.",
                                 button: "Choose a record", symbol: "tray.and.arrow.down"))
        }
        let available = maintenanceCatalog(context, today: today, now: now, hidden: hiddenIdeas)
        let seasonal = applicableIdeas(month: today.month, latitude: context.property.latitude)
        for idea in available where seasonal.contains(idea) {
            guard let thing = owned.first(where: { idea.matchesEquipment($0) }) else { continue }
            let key = "maintenance-\(idea.rawValue)-\(today.year)-\((today.month - 1) / 3)"
            choices.append(.init(id: key, action: .maintenance(idea), title: idea.title,
                                 reason: idea == .dryer ? "You recorded \(thing.name). If it vents outdoors, check its cleaning instructions." :
                                     "Your home records include \(thing.name). Check its maintenance instructions before scheduling.",
                                 button: "Review maintenance", symbol: idea.symbol))
        }
        choices.append(contentsOf: laterPlanning)
        let undated = active.filter { $0.nextDueOn == nil }.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
        for task in undated {
            choices.append(.init(id: "undated-\(task.id)", action: .chore(task.id), title: task.title,
                                 reason: "You saved this open task without a due date.", button: "Open task", symbol: "checklist"))
        }
        if !context.hasInteriorLevel {
            choices.append(.init(id: "setup-plan", action: .setupPlan, title: "Add a floor to your home",
                                 reason: "Your home has no indoor floor yet. Add one when you want to organize work by room.",
                                 button: "Open plan", symbol: "square.split.2x2"))
        }
        return choices.filter { !hidden.contains($0.id) }
    }

    public static func maintenanceCatalog(_ context: HomeRecommendationContext, today: LocalDate, now: Date,
                                          hidden: Set<String> = []) -> [MaintenanceIdea] {
        let propertyID = context.property.id
        let tasks = context.chores.filter { task in
            task.propertyId == propertyID && task.deletedAt == nil && (task.closedAt.map { now.timeIntervalSince($0) < 90 * 86_400 } ?? true)
        }
        let prior = today.adding(days: -90)
        let work = context.projects.filter { project in
            project.propertyId == propertyID && project.deletedAt == nil &&
                (project.status.isFuture || (project.status == .done && project.completedOn.map { (prior...today).contains($0) } == true))
        }
        let equipment = Dictionary(context.things.filter { $0.propertyId == propertyID && $0.deletedAt == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return MaintenanceIdea.seasonalOrder(month: today.month, latitude: context.property.latitude).filter { idea in
            !hidden.contains(idea.rawValue) &&
                !tasks.contains { task in idea.matchesTask(task.title, linkedEquipment: task.linkedThingId.flatMap { equipment[$0] }) } &&
                !work.contains { idea.matchesTask($0.title) }
        }
    }

    private static func applicableIdeas(month: Int, latitude: Double?) -> Set<MaintenanceIdea> {
        var options: Set<MaintenanceIdea> = [.dryer, .filter]
        // The hemisphere alone gives no reliable heating/cooling season near the equator.
        guard let latitude, abs(latitude) > 23.5 else { return options }
        let localMonth = latitude < 0 ? ((month + 5) % 12) + 1 : month
        if (3...5).contains(localMonth) || (9...11).contains(localMonth) { options.insert(.gutters) }
        if (3...8).contains(localMonth) { options.insert(.cooling) }
        if localMonth >= 9 || localMonth <= 2 { options.insert(.furnace) }
        return options
    }
}

public extension MaintenanceIdea {
    func matchesEquipment(_ thing: Thing) -> Bool {
        let words = Set(Self.titleKey((thing.templateKey ?? "") + " " + thing.name).split(separator: " ").map(String.init))
        switch self {
        case .gutters: return !words.isDisjoint(with: ["gutter", "gutters", "downspout"])
        case .dryer: return words.contains("dryer") && !words.contains("ventless") && !words.contains("heatpump") && !(words.contains("heat") && words.contains("pump"))
        case .furnace: return words.contains("furnace")
        case .cooling: return words.contains("ac") || words.contains("cooling") || (words.contains("air") && !words.isDisjoint(with: ["conditioner", "conditioning"]))
        case .filter: return !words.isDisjoint(with: ["hvac", "furnace"]) || thing.attributes["filterSize"] != nil
        default: return false
        }
    }

    func matchesTask(_ title: String, linkedEquipment: Thing? = nil) -> Bool {
        let normalized = Self.titleKey(title)
        if normalized == Self.titleKey(self.title) || normalized == Self.titleKey(self.diyTitle) { return true }
        let words = Set(normalized.split(separator: " ").map(String.init))
        func has(_ terms: Set<String>) -> Bool { !words.isDisjoint(with: terms) }
        switch self {
        case .gutters: return has(["gutters", "gutter", "downspouts"]) && has(["clean", "clear", "cleaning"])
        case .dryer: return has(["dryer"]) && has(["vent", "vents", "duct"]) && has(["clean", "clear", "cleaning"])
        case .filter: return has(["filter", "filters"]) && (has(["hvac", "furnace", "air", "ac"]) || linkedEquipment.map(matchesEquipment) == true) && has(["change", "check", "replace", "inspect"])
        case .furnace: return has(["furnace"]) && has(["service", "tune", "tuneup", "inspect", "inspection"])
        case .cooling: return has(["hvac", "ac", "conditioning", "cooling"]) && has(["service", "tune", "check", "inspect", "inspection"])
        default: return false
        }
    }
}
