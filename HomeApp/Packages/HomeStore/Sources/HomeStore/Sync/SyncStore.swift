import Foundation
import GRDB
import HomeCore
import PlanKit

// Platform-free sync bookkeeping used by HomeSync (LLD §3.3, §5.2–5.4). Rows cross this boundary as
// `[column_name: SyncValue]` dictionaries so HomeSync never touches GRDB and its mappers/merge policy are testable
// on Linux. Column metadata (types, FK parents, enum value lists) is introspected from the migrated schema.

/// A column value as it travels to/from CloudKit (LLD §5.1 type mapping).
public enum SyncValue: Hashable, Sendable, Codable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case bytes(Data)

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int64? { if case .int(let i) = self { return i }; return nil }
    public var dateValue: Date? { if case .date(let d) = self { return d }; return nil }
}

public typealias SyncRow = [String: SyncValue]

/// Column metadata of a synced table.
public struct SyncColumn: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case text, int, double, datetime, blob }
    public var name: String
    public var kind: Kind
    public var notNull: Bool
    public var hasDefault: Bool
    /// FK parent table (as a record type) when the column references a synced table.
    public var references: RecordType?
    /// Allowed values for enum columns (the SQL CHECK list).
    public var enumValues: Set<String>?
}

public struct SyncTableSchema: Hashable, Sendable {
    public var recordType: RecordType
    /// Synced columns (excludes `id` and local derived caches).
    public var columns: [SyncColumn]
    public func column(_ name: String) -> SyncColumn? { columns.first { $0.name == name } }
}

public enum SyncSchema {
    /// Written on every record as `schemaVersion` (plain field) so older clients can detect newer data.
    public static let version: Int64 = 1

    /// Parent-before-child order for applying fetched batches.
    public static let applyOrder: [RecordType] = [.property, .person, .level, .attachment, .space, .opening, .storageSpot,
                                                   .measurement, .thing, .chore, .choreCompletion, .choreCalendarLink,
                                                   .project, .costLineItem, .inventoryItem]

    /// Enum CHECK lists, from HomeCore's forward-compatible enums (known cases only).
    static let enumColumns: [String: Set<String>] = [
        "property.unit_system": set(UnitSystem.self), "level.kind": set(Level.Kind.self),
        "space.space_type": set(SpaceType.self), "space.source": set(Space.Source.self),
        "opening.kind": set(Opening.Kind.self), "opening.swing": set(Opening.Swing.self), "opening.source": set(Opening.Source.self),
        "measurement.kind": set(HomeMeasurement.Kind.self), "measurement.source": set(HomeMeasurement.Source.self),
        "thing.scope": set(Scope.Kind.self), "thing.category": set(Thing.Category.self), "thing.ownership": set(Thing.Ownership.self),
        "chore.scope": set(Scope.Kind.self), "chore_completion.outcome": set(ChoreCompletion.Outcome.self),
        "chore_calendar_link.event_mode": set(ChoreCalendarLink.Mode.self),
        "project.scope": set(Scope.Kind.self), "project.status": set(Project.Status.self),
        "cost_line_item.kind": set(CostLineItem.Kind.self),
        "inventory_item.kind": set(InventoryItem.Kind.self), "inventory_item.scope": set(Scope.Kind.self),
        "inventory_item.season": set(Season.self),
        "attachment.owner_type": set(Attachment.OwnerType.self), "attachment.kind": set(Attachment.Kind.self)]

    static func set<E: ForwardCompatibleEnum>(_ e: E.Type) -> Set<String> { Set(E.knownCases.map(\.rawValue)) }

    static func recordType(table: String) -> RecordType? { RecordType.allCases.first { $0.tableName == table } }

