import SwiftUI
import HomeCore

/// Step 1: optional typed address with autocomplete (FR-PLN-02, FR-EXT-02). No location permission.
/// The address is used for exterior seeding after the plan is created; "Skip" continues without one.
struct AddressStep: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepLabel(step: 1)
                Text("Where's your home?")
                    .font(.largeTitle.weight(.bold))
                Text("We use the address to lay out your yard from the satellite view. It stays on your devices and iCloud.")
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Street address", text: $model.addressQuery)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit { Task { await continueTapped() } }
                    if model.isResolving { ProgressView() }
                    if !model.addressQuery.isEmpty {
                        Button { model.addressQuery = ""; model.resolved = nil; model.suggestions = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel("Clear address")
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                if !model.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.suggestions) { s in
                            Button {
                                Task {
                                    let text = [s.title, s.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                                    model.addressQuery = text
                                    _ = await model.resolveAddress(env, text)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(.primary)
                                    if !s.subtitle.isEmpty { Text(s.subtitle).font(.footnote).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }

                if let r = model.resolved {
                    Label(r.displayName, systemImage: "mappin.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Address found: \(r.displayName)")
                }
                if let msg = model.addressMessage {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { Task { await continueTapped() } } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isResolving)
                Button("Skip — no address") {
                    model.addressQuery = ""; model.resolved = nil; model.addressMessage = nil
                    model.routes.append(.chooser)
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.addressQuery) {
            if model.resolved?.displayName != model.addressQuery { await model.updateSuggestions(env) }
        }
    }

    private func continueTapped() async {
        focused = false
        let q = model.addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, model.resolved?.displayName != q {
            // A failed lookup still continues: the yard can be set up by hand later.
            _ = await model.resolveAddress(env)
        }
        model.routes.append(.chooser)
    }
}

#Preview("Address") {
    NavigationStack { AddressStep(model: OnboardingModel()) }
        .environment(AppEnvironment.preview(sample: false))
}
