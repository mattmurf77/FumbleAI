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
    @Environment(AppEnvironment.self) private var env
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
                                if let band = env.catalog.resale(idea, mode: mode), property.currencyCode == "USD" {
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
        return env.catalog.price(idea, mode: mode).map { $0 + (mode == .diy ? " · DIY guide" : " · US pro guide") }
            ?? "Ask for a written service quote"
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
    @State private var suppliesInitialized = false
    private struct TaskProposal: Identifiable {
        let id = UUID()
        let mode: Chore.WorkMode
        let supplies: [ChoreSupply]
    }
    @State private var scheduled: Chore?
    @State private var taskProposal: TaskProposal?
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
        let proposedSupplies = mode == .diy ? supplies : []
        List {
            Section {
                Text(env.catalog.snapshot?.recommendation(idea)?.detail ?? idea.detail)
                WorkApproachPicker(mode: $mode)
            }
            Section("Estimated cost") {
                if let guide = env.catalog.guide(idea, mode: mode) {
                    if property.currencyCode == guide.currency { Text(guide.priceLabel).font(.headline) }
                    else { Text("Request a local quote in " + property.currencyCode + ".") }
                    Text(guide.scope)
                    ForEach(guide.sources, id: \.url) { source in
                        Link(source.label + " · checked " + source.reviewedOn, destination: source.url)
                    }
                } else if mode == .diy {
                    if property.currencyCode == "USD" { Text(idea.diyBudget).font(.headline) }
                    Text(idea.diyScope)
                    Link(idea.diySourceLabel, destination: idea.diySource)
                } else if let price = idea.costLabel, let source = idea.priceSource, property.currencyCode == "USD" {
                    LabeledContent("US professional guide", value: price)
                    Link(idea.sourceLabel, destination: source)
                    Text("Get a written local quote for your scope.").font(.footnote).foregroundStyle(.secondary)
                } else { Text("Request a local quote for your equipment and scope.") }
            }
            Section("Possible resale impact") {
                if let band = env.catalog.resale(idea, mode: mode), property.currencyCode == "USD" {
                    Text(dollarRange(band)).font(.headline)
                    if let assumption = env.catalog.snapshot?.resaleAssumption(for: idea) {
                        Text(assumption.scope)
                        Link(assumption.source.label, destination: assumption.source.url)
                    } else {
                        Text("Illustration using the US installed-cost guide and the 83% cost recovery surveyed for a typical closet renovation. The project scope, finish and local market determine whether that assumption fits.")
                        Link("NAR/NARI · 2025 Remodeling Impact Report", destination: URL(string: "https://www.nar.realtor/research-and-statistics/research-reports/remodeling-impact")!)
                    }
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
                    if let directory = env.catalog.snapshot?.directory(for: idea) {
                        Link("Find local pros · " + directory.name, destination: directory.url)
                        Text(directory.disclosure).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Link(idea == .closet ? "Find a remodeler in the NARI directory" : "Find local pros on Thumbtack", destination: idea.providerDirectory)
                    }
                    ShareLink(item: "Please send a written estimate for \(idea.title). Include labor, materials, exclusions and availability.") {
                        Label("Share a quote request", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                if let scheduled {
                    Label("Already on your to-do list", systemImage: "checkmark.circle")
                    if scheduled.workMode == .diy, let plan = scheduled.supplyPlan {
                        ShoppingSelectionsSummary(supplies: plan, identifier: "maintenance.savedShopping")
                    }
                } else {
                    Button { taskProposal = TaskProposal(mode: mode, supplies: proposedSupplies) } label: {
                        Label("Add to my to-dos", systemImage: "calendar.badge.plus")
                    }
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
            if !suppliesInitialized {
                supplies = env.catalog.supplies(idea)
                suppliesInitialized = true
            }
            for await all in env.chores.observeChores(.init(propertyId: property.id)) {
                scheduled = all.first {
                    $0.deletedAt == nil && $0.closedAt == nil &&
                    (idea.matchesTask($0.title) || MaintenanceIdea.titleKey($0.title) == MaintenanceIdea.titleKey(idea.diyTitle))
                }
            }
        }
        .sheet(item: $taskProposal) { proposal in
            ChoreForm(spaceID: nil, levelID: nil, suggestion: idea, suggestedMode: proposal.mode, suggestedPlan: proposal.supplies) { _ in
                confirmation = "Saved to your to-dos."
            }
            .id(proposal.id)
        }
        .sheet(isPresented: $addProject) {
            ProjectForm(spaceID: nil, levelID: nil, initialStatus: .planned, suggestion: idea,
                        suggestedGuide: env.catalog.guide(idea, mode: .hirePro)) { _ in confirmation = "Saved to your planned projects." }
        }
    }
}
