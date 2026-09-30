import Foundation
import PlanKit
import HomeCore

public enum RoomPlanImportError: Error, Hashable, Sendable {
    /// "We couldn't find any rooms. Try again with more light, or use Build with blocks."
    case noRooms
    /// The data is neither Apple's `CapturedStructure` JSON (iOS) nor the plain `RPStructure` format.
    case unreadable(String)
}

/// Pure `RPStructure` → `PlanDraft` conversion (LLD §6.12 steps 1–11). Platform-free and deterministic.
public struct RoomPlanConverter: Sendable {
    public static let inchesPerMeter = 39.3701
    /// Step 3: walls within this of a right angle snap to it (after the dominant rotation).
    public var wallSnapDeg: Double = 3
    /// Step 4b: wall endpoints closer than this count as adjacent.
    public var adjacencyIn: Double = 12
    /// Step 5: half a typical interior wall.
    public var wallOffsetIn: Double = 2.25
    /// Step 8: openings attach to the nearest room edge within this distance.
    public var openingAttachIn: Double = 8

    public init() {}

    // MARK: Working types

    struct WorkRoom {
        var source: RPRoom
        var tempId: UUID
        var polygon: Polygon
        var hullFallback = false
        var name = ""
        var type: SpaceType = .room
    }

    // MARK: Convert

