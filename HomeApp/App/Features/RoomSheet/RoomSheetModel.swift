import Foundation
import Observation
import PlanKit
import HomeCore

/// Live data for one room sheet (a room, "This floor" or "Whole house"). Every list is an observation, so
/// completing a chore or adding an item from the sheet updates it in place.
@MainActor
@Observable
final class RoomSheetModel {
    private(set) var property: Property?
    private(set) var space: Space?
    private(set) var level: Level?
    private(set) var chores: [Chore] = []
    private(set) var projects: [Project] = []
    private(set) var things: [Thing] = []
    private(set) var thingNames: [UUID: String] = [:]
    private(set) var items: [InventoryItem] = []
    private(set) var spotTree: [SpotNode] = []
    private(set) var measurements: [HomeMeasurement] = []
    private(set) var openings: [Opening] = []
    private(set) var people: [UUID: Person] = [:]
    private(set) var rollup: Rollup?
    private(set) var loaded = false
    private(set) var missing = false

    /// Resolves the scope and runs every observation until the sheet goes away.
    func run(env: AppEnvironment, spaceId: UUID?, scope fixedScope: Scope?) async {
        guard let p = try? await env.plan.currentProperty() else { missing = true; return }
        property = p
        let scope: Scope
        if let spaceId {
            guard let s = try? await env.plan.space(spaceId) else { missing = true; loaded = true; return }
            space = s
            scope = s.scope
            level = try? await env.plan.levels(property: p.id).first { $0.id == s.levelId }
        } else {
            scope = fixedScope ?? .property
            if let l = scope.levelId { level = try? await env.plan.levels(property: p.id).first { $0.id == l } }
        }
        let pid = p.id
        let allThings = (try? await env.things.things(ThingQuery(propertyId: pid))) ?? []
        thingNames = Dictionary(allThings.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        loaded = true

        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in
                for await ps in env.people.observePeople(property: pid) {
                    self.people = Dictionary(ps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
            g.addTask { @MainActor in
                for await cs in env.chores.observeChores(ChoreQuery(propertyId: pid, scope: scope)) { self.chores = cs }
            }
            g.addTask { @MainActor in
                for await ps in env.projects.observeProjects(ProjectQuery(propertyId: pid, scope: scope)) { self.projects = ps }
            }
            g.addTask { @MainActor in
                for await ts in env.things.observeThings(ThingQuery(propertyId: pid, scope: scope)) { self.things = ts }
            }
            g.addTask { @MainActor in
                for await its in env.inventory.observeItems(InventoryQuery(propertyId: pid, scope: scope)) { self.items = its }
            }
            switch scope {
            case .space(let sid, let lid):
                g.addTask { @MainActor in
                    for await tree in env.inventory.observeSpotTree(space: sid) { self.spotTree = tree }
                }
                g.addTask { @MainActor in
                    for await ms in env.measurements.observeMeasurements(space: sid) { self.measurements = ms }
                }
                g.addTask { @MainActor in
                    for await geo in env.plan.observeGeometry(level: lid) {
                        if let s = geo.spaces.first(where: { $0.id == sid }) { self.space = s }
                        self.openings = geo.openings.filter { $0.spaceId == sid }
                    }
                }
                g.addTask { @MainActor in
                    for await rooms in env.rollups.observeRooms(level: lid) { self.rollup = rooms[sid] ?? Rollup(currency: p.currencyCode) }
                }
            case .level(let lid):
                g.addTask { @MainActor in
                    for await f in env.rollups.observeFloor(level: lid) { self.rollup = f.floorWide }
                }
            case .property:
                g.addTask { @MainActor in
                    for await r in env.rollups.observeProperty(pid) { self.rollup = r.wholeHouse }
                }
            }
        }
    }

    // MARK: Derived lists

    var openChores: [Chore] { chores.filter { $0.isOpen } }

    struct ChoreGroup: Identifiable {
        let id: String
        let title: String
        let chores: [Chore]
        let isDanger: Bool
    }

    /// Overdue / Today / This week / Later (mockup 3.3).
    func choreGroups(today: LocalDate) -> [ChoreGroup] {
        let open = chores.filter { $0.closedAt == nil && $0.deletedAt == nil }
        let weekEnd = today.adding(days: 6)
        func due(_ c: Chore) -> LocalDate { c.nextDueOn ?? LocalDate(9999, 12, 31) }
        let sorted = open.sorted { (due($0), $0.title) < (due($1), $1.title) }
        let overdue = sorted.filter { !$0.isPaused && due($0) < today }
        let todays = sorted.filter { !$0.isPaused && due($0) == today }
        let week = sorted.filter { !$0.isPaused && due($0) > today && due($0) <= weekEnd }
        let later = sorted.filter { $0.isPaused || due($0) > weekEnd }
        return [ChoreGroup(id: "overdue", title: "Overdue", chores: overdue, isDanger: true),
                ChoreGroup(id: "today", title: "Today", chores: todays, isDanger: false),
                ChoreGroup(id: "week", title: "This week", chores: week, isDanger: false),
                ChoreGroup(id: "later", title: "Later", chores: later, isDanger: false)].filter { !$0.chores.isEmpty }
    }

    var futureProjects: [Project] {
        let order: [Project.Status] = [.inProgress, .planned, .idea]
        return projects.filter { $0.status.isFuture }
            .sorted { (order.firstIndex(of: $0.status) ?? 9, $0.title) < (order.firstIndex(of: $1.status) ?? 9, $1.title) }
    }

    var pastProjects: [Project] {
        projects.filter { $0.status == .done }
            .sorted { ($0.completedOn ?? LocalDate(1, 1, 1)) > ($1.completedOn ?? LocalDate(1, 1, 1)) }
    }

    var lifetimeCents: Int64 { rollup?.lifetimeCents ?? 0 }

    var thingsByCategory: [(Thing.Category, [Thing])] {
        let order: [Thing.Category] = [.appliance, .electronic, .furniture, .fixture, .system, .unknown]
        let grouped = Dictionary(grouping: things, by: \.category)
        return order.compactMap { c in grouped[c].map { (c, $0.sorted { $0.name < $1.name }) } }
    }

    var looseItems: [InventoryItem] { items.filter { $0.storageSpotId == nil } }
}
