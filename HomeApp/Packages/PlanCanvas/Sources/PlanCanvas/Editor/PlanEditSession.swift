import Foundation
import PlanKit
import HomeCore

/// What a touch in edit mode grabbed (LLD §6.6 step 6: vertex handles 22 pt, then edges 16 pt, then interior).
public enum EditorHit: Hashable, Sendable {
    case vertex(UUID, Int)
    case edge(UUID, Int)
    case interior(UUID)
    case none

    public var spaceId: UUID? {
        switch self { case .vertex(let s, _), .edge(let s, _), .interior(let s): return s; case .none: return nil }
    }
}

public enum DimensionAxis: String, Hashable, Sendable { case width, depth }

/// A typed-dimension edit: the wall that moved and its new length (the caller upserts a
/// `measurement(kind: .wall, source: .planEdit)` for it, FR-PLN-45).
public struct WallEdit: Hashable, Sendable {
    public var spaceId: UUID
    public var axis: DimensionAxis
    public var segment: Segment
    public var lengthIn: Double
}

/// Undoable state of an edit session.
public struct EditorSnapshot: Hashable, Sendable {
    public var spaces: [Space]
    public var openings: [Opening]
    /// Where the items of deleted/merged rooms go.
    public var deletionTargets: [UUID: Scope]
    public var selection: UUID?
}

/// What the canvas draws on top of the plan in edit mode (layer 7, LLD §7.2).
public struct EditorOverlayState: Hashable, Sendable {
    public var selection: UUID?
    public var handles: [Vec2]
    public var edgeHandles: [Vec2]
    public var guides: [Segment]
    /// Grid line spacing drawn on screen (1 ft, `seven-views.md` §8 "Edit mode").
    public var gridIn: Double
    /// Rooms that currently overlap (drawn with a danger outline; saving is blocked).
    public var invalidSpaceIds: Set<UUID>
    public init(selection: UUID? = nil, handles: [Vec2] = [], edgeHandles: [Vec2] = [], guides: [Segment] = [],
                gridIn: Double = 12, invalidSpaceIds: Set<UUID> = []) {
        self.selection = selection; self.handles = handles; self.edgeHandles = edgeHandles; self.guides = guides
        self.gridIn = gridIn; self.invalidSpaceIds = invalidSpaceIds
    }
}

/// Pure plan-editor model (FR-PLN-40…51, LLD §6.8). Holds a working copy of one level's spaces and openings,
/// applies snapped drags, typed dimensions, add/delete/split/merge and door/window placement, and keeps an undo stack.
/// Persistence is the caller's job: `changes(against:)` → `PlanRepository.updateSpaces`.
public struct PlanEditSession: Sendable {
    public let level: Level
    public private(set) var spaces: [Space]
    public private(set) var openings: [Opening]
    public private(set) var deletionTargets: [UUID: Scope] = [:]
    public var selection: UUID?
    /// "Fine": 1 in grid instead of 6 in (FR-PLN-43).
    public var fineGrid = false
    /// Orthogonal edges stay orthogonal while dragging a corner (default on).
    public var orthogonal = true
    public private(set) var guides: [Segment] = []
    public private(set) var lastSnapKind: SnapResult.Kind = .none

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    public static let undoLimit = 100

    private var dragBase: EditorSnapshot?
    private var dragHit: EditorHit = .none

    public init(geometry: LevelGeometry) {
        level = geometry.level
        spaces = geometry.spaces.filter { $0.deletedAt == nil }
        openings = geometry.openings.filter { $0.deletedAt == nil }
    }

    // MARK: Accessors

