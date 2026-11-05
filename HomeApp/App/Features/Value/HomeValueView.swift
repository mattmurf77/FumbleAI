import SwiftUI
import HomeCore

struct HomeValueView: View {
    @Environment(AppEnvironment.self) private var env
    let property: Property
    @State private var snapshot: HomeValueSnapshot?
    @State private var route: ValueEditRoute?
    @State private var showPastWork = false
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        List {
            if let snapshot {
                Section {
                    if let latest = snapshot.latestEstimate {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(latest.displayAmount).font(.title.weight(.semibold))
                            Text("\(latest.source) · \(ScheduleFormat.longDay(latest.asOf))").font(.subheadline).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    } else { Text("Save a dated estimate from an appraiser, agent or online source.").foregroundStyle(.secondary) }
                    Button { route = .create } label: { Label("Add value reference", systemImage: "plus.circle") }
                        .accessibilityIdentifier("value.add")
                } header: { Text("Latest estimate") } footer: { Text("Value references stay on this device. Improvement spending is tracked separately.") }
                Section("Completed investments") {
                    if snapshot.investments.isEmpty { Text("Record what changed, when it was finished and what you spent.").foregroundStyle(.secondary) }
                    Button { showPastWork = true } label: { Label("Record past work", systemImage: "hammer") }
                    ForEach(snapshot.investments) { work in
                        NavigationLink { ProjectDetailView(projectID: work.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(work.title)
                                Text([work.date.map(ScheduleFormat.longDay) ?? "Completion date unrecorded", work.actual.map { $0.formatted() + " " + $0.currency } ?? "Cost unrecorded"].joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink { HomeBriefBuilder(propertyId: property.id) } label: { Label("Home Brief", systemImage: "doc.richtext") }
                        .accessibilityIdentifier("value.homeBrief")
                } footer: { Text("Choose completed work for a PDF you can share with a buyer or agent.") }
                if !snapshot.references.isEmpty {
                    Section("Reference history") {
                        ForEach(snapshot.references) { ref in
                            Button { route = .edit(ref) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ref.kind.label).font(.caption).foregroundStyle(.secondary)
                                    Text(ref.displayAmount).font(.headline)
                                    Text("\(ref.source) · \(ScheduleFormat.longDay(ref.asOf))").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.tint(.primary)
                        }
                    }
                }
                Section {
                    Link(destination: URL(string: "https://www.redfin.com/what-is-my-home-worth")!) {
                        Label("Research recent sales on Redfin", systemImage: "arrow.up.right.square")
                    }
                } footer: { Text("Opens Redfin in your browser. You choose whether to enter an address there.") }
            } else if failed {
                ContentUnavailableView { Label("Home value unavailable", systemImage: "exclamationmark.circle") } actions: { Button("Try again") { retry += 1 } }
            } else { ProgressView("Loading your home history…") }
        }
        .navigationTitle("Home value")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $route) { item in NavigationStack { ValueReferenceEditor(property: property, original: item.reference) } }
        .sheet(isPresented: $showPastWork) { ProjectForm(spaceID: nil, levelID: nil, initialStatus: .done) }
        .task(id: "\(property.id)-\(retry)") {
            failed = false; snapshot = nil
            for await next in env.homeValue.observe(propertyId: property.id) { snapshot = next }
            if !Task.isCancelled { snapshot = nil; failed = true }
        }
    }
}

private enum ValueEditRoute: Identifiable {
    case create, edit(HomeValueReference)
    var reference: HomeValueReference? { if case .edit(let r) = self { return r }; return nil }
    var id: String { reference?.id.uuidString ?? "create" }
}

private extension HomeValueReference {
    var displayAmount: String {
        let left = amount.formatted(showCents: amount.cents % 100 != 0)
        return (upper.map { left + " – " + $0.formatted(showCents: $0.cents % 100 != 0) } ?? left) + " " + amount.currency
    }
}

private struct ValueReferenceEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let property: Property
    let original: HomeValueReference?
    @State private var kind: HomeValueReference.Kind
    @State private var source: String
    @State private var date: Date
    @State private var amount: String
    @State private var upper: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var currency: String { original?.amount.currency ?? property.currencyCode }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }

    init(property: Property, original: HomeValueReference?) {
        self.property = property; self.original = original
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        _kind = State(initialValue: original?.kind ?? .appraisal)
        _source = State(initialValue: original?.source ?? "")
        _date = State(initialValue: original?.asOf.date(atMinutes: 720, calendar: calendar) ?? Date())
        _amount = State(initialValue: original?.amount.decimal.formatted(.number.grouping(.never)) ?? "")
        _upper = State(initialValue: original?.upper?.decimal.formatted(.number.grouping(.never)) ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) { ForEach(HomeValueReference.Kind.knownCases, id: \.self) { Text($0.label).tag($0) } }
                TextField(kind == .comparableSale ? "Comparable address and source" : "Source, e.g. agent assessment", text: $source).accessibilityIdentifier("value.source")
                DatePicker("As of", selection: $date, in: ...max(Date(), original?.asOf.date(atMinutes: 720, calendar: calendar) ?? .distantPast), displayedComponents: .date)
            }
            Section(currency) {
                TextField("Amount", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("value.amount")
                if kind.estimatesThisHome { TextField("Upper amount (optional)", text: $upper).keyboardType(.decimalPad) }
            }
            if original != nil { Button("Delete reference", role: .destructive) { confirmDelete = true } }
        }
        .disabled(busy).interactiveDismissDisabled(busy)
        .navigationTitle(original == nil ? "Add reference" : "Edit reference").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await commit(delete: false) } }.disabled(busy).accessibilityIdentifier("value.save") }
        }
        .confirmationDialog("Permanently delete this reference?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete reference", role: .destructive) { Task { await commit(delete: true) } }
        }
        .alert("Check the reference", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func input(_ raw: String) throws -> Money? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let sep = Locale.current.decimalSeparator ?? "."
        let normalized = value.replacingOccurrences(of: sep, with: ".")
        guard normalized.range(of: #"^[0-9]{1,13}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let n = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { throw HomeValueProblem("Enter a positive amount with up to two decimal places.") }
        return Money(major: n, currency: currency)
    }
    @MainActor private func commit(delete: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if delete, let original { try await env.homeValue.remove(original) }
            else {
                guard let low = try input(amount) else { throw HomeValueProblem("Enter an amount.") }
                let ref = HomeValueReference(id: original?.id ?? UUID(), propertyId: property.id, kind: kind,
                                             source: source.trimmingCharacters(in: .whitespacesAndNewlines), asOf: LocalDate(date, calendar: calendar),
                                             amount: low, upper: kind.estimatesThisHome ? try input(upper) : nil)
                try await env.homeValue.save(ref, replacing: original)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
