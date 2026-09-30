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
        guard let p else { return }
        let pid = p.id
        let currency = p.currencyCode
        let today = env.clock.today
        let plan = env.plan, chores = env.chores, things = env.things, inventory = env.inventory
        let rollups = env.rollups, people = env.people, clock = env.clock
        propertyTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await list in chores.observeChores(ChoreQuery(propertyId: pid)) {
                        self.counts.apply(chores: list, today: clock.today)
                    }
                }
                group.addTask { @MainActor in
                    for await r in rollups.observeProperty(pid) { self.counts.apply(rollup: r, currency: currency) }
                }
                group.addTask { @MainActor in
                    for await list in things.observeThings(ThingQuery(propertyId: pid)) { self.counts.apply(things: list) }
                }
                group.addTask { @MainActor in
                    for await list in inventory.observeItems(InventoryQuery(propertyId: pid)) { self.counts.apply(items: list) }
                }
                group.addTask { @MainActor in
                    for await list in inventory.observeShoppingList(property: pid, on: today) { self.counts.apply(shopping: list) }
                }
                group.addTask { @MainActor in
                    for await swap in inventory.observeSeasonalSwap(property: pid, on: today) { self.counts.apply(swap: swap) }
                }
                group.addTask { @MainActor in
                    for await list in plan.observeLevels(property: pid) { self.counts.apply(levels: list) }
                }
                group.addTask { @MainActor in
                    for await list in people.observePeople(property: pid) { self.counts.apply(people: list) }
                }
            }
        }
    }
}
