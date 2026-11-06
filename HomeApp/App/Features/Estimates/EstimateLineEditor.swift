import SwiftUI
import HomeCore

/// Quantity, unit, and rate are entered separately so unpriced work stays visible.
struct EstimateLineEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let line: WorkEstimateLine
    let plan: WorkEstimate
    let propertyId: UUID
    let country: String?
    let done: (WorkEstimateLine?) -> Void
    @State private var kind: WorkEstimateLine.Kind
    @State private var name: String
    @State private var quantity: String
    @State private var unit: String
    @State private var packSize: String
    @State private var onHand: String
    @State private var low: String
    @State private var high: String
    @State private var basis: String
    @State private var stockPicker = false
    @State private var stockOptions: [HomeSupplyOption] = []
    @State private var error: String?

    init(line: WorkEstimateLine, plan: WorkEstimate, propertyId: UUID, country: String?, done: @escaping (WorkEstimateLine?) -> Void) {
        self.line = line; self.plan = plan; self.propertyId = propertyId; self.country = country; self.done = done
        _kind = State(initialValue: line.kind)
        _name = State(initialValue: line.name)
        _quantity = State(initialValue: estimateNumberText(line.quantity))
        _unit = State(initialValue: line.unit)
        _packSize = State(initialValue: estimateNumberText(line.packSize))
        _onHand = State(initialValue: estimateNumberText(line.confirmedOnHand))
        _low = State(initialValue: ProjectInput.text(line.unitPrice))
        _high = State(initialValue: ProjectInput.text(line.highUnitPrice))
        _basis = State(initialValue: line.source ?? "")
    }

    private var ownTime: Bool { kind == .labor && plan.mode == .diy }
    private var canUseStock: Bool { kind == .material || (kind == .equipment && ChoreSupply.unitKey(unit) == "ea") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item or service", text: $name).accessibilityIdentifier("estimate.item.name")
                    Picker("Type", selection: $kind) {
                        ForEach(WorkEstimateLine.Kind.allCases.filter { $0 != .wholeJob || plan.lines.allSatisfy { $0.id == line.id } }, id: \.self) { Text($0.estimateLabel).tag($0) }
                    }.onChange(of: kind) { old, new in
                        if new == .wholeJob { quantity = "1"; unit = "job" }
                        else if new == .labor { unit = "hr" }
                        else if old == .labor && unit == "hr" { unit = "ea" }
                        onHand = ""
                    }
                    EstimateNumberField(title: ownTime ? "Hours" : "Quantity needed", text: $quantity, id: "estimate.item.quantity")
                    if !ownTime {
                        TextField("Unit, e.g. ea, sq ft, day", text: $unit)
                            .onChange(of: unit) { _, _ in onHand = "" }
                    }
                }
                if ownTime {
                    Section { Text("Your own time is tracked in hours and adds no cash charge.").font(.footnote) }
                } else {
                    Section {
                        if kind == .material {
                            EstimateNumberField(title: "Units per pack", text: $packSize, id: "estimate.item.pack")
                        }
                        EstimateTradeRateMenu(mode: plan.mode, kind: kind, unit: unit, currency: plan.currency, country: country) { rate in
                            low = ProjectInput.text(rate.low)
                            high = ProjectInput.text(rate.high)
                            basis = rate.sourceNote
                        }
                        estimatePriceField("Price or low rate", text: $low, id: "estimate.item.low")
                        estimatePriceField("High rate (optional)", text: $high, id: "estimate.item.high")
                    } header: {
                        Text("Rate per " + (ownTime ? "hour" : (!packSize.isEmpty && kind == .material ? "pack" : (unit.isEmpty ? "unit" : unit))) + " · " + plan.currency)
                    } footer: { Text("For a flat charge, enter quantity 1. Leave the price blank until you know it.") }
                }
                if canUseStock {
                    Section {
                        EstimateNumberField(title: "Usable amount at home", text: $onHand, id: "estimate.item.onHand")
                        Button("Check my home inventory") { Task { await openStock() } }
                            .disabled(unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: { Text("Owned supplies or equipment") } footer: {
                        Text("Confirm the amount in the same unit before deducting it. This estimate leaves your inventory counts intact.")
                    }
                }
                Section("Price source or terms") {
                    TextField("Store, quote date, link or conditions", text: $basis, axis: .vertical).lineLimit(2...8)
                }
                if plan.lines.contains(where: { $0.id == line.id }) {
                    Button("Remove cost item", role: .destructive) { done(nil); dismiss() }
                }
            }
            .alert("Check this cost item", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .navigationTitle("Cost item").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save item", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("estimate.item.save")
                }
            }
            .sheet(isPresented: $stockPicker) {
                NavigationStack {
                    List {
                        if stockOptions.isEmpty { Text("No recorded stock with this unit. Enter the amount you checked at home.") }
                        ForEach(stockOptions) { option in
                            Button {
                                onHand = estimateNumberText(Decimal(option.onHand))
                                stockPicker = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.name)
                                    Text("Use up to " + option.onHand.formatted() + " " + option.unit + " on hand")
                                        .foregroundStyle(.secondary)
                                    if !option.locations.isEmpty { Text(option.locations.joined(separator: " · ")).font(.caption) }
                                }
                            }
                        }
                    }
                    .navigationTitle("Confirm stock to use").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stockPicker = false } } }
                }
            }
        }
    }

    private func estimatePriceField(_ label: String, text: Binding<String>, id: String) -> some View {
        LabeledContent(label) {
            TextField("Unknown", text: text).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                .accessibilityLabel(label).accessibilityIdentifier(id)
        }
    }

    @MainActor private func openStock() async {
        do {
            async let items = env.inventory.items(.init(propertyId: propertyId))
            async let things = env.things.things(.init(propertyId: propertyId))
            let (inventory, equipment) = try await (items, things)
            let places = await SchedulePlaceNames.load(env, property: propertyId)
            let paths = try await env.inventory.locations(of: inventory.map(\.id))
            let locations = Dictionary(paths.map { ($0.id, $0.displayPath) }, uniquingKeysWith: { first, _ in first })
            let need = ChoreSupply(name: name, unit: unit, isEquipment: kind == .equipment)
            stockOptions = HomeSupplyOption.options(for: need, property: propertyId, items: inventory,
                things: kind == .equipment ? equipment : [], locationOfItem: { locations[$0.id] ?? places.name($0.scope) },
                locationOfThing: { places.name($0.scope) }).filter { $0.onHand > 0 }
            stockPicker = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            func money(_ input: String) throws -> Money? {
                switch ProjectInput.money(input, currency: plan.currency) {
                case .empty: return nil
                case .value(let amount): return amount
                case .invalid(let message): throw WorkEstimateError(message)
                }
            }
            let lowPrice = ownTime ? nil : try money(low)
            let highPrice = ownTime ? nil : try money(high)
            var source = EstimateTradeRate.sourceAfterEditing(basis, low: lowPrice, high: highPrice)
            if let original = line.source, source == original, !original.hasPrefix("Owner-adjusted rates."),
               lowPrice != line.unitPrice || highPrice != line.highUnitPrice {
                source = "Owner-adjusted rates. Previous basis: " + original
            }
            let updated = try WorkEstimateLine(id: line.id, kind: kind, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: estimateNumber(quantity), unit: ownTime ? "hr" : unit.trimmingCharacters(in: .whitespacesAndNewlines),
                confirmedOnHand: canUseStock ? estimateNumber(onHand) : nil, packSize: kind == .material ? estimateNumber(packSize) : nil,
                unitPrice: lowPrice, highUnitPrice: highPrice, source: source)
            _ = try WorkEstimate(mode: plan.mode, currency: plan.currency, lines: [updated]).totals()
            done(updated)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct EstimateNumberField: View {
    let title: String
    @Binding var text: String
    let id: String
    var body: some View {
        LabeledContent(title) {
            TextField("Unknown", text: $text).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                .accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
}

func estimateNumberText(_ n: Decimal?) -> String {
    n?.formatted(.number.grouping(.never).precision(.fractionLength(0...9))) ?? ""
}

func estimateNumber(_ text: String) throws -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let separator = Locale.current.decimalSeparator ?? "."
    let raw = trimmed.replacingOccurrences(of: separator, with: ".")
    guard raw.range(of: #"^(?:[0-9]+(?:\.[0-9]{0,9})?|\.[0-9]{1,9})$"#, options: .regularExpression) != nil,
          let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
        throw WorkEstimateError("Enter a nonnegative number with up to nine decimal places.")
    }
    return number
}
