import Foundation
import HomeCore
import HomeStore

/// Schema-driven mapper between a table row (`SyncRow`, snake_case columns) and a `SyncRecord` (camelCase
/// fields). One mapper per record type, built from the migrated schema, so every column except `id` and the local
/// derived caches is written (LLD §5.1) and new columns need no mapper changes.
public struct RecordMapper: Sendable {
    public let schema: SyncTableSchema
    public var recordType: RecordType { schema.recordType }

    public init(schema: SyncTableSchema) { self.schema = schema }

    /// Fields stored in plain `CKRecord` values; everything else goes to `encryptedValues`.
    public static let plainKeys: Set<String> = ["propertyId", "createdAt", "updatedAt", "deletedAt", "schemaVersion"]
    public static let schemaVersionKey = "schemaVersion"
    public static let assetKey = "file"

    /// Row → record. A column value that is `.null` is written as null (clears the field). Values for enum columns
    /// that this build doesn't know are skipped so the server's original value is preserved.
    public func record(id: UUID, row: SyncRow, zoneName: String, systemFields: Data?, assetURL: URL?) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        for c in schema.columns {
            guard let v = row[c.name] else { continue }
            if let allowed = c.enumValues, case .string(let s) = v, !allowed.contains(s) { continue }
            fields[c.name.camelCased] = v
        }
        if recordType == .property { fields["propertyId"] = .string(id.uuidString.lowercased()) }
        fields[Self.schemaVersionKey] = .int(SyncSchema.version)
        return SyncRecord(recordType: recordType.rawValue, recordName: id.uuidString.lowercased(), zoneName: zoneName,
                          fields: fields, assetURL: assetURL, systemFields: systemFields)
    }

    /// Record → row. Only known columns; keys missing from the record (older clients) are absent from the row so
    /// the local value is kept. Values are coerced to the column's storage kind.
    public func row(from record: SyncRecord) -> SyncRow {
        var out: SyncRow = [:]
        for c in schema.columns {
            guard let v = record.fields[c.name.camelCased] else { continue }
            out[c.name] = Self.coerce(v, to: c.kind)
        }
        return out
    }

    static func coerce(_ v: SyncValue, to kind: SyncColumn.Kind) -> SyncValue {
        switch (kind, v) {
        case (_, .null): return .null
        case (.int, .double(let d)): return .int(Int64(d))
        case (.double, .int(let i)): return .double(Double(i))
        case (.datetime, .string(let s)):
            let f = ISO8601DateFormatter()
            return f.date(from: s).map(SyncValue.date) ?? v
        case (.text, .int(let i)): return .string(String(i))
        default: return v
        }
    }

    /// Parent rows the record references (for orphan parking), e.g. `(level, <uuid>)` for a space.
    public func parentRefs(of record: SyncRecord) -> [RecordRef] {
        schema.columns.compactMap { c in
            guard let t = c.references, case .string(let s)? = record.fields[c.name.camelCased], let id = UUID(uuidString: s) else { return nil }
            return RecordRef(t, id)
        }
    }

    /// Record's `schemaVersion` (0 when absent).
    public static func schemaVersion(of record: SyncRecord) -> Int64 { record.fields[schemaVersionKey]?.intValue ?? 0 }
}

/// Mappers for all 15 record types.
public struct RecordMapperRegistry: Sendable {
    public let mappers: [RecordType: RecordMapper]
    public init(store: SyncStore) throws {
        var m: [RecordType: RecordMapper] = [:]
        for t in RecordType.allCases { m[t] = RecordMapper(schema: try store.schema(t)) }
        mappers = m
    }
    public subscript(_ t: RecordType) -> RecordMapper? { mappers[t] }
}
