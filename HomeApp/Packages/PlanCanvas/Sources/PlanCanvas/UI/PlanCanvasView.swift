#if canImport(SwiftUI)
import SwiftUI
import PlanKit
import HomeCore

/// The floor-plan canvas: a SwiftUI `Canvas` drawing a `LevelRenderModel` through `Painter`, with SwiftUI overlays
/// ("+", chips, pins), browse gestures (tap, double-tap, pan with momentum, pinch, long-press) and one accessibility
/// element per room. LLD §7.
///
/// - `viewport` is owned by the caller so the editor, sheet-awareness and "fit" can drive it.
/// - `mode == .edit`: no browse gestures and no "+"/chips/pins (the editor overlay owns touches); `editor` draws the
///   grid, handles, guides and invalid rooms.
public struct PlanCanvasView: View {
    public enum Mode: Hashable, Sendable { case browse, edit }

    let model: LevelRenderModel
    @Binding var viewport: Viewport
    let selection: UUID?
    let mode: Mode
    let editor: EditorOverlayState?
    let fitRequest: Int
    let obscuredBottom: Double
    let onSelect: (UUID?) -> Void
    let onAdd: (UUID) -> Void
    let onRename: (UUID) -> Void
    let onLongPress: (UUID) -> Void
    let onPinTap: (PinModel) -> Void

