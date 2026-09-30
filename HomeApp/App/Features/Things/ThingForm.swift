import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit an appliance, electronic, furniture, fixture, system or outdoor feature (spec 06, spec 07 fit check).
///
/// - `ThingForm(spaceID:)` — "+" → Appliance/Electronic/Furniture, defaults to that room (nil = whole house).
/// - `ThingForm(spaceID:outdoor: true)` — "+" on Outside: Outdoor category, outdoor templates first.
/// - `ThingForm(thingID:)` — edit; adds spare stock ("Track spares"), maintenance chore and delete.
/// Self-contained: presents its own `NavigationStack`; show it in a sheet.
struct ThingForm: View {
    private enum Mode: Equatable { case create(UUID?), edit(UUID) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    private let outdoor: Bool
    private let onSaved: ((Thing) -> Void)?

    @State private var state = TIK.ThingFormState()
    @State private var original: Thing?
    @State private var property: Property?
    @State private var places = TIK.PlaceIndex()
    @State private var targets: [HomeMeasurement] = []
    @State private var deliveryPaths: [HomeMeasurement] = []
    @State private var targetMissing = false
    @State private var spares: [InventoryItem] = []
    @State private var spareLocations: [UUID: ItemLocation] = [:]
    @State private var lengthMode: TIK.LengthMode = .inches
    @State private var loaded = false
    @State private var saving = false
    @State private var showTemplates = false
    @State private var showNewMeasurement = false
    @State private var showTrackSpares = false
    @State private var editingSpare: InventoryItem?
    @State private var confirmDelete = false
    @State private var confirmChore = false
    @State private var choreNote: String?
    @State private var errorText: String?

    init(spaceID: UUID?, outdoor: Bool = false, onSaved: ((Thing) -> Void)? = nil) {
        mode = .create(spaceID)
        self.outdoor = outdoor
        self.onSaved = onSaved
        var initial = TIK.ThingFormState()
        if outdoor { initial.category = .outdoor }
        _state = State(initialValue: initial)
    }

