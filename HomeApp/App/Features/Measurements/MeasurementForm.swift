import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit a measurement (spec 07 FR-MSR-01..09, mockup 4.4): label, kind, attached to a room / door or
/// window / storage spot, W × D × H typed in inches, feet + inches or centimeters (stored in inches).
///
/// - `MeasurementForm(spaceID:)` — "+" → Measurement (defaults to that room), or a thing's "Goes into → New".
/// - `MeasurementForm(measurementID:)` — edit / delete.
/// Self-contained: presents its own `NavigationStack`; show it in a sheet.
/// Plan pin placement (drag the pin on the room plan) is left to the plan canvas; see INTEGRATION_NOTES.
struct MeasurementForm: View {
    private enum Mode { case create(UUID?), edit(UUID) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    private let onSaved: ((HomeMeasurement) -> Void)?

    @State private var state = TIK.MeasurementFormState()
    @State private var original: HomeMeasurement?
    @State private var property: Property?
    @State private var places = TIK.PlaceIndex()
    @State private var openings: [Opening] = []
    @State private var spots: [SpotNode] = []
    @State private var lengthMode: TIK.LengthMode = .inches
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorText: String?

    init(spaceID: UUID?, onSaved: ((HomeMeasurement) -> Void)? = nil) {
        mode = .create(spaceID)
        self.onSaved = onSaved
    }

