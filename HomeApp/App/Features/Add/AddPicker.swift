import SwiftUI
import HomeCore
import HomeCoreTesting

/// The "+" sheet (mockup 3.2): the six item types; the active view's type is highlighted and badged "Default"
/// (FR-CNV-32; Plan has no default). Choosing a type swaps the sheet's content for that type's form, prefilled
/// with the room and floor, so saving or cancelling the form dismisses the whole sheet.
struct AddPicker: View {
    let spaceID: UUID?
    let levelID: UUID?
    let preselected: AddKind?
    var placeName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var destination: AddDestination?

    init(spaceID: UUID?, levelID: UUID?, preselected: AddKind?, placeName: String? = nil) {
        self.spaceID = spaceID; self.levelID = levelID; self.preselected = preselected; self.placeName = placeName
    }

    var body: some View {
        if let destination {
            AddRouter(destination: destination)
        } else {
            picker
        }
    }

    private var picker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AddKind.allCases, id: \.self) { kind in
                        row(kind)
                    }
                } footer: {
                    if let placeName { Text("Adds to \(placeName). You can change the place in the form.") }
                }
            }
            .navigationTitle(placeName.map { "Add to \($0)" } ?? "Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ kind: AddKind) -> some View {
        let info = AddKindInfo.of(kind)
        let isDefault = kind == preselected
        return Button {
            destination = AddDestination(kind: kind, spaceID: spaceID, levelID: levelID)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: info.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isDefault ? Color.white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isDefault ? Color.accentColor : Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        if isDefault {
                            Text("Default")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(Color.accentColor)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(info.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isDefault ? Color.accentColor.opacity(0.06) : nil)
        .accessibilityAddTraits(isDefault ? [.isSelected] : [])
        .accessibilityHint(isDefault ? "Default for this view" : "")
    }
}

#Preview("Add · To-Dos default") {
    AddPicker(spaceID: SampleHome.kitchenId, levelID: SampleHome.firstFloorId, preselected: .todo, placeName: "Kitchen")
        .environment(AppEnvironment.preview())
}

#Preview("Add · Plan (no default)") {
    AddPicker(spaceID: nil, levelID: SampleHome.firstFloorId, preselected: nil)
        .environment(AppEnvironment.preview())
}