    /// Introspects one table (PRAGMA table_info / foreign_key_list).
    static func introspect(_ db: Database, _ type: RecordType) throws -> SyncTableSchema {
        let table = type.tableName
        let derived = ModelTypes.type(for: type).derivedColumns
        var fks: [String: RecordType] = [:]
        for r in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
            if let from: String = r["from"], let to: String = r["table"], let t = recordType(table: to) { fks[from] = t }
        }
        var cols: [SyncColumn] = []
        for r in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") {
            guard let name: String = r["name"], name != "id", !derived.contains(name) else { continue }
            let decl = ((r["type"] as String?) ?? "").uppercased()
            let kind: SyncColumn.Kind
            if decl.contains("DATETIME") { kind = .datetime }
            else if decl.contains("INT") { kind = .int }
            else if decl.contains("REAL") { kind = .double }
            else if decl.contains("BLOB") { kind = .blob }
            else { kind = .text }
            cols.append(SyncColumn(name: name, kind: kind, notNull: ((r["notnull"] as Int?) ?? 0) != 0,
                                   hasDefault: (r["dflt_value"] as DatabaseValue?).map { !$0.isNull } ?? false,
                                   references: fks[name], enumValues: enumColumns["\(table).\(name)"]))
        }
        return SyncTableSchema(recordType: type, columns: cols)
    }
}

/// A parked record (child before parent, or a value this build doesn't understand yet).
public struct ParkedOrphan: Hashable, Sendable {
    public var recordType: String
    public var recordName: String
    /// Opaque archive written by HomeSync (its own `SyncRecord` encoding).
    public var archive: Data
    /// "space/<uuid>" for a missing parent; "schema:<column>=<value>" for an unknown enum value.
    public var missingParent: String
    public var firstSeenAt: Date
}

/// Outcome of applying one fetched row.
public enum SyncApplyOutcome: Hashable, Sendable {
    case applied
    /// A referenced parent row is missing: park and retry later.
    case missingParent(RecordRef)
    /// A value is unknown to this build (newer app version): park; never written back, so it is preserved.
    case unsupported(column: String, value: String)
    /// SQLite rejected the row (constraint); parked with the message.
    case rejected(String)
}

/// Single-row `sync_state` (engine serialization, account, timestamps, last error).
public struct SyncStateRecord: Hashable, Sendable {
    public var engineState: Data?
    public var accountRecordName: String?
    public var lastFetchAt: Date?
    public var lastSendAt: Date?
    public var lastError: String?
    public init(engineState: Data? = nil, accountRecordName: String? = nil, lastFetchAt: Date? = nil, lastSendAt: Date? = nil, lastError: String? = nil) {
        self.engineState = engineState; self.accountRecordName = accountRecordName; self.lastFetchAt = lastFetchAt
        self.lastSendAt = lastSendAt; self.lastError = lastError
    }
}

/// HomeSync's entry point into the database.
public final class SyncStore: @unchecked Sendable {
    public let database: AppDatabase
    public let files: AttachmentFileStore
    private let lock = NSLock()
    private var schemaCache: [RecordType: SyncTableSchema] = [:]

    init(_ database: AppDatabase, files: AttachmentFileStore) { self.database = database; self.files = files }

    public var clock: HomeClock { database.clock }

    /// Column metadata for `type` (cached).
    public func schema(_ type: RecordType) throws -> SyncTableSchema {
        lock.lock(); if let s = schemaCache[type] { lock.unlock(); return s }; lock.unlock()
        let s = try database.writer.read { try SyncSchema.introspect($0, type) }
        lock.lock(); schemaCache[type] = s; lock.unlock()
        return s
    }

    /// Runs `body` in one write transaction with `origin: .sync` (no outbox). After commit publishes
    /// `DomainEvent.syncApplied` for the rows applied/deleted.
    @discardableResult
    public func perform<T>(_ body: @escaping @Sendable (SyncTransaction) throws -> T) async throws -> T {
        let store = self
        let (result, applied) = try await database.write(origin: .sync) { tx -> (T, [RecordRef]) in
            let st = SyncTransaction(tx: tx, store: store)
            let r = try body(st)
            try st.finish()
            return (r, Array(st.applied))
        }
        if !applied.isEmpty {
            database.bus.publish(.syncApplied(recordTypes: Set(applied.map { $0.type.rawValue }), ids: Set(applied.map(\.id))))
        }
        return result
    }

