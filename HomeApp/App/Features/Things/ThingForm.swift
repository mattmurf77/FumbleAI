import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit an appliance, electronic, furniture, fixture, system or outdoor feature (spec 06, spec 07 fit check).
///
/// - `ThingForm(spaceID:)` — "+" → Appliance/Electronic/Furniture, defaults to that room (nil = whole house).
/// - `ThingForm(spaceID:outdoor: true)` — "+" on Outside: Outdoor category, outdoor templates first.
/// - `ThingForm(spaceID:startWithScan: true)` — "Scan an appliance label": opens the label scan right away.
/// - `ThingForm(thingID:)` — edit; adds spare stock ("Track spares"), maintenance chore and delete.
/// Self-contained: presents its own `NavigationStack`; show it in a sheet.
struct ThingForm: View {
    private enum Mode: Equatable { case create(UUID?), edit(UUID) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    private let outdoor: Bool
    private let startWithScan: Bool
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
    // "Scan label" (create only)
    @State private var scanRequested = false
    @State private var scanning = false
    @State private var scanStarted = false
    @State private var lastScan: ScannedLabel?
    @State private var scanNote: ScanNote?

    init(spaceID: UUID?, outdoor: Bool = false, startWithScan: Bool = false, onSaved: ((Thing) -> Void)? = nil) {
        mode = .create(spaceID)
        self.outdoor = outdoor
        self.startWithScan = startWithScan
        self.onSaved = onSaved
        var initial = TIK.ThingFormState()
        if outdoor { initial.category = .outdoor }
        _state = State(initialValue: initial)
    }

    init(thingID: UUID, onSaved: ((Thing) -> Void)? = nil) {
        mode = .edit(thingID)
        self.outdoor = false
        self.startWithScan = false
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
            .labelScanner(isPresented: $scanRequested, working: $scanning, today: today,
                          onScanned: { applyScan($0) },
                          onFailed: { scanNote = ScanNote(text: $0, warning: true) })
            .task {
                await load()
                if startWithScan && !scanStarted {
                    scanStarted = true
                    try? await Task.sleep(for: .milliseconds(500))   // let the sheet finish presenting first
                    if !Task.isCancelled { scanRequested = true }
                }
            }
            .onChange(of: state.scope) { _, _ in Task { await reloadTargets() } }
        }
        .feedbackPage("Thing form")
    }

    // MARK: Sections

    private var templateSection: some View {
        Section {
            if !isEdit { scanLabelRow }
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

    @ViewBuilder
    private var scanLabelRow: some View {
        Button { scanRequested = true } label: {
            HStack {
                Image(systemName: "text.viewfinder").frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastScan == nil ? "Scan label" : "Scan again").foregroundStyle(.primary)
                    Text("A photo of the model / serial sticker fills in the details")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if scanning { ProgressView() }
            }
        }
        .disabled(scanning)
        .accessibilityIdentifier("thingForm.scanLabel")
        if let scanNote {
            Label(scanNote.text, systemImage: scanNote.warning ? "exclamationmark.triangle" : "text.viewfinder")
                .font(.caption)
                .foregroundStyle(scanNote.warning ? Color.orange : Color.secondary)
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
            if let call = TIK.serviceContactCall(state.attributes) {
                Link(destination: call.url) {
                    HStack {
                        Label("Call", systemImage: "phone.fill")
                        Spacer()
                        Text(call.contact).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityLabel("Call service contact, \(call.contact)")
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
                await saveLabelPhoto(for: saved, property: property.id)
            }
            onSaved?(saved)
            dismiss()
        } catch {
            errorText = "Couldn’t save. \(error.localizedDescription)"
        }
    }

    // MARK: Scan label

    struct ScanNote: Equatable {
        var text: String
        var warning = false
    }

    /// Fills empty fields (or ones the previous scan filled) from the label; sets a template only when none is
    /// chosen yet (or the previous scan chose it). Everything stays editable; nothing is saved here.
    private func applyScan(_ scan: ScannedLabel) {
        let g = scan.guess
        let previous = lastScan?.guess
        lastScan = scan
        guard !g.isEmpty else {
            scanNote = ScanNote(text: "Couldn’t find a brand, model or serial number in that photo. Try a closer, straight-on photo of the label, or type them in.",
                                warning: true)
            return
        }
        var filled: [String] = []
        func fill(_ field: inout String, _ value: String?, _ old: String?, _ label: String) {
            guard let value, !value.isEmpty else { return }
            let current = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty || current == old else { return }
            if current != value { filled.append(label) }
            field = value
        }

        let templateIsOurs = state.templateKey == nil || (previous != nil && state.templateKey == previous?.templateKey)
        if templateIsOurs, let key = g.templateKey, state.templateKey != key, let template = ThingTemplate.find(key) {
            state.apply(template: template)
            filled.append("type (\(template.name))")
        } else if state.templateKey == nil, g.templateKey == nil, let category = g.category, state.category != .outdoor {
            state.category = category
        }
        if let template = state.template, state.templateKey == g.templateKey {
            for (key, value) in g.attributes where state.attributes[key] == nil && template.fields.contains(where: { $0.key == key }) {
                state.attributes[key] = value
            }
        }

        if let name = g.name {
            let current = state.trimmedName
            let defaultName = state.template.map(TIK.defaultName(for:))
            if current != name && (current.isEmpty || current == defaultName || current == previous?.name) {
                state.name = name
                filled.append("name")
            }
        }
        fill(&state.brand, g.brand, previous?.brand, "brand")
        fill(&state.model, g.model, previous?.model, "model")
        fill(&state.serial, g.serial, previous?.serial, "serial")
        if let made = g.manufactureDate, state.purchaseDate == nil || state.purchaseDate == previous?.manufactureDate,
           state.purchaseDate != made {
            state.purchaseDate = made
            filled.append("purchase date (from the manufacture date)")
        }

        scanNote = filled.isEmpty
            ? ScanNote(text: "Nothing new to fill in from that photo. Your entries are unchanged.")
            : ScanNote(text: "Filled from photo: \(filled.joined(separator: ", ")). Check them before saving.")
    }

    /// Keeps the label photo with the new item (kind photo, with its OCR text). A failure here doesn't undo the save.
    private func saveLabelPhoto(for thing: Thing, property: UUID) async {
        guard let scan = lastScan, !scan.guess.isEmpty, let photo = scan.photo else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("label-\(UUID().uuidString).jpg")
        do {
            try photo.write(to: url)
            let draft = AttachmentDraft(fileURL: url, kind: .photo, fileExt: "jpg", uti: "public.jpeg", caption: "Label",
                                        ocrText: scan.lines.joined(separator: "\n"), capturedAt: env.clock.now)
            _ = try await env.attachments.add(draft, ownerType: .thing, ownerId: thing.id, property: property)
        } catch {
            // The item is saved; the photo is a nice-to-have.
        }
        try? FileManager.default.removeItem(at: url)
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
