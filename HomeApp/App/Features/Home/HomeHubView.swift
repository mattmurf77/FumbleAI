import SwiftUI
import HomeCore
import HomeCoreTesting
import PlanCanvas

/// The landing screen once a property exists: "What would you like to do?" with the home's name/address, a live
/// one-line summary and a grid of large cards, one per area of the app.
///
/// Navigation: this view owns the app's `NavigationStack` and is its root. Every card pushes (so the system back
/// button returns here) except screens that bring their own `NavigationStack` (Search, Settings, yard setup), which
/// open as sheets. Plan "lenses" (To-Dos, Future, Past, Things, Inventory, Budget) push `PlanScreen` after setting
/// `env.selectedLens`, which `PlanScreenModel.run` reads when the screen starts. Deep links (`env.pendingDeepLink`)
/// push the plan so `PlanScreen` can consume them.
struct HomeHubView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var model = HomeHubModel()
    @State private var path: [HubRoute] = []
    @State private var sheet: HubSheet?

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var columns: Int { typeSize.isAccessibilitySize ? 1 : 2 }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Home")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HubRoute.self) { route in destination(route) }
        }
        .tint(theme.accent)
        .task { await model.run(env: env) }
        .onAppear { if env.pendingDeepLink != nil { showPlanForDeepLink() } }
        .onChange(of: env.pendingDeepLink) { _, ref in if ref != nil { showPlanForDeepLink() } }
        .sheet(item: $sheet) { s in sheetContent(s) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.paper.ignoresSafeArea())
        } else if model.property == nil {
            ContentUnavailableView("No home yet", systemImage: "house",
                                   description: Text("Create a floor plan to get started."))
                .background(theme.paper.ignoresSafeArea())
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(HubGridPaper(theme: theme).ignoresSafeArea())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sub = model.subtitle {
                Text(sub)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(2)
            }
            Text("What would you like to do?")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.accentSoft))
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func sectionView(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.ink3)
                .accessibilityAddTraits(.isHeader)
            if section.id == "home" {
                VStack(spacing: 10) {
                    ForEach(section.cards) { card in
                        HubWideCardView(card: card, theme: theme, onTap: perform)
                    }
                }
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(rows(section.cards), id: \.self) { row in
                        GridRow {
                            ForEach(row) { card in
                                HubCardView(card: card, theme: theme, onTap: perform)
                            }
                            if row.count < columns {
                                ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func rows(_ cards: [HubCard]) -> [[HubCard]] {
        stride(from: 0, to: cards.count, by: columns).map { Array(cards[$0..<min($0 + columns, cards.count)]) }
    }

    // MARK: Navigation

    private func perform(_ action: HubAction) {
        switch action {
        case .push(let route):
            if case .plan(let lens, _) = route { env.selectedLens = lens }
            path.append(route)
        case .sheet(let s):
            sheet = s
        }
    }

    @ViewBuilder
    private func destination(_ route: HubRoute) -> some View {
        switch route {
        case .plan(_, let levelID):
            planScreen(levelID: levelID)
        case .todosList:
            ToDosListView()
        case .budget:
            BudgetDrillDown()
        case .storage:
            StorageTreeView()
        case .shoppingList:
            ShoppingListView()
        case .seasonalSwap:
            SeasonalSwapView()
        case .housemates:
            PeopleEditor()
        }
    }

    /// `PlanScreen` pushed onto the hub's stack. It has no `NavigationStack` of its own (its search / settings /
    /// add flows are sheets), so the system back button ("Home") returns here.
    ///
    /// INTEGRATION(home-hub): `PlanScreen` can't be told which floor to open yet. Once it takes
    /// `PlanScreen(initialLevelID:)` (see INTEGRATION_NOTES/home-hub.md), pass `levelID` and drop the hint overlay.
    @ViewBuilder
    private func planScreen(levelID: UUID?) -> some View {
        PlanScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.paper, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if levelID != nil {
                    HubPlanHint(text: HomeHubCatalog.levelHint(levelName: model.counts.exteriorLevelName), theme: theme)
                        .padding(.bottom, 72)
                }
            }
    }

    /// A notification tap / `home://` link / search hit for a chore or project: the plan consumes
    /// `env.pendingDeepLink`, so make sure it is on screen.
    private func showPlanForDeepLink() {
        sheet = nil
        if case .plan? = path.last { return }
        path.append(.plan(lens: env.selectedLens))
    }

    @ViewBuilder
    private func sheetContent(_ s: HubSheet) -> some View {
        switch s {
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        case .addYard:
            if let property = model.property {
                YardSetupSheet(property: property) { levelID in
                    sheet = nil
                    env.selectedLens = .plan
                    path.append(.plan(lens: .plan, levelID: levelID))
                }
            }
        }
    }
}

// MARK: - Cards

/// Grid card: symbol tile + badge, title, one-line description, optional secondary link.
struct HubCardView: View {
    let card: HubCard
    let theme: PlanTheme
    let onTap: (HubAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onTap(card.action) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        HubSymbolTile(symbol: card.symbol, theme: theme)
                        Spacer(minLength: 4)
                        if let badge = card.badge {
                            HubBadge(text: badge, tone: card.badgeTone, theme: theme)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                        Text(card.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.ink2)
                            .lineLimit(3)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(HubPressStyle())

            if let title = card.secondaryTitle, let action = card.secondaryAction {
                Rectangle().fill(theme.separator).frame(height: 0.5)
                Button { onTap(action) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: LensID.plan.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(card.title): \(title)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button { onTap(card.action) } label: { Text("Open \(card.title)") }
            if let title = card.secondaryTitle, let action = card.secondaryAction {
                Button { onTap(action) } label: { Label(title, systemImage: LensID.plan.symbol) }
            }
        }
    }
}

/// Full-width card for the "Your home" section (floor plan, yard): drawn on a blueprint grid.
struct HubWideCardView: View {
    let card: HubCard
    let theme: PlanTheme
    let onTap: (HubAction) -> Void

    var body: some View {
        Button { onTap(card.action) } label: {
            HStack(spacing: 14) {
                HubSymbolTile(symbol: card.symbol, theme: theme, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(card.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.ink2)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if let badge = card.badge {
                    HubBadge(text: badge, tone: card.badgeTone, theme: theme)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface)
                    HubGridPaper(theme: theme, spacing: 12)
                        .opacity(0.9)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(HubPressStyle())
    }
}

struct HubSymbolTile: View {
    let symbol: String
    let theme: PlanTheme
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(theme.accentSoft))
            .accessibilityHidden(true)
    }
}

struct HubBadge: View {
    let text: String
    let tone: HubCard.Tone
    let theme: PlanTheme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tone == .attention ? theme.danger : theme.ink2)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(tone == .attention ? theme.dangerSoft : theme.surface2))
    }
}

struct HubPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The listing floor-plan "paper": faint blueprint grid on the paper color.
struct HubGridPaper: View {
    let theme: PlanTheme
    var spacing: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = 0
            while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y: CGFloat = 0
            while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            ctx.stroke(p, with: .color(theme.grid), lineWidth: 0.5)
        }
        .background(theme.paper)
        .accessibilityHidden(true)
    }
}

