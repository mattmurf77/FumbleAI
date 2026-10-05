import SwiftUI
import HomeCore
import HomeCoreTesting
import PlanCanvas

/// The app once a property exists: a bottom tab bar with Home ("What would you like to do?"), Plan, To-Dos,
/// Projects and Stuff ("Record your stuff"). One `HomeHubModel` feeds the counts and badges on every tab.
///
/// Plan lenses and floors are chosen through `env.selectedLens` / `env.pendingLevelID` before switching to the
/// Plan tab, which applies them. Deep links (`env.pendingDeepLink`) switch to the Plan tab, which consumes them.
/// Lists shared into the share extension (Notes, Messages…) open in Quick add when the app comes to the foreground;
/// receipts, documents and notes (from Mail, Photos, Files…) open the "File it" sheet, one share at a time.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .home
    @State private var model = HomeHubModel()
    @State private var sharedText: SharedText?
    @State private var sharedItem: SharedInboxItem?
    @State private var sharedQueue: [SharedInboxItem] = []
    @State private var demoSheet: DemoSheet?

    private struct SharedText: Identifiable { let id = UUID(); let text: String }

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var todoBadge: Int { model.counts.overdue + model.counts.dueToday }

    var body: some View {
        TabView(selection: $tab) {
            HomeHubView(model: model, onNavigate: navigate)
                .tabItem { tabLabel(.home) }
                .tag(AppTab.home)

            NavigationStack {
                PlanScreen()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { tabLabel(.plan) }
            .tag(AppTab.plan)

            NavigationStack {
                ToDosListView()
            }
            .tabItem { tabLabel(.todos) }
            .tag(AppTab.todos)
            .badge(todoBadge)

            HubRowsScreen(title: "Projects & budget",
                          subtitle: "Plan improvements, log finished work and keep an eye on costs.",
                          feedbackName: "Projects",
                          sections: HomeHubCatalog.projectSections(model.counts),
                          onNavigate: navigate)
                .tabItem { tabLabel(.projects) }
                .tag(AppTab.projects)

            HubRowsScreen(title: "Record your stuff",
                          subtitle: "Appliances, furniture, plants and outdoor features, pantry, clothing and storage.",
                          feedbackName: "Stuff",
                          sections: HomeHubCatalog.stuffSections(model.counts),
                          onNavigate: navigate)
                .tabItem { tabLabel(.stuff) }
                .tag(AppTab.stuff)
        }
        .tint(theme.accent)
        .task { await model.run(env: env) }
        .onChange(of: env.pendingDeepLink, initial: true) { _, ref in if ref != nil { tab = .plan } }
        .onAppear { applyDemo() }
        .sheet(item: $demoSheet) { $0.view }
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { collectShared() } }
        .sheet(item: $sharedText, onDismiss: showNextShared) { shared in
            QuickCaptureSheet(initialText: shared.text)
        }
        .sheet(item: $sharedItem, onDismiss: showNextShared) { item in
            SharedInboxSheet(item: item)
        }
    }

    /// Screenshot mode: open on the requested tab, floor and sheet.
    private func applyDemo() {
        guard let demo = DemoLaunch.current else { return }
        tab = demo.tab
        if let level = demo.levelID { env.pendingLevelID = level }
        if let sheet = demo.sheet {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                demoSheet = sheet
            }
        }
    }

    /// Shares waiting from the share extension: to-do text → Quick add (review step) on the To-Dos tab; receipts,
    /// documents and notes → "File it" on the Projects tab (after Quick add, one at a time).
    private func collectShared() {
        guard sharedText == nil, sharedItem == nil, demoSheet == nil else { return }
        let taken = SharedCaptureInbox.takeAll()
        guard !taken.isEmpty else { return }
        let todoText = taken.filter(\.entry.isTodoList).map(\.entry.text).filter { !$0.isEmpty }
        sharedQueue += taken.filter { !$0.entry.isTodoList }.compactMap(SharedInboxItem.make(from:))
        if !todoText.isEmpty {
            tab = .todos
            sharedText = SharedText(text: todoText.joined(separator: "\n"))
        } else {
            showNextShared()
        }
    }

    /// The next receipt / document / note waiting to be filed, if any.
    private func showNextShared() {
        guard sharedText == nil, sharedItem == nil, !sharedQueue.isEmpty else { return }
        tab = .projects
        sharedItem = sharedQueue.removeFirst()
    }

        private func tabLabel(_ t: AppTab) -> some View {
        Label(t.title, systemImage: t.symbol)
    }

    /// Tab switches requested by cards and rows. Other actions are handled by the screen that owns them.
    private func navigate(_ action: HubAction) {
        switch action {
        case .tab(let t):
            tab = t
        case .plan(let lens, let levelID):
            env.selectedLens = lens
            if let levelID { env.pendingLevelID = levelID }
            tab = .plan
        case .push, .sheet, .add:
            break
        }
    }
}

#Preview("Tabs") {
    MainTabView().environment(AppEnvironment.preview())
}