    public var gridIn: Double { fineGrid ? 1 : 6 }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isDragging: Bool { dragBase != nil }
    public var minArea: Double { level.isExterior ? Tolerance.minZoneArea : Tolerance.minRoomArea }
    public var geometry: LevelGeometry { LevelGeometry(level: level, spaces: spaces, openings: openings) }

    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }
    private func index(_ id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }

    public var snapshot: EditorSnapshot {
        EditorSnapshot(spaces: spaces, openings: openings, deletionTargets: deletionTargets, selection: selection)
    }

    private mutating func restore(_ s: EditorSnapshot) {
        spaces = s.spaces; openings = s.openings; deletionTargets = s.deletionTargets; selection = s.selection
        if let sel = selection, space(sel) == nil { selection = nil }
    }

    private mutating func pushUndo() {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    public mutating func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(s)
        guides = []
    }

    public mutating func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
        guides = []
    }

    /// Overlay state for the canvas.
    public func overlayState() -> EditorOverlayState {
        var st = EditorOverlayState(selection: selection, guides: guides, invalidSpaceIds: Set(overlappingPairs().flatMap { [$0.0, $0.1] }))
        if let sel = selection, let s = space(sel) {
            st.handles = s.polygon.vertices
            st.edgeHandles = s.polygon.edges.map(\.midpoint)
        }
        return st
    }

    // MARK: Hit testing

    public func hitTest(_ m: Vec2, scale: Double) -> EditorHit {
        let s = max(scale, 1e-6)
        if let sel = selection, let sp = space(sel) {
            if let i = HitTester.vertexIndex(m, in: sp.polygon, radius: 22 / s) { return .vertex(sel, i) }
            if let i = HitTester.edgeIndex(m, in: sp.polygon, radius: 16 / s) { return .edge(sel, i) }
        }
        if let id = HitTester.hit(m, in: spaces.map(\.identifiedPolygon), hitRadius: 22 / s) { return .interior(id) }
        return .none
    }

    // MARK: Drags

    public mutating func beginDrag(_ hit: EditorHit) {
        guard hit != .none else { return }
        dragBase = snapshot
        dragHit = hit
        if let id = hit.spaceId { selection = id }
        guides = []
        lastSnapKind = .none
    }

    /// Updates the in-flight drag. `translation` is the pointer travel in model inches since `beginDrag`.
    /// Returns the snap kind (fire a selection haptic when it changes).
    @discardableResult
    public mutating func updateDrag(translation t: Vec2, scale: Double) -> SnapResult.Kind {
        guard let base = dragBase else { return .none }
        let kind: SnapResult.Kind
        switch dragHit {
        case .vertex(let id, let i): kind = dragVertex(id, i, base: base, translation: t, scale: scale)
        case .edge(let id, let i): kind = dragEdge(id, i, base: base, translation: t, scale: scale)
        case .interior(let id): kind = moveRoom(id, base: base, translation: t, scale: scale)
        case .none: kind = .none
        }
        lastSnapKind = kind
        return kind
    }

    /// Ends the drag: normalizes the touched polygons and records one undo step if anything changed.
    @discardableResult
    public mutating func endDrag() -> Bool {
        guard let base = dragBase else { return false }
        dragBase = nil
        dragHit = .none
        guides = []
        // Normalize (dedupe, collinear drop, 0.01 in rounding); revert any polygon that fails.
        for i in spaces.indices where base.spaces.first(where: { $0.id == spaces[i].id })?.polygon != spaces[i].polygon {
            if let p = try? Polygon(spaces[i].polygon.vertices, minArea: minArea) {
                spaces[i].polygon = p
                spaces[i].isApproximate = false
            } else if let old = base.spaces.first(where: { $0.id == spaces[i].id }) {
                spaces[i].polygon = old.polygon
            }
        }
        let changed = spaces != base.spaces || openings != base.openings
        if changed {
            undoStack.append(base)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        return changed
    }

    public mutating func cancelDrag() {
        if let base = dragBase { restore(base) }
        dragBase = nil; dragHit = .none; guides = []
    }

    private func snapContext(excluding id: UUID, scale: Double, in snap: EditorSnapshot) -> SnapContext {
        let others = snap.spaces.filter { $0.id != id }
        return SnapContext(vertices: others.flatMap(\.polygon.vertices), edges: others.flatMap(\.polygon.edges),
                           gridIn: gridIn, scale: scale, orthogonal: false)
    }

    /// Valid simple polygon of at least the minimum area that keeps its winding (a drag may not flip a room
    /// inside out — that would read as "valid" after normalization).
    private func isValid(_ v: [Vec2], like original: Polygon) -> Bool {
        v.count >= 3 && Validation.validate(v, minArea: minArea) == nil
            && (Area.signedArea(v) >= 0) == (original.signedArea >= 0)
    }

    private mutating func dragVertex(_ id: UUID, _ i: Int, base: EditorSnapshot, translation t: Vec2, scale: Double) -> SnapResult.Kind {
        guard let sp = base.spaces.first(where: { $0.id == id }), let k = index(id) else { return .none }
        var v = sp.polygon.vertices
        guard v.indices.contains(i) else { return .none }
        let snapped = Snapper.snap(candidate: v[i] + t, context: snapContext(excluding: id, scale: scale, in: base))
        let p = snapped.point
        let n = v.count
        if orthogonal {
            for j in [(i - 1 + n) % n, (i + 1) % n] {
                let d = v[i] - v[j]
                if abs(d.y) < 0.5 { v[j].y = p.y } else if abs(d.x) < 0.5 { v[j].x = p.x }
            }
        }
        v[i] = p
        guard isValid(v, like: sp.polygon) else { return lastSnapKind }   // keep the last valid shape
        spaces[k].polygon = Polygon(unchecked: v)
        guides = snapped.guides
        return snapped.kind
    }

    private mutating func dragEdge(_ id: UUID, _ i: Int, base: EditorSnapshot, translation t: Vec2, scale: Double) -> SnapResult.Kind {
        guard let sp = base.spaces.first(where: { $0.id == id }) else { return .none }
        let edges = sp.polygon.edges
        guard edges.indices.contains(i) else { return .none }
        let e = edges[i]
        let nrm = e.direction.perpendicular
        guard nrm != .zero else { return .none }
        let raw = t.dot(nrm)
        let others = base.spaces.filter { $0.id != id }
        // Shared walls move together, except around closets nested in a room: dragging a closet's wall resizes only
        // the closet, and a closet against a room wall that moves slides along with that wall (keeps its depth).
        let nested = SpaceNesting.hosts(base.spaces)
        var coincident = nested[id] != nil ? []
            : WallDerivation.coincidentEdges(of: e, excluding: id, in: others.map(\.identifiedPolygon))
        let slidingClosets = Set(coincident.map(\.spaceId).filter { nested[$0] != nil })
        coincident.removeAll { slidingClosets.contains($0.spaceId) }
        let baseOffset = nrm.dot(e.a)
        let sinTol = sin(Geometry.radians(Tolerance.angleDeg))
        let neighborOffsets = others.flatMap(\.polygon.edges)
            .filter { $0.length > 1e-6 && abs($0.direction.cross(e.direction)) <= sinTol }
            .map { nrm.dot($0.a) }
            .filter { abs($0 - baseOffset) > Tolerance.wallMerge }
        let delta = Snapper.snapEdgeOffset(raw, baseOffset: baseOffset, neighborOffsets: neighborOffsets, gridIn: gridIn, scale: scale)
        let move = nrm * delta

        var updated: [UUID: [Vec2]] = [:]
        var v = sp.polygon.vertices
        let n = v.count
        v[i] += move; v[(i + 1) % n] += move
        updated[id] = v
        for (sid, k) in coincident {
            guard let o = base.spaces.first(where: { $0.id == sid }) else { continue }
            var ov = updated[sid] ?? o.polygon.vertices
            let m = ov.count
            ov[k] += move; ov[(k + 1) % m] += move
            updated[sid] = ov
        }
        guard updated.allSatisfy({ sid, v in
            base.spaces.first(where: { $0.id == sid }).map { isValid(v, like: $0.polygon) } ?? false
        }) else { return lastSnapKind }  // clamp at the last valid δ
        for (sid, verts) in updated { if let k = index(sid) { spaces[k].polygon = Polygon(unchecked: verts) } }
        for c in slidingClosets {
            if let k = index(c), let o = base.spaces.first(where: { $0.id == c }) { spaces[k].polygon = o.polygon.translated(by: move) }
        }
        translateOpenings(of: slidingClosets, base: base, by: move)
        let moved = Segment(a: e.a + move, b: e.b + move)
        guides = delta != 0 && abs(delta - Geometry.snap(raw, to: gridIn)) > 1e-9 ? [moved] : []
        return abs(delta - Geometry.snap(raw, to: gridIn)) > 1e-9 ? .edge : .grid
    }

    private mutating func moveRoom(_ id: UUID, base: EditorSnapshot, translation t: Vec2, scale: Double) -> SnapResult.Kind {
        guard let sp = base.spaces.first(where: { $0.id == id }), let k = index(id) else { return .none }
        let bb = sp.polygon.bounds
        // Snap the corner closest to the pointer direction: use the bbox min corner (stable).
        let candidate = Vec2(x: bb.minX, y: bb.minY) + t
        let snapped = Snapper.snap(candidate: candidate, context: snapContext(excluding: id, scale: scale, in: base))
        let move = t + (snapped.point - candidate)
        spaces[k].polygon = sp.polygon.translated(by: move)
        // Closets inside the room move with it, and so do the openings of the room and those closets.
        let carried = Set(SpaceNesting.hosts(base.spaces).filter { $0.value == id }.map(\.key))
        for c in carried {
            if let ck = index(c), let o = base.spaces.first(where: { $0.id == c }) { spaces[ck].polygon = o.polygon.translated(by: move) }
        }
        translateOpenings(of: carried.union([id]), base: base, by: move)
        guides = snapped.guides
        return snapped.kind
    }

    private mutating func translateOpenings(of ids: Set<UUID>, base: EditorSnapshot, by move: Vec2) {
        for j in openings.indices where openings[j].spaceId.map(ids.contains) == true {
            if let o = base.openings.first(where: { $0.id == openings[j].id }) {
                openings[j].segment = Segment(a: o.segment.a + move, b: o.segment.b + move)
            }
        }
    }

    // MARK: Typed dimensions (FR-PLN-45)

    /// Resizes the room so its width (x extent) or depth (y extent) equals `inches`, moving the right/bottom edge
    /// (left/top stays fixed). Neighbours sharing that wall move with it. Returns nil if the result is invalid.
    @discardableResult
    public mutating func setDimension(_ id: UUID, axis: DimensionAxis, inches: Double) -> WallEdit? {
        guard inches > 0, inches.isFinite, let sp = space(id) else { return nil }
        let bb = sp.polygon.bounds
        let current = axis == .width ? bb.width : bb.height
        let delta = inches - current
        guard abs(delta) > 0.004 else { return nil }
        let edgeCoord = axis == .width ? bb.maxX : bb.maxY
        let tol = 0.5
        func onEdge(_ p: Vec2) -> Bool { abs((axis == .width ? p.x : p.y) - edgeCoord) < tol }
        func shifted(_ p: Vec2) -> Vec2 { axis == .width ? Vec2(x: p.x + delta, y: p.y) : Vec2(x: p.x, y: p.y + delta) }

        var updated: [UUID: [Vec2]] = [id: sp.polygon.vertices.map { onEdge($0) ? shifted($0) : $0 }]
        // Shared walls: other rooms' edges lying on the moved line, overlapping the room's span.
        let edgesOnLine = sp.polygon.edges.filter { onEdge($0.a) && onEdge($0.b) }
        for e in edgesOnLine {
            for (sid, k) in WallDerivation.coincidentEdges(of: e, excluding: id, in: spaces.map(\.identifiedPolygon)) {
                guard let o = space(sid) else { continue }
                var ov = updated[sid] ?? o.polygon.vertices
                let m = ov.count
                for idx in [k, (k + 1) % m] where onEdge(ov[idx]) { ov[idx] = shifted(ov[idx]) }
                updated[sid] = ov
            }
        }
        var newPolys: [UUID: Polygon] = [:]
        for (sid, v) in updated {
            guard let p = try? Polygon(v, minArea: minArea) else { return nil }
            newPolys[sid] = p
        }
        pushUndo()
        for (sid, p) in newPolys { if let k = index(sid) { spaces[k].polygon = p; spaces[k].isApproximate = false } }
        let nb = newPolys[id]!.bounds
        let seg = axis == .width ? Segment(a: Vec2(x: nb.minX, y: nb.maxY), b: Vec2(x: nb.maxX, y: nb.maxY))
                                 : Segment(a: Vec2(x: nb.maxX, y: nb.minY), b: Vec2(x: nb.maxX, y: nb.maxY))
        return WallEdit(spaceId: id, axis: axis, segment: seg, lengthIn: inches)
    }

    // MARK: Structure edits

    /// Adds a rectangular room (default 12 × 12 ft) centered near `center`, snapped to the grid. If it would
    /// overlap an interior room it is placed against the right side of the level instead. FR-PLN-22.
    @discardableResult
    public mutating func addRoom(type: SpaceType = .room, name: String? = nil, center: Vec2, size: Vec2 = Vec2(144, 144)) -> UUID? {
        let w = max(size.x, 24), h = max(size.y, 24)
        let c = Vec2(x: Geometry.snap(center.x, to: 6), y: Geometry.snap(center.y, to: 6))
        var rect = Rect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let interior = spaces.filter { !$0.isExterior }
        if !level.isExterior && interior.contains(where: { Clip.overlaps(Polygon(rect: rect), $0.polygon) }) {
            let b = interior.reduce(Rect.null) { $0.union($1.polygon.bounds) }
            rect = Rect(x: b.maxX, y: b.minY, width: w, height: h)
        }
        guard let poly = try? Polygon(Polygon(rect: rect).vertices, minArea: minArea) else { return nil }
        pushUndo()
        let sp = Space(propertyId: level.propertyId, levelId: level.id, name: name ?? uniqueName(type.displayName == "Room" ? "Room" : type.displayName),
                       spaceType: type, isExterior: level.isExterior || type.isExteriorZone, polygon: poly, source: .manual,
                       sortOrder: (spaces.map(\.sortOrder).max() ?? -1) + 1)
        spaces.append(sp)
        selection = sp.id
        return sp.id
    }

    /// Adds a Stairs room with exactly `polygon` (the stairs of the floor above/below, so they line up), cutting the
    /// stairwell out of any room it overlaps (a room left with several pieces keeps its id and items on the largest;
    /// the others become new rooms with the same type). One undo step. Returns nil, changing nothing, when stairs
    /// already cover that spot or a room can't be cut cleanly.
    @discardableResult
    public mutating func insertStairs(_ polygon: Polygon, name: String? = nil) -> UUID? {
        guard !level.isExterior, let poly = try? Polygon(polygon.vertices, minArea: Tolerance.minZoneArea) else { return nil }
        var working: [Space] = []
        var extras: [Space] = []
        var removed: [UUID] = []
        var nextSort = (spaces.map(\.sortOrder).max() ?? -1) + 1
        for s in spaces {
            guard !s.isExterior, Clip.overlaps(s.polygon, poly) else { working.append(s); continue }
            if s.spaceType == .stairs { return nil }
            guard let pieces = FloorMatching.carve(s.polygon, removing: poly) else { return nil }
            guard let first = pieces.first else { removed.append(s.id); continue }
            var kept = s
            kept.polygon = first
            kept.isApproximate = false
            working.append(kept)
            for p in pieces.dropFirst() {
                extras.append(Space(propertyId: s.propertyId, levelId: s.levelId, name: s.name, spaceType: s.spaceType,
                                    polygon: p, source: .manual, sortOrder: nextSort))
                nextSort += 1
            }
        }
        pushUndo()
        spaces = working
        for var e in extras { e.name = uniqueName(e.name); spaces.append(e) }
        for id in removed { deletionTargets[id] = .level(level.id) }
        let sp = Space(propertyId: level.propertyId, levelId: level.id, name: name ?? uniqueName(FloorMatching.stairsName),
                       spaceType: .stairs, polygon: poly, source: .manual, sortOrder: nextSort)
        spaces.append(sp)
        selection = sp.id
        return sp.id
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(spaces.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Deletes a room; its items go to `reassignItemsTo` (default "This floor", FR-PLN-48).
    public mutating func deleteRoom(_ id: UUID, reassignItemsTo: Scope? = nil) {
        guard let k = index(id) else { return }
        pushUndo()
        spaces.remove(at: k)
        openings.removeAll { $0.spaceId == id }
        deletionTargets[id] = reassignItemsTo ?? .level(level.id)
        if selection == id { selection = nil }
    }

    public mutating func rename(_ id: UUID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty, let k = index(id), spaces[k].name != trimmed else { return }
        pushUndo()
        spaces[k].name = trimmed
    }

    public mutating func setType(_ id: UUID, to type: SpaceType) {
        guard let k = index(id), spaces[k].spaceType != type else { return }
        pushUndo()
        spaces[k].spaceType = type
    }

    /// Splits a room along the orthogonal line through `point` (FR-PLN-46). The original keeps its id and name on
    /// the larger half; the new half is "<name> 2". Returns the new room's id.
    @discardableResult
    public mutating func split(_ id: UUID, at point: Vec2, vertical: Bool) -> UUID? {
        guard let k = index(id) else { return nil }
        let sp = spaces[k]
        let dir = vertical ? Vec2(0, 1) : Vec2(1, 0)
        let snappedPoint = Vec2(x: Geometry.snap(point.x, to: gridIn), y: Geometry.snap(point.y, to: gridIn))
        guard let (a, b) = Clip.split(sp.polygon, linePoint: snappedPoint, direction: dir, minArea: minArea) else { return nil }
        let (keep, give) = a.area >= b.area ? (a, b) : (b, a)
        pushUndo()
        spaces[k].polygon = keep
        spaces[k].isApproximate = false
        let new = Space(propertyId: sp.propertyId, levelId: sp.levelId, name: uniqueName(sp.name), spaceType: sp.spaceType,
                        isExterior: sp.isExterior, polygon: give, source: .manual, sortOrder: (spaces.map(\.sortOrder).max() ?? 0) + 1)
        spaces.append(new)
        return new.id
    }

    /// Merges `b` into `a` if the union is one simple polygon (FR-PLN-47). Items of `b` move to `a`.
    @discardableResult
    public mutating func merge(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b, let ka = index(a), let kb = index(b) else { return false }
        guard let u = Clip.unionAdjacent(spaces[ka].polygon, spaces[kb].polygon, minArea: minArea) else { return false }
        pushUndo()
        spaces[ka].polygon = u
        spaces[ka].isApproximate = false
        for j in openings.indices where openings[j].spaceId == b { openings[j].spaceId = a }
        deletionTargets[b] = .space(a, level: level.id)
        spaces.remove(at: kb)
        selection = a
        return true
    }

    /// Places a display-only door/window on the wall nearest `point` (within 44 pt). FR-PLN-49.
    @discardableResult
    public mutating func addOpening(kind: Opening.Kind, near point: Vec2, widthIn: Double? = nil, scale: Double) -> UUID? {
        let radius = 44 / max(scale, 1e-6)
        var best: (Space, Segment, Double)?
        for s in spaces where !s.isExterior || level.isExterior {
            for e in s.polygon.edges {
                let d = e.distance(to: point)
                if d <= radius, d < (best?.2 ?? .infinity) { best = (s, e, d) }
            }
        }
        guard let (sp, e, _) = best, e.length > 6 else { return nil }
        let width = min(widthIn ?? (kind == .window ? 36 : 32), e.length * 0.9)
        let t = e.projectionParameter(of: point)
        let half = width / 2 / e.length
        let tc = min(max(t, half), 1 - half)
        let seg = Segment(a: e.point(at: tc - half), b: e.point(at: tc + half))
        pushUndo()
        let o = Opening(propertyId: level.propertyId, levelId: level.id, spaceId: sp.id, kind: kind, segment: seg,
                        heightIn: kind == .door ? 80 : 48, sillIn: kind == .window ? 36 : nil,
                        swing: kind == .door ? .leftIn : nil, source: .manual)
        openings.append(o)
        return o.id
    }

    /// Default reach-in closet: 5 ft along the wall × 2 ft deep.
    public static let closetSize = Vec2(60, 24)

    /// Places a closet the way a door is placed (founder feedback): tap a room's wall and a closet is created inside
    /// that room, flush against the wall and centered on the tap (snapped to the grid along the wall), with a sliding
    /// door on its open side. Width is clamped to the wall, depth to what fits in the room. The closet is its own
    /// space (`.closet`, "Closet", "Closet 2", …) nested in the room, so it is not an overlap (`SpaceNesting`).
    /// Returns the new closet's id (selected), or nil, changing nothing, when no room wall is within 44 pt or no
    /// closet of at least 4 sq ft (2 ft wide, 1 ft deep) fits there.
    @discardableResult
    public mutating func addCloset(near point: Vec2, scale: Double, size: Vec2 = PlanEditSession.closetSize) -> UUID? {
        guard !level.isExterior else { return nil }
        let radius = 44 / max(scale, 1e-6)
        let nested = SpaceNesting.hosts(spaces)
        // Wall nearest the tap among rooms that can hold a closet; a room containing the tap wins a shared wall.
        var best: (room: Space, edge: Segment, inside: Bool, d: Double)?
        for s in spaces where !s.isExterior && SpaceNesting.canHost(s.spaceType) && nested[s.id] == nil {
            let inside = s.polygon.contains(point)
            for e in s.polygon.edges where e.length > 1e-6 {
                let d = e.distance(to: point)
                guard d <= radius else { continue }
                if let b = best, (b.inside ? 0 : 1, b.d) <= (inside ? 0 : 1, d) { continue }
                best = (s, e, inside, d)
            }
        }
        guard let (room, e, _, _) = best, e.length >= 24 else { return nil }

        // Inward normal: the side of the wall the room is on.
        let u = e.direction
        var n = u.perpendicular
        if !room.polygon.contains(e.midpoint + n * 1, tolerance: 0) { n = -n }

        // Along the wall: clamp the width to the wall, center on the tap (grid-snapped on axis-aligned walls).
        let width = min(max(size.x, 24), e.length)
        var center = e.point(at: e.projectionParameter(of: point))
        if abs(u.x) < 1e-9 || abs(u.y) < 1e-9 {
            center = Vec2(x: abs(u.y) < 1e-9 ? Geometry.snap(center.x, to: gridIn) : center.x,
                          y: abs(u.x) < 1e-9 ? Geometry.snap(center.y, to: gridIn) : center.y)
        }
        let half = width / 2 / e.length
        let tc = min(max(e.projectionParameter(of: center), half), 1 - half)
        let a = e.point(at: tc - half), b = e.point(at: tc + half)

        // Depth: the default, or less where the room (or something already in it) is shallower (≥ 1 ft and 4 sq ft).
        let others = spaces.filter { !$0.isExterior && $0.id != room.id }
        var depth = max(size.y, 12)
        var closet: Polygon?
        while depth >= 12 {
            if let p = try? Polygon([a, b, b + n * depth, a + n * depth], minArea: minArea),
               Clip.isContained(p, in: room.polygon),
               !others.contains(where: { Clip.overlaps($0.polygon, p) }) {
                closet = p
                break
            }
            depth -= 6
        }
        guard let poly = closet else { return nil }

        pushUndo()
        let sp = Space(propertyId: level.propertyId, levelId: level.id, name: uniqueName(SpaceType.closet.displayName),
                       spaceType: .closet, polygon: poly, source: .manual,
                       sortOrder: (spaces.map(\.sortOrder).max() ?? -1) + 1)
        spaces.append(sp)
        // Sliding door across the open side (6 in returns each side; a narrow closet gets one 24 in+ opening).
        let front = Segment(a: a + n * depth, b: b + n * depth)
        let doorWidth = width >= 48 ? width - 12 : min(width, max(24, width - 6))
        let dt = doorWidth / 2 / front.length
        let door = Segment(a: front.point(at: 0.5 - dt), b: front.point(at: 0.5 + dt))
        openings.append(Opening(propertyId: level.propertyId, levelId: level.id, spaceId: sp.id, kind: .door, segment: door,
                                heightIn: 80, swing: .sliding, source: .manual))
        selection = sp.id
        return sp.id
    }

    public mutating func deleteOpening(_ id: UUID) {
        guard let k = openings.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        openings.remove(at: k)
    }

    // MARK: Validation / diff

    /// Interior pairs overlapping by more than 1 sq in (the repository would reject the save). A closet inside its
    /// room is not an overlap (`SpaceNesting`).
    public func overlappingPairs() -> [(UUID, UUID)] {
        SpaceNesting.overlappingPairs(spaces)
    }

    public var canSave: Bool { overlappingPairs().isEmpty }

    /// Space changes that turn `baseline` into the current working copy.
    public func changes(against baseline: [Space]) -> [SpaceChange] {
        let old = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [SpaceChange] = []
        for s in spaces {
            if let o = old[s.id] {
                if o != s { out.append(.update(s)) }
            } else {
                out.append(.insert(s))
            }
        }
        let current = Set(spaces.map(\.id))
        for o in baseline where !current.contains(o.id) {
            out.append(.delete(o.id, reassignItemsTo: deletionTargets[o.id] ?? .level(level.id)))
        }
        return out
    }

    /// Openings to save and ids to delete relative to `baseline`.
    public func openingChanges(against baseline: [Opening]) -> (upserts: [Opening], deletes: [UUID]) {
        let old = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ups = openings.filter { old[$0.id] != $0 }
        let current = Set(openings.map(\.id))
        return (ups, baseline.map(\.id).filter { !current.contains($0) })
    }
}
