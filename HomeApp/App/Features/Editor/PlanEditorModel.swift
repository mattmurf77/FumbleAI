import Foundation
import Observation
import PlanKit
import HomeCore
import PlanCanvas

/// Edit-mode state for one level: the pure `PlanEditSession` (snapping, shared walls, typed dimensions, undo) plus
/// persistence. Edits are saved when the finger lifts (FR-PLN-51) through `PlanRepository.updateSpaces` /
/// `saveOpening` / `deleteOpening`; "Cancel" writes the geometry from before edit mode back.
@MainActor
@Observable
final class PlanEditorModel {
    enum Tool: Hashable {
        case select
        case split(vertical: Bool)
        case merge
        case door
        case window
    }

    var session: PlanEditSession
    private(set) var renderModel: LevelRenderModel
    var tool: Tool = .select
    /// Banner text (overlap, invalid split, save errors).
    var message: String?
    /// Bumped whenever the snap target changes (selection haptic).
    private(set) var hapticTick = 0

    let initial: LevelGeometry
    let unitSystem: UnitSystem
    @ObservationIgnored private var persistedSpaces: [Space]
    @ObservationIgnored private var persistedOpenings: [Opening]
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var lastSnap: SnapResult.Kind = .none

    init(geometry: LevelGeometry, unitSystem: UnitSystem, selection: UUID? = nil) {
        initial = geometry
        self.unitSystem = unitSystem
        var s = PlanEditSession(geometry: geometry)
        s.selection = selection
        session = s
        persistedSpaces = s.spaces
        persistedOpenings = s.openings
        renderModel = RenderModelBuilder.build(geometry: geometry, stats: nil, lens: .plan,
                                               context: LensContext(levelName: geometry.level.name, unitSystem: unitSystem))
    }

    var levelId: UUID { session.level.id }
    var selectedSpace: Space? { session.selection.flatMap { session.space($0) } }
    var hasUnsavedChanges: Bool {
        !session.changes(against: persistedSpaces).isEmpty || {
            let o = session.openingChanges(against: persistedOpenings); return !o.upserts.isEmpty || !o.deletes.isEmpty
        }()
    }

    func refresh() {
        renderModel = RenderModelBuilder.build(geometry: session.geometry, stats: nil, lens: .plan,
                                               context: LensContext(levelName: session.level.name, unitSystem: unitSystem),
                                               version: renderModel.version + 1)
        if !session.canSave {
            message = "Rooms overlap. Move them apart to save."
        } else if message == "Rooms overlap. Move them apart to save." {
            message = nil
        }
    }

    // MARK: Drag plumbing

    func dragChanged(translation: Vec2, scale: Double) {
        let kind = session.updateDrag(translation: translation, scale: scale)
        if kind != lastSnap && kind != .none { hapticTick += 1 }
        lastSnap = kind
        refresh()
    }

    /// Ends the drag and saves if anything changed.
    func dragEnded(env: AppEnvironment) {
        lastSnap = .none
        let changed = session.endDrag()
        refresh()
        if changed { scheduleSave(env: env) }
    }

    /// Runs one structural edit (add/split/merge/delete/…) then saves.
    func apply(env: AppEnvironment, _ edit: (inout PlanEditSession) -> Bool, failure: String? = nil) {
        if edit(&session) {
            refresh()
            scheduleSave(env: env)
        } else if let failure {
            message = failure
        }
    }

    func undo(env: AppEnvironment) { session.undo(); refresh(); scheduleSave(env: env) }
    func redo(env: AppEnvironment) { session.redo(); refresh(); scheduleSave(env: env) }

    // MARK: Persistence

