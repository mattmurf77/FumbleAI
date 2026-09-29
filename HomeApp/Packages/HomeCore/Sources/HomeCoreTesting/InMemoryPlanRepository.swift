import Foundation
import HomeCore
import PlanKit

/// In-memory `PlanRepository` + `PlanCommitting`. Validates the level overlap rule; does not weld
/// (HomeStore welds on commit).
public struct InMemoryPlanRepository: PlanRepository, PlanCommitting {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func properties() async throws -> [Property] { store.read { $0.liveProperties } }
    public func currentProperty() async throws -> Property? { store.read { $0.liveProperties.first } }
    public func observeCurrentProperty() -> AsyncStream<Property?> { store.observe { $0.liveProperties.first } }

    public func saveProperty(_ property: Property) async throws {
        var p = property
        p.updatedAt = store.now
        store.write(events: [.recordsChanged([RecordRef(.property, p.id)])]) { $0.properties[p.id] = p }
    }

    public func setDefaultLevel(_ levelId: UUID, property: UUID) async throws {
        try store.write(events: [.recordsChanged([RecordRef(.property, property)])]) { s in
            guard var p = s.properties[property] else { throw notFound(.property, property) }
            p.defaultLevelId = levelId; p.updatedAt = store.now
            s.properties[property] = p
        }
    }

    public func levels(property: UUID) async throws -> [Level] { store.read { $0.liveLevels.filter { $0.propertyId == property } } }
    public func observeLevels(property: UUID) -> AsyncStream<[Level]> { store.observe { $0.liveLevels.filter { $0.propertyId == property } } }

    public func saveLevel(_ level: Level) async throws {
        var l = level
        l.updatedAt = store.now
        try store.write(events: [.recordsChanged([RecordRef(.level, l.id)]), .geometryChanged(levelId: l.id)]) { s in
            if l.kind == .exterior, s.liveLevels.contains(where: { $0.propertyId == l.propertyId && $0.kind == .exterior && $0.id != l.id }) {
                throw RepositoryError.invalid("A property has at most one exterior level")
            }
            s.levels[l.id] = l
        }
    }

    public func deleteLevel(_ id: UUID, reassignItemsTo: Scope) async throws {
        let now = store.now
        try store.write(events: [.recordsChanged([RecordRef(.level, id)]), .geometryChanged(levelId: id)]) { s in
            guard var l = s.levels[id] else { throw notFound(.level, id) }
            l.deletedAt = now; l.updatedAt = now
            s.levels[id] = l
            for sp in s.liveSpaces where sp.levelId == id {
                Self.softDeleteSpace(sp.id, in: &s, reassign: reassignItemsTo, now: now)
            }
            Self.reassign(level: id, to: reassignItemsTo, in: &s, now: now)
        }
    }

    public func geometry(level: UUID) async throws -> LevelGeometry {
        try store.read { s in
            guard let l = s.levels[level] else { throw notFound(.level, level) }
            return Self.geometry(l, s)
        }
    }

    public func observeGeometry(level: UUID) -> AsyncStream<LevelGeometry> {
        let placeholder = Level(id: level, propertyId: level, name: "", createdAt: .distantPast, updatedAt: .distantPast)
        return store.observe { s in Self.geometry(s.levels[level] ?? placeholder, s) }
    }

    static func geometry(_ l: Level, _ s: InMemorySnapshot) -> LevelGeometry {
        LevelGeometry(level: l, spaces: s.liveSpaces.filter { $0.levelId == l.id }, openings: s.liveOpenings.filter { $0.levelId == l.id })
    }