    public func convert(_ structure: RPStructure, storyMap: [Int: Level.Kind]) throws -> PlanDraft {
        let rooms = structure.rooms
        guard !rooms.isEmpty else { throw RoomPlanImportError.noRooms }
        var ids = DeterministicIDs(seed: DeterministicIDs.seed("roomplan|\(rooms.count)|\(rooms.map { $0.identifier?.uuidString ?? "" }.joined())|\(rooms.first?.walls.first?.transform.m.description ?? "")"))

        // Step 3: dominant rotation over every wall of every story (stories share one world frame).
        let rawWalls = rooms.flatMap { $0.walls.map(Self.segment(of:)) }
        var alpha = Orientation.dominantAngle(of: rawWalls)
        if alpha > .pi / 4 { alpha -= .pi / 2 }
        let rot = Transform2D.rotation(-alpha)
        let map2D: (RPVec3) -> Vec2 = { rot.apply(Self.project($0)) }

        // Step 1: group by story (ascending).
        let stories = Array(Set(rooms.map(\.story))).sorted()
        let levelInfo = Self.levelInfo(stories: stories, storyMap: storyMap)
        let allSections = structure.sections + rooms.flatMap(\.sections)

        var levels: [LevelDraft] = []
        for story in stories {
            let storyRooms = rooms.filter { $0.story == story }
            var work: [WorkRoom] = []
            var warnings: [DraftWarning] = []

            // Step 4–5: room polygons, offset to the wall centerline.
            for r in storyRooms {
                let tempId = ids.next()
                let walls = r.walls.map { snapSegment(rot.apply(Self.segment(of: $0))) }
                var poly: Polygon?
                var hull = false
                if let floor = r.floors.first(where: { $0.polygonCorners.count >= 3 }) {
                    let pts = floor.polygonCorners.map { map2D(floor.transform.apply($0)) }
                    poly = try? Polygon(straighten(pts))
                }
                if poly == nil, let loop = wallLoop(walls) { poly = try? Polygon(straighten(loop)) }
                if poly == nil {
                    let hullPts = Clip.convexHull(walls.flatMap { [$0.a, $0.b] } + r.floors.map { map2D($0.transform.position) })
                    poly = try? Polygon(hullPts)
                    hull = true
                }
                guard let base = poly else { continue }
                let offset = Clip.offset(base, by: wallOffsetIn, miterLimit: 2, minArea: Tolerance.minRoomArea) ?? base
                work.append(WorkRoom(source: r, tempId: tempId, polygon: offset, hullFallback: hull))
            }
            guard !work.isEmpty else { continue }

            // Step 6: weld, then overlaps.
            let welded = Weld.weldDetailed(polygons: work.map(\.polygon), tolerance: Tolerance.weld, minArea: Tolerance.minRoomArea)
            for (k, p) in welded.polygons.enumerated() { work[k].polygon = p }
            for k in welded.failedIndices { warnings.append(.weldFailed(spaceId: work[k].tempId)) }
            for k in work.indices where work[k].hullFallback { warnings.append(.hullFallback(spaceId: work[k].tempId)) }
            warnings += resolveOverlaps(&work)

            // Step 7: names.
            let storySections = allSections.filter { $0.story == story }
            nameRooms(&work, sections: storySections.map { ($0.label, map2D($0.center)) })

            // Step 8: openings (+ door measurements).
            var openings: [OpeningDraft] = []
            var measurements: [MeasurementDraft] = []
            for w in work {
                let floorY = Self.floorHeight(of: w.source)
                let groups: [(Opening.Kind, [RPSurface])] = [(.door, w.source.doors), (.window, w.source.windows), (.opening, w.source.openings)]
                for (kind, surfaces) in groups {
                    for s in surfaces {
                        var seg = snapSegment(rot.apply(Self.segment(of: s)))
                        // Duplicate (the same door reported by both rooms)?
                        if openings.contains(where: { $0.kind == kind && $0.segment.midpoint.distance(to: seg.midpoint) < 6 }) { continue }
                        let (roomIndex, edge, touching) = nearestEdge(to: seg.midpoint, in: work)
                        if let edge { seg = Segment(edge.closestPointOnLine(seg.a), edge.closestPointOnLine(seg.b)) }
                        let heightIn = s.dimensions.y * Self.inchesPerMeter
                        let bottom = s.transform.position.y - s.dimensions.y / 2
                        let sill = kind == .window ? max(0, (bottom - floorY) * Self.inchesPerMeter) : nil
                        let od = OpeningDraft(tempId: ids.next(), spaceTempId: roomIndex.map { work[$0].tempId } ?? w.tempId, kind: kind,
                                              segment: seg, heightIn: heightIn, sillIn: sill, swing: nil,
                                              isExteriorDoor: kind == .door && touching == 1)
                        openings.append(od)
                        if kind == .door {
                            let roomName = roomIndex.map { work[$0].name } ?? w.name
                            measurements.append(MeasurementDraft(tempId: ids.next(), label: "\(roomName) door", kind: .door,
                                                                 spaceTempId: od.spaceTempId, openingTempId: od.tempId,
                                                                 dims: Dims3(width: seg.length.rounded(toPlaces: 2), height: heightIn.rounded(toPlaces: 2)),
                                                                 segment: seg, source: .roomplan))
                        }
                    }
                }
            }

            // Step 9: suggested Things (user must accept each).
            var things: [SuggestedThing] = []
            for w in work {
                for o in w.source.objects {
                    guard let m = RoomPlanLabelMap.thing(forObject: o.category) else { continue }
                    let pin = map2D(o.transform.position)
                    let owner = work.first { $0.polygon.contains(pin) }?.tempId ?? w.tempId
                    let d = o.dimensions * Self.inchesPerMeter
                    things.append(SuggestedThing(tempId: ids.next(), spaceTempId: owner, category: m.category, templateKey: m.templateKey,
                                                 name: m.name, dims: Dims3(width: d.x.rounded(toPlaces: 1), depth: d.z.rounded(toPlaces: 1), height: d.y.rounded(toPlaces: 1)),
                                                 pin: pin.rounded(to: 0.01)))
                }
            }

            let info = levelInfo[story]!
            let spaces = work.map { SpaceDraft(tempId: $0.tempId, name: $0.name, spaceType: $0.type, polygon: $0.polygon, source: .roomplan) }
            levels.append(LevelDraft(tempId: ids.next(), name: info.name, kind: info.kind, sortOrder: info.sortOrder, spaces: spaces,
                                     openings: openings, suggestedThings: things, measurements: measurements, storyIndex: story, warnings: warnings))
        }
        guard !levels.isEmpty else { throw RoomPlanImportError.noRooms }
        return PlanDraft(levels: levels, source: .roomplan)
    }

    // MARK: Projection

    /// World meters (x, z) → inches (x right, y = z down). Looking down −y, no mirroring (§6.12 step 2).
    static func project(_ p: RPVec3) -> Vec2 { Vec2(p.x * inchesPerMeter, p.z * inchesPerMeter) }

    /// Surface centerline: center ± right·(width / 2), projected.
    static func segment(of s: RPSurface) -> Segment {
        let c = s.transform.position
        var right = s.transform.column0
        right.y = 0
        right = right.normalized
        let half = right * (s.dimensions.x / 2)
        return Segment(project(c + half * -1), project(c + half))
    }

