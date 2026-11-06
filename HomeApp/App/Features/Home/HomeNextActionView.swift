import SwiftUI
import HomeCore
import PlanCanvas

/// One primary action above the owner's scheduled tasks. The catalog and dismissal controls stay one tap away.
struct HomeNextActionView: View {
    let model: HomeHubModel
    let property: Property
    let openPlan: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage private var hasUsedRecords: Bool
    @AppStorage private var hidden: String
    @AppStorage private var hiddenMaintenance: String
    @State private var dayRevision = 0
    @State private var screen: Screen?
    @State private var explanation: HomeRecommendation?
    @State private var options: HomeRecommendation?

    private enum Screen: Identifiable {
        case all, action(HomeRecommendation)
        var id: String {
            switch self { case .all: return "all"; case .action(let item): return item.id }
        }
    }
    init(model: HomeHubModel, property: Property, openPlan: @escaping () -> Void) {
        self.model = model; self.property = property; self.openPlan = openPlan
        _hasUsedRecords = AppStorage(wrappedValue: false, "home.next.used." + property.id.uuidString)
        _hidden = AppStorage(wrappedValue: "", HomeRecommendations.preferenceKey(propertyID: property.id))
        _hiddenMaintenance = AppStorage(wrappedValue: "", "maintenance.hidden." + property.id.uuidString)
    }
    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var ignored: Set<String> { Set(hidden.split(separator: ",").map(String.init)) }
    private var excludedIdeas: Set<String> { Set(hiddenMaintenance.split(separator: ",").map(String.init)) }
    private var ranked: [HomeRecommendation] {
        _ = dayRevision
        guard var context = model.recommendationContext else { return [] }
        context.previouslyUsed = hasUsedRecords
        return HomeRecommendations.ranked(context, today: env.clock.today, now: env.clock.now,
                                          hidden: ignored, hiddenIdeas: excludedIdeas)
    }

    var body: some View {
        let best = ranked.first
        VStack(alignment: .leading, spacing: 9) {
            Text("Recommended next").font(.headline).foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let best {
                HStack(alignment: .top, spacing: 4) {
                    Button { open(best) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(best.title, systemImage: best.symbol)
                                .font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
                            Text(best.reason).font(.subheadline).foregroundStyle(theme.ink2)
                            if case .maintenance(let idea) = best.action, property.currencyCode == "USD", let cost = env.catalog.price(idea, mode: .hirePro) {
                                Text(cost + " · US professional guide · " + (env.catalog.guide(idea, mode: .hirePro)?.sourceLabel ?? idea.sourceLabel))
                                    .font(.footnote).foregroundStyle(theme.ink2)
                            }
                            Text(best.button)
                                .font(.subheadline.bold()).foregroundStyle(theme.accent)
                        }
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.nextAction")
                    Button { options = best } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).foregroundStyle(theme.ink2)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Recommendation options")
                    .accessibilityIdentifier("home.nextOptions")
                }
            } else if model.recommendationContext == nil { ProgressView("Checking your records…").font(.subheadline) }
            else {
                Text(ignored.isEmpty ? "No priority action to suggest today." : "No more priority suggestions to show.")
                    .font(.subheadline).foregroundStyle(theme.ink2)
            }
            Button("All recommendations") { screen = .all }
                .buttonStyle(.plain).font(.subheadline).frame(minHeight: 44).foregroundStyle(theme.accent)
                .accessibilityIdentifier("home.otherSuggestions")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(theme.separator, lineWidth: 1))
        .onChange(of: model.hasRecommendationActivity, initial: true) { _, used in if used { hasUsedRecords = true } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dayRevision += 1 }
        .onChange(of: scenePhase) { _, phase in if phase == .active { dayRevision += 1 } }
        .sheet(item: $screen) { item in
            switch item {
            case .all:
                HomeAllRecommendations(model: model, property: property, actions: ranked, catalog: catalog,
                                       canRestore: !hidden.isEmpty || !hiddenMaintenance.isEmpty, restore: {
                    hidden = ""; hiddenMaintenance = ""
                }, hide: hide, openPlan: { screen = nil; openPlan() })
            case .action(let item):
                if case .reviewWarranty(let id) = item.action { ThingForm(thingID: id) }
                else {
                    NavigationStack {
                        HomeRecommendationTarget(action: item.action, property: property, model: model)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { screen = nil } } }
                    }
                }
            }
        }
        .confirmationDialog("Recommendation options", isPresented: Binding(get: { options != nil }, set: { if !$0 { options = nil } }), presenting: options) { choice in
            Button("Why this suggestion?") { explanation = choice }
            Button("Hide this suggestion") { hide(choice) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Why this suggestion?", isPresented: Binding(get: { explanation != nil }, set: { if !$0 { explanation = nil } })) {
            Button("OK") { explanation = nil }
        } message: {
            Text(explanation?.reason ?? "")
        }
    }

    private var catalog: [MaintenanceIdea] {
        guard let context = model.recommendationContext else { return [] }
        return HomeRecommendations.maintenanceCatalog(context, today: env.clock.today, now: env.clock.now, hidden: excludedIdeas)
    }

    private func hide(_ item: HomeRecommendation) {
        switch item.action {
        case .maintenance(let idea):
            hiddenMaintenance = excludedIdeas.union([idea.rawValue]).sorted().joined(separator: ",")
        default:
            hidden = ignored.union([item.id]).sorted().joined(separator: ",")
        }
    }
    private func open(_ item: HomeRecommendation) {
        if item.action == .setupPlan { openPlan() } else { screen = .action(item) }
    }
}

