import SwiftUI
import HomeCore
import HomeCoreTesting

/// Shopping list (spec 08 FR-INV-50..52, LLD §11.5, mockup 5.3): filters & bulbs due (linked chore due within
/// 14 days, no spares left) first, then running-low items. "Bought" clears the low flag with a new quantity, or
/// adds spares for a replacement; the list shares as plain text. Pushable (no own `NavigationStack`).
struct ShoppingListView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var property: Property?
    @State private var lines: [ShoppingLine] = []
    @State private var loaded = false
    @State private var locations: [UUID: ItemLocation] = [:]
    @State private var filter: TIK.ShoppingFilter = .all
    @State private var buying: ShoppingLine?
    @State private var editingStockCheck: ShoppingLine.StockReport?
    @State private var quantityText = ""
    @State private var errorText: String?

    private var today: LocalDate { env.clock.today }
    private var visible: [ShoppingLine] { lines.filter { filter.includes($0) } }
    private var supplies: [ShoppingLine] { visible.filter { $0.reason == .toDoSupply } }
    private var due: [ShoppingLine] { visible.filter { $0.reason == .replacementDue } }
    private var low: [ShoppingLine] { visible.filter { $0.reason == .low } }

    var body: some View {
        shoppingList
            .sheet(item: $editingStockCheck) { report in ChoreForm(choreID: report.id) }
            .feedbackPage("Shopping list")
            .navigationTitle("Shopping list")
            .toolbar { ToolbarItem(placement: .primaryAction) { shareButton } }
            .overlay { emptyState }
            .alert(buyTitle, isPresented: showsPurchase, presenting: buying) { line in
                purchaseActions(line)
            } message: { line in
                Text(purchaseMessage(line))
            }
            .alert("Something went wrong", isPresented: showsError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task { property = try? await env.plan.currentProperty() }
            .task(id: property?.id) { await observeList() }
    }

    private var shoppingList: some View {
        List {
            Section { filterPicker }
            supplySection
            if !due.isEmpty {
                Section("Filters & bulbs due") {
                    ForEach(due) { line in row(line, subtitle: "Replacement due · no spares left", symbol: "wrench.and.screwdriver") }
                }
            }
            if !low.isEmpty {
                Section("Running low") {
                    ForEach(low) { line in row(line, subtitle: lowSubtitle(line), symbol: nil) }
                }
            }
            if !lines.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("To-do supplies appear when you select missing items in a DIY plan. Low items come from the “running low” flag. Filters and bulbs come from appliances with a due to-do and no spares left.")
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(TIK.ShoppingFilter.allCases) { option in
                let count = lines.filter { option.includes($0) }.count
                Text("\(option.title) · \(count)").tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var supplySection: some View {
        if !supplies.isEmpty {
            Section("For your to-dos") {
                ForEach(supplies) { line in
                    if let checks = line.conflictingCounts {
                        countReview(line, checks: checks)
                    } else {
                        row(line, subtitle: "Buy " + TIK.quantityLabel(line.quantity, unit: line.unit), symbol: "checklist")
                    }
                }
            }
        }
    }

    private var shareButton: some View {
        ShareLink(item: TIK.shoppingText(visible)) { Image(systemName: "square.and.arrow.up") }
            .disabled(visible.isEmpty)
            .accessibilityLabel("Share list")
    }

    @ViewBuilder private var emptyState: some View {
        if loaded && lines.isEmpty {
            ContentUnavailableView("You’re stocked up.", systemImage: "cart",
                                   description: Text("Mark pantry items as running low to add them here."))
        }
    }

    private var showsPurchase: Binding<Bool> {
        Binding(get: { buying != nil }, set: { if !$0 { buying = nil } })
    }

    private var showsError: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    @ViewBuilder private func purchaseActions(_ line: ShoppingLine) -> some View {
        if line.reason != .toDoSupply {
            TextField(line.reason == .low ? "New quantity" : "Spares", text: $quantityText)
                .keyboardType(.decimalPad)
        }
        Button("Cancel", role: .cancel) {}
        Button(line.reason == .toDoSupply ? "Record purchase" : "Save") { Task { await bought(line) } }
    }

    private func purchaseMessage(_ line: ShoppingLine) -> String {
        if line.reason == .toDoSupply {
            let amount = TIK.quantityLabel(line.quantity, unit: line.unit)
            return "Add \(amount) to your inventory and clear the matching to-do requests."
        }
        return line.reason == .low ? "How many do you have now?" : "Add spares so the next replacement is covered."
    }

    private func observeList() async {
        guard let pid = property?.id else { return }
        for await update in env.inventory.observeShoppingList(property: pid, on: today) {
            lines = update
            loaded = true
            let ids = update.compactMap { line -> UUID? in
                if case .inventory(let id) = line.ref { return id }
                return nil
            }
            let locs = (try? await env.inventory.locations(of: ids)) ?? []
            locations = Dictionary(locs.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private var buyTitle: String {
        guard let b = buying else { return "" }
        if b.reason == .toDoSupply { return "Bought \(b.label)?" }
        return b.reason == .low ? "Bought \(b.label)" : "Add spares for \(b.label)"
    }

    private func row(_ line: ShoppingLine, subtitle: String, symbol: String?) -> some View {
        HStack(spacing: 12) {
            buyButton(line)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.label)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(line.reason == .replacementDue ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            if case .inventory(let id) = line.ref, let owner = locations[id]?.owner {
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
        }
    }

    private func buyButton(_ line: ShoppingLine) -> some View {
        Button { beginBuy(line) } label: {
            Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bought \(line.label)")
        .accessibilityIdentifier((line.reason == .toDoSupply ? "shopping.todo." : "shopping.stock.") + line.label)
    }

    private func countReview(_ line: ShoppingLine, checks: [ShoppingLine.StockReport]) -> some View {
        DisclosureGroup {
            Text("Open a to-do to correct its checked count or switch back to the catalog count.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(checks) { report in stockReportButton(report, unit: line.unit) }
        } label: {
            countReviewLabel(line, checks: checks)
        }
    }

    private func stockReportButton(_ report: ShoppingLine.StockReport, unit: String?) -> some View {
        let quantity = TIK.quantityLabel(Double(report.count), unit: unit)
        let reviewLabel = "Review \(report.taskTitle), checked \(report.count) \(unit ?? "")"
        return Button { editingStockCheck = report } label: {
            LabeledContent(report.taskTitle, value: quantity).frame(minHeight: 44)
        }
        .accessibilityLabel(Text(reviewLabel))
    }

    private func countReviewLabel(_ line: ShoppingLine, checks: [ShoppingLine.StockReport]) -> some View {
        let counts = Set(checks.map(\.count)).sorted().map(String.init).joined(separator: ", ")
        let summary = "Review checked counts: \(counts) \(line.unit ?? "")"
        return VStack(alignment: .leading, spacing: 3) {
            Label(line.label, systemImage: "questionmark.circle")
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func lowSubtitle(_ line: ShoppingLine) -> String {
        var parts: [String] = []
        let q = TIK.quantityLabel(line.quantity, unit: line.unit)
        if !q.isEmpty { parts.append("\(q) left") }
        if case .inventory(let id) = line.ref, let loc = locations[id] { parts.append(loc.displayPath) }
        return parts.joined(separator: " · ")
    }

    private func beginBuy(_ line: ShoppingLine) {
        Task {
            switch line.ref {
            case .inventory(let id):
                let item = try? await env.inventory.item(id)
                let q = TIK.boughtQuantity(current: item?.quantity ?? line.quantity ?? 0, threshold: item?.lowThreshold)
                quantityText = TIK.quantityText(q)
            default:
                quantityText = "2"
            }
            buying = line
        }
    }

    private func bought(_ line: ShoppingLine) async {
        let entered = Double(quantityText.replacingOccurrences(of: ",", with: "."))
        buying = nil
        do {
            if line.reason == .toDoSupply, let property {
                try await env.inventory.buySelectedSupply(line, propertyId: property.id)
                return
            }
            switch line.ref {
            case .inventory(let id):
                guard var item = try await env.inventory.item(id) else { return }
                if let q = entered { item.quantity = max(0, q) }
                item.isLow = false
                // Still at/below the threshold → stays low (and on the list), per the auto-flag rule.
                item = InventoryLogic.applyLowThreshold(item)
                try await env.inventory.update(item)
            case .thing(let tid):
                let n = max(1, entered ?? 1)
                guard let pid = property?.id, let thing = try await env.things.thing(tid) else { return }
                let all = try await env.inventory.items(InventoryQuery(propertyId: pid))
                if let spare = all.first(where: { $0.linkedThingId == tid }) {
                    try await env.inventory.adjustQuantity(spare.id, by: n)
                } else {
                    let extra = TIK.extra(for: thing.templateKey)
                    let draft = InventoryDraft(propertyId: pid, kind: .stored,
                                               name: TIK.spareName(templateKey: thing.templateKey, attributes: thing.attributes, thingName: thing.name),
                                               category: thing.templateKey == "light_fixture" ? "bulbs" : "filters",
                                               scope: thing.scope, quantity: n, unit: extra.spareUnit,
                                               lowThreshold: extra.spareLowThreshold, linkedThingId: tid)
                    _ = try await env.inventory.create(draft)
                }
            default:
                break
            }
        } catch {
            errorText = "Couldn’t update the list. \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { ShoppingListView() }.environment(AppEnvironment.preview())
}
