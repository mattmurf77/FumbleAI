import SwiftUI
import PlanKit
import HomeCore
import HomeCoreTesting
import PlanCanvas

/// Plan editor mode (spec 01 FR-PLN-40…51, mockup 6.2, `seven-views.md` §8 "Edit mode").
///
/// Header "Cancel / Edit {Floor} / Done"; the floor pills stay (passed in as `accessory`) so another floor can be
/// edited; a 1 ft grid, handles and snap guides are drawn by the canvas; an inspector card (name, W × D chips for
/// typed dimensions, Rename, type, delete) and a toolbar (Room, Split, Merge, Door, Window, Closet, Fine, Undo, Redo)
/// replace the summary strip. Drag the selected room's corner (reshape), edge (resize; shared walls move together)
/// or inside (move). Edits save when the finger lifts.
struct PlanEditorOverlay<Accessory: View>: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    let geometry: LevelGeometry
    let property: Property
    @Binding var viewport: Viewport
    let onFinish: () -> Void
    let onLevelAdded: (UUID) -> Void
    let accessory: Accessory

    @State private var editor: PlanEditorModel
    @State private var interaction: Interaction?
    @State private var gestures = GestureController()
    @State private var dimensionAxis: DimensionAxis?
    @State private var dimensionText = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var showOverlapAlert = false
    @State private var showAddFloor = false

    private enum Interaction { case edit, pan, tap, pinch }

    init(geometry: LevelGeometry, property: Property, viewport: Binding<Viewport>, initialSelection: UUID? = nil,
         onFinish: @escaping () -> Void, onLevelAdded: @escaping (UUID) -> Void = { _ in },
         @ViewBuilder accessory: () -> Accessory) {
        self.geometry = geometry; self.property = property; self._viewport = viewport
        self.onFinish = onFinish; self.onLevelAdded = onLevelAdded; self.accessory = accessory()
        _editor = State(initialValue: PlanEditorModel(geometry: geometry, unitSystem: property.unitSystem, selection: initialSelection))
    }

    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var unit: UnitSystem { property.unitSystem }

    var body: some View {
        VStack(spacing: 0) {
            header
            accessory
            canvas
            if let space = editor.selectedSpace { inspector(space) }
            toolbar
        }
        .sensoryFeedback(.selection, trigger: editor.hapticTick)
        .onChange(of: geometry.level.id) { _, _ in switchLevel() }
        .alert(dimensionAxis == .depth ? "Depth" : "Width", isPresented: dimensionBinding) {
            TextField("12'4\"", text: $dimensionText)
            Button("Set") { if let a = dimensionAxis { editor.setDimension(a, text: dimensionText, env: env) }; dimensionAxis = nil }
            Button("Cancel", role: .cancel) { dimensionAxis = nil }
        } message: {
            Text(dimensionAxis == .depth ? "Moves the bottom wall; the top stays put." : "Moves the right wall; the left stays put.")
        }
        .alert("Rename room", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { if let id = editor.session.selection { editor.apply(env: env, { s in s.rename(id, to: renameText); return true }) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rooms overlap", isPresented: $showOverlapAlert) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard changes", role: .destructive) { Task { await editor.revert(env: env); onFinish() } }
        } message: {
            Text("Move the highlighted rooms apart before leaving edit mode.")
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            if let space = editor.selectedSpace {
                Button("Move items to this floor", role: .destructive) { delete(space.id, to: .level(space.levelId)) }
                ForEach(editor.session.spaces.filter { $0.id != space.id && !$0.isExterior }) { other in
                    Button("Move items to \(other.name)", role: .destructive) { delete(space.id, to: .space(other.id, level: other.levelId)) }
                }
            }
        } message: {
            Text("The room goes to Recently Deleted for 30 days.")
        }
        .sheet(isPresented: $showAddFloor) {
            AddFloorSheet(property: property) { id in onLevelAdded(id) }
        }
        .confirmationDialog(stairsRequestTitle, isPresented: stairsRequestBinding, titleVisibility: .visible,
                            presenting: editor.stairsRequest) { req in
            Button("Add stairs on \(req.floor.level.name)") { Task { await editor.addMatchingStairs(req.polygon, on: req.floor, env: env) } }
            Button("Cancel", role: .cancel) { editor.stairsRequest = nil }
        } message: { req in
            Text("The stairwell will be cut out of \(req.blockers.joined(separator: ", ")) on \(req.floor.level.name).")
        }
        .task { await editor.loadOtherFloors(env: env) }
    }

    private var stairsRequestTitle: String { "Add matching stairs on \(editor.stairsRequest?.floor.level.name ?? "that floor")?" }

    private var stairsRequestBinding: Binding<Bool> {
        Binding(get: { editor.stairsRequest != nil }, set: { if !$0 { editor.stairsRequest = nil } })
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Cancel") { Task { await editor.revert(env: env); onFinish() } }
            Spacer()
            Text("Edit \(geometry.level.name)").font(.headline).lineLimit(1)
            Spacer()
            Menu {
                Button { showAddFloor = true } label: { Label("Add floor", systemImage: "plus.square.on.square") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17))
            }
            .accessibilityLabel("More")
            Button("Done") { finish() }.fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func finish() {
        Task {
            if await editor.flush(env: env) { onFinish() } else { showOverlapAlert = true }
        }
    }

    // MARK: Canvas + gestures

    private var canvas: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                PlanCanvasView(model: editor.renderModel, viewport: $viewport, selection: editor.session.selection,
                               mode: .edit, editor: overlayState)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(editDrag)
                    .simultaneousGesture(editPinch(size: g.size))
                    .accessibilityHidden(true)
                if let space = editor.selectedSpace, editor.tool == .select { dimensionChips(space) }
                banner
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var overlayState: EditorOverlayState {
        var s = editor.session.overlayState()
        s.gridIn = 12
        if editor.tool != .select { s.handles = []; s.edgeHandles = [] }
        return s
    }

    @ViewBuilder
    private var banner: some View {
        if let text = editor.message ?? editor.notice ?? editor.toolHint {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(editor.message != nil ? theme.danger : theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .top)
                .onTapGesture { editor.message = nil; editor.notice = nil }
        }
    }

    private var editDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if interaction == nil { begin(at: v.startLocation) }
                let moved = hypot(Double(v.translation.width), Double(v.translation.height))
                switch interaction {
                case .edit:
                    let s = max(viewport.scale, 1e-6)
                    editor.dragChanged(translation: Vec2(Double(v.translation.width) / s, Double(v.translation.height) / s), scale: s)
                case .tap where moved > 6:
                    interaction = .pan
                    viewport = gestures.pan(translation: v.translation, current: viewport)
                case .pan:
                    viewport = gestures.pan(translation: v.translation, current: viewport)
                default:
                    break
                }
            }
            .onEnded { v in
                switch interaction {
                case .edit: editor.dragEnded(env: env)
                case .pan: _ = gestures.endPan(velocity: .zero)
                case .tap: editor.tap(at: viewport.toModel(v.location), scale: viewport.scale, env: env)
                default: break
                }
                interaction = nil
            }
    }

    private func begin(at p: CGPoint) {
        guard editor.tool == .select else { interaction = .tap; return }
        let hit = editor.session.hitTest(viewport.toModel(p), scale: viewport.scale)
        switch hit {
        case .vertex, .edge:
            editor.session.beginDrag(hit)
            interaction = .edit
        case .interior(let id) where id == editor.session.selection:
            editor.session.beginDrag(hit)
            interaction = .edit
        default:
            interaction = .tap
        }
    }

    private func editPinch(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if interaction == .edit { editor.session.cancelDrag(); editor.refresh() }
                interaction = .pinch
                let anchor = CGPoint(x: v.startAnchor.x * size.width, y: v.startAnchor.y * size.height)
                viewport = gestures.pinch(magnification: Double(v.magnification), anchor: anchor, current: viewport)
            }
            .onEnded { _ in
                gestures.endPinch()
                gestures.cancel()
                interaction = nil
            }
    }

    // MARK: Dimension chips on the selected room (tap to type a size)

    @ViewBuilder
    private func dimensionChips(_ space: Space) -> some View {
        let b = space.polygon.bounds
        let top = viewport.toScreen(Vec2(b.center.x, b.minY))
        let right = viewport.toScreen(Vec2(b.maxX, b.center.y))
        dimChip(HomeLengthFormatter.format(b.width, system: unit), axis: .width).position(x: top.x, y: top.y - 16)
        dimChip(HomeLengthFormatter.format(b.height, system: unit), axis: .depth).position(x: right.x + 30, y: right.y)
    }

    private func dimChip(_ text: String, axis: DimensionAxis) -> some View {
        Button {
            dimensionText = text
            dimensionAxis = axis
        } label: {
            Text(LensFormat.primes(text))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(theme.accent))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(axis == .width ? "Width \(text)" : "Depth \(text)")
        .accessibilityHint("Type a new size")
    }

    private var dimensionBinding: Binding<Bool> {
        Binding(get: { dimensionAxis != nil }, set: { if !$0 { dimensionAxis = nil } })
    }

    // MARK: Inspector

    private func inspector(_ space: Space) -> some View {
        HStack(spacing: 12) {
            Image(systemName: space.spaceType == .stairs ? "stairs" : space.spaceType == .closet ? "cabinet" : "square.dashed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(LensFormat.primes(HomeLengthFormatter.dimensionText(for: space.polygon, isApproximate: space.isApproximate, system: unit))) · snaps to \(editor.session.fineGrid ? "1 in" : "6 in") · drag a wall")
                    .font(.footnote).foregroundStyle(theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button { renameText = space.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Menu {
                    ForEach(roomTypes, id: \.self) { t in
                        Button(t.displayName) { editor.apply(env: env, { s in s.setType(space.id, to: t); return true }) }
                    }
                } label: { Label("Room type", systemImage: "tag") }
                ForEach(editor.floorsMissing(space)) { floor in
                    Button { editor.requestMatchingStairs(space, on: floor, env: env) } label: {
                        Label("Add matching stairs on \(floor.level.name)", systemImage: "stairs")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete room", systemImage: "trash") }
            } label: {
                Text("Edit").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(theme.accentSoft))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var deleteTitle: String { "Delete \(editor.selectedSpace?.name ?? "room")? Where should its items go?" }

    private func delete(_ id: UUID, to scope: Scope) {
        editor.apply(env: env, { s in s.deleteRoom(id, reassignItemsTo: scope); return true })
    }

    private var roomTypes: [SpaceType] {
        geometry.level.isExterior
            ? [.patio, .deck, .gardenBed, .lawn, .driveway, .sidewalk, .shed, .pool, .frontYard, .backyard, .sideYard, .customZone]
            : [.room, .bedroom, .bathroom, .halfBath, .kitchen, .living, .dining, .family, .office, .laundry, .closet, .hall,
               .stairs, .garage, .utility, .mudroom, .storage]
    }

    // MARK: Toolbar (FR-PLN-41)

    private var toolbar: some View {
        HStack(spacing: 0) {
            Menu {
                let matches = editor.stairsToMatchHere
                if !matches.isEmpty {
                    Section("Line up with another floor") {
                        ForEach(matches) { m in
                            Button { editor.addStairsHere(m.polygons, from: m.floor, env: env) } label: {
                                Label("Stairs matching \(m.floor.level.name)", systemImage: "stairs")
                            }
                        }
                    }
                }
                ForEach(roomTypes, id: \.self) { t in
                    Button(t.displayName) { addRoom(t) }
                }
            } label: { toolLabel("Room", "plus.square", active: false) }
            Menu {
                Button { editor.tool = .split(vertical: true) } label: { Label("Vertical line", systemImage: "rectangle.split.2x1") }
                Button { editor.tool = .split(vertical: false) } label: { Label("Horizontal line", systemImage: "rectangle.split.1x2") }
            } label: { toolLabel("Split", "rectangle.split.2x1", active: isSplit) }
            .disabled(editor.selectedSpace == nil)
            toolButton("Merge", "rectangle.compress.vertical", tool: .merge).disabled(editor.selectedSpace == nil)
            toolButton("Door", "door.left.hand.open", tool: .door)
            toolButton("Window", "window.vertical.closed", tool: .window)
            toolButton("Closet", "cabinet", tool: .closet).disabled(geometry.level.isExterior)
            Button { editor.session.fineGrid.toggle() } label: {
                toolLabel("Fine", "grid", active: editor.session.fineGrid)
            }
            .accessibilityValue(editor.session.fineGrid ? "On, 1 inch" : "Off, 6 inches")
            Button { editor.undo(env: env) } label: { toolLabel("Undo", "arrow.uturn.backward", active: false) }
                .disabled(!editor.session.canUndo)
            Button { editor.redo(env: env) } label: { toolLabel("Redo", "arrow.uturn.forward", active: false) }
                .disabled(!editor.session.canRedo)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var isSplit: Bool { if case .split = editor.tool { return true }; return false }

    private func toolButton(_ title: String, _ symbol: String, tool: PlanEditorModel.Tool) -> some View {
        Button { editor.tool = editor.tool == tool ? .select : tool; editor.message = nil } label: {
            toolLabel(title, symbol, active: editor.tool == tool)
        }
    }

    private func toolLabel(_ title: String, _ symbol: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? theme.accent : theme.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? theme.accentSoft : Color.clear))
        .contentShape(Rectangle())
    }

    private func addRoom(_ type: SpaceType) {
        // Closets go inside a room, placed like a door: Room › Closet starts the Closet tool (tap a wall).
        if type == .closet && !geometry.level.isExterior {
            editor.tool = .closet
            editor.message = nil
            return
        }
        let center = viewport.toModel(CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2))
        // Stairs: a straight run, 3 ft 6 in wide × 10 ft long (drawn with treads).
        let size = geometry.level.isExterior ? Vec2(120, 96)
            : (type == .closet ? Vec2(48, 72) : type == .stairs ? Vec2(42, 120) : Vec2(144, 144))
        editor.tool = .select
        editor.apply(env: env, { s in s.addRoom(type: type, center: center, size: size) != nil },
                     failure: "Couldn’t place a room there.")
    }

    // MARK: Floor switching (pills still work in edit mode)

    private func switchLevel() {
        let old = editor
        Task { _ = await old.flush(env: env) }
        let next = PlanEditorModel(geometry: geometry, unitSystem: unit)
        editor = next
        interaction = nil
        gestures.cancel()
        Task { await next.loadOtherFloors(env: env) }
    }
}

#Preview("Editor · 1st floor") {
    PlanEditorPreviewHost().environment(AppEnvironment.preview())
}

private struct PlanEditorPreviewHost: View {
    @State private var viewport = Viewport.zero
    var body: some View {
        let s = SampleHome.snapshot()
        let level = SampleHome.firstFloorId
        let geo = LevelGeometry(level: s.levels[level]!, spaces: s.liveSpaces.filter { $0.levelId == level },
                                openings: s.liveOpenings.filter { $0.levelId == level })
        PlanEditorOverlay(geometry: geo, property: s.properties[SampleHome.propertyId]!, viewport: $viewport,
                          initialSelection: SampleHome.kitchenId, onFinish: {}) { EmptyView() }
    }
}
