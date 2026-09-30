import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit a pantry, clothing, stored or other item (spec 08 FR-INV-20..42).
///
/// - `InventoryForm(spaceID:)` — "+" → Inventory item (location = that room; nil = whole house).
/// - `InventoryForm(spotID:)` — "Add item here" from a storage spot.
/// - `InventoryForm(spareFor:)` — a thing's "Track spares" (kind stored, linked, low threshold 1, FR-THG-20).
/// - `InventoryForm(itemID:)` — edit / delete.
/// Create modes offer "Save and add another" (keeps kind, owner and location, FR-INV-22).
/// Self-contained: presents its own `NavigationStack`; show it in a sheet.
struct InventoryForm: View {
    private enum Mode {
        case create(UUID?)
        case inSpot(UUID)
        case spare(Thing)
        case edit(UUID)
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    private let onSaved: ((InventoryItem) -> Void)?

    @State private var state = TIK.InventoryFormState()
    @State private var original: InventoryItem?
    @State private var property: Property?
    @State private var places = TIK.PlaceIndex()
    @State private var people: [Person] = []
    @State private var spots: [SpotNode] = []
    @State private var linkedThing: Thing?
    @State private var loaded = false
    @State private var saving = false
    @State private var addedCount = 0
    @State private var lastAdded: String?
    @State private var confirmDelete = false
    @State private var errorText: String?

