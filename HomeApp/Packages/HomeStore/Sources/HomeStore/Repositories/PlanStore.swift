import Foundation
import GRDB
import HomeCore
import PlanKit

/// GRDB `PlanRepository`: property, levels, spaces, openings (LLD `PlanServicing`).
public struct PlanStore: PlanRepository {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    // MARK: Property

    static func liveProperties(_ d: Database) throws -> [Property] {
        try Property.fetchAll(d).sorted { $0.createdAt < $1.createdAt }
    }

    public func properties() async throws -> [Property] { try await db.read { try Self.liveProperties($0) } }
    public func currentProperty() async throws -> Property? { try await db.read { try Self.liveProperties($0).first } }
    public func observeCurrentProperty() -> AsyncStream<Property?> { db.observe { try Self.liveProperties($0).first } }

    public func saveProperty(_ property: Property) async throws {
        try await db.write { tx in
            try tx.save(property)
            tx.emit(.recordsChanged([RecordRef(.property, property.id)]))
        }
    }

    public func setDefaultLevel(_ levelId: UUID, property: UUID) async throws {
        try await db.write { tx in
            var p = try tx.require(Property.self, property, includeDeleted: true)
            p.defaultLevelId = levelId
            try tx.save(p)
            tx.emit(.recordsChanged([RecordRef(.property, property)]))
        }
    }

    // MARK: Levels

    static func levels(_ d: Database, property: UUID) throws -> [Level] {
        try Level.fetchAll(d, where: "property_id = ?", [property.db]).sortedForPills
    }

    public func levels(property: UUID) async throws -> [Level] { try await db.read { try Self.levels($0, property: property) } }
    public func observeLevels(property: UUID) -> AsyncStream<[Level]> { db.observe { try Self.levels($0, property: property) } }

    public func saveLevel(_ level: Level) async throws {
        try await db.write { tx in
            if level.kind == .exterior && level.deletedAt == nil {
                let others = try Level.fetchAll(tx.db, where: "property_id = ? AND kind = 'exterior' AND id <> ?", [level.propertyId.db, level.id.db])
                if !others.isEmpty { throw RepositoryError.invalid("A property has at most one exterior level") }
            }
            try tx.save(level)
            tx.emit(.recordsChanged([RecordRef(.level, level.id)]))
            tx.emit(.geometryChanged(levelId: level.id))
        }
    }

    public func deleteLevel(_ id: UUID, reassignItemsTo: Scope) async throws {
        try await db.write { tx in
            let l = try tx.require(Level.self, id, includeDeleted: true)
            try tx.softDelete(l)
            for sp in try Space.fetchAll(tx.db, where: "level_id = ?", [id.db]) {
                try Self.softDeleteSpace(sp, in: tx, reassign: reassignItemsTo)
            }
            try Self.reassign(column: "level_id", value: id, to: reassignItemsTo, in: tx)
            tx.emit(.recordsChanged([RecordRef(.level, id)]))
            tx.emit(.geometryChanged(levelId: id))
        }
    }

    // MARK: Geometry

    static func geometry(_ d: Database, _ l: Level) throws -> LevelGeometry {
        let spaces = try Space.fetchAll(d, where: "level_id = ?", [l.id.db]).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        let openings = try Opening.fetchAll(d, where: "level_id = ?", [l.id.db]).sorted { ($0.createdAt, $0.id.db) < ($1.createdAt, $1.id.db) }
        return LevelGeometry(level: l, spaces: spaces, openings: openings)
    }

    public func geometry(level: UUID) async throws -> LevelGeometry {
        try await db.read { d in
            guard let l = try Level.fetchOne(d, id: level) else { throw RepositoryError.notFound(RecordRef(.level, level)) }
            return try Self.geometry(d, l)
        }
    }

    public func observeGeometry(level: UUID) -> AsyncStream<LevelGeometry> {
        let placeholder = Level(id: level, propertyId: level, name: "", createdAt: .distantPast, updatedAt: .distantPast)
        return db.observe { d in try Self.geometry(d, try Level.fetchOne(d, id: level) ?? placeholder) }
    }

    public func space(_ id: UUID) async throws -> Space? { try await db.read { try Space.fetchOne($0, id: id, includeDeleted: false) } }

    public func spaces(property: UUID) async throws -> [Space] {
        try await db.read { d in
            try Space.fetchAll(d, where: "property_id = ?", [property.db]).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        }
    }

