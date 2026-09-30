import Foundation
import GRDB
import HomeCore

/// Durable pending changes (`sync_outbox`, LLD §3.3 / §5.3): the source of truth for "unsent".
public struct OutboxEntry: Hashable, Sendable {
    public enum Op: String, Sendable { case save, delete }
    public var recordType: RecordType
    public var id: UUID
    public var zoneName: String
    public var op: Op
    /// Union of column names edited locally since the last successful send (`attributes_json.<key>` entries too).
    public var changedFields: Set<String>
    /// Bumps on each local write; a send clears the entry only if unchanged.
    public var localVersion: Int64
    public var enqueuedAt: Date
    public var ref: RecordRef { RecordRef(recordType, id) }
}

enum Outbox {
    static func upsert(_ db: Database, type: RecordType, id: UUID, zone: String, op: OutboxEntry.Op,
                       changedFields: Set<String>, now: Date) throws {
        if let existing = try entry(db, type: type, id: id) {
            let fields = existing.changedFields.union(changedFields)
            try db.execute(sql: """
                UPDATE sync_outbox SET op = ?, zone_name = ?, changed_fields = ?, local_version = local_version + 1
                WHERE record_type = ? AND record_name = ?
                """, arguments: [op.rawValue, zone, try encode(fields), type.rawValue, id.db])
        } else {
            try db.execute(sql: """
                INSERT INTO sync_outbox (record_type, record_name, zone_name, op, changed_fields, local_version, enqueued_at)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                """, arguments: [type.rawValue, id.db, zone, op.rawValue, try encode(changedFields), now])
        }
    }

    static func entry(_ db: Database, type: RecordType, id: UUID) throws -> OutboxEntry? {
        try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE record_type = ? AND record_name = ?",
                         arguments: [type.rawValue, id.db]).flatMap(decode)
    }

    static func all(_ db: Database) throws -> [OutboxEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM sync_outbox ORDER BY enqueued_at").compactMap(decode)
    }

    static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0
    }

    /// Removes the entry only if no newer local edit happened since `version` was sent.
    @discardableResult
    static func clear(_ db: Database, type: RecordType, id: UUID, ifVersion version: Int64?) throws -> Bool {
        if let version {
            try db.execute(sql: "DELETE FROM sync_outbox WHERE record_type = ? AND record_name = ? AND local_version = ?",
                           arguments: [type.rawValue, id.db, version])
        } else {
            try db.execute(sql: "DELETE FROM sync_outbox WHERE record_type = ? AND record_name = ?", arguments: [type.rawValue, id.db])
        }
        return db.changesCount > 0
    }

    static func decode(_ row: Row) -> OutboxEntry? {
        guard let t = RecordType(rawValue: row["record_type"] ?? ""), let id = UUID(uuidString: row["record_name"] ?? "") else { return nil }
        let fields = (try? HomeJSON.decode([String].self, from: row["changed_fields"] ?? "[]")) ?? []
        return OutboxEntry(recordType: t, id: id, zoneName: row["zone_name"] ?? "", op: OutboxEntry.Op(rawValue: row["op"] ?? "") ?? .save,
                           changedFields: Set(fields), localVersion: row["local_version"] ?? 0,
                           enqueuedAt: row["enqueued_at"] ?? Date(timeIntervalSince1970: 0))
    }

    static func encode(_ fields: Set<String>) throws -> String { try HomeJSON.encodeString(fields.sorted()) }
}