    // MARK: Non-transactional reads

    public func outbox() async throws -> [OutboxEntry] { try await database.read { try Outbox.all($0) } }
    public func outboxCount() async throws -> Int { try await database.read { try Outbox.count($0) } }
    public func outboxEntry(_ ref: RecordRef) async throws -> OutboxEntry? {
        try await database.read { try Outbox.entry($0, type: ref.type, id: ref.id) }
    }
    public func orphanCount() async throws -> Int { try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_orphan") ?? 0 } }

    /// `property-<uuid>` zones this device has data for.
    public func propertyIds() async throws -> [UUID] {
        try await database.read { try String.fetchAll($0, sql: "SELECT id FROM property ORDER BY created_at").compactMap(UUID.init(uuidString:)) }
    }

    public func state() async throws -> SyncStateRecord {
        try await database.read { d in
            guard let r = try Row.fetchOne(d, sql: "SELECT * FROM sync_state WHERE id = 1") else { return SyncStateRecord() }
            return SyncStateRecord(engineState: r["engine_state"], accountRecordName: r["account_record_name"],
                                   lastFetchAt: r["last_fetch_at"], lastSendAt: r["last_send_at"], lastError: r["last_error"])
        }
    }

    public func updateState(_ f: @escaping @Sendable (inout SyncStateRecord) -> Void) async throws {
        try await database.write(origin: .sync) { tx in
            let d = tx.db
            var s = SyncStateRecord()
            if let r = try Row.fetchOne(d, sql: "SELECT * FROM sync_state WHERE id = 1") {
                s = SyncStateRecord(engineState: r["engine_state"], accountRecordName: r["account_record_name"],
                                    lastFetchAt: r["last_fetch_at"], lastSendAt: r["last_send_at"], lastError: r["last_error"])
            }
            f(&s)
            try d.execute(sql: """
                INSERT INTO sync_state (id, engine_state, account_record_name, last_fetch_at, last_send_at, last_error)
                VALUES (1, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET engine_state = excluded.engine_state, account_record_name = excluded.account_record_name,
                  last_fetch_at = excluded.last_fetch_at, last_send_at = excluded.last_send_at, last_error = excluded.last_error
                """, arguments: [s.engineState, s.accountRecordName, s.lastFetchAt, s.lastSendAt, s.lastError])
        }
    }

    /// Local attachment binary for building a `CKAsset` (nil if not present).
    public func attachmentFileURL(id: UUID) async throws -> URL? {
        guard let a = try await database.read({ try Attachment.fetchOne($0, id: id) }) else { return nil }
        return files.exists(a) ? files.url(for: a) : nil
    }

    /// Moves a downloaded asset into `Attachments/` and marks it `local` (post-commit of the apply, LLD §5.6).
    public func adoptAttachmentFile(id: UUID, from url: URL) async throws {
        guard let a = try await database.read({ try Attachment.fetchOne($0, id: id) }) else { return }
        try files.adopt(downloaded: url, id: a.id, ext: a.fileExt)
        try await database.write(origin: .sync) { tx in try AttachmentStore.setLocalState(tx.db, id: id, state: "local") }
    }

    /// Account switch → "Erase and use the new account": deletes every row (domain + sync tables) and binaries.
    public func eraseAllData() async throws {
        try await database.write(origin: .sync) { tx in
            let d = tx.db
            for t in SyncSchema.applyOrder.reversed() { try d.execute(sql: "DELETE FROM \(t.tableName)") }
            for t in ["sync_state", "sync_record_meta", "sync_outbox", "sync_orphan", "calendar_event_cache", "attachment_local",
                      "map_snapshot_cache", "notification_snooze", "search_fts"] {
                try d.execute(sql: "DELETE FROM \(t)")
            }
        }
        try? FileManager.default.removeItem(at: files.directory)
        database.bus.publish(.syncApplied(recordTypes: Set(RecordType.allCases.map(\.rawValue)), ids: []))
    }
}

/// Operations available inside `SyncStore.perform` (one transaction, origin `.sync`).
public final class SyncTransaction {
    let tx: StoreTx
    let store: SyncStore
    var applied: Set<RecordRef> = []
    var choresToRecompute: Set<UUID> = []

