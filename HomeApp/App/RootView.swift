import SwiftUI
import HomeCore

/// Placeholder root. INTEGRATION: Features/Plan owns the real PlanScreen (pills + lens menu + canvas + footer);
/// Features/Onboarding owns the no-property flow. Replace the body once those land.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var property: Property?
    @State private var levels: [Level] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if let property {
                    Section("Home") {
                        LabeledContent("Name", value: property.name)
                        LabeledContent("Sync", value: env.syncStatus.displayText)
                    }
                    Section("Floors") {
                        ForEach(levels) { level in
                            Label(level.name, systemImage: level.kind == .exterior ? "tree" : "square.split.bottomrightquarter")
                        }
                    }
                }
                Section("Views") {
                    ForEach(LensID.allCases, id: \.self) { lens in
                        Label(lens.title, systemImage: lens.symbol)
                    }
                }
            }
            .navigationTitle("Home")
            .overlay {
                if loaded && property == nil {
                    ContentUnavailableView("No home yet", systemImage: "house",
                                           description: Text("Onboarding will start here."))
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        property = try? await env.plan.currentProperty()
        loaded = true
        guard let id = property?.id else { return }
        for await update in env.plan.observeLevels(property: id) {
            levels = update
        }
    }
}

#Preview("Sample house") {
    RootView().environment(AppEnvironment.preview())
}

#Preview("Empty") {
    RootView().environment(AppEnvironment.preview(sample: false))
}