    @State private var gestures = GestureController()
    @State private var motionTask: Task<Void, Never>?
    @State private var isPinching = false
    @State private var fittedLevel: UUID?
    @State private var fittedEmpty = true
    @Namespace private var rotorNamespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.planTheme) private var themeOverride
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: LevelRenderModel, viewport: Binding<Viewport>, selection: UUID? = nil, mode: Mode = .browse,
                editor: EditorOverlayState? = nil, fitRequest: Int = 0, obscuredBottom: Double = 0,
                onSelect: @escaping (UUID?) -> Void = { _ in }, onAdd: @escaping (UUID) -> Void = { _ in },
                onRename: @escaping (UUID) -> Void = { _ in }, onLongPress: @escaping (UUID) -> Void = { _ in },
                onPinTap: @escaping (PinModel) -> Void = { _ in }) {
        self.model = model; self._viewport = viewport; self.selection = selection; self.mode = mode; self.editor = editor
        self.fitRequest = fitRequest; self.obscuredBottom = obscuredBottom; self.onSelect = onSelect; self.onAdd = onAdd
        self.onRename = onRename; self.onLongPress = onLongPress; self.onPinTap = onPinTap
    }

    public var body: some View {
        GeometryReader { geo in
            let theme = themeOverride ?? PlanTheme.forScheme(scheme)
            let editing = mode == .edit || editor != nil
            let layout = OverlayLayout.compute(model: model, viewport: viewport, isEditing: editing)
            ZStack(alignment: .topLeading) {
                canvas(theme: theme, layout: layout)
                if !editing { overlays(layout) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(tapGesture(size: geo.size), including: mode == .browse ? .all : .subviews)
            .simultaneousGesture(panGesture(), including: mode == .browse ? .all : .subviews)
            .simultaneousGesture(pinchGesture(size: geo.size), including: mode == .browse ? .all : .subviews)
            .simultaneousGesture(longPressGesture(), including: mode == .browse ? .all : .subviews)
            .onAppear { configure(size: geo.size) }
            .onChange(of: geo.size) { _, s in configure(size: s) }
            .onChange(of: model.levelId) { _, _ in configure(size: geo.size) }
            .onChange(of: model.bounds) { _, b in if fittedEmpty && !b.isNull { refit(size: geo.size) } }
            .onChange(of: fitRequest) { _, _ in animate(to: fitted(size: geo.size)) }
            .onChange(of: obscuredBottom) { _, _ in revealSelection() }
            .onChange(of: selection) { _, _ in revealSelection() }
            .onDisappear { motionTask?.cancel() }
        }
    }

    // MARK: Canvas + accessibility

    @ViewBuilder
    private func canvas(theme: PlanTheme, layout: OverlayLayout) -> some View {
        let rooms = AccessibilityModel.rooms(model: model, viewport: viewport)
        let overdue = rooms.filter(\.hasOverdue)
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
            Painter(theme: theme).draw(&ctx, size: size, model: model, viewport: viewport, labels: layout.labels,
                                       selection: selection, editor: editor)
        }
        .accessibilityLabel(Text("Floor plan, \(model.geometry.levelName)"))
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(rooms) { r in
                    Color.clear
                        .frame(width: r.frame.width, height: r.frame.height)
                        .position(x: r.frame.midX, y: r.frame.midY)
                        .accessibilityElement()
                        .accessibilityLabel(Text(r.label))
                        .accessibilityValue(Text(r.value))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onSelect(r.id) }
                        .accessibilityAction(named: Text("Add item")) { onAdd(r.id) }
                        .accessibilityAction(named: Text("Rename")) { onRename(r.id) }
                        .accessibilityRotorEntry(id: r.id, in: rotorNamespace)
                }
            }
        }
        .accessibilityRotor(Text("Rooms with overdue chores")) {
            ForEach(overdue) { r in
                AccessibilityRotorEntry(Text(r.label), id: r.id, in: rotorNamespace)
            }
        }
    }

    @ViewBuilder
    private func overlays(_ layout: OverlayLayout) -> some View {
        let fade = isPinching && layout.fadesDuringPinch
        ForEach(layout.addButtons) { b in
            AddButtonView(isQuiet: b.isQuiet) { onAdd(b.id) }
                .position(b.center)
        }
        ForEach(layout.chips) { c in
            ChipView(c.chip)
                .position(x: c.isCorner ? c.center.x - 12 : c.center.x, y: c.center.y)
                .opacity(fade ? 0 : 1)
                .allowsHitTesting(false)
        }
        ForEach(layout.pins) { p in
            Button {
                if p.isCluster { zoom(by: 2, at: p.center) } else if let pin = p.pins.first { onPinTap(pin) }
            } label: {
                PinView(p).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(p.center)
            .opacity(fade ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.12), value: fade)
    }

    // MARK: Gestures

    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { v in
                if let id = CanvasHitTesting.space(at: v.location, model: model, viewport: viewport),
                   let s = model.geometry.space(id) {
                    animate(to: viewport.focusing(on: s.bbox))
                } else {
                    zoom(by: 2, at: v.location)
                }
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                onSelect(CanvasHitTesting.space(at: v.location, model: model, viewport: viewport))
            })
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if !gestures.isActive { motionTask?.cancel() }
                gestures.contentBounds = model.bounds.isNull ? nil : model.bounds
                viewport = gestures.pan(translation: v.translation, current: viewport)
            }
            .onEnded { v in
                if let m = gestures.endPan(velocity: v.velocity) { runMomentum(m) }
            }
    }

    private func pinchGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if !gestures.isActive { motionTask?.cancel() }
                gestures.contentBounds = model.bounds.isNull ? nil : model.bounds
                let anchor = CGPoint(x: v.startAnchor.x * size.width, y: v.startAnchor.y * size.height)
                viewport = gestures.pinch(magnification: Double(v.magnification), anchor: anchor, current: viewport)
                if !isPinching { isPinching = true }
            }
            .onEnded { _ in
                gestures.endPinch()
                isPinching = false
            }
    }

    /// Long-press a room → context actions (Rename, Edit shape, Add measurement) shown by the caller.
    private func longPressGesture() -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                if case .second(true, let drag?) = value,
                   let id = CanvasHitTesting.space(at: drag.location, model: model, viewport: viewport) {
                    onLongPress(id)
                }
            }
    }

    // MARK: Viewport management

    private func fitted(size: CGSize) -> Viewport {
        var v = Viewport.fit(model.bounds, in: size)
        v.obscuredBottom = obscuredBottom
        return v
    }

    private func refit(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        motionTask?.cancel()
        viewport = fitted(size: size)
        fittedLevel = model.levelId
        fittedEmpty = model.bounds.isNull
    }

    private func configure(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if fittedLevel == nil, viewport.isConfigured, viewport.size == size, !model.bounds.isNull {
            // A new canvas for the same level (e.g. entering edit mode): keep the caller's zoom and pan.
            fittedLevel = model.levelId
            fittedEmpty = false
            return
        }
        if fittedLevel != model.levelId || !viewport.isConfigured {
            refit(size: size)
        } else if viewport.size != size {
            viewport = viewport.resized(to: size)
        }
    }

    private func revealSelection() {
        var v = viewport
        v.obscuredBottom = obscuredBottom
        guard let sel = selection, let s = model.geometry.space(sel), obscuredBottom > 0 else { viewport = v; return }
        animate(to: v.revealing(s.bbox))
    }

    private func zoom(by factor: Double, at point: CGPoint) {
        var v = viewport
        v.zoom(by: factor, anchor: point)
        animate(to: v)
    }

    /// Animates the viewport (Canvas redraws per step). Reduce Motion jumps straight to the target.
    private func animate(to target: Viewport) {
        motionTask?.cancel()
        guard !reduceMotion else { viewport = target; return }
        let start = viewport
        let t0 = Date()
        let duration = 0.28
        motionTask = Task { @MainActor in
            while !Task.isCancelled {
                let t = min(Date().timeIntervalSince(t0) / duration, 1)
                let eased = 1 - pow(1 - t, 3)
                viewport = start.interpolated(to: target, eased)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    /// Pan momentum (τ = 325 ms) until it settles or another gesture starts.
    private func runMomentum(_ m: Momentum) {
        motionTask?.cancel()
        guard !reduceMotion else { return }
        let start = viewport
        let bounds = model.bounds.isNull ? nil : model.bounds
        let t0 = Date()
        motionTask = Task { @MainActor in
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(t0)
                viewport = GestureController.apply(m, to: start, elapsed: t, contentBounds: bounds)
                if m.isFinished(at: t) { break }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }
}

// MARK: - List mirror (FR-CNV-51, LLD §7.6)

/// VoiceOver-friendly list of the level's rooms with the same per-lens values as the chips.
public struct PlanListView: View {
    let models: [LevelRenderModel]
    let onSelect: (UUID) -> Void
    let onAdd: (UUID) -> Void

    public init(models: [LevelRenderModel], onSelect: @escaping (UUID) -> Void, onAdd: @escaping (UUID) -> Void = { _ in }) {
        self.models = models; self.onSelect = onSelect; self.onAdd = onAdd
    }

    public var body: some View {
        List {
            ForEach(models, id: \.levelId) { m in
                Section(m.geometry.levelName) {
                    ForEach(AccessibilityModel.listRows(model: m)) { row in
                        Button { onSelect(row.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.body.weight(.semibold))
                                    Text(row.value).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let chip = row.chip { ChipView(chip) }
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(row.name))
                        .accessibilityValue(Text(row.value))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: Text("Add item")) { onAdd(row.id) }
                    }
                }
            }
        }
    }
}

#endif