    init(tx: StoreTx, store: SyncStore) { self.tx = tx; self.store = store }

    var db: Database { tx.db }

    // MARK: Rows

    /// Current row (including soft-deleted) as `[column: value]`, without `id` or derived caches.
    public func row(_ ref: RecordRef) throws -> SyncRow? {
        let schema = try store.schema(ref.type)
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM \(ref.type.tableName) WHERE id = ?", arguments: [ref.id.db]) else { return nil }
        var out: SyncRow = [:]
        for c in schema.columns { out[c.name] = Self.syncValue(r[c.name] as DatabaseValue? ?? .null, c.kind) }
        return out
    }

    public func exists(_ ref: RecordRef) throws -> Bool {
        try Row.fetchOne(db, sql: "SELECT 1 FROM \(ref.type.tableName) WHERE id = ?", arguments: [ref.id.db]) != nil
    }

    static func syncValue(_ v: DatabaseValue, _ kind: SyncColumn.Kind) -> SyncValue {
        switch v.storage {
        case .null: return .null
        case .int64(let i): return kind == .double ? .double(Double(i)) : .int(i)
        case .double(let d): return kind == .int ? .int(Int64(d)) : .double(d)
        case .string(let s):
            if kind == .datetime, let d = Date.fromDatabaseValue(v) { return .date(d) }
            return .string(s)
        case .blob(let b): return .bytes(b)
        }
    }

    static func databaseValue(_ v: SyncValue) -> DatabaseValue {
        switch v {
        case .null: return .null
        case .int(let i): return i.databaseValue
        case .double(let d): return d.databaseValue
        case .string(let s): return s.databaseValue
        case .date(let d): return d.databaseValue
        case .bytes(let b): return b.databaseValue
        }
    }

