import Foundation
import HomeCore
import HomeStore

/// Platform-free image of a CloudKit record (LLD §5.1). The CloudKit adapter converts `CKRecord` ↔ `SyncRecord`;
/// everything else in HomeSync (mappers, merge policy, apply/sent handling) works on this type so it is testable
/// on Linux with a fake engine.
public struct SyncRecord: Hashable, Sendable, Codable {
    /// PascalCase record type, e.g. "Chore".
    public var recordType: String
    /// Row UUID (lowercase).
    public var recordName: String
    /// `property-<uuid>`.
    public var zoneName: String
    /// camelCase field keys (user content is written to `encryptedValues` by the CloudKit adapter).
    public var fields: [String: SyncValue]
    /// Attachment binary (`file` CKAsset).
    public var assetURL: URL?
    /// `CKRecord.encodeSystemFields` archive (change tag etc.); nil for a record never saved.
    public var systemFields: Data?

    public init(recordType: String, recordName: String, zoneName: String, fields: [String: SyncValue] = [:],
                assetURL: URL? = nil, systemFields: Data? = nil) {
        self.recordType = recordType; self.recordName = recordName; self.zoneName = zoneName; self.fields = fields
        self.assetURL = assetURL; self.systemFields = systemFields
    }

    public var type: RecordType? { RecordType(rawValue: recordType) }
    public var id: UUID? { UUID(uuidString: recordName) }
    public var ref: RecordRef? {
        guard let t = type, let i = id else { return nil }
        return RecordRef(t, i)
    }
}

/// Where a pending change goes (from the outbox).
public struct PendingChange: Hashable, Sendable {
    public enum Op: Hashable, Sendable { case save, delete }
    public var ref: RecordRef
    public var zoneName: String
    public var op: Op
    public init(ref: RecordRef, zoneName: String, op: Op) { self.ref = ref; self.zoneName = zoneName; self.op = op }
}

/// Per-record send failures, mapped from `CKError` (LLD §5.3 "Sent handling").
public enum SyncSendError: Error, Hashable, Sendable {
    case serverRecordChanged(server: SyncRecord)
    case zoneNotFound
    case userDeletedZone
    case unknownItem
    case quotaExceeded
    case networkUnavailable
    case other(String)
}

extension String {
    /// snake_case → camelCase (`next_due_on` → `nextDueOn`).
    var camelCased: String {
        let parts = split(separator: "_")
        guard let first = parts.first else { return self }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
