import Foundation
import HomeCore

// Pure (SwiftUI-free) logic for the Home, Projects and Stuff tabs: the live counts, the cards and rows, and the
// summary line.

// MARK: - Navigation values

/// The bottom tab bar.
enum AppTab: String, Hashable, CaseIterable {
    case home, plan, todos, projects, stuff

    var title: String {
        switch self {
        case .home: return "Home"; case .plan: return "Plan"; case .todos: return "To-Dos"
        case .projects: return "Projects"; case .stuff: return "Stuff"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"; case .plan: return LensID.plan.symbol; case .todos: return LensID.todos.symbol
        case .projects: return LensID.futureProjects.symbol; case .stuff: return "shippingbox"
        }
    }
}

/// Screens pushed onto a tab's `NavigationStack` (Projects and Stuff).
enum HubRoute: Hashable {
    case budget
    case storage
    case shoppingList
    case seasonalSwap
}

/// Screens that manage their own `NavigationStack` and are therefore shown as sheets.
enum HubSheet: String, Identifiable, Hashable {
    case search, settings, addYard
    var id: String { rawValue }
}

/// What tapping a card or row does.
enum HubAction: Hashable {
    /// Switch to another tab.
    case tab(AppTab)
    /// Switch to the Plan tab with this lens (and floor, e.g. the Outside level for "Yard & Exterior").
    case plan(lens: LensID, levelID: UUID? = nil)
    case push(HubRoute)
    case sheet(HubSheet)
    /// Open a create form ("New project", "Add a plant or outdoor feature", ...).
    case add(AddDestination)
}

// MARK: - Live counts

/// Whole-home numbers shown on the hub. Filled from the repositories' observation streams; every `apply`
/// replaces the fields it owns, so streams can yield in any order.
struct HubCounts: Hashable, Sendable {
    // To-Dos
    var overdue = 0
    var dueToday = 0
    var dueWeek = 0
    var openChores = 0
    // Projects (from the property rollup)
    var futureCount = 0
    var inProgressCount = 0
    var pastCount = 0
    var plannedCents: Int64 = 0
    var spentCents: Int64 = 0
    var lifetimeCents: Int64 = 0
    var currency = "USD"
    // Things
    var ownedThings = 0
    var plannedThings = 0
    // Inventory
    var inventoryCount = 0
    var lowCount = 0
    var shoppingCount = 0
    var swapCount = 0
    var upcomingSeason: Season?
    // Plan / people
    var interiorLevelCount = 0
    var exteriorLevelID: UUID?
    var exteriorLevelName: String?
    var peopleCount = 0

    var planned: Money { Money(cents: plannedCents, currency: currency) }
    var lifetime: Money { Money(cents: lifetimeCents, currency: currency) }

    mutating func apply(chores: [Chore], today: LocalDate) {
        let open = chores.filter(\.isOpen)
        openChores = open.count
        overdue = open.filter { $0.isOverdue(today: today) }.count
        dueToday = open.filter { $0.isDue(on: today) }.count
        dueWeek = open.filter { $0.isDueThisWeek(today: today) }.count
    }

    mutating func apply(rollup: PropertyRollup, currency: String) {
        let t = rollup.total
        futureCount = t.openCount + t.ideaCount
        inProgressCount = t.inProgressCount
        pastCount = t.doneCount
        plannedCents = t.plannedCents
        spentCents = t.spentCents
        lifetimeCents = t.lifetimeCents
        self.currency = currency
    }

    mutating func apply(things: [Thing]) {
        let live = things.filter { $0.deletedAt == nil }
        ownedThings = live.filter { $0.ownership != .planned }.count
        plannedThings = live.filter { $0.ownership == .planned }.count
    }

    mutating func apply(items: [InventoryItem]) {
        let live = items.filter { $0.deletedAt == nil }
        inventoryCount = live.count
        lowCount = live.filter(\.isLow).count
    }

    mutating func apply(shopping: [ShoppingLine]) {
        shoppingCount = shopping.count
    }

    mutating func apply(swap: SeasonalSwap) {
        swapCount = swap.getOut.count + swap.putAway.count
        upcomingSeason = swap.upcoming
    }

    mutating func apply(levels: [Level]) {
        let live = levels.filter { $0.deletedAt == nil }
        interiorLevelCount = live.filter { !$0.isExterior }.count
        let exterior = live.filter(\.isExterior).sortedForPills.first
        exteriorLevelID = exterior?.id
        exteriorLevelName = exterior?.name
    }

    mutating func apply(people: [Person]) {
        peopleCount = people.filter { $0.deletedAt == nil }.count
    }
}

// MARK: - Cards

