import Foundation
import GRDB
import HomeCore

/// One write transaction (LLD §5.3 "Local write path"). Every repository write goes through `save`, which stamps
/// `updatedAt`, writes only changed columns, unions the changed column names into `sync_outbox` (local origin
/// only) and schedules the FTS reindex that `flush()` runs before commit.
final class StoreTx {
    let db: Database
    let origin: WriteOrigin
    let now: Date
    let engine: RecurrenceEngine
    let calendar: Calendar

    /// Post-commit events (published by `AppDatabase.write`).
    var events: [DomainEvent] = []
    /// Rows whose outbox entry changed (sync listener notification).
    var outboxTouched: Set<RecordRef> = []
    /// Rows to reindex in FTS before commit (cascades are expanded by `SearchIndexer`).
    var reindex: Set<RecordRef> = []

    init(db: Database, origin: WriteOrigin, now: Date, engine: RecurrenceEngine, calendar: Calendar) {
        self.db = db; self.origin = origin; self.now = now; self.engine = engine; self.calendar = calendar
    }

    var today: LocalDate { LocalDate(now, calendar: calendar) }

    func emit(_ e: DomainEvent) { events.append(e) }

    // MARK: Reads

    func get<M: DatabaseModel>(_ t: M.Type, _ id: UUID, includeDeleted: Bool = false) throws -> M? {
        try M.fetchOne(db, id: id, includeDeleted: includeDeleted)
    }

    func require<M: DatabaseModel>(_ t: M.Type, _ id: UUID, includeDeleted: Bool = false) throws -> M {
        guard let m = try get(t, id, includeDeleted: includeDeleted) else { throw RepositoryError.notFound(RecordRef(M.recordType, id)) }
        return m
    }

    // MARK: Writes

    /// Upserts `model`. Local writes stamp `updatedAt = now` and enqueue the changed columns.
    /// Returns the stored model (with the stamped `updatedAt`).
    @discardableResult
    func save<M: DatabaseModel>(_ model: M, stamp: Bool = true) throws -> M {
        var m = model
        if origin == .local && stamp { m.updatedAt = now }
        let cols = try m.columns().values
        let old = try Row.fetchOne(db, sql: "SELECT * FROM \(M.table) WHERE id = ?", arguments: [m.id.db])
        var changed: Set<String> = []
        if let old {
            for (k, v) in cols where old[k] as DatabaseValue? ?? .null != v { changed.insert(k) }
            guard !changed.isEmpty else { return m }
            let assignments = changed.sorted().map { "\($0) = ?" }.joined(separator: ", ")
            let args = StatementArguments(changed.sorted().map { cols[$0]! }) + [m.id.db]
            try db.execute(sql: "UPDATE \(M.table) SET \(assignments) WHERE id = ?", arguments: args)
            if changed.contains("attributes_json"), let o: String = old["attributes_json"],
               let n = String.fromDatabaseValue(cols["attributes_json"] ?? .null) {
                changed.formUnion(Self.changedJSONKeys(old: o, new: n).map { "attributes_json.\($0)" })
            }
        } else {
            let keys = cols.keys.sorted()
            let sql = "INSERT INTO \(M.table) (id, \(keys.joined(separator: ", "))) VALUES (?\(String(repeating: ", ?", count: keys.count)))"
            try db.execute(sql: sql, arguments: StatementArguments([m.id.db.databaseValue] + keys.map { cols[$0]! }))
            changed = Set(keys)
        }
        changed.subtract(M.derivedColumns)
        if origin == .local {
            try Outbox.upsert(db, type: M.recordType, id: m.id, zone: m.zoneName, op: .save, changedFields: changed, now: now)
            outboxTouched.insert(m.ref)
        }
        reindex.insert(m.ref)
        return m
    }

    /// Soft delete (a save of `deleted_at`).
    func softDelete<M: DatabaseModel>(_ model: M) throws {
        var m = model
        guard m.deletedAt == nil else { return }
        m.deletedAt = now
        try save(m)
    }

    /// Hard delete of one row (purge). Enqueues a CloudKit delete for local purges.
    func hardDelete(_ ref: RecordRef, zone: String) throws {
        try db.execute(sql: "DELETE FROM \(ref.type.tableName) WHERE id = ?", arguments: [ref.id.db])
        try db.execute(sql: "DELETE FROM sync_record_meta WHERE record_type = ? AND record_name = ?", arguments: [ref.type.rawValue, ref.id.db])
        if origin == .local {
            try Outbox.upsert(db, type: ref.type, id: ref.id, zone: zone, op: .delete, changedFields: [], now: now)
            outboxTouched.insert(ref)
        }
        try SearchIndexer.remove(db, ref)
    }

    /// Runs the pending FTS reindex (with cascades) inside the transaction.
    func flush() throws {
        guard !reindex.isEmpty else { return }
        let refs = reindex
        reindex = []
        try SearchIndexer.reindex(db, refs: refs)
    }

    static func changedJSONKeys(old: String, new: String) -> Set<String> {
        let o = (try? HomeJSON.decode([String: JSONValue].self, from: old)) ?? [:]
        let n = (try? HomeJSON.decode([String: JSONValue].self, from: new)) ?? [:]
        return Set(o.keys).union(n.keys).filter { o[$0] != n[$0] }
    }
}
