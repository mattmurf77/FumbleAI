import SwiftUI
import HomeCore

struct SuggestedMaintenanceView: View {
    @Environment(AppEnvironment.self) private var env
    let property: Property
    @AppStorage private var hidden: String

    init(property: Property) {
        self.property = property
        _hidden = AppStorage(wrappedValue: "", "maintenance.hidden." + property.id.uuidString)
    }
    var body: some View {
        List {
            MaintenanceRecommendationCatalog(property: property, ideas: MaintenanceIdea.visible(month: env.clock.today.month, latitude: property.latitude, hidden: hidden))
            if !hidden.isEmpty { Button("Show hidden ideas again") { hidden = "" } }
        }
        .navigationTitle("All recommendations")
    }
}

struct MaintenanceRecommendationCatalog: View {
    let property: Property
    let ideas: [MaintenanceIdea]
    @State private var mode = Chore.WorkMode.hirePro

    var body: some View {
        if !ideas.isEmpty {
            Section("Work around your home") {
                WorkApproachPicker(mode: $mode)
                ForEach(ideas) { idea in
                    NavigationLink { MaintenanceRecommendationDetail(property: property, idea: idea, initialMode: mode) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode == .diy ? idea.diyTitle : idea.title).font(.headline)
                                Text(costLabel(idea)).font(.subheadline).foregroundStyle(.secondary)
                                if let band = idea.resaleScenario(isDIY: mode == .diy), property.currencyCode == "USD" {
                                    Text("Resale scenario: " + dollarRange(band)).font(.caption)
                                } else {
                                    Text(idea == .closet ? "Resale impact needs a scope-matched estimate" : "Value impact: upkeep").font(.caption)
                                }
                            }
                        } icon: { Image(systemName: idea.symbol) }
                    }.accessibilityIdentifier("maintenance." + idea.rawValue)
                }
            }
        }
    }

    private func costLabel(_ idea: MaintenanceIdea) -> String {
        guard property.currencyCode == "USD" else { return "Get a local price in " + property.currencyCode }
        return mode == .diy ? idea.diyBudget : idea.costLabel.map { $0 + " · US pro guide" } ?? "Ask for a written service quote"
    }
}

private func dollarRange(_ band: ClosedRange<Int>) -> String {
    let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))
    return Double(band.lowerBound).formatted(format) + "–" + Double(band.upperBound).formatted(format) + " USD"
}

private struct WorkApproachPicker: View {
    @Binding var mode: Chore.WorkMode
    var body: some View {
        Picker("Who will do the work?", selection: $mode) {
            Text("DIY").tag(Chore.WorkMode.diy)
            Text("Hire a pro").tag(Chore.WorkMode.hirePro)
        }.pickerStyle(.segmented).accessibilityIdentifier("maintenance.mode")
    }
}

struct MaintenanceRecommendationDetail: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let property: Property
    let idea: MaintenanceIdea
    @AppStorage private var hidden: String
    @State private var mode: Chore.WorkMode
    @State private var supplies: [ChoreSupply]
    @State private var scheduled = false
    @State private var addTask = false
    @State private var addProject = false
    @State private var confirmation: String?

    init(property: Property, idea: MaintenanceIdea, initialMode: Chore.WorkMode = .hirePro) {
        self.property = property
        self.idea = idea
        _mode = State(initialValue: initialMode)
        _supplies = State(initialValue: idea.suggestedSupplyPlan)
        _hidden = AppStorage(wrappedValue: "", "maintenance.hidden." + property.id.uuidString)
    }

    var body: some View {
        List {
            Section {
                Text(idea.detail)
                WorkApproachPicker(mode: $mode)
            }
            Section("Estimated cost") {
                if mode == .diy {
                    if property.currencyCode == "USD" { Text(idea.diyBudget).font(.headline) }
                    Text(idea.diyScope)
                    Link("DIY price guide · Angi, 2026", destination: idea.diySource)
                } else if let price = idea.costLabel, let source = idea.priceSource, property.currencyCode == "USD" {
                    LabeledContent("US professional guide", value: price)
                    Link(idea.sourceLabel, destination: source)
                    Text("Get a written local quote for your scope.").font(.footnote).foregroundStyle(.secondary)
                } else { Text("Request a local quote for your equipment and scope.") }
            }
            Section("Possible resale impact") {
                if let band = idea.resaleScenario(isDIY: mode == .diy), property.currencyCode == "USD" {
                    Text(dollarRange(band)).font(.headline)
                    Text("Illustration using the US installed-cost guide and the 83% cost recovery surveyed for a typical closet renovation. The project scope, finish and local market determine whether that assumption fits.")
                    Link("NAR/NARI · 2025 Remodeling Impact Report", destination: URL(string: "https://www.nar.realtor/research-and-statistics/research-reports/remodeling-impact")!)
                } else {
                    Text(idea == .closet ? "A kit-only change needs a scope-matched local estimate." : "Routine maintenance helps preserve condition. A reliable increase in sale price has not been established for this task.")
                }
            }
            if mode == .diy {
                Section("Supplies and equipment") {
                    DIYReadinessView(propertyId: property.id, plan: $supplies)
                }
            } else {
                Section("Get a quote") {
                    if let partner = ProjectReferral(kind: "Contractor") { ProjectReferralLink(partner: partner) }
                    Link("Find professionals", destination: idea.priceSource ?? URL(string: "https://www.thumbtack.com/")!)
                    ShareLink(item: "Please send a written estimate for \(idea.title). Include labor, materials, exclusions and availability.") {
                        Label("Share a quote request", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                if scheduled { Label("Already on your to-do list", systemImage: "checkmark.circle") }
                else {
                    Button { addTask = true } label: { Label("Add to my to-dos", systemImage: "calendar.badge.plus") }
                        .accessibilityIdentifier("maintenance.addTask")
                }
                if mode == .hirePro {
                    Button { addProject = true } label: { Label("Plan as a project", systemImage: "hammer") }
                }
                if let confirmation { Text(confirmation).foregroundStyle(.secondary) }
            }
            Button("Hide this idea for my home") {
                let existing = Set(hidden.split(separator: ",").map(String.init))
                hidden = existing.union([idea.rawValue]).sorted().joined(separator: ",")
                dismiss()
            }
        }
        .navigationTitle(mode == .diy ? idea.diyTitle : idea.title).navigationBarTitleDisplayMode(.inline)
        .task(id: property.id) {
            for await all in env.chores.observeChores(.init(propertyId: property.id)) {
                scheduled = all.contains {
                    $0.deletedAt == nil && $0.closedAt == nil &&
                    (idea.matchesTask($0.title) || MaintenanceIdea.titleKey($0.title) == MaintenanceIdea.titleKey(idea.diyTitle))
                }
            }
        }
        .sheet(isPresented: $addTask) {
            ChoreForm(spaceID: nil, levelID: nil, suggestion: idea, suggestedMode: mode, suggestedSupplies: idea.supplySuggestions, suggestedPlan: mode == .diy ? supplies : []) { _ in
                confirmation = "Saved to your to-dos."
            }
        }
        .sheet(isPresented: $addProject) {
            ProjectForm(spaceID: nil, levelID: nil, initialStatus: .planned, suggestion: idea) { _ in confirmation = "Saved to your planned projects." }
        }
    }
}