    /// Validates and upserts a fetched (or merged) row. Missing columns keep their current value (or the SQL
    /// default on insert). Recomputes derived columns, reindexes FTS, and tracks chores whose `next_due_on`
    /// inputs changed (completions, rule, start).
    public func apply(_ ref: RecordRef, values: SyncRow) throws -> SyncApplyOutcome {
        let schema = try store.schema(ref.type)
        var cols: [String: DatabaseValue] = [:]
        for c in schema.columns {
            guard let v = values[c.name] else { continue }
            if let allowed = c.enumValues, case .string(let s) = v, !allowed.contains(s) { return .unsupported(column: c.name, value: s) }
            if let parent = c.references, case .string(let s) = v {
                guard let pid = UUID(uuidString: s) else { return .rejected("\(c.name): bad id") }
                let pref = RecordRef(parent, pid)
                if pref != ref, try !exists(pref) { return .missingParent(pref) }
            }
            cols[c.name] = Self.databaseValue(v)
        }
        let old = try row(ref)
        if old == nil, let missing = schema.columns.first(where: { $0.notNull && !$0.hasDefault && cols[$0.name] == nil }) {
            return .rejected("missing required field \(missing.name)")
        }
        if ref.type == .space, let json = values["polygon_json"]?.stringValue, let poly = try? HomeJSON.decode(PlanKitPolygon.self, from: json) {
            var derived = Columns()
            Space.setDerived(&derived, poly)
            for (k, v) in derived.values { cols[k] = v }
        }
        do {
            try db.execute(sql: "SAVEPOINT sync_apply")
            if old != nil {
                let keys = cols.keys.sorted()
                if !keys.isEmpty {
                    try db.execute(sql: "UPDATE \(ref.type.tableName) SET \(keys.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                                   arguments: StatementArguments(keys.map { cols[$0]! } + [ref.id.db.databaseValue]))
                }
            } else {
                let keys = cols.keys.sorted()
                try db.execute(sql: "INSERT INTO \(ref.type.tableName) (id\(keys.map { ", \($0)" }.joined())) VALUES (?\(String(repeating: ", ?", count: keys.count)))",
                               arguments: StatementArguments([ref.id.db.databaseValue] + keys.map { cols[$0]! }))
                if ref.type == .attachment { try AttachmentStore.setLocalState(db, id: ref.id, state: "remote_only") }
            }
            try db.execute(sql: "RELEASE SAVEPOINT sync_apply")
        } catch let e as DatabaseError {
            try? db.execute(sql: "ROLLBACK TO SAVEPOINT sync_apply")
            try? db.execute(sql: "RELEASE SAVEPOINT sync_apply")
            return .rejected(e.message ?? "\(e.resultCode)")
        }
        applied.insert(ref)
        tx.reindex.insert(ref)
        switch ref.type {
        case .choreCompletion:
            if let c = values["chore_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? old?["chore_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                choresToRecompute.insert(c)
            }
        case .chore:
            if let old {
                let ruleChanged = values["repeat_rule_json"].map { $0 != old["repeat_rule_json"] } ?? false
                let startChanged = values["start_on"].map { $0 != old["start_on"] } ?? false
                if ruleChanged || startChanged { choresToRecompute.insert(ref.id) }
            }
        case .space, .opening:
            if let l = (values["level_id"] ?? old?["level_id"])?.stringValue.flatMap(UUID.init(uuidString:)) { tx.emit(.geometryChanged(levelId: l)) }
        default: break
        }
        return .applied
    }

    /// Fetched deletion: hard-delete locally (children cascade), drop system fields and any outbox entry.
    public func deleteLocal(_ ref: RecordRef) throws {
        guard try exists(ref) else { return }
        if ref.type == .attachment, let a = try Attachment.fetchOne(db, id: ref.id) {
            store.files.remove(id: a.id, ext: a.fileExt)
            try db.execute(sql: "DELETE FROM attachment_local WHERE attachment_id = ?", arguments: [ref.id.db])
        }
        _ = try RecentlyDeletedStore.purge(ref, in: tx)   // origin .sync: no outbox deletes
        try Outbox.clear(db, type: ref.type, id: ref.id, ifVersion: nil)
        applied.insert(ref)
    }

    /// Marks `choreId` for `next_due_on` recomputation at the end of the transaction.
    public func recomputeNextDue(chore choreId: UUID) { choresToRecompute.insert(choreId) }

    func finish() throws {
        for id in choresToRecompute {
            guard let c = try Chore.fetchOne(db, id: id) else { continue }
            let comps = try ChoreCompletion.fetchAll(db, where: "chore_id = ?", [id.db])
            let r = ChoreLogic.recomputeNextDue(c, completions: comps, engine: tx.engine)
            if r != c { try tx.save(r, stamp: false) }
        }
    }

    // MARK: Outbox

    public func outboxEntry(_ ref: RecordRef) throws -> OutboxEntry? { try Outbox.entry(db, type: ref.type, id: ref.id) }
    public func outbox() throws -> [OutboxEntry] { try Outbox.all(db) }

    /// Clears the entry if its `local_version` is still `version` (a successful send). Returns true if cleared.
    @discardableResult
    public func clearOutbox(_ ref: RecordRef, ifVersion version: Int64?) throws -> Bool {
        try Outbox.clear(db, type: ref.type, id: ref.id, ifVersion: version)
    }

    /// Re-enqueues a row with the given changed fields (e.g. after a conflict merge, or "mark all pending").
    public func enqueue(_ ref: RecordRef, zone: String, changedFields: Set<String>, op: OutboxEntry.Op = .save) throws {
        try Outbox.upsert(db, type: ref.type, id: ref.id, zone: zone, op: op, changedFields: changedFields, now: tx.now)
    }

    /// Account sign-in / zone recovery: every row (soft-deleted too) of `property` (or all) becomes pending with
    /// all its columns. Returns the enqueued refs.
    @discardableResult
    public func enqueueAll(property: UUID? = nil) throws -> [RecordRef] {
        var out: [RecordRef] = []
        for t in SyncSchema.applyOrder {
            let schema = try store.schema(t)
            let fields = Set(schema.columns.map(\.name))
            let sql: String
            var args: StatementArguments = []
            if let property {
                sql = "SELECT id, \(t == .property ? "id" : "property_id") AS pid FROM \(t.tableName) WHERE \(t == .property ? "id" : "property_id") = ?"
                args = [property.db]
            } else {
                sql = "SELECT id, \(t == .property ? "id" : "property_id") AS pid FROM \(t.tableName)"
            }
            for r in try Row.fetchAll(db, sql: sql, arguments: args) {
                guard let id = r.uuidOpt("id"), let pid = r.uuidOpt("pid") else { continue }
                try Outbox.upsert(db, type: t, id: id, zone: Property.zoneName(for: pid), op: .save, changedFields: fields, now: tx.now)
                out.append(RecordRef(t, id))
            }
        }
        return out
    }

    // MARK: System fields (CKRecord.encodeSystemFields archive)

    public func systemFields(_ ref: RecordRef) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT system_fields FROM sync_record_meta WHERE record_type = ? AND record_name = ?",
                          arguments: [ref.type.rawValue, ref.id.db])
    }

