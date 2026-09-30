import SwiftUI
import HomeCore
#if canImport(UIKit)
import UIKit
#endif

// Small SwiftUI building blocks shared by the Things / Measurements / Inventory / Search / People / Settings
// features. Namespaced under `TIK` (see ThingsInventoryKit.swift) to avoid clashes with other feature folders.

extension TIK {
    static func color(hex: String?, fallback: Color = .gray) -> Color {
        guard let c = rgb(hex: hex) else { return fallback }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func permissionText(_ p: PermissionStatus) -> String {
        switch p {
        case .notDetermined: return "Not asked yet"; case .denied: return "Off"; case .authorized: return "On"
        case .provisional: return "Provisional"; case .restricted: return "Restricted"; case .writeOnly: return "Add-only"
        case .unknown: return "Unknown"
        }
    }

    /// iOS Settings deep link (iCloud off, calendar access off).
    static var systemSettingsURL: URL? {
        #if canImport(UIKit)
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return nil
        #endif
    }

    /// Current property + its levels and spaces.
    @MainActor
    static func loadPlaces(_ env: AppEnvironment) async -> (Property?, PlaceIndex) {
        guard let p = try? await env.plan.currentProperty() else { return (nil, PlaceIndex()) }
        let levels = (try? await env.plan.levels(property: p.id)) ?? []
        let spaces = (try? await env.plan.spaces(property: p.id)) ?? []
        return (p, PlaceIndex(levels: levels, spaces: spaces))
    }

    /// Adds a housemate with the next palette color ("Add person…" in any picker, FR-INV-01).
    @MainActor
    static func addPerson(named name: String, env: AppEnvironment, propertyId: UUID, existing: [Person]) async -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let person = Person(propertyId: propertyId, name: trimmed,
                            colorHex: nextPersonColor(existing: existing.map(\.colorHex)),
                            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
                            createdAt: env.clock.now, updatedAt: env.clock.now)
        do {
            try await env.people.save(person)
            return person
        } catch {
            return nil
        }
    }

    // MARK: Person dot

    struct PersonDot: View {
        let name: String
        let colorHex: String?
        var size: CGFloat = 24

        init(person: Person, size: CGFloat = 24) { name = person.name; colorHex = person.colorHex; self.size = size }
        init(name: String, colorHex: String?, size: CGFloat = 24) { self.name = name; self.colorHex = colorHex; self.size = size }