    /// Validates the level overlap rule (interior spaces ≤ 1 sq in), welds interior polygons of every touched
    /// level (PlanKit `Weld`), and writes everything in one transaction.
    public func updateSpaces(_ changes: [SpaceChange]) async throws {
        try await db.write { tx in
            var levels = Set<UUID>()
            for change in changes {
                switch change {
                case .insert(var sp), .update(var sp):
                    if let old = try Space.fetchOne(tx.db, id: sp.id) {
                        if case .update = change, old.polygon != sp.polygon { sp.isApproximate = false }
                        sp.createdAt = old.createdAt
                    } else {
                        sp.createdAt = tx.now
                    }
                    try tx.save(sp)
                    levels.insert(sp.levelId)
                case .delete(let id, let reassign):
                    guard let sp = try Space.fetchOne(tx.db, id: id) else { throw RepositoryError.notFound(RecordRef(.space, id)) }
                    levels.insert(sp.levelId)
                    try Self.softDeleteSpace(sp, in: tx, reassign: reassign)
                }
            }
            for level in levels {
                let interior = try Space.fetchAll(tx.db, where: "level_id = ? AND is_exterior = 0", [level.db])
                // A closet nested inside its room is allowed (SpaceNesting); any other overlap is rejected.
                if let (a, b) = SpaceNesting.overlappingPairs(interior).first {
                    throw RepositoryError.overlap([a, b])
                }
                // Nested closets stay out of the weld: their walls sit inside the room, not on the floor's wall graph.
                let nested = SpaceNesting.hosts(interior)
                try Self.weld(interior.filter { nested[$0.id] == nil }, in: tx)
                tx.emit(.geometryChanged(levelId: level))
            }
        }
    }

    /// Welds interior polygons of one level; writes back only polygons that actually moved.
    static func weld(_ interior: [Space], in tx: StoreTx) throws {
        guard interior.count > 1 else { return }
        let result = Weld.weldDetailed(polygons: interior.map(\.polygon))
        for (i, sp) in interior.enumerated() where !result.failedIndices.contains(i) {
            let w = result.polygons[i]
            guard !samePolygon(w, sp.polygon) else { continue }
            var s = sp
            s.polygon = w
            try tx.save(s)
        }
    }

    static func samePolygon(_ a: Polygon, _ b: Polygon) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a.vertices, b.vertices).allSatisfy { abs($0.x - $1.x) < 0.005 && abs($0.y - $1.y) < 0.005 }
    }

    public func renameSpace(_ id: UUID, to name: String) async throws {
        try await db.write { tx in
            var sp = try tx.require(Space.self, id, includeDeleted: true)
            sp.name = name
            try tx.save(sp)
            tx.emit(.recordsChanged([RecordRef(.space, id)]))
            tx.emit(.geometryChanged(levelId: sp.levelId))
        }
    }

    public func deleteSpace(_ id: UUID, reassignItemsTo: Scope) async throws {
        try await updateSpaces([.delete(id, reassignItemsTo: reassignItemsTo)])
    }

    public func saveOpening(_ opening: Opening) async throws {
        try await db.write { tx in
            try tx.save(opening)
            tx.emit(.geometryChanged(levelId: opening.levelId))
        }
    }

    public func deleteOpening(_ id: UUID) async throws {
        try await db.write { tx in
            let o = try tx.require(Opening.self, id, includeDeleted: true)
            try tx.softDelete(o)
            tx.emit(.geometryChanged(levelId: o.levelId))
        }
    }

    // MARK: Helpers (shared with Recently Deleted)

    /// Soft-deletes a space and its storage spots; items scoped to it move to `reassign` (FR-SES-61).
    static func softDeleteSpace(_ sp: Space, in tx: StoreTx, reassign: Scope) throws {
        try tx.softDelete(sp)
        for spot in try StorageSpot.fetchAll(tx.db, where: "space_id = ?", [sp.id.db]) { try tx.softDelete(spot) }
        try Self.reassign(column: "space_id", value: sp.id, to: reassign, in: tx)
    }

    /// Moves every chore/project/thing/inventory row (deleted ones too) whose `column` is `value` to `target`.
    static func reassign(column: String, value: UUID, to target: Scope, in tx: StoreTx) throws {
        for var c in try Chore.fetchAll(tx.db, where: "\(column) = ?", [value.db], includeDeleted: true) { c.scope = target; try tx.save(c) }
        for var p in try Project.fetchAll(tx.db, where: "\(column) = ?", [value.db], includeDeleted: true) { p.scope = target; try tx.save(p) }
        for var t in try Thing.fetchAll(tx.db, where: "\(column) = ?", [value.db], includeDeleted: true) { t.scope = target; try tx.save(t) }
        for var i in try InventoryItem.fetchAll(tx.db, where: "\(column) = ?", [value.db], includeDeleted: true) {
            i.scope = target; i.storageSpotId = nil; try tx.save(i)
        }
    }
}
