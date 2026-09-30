import SwiftUI
import PlanKit
import HomeCore
import PlanCanvas

/// The home screen (spec 02, mockup 2.x): property header, single-select view dropdown, floor pills, the plan
/// canvas with "+"/chips/pins, "Whole house"/"This floor" chips, and the summary strip. Tapping a room opens the
/// room sheet at the half detent; "+" opens the add picker preselected for the active view; the pencil enters the
/// plan editor. VoiceOver (or Settings › Show plan as a list) swaps the canvas for the list mirror.
struct PlanScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var model = PlanScreenModel()
    @State private var viewport = Viewport.zero
    @State private var selection: UUID?
    @State private var roomSheet: RoomSheetTarget?
    @State private var sheetDetent: PresentationDetent = .medium
    @State private var addRequest: AddRequest?
    @State private var isEditing = false
    @State private var editSelection: UUID?
    @State private var fitRequest = 0
    @State private var longPressRoom: UUID?
    @State private var renameTarget: UUID?
    @State private var renameText = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showAddFloor = false
    @State private var footerLink: FooterLinkTarget?
    @State private var listToggle = false

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var showList: Bool { voiceOver || model.settings.showPlanAsList || listToggle }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing, let geometry = model.geometry, let property = model.property {
                PlanEditorOverlay(geometry: geometry, property: property, viewport: $viewport, initialSelection: editSelection,
                                  onFinish: { isEditing = false; editSelection = nil },
                                  onLevelAdded: { id in model.select(level: id, env: env) }) {
                    pills
                }
            } else {
                header
                pills
                canvasArea
                SummaryStripView(footer: model.model.lens.footer, onTap: footerTapAction)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
        .background(theme.paper.ignoresSafeArea())
        .overlay {
            if model.loaded && model.property == nil {
                ContentUnavailableView("No home yet", systemImage: "house",
                                       description: Text("Create a floor plan to get started."))
                    .background(theme.paper)
            }
        }
        .task { await model.run(env: env) }
        .onChange(of: env.selectedLens) { _, l in model.setLens(l, env: env) }
        .onChange(of: model.levelId) { _, _ in viewport = .zero }
        .onChange(of: env.pendingDeepLink) { _, ref in if let ref { Task { await handleDeepLink(ref) } } }
        .onChange(of: model.loaded) { _, _ in if let ref = env.pendingDeepLink { Task { await handleDeepLink(ref) } } }
        .sheet(item: $roomSheet, onDismiss: { selection = nil; sheetDetent = .medium }) { target in
            roomSheetView(target)
                .presentationDetents([.medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $addRequest) { r in
            if let direct = r.direct {
                AddRouter(destination: AddDestination(kind: direct, spaceID: r.spaceID, levelID: r.levelID))
            } else {
                AddPicker(spaceID: r.spaceID, levelID: r.levelID, preselected: r.preselected, placeName: r.placeName)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(onShowLocation: { loc in
                showSearch = false
                if let l = loc.levelId { model.select(level: l, env: env) }
                if let s = loc.spaceId { openRoom(s) }
            })
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAddFloor) {
            if let p = model.property {
                AddFloorSheet(property: p) { id in model.select(level: id, env: env) }
            }
        }
        .sheet(item: $footerLink) { link in FooterLinkDestination(target: link) }
        .confirmationDialog(longPressTitle, isPresented: longPressBinding, titleVisibility: .visible, presenting: longPressRoom) { id in
            Button("Rename") { beginRename(id) }
            Button("Edit shape") { enterEdit(id) }
            Button("Add measurement") {
                addRequest = AddRequest(spaceID: id, levelID: model.levelId, preselected: .measurement, direct: .measurement)
            }
        }
        .alert("Rename room", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("1–60 characters.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.property?.name ?? " ")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    if let sub = propertySubtitle {
                        Text(sub).font(.system(size: 13)).foregroundStyle(theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    circleButton("magnifyingglass", label: "Search") { showSearch = true }
                    if !voiceOver {
                        circleButton(showList ? "square.split.bottomrightquarter" : "list.bullet",
                                     label: showList ? "Show plan" : "Show as list") { listToggle.toggle() }
                    }
                    circleButton("pencil", label: "Edit plan") { enterEdit(nil) }
                        .disabled(model.geometry == nil)
                    circleButton("gearshape", label: "Settings") { showSettings = true }
                }
            }
            lensMenu.padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private var propertySubtitle: String? {
        guard let a = model.property?.address else { return nil }
        let s = [a.locality, a.region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return s.isEmpty ? a.line : s
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
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

    /// Single-select pull-down with a checkmark on the active view (FR-CNV-20).
    private var lensMenu: some View {
        Menu {
            Picker("Show on plan", selection: Binding(get: { model.lens }, set: { model.setLens($0, env: env) })) {
                ForEach(LensID.allCases, id: \.self) { l in
                    Label(l.title, systemImage: l.symbol).tag(l)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.lens.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(model.lens.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        }
        .accessibilityLabel("View")
        .accessibilityValue(model.lens.title)
    }

    // MARK: Pills (floors change only here, decision #12)

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.levels) { l in
                    let on = l.id == model.levelId
                    Button {
                        guard !on else { return }
                        roomSheet = nil
                        selection = nil
                        model.select(level: l.id, env: env)
                    } label: {
                        Text(l.name)
                            .font(.system(size: 14, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? theme.paper : theme.ink)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(Capsule().fill(on ? theme.ink : theme.surface))
                            .overlay(Capsule().strokeBorder(on ? Color.clear : theme.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
                if model.property != nil {
                    Button { showAddFloor = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 32, height: 32)
                            .background(Capsule().fill(theme.surface))
                            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add floor")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if showList {
                    PlanListView(models: [model.model], onSelect: { openRoom($0) }, onAdd: { add(in: $0) })
                } else if model.geometry == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlanCanvasView(model: model.model, viewport: $viewport, selection: selection, fitRequest: fitRequest,
                                   obscuredBottom: roomSheet != nil && sheetDetent == .medium ? Double(g.size.height) * 0.45 : 0,
                                   onSelect: { id in select(id) },
                                   onAdd: { id in add(in: id) },
                                   onRename: { id in beginRename(id) },
                                   onLongPress: { id in longPressRoom = id },
                                   onPinTap: { pin in pinTapped(pin) })
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if model.model.spaces.isEmpty {
                        emptyFloor
                    }
                    Button { fitRequest += 1 } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(theme.surface))
                            .overlay(Circle().strokeBorder(theme.separator, lineWidth: 0.5))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fit floor")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                }
                if !showList {
                    ScopeChipsView(decorations: model.model.lens) { target in openScope(target) }
                        .padding(8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var emptyFloor: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed").font(.system(size: 34)).foregroundStyle(theme.ink3)
            Text("No rooms on this floor").font(.headline).foregroundStyle(theme.ink)
            Button("Add a room") { enterEdit(nil) }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func select(_ id: UUID?) {
        // Exterior: tapping the house outline jumps to the default (ground) floor.
        if let id, model.model.isExterior, model.model.geometry.space(id)?.spaceType == .footprint,
           let ground = model.levels.filter({ !$0.isExterior }).defaultLevel(preferred: model.property?.defaultLevelId) {
            selection = nil
            roomSheet = nil
            model.select(level: ground.id, env: env)
            return
        }
        selection = id
        if let id { roomSheet = .space(id) } else { roomSheet = nil }
    }

    private func openRoom(_ id: UUID) {
        selection = id
        roomSheet = .space(id)
    }

    private func openScope(_ t: ScopeChipsView.Target) {
        selection = nil
        switch t {
        case .wholeHouse: roomSheet = .scope(.property)
        case .thisFloor: if let l = model.levelId { roomSheet = .scope(.level(l)) }
        }
    }

    private func add(in spaceId: UUID) {
        let name = model.model.geometry.space(spaceId)?.name
        addRequest = AddRequest(spaceID: spaceId, levelID: model.levelId, preselected: model.lens.addDefault, placeName: name)
    }

    private func pinTapped(_ pin: PinModel) {
        if let s = pin.spaceId { openRoom(s) }
    }

    private func enterEdit(_ spaceId: UUID?) {
        roomSheet = nil
        selection = nil
        editSelection = spaceId
        isEditing = true
    }

    private var footerTapAction: (() -> Void)? {
        guard let link = model.model.lens.footer.link else { return nil }
        switch link {
        case .shoppingList: return { footerLink = .shoppingList }
        case .seasonalSwap: return { footerLink = .seasonalSwap }
        case .chores: return { footerLink = .chores }
        case .budget: return { footerLink = .budget }
        }
    }

    private var longPressTitle: String {
        longPressRoom.flatMap { model.model.geometry.space($0)?.name } ?? "Room"
    }

    private var longPressBinding: Binding<Bool> {
        Binding(get: { longPressRoom != nil }, set: { if !$0 { longPressRoom = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func beginRename(_ id: UUID) {
        renameText = model.model.geometry.space(id)?.name ?? ""
        renameTarget = id
    }

    private func commitRename() {
        guard let id = renameTarget else { return }
        let name = String(renameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task { try? await env.plan.renameSpace(id, to: name) }
    }

    @ViewBuilder
    private func roomSheetView(_ target: RoomSheetTarget) -> some View {
        switch target {
        case .space(let id):
            RoomSheet(spaceId: id, onEditShape: { sid in enterEdit(sid) })
        case .scope(let scope):
            RoomSheet(scope: scope)
        }
    }

    /// `home://chore/<uuid>` etc.: switch to the item's floor and view, then open its room sheet.
    private func handleDeepLink(_ ref: ItemRef) async {
        guard model.loaded else { return }
        env.pendingDeepLink = nil
        var scope: Scope?
        var lens: LensID?
        switch ref {
        case .chore(let id):
            scope = try? await env.chores.chore(id)?.scope; lens = .todos
        case .project(let id):
            let p = try? await env.projects.project(id)
            scope = p?.scope; lens = p?.status == .done ? .pastWork : .futureProjects
        case .thing(let id):
            scope = try? await env.things.thing(id)?.scope; lens = .things
        case .inventory(let id):
            scope = try? await env.inventory.item(id)?.scope; lens = .inventory
        case .measurement(let id):
            if let m = try? await env.measurements.measurement(id), let sid = m.spaceId,
               let sp = try? await env.plan.space(sid) {
                scope = .space(sid, level: sp.levelId)
            }
            lens = .plan
        }
        if let lens { model.setLens(lens, env: env) }
        guard let scope else { return }
        if let l = scope.levelId { model.select(level: l, env: env) }
        switch scope {
        case .space(let s, _): openRoom(s)
        case .level, .property: roomSheet = .scope(scope)
        }
    }
}

// MARK: - Presentation values

/// What the room sheet shows: one room, or a floor-wide / whole-house scope.
enum RoomSheetTarget: Hashable, Identifiable {
    case space(UUID)
    case scope(Scope)
    var id: String {
        switch self {
        case .space(let s): return "space:\(s)"
        case .scope(.property): return "property"
        case .scope(.level(let l)): return "level:\(l)"
        case .scope(.space(let s, _)): return "space:\(s)"
        }
    }
}

/// A pending "+" (room, floor or house) with the preselected kind; `direct` skips the picker.
struct AddRequest: Identifiable, Hashable {
    let id = UUID()
    var spaceID: UUID?
    var levelID: UUID?
    var preselected: AddKind?
    var direct: AddKind? = nil
    var placeName: String? = nil
}

enum FooterLinkTarget: String, Identifiable, Hashable {
    case shoppingList, seasonalSwap, chores, budget
    var id: String { rawValue }
}

/// Screens the summary strip links to (owned by other features).
private struct FooterLinkDestination: View {
    let target: FooterLinkTarget
    var body: some View {
        NavigationStack {
            switch target {
            case .shoppingList: ShoppingListView()
            case .seasonalSwap: SeasonalSwapView()
            case .chores: ToDosListView()
            case .budget: BudgetDrillDown()
            }
        }
    }
}

#Preview("Plan screen") {
    PlanScreen().environment(AppEnvironment.preview())
}

#Preview("Plan screen · empty") {
    PlanScreen().environment(AppEnvironment.preview(sample: false))
}