    static func floorHeight(of r: RPRoom) -> Double {
        if let f = r.floors.first { return f.transform.position.y }
        let bottoms = r.walls.map { $0.transform.position.y - $0.dimensions.y / 2 }
        return bottoms.min() ?? 0
    }

    // MARK: Snapping

    /// Rotates a segment about its midpoint onto the nearest multiple of 90° when within `wallSnapDeg`.
    func snapSegment(_ s: Segment) -> Segment {
        let snapped = Orientation.snapToRightAngle(s.angle, toleranceDeg: wallSnapDeg)
        guard snapped != s.angle else { return s }
        let half = s.length / 2, m = s.midpoint
        let d = Vec2(cos(snapped), sin(snapped)) * half
        return Segment(m - d, m + d)
    }

    /// Makes near-axis polygon edges exactly axis-aligned (both endpoints share the average coordinate).
    func straighten(_ pts: [Vec2]) -> [Vec2] {
        var v = pts
        let n = v.count
        guard n >= 3 else { return v }
        let tol = Geometry.radians(wallSnapDeg)
        for i in 0..<n {
            let j = (i + 1) % n
            let d = v[j] - v[i]
            guard d.length > 1e-6 else { continue }
            let a = abs(atan2(d.y, d.x))
            if a <= tol || abs(a - .pi) <= tol {           // horizontal
                let y = (v[i].y + v[j].y) / 2; v[i].y = y; v[j].y = y
            } else if abs(a - .pi / 2) <= tol {            // vertical
                let x = (v[i].x + v[j].x) / 2; v[i].x = x; v[j].x = x
            }
        }
        return v
    }

    // MARK: Wall loop (step 4b)

    /// Chains walls end-to-end (endpoints within `adjacencyIn`), trimming/extending each pair to the intersection of
    /// their lines, until the loop closes. Returns the corner ring, or nil.
    func wallLoop(_ walls: [Segment]) -> [Vec2]? {
        let segs = walls.filter { $0.length > 1 }
        guard segs.count >= 3 else { return nil }
        var used = Set([0])
        var chain: [Segment] = [segs[0]]
        var corners: [Vec2] = []
        while true {
            let cur = chain.last!
            // Closed?
            if chain.count >= 3, cur.b.distance(to: chain[0].a) <= adjacencyIn {
                corners.append(Self.corner(cur, chain[0]))
                break
            }
            var best: (Int, Segment, Double)?
            for (k, s) in segs.enumerated() where !used.contains(k) {
                for cand in [s, s.reversed] {
                    let d = cand.a.distance(to: cur.b)
                    if d <= adjacencyIn, d < (best?.2 ?? .infinity) { best = (k, cand, d) }
                }
            }
            guard let (k, next, _) = best else { return nil }
            corners.append(Self.corner(cur, next))
            used.insert(k)
            chain.append(next)
            if chain.count > segs.count + 1 { return nil }
        }
        // corners[i] is the corner between chain[i] and chain[i+1]; rotate so the ring starts at chain[0].a.
        return corners.count >= 3 ? [corners.last!] + corners.dropLast() : nil
    }

    /// Intersection of the infinite lines through `a` (ending) and `b` (starting); midpoint when parallel.
    static func corner(_ a: Segment, _ b: Segment) -> Vec2 {
        let r = a.vector, s = b.vector
        let denom = r.cross(s)
        guard abs(denom) > 1e-9 * max(1, r.length * s.length) else { return a.b.lerp(to: b.a, 0.5) }
        let t = (b.a - a.a).cross(s) / denom
        return a.point(at: t)
    }

    // MARK: Overlaps (step 6)

    /// Overlaps ≥ 1 sq ft are flagged; smaller ones (> 1 sq in) are trimmed by shrinking the smaller room.
    func resolveOverlaps(_ work: inout [WorkRoom]) -> [DraftWarning] {
        var warnings: [DraftWarning] = []
        for i in work.indices {
            for j in work.indices where j > i {
                var area = Clip.intersectionArea(work[i].polygon, work[j].polygon)
                guard area > Tolerance.maxInteriorOverlap else { continue }
                if area >= 144 { warnings.append(.overlap(spaceIds: [work[i].tempId, work[j].tempId])); continue }
                let small = work[i].polygon.area <= work[j].polygon.area ? i : j
                let big = small == i ? j : i
                for inset in [0.5, 1.0, 1.5, 2.25, 3.0] {
                    guard let shrunk = Clip.offset(work[small].polygon, by: -inset, miterLimit: 2, minArea: Tolerance.minRoomArea) else { break }
                    area = Clip.intersectionArea(shrunk, work[big].polygon)
                    if area <= Tolerance.maxInteriorOverlap { work[small].polygon = shrunk; break }
                }
                if area > Tolerance.maxInteriorOverlap { warnings.append(.overlap(spaceIds: [work[i].tempId, work[j].tempId])) }
            }
        }
        return warnings
    }

