import SwiftUI
import HomeCore

/// One editable plan for a recommendation and for a saved to-do. Nothing is bought or added to stock here.
struct DIYReadinessView: View {
    @Environment(AppEnvironment.self) private var env
    let propertyId: UUID
    @Binding var plan: [ChoreSupply]
    @State private var items: [InventoryItem]?
    @State private var things: [Thing]?
    @State private var locations: [UUID: String] = [:]
    @State private var names = SchedulePlaceNames()
    @State private var adding = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach($plan) { $supply in
                let stock = SupplyReadiness(supply, propertyId: propertyId, inventory: items ?? [], things: things ?? [])
                let missing = max(0, Double(supply.quantity) - (stock.onHand ?? 0))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Supply or tool name", text: $supply.name)
                        Stepper("Quantity needed: \(supply.quantity)", value: $supply.quantity, in: 1...9_999)
                        TextField("Unit, e.g. ea or box", text: $supply.unit)
                        Toggle("Reusable equipment", isOn: $supply.isEquipment)
                        if let count = supply.confirmedOnHand {
                            Stepper("Checked at home: \(count)", value: Binding(get: { supply.confirmedOnHand ?? 0 }, set: { supply.confirmedOnHand = $0 }), in: 0...9_999)
                            Button("Use catalog count") { supply.confirmedOnHand = nil }
                        } else { Button("Enter count checked at home") { supply.confirmedOnHand = Int(min(9_999, stock.onHand ?? 0)) } }
                        if items != nil && things != nil && (missing > 0 || supply.requested) {
                            Toggle(missing > 0 ? "Add \(Int(ceil(missing))) \(supply.unit) to Shopping list" : "Requested for Shopping list", isOn: $supply.requested)
                        }
                        Button("Remove from this to-do", role: .destructive) { plan.removeAll { $0.id == supply.id } }
                    }.padding(.top, 8).buttonStyle(.borderless)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(supply.name) · \(supply.quantity) \(supply.unit)").font(.subheadline.weight(.semibold))
                        if items == nil || things == nil { Text("Checking home records…").font(.caption) }
                        else {
                            let status = stock.onHand.map { amount in
                                (amount >= Double(supply.quantity) ? "Ready · " : (amount == 0 ? "" : "Partial stock · ")) + amount.formatted() + " " + supply.unit + " on hand"
                            } ?? "Check at home"
                            Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("supplies.readiness." + supply.name)
                            let paths = Set(stock.inventory.compactMap { locations[$0.id] } + stock.equipment.map { names.name($0.scope) }).filter { !$0.isEmpty }.sorted()
                            if !paths.isEmpty { Text(paths.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            if supply.requested && missing > 0 { Label("Selected for Shopping list", systemImage: "cart").font(.caption) }
                        }
                    }
                }
            }
            HStack {
                TextField("Add supply or equipment", text: $adding).onSubmit(add).accessibilityIdentifier("supplies.name")
                Button("Add", action: add).buttonStyle(.borderless).disabled(adding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("supplies.add")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .task(id: propertyId) {
            names = await SchedulePlaceNames.load(env, property: propertyId)
            for await values in env.inventory.observeItems(.init(propertyId: propertyId)) {
                items = values
                let resolved = (try? await env.inventory.locations(of: values.map(\.id))) ?? []
                locations = Dictionary(resolved.map { ($0.id, $0.displayPath) }, uniquingKeysWith: { first, _ in first })
            }
        }
        .task(id: propertyId) { for await values in env.things.observeThings(.init(propertyId: propertyId)) { things = values } }
    }
    private func add() {
        let next = ChoreSupply(name: adding.trimmingCharacters(in: .whitespacesAndNewlines))
        do { try ChoreSupply.validate(plan + [next]); plan.append(next); adding = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
