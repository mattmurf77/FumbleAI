import SwiftUI
import PlanKit
import HomeCore

/// Review before commit (mandatory for Scan, FR-PLN-38; shown for every path). Rename rooms, map scanned stories to
/// floors, see draft warnings, accept suggested Things (all unchecked by default), choose whether to set up the yard,
/// then commit the whole draft in one transaction through `PlanCommitting`.
struct ReviewDraft: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: OnboardingModel
    let onFinished: () -> Void
    @State private var levelIndex = 0

    var body: some View {
        if let draft = model.draft, !draft.levels.isEmpty {
            content(draft)
        } else {
            ContentUnavailableView("Nothing to review", systemImage: "square.dashed")
        }
    }

    @ViewBuilder
    private func content(_ draft: PlanDraft) -> some View {
        let li = min(levelIndex, draft.levels.count - 1)
        let level = draft.levels[li]
        List {
            if draft.levels.count > 1 {
                Section {
                    Picker("Floor", selection: $levelIndex) {
                        ForEach(draft.levels.indices, id: \.self) { i in Text(draft.levels[i].name).tag(i) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section {
                DraftPlanPreview(level: level, highlighted: Self.warnedSpaces(level))
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(summary(level))
            }

            if model.path == .scan, let story = level.storyIndex {
                Section {
                    Picker("Scanned floor \(story + 1) is", selection: Binding(
                        get: { model.storyKinds[story] ?? .floor },
                        set: { model.remapStory(story, to: $0, env: env) })) {
                        Text("A floor").tag(Level.Kind.floor)
                        Text("Basement").tag(Level.Kind.basement)
                        Text("Attic").tag(Level.Kind.attic)
                    }
                } footer: {
                    Text("The lowest scanned floor becomes the ground floor unless you started in the basement.")
                }
            }

            if !level.warnings.isEmpty {
                Section("Check these") {
                    ForEach(Array(level.warnings.enumerated()), id: \.offset) { _, w in
                        Label(Self.text(for: w, in: level), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !level.spaces.isEmpty {
                Section {
                    ForEach(level.spaces.indices, id: \.self) { si in
                        HStack {
                            TextField("Room name", text: nameBinding(level: li, space: si))
                                .textInputAutocapitalization(.words)
                            Spacer()
                            Text(HomeLengthFormatter.dimensionText(for: level.spaces[si].polygon, isApproximate: level.spaces[si].isApproximate))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Rooms")
                } footer: {
                    Text("Names are yours to change any time.")
                }
            } else {
                Section {
                    Text("No rooms yet. You'll add them in the editor.").foregroundStyle(.secondary)
                }
            }

            if !level.suggestedThings.isEmpty {
                Section {
                    ForEach(level.suggestedThings) { t in
                        Toggle(isOn: acceptBinding(t.tempId)) {
                            Text("We found a \(t.name.lowercased()) in \(roomName(t.spaceTempId, level)). Add it?")
                        }
                    }
                } header: {
                    Text("Found while scanning")
                } footer: {
                    Text("Nothing is added unless you check it.")
                }
            }

            if model.resolved != nil {
                Section {
                    Toggle("Set up the yard from the satellite view", isOn: $model.seedExterior)
                } footer: {
                    Text("Runs in the background after your plan opens.")
                }
            }
        }
        .navigationTitle("Review your plan")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let err = model.commitError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await model.commit(env, onFinished: onFinished) }
                } label: {
                    HStack {
                        if model.isSaving { ProgressView().tint(.white) }
                        Text(model.isSaving ? "Saving…" : "Create my plan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    // MARK: Bindings

    private func nameBinding(level li: Int, space si: Int) -> Binding<String> {
        Binding(
            get: { model.draft?.levels.onboardingElement(at: li)?.spaces.onboardingElement(at: si)?.name ?? "" },
            set: { newValue in
                guard var d = model.draft, li < d.levels.count, si < d.levels[li].spaces.count else { return }
                d.levels[li].spaces[si].name = String(newValue.prefix(60))
                model.draft = d
            })
    }

    private func acceptBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.acceptedSuggestions.contains(id) },
                set: { on in if on { model.acceptedSuggestions.insert(id) } else { model.acceptedSuggestions.remove(id) } })
    }

    // MARK: Text

    private func roomName(_ id: UUID?, _ level: LevelDraft) -> String {
        level.spaces.first { $0.tempId == id }?.name ?? level.name
    }

    private func summary(_ level: LevelDraft) -> String {
        let area = level.spaces.filter { !$0.isExterior }.reduce(0) { $0 + $1.polygon.area }
        let rooms = level.spaces.count
        guard rooms > 0 else { return level.name }
        let approx = level.spaces.contains { $0.isApproximate } ? "~" : ""
        return "\(level.name) · \(rooms) room\(rooms == 1 ? "" : "s") · \(approx)\(HomeLengthFormatter.formatArea(squareInches: area))"
    }

    static func warnedSpaces(_ level: LevelDraft) -> Set<UUID> {
        var ids = Set<UUID>()
        for w in level.warnings {
            switch w {
            case .overlap(let s): ids.formUnion(s)
            case .weldFailed(let s), .hullFallback(let s): ids.insert(s)
            default: break
            }
        }
        return ids
    }

    static func text(for w: DraftWarning, in level: LevelDraft) -> String {
        func name(_ id: UUID) -> String { level.spaces.first { $0.tempId == id }?.name ?? "A room" }
        switch w {
        case .overlap(let ids): return "\(ids.map(name).joined(separator: " and ")) overlap. Adjust them after saving."
        case .weldFailed(let id): return "\(name(id))'s walls didn't line up with its neighbors."
        case .hullFallback(let id): return "\(name(id))'s outline was estimated. Check its shape."
        case .possiblyStretched: return "This image may be stretched. Try the document scanner."
        case .footprintFallback: return "We couldn't find your house outline. Drag the block to match the photo."
        case .other(let s): return s
        }
    }
}

extension Array {
    /// Bounds-checked element access (onboarding review bindings).
    fileprivate func onboardingElement(at i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

#Preview("Review – rough") {
    let model = OnboardingModel()
    model.draft = StubPreviewDrafts.rough()
    model.path = .rough
    return NavigationStack { ReviewDraft(model: model, onFinished: {}) }
        .environment(AppEnvironment.preview(sample: false))
}
