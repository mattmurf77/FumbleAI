import SwiftUI
import HomeCore

/// All scopes are browsable before a plan exists. Room storage remains available for arranging shelves and bins.
struct EquipmentCatalogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var propertyId: UUID?
    @State private var places = TIK.PlaceIndex()
    @State private var inventory: [InventoryItem]?
    @State private var owned: [Thing]?
    @State private var locations: [UUID: ItemLocation] = [:]
    @State private var query = ""
    @State private var filter: CatalogFilter = .all
    @State private var edit: CatalogEdit?
    @State private var refresh = 0
    @State private var loadedProperty = false

    private var rows: [CatalogRow] { CatalogRow.make(propertyId: propertyId, inventory: inventory ?? [], owned: owned ?? [], places: places, locations: locations) }
    var body: some View {
        List {
            if propertyId != nil {
                Section {
                    Button { edit = .addStock } label: { Label("Add tool or supply", systemImage: "plus.circle") }
                        .accessibilityIdentifier("equipment.addStock")
                    Button { edit = .addEquipment } label: { Label("Add equipment with specifications", systemImage: "wrench.and.screwdriver") }
                        .accessibilityIdentifier("equipment.addThing")
                    if !places.spaces.isEmpty {
                        NavigationLink { StorageRoomsList() } label: { Label("Browse rooms and storage spots", systemImage: "archivebox") }
                            .accessibilityIdentifier("equipment.rooms")
                    }
                }
                if inventory == nil || owned == nil { ProgressView("Loading your equipment…") }
                else if rows.isEmpty {
                    ContentUnavailableView("No equipment or inventory yet", systemImage: "shippingbox", description: Text("Add a tool with its quantity, or keep an equipment record with its model and warranty. You can choose a room later."))
                } else {
                    Section {
                        Picker("Show", selection: $filter) { ForEach(CatalogFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        let result = rows.filter { $0.matches(query, filter: filter) }
                        if result.isEmpty { Text("No matching items").foregroundStyle(.secondary) }
                        ForEach(result) { row in
                            Button { edit = row.edit } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.headline).foregroundStyle(.primary)
                                    Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                                    Text(row.place).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 2)
                            }.accessibilityIdentifier("equipment.item." + row.id)
                        }
                    } header: { Text("Your catalog") }
                }
            } else if loadedProperty {
                ContentUnavailableView("Home unavailable", systemImage: "house", description: Text("Open your home to see its inventory."))
            } else { ProgressView("Opening catalog…") }
        }
        .navigationTitle("Tools & equipment")
        .searchable(text: $query, prompt: "Item, model or location")
        .task(id: refresh) {
            let (home, index) = await TIK.loadPlaces(env)
            propertyId = home?.id; places = index; loadedProperty = true
            guard let pid = home?.id else { return }
            await loadLocations((try? await env.inventory.items(.init(propertyId: pid))) ?? [])
        }
        .task(id: propertyId) {
            guard let pid = propertyId else { return }
            for await values in env.inventory.observeItems(.init(propertyId: pid)) {
                inventory = values; await loadLocations(values)
            }
        }
        .task(id: propertyId) {
            guard let pid = propertyId else { return }
            for await values in env.things.observeThings(.init(propertyId: pid, ownership: .owned)) { owned = values }
        }
        .onAppear { refresh += 1 }
        .sheet(item: $edit, onDismiss: { refresh += 1 }) { destination in
            switch destination {
            case .addStock: InventoryForm(spaceID: nil, initialKind: .stored)
            case .addEquipment: ThingForm(spaceID: nil)
            case .inventory(let id): InventoryForm(itemID: id)
            case .thing(let id): ThingForm(thingID: id)
            }
        }
    }
    /// Chunked to stay within SQLite's bound variable limit on large household catalogs.
    @MainActor private func loadLocations(_ records: [InventoryItem]) async {
        let ids = records.map(\.id)
        var current: [UUID: ItemLocation] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            guard !Task.isCancelled else { return }
            let entries = (try? await env.inventory.locations(of: Array(ids[start..<min(start + 400, ids.count)]))) ?? []
            for location in entries { current[location.id] = location }
        }
        if !Task.isCancelled { locations = current }
    }
}

enum CatalogFilter: String, CaseIterable { case all = "All", stock = "With quantity", equipment = "With specs" }

enum CatalogEdit: Identifiable {
    case addStock, addEquipment, inventory(UUID), thing(UUID)
    var id: String {
        switch self {
        case .addStock: return "new-stock"
        case .addEquipment: return "new-equipment"
        case .inventory(let id): return "inventory." + id.uuidString
        case .thing(let id): return "thing." + id.uuidString
        }
    }
}

struct CatalogRow: Identifiable {
    let edit: CatalogEdit
    let title: String
    let detail: String
    let place: String
    let searchTerms: String
    let filter: CatalogFilter
    var id: String { edit.id }
    func matches(_ search: String, filter selected: CatalogFilter) -> Bool {
        guard selected == .all || selected == filter else { return false }
        let text = [title, detail, place, searchTerms].joined(separator: " ")
        return search.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }
    static func make(propertyId: UUID?, inventory: [InventoryItem], owned: [Thing], places: TIK.PlaceIndex, locations: [UUID: ItemLocation]) -> [Self] {
        guard let propertyId else { return [] }
        let stock = inventory.filter { $0.propertyId == propertyId && $0.deletedAt == nil }.map { item in
            let spot = locations[item.id]?.spotPath
            let place = [places.label(for: item.scope), spot].compactMap { $0 }.joined(separator: " › ")
            let detail = "On hand · " + TIK.quantityLabel(item.quantity, unit: item.unit) + " · " + TIK.kindTitle(item.kind)
            return Self(edit: .inventory(item.id), title: item.name, detail: detail, place: place, searchTerms: item.category ?? "", filter: .stock)
        }
        let assets = owned.filter { $0.propertyId == propertyId && $0.deletedAt == nil && $0.ownership == .owned }.map { item in
            Self(edit: .thing(item.id), title: item.name, detail: "Owned equipment · " + item.category.rawValue.capitalized,
                 place: places.label(for: item.scope), searchTerms: [item.brand, item.model, item.serial].compactMap { $0 }.joined(separator: " "), filter: .equipment)
        }
        return (stock + assets).sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