struct HubCard: Identifiable, Hashable {
    enum ID: String, Hashable, CaseIterable {
        case floorPlan, yard, todos, projects, stuff, search
    }
    enum Tone: Hashable { case neutral, attention }

    let id: ID
    let title: String
    let detail: String
    let symbol: String
    var badge: String?
    var badgeTone: Tone = .neutral
    let action: HubAction
}

struct HubSection: Identifiable, Hashable {
    let id: String
    let title: String
    let cards: [HubCard]
}

/// A row on the Projects and Stuff tabs.
struct HubRow: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var badge: String?
    var badgeTone: HubCard.Tone = .neutral
    let action: HubAction
}

struct HubRowSection: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [HubRow]
}

enum HomeHubCatalog {
    /// The Home tab: the house itself, then four tasks. Everything else lives in the tabs or the header buttons.
    static func sections(_ c: HubCounts) -> [HubSection] {
        [
            HubSection(id: "home", title: "Your home", cards: [floorPlan(c), yard(c)]),
            HubSection(id: "tasks", title: "Get things done", cards: [todos(c), projects(c), stuff(c), search]),
        ]
    }

    static func cards(_ c: HubCounts) -> [HubCard] { sections(c).flatMap(\.cards) }

    static func floorPlan(_ c: HubCounts) -> HubCard {
        HubCard(id: .floorPlan, title: "Floor plan", detail: "Every floor and room at a glance",
                symbol: LensID.plan.symbol,
                badge: c.interiorLevelCount > 0 ? plural(c.interiorLevelCount, "floor") : nil,
                action: .plan(lens: .plan))
    }

    static func yard(_ c: HubCounts) -> HubCard {
        if let id = c.exteriorLevelID {
            return HubCard(id: .yard, title: "Yard & Exterior", detail: "Trees, flowers, patio and outside jobs",
                           symbol: "tree", action: .plan(lens: .plan, levelID: id))
        }
        return HubCard(id: .yard, title: "Yard & Exterior", detail: "Add your yard to plan outside work",
                       symbol: "tree", badge: "Add", action: .sheet(.addYard))
    }

    static func todos(_ c: HubCounts) -> HubCard {
        var card = HubCard(id: .todos, title: LensID.todos.title, detail: "Chores and reminders by due date",
                           symbol: LensID.todos.symbol, action: .tab(.todos))
        if c.overdue > 0 {
            card.badge = "\(c.overdue) overdue"; card.badgeTone = .attention
        } else if c.dueToday > 0 {
            card.badge = "\(c.dueToday) today"
        } else if c.dueWeek > 0 {
            card.badge = "\(c.dueWeek) this week"
        }
        return card
    }

    static func projects(_ c: HubCounts) -> HubCard {
        let detail = c.inProgressCount > 0 ? "\(c.inProgressCount) in progress · past work and budget"
                                           : "Ideas, past work and budget"
        return HubCard(id: .projects, title: "Projects & budget", detail: detail,
                       symbol: LensID.futureProjects.symbol, badge: count(c.futureCount), action: .tab(.projects))
    }

    static func stuff(_ c: HubCounts) -> HubCard {
        var card = HubCard(id: .stuff, title: "Record your stuff", detail: "Appliances, furniture, plants and storage",
                           symbol: "shippingbox", action: .tab(.stuff))
        if c.lowCount > 0 {
            card.badge = "\(c.lowCount) low"; card.badgeTone = .attention
        } else {
            card.badge = count(c.ownedThings + c.inventoryCount)
        }
        return card
    }

    static let search = HubCard(id: .search, title: "Find something", detail: "“Where’s the winter coat?”",
                                symbol: "magnifyingglass", action: .sheet(.search))

    // MARK: Projects tab

    static func projectSections(_ c: HubCounts) -> [HubRowSection] {
        [
            HubRowSection(id: "add", title: "Add", rows: [
                HubRow(id: "newProject", title: "New project or idea", detail: "An improvement or repair, with an estimate",
                       symbol: "plus.circle", action: .add(.futureProject(spaceID: nil, levelID: nil))),
                HubRow(id: "logWork", title: "Log finished work", detail: "What was done, the cost and the receipt",
                       symbol: "checkmark.circle", action: .add(.pastWork(spaceID: nil, levelID: nil))),
            ]),
            HubRowSection(id: "see", title: "See", rows: [
                HubRow(id: "future", title: LensID.futureProjects.title,
                       detail: c.inProgressCount > 0 ? "\(c.inProgressCount) in progress · shown on the floor plan" : "Ideas and plans, shown on the floor plan",
                       symbol: LensID.futureProjects.symbol, badge: count(c.futureCount), action: .plan(lens: .futureProjects)),
                HubRow(id: "past", title: LensID.pastWork.title,
                       detail: c.lifetimeCents > 0 ? "\(c.lifetime.compact) spent on finished jobs" : "Finished jobs, receipts and costs",
                       symbol: LensID.pastWork.symbol, badge: count(c.pastCount), action: .plan(lens: .pastWork)),
                HubRow(id: "budget", title: LensID.budget.title, detail: "Planned, spent and remaining by floor",
                       symbol: LensID.budget.symbol, badge: c.plannedCents > 0 ? c.planned.compact : nil, action: .push(.budget)),
            ]),
        ]
    }

