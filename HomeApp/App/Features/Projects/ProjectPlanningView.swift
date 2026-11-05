import SwiftUI
import HomeCore

/// Everything starts from the owner's existing project. Planning assumptions never change its recorded costs.
struct ProjectPlanningView: View {
    @Environment(AppEnvironment.self) private var env
    let project: Project
    @State private var property: Property?
    @State private var quotes: [HomeDocument] = []
    @State private var budgetText: String
    @State private var showingRequest = false
    @State private var benchmark: RecoveryBenchmark?
    @State private var recoveryText = ""
    @State private var rateText = ""
    @State private var termMonths = 60

    init(project: Project) {
        self.project = project
        _budgetText = State(initialValue: ProjectInput.text(project.estCost))
    }

    var body: some View {
        Form {
            Section {
                ProjectMoneyField(title: "Project cost", text: $budgetText, currency: project.currencyCode)
                if !budgetText.isEmpty && budget == nil {
                    Text("Enter a positive amount in \(project.currencyCode).").font(.footnote)
                }
            } header: { Text("Planning estimate") } footer: {
                Text("Try an amount here or use a saved quote below. Edit the project to change its budget.")
            }
            quoteSection
            recoverySection
            financingSection
        }
        .navigationTitle("Plan this project").navigationBarTitleDisplayMode(.inline)
        .task(id: project.propertyId) {
            do { property = try await env.plan.currentProperty() } catch { property = nil }
            for await docs in env.attachments.observeDocuments(propertyId: project.propertyId) {
                quotes = docs.filter { $0.linkedProjectId == project.id && $0.details.category == .estimate }
            }
        }
        .sheet(isPresented: $showingRequest) { NavigationStack { QuoteRequestView(project: project) } }
    }

    private var budget: Money? {
        if case .value(let amount) = ProjectInput.money(budgetText, currency: project.currencyCode), amount.cents > 0 { return amount }
        return nil
    }

    private var quoteSection: some View {
        Section {
            Button { showingRequest = true } label: { Label("Prepare a quote request", systemImage: "square.and.pencil") }
            if let partner = ProjectReferral(kind: "Contractor") { ProjectReferralLink(partner: partner) }
            Link("Find a local remodeler in NARI’s directory", destination: Self.directoryURL)
            if let property {
                NavigationLink { HomeDocumentsView(property: property, projectId: project.id, initialCategory: .estimate) } label: {
                    Label("Save or open contractor quotes", systemImage: "doc.on.doc")
                }
            }
            ForEach(quotes) { quote in
                VStack(alignment: .leading, spacing: 5) {
                    Text(quote.details.title).font(.headline)
                    if let amount = quote.details.quoteAmount {
                        Text(amount.formatted() + " " + amount.currency)
                        if amount.currency == project.currencyCode {
                            Button("Use in this scenario") { budgetText = ProjectInput.text(amount) }.font(.footnote)
                        }
                    } else { Text("Amount unrecorded").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        } header: { Text("Contractor quotes") } footer: {
            Text("You choose whom to contact and which details to send. Check licensing, insurance and references for the work you need.")
        }
    }

    private var recoverySection: some View {
        Section {
            if project.currencyCode == "USD" {
                Picker("Example project", selection: $benchmark) {
                    Text("Choose or enter your own").tag(Optional<RecoveryBenchmark>.none)
                    ForEach(RecoveryBenchmark.allCases, id: \.self) { option in Text(option.rawValue).tag(Optional(option)) }
                }
                .onChange(of: benchmark) { _, choice in recoveryText = choice.map { String($0.percent) } ?? "" }
            }
            if benchmark == nil {
                TextField("Assumed cost recovered (%)", text: $recoveryText).keyboardType(.decimalPad)
            } else if let benchmark {
                LabeledContent("Study estimate", value: "\(benchmark.percent)% of project cost")
            }
            if let budget, let pct = try? Decimal(recoveryText, format: .number), let impact = ProjectScenarios.recoveredCost(budget, percent: pct) {
                LabeledContent("Illustrative resale contribution", value: impact.formatted())
            } else if !recoveryText.isEmpty {
                Text("Use a project cost above and a percentage between 0 and 200.").font(.footnote)
            }
            Link("2025 Remodeling Impact Report", destination: Self.studyURL)
        } header: { Text("Possible resale impact") } footer: {
            Text("This scenario applies a recovery percentage to your cost. The examples use US national survey estimates for typical work on a 2,300 sq. ft. post-1978 home. Actual sale proceeds depend on your market, scope and condition.")
        }
    }

    private var financingSection: some View {
        Section {
            DisclosureGroup("Estimate a monthly payment") {
                TextField("Annual interest rate (%)", text: $rateText).keyboardType(.decimalPad)
                Picker("Term", selection: $termMonths) {
                    ForEach([12, 24, 36, 48, 60, 84, 120, 180, 240], id: \.self) { Text("\($0) months").tag($0) }
                }
                if let budget, let rate = try? Double(rateText, format: .number),
                   let payment = ProjectScenarios.monthlyPayment(principal: budget, annualRate: rate, months: termMonths) {
                    LabeledContent("Monthly principal and interest", value: payment.formatted())
                }
            }
            if let partner = ProjectReferral(kind: "Financing") { ProjectReferralLink(partner: partner) }
            Link("Understand home-equity borrowing", destination: Self.borrowingURL)
        } header: { Text("Paying for the work") } footer: {
            Text("Use terms from your lender. The illustration assumes you finance the full project cost at a fixed rate, with no fees.")
        }
    }

    private enum RecoveryBenchmark: String, CaseIterable {
        case steel = "New steel front door", closet = "Closet renovation", fiberglass = "New fiberglass front door"
        var percent: Int { switch self { case .steel: 100; case .closet: 83; case .fiberglass: 80 } }
    }

    private static let directoryURL = URL(string: "https://remodelingdoneright.nari.org/find-a-remodeler/")!
    private static let studyURL = URL(string: "https://www.nar.realtor/research-and-statistics/research-reports/remodeling-impact")!
    private static let borrowingURL = URL(string: "https://consumer.ftc.gov/articles/home-equity-loans-and-home-equity-lines-credit")!
}

private struct QuoteRequestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String
    @State private var target = ""

    init(project: Project) {
        _scope = State(initialValue: project.title)
    }

    private var request: String {
        var lines = ["Request for a written estimate", scope.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("Preferred timing: " + target) }
        lines.append("Please include labor, materials, permits, exclusions, estimated schedule and how long the quote is valid.")
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        Form {
            Section("Work to quote") { TextField("What would you like done?", text: $scope, axis: .vertical) }
            TextField("Preferred timing (optional)", text: $target)
            Section("Preview") { Text(request).textSelection(.enabled) }
            ShareLink(item: request, subject: Text("Request for a project estimate")) { Label("Share quote request", systemImage: "square.and.arrow.up") }
                .disabled(scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Request a quote").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
}
