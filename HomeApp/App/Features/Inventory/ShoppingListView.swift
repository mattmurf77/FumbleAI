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
    @State private var quantityText = ""
    @State private var errorText: String?

    private var today: LocalDate { env.clock.today }
    private var visible: [ShoppingLine] { lines.filter { filter.includes($0) } }
    private var due: [ShoppingLine] { visible.filter { $0.reason == .replacementDue } }
    private var low: [ShoppingLine] { visible.filter { $0.reason == .low } }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(TIK.ShoppingFilter.allCases) { f in
                        Text("\(f.title) · \(lines.filter { f.includes($0) }.count)").tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
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
                    Text("Low items come from the “running low” flag. Filters and bulbs come from appliances with a due to-do and no spares left.")
                }
            }
        }
        .navigationTitle("Shopping list")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: TIK.shoppingText(visible)) { Image(systemName: "square.and.arrow.up") }
                    .disabled(visible.isEmpty)
                    .accessibilityLabel("Share list")
            }
        }
        .overlay {
            if loaded && lines.isEmpty {
                ContentUnavailableView("You’re stocked up.", systemImage: "cart",
                                       description: Text("Mark pantry items as running low to add them here."))
            }
        }
        .alert(buyTitle, isPresented: Binding(get: { buying != nil }, set: { if !$0 { buying = nil } }), presenting: buying) { line in
            TextField(line.reason == .low ? "New quantity" : "Spares", text: $quantityText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await bought(line) } }
        } message: { line in
            Text(line.reason == .low ? "How many do you have now?" : "Add spares so the next replacement is covered.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task { property = try? await env.plan.currentProperty() }
        .task(id: property?.id) {
            guard let pid = property?.id else { return }
            for await update in env.inventory.observeShoppingList(property: pid, on: today) {
                lines = update
                loaded = true
                let ids = update.compactMap { l -> UUID? in if case .inventory(let id) = l.ref { return id }; return nil }
                let locs = (try? await env.inventory.locations(of: ids)) ?? []
                locations = Dictionary(locs.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private var buyTitle: String {
        guard let b = buying else { return "" }
        return b.reason == .low ? "Bought \(b.label)" : "Add spares for \(b.label)"
    }

    private func row(_ line: ShoppingLine, subtitle: String, symbol: String?) -> some View {
        HStack(spacing: 12) {
            Button { beginBuy(line) } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bought \(line.label)")
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