    public func setSystemFields(_ ref: RecordRef, zone: String, data: Data) throws {
        try db.execute(sql: """
            INSERT INTO sync_record_meta (record_name, record_type, zone_name, system_fields) VALUES (?, ?, ?, ?)
            ON CONFLICT(record_type, record_name) DO UPDATE SET zone_name = excluded.zone_name, system_fields = excluded.system_fields
            """, arguments: [ref.id.db, ref.type.rawValue, zone, data])
    }

    public func clearSystemFields(_ ref: RecordRef) throws {
        try db.execute(sql: "DELETE FROM sync_record_meta WHERE record_type = ? AND record_name = ?", arguments: [ref.type.rawValue, ref.id.db])
    }

    /// Zone gone (recovery or user deletion): forget all system fields of that zone.
    public func clearSystemFields(zone: String) throws {
        try db.execute(sql: "DELETE FROM sync_record_meta WHERE zone_name = ?", arguments: [zone])
    }

    // MARK: Orphans (LLD §3.3 `sync_orphan`)

    public func park(recordType: String, recordName: String, archive: Data, missing: String) throws {
        try db.execute(sql: """
            INSERT INTO sync_orphan (record_type, record_name, record_archive, missing_parent, first_seen_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(record_type, record_name) DO UPDATE SET record_archive = excluded.record_archive, missing_parent = excluded.missing_parent
            """, arguments: [recordType, recordName, archive, missing, tx.now])
    }

    public func orphans() throws -> [ParkedOrphan] {
        try Row.fetchAll(db, sql: "SELECT * FROM sync_orphan ORDER BY first_seen_at").map { r in
            ParkedOrphan(recordType: r["record_type"] ?? "", recordName: r["record_name"] ?? "", archive: r["record_archive"] ?? Data(),
                         missingParent: r["missing_parent"] ?? "", firstSeenAt: r["first_seen_at"] ?? Date(timeIntervalSince1970: 0))
        }
    }

    public func removeOrphan(recordType: String, recordName: String) throws {
        try db.execute(sql: "DELETE FROM sync_orphan WHERE record_type = ? AND record_name = ?", arguments: [recordType, recordName])
    }

    /// Today in the store's calendar (merge fallbacks such as `completed_on`).
    public var today: LocalDate { tx.today }
    public var now: Date { tx.now }
}

typealias PlanKitPolygon = PlanKit.Polygon