    init(thingID: UUID, onSaved: ((Thing) -> Void)? = nil) {
        mode = .edit(thingID)
        self.outdoor = false
        self.onSaved = onSaved
    }

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var today: LocalDate { env.clock.today }
    private var calendar: Calendar { env.clock.calendar }
    private var target: HomeMeasurement? {
        state.fitMeasurementId.flatMap { id in targets.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                templateSection
                basicsSection
                Section("Where") {
                    TIK.PlacePicker(title: "Place", scope: $state.scope, places: places)
                }
                if let template = state.template, !template.fields.isEmpty {
                    Section(template.name) {
                        TemplateFields(template: template, attributes: $state.attributes, calendar: calendar, today: today)
                    }
                }
                dimensionsSection
                fitSection
                detailsSection
                if isEdit {
                    sparesSection
                    maintenanceSection
                }
                Section("Notes") {
                    TextField("Notes", text: $state.notes, axis: .vertical).lineLimit(2...6)
                }
                if isEdit {
                    Section {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEdit ? (original?.name ?? "Item")
                             : state.category == .outdoor ? "New Outdoor item" : "New \(TIK.categoryTitle(state.category))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!state.canSave || saving || property == nil)
                }
            }
            .sheet(isPresented: $showTemplates) {
                TemplatePickerSheet(selectedKey: state.templateKey, outdoorFirst: outdoor || state.category == .outdoor) {
                    state.apply(template: $0)
                }
            }
            .sheet(isPresented: $showNewMeasurement) {
                MeasurementForm(spaceID: state.scope.spaceId) { m in
                    Task {
                        await reloadTargets()
                        state.fitMeasurementId = m.id
                    }
                }
            }
            .sheet(isPresented: $showTrackSpares, onDismiss: { Task { await reloadSpares() } }) {
                if let original { InventoryForm(spareFor: original) }
            }
            .sheet(item: $editingSpare, onDismiss: { Task { await reloadSpares() } }) { spare in
                InventoryForm(itemID: spare.id)
            }
            .confirmationDialog("Delete \(state.trimmedName.isEmpty ? "this item" : state.trimmedName)?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                if spares.isEmpty {
                    Button("Delete", role: .destructive) { Task { await delete(alsoSpares: false) } }
                } else {
                    Button("Delete, keep \(spareCount) spare\(spareCount == 1 ? "" : "s")", role: .destructive) {
                        Task { await delete(alsoSpares: false) }
                    }
                    Button("Also delete \(spareCount) spare\(spareCount == 1 ? "" : "s")", role: .destructive) {
                        Task { await delete(alsoSpares: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It moves to Recently Deleted for 30 days. Linked to-dos stay; their link is cleared.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task { await load() }
            .onChange(of: state.scope) { _, _ in Task { await reloadTargets() } }
        }
        .feedbackPage("Thing form")
    }

    // MARK: Sections

    private var templateSection: some View {
        Section {
            Button { showTemplates = true } label: {
                HStack {
                    Image(systemName: state.template?.symbol ?? ThingTemplate.defaultSymbol(for: state.category))
                        .frame(width: 28).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Template").font(.caption).foregroundStyle(.secondary)
                        Text(state.template?.name ?? "Custom").foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text(state.category == .outdoor
                 ? "A template sets the category, icon and extra fields like species, bloom season or pool size."
                 : "A template sets the category, icon, fit-check clearances and extra fields like bulb base or filter size.")
        }
    }

    private var basicsSection: some View {
        Section {
            TextField("Name", text: $state.name)
            Picker("Category", selection: $state.category) {
                ForEach(Thing.Category.knownCases, id: \.self) { Text(TIK.categoryTitle($0)).tag($0) }
            }
            Picker("Ownership", selection: $state.ownership) {
                Text("Owned").tag(Thing.Ownership.owned)
                Text("Planned purchase").tag(Thing.Ownership.planned)
            }
            .pickerStyle(.segmented)
        } footer: {
            if state.ownership == .planned {
                Text("Planned purchases draw dashed on the plan and aren’t counted until you switch them to Owned.")
            }
        }
    }

    private var dimensionsSection: some View {
        Section("Dimensions") {
            TIK.LengthModePicker(mode: $lengthMode)
            TIK.LengthField(title: "Width", inches: $state.dims.width, mode: lengthMode)
            TIK.LengthField(title: "Depth", inches: $state.dims.depth, mode: lengthMode)
            TIK.LengthField(title: "Height", inches: $state.dims.height, mode: lengthMode)
        }
    }

    private var fitSection: some View {
        Section {
            Picker("Goes into", selection: $state.fitMeasurementId) {
                Text("Not set").tag(UUID?.none)
                ForEach(targets) { m in
                    Text(m.label).tag(UUID?.some(m.id))
                }
            }
            Button("New measurement…") { showNewMeasurement = true }
            if targetMissing {
                Text("No space chosen — the measurement it went into was deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FitBanner(item: state.dims, policy: state.policy(), target: target, deliveryPaths: deliveryPaths)
        } header: {
            Text("Fit check")
        } footer: {
            Text("The fit check never blocks saving.")
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Brand", text: $state.brand)
            TextField("Model", text: $state.model).autocorrectionDisabled()
            TextField("Serial number", text: $state.serial).autocorrectionDisabled().textInputAutocapitalization(.characters)
            TIK.OptionalDateRow(title: "Purchase date", date: $state.purchaseDate, calendar: calendar, defaultDate: today)
            HStack {
                Text("Purchase price")
                Spacer()
                TextField(property?.currencyCode ?? "USD", text: $state.priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            TIK.OptionalDateRow(title: "Warranty end", date: $state.warrantyEnd, calendar: calendar, defaultDate: today.adding(months: 12))
            if let badge = TIK.warrantyBadge(end: state.warrantyEnd, today: today) {
                Label(badge.text, systemImage: badge.tone == .expired ? "xmark.seal" : "checkmark.seal")
                    .foregroundStyle(badge.tone == .ok ? Color.green : badge.tone == .warn ? Color.orange : Color.secondary)
            }
        }
    }

    private var spareCount: Int { Int(spares.reduce(0) { $0 + $1.quantity }.rounded()) }

    private var sparesSection: some View {
        Section {
            ForEach(spares) { spare in
                Button { editingSpare = spare } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spare.name).foregroundStyle(.primary)
                        Text(spareSubtitle(spare)).font(.caption)
                            .foregroundStyle(spare.quantity <= (spare.lowThreshold ?? 0) || spare.isLow ? Color.orange : Color.secondary)
                    }
                }
            }
            Button(spares.isEmpty ? "Track spares" : "Track another spare") { showTrackSpares = true }
        } header: {
            Text("Spare stock")
        } footer: {
            Text("Spares are inventory items linked to this \(TIK.categoryTitle(state.category).lowercased()). When a linked to-do is due and no spares are left, it lands on the shopping list.")
        }
    }

    private func spareSubtitle(_ s: InventoryItem) -> String {
        let q = TIK.quantityText(s.quantity)
        let noun = s.quantity == 1 ? "spare" : "spares"
        if let loc = spareLocations[s.id] { return "\(q) \(noun) in \(loc.displayPath)" }
        return "\(q) \(noun)"
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        if let suggestion = state.template?.suggestedChore {
            Section {
                Button("Add maintenance to-do") { confirmChore = true }
                    .confirmationDialog("Add “\(suggestion.title)”?", isPresented: $confirmChore, titleVisibility: .visible) {
                        Button("Add to-do: \(suggestion.rule.humanText)") { Task { await addChore(suggestion) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Linked to this item and placed in the same room. You can edit it in To-Dos.")
                    }
                if let choreNote { Text(choreNote).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Suggested: \(suggestion.title), \(suggestion.rule.humanText.lowercased()).")
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let (p, idx) = await TIK.loadPlaces(env)
        property = p
        places = idx
        lengthMode = .preferred(for: p?.unitSystem ?? .imperial)
        switch mode {
        case .create(let spaceID):
            if let spaceID {
                if let s = idx.scope(forSpace: spaceID) {
                    state.scope = s
                } else if let space = try? await env.plan.space(spaceID) {
                    state.scope = space.scope
                }
            } else if outdoor, let yard = idx.levels.first(where: \.isExterior) {
                // Outdoor item from the Stuff tab: the yard rather than the whole house.
                state.scope = .level(yard.id)
            }
        case .edit(let id):
            if let t = try? await env.things.thing(id) {
                original = t
                state = TIK.ThingFormState(thing: t)
            } else {
                errorText = "This item no longer exists."
            }
        }
        if let p { deliveryPaths = (try? await env.measurements.deliveryPaths(property: p.id)) ?? [] }
        await reloadTargets()
        await reloadSpares()
    }

    /// "Goes into" candidates: measurements in the same room (or the whole property when not in a room).
    private func reloadTargets() async {
        guard let pid = property?.id else { return }
        var list: [HomeMeasurement]
        if let sid = state.scope.spaceId {
            list = (try? await env.measurements.measurements(space: sid)) ?? []
        } else {
            list = (try? await env.measurements.measurements(property: pid)) ?? []
        }
        list = TIK.fitTargetOrder(list.filter { !$0.isDeliveryPath || $0.kind != .door })
        if let id = state.fitMeasurementId, !list.contains(where: { $0.id == id }) {
            if let m = try? await env.measurements.measurement(id) {
                list.append(m)  // chosen in another room: keep showing it
            } else {
                state.fitMeasurementId = nil
                targetMissing = true
            }
        }
        targets = list
    }

    private func reloadSpares() async {
        guard let pid = property?.id, let tid = original?.id else { return }
        let all = (try? await env.inventory.items(InventoryQuery(propertyId: pid))) ?? []
        spares = all.filter { $0.linkedThingId == tid }
        let locs = (try? await env.inventory.locations(of: spares.map(\.id))) ?? []
        spareLocations = Dictionary(locs.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Actions

    private func save() async {
        guard let property else { return }
        saving = true
        defer { saving = false }
        do {
            let saved: Thing
            if let original {
                let t = state.applied(to: original, currency: property.currencyCode)
                try await env.things.update(t)
                saved = t
            } else {
                saved = try await env.things.create(state.draft(propertyId: property.id, currency: property.currencyCode))
            }
            onSaved?(saved)
            dismiss()
        } catch {
            errorText = "Couldn’t save. \(error.localizedDescription)"
        }
    }

    private func delete(alsoSpares: Bool) async {
        guard let original else { return }
        do {
            for var spare in spares {
                if alsoSpares {
                    try await env.inventory.delete(spare.id)
                } else {
                    spare.linkedThingId = nil
                    try await env.inventory.update(spare)
                }
            }
            try await env.things.delete(original.id)
            dismiss()
        } catch {
            errorText = "Couldn’t delete. \(error.localizedDescription)"
        }
    }

    private func addChore(_ suggestion: ThingTemplate.SuggestedChore) async {
        guard let property, let original else { return }
        let draft = ChoreDraft(propertyId: property.id, scope: state.scope, title: suggestion.title,
                               repeatRule: suggestion.rule, startOn: today, linkedThingId: original.id)
        do {
            _ = try await env.chores.create(draft)
            choreNote = "Added “\(suggestion.title)” to To-Dos."
        } catch {
            errorText = "Couldn’t add the to-do. \(error.localizedDescription)"
        }
    }
}

#Preview("New in Kitchen") {
    ThingForm(spaceID: SampleHome.kitchenId).environment(AppEnvironment.preview())
}

#Preview("New outdoor item") {
    ThingForm(spaceID: nil, outdoor: true).environment(AppEnvironment.preview())
}

#Preview("Edit planned fridge (won't fit)") {
    ThingForm(thingID: SampleHome.plannedFridgeId).environment(AppEnvironment.preview())
}

#Preview("Edit furnace (spares)") {
    ThingForm(thingID: SampleHome.furnaceId).environment(AppEnvironment.preview())
}