    init(spaceID: UUID?, onSaved: ((InventoryItem) -> Void)? = nil) { mode = .create(spaceID); self.onSaved = onSaved }
    init(spotID: UUID, onSaved: ((InventoryItem) -> Void)? = nil) { mode = .inSpot(spotID); self.onSaved = onSaved }
    init(spareFor thing: Thing, onSaved: ((InventoryItem) -> Void)? = nil) { mode = .spare(thing); self.onSaved = onSaved }
    init(itemID: UUID, onSaved: ((InventoryItem) -> Void)? = nil) { mode = .edit(itemID); self.onSaved = onSaved }

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var today: LocalDate { env.clock.today }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $state.kind) {
                        ForEach(InventoryItem.Kind.knownCases, id: \.self) { Text(TIK.kindTitle($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $state.name)
                    categoryRow
                }
                Section("Owner") {
                    TIK.PersonPicker(title: "Owner", personId: $state.ownerId, people: $people, propertyId: property?.id)
                }
                locationSection
                quantitySection
                if state.kind == .clothing || (state.kind == .stored && state.season != nil) {
                    clothingSection
                } else if state.kind == .stored {
                    Section {
                        Picker("Season", selection: $state.season) { seasonOptions }
                    } footer: {
                        Text("Optional. Seasonal decor and gear can carry a season too.")
                    }
                }
                if state.kind == .pantry { pantrySection }
                if let linkedThing {
                    Section {
                        LabeledContent("Spare for", value: linkedThing.name)
                        Button("Unlink", role: .destructive) { state.linkedThingId = nil; self.linkedThing = nil }
                    } footer: {
                        Text("When a linked to-do is due and this runs out, it goes on the shopping list.")
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $state.notes, axis: .vertical).lineLimit(1...5)
                }
                if !isEdit {
                    Section {
                        Button("Save and add another") { Task { await save(addAnother: true) } }
                            .disabled(!state.canSave || saving || property == nil)
                    } footer: {
                        if let lastAdded {
                            Text("Added “\(lastAdded)”\(addedCount > 1 ? " · \(addedCount) items so far" : "").")
                        }
                    }
                } else {
                    Section { Button("Delete", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(isEdit ? "Item" : (isSpare ? "Track spares" : "New \(TIK.kindTitle(state.kind)) Item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(addedCount > 0 ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(addAnother: false) } }
                        .disabled(!state.canSave || saving || property == nil)
                }
            }
            .confirmationDialog("Delete “\(state.trimmedName)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It stays in Recently Deleted for 30 days.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task { await load() }
            .task(id: state.scope) { await loadSpots() }
        }
    }

    private var isSpare: Bool { if case .spare = mode { return true }; return false }

    // MARK: Sections

    private var categoryRow: some View {
        HStack {
            TextField("Category", text: $state.category)
            let suggestions = TIK.categorySuggestions(for: state.kind)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { s in Button(s.capitalized) { state.category = s } }
                } label: {
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Category suggestions")
            }
        }
    }

    private var locationSection: some View {
        Section {
            TIK.PlacePicker(title: "Place", scope: $state.scope, places: places)
            if state.scope.spaceId != nil && !spots.isEmpty {
                Picker("Spot", selection: $state.storageSpotId) {
                    Text("Room (no spot)").tag(UUID?.none)
                    ForEach(TIK.flatten(spots)) { n in Text(n.path).tag(UUID?.some(n.id)) }
                }
                .pickerStyle(.navigationLink)
            }
        } header: {
            Text("Location")
        } footer: {
            if state.scope.spaceId != nil && spots.isEmpty {
                Text("Add shelves, closets or bins to this room in Storage to track exactly where things are.")
            }
        }
    }

    private var quantitySection: some View {
        Section("Quantity") {
            Stepper {
                HStack {
                    Text("Quantity")
                    Spacer()
                    TextField("1", value: $state.quantity, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
            } onIncrement: {
                state.quantity += 1
            } onDecrement: {
                state.quantity = max(0, state.quantity - 1)
            }
            Picker("Unit", selection: $state.unit) {
                ForEach(unitChoices, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var unitChoices: [String] {
        TIK.inventoryUnits.contains(state.unit) || state.unit.isEmpty ? TIK.inventoryUnits : TIK.inventoryUnits + [state.unit]
    }

    @ViewBuilder
    private var seasonOptions: some View {
        Text("None").tag(Season?.none)
        Text("Summer").tag(Season?.some(.summer))
        Text("Winter").tag(Season?.some(.winter))
        Text("All-year").tag(Season?.some(.allYear))
    }

    private var clothingSection: some View {
        Section {
            Picker("Season", selection: $state.season) { seasonOptions }
            if state.kind == .clothing {
                Picker("State", selection: $state.inRotation) {
                    Text("In rotation").tag(true)
                    Text("Stored").tag(false)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Season")
        } footer: {
            if state.kind == .clothing {
                Text("Seasonal swap lists stored items for the coming season and in-rotation items to put away. All-year items never appear there.")
            }
        }
    }

    private var pantrySection: some View {
        Section {
            TIK.OptionalDateRow(title: "Expires", date: $state.expiresOn, calendar: env.clock.calendar, defaultDate: today.adding(days: 30))
            if let tone = expiryToneText { Text(tone.0).font(.caption).foregroundStyle(tone.1) }
            Toggle("Running low", isOn: $state.isLow)
            HStack {
                Text("Low at or below")
                Spacer()
                TextField("Optional", text: $state.lowThresholdText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
        } header: {
            Text("Pantry")
        } footer: {
            Text("Running-low items go on the shopping list. With a threshold, the flag is set automatically.")
        }
    }

    private var expiryToneText: (String, Color)? {
        switch TIK.expiryTone(state.expiresOn, today: today) {
        case .expired: return ("Expired", .red)
        case .soon: return ("Expires within 7 days", .orange)
        case .none: return nil
        }
    }

    // MARK: Loading

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let (p, idx) = await TIK.loadPlaces(env)
        property = p
        places = idx
        if let pid = p?.id {
            people = ((try? await env.people.people(property: pid)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
        }
        switch mode {
        case .create(let spaceID):
            if let spaceID {
                if let s = idx.scope(forSpace: spaceID) { state.scope = s }
                else if let space = try? await env.plan.space(spaceID) { state.scope = space.scope }
            }
        case .inSpot(let spotID):
            if let spot = try? await env.inventory.spot(spotID) {
                var level = idx.space(spot.spaceId)?.levelId
                if level == nil, let space = try? await env.plan.space(spot.spaceId) { level = space.levelId }
                if let level { state.scope = .space(spot.spaceId, level: level) }
                state.storageSpotId = spot.id
                state.ownerId = spot.ownerId
            }
        case .spare(let thing):
            state.kind = .stored
            state.name = TIK.spareName(templateKey: thing.templateKey, attributes: thing.attributes, thingName: thing.name)
            state.category = thing.templateKey == "light_fixture" ? "bulbs" : "filters"
            state.unit = TIK.extra(for: thing.templateKey).spareUnit
            state.lowThresholdText = TIK.quantityText(TIK.extra(for: thing.templateKey).spareLowThreshold)
            state.linkedThingId = thing.id
            state.scope = thing.scope
            linkedThing = thing
        case .edit(let id):
            if let item = try? await env.inventory.item(id) {
                original = item
                state = TIK.InventoryFormState(item: item)
                if let tid = item.linkedThingId { linkedThing = try? await env.things.thing(tid) }
            } else {
                errorText = "This item no longer exists."
            }
        }
    }

    private func loadSpots() async {
        guard let sid = state.scope.spaceId else {
            spots = []
            state.storageSpotId = nil
            return
        }
        let list = (try? await env.inventory.spots(space: sid)) ?? []
        spots = InventoryLogic.tree(space: sid, spots: list, items: [])
        if let spid = state.storageSpotId, !list.contains(where: { $0.id == spid }) { state.storageSpotId = nil }
    }

    // MARK: Actions

    private func save(addAnother: Bool) async {
        guard let property, state.canSave else { return }
        saving = true
        defer { saving = false }
        do {
            let saved: InventoryItem
            if let original {
                let item = state.applied(to: original)
                try await env.inventory.update(item)
                saved = item
            } else {
                saved = try await env.inventory.create(state.draft(propertyId: property.id))
            }
            onSaved?(saved)
            if addAnother {
                addedCount += 1
                lastAdded = saved.name
                state = state.nextEntry()
            } else {
                dismiss()
            }
        } catch {
            errorText = "Couldn’t save. \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard let original else { return }
        do {
            try await env.inventory.delete(original.id)
            dismiss()
        } catch {
            errorText = "Couldn’t delete. \(error.localizedDescription)"
        }
    }
}

#Preview("New in Kitchen") {
    InventoryForm(spaceID: SampleHome.kitchenId).environment(AppEnvironment.preview())
}

#Preview("Add to winter bin") {
    InventoryForm(spotID: SampleHome.winterBinId).environment(AppEnvironment.preview())
}

#Preview("Spares for furnace") {
    InventoryForm(spareFor: Thing(propertyId: SampleHome.propertyId, scope: .space(SampleHome.utilityId, level: SampleHome.basementId),
                                  category: .system, name: "Furnace", templateKey: "hvac_furnace",
                                  attributes: ["filterSize": "16x25x1", "merv": 11]))
        .environment(AppEnvironment.preview())
}