    public func space(_ id: UUID) async throws -> Space? { store.read { $0.spaces[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func spaces(property: UUID) async throws -> [Space] { store.read { $0.liveSpaces.filter { $0.propertyId == property } } }

    public func updateSpaces(_ changes: [SpaceChange]) async throws {
        let now = store.now
        var levels = Set<UUID>()
        try store.write(events: []) { s in
            var work = s
            for change in changes {
                switch change {
                case .insert(var sp), .update(var sp):
                    if case .update = change, let old = work.spaces[sp.id], old.polygon != sp.polygon { sp.isApproximate = false }
                    sp.updatedAt = now
                    if work.spaces[sp.id] == nil { sp.createdAt = now }
                    work.spaces[sp.id] = sp
                    levels.insert(sp.levelId)
                case .delete(let id, let reassign):
                    if let lv = work.spaces[id]?.levelId { levels.insert(lv) }
                    Self.softDeleteSpace(id, in: &work, reassign: reassign, now: now)
                }
            }
            // Level rule: interior spaces may not overlap by more than 1 sq in.
            for level in levels {
                let interior = work.liveSpaces.filter { $0.levelId == level && !$0.isExterior }
                for i in interior.indices { for j in interior.indices where j > i {
                    if Clip.overlaps(interior[i].polygon, interior[j].polygon) { throw RepositoryError.overlap([interior[i].id, interior[j].id]) }
                } }
            }
            s = work
        }
        for l in levels { store.bus.publish(.geometryChanged(levelId: l)) }
    }

    public func renameSpace(_ id: UUID, to name: String) async throws {
        try store.write(events: [.recordsChanged([RecordRef(.space, id)])]) { s in
            guard var sp = s.spaces[id] else { throw notFound(.space, id) }
            sp.name = name; sp.updatedAt = store.now
            s.spaces[id] = sp
        }
    }

    public func deleteSpace(_ id: UUID, reassignItemsTo: Scope) async throws {
        try await updateSpaces([.delete(id, reassignItemsTo: reassignItemsTo)])
    }

    public func saveOpening(_ opening: Opening) async throws {
        var o = opening
        o.updatedAt = store.now
        store.write(events: [.geometryChanged(levelId: o.levelId)]) { $0.openings[o.id] = o }
    }

    public func deleteOpening(_ id: UUID) async throws {
        let level = store.read { $0.openings[id]?.levelId }
        try store.write(events: level.map { [.geometryChanged(levelId: $0)] } ?? []) { s in
            guard var o = s.openings[id] else { throw notFound(.opening, id) }
            o.deletedAt = store.now; o.updatedAt = store.now
            s.openings[id] = o
        }
    }

    // MARK: PlanCommitting

    public func commit(_ draft: PlanDraft, into property: UUID, acceptedSuggestions: Set<UUID>) async throws -> [UUID] {
        let now = store.now
        var levelIds: [UUID] = []
        try store.write(events: []) { s in
            guard s.properties[property] != nil else { throw notFound(.property, property) }
            for ld in draft.levels {
                let levelId = UUID()
                levelIds.append(levelId)
                var underlayId: UUID?
                if let u = ld.underlay {
                    let a = Attachment(propertyId: property, ownerType: .level, ownerId: levelId, kind: .underlay,
                                       fileExt: u.image.fileExt, uti: u.image.uti, byteSize: 0, widthPx: u.image.widthPx,
                                       heightPx: u.image.heightPx, sha256: "", createdAt: now, updatedAt: now)
                    s.attachments[a.id] = a
                    underlayId = a.id
                }
                s.levels[levelId] = Level(id: levelId, propertyId: property, name: ld.name, kind: ld.kind, sortOrder: ld.sortOrder,
                                          underlayAttachmentId: underlayId, underlayTransform: ld.underlay?.transform,
                                          georef: ld.georef, createdAt: now, updatedAt: now)
                let t = ld.alignment ?? .identity
                var spaceMap: [UUID: UUID] = [:]
                for (i, sd) in ld.spaces.enumerated() {
                    let id = UUID(); spaceMap[sd.tempId] = id
                    s.spaces[id] = Space(id: id, propertyId: property, levelId: levelId, name: sd.name, spaceType: sd.spaceType,
                                         isExterior: sd.isExterior, polygon: sd.polygon.transformed(by: t), source: sd.source,
                                         isApproximate: sd.isApproximate, colorHex: sd.colorHex, sortOrder: i,
                                         createdAt: now, updatedAt: now)
                }
                var openingMap: [UUID: UUID] = [:]
                for od in ld.openings {
                    let id = UUID(); openingMap[od.tempId] = id
                    s.openings[id] = Opening(id: id, propertyId: property, levelId: levelId, spaceId: od.spaceTempId.flatMap { spaceMap[$0] },
                                             kind: od.kind, segment: t.apply(od.segment), heightIn: od.heightIn, sillIn: od.sillIn,
                                             swing: od.swing, isExteriorDoor: od.isExteriorDoor,
                                             source: draft.source == .roomplan ? .roomplan : .manual, createdAt: now, updatedAt: now)
                }
                for md in ld.measurements {
                    let spaceId = md.spaceTempId.flatMap { spaceMap[$0] }, openingId = md.openingTempId.flatMap { openingMap[$0] }
                    guard spaceId != nil || openingId != nil else { continue }
                    let m = HomeMeasurement(propertyId: property, label: md.label, kind: md.kind, spaceId: spaceId, openingId: openingId,
                                        pin: md.pin.map(t.apply), segment: md.segment.map(t.apply), dims: md.dims,
                                        isDeliveryPath: md.isDeliveryPath, source: md.source, createdAt: now, updatedAt: now)
                    s.measurements[m.id] = m
                }
                for st in ld.suggestedThings where acceptedSuggestions.contains(st.tempId) {
                    let scope: Scope = st.spaceTempId.flatMap { spaceMap[$0] }.map { .space($0, level: levelId) } ?? .level(levelId)
                    let th = Thing(propertyId: property, scope: scope, category: st.category, name: st.name, templateKey: st.templateKey,
                                   dims: st.dims, pin: st.pin.map(t.apply), createdAt: now, updatedAt: now)
                    s.things[th.id] = th
                }
            }
            if var p = s.properties[property], p.defaultLevelId == nil {
                p.defaultLevelId = s.liveLevels.filter { $0.propertyId == property }.defaultLevel(preferred: nil)?.id
                s.properties[property] = p
            }
        }
        for l in levelIds { store.bus.publish(.geometryChanged(levelId: l)) }
        return levelIds
    }

    // MARK: Helpers (shared with RecentlyDeleted)

    static func softDeleteSpace(_ id: UUID, in s: inout InMemorySnapshot, reassign: Scope, now: Date) {
        guard var sp = s.spaces[id] else { return }
        sp.deletedAt = now; sp.updatedAt = now
        s.spaces[id] = sp
        for spot in s.liveSpots where spot.spaceId == id {
            var x = spot; x.deletedAt = now; x.updatedAt = now; s.spots[x.id] = x
        }
        for (k, var c) in s.chores where c.scope.spaceId == id { c.scope = reassign; c.updatedAt = now; s.chores[k] = c }
        for (k, var p) in s.projects where p.scope.spaceId == id { p.scope = reassign; p.updatedAt = now; s.projects[k] = p }
        for (k, var t) in s.things where t.scope.spaceId == id { t.scope = reassign; t.updatedAt = now; s.things[k] = t }
        for (k, var i) in s.inventory where i.scope.spaceId == id {
            i.scope = reassign; i.storageSpotId = nil; i.updatedAt = now; s.inventory[k] = i
        }
    }

    static func reassign(level: UUID, to target: Scope, in s: inout InMemorySnapshot, now: Date) {
        for (k, var c) in s.chores where c.scope.levelId == level { c.scope = target; c.updatedAt = now; s.chores[k] = c }
        for (k, var p) in s.projects where p.scope.levelId == level { p.scope = target; p.updatedAt = now; s.projects[k] = p }
        for (k, var t) in s.things where t.scope.levelId == level { t.scope = target; t.updatedAt = now; s.things[k] = t }
        for (k, var i) in s.inventory where i.scope.levelId == level { i.scope = target; i.storageSpotId = nil; i.updatedAt = now; s.inventory[k] = i }
    }
}