    // MARK: Stuff tab ("Record your stuff")

    static func stuffSections(_ c: HubCounts) -> [HubRowSection] {
        [
            HubRowSection(id: "add", title: "Record something", rows: [
                HubRow(id: "thing", title: "Appliance, electronic or furniture", detail: "Specs, warranty, filters and bulbs",
                       symbol: "sofa", action: .add(.thing(spaceID: nil))),
                HubRow(id: "scanLabel", title: "Scan an appliance label", detail: "Snap the model sticker; brand, model and serial fill in",
                       symbol: "text.viewfinder", action: .add(.scannedThing(spaceID: nil))),
                HubRow(id: "outdoor", title: "Plant or outdoor feature", detail: "Trees, fence, swing set, pool, septic, utility lines",
                       symbol: "tree", action: .add(.outdoorThing(spaceID: nil))),
                HubRow(id: "inventory", title: "Pantry, clothing or stored item", detail: "What you have and where it’s kept",
                       symbol: "shippingbox", action: .add(.inventory(spaceID: nil))),
                HubRow(id: "measurement", title: "Measurement", detail: "Width, depth and height of a spot, door or wall",
                       symbol: "ruler", action: .add(.measurement(spaceID: nil))),
            ]),
            HubRowSection(id: "browse", title: "Browse", rows: [
                HubRow(id: "things", title: "On the floor plan", detail: c.plannedThings > 0 ? "\(c.plannedThings) planned · see what’s in each room" : "See what’s in each room",
                       symbol: LensID.things.symbol, badge: count(c.ownedThings), action: .plan(lens: .things)),
                inventoryRow(c),
                HubRow(id: "shopping", title: "Shopping list", detail: "Low supplies and replacements due",
                       symbol: "cart", badge: count(c.shoppingCount), action: .push(.shoppingList)),
                HubRow(id: "swap", title: "Seasonal swap", detail: swapDetail(c),
                       symbol: "arrow.triangle.2.circlepath", badge: count(c.swapCount), action: .push(.seasonalSwap)),
            ]),
        ]
    }

    static func inventoryRow(_ c: HubCounts) -> HubRow {
        var row = HubRow(id: "storage", title: "Storage & inventory", detail: "Pantry, closets and storage spots",
                         symbol: LensID.inventory.symbol, action: .push(.storage))
        if c.lowCount > 0 {
            row.badge = "\(c.lowCount) low"; row.badgeTone = .attention
        } else {
            row.badge = count(c.inventoryCount)
        }
        return row
    }

    static func swapDetail(_ c: HubCounts) -> String {
        switch c.upcomingSeason {
        case .summer?: return "Get summer things out, put winter away"
        case .winter?: return "Get winter things out, put summer away"
        default: return "Rotate seasonal clothes and gear"
        }
    }

    // MARK: Text

    /// One-line live summary under the title, e.g. "3 chores due today · 1 overdue · $4.2k planned".
    static func summary(_ c: HubCounts) -> String {
        var parts: [String] = []
        if c.dueToday > 0 { parts.append(plural(c.dueToday, "chore") + " due today") }
        if c.overdue > 0 { parts.append("\(c.overdue) overdue") }
        if c.dueToday == 0 && c.overdue == 0 {
            parts.append(c.dueWeek > 0 ? plural(c.dueWeek, "chore") + " due this week" : "Nothing due this week")
        }
        if c.plannedCents > 0 { parts.append("\(c.planned.compact) planned") }
        if c.lowCount > 0 { parts.append("\(c.lowCount) running low") }
        return parts.joined(separator: " · ")
    }

    /// Property name + address line for the header subtitle ("Maple House · 12 Oak St, Portland, OR").
    static func subtitle(name: String?, address: PostalAddressLite?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let a = address?.singleLine ?? ""
        let parts = [n, a].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// Badge text for a plain count; nothing for zero so empty cards stay quiet.
    static func count(_ n: Int) -> String? { n > 0 ? "\(n)" : nil }
}
