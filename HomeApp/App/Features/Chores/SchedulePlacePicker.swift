import SwiftUI
import HomeCore
import HomeCoreTesting

/// "Place" row used by the chore and project forms: a room, a whole floor, or the whole house (FR-CHR-01, FR-PRJ-01).
struct SchedulePlacePicker: View {
    @Environment(AppEnvironment.self) private var env
    let propertyId: UUID?
    @Binding var scope: Scope
    var title = "Place"

    @State private var levels: [Level] = []
    @State private var spaces: [Space] = []

    var body: some View {
        Picker(title, selection: $scope) {
            Text("Whole house").tag(Scope.property)
            ForEach(levels) { level in
                Section(level.name) {
                    Text("All of \(level.name)").tag(Scope.level(level.id))
                    ForEach(rooms(on: level.id)) { space in
                        Text(space.name).tag(Scope.space(space.id, level: level.id))
                    }
                }
            }
        }
        .pickerStyle(.navigationLink)
        .task(id: propertyId) { await load() }
    }

    private func rooms(on level: UUID) -> [Space] {
        spaces.filter { $0.levelId == level && $0.deletedAt == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load() async {
        guard let propertyId else { return }
        levels = ((try? await env.plan.levels(property: propertyId)) ?? []).filter { $0.deletedAt == nil }.sortedForPills
        spaces = (try? await env.plan.spaces(property: propertyId)) ?? []
    }
}

extension Scope {
    /// Scope for a form opened from "+" with an optional room / floor (room wins; neither → whole house).
    static func scheduleDefault(spaceID: UUID?, levelID: UUID?, spaceLevel: UUID?) -> Scope {
        if let spaceID, let level = spaceLevel ?? levelID { return .space(spaceID, level: level) }
        if let levelID { return .level(levelID) }
        return .property
    }
}

private struct PlacePickerPreview: View {
    @State var scope: Scope = .space(SampleHome.kitchenId, level: SampleHome.firstFloorId)
    var body: some View {
        NavigationStack { Form { SchedulePlacePicker(propertyId: SampleHome.propertyId, scope: $scope) } }
    }
}

#Preview {
    PlacePickerPreview().environment(AppEnvironment.preview())
}