/// Short-lived hint over the plan (e.g. "Tap “Outside” in the floor pills").
struct HubPlanHint: View {
    let text: String
    let theme: PlanTheme
    @State private var visible = true

    var body: some View {
        ZStack {
            if visible {
                Label(text, systemImage: "hand.tap")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accent))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture { withAnimation { visible = false } }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { visible = false }
        }
    }
}

// MARK: - Yard setup

/// "Yard & Exterior" when the plan has no outside level: explains, then either maps the yard from the home's
/// address (the same exterior seeding onboarding runs) or opens the editor's "Add floor" sheet to draw it by hand.
struct YardSetupSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let property: Property
    let onAdded: (UUID) -> Void

    @State private var working = false
    @State private var message: String?
    @State private var showManual = false

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HubSymbolTile(symbol: "tree", theme: theme, size: 56)
                    Text("Add your yard")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Text("Your plan doesn’t have an outside level yet. Add one to map the lawn, beds, patio and driveway, and keep outside jobs like gutters or mowing in the right place.")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    if property.coordinate != nil {
                        Button { Task { await mapFromAddress() } } label: {
                            HStack {
                                if working { ProgressView().tint(theme.onAccent) } else { Image(systemName: "map") }
                                Text(working ? "Finding your house…" : "Map it from my address")
                            }
                            .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                    }
                    Button { showManual = true } label: {
                        Label("Draw it myself", systemImage: "pencil.and.outline")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                    Text("Drawing it yourself? Choose Kind › Outside on the next screen.")
                        .font(.footnote)
                        .foregroundStyle(theme.ink3)

                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(theme.danger)
                    }
                }
                .padding(20)
            }
            .background(theme.paper.ignoresSafeArea())
            .navigationTitle("Yard & Exterior")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showManual) {
                AddFloorSheet(property: property) { id in onAdded(id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func mapFromAddress() async {
        guard let coordinate = property.coordinate else { return }
        working = true
        message = nil
        defer { working = false }
        let address = ResolvedAddress(address: property.address ?? PostalAddressLite(), coordinate: coordinate,
                                      displayName: property.address?.singleLine ?? property.name)
        let level = await env.exteriorSeeder.exteriorLevel(for: address)
        if level.warnings.contains(.other(OnboardingModel.footprintUnavailableTag)) || level.spaces.isEmpty {
            message = "Couldn’t find your house outline right now. Draw the yard yourself, or try again later."
            return
        }
        do {
            let ids = try await env.planCommitter.commit(PlanDraft(levels: [level], source: .autoseed),
                                                         into: property.id, acceptedSuggestions: [])
            guard let levelID = ids.first else { return }
            // Local-only satellite image under the zones (best effort, never blocks).
            let snapshots = env.snapshots
            Task.detached(priority: .utility) {
                _ = try? await snapshots.snapshot(center: coordinate, spanMeters: 90, levelId: levelID)
            }
            onAdded(levelID)
        } catch {
            message = "Couldn’t add the yard: \(error.localizedDescription)"
        }
    }
}

// MARK: - Previews

#Preview("Home hub") {
    HomeHubView().environment(AppEnvironment.preview())
}

#Preview("Home hub · large text") {
    HomeHubView()
        .environment(AppEnvironment.preview())
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Home hub · dark") {
    HomeHubView()
        .environment(AppEnvironment.preview())
        .preferredColorScheme(.dark)
}

#Preview("No home") {
    HomeHubView().environment(AppEnvironment.preview(sample: false))
}

#Preview("Cards") {
    let counts: HubCounts = {
        var c = HubCounts()
        c.overdue = 1; c.dueToday = 2; c.lowCount = 2; c.plannedCents = 420_000; c.ownedThings = 5; c.plannedThings = 1
        return c
    }()
    ScrollView {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                HubCardView(card: HomeHubCatalog.todos(counts), theme: .light, onTap: { _ in })
                HubCardView(card: HomeHubCatalog.inventory(counts), theme: .light, onTap: { _ in })
            }
            GridRow {
                HubCardView(card: HomeHubCatalog.things(counts), theme: .light, onTap: { _ in })
                HubCardView(card: HomeHubCatalog.budget(counts), theme: .light, onTap: { _ in })
            }
        }
        HubWideCardView(card: HomeHubCatalog.yard(counts), theme: .light, onTap: { _ in })
    }
    .padding()
    .background(HubGridPaper(theme: .light))
}

#Preview("Yard setup") {
    Color.clear.sheet(isPresented: .constant(true)) {
        YardSetupSheet(property: Property(name: "Maple Street")) { _ in }
    }
    .environment(AppEnvironment.preview())
}
