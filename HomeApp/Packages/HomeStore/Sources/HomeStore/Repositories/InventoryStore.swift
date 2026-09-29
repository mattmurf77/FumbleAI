import Foundation
import GRDB
import HomeCore

/// GRDB `InventoryRepository` (LLD `InventoryServicing`, §11): items, storage-spot tree (CTE, cycle guard),
/// where-is, seasonal swap and shopping list. Rules come from `InventoryLogic`.
public struct InventoryStore: InventoryRepository {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static func query(_ d: Database, _ q: InventoryQuery) throws -> [InventoryItem] {
        var (sql, args) = scopeFilter(q.scope, levelId: q.levelId)
        sql += " AND property_id = ?"; args.append(q.propertyId.db)
        if let spot = q.spotId {
            let sub = try StorageQueries.subtree(d, of: spot)
            sql += " AND storage_spot_id IN (\(Array(repeating: "?", count: sub.count).joined(separator: ",")))"
            args += sub.map(\.db)
        }
        if let k = q.kind { sql += " AND kind = ?"; args.append(k.rawValue) }
        if let o = q.ownerId { sql += " AND owner_id = ?"; args.append(o.db) }
        if q.lowOnly { sql += " AND is_low = 1" }
        return try InventoryItem.fetchAll(d, where: sql, StatementArguments(args)).sorted { ($0.name, $0.id.db) < ($1.name, $1.id.db) }
    }

    /// Scope of the room a live spot lives in.
    static func scope(ofSpot id: UUID, _ d: Database) throws -> Scope? {
        guard let spot = try StorageSpot.fetchOne(d, id: id), let space = try Space.fetchOne(d, id: spot.spaceId) else { return nil }
        return .space(space.id, level: space.levelId)
    }

    public func item(_ id: UUID) async throws -> InventoryItem? { try await db.read { try InventoryItem.fetchOne($0, id: id, includeDeleted: false) } }
    public func items(_ query: InventoryQuery) async throws -> [InventoryItem] { try await db.read { try Self.query($0, query) } }
    public func observeItems(_ query: InventoryQuery) -> AsyncStream<[InventoryItem]> { db.observe { try Self.query($0, query) } }

    public func create(_ draft: InventoryDraft) async throws -> InventoryItem {
        try await db.write { tx in
            var spotScope: Scope?
            if let sid = draft.storageSpotId {
                guard let s = try Self.scope(ofSpot: sid, tx.db) else { throw RepositoryError.notFound(RecordRef(.storageSpot, sid)) }
                spotScope = s
            }
            let item = InventoryLogic.make(from: draft, now: tx.now, spotScope: spotScope)
            let saved = try tx.save(item)
            tx.emit(.created(.inventory(item.id)))
            return saved
        }
    }

