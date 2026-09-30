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
    /// Neutral banner text (e.g. "Added matching stairs on 2nd Floor.").
    var notice: String?
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

    // MARK: Stairs across floors (spec 01 edge case "a Stairs room on each floor")

    /// Another interior floor of the property and its rooms, for lining stairs up.
    struct OtherFloor: Identifiable, Hashable {
        var level: Level
        var spaces: [Space]
        var id: UUID { level.id }
        var stairs: [Space] { spaces.filter { $0.spaceType == .stairs && $0.deletedAt == nil } }
    }

    /// A pending "Add matching stairs on <floor>" that would reshape rooms there (asks first).
    struct StairsRequest: Identifiable {
        var id = UUID()
        var polygon: PlanKit.Polygon
        var floor: OtherFloor
        var blockers: [String]
    }

    private(set) var otherFloors: [OtherFloor] = []
    var stairsRequest: StairsRequest?

    /// Loads the property's other interior floors (called when the editor opens and after it switches floors).
    func loadOtherFloors(env: AppEnvironment) async {
        guard !session.level.isExterior else { otherFloors = []; return }
        let levels = ((try? await env.plan.levels(property: session.level.propertyId)) ?? [])
            .filter { $0.deletedAt == nil && !$0.isExterior && $0.id != levelId }
            .sorted { $0.sortOrder < $1.sortOrder }
        var out: [OtherFloor] = []
        for l in levels {
            let spaces = ((try? await env.plan.geometry(level: l.id))?.spaces ?? []).filter { $0.deletedAt == nil }
            out.append(OtherFloor(level: l, spaces: spaces))
        }
        otherFloors = out
    }

    /// Stairs on another floor that this floor lacks.
    struct StairsMatch: Identifiable {
        var floor: OtherFloor
        var polygons: [PlanKit.Polygon]
        var id: UUID { floor.id }
    }

    /// Floors whose stairs are missing here ("Stairs matching <floor>" in the Room menu), with the missing shapes.
    var stairsToMatchHere: [StairsMatch] {
        guard !session.level.isExterior else { return [] }
        let here = session.spaces.map(FloorShape.init)
        return otherFloors.compactMap { f in
            let missing = FloorMatching.missingStairs(reference: f.spaces.map(FloorShape.init), target: here)
            return missing.isEmpty ? nil : StairsMatch(floor: f, polygons: missing)
        }
    }

    /// Other floors that don't have the selected stairs yet ("Add matching stairs on <floor>").
    func floorsMissing(_ stairs: Space) -> [OtherFloor] {
        guard stairs.spaceType == .stairs else { return [] }
        let ref = [FloorShape(stairs)]
        return otherFloors.filter { !FloorMatching.missingStairs(reference: ref, target: $0.spaces.map(FloorShape.init)).isEmpty }
    }

    /// Adds the other floor's stairs to this floor at the same position (undoable; carves overlapped rooms).
    func addStairsHere(_ polygons: [PlanKit.Polygon], from floor: OtherFloor, env: AppEnvironment) {
        tool = .select
        apply(env: env, { s in
            var ok = true
            for p in polygons where s.insertStairs(p) == nil { ok = false }
            return ok
        }, failure: "Couldn’t fit the stairs from \(floor.level.name) here. Clear that spot and try again.")
    }

    /// Step 1 of "Add matching stairs on <floor>": asks first when rooms there must be reshaped.
    func requestMatchingStairs(_ stairs: Space, on floor: OtherFloor, env: AppEnvironment) {
        let blockers = FloorMatching.blockers(for: stairs.polygon, on: floor.spaces)
        if blockers.isEmpty {
            Task { await addMatchingStairs(stairs.polygon, on: floor, env: env) }
        } else {
            stairsRequest = StairsRequest(polygon: stairs.polygon, floor: floor, blockers: blockers.map(\.name))
        }
    }

    /// Writes the stairs onto the other floor (its own transaction; not part of this floor's undo).
    func addMatchingStairs(_ polygon: PlanKit.Polygon, on floor: OtherFloor, env: AppEnvironment) async {
        stairsRequest = nil
        guard let g = try? await env.plan.geometry(level: floor.level.id) else {
            message = "Couldn’t open \(floor.level.name)."; return
        }
        var other = PlanEditSession(geometry: g)
        guard other.insertStairs(polygon, name: FloorMatching.stairsName) != nil else {
            message = "Couldn’t fit the stairs on \(floor.level.name). Clear that spot there first."; return
        }
        do {
            try await env.plan.updateSpaces(other.changes(against: g.spaces.filter { $0.deletedAt == nil }))
            notice = "Added matching stairs on \(floor.level.name)."
            await loadOtherFloors(env: env)
        } catch {
            message = "Couldn’t save: \(error.localizedDescription)"
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
