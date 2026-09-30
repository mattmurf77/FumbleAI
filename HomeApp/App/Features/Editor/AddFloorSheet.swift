import SwiftUI
import PlanKit
import HomeCore

/// "Add floor" (pill "+", FR-CNV-12; editor menu). Commits a one-level `PlanDraft` through `PlanCommitting`, then
/// switches the plan to the new floor. The full creation paths (scan, trace, blocks, rough-in) live in Onboarding;
/// this is the quick manual path.
///
/// Once a floor exists the new level can start from it (founder feedback): "Same outline as <floor>" (default on)
/// fills the new level with that floor's exterior outline as one "Unassigned space" for the user to split, and
/// "Stairs matching <floor>" (default on when it has stairs) places a stairwell at the same position. Without the
/// outline it can still start with one 12 × 12 ft room. Outside builds the full default yard (house outline from the
/// ground floor, front yard, backyard, side yards, driveway, sidewalk; the footprint lookup when an address is saved).
struct AddFloorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let property: Property
    let onAdded: (UUID) -> Void

    @State private var levels: [Level] = []
    @State private var name = ""
    @State private var kind: Level.Kind = .floor
    @State private var startWithRoom = true
    @State private var matchOutline = true
    @State private var matchStairs = true
    /// The floor to line up with (nil until levels load; then the floor below / the lowest floor for a basement).
    @State private var referenceId: UUID?
    @State private var referenceSpaces: [Space] = []
    @State private var saving = false
    @State private var errorText: String?

    init(property: Property, onAdded: @escaping (UUID) -> Void, initialKind: Level.Kind = .floor) {
        self.property = property
        self.onAdded = onAdded
        _kind = State(initialValue: initialKind)
    }

    private var interiorLevels: [Level] { levels.filter { !$0.isExterior }.sorted { $0.sortOrder < $1.sortOrder } }
    private var reference: Level? { interiorLevels.first { $0.id == referenceId } }
    private var referenceRooms: [Space] { referenceSpaces.filter { $0.deletedAt == nil && !$0.isExterior } }
    private var referenceHasStairs: Bool { referenceRooms.contains { $0.spaceType == .stairs } }
    private var canMatch: Bool { kind != .exterior && reference != nil && !referenceRooms.isEmpty }
    private var usesOutline: Bool { canMatch && matchOutline }
    private var usesStairs: Bool { canMatch && matchStairs && referenceHasStairs }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if kind != .exterior { TextField(suggestedName, text: $name) }
                    Picker("Kind", selection: $kind) {
                        Text("Floor").tag(Level.Kind.floor)
                        Text("Basement").tag(Level.Kind.basement)
                        Text("Attic").tag(Level.Kind.attic)
                        if !levels.contains(where: { $0.kind == .exterior }) { Text("Outside (yard)").tag(Level.Kind.exterior) }
                    }
                    if kind != .exterior && !usesOutline {
                        Toggle("Start with one room", isOn: $startWithRoom)
                    }
                } footer: {
                    if kind == .exterior {
                        Text("Adds your house outline with a front yard, backyard, side yards, driveway and sidewalk. Drag them to fit.")
                    } else if !usesOutline {
                        Text("You can draw rooms in edit mode afterwards.")
                    }
                }
                if kind != .exterior, let ref = reference, !referenceRooms.isEmpty {
                    Section {
                        if interiorLevels.count > 1 {
                            Picker("Line up with", selection: $referenceId) {
                                ForEach(interiorLevels) { l in Text(l.name).tag(UUID?.some(l.id)) }
                            }
                        }
                        Toggle("Same outline as \(ref.name)", isOn: $matchOutline)
                        if referenceHasStairs {
                            Toggle("Stairs matching \(ref.name)", isOn: $matchStairs)
                        }
                    } header: {
                        Text("Line up with \(ref.name)")
                    } footer: {
                        Text(outlineFooter(ref))
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle(kind == .exterior ? "Add yard" : "Add floor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add() } }
                    }
                }
            }
            .task {
                levels = ((try? await env.plan.levels(property: property.id)) ?? []).filter { $0.deletedAt == nil }
                if kind == .exterior && levels.contains(where: { $0.kind == .exterior }) { kind = .floor }
                pickDefaultReference()
            }
            .onChange(of: kind) { _, _ in pickDefaultReference() }
            .task(id: referenceId) { await loadReference() }
        }
        .presentationDetents([.medium, .large])
    }

    private func outlineFooter(_ ref: Level) -> String {
        switch (usesOutline, usesStairs) {
        case (true, true):
            return "The new floor starts as one “\(FloorMatching.unassignedName)” with \(ref.name)’s outside walls and the stairs in the same spot. Split it into rooms in edit mode."
        case (true, false):
            return "The new floor starts as one “\(FloorMatching.unassignedName)” with \(ref.name)’s outside walls. Split it into rooms in edit mode."
        case (false, true):
            return "The stairs go in the same spot as on \(ref.name)."
        case (false, false):
            return "The new floor starts empty."
        }
    }

    /// Floor / attic: the highest floor (the one the new floor sits on). Basement: the lowest floor.
    private func pickDefaultReference() {
        let floors = interiorLevels
        referenceId = kind == .basement ? floors.first?.id : floors.last?.id
    }

    private func loadReference() async {
        guard let id = referenceId else { referenceSpaces = []; return }
        referenceSpaces = (try? await env.plan.geometry(level: id))?.spaces ?? []
    }

    private var suggestedName: String {
        switch kind {
        case .basement: return "Basement"
        case .attic: return "Attic"
        case .exterior: return ExteriorPlanning.levelName
        default:
            let n = levels.filter { $0.kind == .floor }.count + 1
            return n == 1 ? "Ground" : "\(ordinal(n)) Floor"
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" }
        }
        return "\(n)\(suffix)"
    }

    /// Elevation index: basement below the lowest, floors/attic above the highest interior level, exterior 100.
    private var sortOrder: Int {
        let interior = levels.filter { $0.kind != .exterior }.map(\.sortOrder)
        switch kind {
        case .basement: return min(interior.min() ?? 0, 0) - 1
        case .exterior: return Level.exteriorSortOrder
        default: return interior.isEmpty ? 0 : (interior.max() ?? 0) + 1
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        if kind == .exterior { await addOutside(); return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let levelName = trimmed.isEmpty ? suggestedName : String(trimmed.prefix(60))
        var spaces = FloorMatching.matchingSpaces(reference: referenceRooms.map(FloorShape.init),
                                                  outline: usesOutline, stairs: usesStairs, source: .manual)
        if !usesOutline && startWithRoom {
            // 12 × 12 ft starting room, beside the stairwell when there is one.
            let stairs = spaces.reduce(PlanKit.Rect.null) { $0.union($1.polygon.bounds) }
            let origin = stairs.isNull ? Vec2(0, 0) : Vec2(stairs.maxX, stairs.minY)
            spaces.append(SpaceDraft(name: "Room", spaceType: .room,
                                     polygon: PlanKit.Polygon(rect: PlanKit.Rect(x: origin.x, y: origin.y, width: 144, height: 144)),
                                     source: .manual))
        }
        let draft = PlanDraft(levels: [LevelDraft(name: levelName, kind: kind, sortOrder: sortOrder, spaces: spaces)], source: .manual)
        do {
            let ids = try await env.planCommitter.commit(draft, into: property.id, acceptedSuggestions: [])
            if let id = ids.first { onAdded(id) }
            dismiss()
        } catch {
            errorText = "Couldn’t add the floor: \(error.localizedDescription)"
        }
    }

    /// Outside: the full default yard (FR-EXT-06/07), never an empty level.
    private func addOutside() async {
        let services = ExteriorSetup.Services(env)
        let id = await ExteriorSetup.ensureOutside(services, propertyId: property.id, address: ExteriorSetup.address(of: property),
                                                   groundOutline: nil)
        if let id {
            onAdded(id)
            dismiss()
        } else {
            errorText = "Couldn’t add the yard. Try again."
        }
    }
}

#Preview {
    AddFloorSheet(property: Property(name: "Preview")) { _ in }
        .environment(AppEnvironment.preview())
}