        var body: some View {
            Text(TIK.initial(name))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(TIK.color(hex: colorHex)))
                .accessibilityHidden(true)
        }
    }

    // MARK: Length field (W / D / H)

    /// A dimension entry row bound to inches. Accepts `32`, `32"`, `2'8"`, `35 3/4`, `35¾`, `81.3cm`, `0.81m`
    /// (spec 07 FR-MSR-03); shows the inline error for letters or zero.
    struct LengthField: View {
        let title: String
        @Binding var inches: Double?
        let mode: LengthMode
        var optional = false

        @State private var primary = ""
        @State private var secondary = ""
        @State private var invalid = false
        /// Box texts last written from the bound value; re-parsing them must not change the value (e.g. a 32 in
        /// value shown as "81.3" cm would otherwise round-trip to 32.01 in).
        @State private var syncedPrimary = ""
        @State private var syncedSecondary = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                        if optional { Text("Optional").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    switch mode {
                    case .feetInches:
                        box($primary, unit: "ft", width: 48)
                        box($secondary, unit: "in", width: 64)
                    case .inches:
                        box($primary, unit: "in", width: 96)
                    case .centimeters:
                        box($primary, unit: "cm", width: 96)
                    }
                }
                if invalid {
                    Text("Enter a length like 32 or 2′8″").font(.caption).foregroundStyle(.red)
                }
            }
            .onAppear { syncFromValue(force: true) }
            .onChange(of: mode) { _, _ in syncFromValue(force: true) }
            .onChange(of: inches) { _, _ in syncFromValue(force: false) }
            .onChange(of: primary) { _, _ in parseText() }
            .onChange(of: secondary) { _, _ in parseText() }
        }

        private func box(_ text: Binding<String>, unit: String, width: CGFloat) -> some View {
            HStack(spacing: 4) {
                TextField("—", text: text)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                Text(unit).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) in \(unit)")
        }

        private var isEmpty: Bool {
            primary.trimmingCharacters(in: .whitespaces).isEmpty
                && (mode != .feetInches || secondary.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        /// The boxes still show exactly what `syncFromValue` wrote for the current value.
        private var showsSyncedValue: Bool {
            guard inches != nil, primary == syncedPrimary, secondary == syncedSecondary else { return false }
            let t = LengthInput.fieldTexts(inches, mode: mode)
            return t.0 == primary && t.1 == secondary
        }

        private func currentParse() -> Double? {
            mode == .feetInches ? LengthInput.parse(feet: primary, inches: secondary) : LengthInput.parse(primary, mode: mode)
        }

        private func parseText() {
            if showsSyncedValue { invalid = false; return }
            if isEmpty {
                invalid = false
                if inches != nil { inches = nil }
                return
            }
            let parsed = currentParse()
            invalid = parsed == nil
            if parsed != inches { inches = parsed }
        }

        /// Rewrites the boxes from the bound value when it changed from outside (load, mode switch).
        private func syncFromValue(force: Bool) {
            if !force {
                if isEmpty && inches == nil { return }
                if showsSyncedValue { return }
                if currentParse() == inches { return }
                if invalid && inches == nil { return }  // keep what the user is typing
            }
            let t = LengthInput.fieldTexts(inches, mode: mode)
            syncedPrimary = t.0
            syncedSecondary = t.1
            primary = t.0
            secondary = t.1
            invalid = false
        }
    }

    struct LengthModePicker: View {
        @Binding var mode: LengthMode
        var body: some View {
            Picker("Units", selection: $mode) {
                ForEach(LengthMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Optional date row

    struct OptionalDateRow: View {
        let title: String
        @Binding var date: LocalDate?
        let calendar: Calendar
        let defaultDate: LocalDate

        var body: some View {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { on in date = on ? (date ?? defaultDate) : nil }))
            if date != nil {
                DatePicker(title, selection: Binding(
                    get: { date?.date(atMinutes: 12 * 60, calendar: calendar) ?? Date() },
                    set: { date = LocalDate($0, calendar: calendar) }), displayedComponents: .date)
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
            }
        }
    }

    // MARK: Place picker (room / whole floor / whole house)

    struct PlacePicker: View {
        let title: String
        @Binding var scope: Scope
        let places: PlaceIndex
        /// Offer "whole floor" and "whole house" (false = rooms only).
        var allowBroad = true

        var body: some View {
            Picker(title, selection: $scope) {
                if allowBroad { Text("Whole house").tag(Scope.property) }
                ForEach(places.levels) { level in
                    Section(level.name) {
                        if allowBroad { Text("\(level.name) · whole floor").tag(Scope.level(level.id)) }
                        ForEach(places.spaces(on: level.id)) { s in
                            Text(s.name).tag(Scope.space(s.id, level: s.levelId))
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    // MARK: Person picker with "Add person…"

    struct PersonPicker: View {
        @Environment(AppEnvironment.self) private var env
        let title: String
        @Binding var personId: UUID?
        @Binding var people: [Person]
        let propertyId: UUID?
        var noneLabel = "No owner"

        @State private var adding = false
        @State private var newName = ""

        var body: some View {
            Picker(title, selection: $personId) {
                Text(noneLabel).tag(UUID?.none)
                ForEach(people) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            Button("Add person…") { adding = true }
                .disabled(propertyId == nil)
                .alert("Add person", isPresented: $adding) {
                    TextField("Name", text: $newName)
                    Button("Cancel", role: .cancel) { newName = "" }
                    Button("Add") {
                        let name = newName
                        newName = ""
                        guard let pid = propertyId else { return }
                        Task { @MainActor in
                            if let p = await TIK.addPerson(named: name, env: env, propertyId: pid, existing: people) {
                                people.append(p)
                                personId = p.id
                            }
                        }
                    }
                } message: {
                    Text("Housemates are name labels. They don't need an account.")
                }
        }
    }

    // MARK: Move items to a room / spot (storage tree multi-select, seasonal swap "put away")

    struct MoveItemsSheet: View {
        @Environment(AppEnvironment.self) private var env
        @Environment(\.dismiss) private var dismiss
        let itemIds: [UUID]
        var title = "Move to…"
        var onDone: (() -> Void)? = nil

        @State private var places = PlaceIndex()
        @State private var roomScope: Scope = .property
        @State private var spots: [SpotNode] = []
        @State private var spotId: UUID?
        @State private var error: String?
        @State private var working = false

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        PlacePicker(title: "Room", scope: $roomScope, places: places, allowBroad: false)
                        if !spots.isEmpty {
                            Picker("Spot", selection: $spotId) {
                                Text("Room (no spot)").tag(UUID?.none)
                                ForEach(TIK.flatten(spots)) { n in Text(n.path).tag(UUID?.some(n.id)) }
                            }
                            .pickerStyle(.navigationLink)
                        }
                    } footer: {
                        Text("\(itemIds.count) item\(itemIds.count == 1 ? "" : "s") keep their details; only the location changes.")
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Move") { Task { await move() } }.disabled(roomScope.spaceId == nil || working)
                    }
                }
                .task {
                    let (_, idx) = await TIK.loadPlaces(env)
                    places = idx
                }
                .task(id: roomScope) {
                    spotId = nil
                    guard let sid = roomScope.spaceId else { spots = []; return }
                    for await nodes in env.inventory.observeSpotTree(space: sid) {
                        spots = nodes
                    }
                }
            }
        }

        private func move() async {
            working = true
            defer { working = false }
            do {
                if let spotId {
                    try await env.inventory.move(itemIds, to: spotId)
                } else {
                    // Room top level: `move(to: nil)` keeps the current scope, so re-scope each item explicitly.
                    for id in itemIds {
                        guard var item = try await env.inventory.item(id) else { continue }
                        item.storageSpotId = nil
                        item.scope = roomScope
                        try await env.inventory.update(item)
                    }
                }
                onDone?()
                dismiss()
            } catch {
                self.error = "Couldn't move the items. \(error.localizedDescription)"
            }
        }
    }
}
