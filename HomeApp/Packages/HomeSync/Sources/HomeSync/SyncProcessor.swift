import Foundation
import HomeCore
import HomeStore

/// Engine-agnostic sync logic (LLD §5.2–5.4): builds outgoing records from rows + outbox, applies fetched batches
/// (merge with pending local edits, orphan parking, unknown-value parking), and handles per-record send results.
/// `SyncCoordinator` drives it from CKSyncEngine events; tests drive it with a fake cloud.
public actor SyncProcessor {
    public nonisolated let store: SyncStore
    public nonisolated let mappers: RecordMapperRegistry
    /// Outbox `local_version` of each record handed to the engine (send clears the outbox only if unchanged).
    private var inFlight: [RecordRef: Int64] = [:]
    /// Parked asset copies (attachments whose parent row hasn't arrived yet).
    let parkingDirectory: URL

    public init(store: SyncStore) throws {
        self.store = store
        self.mappers = try RecordMapperRegistry(store: store)
        self.parkingDirectory = store.files.directory.deletingLastPathComponent().appendingPathComponent("SyncParking", isDirectory: true)
    }

    // MARK: Outgoing

    public func pendingChanges() async throws -> [PendingChange] {
        try await store.outbox().map(Self.pending)
    }

    public func pendingChanges(for refs: Set<RecordRef>) async throws -> [PendingChange] {
        try await store.outbox().filter { refs.contains($0.ref) }.map(Self.pending)
    }

    static func pending(_ e: OutboxEntry) -> PendingChange {
        PendingChange(ref: e.ref, zoneName: e.zoneName, op: e.op == .delete ? .delete : .save)
    }

    /// Resolves a CloudKit recordName (row UUID) to its record type via the outbox, else the tables.
    public func ref(forRecordName name: String) async throws -> RecordRef? {
        guard let id = UUID(uuidString: name) else { return nil }
        if let e = try await store.outbox().first(where: { $0.id == id }) { return e.ref }
        return try await store.perform { st in
            for t in RecordType.allCases where try st.exists(RecordRef(t, id)) { return RecordRef(t, id) }
            return nil
        }
    }

    /// The record to send for `ref`: the row + saved system fields + asset. When the server already has the record
    /// (system fields known) only the locally changed columns are written, so fields this build doesn't know (or
    /// doesn't understand) keep their server values. Returns nil when the row no longer exists.
    public func buildRecord(_ ref: RecordRef) async throws -> SyncRecord? {
        guard let mapper = mappers[ref.type] else { return nil }
        let assetURL = ref.type == .attachment ? try await store.attachmentFileURL(id: ref.id) : nil
        let built = try await store.perform { st -> (SyncRecord, Int64?)? in
            guard let row = try st.row(ref) else { return nil }
            let entry = try st.outboxEntry(ref)
            let system = try st.systemFields(ref)
            let zone = entry?.zoneName ?? Property.zoneName(for: Self.propertyId(ref, row))
            var fields = row
            if system != nil, let changed = entry?.changedFields {
                let cols = Set(changed.map { $0.split(separator: ".").first.map(String.init) ?? $0 })
                    .union(["updated_at", "deleted_at", "property_id"])
                fields = row.filter { cols.contains($0.key) }
            }
            // The binary is immutable (LLD §5.6): upload it with the first save only.
            let rec = mapper.record(id: ref.id, row: fields, zoneName: zone, systemFields: system, assetURL: system == nil ? assetURL : nil)
            return (rec, entry?.localVersion)
        }
        guard let (rec, version) = built else { return nil }
        if let version { inFlight[ref] = version }
        return rec
    }

    static func propertyId(_ ref: RecordRef, _ row: SyncRow) -> UUID {
        if ref.type == .property { return ref.id }
        return row["property_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? ref.id
    }

    // MARK: Sent results

    /// Successful save: keep the server's system fields; clear the outbox if no newer local edit happened.
    public func handleSaved(_ server: SyncRecord) async throws {
        guard let ref = server.ref else { return }
        let version = inFlight[ref]
        try await store.perform { st in
            if let sf = server.systemFields { try st.setSystemFields(ref, zone: server.zoneName, data: sf) }
            try st.clearOutbox(ref, ifVersion: version)
        }
        inFlight[ref] = nil
    }

    /// Successful delete.
    public func handleDeleted(_ ref: RecordRef) async throws {
        let version = inFlight[ref]
        try await store.perform { st in
            try st.clearSystemFields(ref)
            if let e = try st.outboxEntry(ref), e.op == .delete { try st.clearOutbox(ref, ifVersion: version) }
        }
        inFlight[ref] = nil
    }

    /// What the coordinator must do after a failed send.
    public enum FollowUp: Hashable, Sendable {
        case none
        case resend(PendingChange)
        case recreateZone(String)
        case userDeletedZone(String)
        case quotaExceeded
        case retryLater
        case failed(String)
    }

    public func handleFailedSave(_ sent: SyncRecord, error: SyncSendError) async throws -> FollowUp {
        guard let ref = sent.ref, let mapper = mappers[ref.type] else { return .none }
        switch error {
        case .serverRecordChanged(let server):
            // Merge: server + local changed columns; apply locally; keep the outbox; send again on the server's tag.
            let serverRow = mapper.row(from: server)
            try await store.perform { st in
                if let local = try st.row(ref), let e = try st.outboxEntry(ref) {
                    let merged = MergePolicy.merge(ref.type, server: serverRow, local: local, changed: e.changedFields, today: st.today)
                    _ = try st.apply(ref, values: merged)
                }
                if let sf = server.systemFields { try st.setSystemFields(ref, zone: server.zoneName, data: sf) }
            }
            return .resend(PendingChange(ref: ref, zoneName: sent.zoneName, op: .save))
        case .zoneNotFound:
            return .recreateZone(sent.zoneName)
        case .userDeletedZone:
            return .userDeletedZone(sent.zoneName)
        case .unknownItem:
            // Hard-deleted on the server (purge). Delete wins, except a pending local restore → re-save as new.
            let resend = try await store.perform { st -> Bool in
                if let e = try st.outboxEntry(ref), e.changedFields.contains("deleted_at"), let row = try st.row(ref),
                   row["deleted_at"]?.isNull ?? true {
                    try st.clearSystemFields(ref)
                    return true
                }
                try st.deleteLocal(ref)
                return false
            }
            return resend ? .resend(PendingChange(ref: ref, zoneName: sent.zoneName, op: .save)) : .none
        case .quotaExceeded:
            return .quotaExceeded
        case .networkUnavailable:
            return .retryLater
        case .other(let msg):
            return .failed(msg)
        }
    }

    // MARK: Fetched changes

    public struct FetchOutcome: Sendable {
        /// Rows merged with pending local edits: send them again.
        public var resend: [PendingChange] = []
        public var applied = 0
        public var parked = 0
    }

    /// Applies one fetched batch in one transaction (LLD §5.3 "Apply fetched changes"), then retries parked orphans
    /// until no progress, then moves downloaded assets into `Attachments/`.
    public func applyFetched(modifications: [SyncRecord], deletions: [RecordRef]) async throws -> FetchOutcome {
        let order = Dictionary(uniqueKeysWithValues: SyncSchema.applyOrder.enumerated().map { ($1.rawValue, $0) })
        let sorted = modifications.sorted { (order[$0.recordType] ?? 99) < (order[$1.recordType] ?? 99) }
        let mappers = self.mappers
        let parking = parkingDirectory
        let (outcome, adoptions) = try await store.perform { st -> (FetchOutcome, [(UUID, URL)]) in
            var out = FetchOutcome()
            var adoptions: [(UUID, URL)] = []
            for rec in sorted {
                switch try Self.applyOne(rec, st: st, mappers: mappers, parking: parking) {
                case .applied(let merged, let asset):
                    out.applied += 1
                    if merged, let ref = rec.ref { out.resend.append(PendingChange(ref: ref, zoneName: rec.zoneName, op: .save)) }
                    if let asset, let id = rec.id { adoptions.append((id, asset)) }
                case .parked: out.parked += 1
                case .skipped: break
                }
            }
            for ref in deletions {
                try st.removeOrphan(recordType: ref.type.rawValue, recordName: ref.id.uuidString.lowercased())
                if let e = try st.outboxEntry(ref), e.op == .save, e.changedFields.contains("deleted_at"),
                   let row = try st.row(ref), row["deleted_at"]?.isNull ?? true {
                    // Pending local restore wins over the server purge: re-save as a new record.
                    try st.clearSystemFields(ref)
                    out.resend.append(PendingChange(ref: ref, zoneName: e.zoneName, op: .save))
                } else {
                    try st.deleteLocal(ref)
                }
            }
            let (retried, retriedAssets) = try Self.retryOrphans(st: st, mappers: mappers, parking: parking)
            out.applied += retried
            adoptions += retriedAssets
            return (out, adoptions)
        }
        for (id, url) in adoptions { try? await store.adoptAttachmentFile(id: id, from: url) }
        try await store.updateState { $0.lastFetchAt = Date() }
        return outcome
    }

    /// Retries every parked orphan (e.g. after an app update that understands new values). Returns applied count.
    public func retryOrphans() async throws -> Int {
        let mappers = self.mappers, parking = parkingDirectory
        let (n, adoptions) = try await store.perform { st in try Self.retryOrphans(st: st, mappers: mappers, parking: parking) }
        for (id, url) in adoptions { try? await store.adoptAttachmentFile(id: id, from: url) }
        return n
    }

    enum ApplyResult { case applied(merged: Bool, asset: URL?), parked, skipped }

    static func applyOne(_ rec: SyncRecord, st: SyncTransaction, mappers: RecordMapperRegistry, parking: URL) throws -> ApplyResult {
        guard let t = rec.type, let id = rec.id, let mapper = mappers[t] else {
            try park(rec, missing: "schema:recordType=\(rec.recordType)", st: st, parking: parking)
            return .parked
        }
        let ref = RecordRef(t, id)
        var row = mapper.row(from: rec)
        var merged = false
        if let e = try st.outboxEntry(ref) {
            if e.op == .delete { return .skipped }        // our purge is pending: it will be sent
            if let local = try st.row(ref) {
                row = MergePolicy.merge(t, server: row, local: local, changed: e.changedFields, today: st.today)
                merged = true
            }
        }
        switch try st.apply(ref, values: row) {
        case .applied:
            if let sf = rec.systemFields { try st.setSystemFields(ref, zone: rec.zoneName, data: sf) }
            try st.removeOrphan(recordType: rec.recordType, recordName: rec.recordName)
            return .applied(merged: merged, asset: rec.assetURL)
        case .missingParent(let p):
            try park(rec, missing: "\(p.type.tableName)/\(p.id.uuidString.lowercased())", st: st, parking: parking)
        case .unsupported(let column, let value):
            try park(rec, missing: "schema:\(column)=\(value)", st: st, parking: parking)
        case .rejected(let msg):
            try park(rec, missing: "rejected:\(msg)", st: st, parking: parking)
        }
        return .parked
    }

    static func park(_ rec: SyncRecord, missing: String, st: SyncTransaction, parking: URL) throws {
        var r = rec
        if let asset = rec.assetURL, asset.deletingLastPathComponent().standardizedFileURL != parking.standardizedFileURL {
            try? FileManager.default.createDirectory(at: parking, withIntermediateDirectories: true)
            let dest = parking.appendingPathComponent(rec.recordName + "." + asset.pathExtension)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: asset, to: dest)) != nil { r.assetURL = dest }
        }
        try st.park(recordType: rec.recordType, recordName: rec.recordName, archive: try JSONEncoder().encode(r), missing: missing)
    }

    static func retryOrphans(st: SyncTransaction, mappers: RecordMapperRegistry, parking: URL) throws -> (Int, [(UUID, URL)]) {
        var applied = 0
        var assets: [(UUID, URL)] = []
        var progress = true
        while progress {
            progress = false
            for o in try st.orphans() {
                guard let rec = try? JSONDecoder().decode(SyncRecord.self, from: o.archive) else { continue }
                if case .applied(_, let asset) = try applyOne(rec, st: st, mappers: mappers, parking: parking) {
                    applied += 1
                    progress = true
                    if let asset, let id = rec.id { assets.append((id, asset)) }
                }
            }
        }
        return (applied, assets)
    }

    // MARK: Account / zones

    /// Sign-in or zone recovery: every row (of `property`, or all) becomes pending with all columns.
    public func markAllPending(property: UUID? = nil, forgetSystemFields: Bool = false) async throws -> [PendingChange] {
        try await store.perform { st in
            if forgetSystemFields, let property { try st.clearSystemFields(zone: Property.zoneName(for: property)) }
            _ = try st.enqueueAll(property: property)
        }
        let all = try await store.outbox()
        return all.filter { property == nil || $0.zoneName == Property.zoneName(for: property!) }.map(Self.pending)
    }
}