    init(measurementID: UUID, onSaved: ((HomeMeasurement) -> Void)? = nil) {
        mode = .edit(measurementID)
        self.onSaved = onSaved
    }

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var system: UnitSystem { property?.unitSystem ?? .imperial }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $state.label, prompt: Text("Fridge opening"))
                    Picker("Kind", selection: $state.kind) {
                        ForEach(HomeMeasurement.Kind.knownCases, id: \.self) { Text(TIK.measurementKindTitle($0)).tag($0) }
                    }
                }
                attachedSection
                dimensionsSection
                if state.kind == .door {
                    Section {
                        Toggle("Delivery path", isOn: $state.isDeliveryPath)
                    } footer: {
                        Text("Big items are checked against every delivery-path door (smallest two dimensions vs. the door’s width and height).")
                    }
                }
                Section("Note") {
                    TextField("Note", text: $state.note, axis: .vertical).lineLimit(1...4)
                }
                if isEdit {
                    Section { Button("Delete", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(isEdit ? "Measurement" : "New Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(state.problem != nil || saving || property == nil)
                }
            }
            .confirmationDialog("Delete “\(state.trimmedLabel)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Items that go into it will show “No space chosen”. It stays in Recently Deleted for 30 days.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task { await load() }
            .task(id: state.spaceId) { await loadRoomParts() }
        }
    }

    private var attachedSection: some View {
        Section("Attached to") {
            Picker("Room or zone", selection: $state.spaceId) {
                Text("Choose…").tag(UUID?.none)
                ForEach(places.levels) { level in
                    Section(level.name) {
                        ForEach(places.spaces(on: level.id)) { s in Text(s.name).tag(UUID?.some(s.id)) }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            if !openings.isEmpty {
                Picker("Door or window", selection: $state.openingId) {
                    Text("None").tag(UUID?.none)
                    ForEach(openings) { o in Text(openingLabel(o)).tag(UUID?.some(o.id)) }
                }
                .onChange(of: state.openingId) { _, new in adoptOpening(new) }
            }
            if !spots.isEmpty {
                Picker("Storage spot", selection: $state.storageSpotId) {
                    Text("None").tag(UUID?.none)
                    ForEach(TIK.flatten(spots)) { n in Text(n.path).tag(UUID?.some(n.id)) }
                }
            }
        }
    }

    private var dimensionsSection: some View {
        Section {
            TIK.LengthModePicker(mode: $lengthMode)
            TIK.LengthField(title: "Width", inches: $state.dims.width, mode: lengthMode)
            TIK.LengthField(title: state.kind == .door || state.kind == .window ? "Depth (jamb)" : "Depth",
                            inches: $state.dims.depth, mode: lengthMode, optional: state.kind == .door || state.kind == .window)
            TIK.LengthField(title: "Height", inches: $state.dims.height, mode: lengthMode, optional: state.kind != .door)
            if let area = state.zoneAreaSqIn {
                LabeledContent("Area", value: HomeLengthFormatter.formatArea(squareInches: area, system: system))
            }
        } header: {
            Text("Dimensions")
        } footer: {
            if let problem = state.problem { Text(problem).foregroundStyle(.red) }
            else { Text(TIK.dimsSummary(state.dims, system: system)) }
        }
    }

    private func openingLabel(_ o: Opening) -> String {
        let kind: String
        switch o.kind {
        case .door: kind = o.isExteriorDoor ? "Exterior door" : "Door"
        case .window: kind = "Window"
        default: kind = "Opening"
        }
        return "\(kind) · \(HomeLengthFormatter.formatInches(o.widthIn, system: system)) wide"
    }

    /// Choosing a door/window marker sets the kind and pre-fills its width/height when empty (FR-MSR-05).
    private func adoptOpening(_ id: UUID?) {
        guard let id, let o = openings.first(where: { $0.id == id }) else { return }
        switch o.kind {
        case .door: state.kind = .door
        case .window: state.kind = .window
        default: break
        }
        if state.dims.width == nil { state.dims.width = (o.widthIn * 100).rounded() / 100 }
        if state.dims.height == nil, let h = o.heightIn { state.dims.height = h }
        if state.trimmedLabel.isEmpty { state.label = openingLabel(o).components(separatedBy: " · ").first ?? "" }
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
            state.spaceId = spaceID
            if let spaceID, idx.space(spaceID)?.isExterior == true { state.kind = .zone }
        case .edit(let id):
            if let m = try? await env.measurements.measurement(id) {
                original = m
                state = TIK.MeasurementFormState(measurement: m)
            } else {
                errorText = "This measurement no longer exists."
            }
        }
    }

    /// Door/window markers and storage spots of the chosen room; drops choices from another room.
    private func loadRoomParts() async {
        guard let sid = state.spaceId else {
            openings = []; spots = []
            return
        }
        var space = places.space(sid)
        if space == nil { space = try? await env.plan.space(sid) }
        if let space {
            let geo = try? await env.plan.geometry(level: space.levelId)
            openings = (geo?.openings ?? []).filter { $0.spaceId == sid }
        } else {
            openings = []
        }
        let spotList = (try? await env.inventory.spots(space: sid)) ?? []
        spots = InventoryLogic.tree(space: sid, spots: spotList, items: [])
        if let oid = state.openingId, !openings.contains(where: { $0.id == oid }) { state.openingId = nil }
        if let spid = state.storageSpotId, !spotList.contains(where: { $0.id == spid }) { state.storageSpotId = nil }
    }

    // MARK: Actions

    private func save() async {
        guard let property, state.problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let saved: HomeMeasurement
            if let original {
                let m = state.applied(to: original)
                try await env.measurements.update(m)
                saved = m
            } else {
                saved = try await env.measurements.create(state.input(propertyId: property.id))
            }
            onSaved?(saved)
            dismiss()
        } catch {
            errorText = "Couldn’t save. \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard let original else { return }
        do {
            try await env.measurements.delete(original.id)
            dismiss()
        } catch {
            errorText = "Couldn’t delete. \(error.localizedDescription)"
        }
    }
}

#Preview("New in Kitchen") {
    MeasurementForm(spaceID: SampleHome.kitchenId).environment(AppEnvironment.preview())
}

#Preview("Edit fridge opening") {
    MeasurementForm(measurementID: SampleHome.fridgeOpeningId).environment(AppEnvironment.preview())
}