private struct HomeAllRecommendations: View {
    @Environment(\.dismiss) private var dismiss
    let model: HomeHubModel
    let property: Property
    let actions: [HomeRecommendation]
    let catalog: [MaintenanceIdea]
    let canRestore: Bool
    let restore: () -> Void
    let hide: (HomeRecommendation) -> Void
    let openPlan: () -> Void
    @State private var warranty: HomeRecommendation?

    var body: some View {
        NavigationStack {
            List {
                let local = actions.filter { if case .maintenance = $0.action { return false }; return true }
                if !local.isEmpty {
                    Section("From your home") {
                        ForEach(local) { item in
                            Group {
                                switch item.action {
                                case .setupPlan: Button(action: openPlan) { row(item) }
                                case .reviewWarranty: Button { warranty = item } label: { row(item) }
                                default: NavigationLink { HomeRecommendationTarget(action: item.action, property: property, model: model) } label: { row(item) }
                                }
                            }
                            .swipeActions { Button("Hide") { hide(item) } }
                            .accessibilityAction(named: "Hide suggestion") { hide(item) }
                        }
                    }
                }
                MaintenanceRecommendationCatalog(property: property, ideas: catalog)
                if local.isEmpty && catalog.isEmpty {
                    ContentUnavailableView("No suggestions to show", systemImage: "checkmark.circle",
                                           description: Text("Your recommendations update as your home records change."))
                }
                if canRestore { Button("Restore hidden recommendations for this home", action: restore).accessibilityIdentifier("home.restoreSuggestions") }
            }
            .navigationTitle("All recommendations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $warranty) { item in if case .reviewWarranty(let id) = item.action { ThingForm(thingID: id) } }
        }
    }
    private func row(_ item: HomeRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(item.title, systemImage: item.symbol).font(.headline)
            Text(item.reason).font(.subheadline).foregroundStyle(.secondary)
        }.multilineTextAlignment(.leading)
    }
}

private struct HomeRecommendationTarget: View {
    let action: HomeRecommendation.Action
    let property: Property
    let model: HomeHubModel

    @ViewBuilder var body: some View {
        switch action {
        case .chore(let id): ChoreDetailView(choreID: id)
        case .planProject(let id):
            if let project = model.projects.first(where: { $0.id == id }) { ProjectPlanningView(project: project) }
            else { ContentUnavailableView("Project unavailable", systemImage: "hammer") }
        case .maintenance(let idea): MaintenanceRecommendationDetail(property: property, idea: idea)
        case .firstRecord: BringRecordsView(property: property)
        case .reviewWarranty(let id): ThingForm(thingID: id)
        case .setupPlan: EmptyView() // handled by the Home tab so the existing Plan navigation state survives
        }
    }
}
