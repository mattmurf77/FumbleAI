import SwiftUI
import PlanKit
import HomeCore

/// "Add floor" (pill "+", FR-CNV-12; editor menu). Commits a one-level `PlanDraft` through `PlanCommitting`, with an
/// optional 12 × 12 ft starting room, then switches the plan to the new floor. The full creation paths (scan, trace,
/// blocks, rough-in) live in Onboarding; this is the quick manual path.
struct AddFloorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let property: Property
    let onAdded: (UUID) -> Void

    @State private var levels: [Level] = []
    @State private var name = ""
    @State private var kind: Level.Kind = .floor
    @State private var startWithRoom = true
    @State private var saving = false
    @State private var errorText: String?

    init(property: Property, onAdded: @escaping (UUID) -> Void) {
        self.property = property
        self.onAdded = onAdded
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(suggestedName, text: $name)
                    Picker("Kind", selection: $kind) {
                        Text("Floor").tag(Level.Kind.floor)
                        Text("Basement").tag(Level.Kind.basement)
                        Text("Attic").tag(Level.Kind.attic)
                        if !levels.contains(where: { $0.kind == .exterior }) { Text("Outside").tag(Level.Kind.exterior) }
                    }
                    Toggle(kind == .exterior ? "Start with one zone" : "Start with one room", isOn: $startWithRoom)
                } footer: {
                    Text("You can draw rooms in edit mode afterwards.")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add floor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(saving)
                }
            }
            .task { levels = ((try? await env.plan.levels(property: property.id)) ?? []).filter { $0.deletedAt == nil } }
        }
        .presentationDetents([.medium])
    }

    private var suggestedName: String {
        switch kind {
        case .basement: return "Basement"
        case .attic: return "Attic"
        case .exterior: return "Outside"
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let levelName = trimmed.isEmpty ? suggestedName : String(trimmed.prefix(60))
        var spaces: [SpaceDraft] = []
        if startWithRoom {
            let exterior = kind == .exterior
            spaces = [SpaceDraft(name: exterior ? "Zone" : "Room", spaceType: exterior ? .customZone : .room, isExterior: exterior,
                                 polygon: Polygon(rect: Rect(x: 0, y: 0, width: 144, height: 144)), source: .manual)]
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
}

#Preview {
    AddFloorSheet(property: Property(name: "Preview")) { _ in }
        .environment(AppEnvironment.preview())
}