    // MARK: Names (step 7)

    func nameRooms(_ work: inout [WorkRoom], sections: [(String, Vec2)]) {
        var names: [String] = []
        var unnamed = 0
        for k in work.indices {
            // a. Sections whose center falls inside: most frequent label wins (ties → first seen).
            let inside = sections.filter { work[k].polygon.contains($0.1) }.compactMap { RoomPlanLabelMap.room(forSection: $0.0) }
            var chosen: (name: String, type: SpaceType)?
            if !inside.isEmpty {
                var counts: [String: Int] = [:]
                for s in inside { counts[s.name, default: 0] += 1 }
                let top = counts.values.max()!
                chosen = inside.first { counts[$0.name] == top }
            }
            // b. Objects.
            if chosen == nil { chosen = RoomPlanLabelMap.room(forObjects: work[k].source.objects.map(\.category)) }
            if let c = chosen {
                names.append(c.name); work[k].type = c.type
            } else {
                unnamed += 1
                names.append("Room \(unnamed)"); work[k].type = .room
            }
        }
        // c. Number duplicates ("Bedroom", "Bedroom 2").
        for (k, n) in CaptureNaming.numberDuplicates(names).enumerated() { work[k].name = n }
    }

    // MARK: Openings (step 8)

    /// Nearest room edge within `openingAttachIn` of `p`: (room index, edge, number of rooms with an edge in range).
    func nearestEdge(to p: Vec2, in work: [WorkRoom]) -> (Int?, Segment?, Int) {
        var best: (Int, Segment, Double)?
        var touching = 0
        for (k, w) in work.enumerated() {
            var roomHit = false
            for e in w.polygon.edges {
                let d = e.distance(to: p)
                guard d <= openingAttachIn else { continue }
                roomHit = true
                if d < (best?.2 ?? .infinity) { best = (k, e, d) }
            }
            if roomHit { touching += 1 }
        }
        return (best?.0, best?.1, touching)
    }

    // MARK: Levels (step 1)

    struct LevelInfo { var name: String; var kind: Level.Kind; var sortOrder: Int }

    /// Story → level. Default: every story is a floor, lowest = ground. Basements count down from −1, floors up from 0,
    /// attics above the highest floor.
    static func levelInfo(stories: [Int], storyMap: [Int: Level.Kind]) -> [Int: LevelInfo] {
        var out: [Int: LevelInfo] = [:]
        let kinds = stories.map { s -> Level.Kind in
            let k = storyMap[s] ?? .floor
            return (k == .exterior || k == .unknown) ? .floor : k
        }
        let basements = zip(stories, kinds).filter { $0.1 == .basement }.map(\.0)
        for (i, s) in basements.enumerated() {
            let order = -(basements.count - i)
            out[s] = LevelInfo(name: basements.count > 1 ? "Basement \(i + 1)" : "Basement", kind: .basement, sortOrder: order)
        }
        let floors = zip(stories, kinds).filter { $0.1 == .floor }.map(\.0)
        for (i, s) in floors.enumerated() { out[s] = LevelInfo(name: CaptureNaming.floorName(index: i), kind: .floor, sortOrder: i) }
        let attics = zip(stories, kinds).filter { $0.1 == .attic }.map(\.0)
        for (i, s) in attics.enumerated() {
            out[s] = LevelInfo(name: attics.count > 1 ? "Attic \(i + 1)" : "Attic", kind: .attic, sortOrder: floors.count + i)
        }
        return out
    }
}

extension Segment {
    /// Projection of `p` onto the infinite line through the segment.
    func closestPointOnLine(_ p: Vec2) -> Vec2 { point(at: projectionParameter(of: p)) }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10, Double(n))
        return (self * f).rounded() / f
    }
}
