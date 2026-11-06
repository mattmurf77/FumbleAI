import Foundation
import Observation
import HomeCore

/// Public content can refresh independently of releases. Saved jobs retain their own inputs.
@MainActor @Observable
final class HomeGuideContent {
    private(set) var snapshot: HomeContentCatalog?
    @ObservationIgnored private let client: HomeCatalogClient

    init(config: AppConfig, remoteEnabled: Bool) {
        let bundled = Bundle.main.url(forResource: "home-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? HomeContentCatalog.decode($0) }
        snapshot = bundled
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HomePlanning/catalog.json")
        client = HomeCatalogClient(config: remoteEnabled ? config : AppConfig(), bundled: bundled,
                                   cacheURL: remoteEnabled ? cache : nil)
    }

    func refresh() async {
        snapshot = await client.snapshot()
        snapshot = await client.refresh()
    }
    func guide(_ idea: MaintenanceIdea, mode: Chore.WorkMode) -> HomeContentCatalog.Guide? {
        snapshot?.guide(for: idea, mode: mode)
    }
    func price(_ idea: MaintenanceIdea, mode: Chore.WorkMode) -> String? {
        guide(idea, mode: mode)?.priceLabel ?? (mode == .diy ? idea.diyBudget : idea.costLabel)
    }
    func supplies(_ idea: MaintenanceIdea) -> [ChoreSupply] {
        snapshot?.recommendation(idea)?.supplies.map(\.suggestion) ?? idea.suggestedSupplyPlan
    }
    func resale(_ idea: MaintenanceIdea, mode: Chore.WorkMode) -> ClosedRange<Int>? {
        if let snapshot { return snapshot.resaleScenario(for: idea, mode: mode) }
        return idea.resaleScenario(isDIY: mode == .diy)
    }
}
