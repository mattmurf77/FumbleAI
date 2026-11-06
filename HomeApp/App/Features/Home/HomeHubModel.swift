import Foundation
import Observation
import HomeCore

/// Loads the hub's header and live counts for the current property. Every source is an observation stream
/// (yields now, then after each commit), so the cards stay current while the user pushes screens and comes back.
@MainActor
@Observable
final class HomeHubModel {
    private(set) var property: Property?
    private(set) var counts = HubCounts()
    private(set) var loaded = false
    private(set) var chores: [Chore] = []
    private(set) var projects: [Project] = []
    private var things: [Thing] = []
    private var documentCount = 0
    private var quotedProjects = Set<UUID>()
    private enum Source: CaseIterable { case chores, projects, things, documents, inventory, levels }
    private var recommendationSources = Set<Source>()

    var recommendationContext: HomeRecommendationContext? {
        guard recommendationSources.count == Source.allCases.count, let property else { return nil }
        var state = HomeRecommendationContext(property: property)
        state.chores = chores
        state.projects = projects
        state.things = things
        state.quotedProjects = quotedProjects
        state.documentCount = documentCount
        state.inventoryCount = counts.inventoryCount
        state.hasInteriorLevel = counts.interiorLevelCount > 0
        return state
    }

    var hasRecommendationActivity: Bool {
        guard let state = recommendationContext else { return false }
        return !state.chores.isEmpty || !state.projects.isEmpty || !state.things.isEmpty || state.inventoryCount > 0 || state.documentCount > 0
    }

    /// Per-property observations; replaced when the property changes, cancelled when `run` ends (the hub's
    /// `.task` is cancelled), which also releases the model.
    @ObservationIgnored private var propertyTask: Task<Void, Never>?

    var sections: [HubSection] { HomeHubCatalog.sections(counts) }
    var summary: String { HomeHubCatalog.summary(counts) }
    var subtitle: String? { HomeHubCatalog.subtitle(name: property?.name, address: property?.address) }

    /// Runs for the lifetime of the hub (`.task`). Cancelling the task ends every observation.
    func run(env: AppEnvironment) async {
        for await p in env.plan.observeCurrentProperty() {
            let changed = p?.id != property?.id
            property = p
            loaded = true
            if changed { observe(p, env: env) }
        }
        propertyTask?.cancel()
        propertyTask = nil
    }

    private func observe(_ p: Property?, env: AppEnvironment) {
        propertyTask?.cancel()
        counts = HubCounts()
        recommendationSources = []; chores = []; projects = []; things = []
        documentCount = 0; quotedProjects = []
        guard let p else { return }
        let pid = p.id
        let currency = p.currencyCode
        let today = env.clock.today
        let plan = env.plan, chores = env.chores, things = env.things, inventory = env.inventory
        let rollups = env.rollups, people = env.people, clock = env.clock
        let projectRepo = env.projects, attachments = env.attachments
        propertyTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await list in chores.observeChores(ChoreQuery(propertyId: pid, includeClosed: true)) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.counts.apply(chores: list, today: clock.today)
                        self.chores = list
                        self.recommendationSources.insert(.chores)
                    }
                }
                group.addTask { @MainActor in
                    for await projects in projectRepo.observeProjects(.init(propertyId: pid)) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.projects = projects
                        self.recommendationSources.insert(.projects)
                    }
                }
                group.addTask { @MainActor in
                    for await documents in attachments.observeDocuments(propertyId: pid) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.documentCount = documents.count
                        self.quotedProjects = Set(documents.filter { $0.details.category == .estimate }.compactMap(\.linkedProjectId))
                        self.recommendationSources.insert(.documents)
                    }
                }
                group.addTask { @MainActor in
                    for await r in rollups.observeProperty(pid) { self.counts.apply(rollup: r, currency: currency) }
                }
                group.addTask { @MainActor in
                    for await list in things.observeThings(ThingQuery(propertyId: pid)) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.things = list; self.counts.apply(things: list)
                        self.recommendationSources.insert(.things)
                    }
                }
                group.addTask { @MainActor in
                    for await list in inventory.observeItems(InventoryQuery(propertyId: pid)) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.counts.apply(items: list); self.recommendationSources.insert(.inventory)
                    }
                }
                group.addTask { @MainActor in
                    for await list in inventory.observeShoppingList(property: pid, on: today) { self.counts.apply(shopping: list) }
                }
                group.addTask { @MainActor in
                    for await swap in inventory.observeSeasonalSwap(property: pid, on: today) { self.counts.apply(swap: swap) }
                }
                group.addTask { @MainActor in
                    for await list in plan.observeLevels(property: pid) {
                        guard !Task.isCancelled, self.property?.id == pid else { return }
                        self.counts.apply(levels: list); self.recommendationSources.insert(.levels)
                    }
                }
                group.addTask { @MainActor in
                    for await list in people.observePeople(property: pid) { self.counts.apply(people: list) }
                }
            }
        }
    }
}