    public func update(_ item: InventoryItem) async throws {
        try await db.write { tx in
            var i = InventoryLogic.applyLowThreshold(item)
            _ = try tx.require(InventoryItem.self, i.id, includeDeleted: true)
            if let sid = i.storageSpotId, let sc = try Self.scope(ofSpot: sid, tx.db) { i.scope = sc }
            try tx.save(i)
            tx.emit(.updated(.inventory(i.id)))
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(InventoryItem.self, id, includeDeleted: true))
            tx.emit(.deleted(.inventory(id)))
        }
    }

    public func move(_ ids: [UUID], to spot: UUID?) async throws {
        try await db.write { tx in
            var target: Scope?
            if let spot {
                guard let s = try Self.scope(ofSpot: spot, tx.db) else { throw RepositoryError.notFound(RecordRef(.storageSpot, spot)) }
                target = s
            }
            for id in ids {
                guard var i = try tx.get(InventoryItem.self, id, includeDeleted: true) else { continue }
                i.storageSpotId = spot
                if let target { i.scope = target }
                try tx.save(i)
                tx.emit(.updated(.inventory(id)))
            }
        }
    }

    public func adjustQuantity(_ id: UUID, by delta: Double) async throws {
        try await db.write { tx in
            var i = try tx.require(InventoryItem.self, id, includeDeleted: true)
            i.quantity = max(0, i.quantity + delta)
            i = InventoryLogic.applyLowThreshold(i)
            try tx.save(i)
            tx.emit(.updated(.inventory(id)))
        }
    }

    // MARK: Spots

    public func spot(_ id: UUID) async throws -> StorageSpot? { try await db.read { try StorageSpot.fetchOne($0, id: id, includeDeleted: false) } }

    public func spots(space: UUID) async throws -> [StorageSpot] {
        try await db.read { d in
            try StorageSpot.fetchAll(d, where: "space_id = ?", [space.db]).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        }
    }

    public func saveSpot(_ spot: StorageSpot) async throws {
        try await db.write { tx in
            if spot.parentSpotId == spot.id { throw RepositoryError.cycle }
            if let pid = spot.parentSpotId, let parent = try tx.get(StorageSpot.self, pid, includeDeleted: true), parent.spaceId != spot.spaceId {
                throw RepositoryError.cycle
            }
            if let pid = spot.parentSpotId, try tx.get(StorageSpot.self, spot.id, includeDeleted: true) != nil,
               try StorageQueries.subtree(tx.db, of: spot.id).contains(pid) {
                throw RepositoryError.cycle
            }
            let old = try tx.get(StorageSpot.self, spot.id, includeDeleted: true)
            try tx.save(spot)
            // A spot moved to another room carries its subtree and the items inside (§11.2).
            if let old, old.spaceId != spot.spaceId { try Self.moveSubtree(spot.id, toSpace: spot.spaceId, in: tx) }
            tx.emit(.recordsChanged([RecordRef(.storageSpot, spot.id)]))
        }
    }

    static func moveSubtree(_ spotId: UUID, toSpace space: UUID, in tx: StoreTx) throws {
        guard let sp = try Space.fetchOne(tx.db, id: space) else { return }
        for sid in try StorageQueries.subtree(tx.db, of: spotId) {
            if var s = try tx.get(StorageSpot.self, sid), s.spaceId != space { s.spaceId = space; try tx.save(s) }
            for var i in try InventoryItem.fetchAll(tx.db, where: "storage_spot_id = ?", [sid.db]) {
                i.scope = .space(space, level: sp.levelId)
                try tx.save(i)
            }
        }
    }

    public func deleteSpot(_ id: UUID, moveItemsTo: UUID?) async throws {
        try await db.write { tx in
            guard try tx.get(StorageSpot.self, id, includeDeleted: true) != nil else { throw RepositoryError.notFound(RecordRef(.storageSpot, id)) }
            let sub = try StorageQueries.subtree(tx.db, of: id)
            let target = try moveItemsTo.flatMap { try Self.scope(ofSpot: $0, tx.db) }
            let (marks, args) = StorageQueries.inList(sub)
            for var i in try InventoryItem.fetchAll(tx.db, where: "storage_spot_id IN (\(marks))", args, includeDeleted: true) {
                i.storageSpotId = moveItemsTo
                if let target { i.scope = target }
                try tx.save(i)
            }
            for sid in sub { if let s = try tx.get(StorageSpot.self, sid, includeDeleted: true) { try tx.softDelete(s) } }
            tx.emit(.recordsChanged([RecordRef(.storageSpot, id)]))
        }
    }

    public func reparentSpot(_ id: UUID, to parent: UUID?) async throws {
        try await db.write { tx in
            guard var sp = try tx.get(StorageSpot.self, id, includeDeleted: true) else { throw RepositoryError.notFound(RecordRef(.storageSpot, id)) }
            if let parent {
                guard let p = try tx.get(StorageSpot.self, parent, includeDeleted: true), p.spaceId == sp.spaceId,
                      !(try StorageQueries.subtree(tx.db, of: id)).contains(parent) else { throw RepositoryError.cycle }
            }
            sp.parentSpotId = parent
            try tx.save(sp)
            tx.emit(.recordsChanged([RecordRef(.storageSpot, id)]))
        }
    }

    public func observeSpotTree(space: UUID) -> AsyncStream<[SpotNode]> { db.observe { try StorageQueries.tree($0, space: space) } }

    // MARK: Queries

    public func locations(of ids: [UUID]) async throws -> [ItemLocation] { try await db.read { try StorageQueries.locations($0, ids: ids) } }

    public func observeSeasonalSwap(property: UUID, on date: LocalDate) -> AsyncStream<SeasonalSwap> {
        db.observe { try StorageQueries.seasonalSwap($0, property: property, on: date) }
    }

    public func applySwap(itemIds: [UUID], inRotation: Bool) async throws {
        try await db.write { tx in
            for id in itemIds {
                guard var i = try tx.get(InventoryItem.self, id, includeDeleted: true) else { continue }
                i.inRotation = inRotation
                try tx.save(i)
                tx.emit(.updated(.inventory(id)))
            }
        }
    }

    public func observeShoppingList(property: UUID, on date: LocalDate) -> AsyncStream<[ShoppingLine]> {
        db.observe { try StorageQueries.shoppingList($0, property: property, on: date) }
    }
}