    /// Serializes saves so a quick sequence of edits lands in order.
    func scheduleSave(env: AppEnvironment) {
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            _ = await self.save(env: env)
        }
    }

    /// Writes the working copy. Returns false (and keeps the edits) when the level rules reject it.
    @discardableResult
    func save(env: AppEnvironment) async -> Bool {
        guard session.canSave else {
            message = "Rooms overlap. Move them apart to save."
            return false
        }
        let changes = session.changes(against: persistedSpaces)
        let openingChanges = session.openingChanges(against: persistedOpenings)
        guard !changes.isEmpty || !openingChanges.upserts.isEmpty || !openingChanges.deletes.isEmpty else { return true }
        let spacesSnapshot = session.spaces, openingsSnapshot = session.openings
        do {
            if !changes.isEmpty { try await env.plan.updateSpaces(changes) }
            for o in openingChanges.upserts { try await env.plan.saveOpening(o) }
            for id in openingChanges.deletes { try await env.plan.deleteOpening(id) }
            persistedSpaces = spacesSnapshot
            persistedOpenings = openingsSnapshot
            if message?.hasPrefix("Couldn’t save") == true { message = nil }
            return true
        } catch RepositoryError.overlap {
            message = "Rooms overlap. Move them apart to save."
        } catch {
            message = "Couldn’t save: \(error.localizedDescription)"
        }
        return false
    }

    /// Waits for pending saves, then saves once more.
    func flush(env: AppEnvironment) async -> Bool {
        await saveChain?.value
        return await save(env: env)
    }

    /// "Cancel": restore the geometry from before edit mode.
    func revert(env: AppEnvironment) async {
        await saveChain?.value
        session = PlanEditSession(geometry: initial)
        refresh()
        _ = await save(env: env)
    }

    // MARK: Typed dimensions (FR-PLN-45)

    /// Resizes the selected room and upserts a `wall` measurement (`source: .planEdit`) for the moved edge.
    func setDimension(_ axis: DimensionAxis, text: String, env: AppEnvironment) {
        guard let space = selectedSpace else { return }
        guard let inches = HomeLengthFormatter.parse(text, bareUnit: unitSystem == .metric ? .metric : .imperial), inches > 0 else {
            message = "Enter a length like 12'4\", 148in or 3.76m."
            return
        }
        guard let edit = session.setDimension(space.id, axis: axis, inches: inches) else {
            message = "That size doesn’t fit here."
            return
        }
        refresh()
        let name = space.name
        let propertyId = space.propertyId
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            guard await self.save(env: env) else { return }
            let label = "\(name) \(axis == .width ? "width" : "depth")"
            let existing = (try? await env.measurements.measurements(space: edit.spaceId))?
                .first { $0.kind == .wall && $0.source == .planEdit && $0.label == label }
            if var m = existing {
                m.dims = Dims3(width: edit.lengthIn)
                m.segment = edit.segment
                try? await env.measurements.update(m)
            } else {
                _ = try? await env.measurements.create(MeasurementInput(propertyId: propertyId, label: label, kind: .wall,
                                                                        spaceId: edit.spaceId, segment: edit.segment,
                                                                        dims: Dims3(width: edit.lengthIn), source: .planEdit))
            }
        }
    }

    // MARK: Taps with the active tool

    /// Handles a tap at a model point. Returns true if the tap did something.
    func tap(at m: Vec2, scale: Double, env: AppEnvironment) {
        switch tool {
        case .select:
            session.selection = session.hitTest(m, scale: scale).spaceId
            refresh()
        case .door, .window:
            let kind: Opening.Kind = tool == .door ? .door : .window
            apply(env: env, { $0.addOpening(kind: kind, near: m, scale: scale) != nil },
                  failure: "Tap on a wall to place the \(kind == .door ? "door" : "window").")
        case .split(let vertical):
            guard let sel = session.selection else { message = "Select a room to split first."; return }
            apply(env: env, { $0.split(sel, at: m, vertical: vertical) != nil },
                  failure: "The split line must cross the room once and leave two rooms of at least 4 sq ft.")
            tool = .select
        case .merge:
            guard let sel = session.selection, let other = session.hitTest(m, scale: scale).spaceId, other != sel else {
                message = "Tap a neighbouring room to merge with \(selectedSpace?.name ?? "the selected room")."
                return
            }
            apply(env: env, { $0.merge(sel, other) }, failure: "Only rooms that share a wall and make one simple shape can merge.")
            tool = .select
        }
    }

    var toolHint: String? {
        switch tool {
        case .select: return nil
        case .split(let v): return "Tap where the \(v ? "vertical" : "horizontal") split line goes."
        case .merge: return "Tap the room to merge into \(selectedSpace?.name ?? "the selected room")."
        case .door: return "Tap a wall to place a door (display only)."
        case .window: return "Tap a wall to place a window (display only)."
        }
    }
}
