import SwiftUI
import HomeCore

/// Name matching proposes possible substitutes. Only the homeowner can choose a different item.
struct HomeSupplyOption: Identifiable {
    let name: String
    let isEquipment: Bool
    let onHand: Double
    let unit: String
    let locations: [String]
    var id: String { ChoreSupply.normalize(name) }

    static func options(for need: ChoreSupply, property: UUID, items: [InventoryItem], things: [Thing],
                        locationOfItem: (InventoryItem) -> String, locationOfThing: (Thing) -> String) -> [Self] {
        let unit = ChoreSupply.unitKey(need.unit)
        let stock = items.filter { $0.propertyId == property && $0.deletedAt == nil && ChoreSupply.unitKey($0.unit) == unit }
        let owned = unit == "ea" ? things.filter { $0.propertyId == property && $0.deletedAt == nil && $0.ownership == .owned } : []
        let stockGroups = Dictionary(grouping: stock) { ChoreSupply.normalize($0.name) }
        let toolGroups = Dictionary(grouping: owned) { ChoreSupply.normalize($0.name) }
        return Set(stockGroups.keys).union(toolGroups.keys).compactMap { key in
            let stored = stockGroups[key] ?? [], tools = toolGroups[key] ?? []
            guard let name = (stored.map(\.name) + tools.map(\.name)).sorted().first, !key.isEmpty else { return nil }
            let reusable = need.isEquipment || (stored.isEmpty && !tools.isEmpty)
            let selected = ChoreSupply(name: name, unit: need.unit, isEquipment: reusable)
            let readiness = SupplyReadiness(selected, propertyId: property, inventory: stored, things: tools)
            let places = Set(readiness.inventory.map(locationOfItem) + readiness.equipment.map(locationOfThing))
                .filter { !$0.isEmpty }.sorted()
            return Self(name: name, isEquipment: reusable, onHand: readiness.onHand ?? 0, unit: need.unit, locations: places)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isPossibleMatch(for need: ChoreSupply) -> Bool {
        func words(_ name: String) -> Set<String> {
            Set(ChoreSupply.normalize(name).split { !$0.isLetter && !$0.isNumber }.map(String.init))
                .subtracting(["a", "of", "the", "and", "for", "with", "kit", "set", "work", "replacement"])
        }
        return !words(need.name).isDisjoint(with: words(name))
    }
}

struct HomeSupplyPicker: View {
    @Environment(\.dismiss) private var dismiss
    let need: ChoreSupply
    let options: [HomeSupplyOption]
    let choose: (HomeSupplyOption) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let visible = options.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                let possible = visible.filter { $0.isPossibleMatch(for: need) }
                let others = visible.filter { !$0.isPossibleMatch(for: need) }
                if !possible.isEmpty { Section("Possible matches for " + need.name) { rows(possible) } }
                if !others.isEmpty { Section("Other items in this unit") { rows(others) } }
                if visible.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Choose an item at home")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search your home")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func rows(_ choices: [HomeSupplyOption]) -> some View {
        ForEach(choices) { choice in
            Button {
                choose(choice)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.name).font(.headline)
                    Text(choice.onHand.formatted() + " " + choice.unit + " on hand").foregroundStyle(.secondary)
                    if !choice.locations.isEmpty {
                        Text(choice.locations.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("supplies.option." + choice.name)
        }
    }
}
