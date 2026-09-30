import SwiftUI
import HomeCore
import HomeCoreTesting
import PlanCanvas

/// The Home tab: "What would you like to do?" with the home's name/address, a live one-line summary, the house
/// (floor plan, yard) and four task cards. Cards switch tabs (`onNavigate`); Search, Settings and yard setup open as
/// sheets. Counts come from the `HomeHubModel` that `MainTabView` shares across tabs.
struct HomeHubView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    let model: HomeHubModel
    /// Handles `.tab` and `.plan` actions (tab switches).
    let onNavigate: (HubAction) -> Void

    @State private var sheet: HubSheet?

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var columns: Int { typeSize.isAccessibilitySize ? 1 : 2 }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Home")
                .toolbar(.hidden, for: .navigationBar)
        }
        .feedbackPage("Home")
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
            HStack(alignment: .top, spacing: 8) {
                if let sub = model.subtitle {
                    Text(sub)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .lineLimit(2)
                        .padding(.top, 12)
                }
                Spacer(minLength: 0)
                HubCircleButton(symbol: "gearshape", label: "Settings", theme: theme) { sheet = .settings }
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
        case .sheet(let s):
            sheet = s
        default:
            onNavigate(action)
        }
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
                    onNavigate(.plan(lens: .plan, levelID: levelID))
                }
            }
        }
    }
}

/// The Projects and Stuff tabs: a short header and grouped rows. Rows push inside the tab's stack, open create
/// forms as sheets, or switch to the Plan tab with a lens (`onNavigate`).
struct HubRowsScreen: View {
    @Environment(\.colorScheme) private var scheme

    let title: String
    let subtitle: String
    let feedbackName: String
    let sections: [HubRowSection]
    let onNavigate: (HubAction) -> Void

    @State private var path: [HubRoute] = []
    @State private var adding: AddDestination?

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(theme.ink2)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in rowView(row) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: HubRoute.self) { route in destination(route) }
        }
        .tint(theme.accent)
        .feedbackPage(feedbackName)
        .sheet(item: $adding) { d in AddRouter(destination: d) }
    }

    private func rowView(_ row: HubRow) -> some View {
        Button { perform(row.action) } label: {
            HStack(spacing: 12) {
                HubSymbolTile(symbol: row.symbol, theme: theme, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.body.weight(.semibold)).foregroundStyle(theme.ink)
                    Text(row.detail).font(.subheadline).foregroundStyle(theme.ink2).lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if let badge = row.badge {
                    HubBadge(text: badge, tone: row.badgeTone, theme: theme)
                }
                Image(systemName: isAdd(row.action) ? "plus" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isAdd(_ action: HubAction) -> Bool {
        if case .add = action { return true }
        return false
    }

    private func perform(_ action: HubAction) {
        switch action {
        case .push(let route): path.append(route)
        case .add(let d): adding = d
        default: onNavigate(action)
        }
    }

    @ViewBuilder
    private func destination(_ route: HubRoute) -> some View {
        switch route {
        case .budget: BudgetDrillDown()
        case .storage: StorageTreeView()
        case .shoppingList: ShoppingListView()
        case .seasonalSwap: SeasonalSwapView()
        }
    }
}

struct HubCircleButton: View {
    let symbol: String
    let label: String
    let theme: PlanTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.surface))
                .overlay(Circle().strokeBorder(theme.separator, lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 132)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// Always ends with a yard (founder bug "Exterior/yard is missing"): the address footprint when the lookup works,
    /// else the ground floor's outline (or the 40 × 30 ft block) with the default zones — see `ExteriorSetup`.
    @MainActor
    private func mapFromAddress() async {
        working = true
        message = nil
        defer { working = false }
        let services = ExteriorSetup.Services(env)
        let id = await ExteriorSetup.ensureOutside(services, propertyId: property.id,
                                                   address: ExteriorSetup.address(of: property), groundOutline: nil)
        if let id {
            onAdded(id)
        } else {
            message = "Couldn’t add the yard. Try again, or draw it yourself."
        }
    }
}

// MARK: - Previews

#Preview("Home tab") {
    MainTabView().environment(AppEnvironment.preview())
}

#Preview("Home tab · large text") {
    MainTabView()
        .environment(AppEnvironment.preview())
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Home tab · dark") {
    MainTabView()
        .environment(AppEnvironment.preview())
        .preferredColorScheme(.dark)
}

#Preview("No home") {
    MainTabView().environment(AppEnvironment.preview(sample: false))
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
                HubCardView(card: HomeHubCatalog.projects(counts), theme: .light, onTap: { _ in })
            }
            GridRow {
                HubCardView(card: HomeHubCatalog.stuff(counts), theme: .light, onTap: { _ in })
                HubCardView(card: HomeHubCatalog.search, theme: .light, onTap: { _ in })
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
