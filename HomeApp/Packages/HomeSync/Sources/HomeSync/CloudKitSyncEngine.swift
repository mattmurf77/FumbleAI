#if canImport(CloudKit)
import Foundation
import CloudKit
import HomeCore
import HomeStore

/// `CKSyncEngine` driver (iOS 17 / macOS 14, LLD §5.2): private database, one zone per property, user fields in
/// `encryptedValues`, system fields round-tripped via `encodeSystemFields`. All merge/apply logic lives in
/// `SyncCoordinator` / `SyncProcessor`; this type only converts between CloudKit and `SyncRecord`.
public final class CloudKitSyncEngine: SyncEngineDriver, CKSyncEngineDelegate, @unchecked Sendable {
    public let container: CKContainer
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private weak var coordinator: SyncCoordinator?

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    private var database: CKDatabase { container.privateCloudDatabase }
    private func current() -> CKSyncEngine? { lock.lock(); defer { lock.unlock() }; return engine }

    // MARK: SyncEngineDriver

    public func start(coordinator: SyncCoordinator, stateSerialization: Data?) async throws {
        let state = stateSerialization.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        lock.lock(); self.coordinator = coordinator; engine = e; lock.unlock()
    }

    public func add(pending: [PendingChange]) async {
        guard let e = current() else { return }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = pending.map { p in
            let id = CKRecord.ID(recordName: p.ref.id.uuidString.lowercased(), zoneID: Self.zoneID(p.zoneName))
            return p.op == .delete ? .deleteRecord(id) : .saveRecord(id)
        }
        e.state.add(pendingRecordZoneChanges: changes)
    }

    public func addZoneSaves(_ zoneNames: [String]) async {
        guard let e = current() else { return }
        e.state.add(pendingDatabaseChanges: zoneNames.map { .saveZone(CKRecordZone(zoneID: Self.zoneID($0))) })
    }

    public func fetchChanges() async throws { try await current()?.fetchChanges() }
    public func sendChanges() async throws { try await current()?.sendChanges() }

    public func accountStatus() async -> SyncAccountStatus {
        guard let s = try? await container.accountStatus() else { return .couldNotDetermine }
        switch s {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }

    public func zoneNames() async throws -> [String] {
        try await database.allRecordZones().map(\.zoneID.zoneName)
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let coordinator = lock.withLock({ self.coordinator }) else { return }
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) { await coordinator.handle(.stateSerialization(data)) }
        case .accountChange(let e):
            switch e.changeType {
            case .signIn(let user): await coordinator.handle(.accountSignedIn(userRecordName: user.recordName))
            case .signOut: await coordinator.handle(.accountSignedOut)
            case .switchAccounts(_, let user): await coordinator.handle(.accountSwitched(userRecordName: user.recordName))
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let e):
            for d in e.deletions {
                let reason: ZoneDeletionReason
                switch d.reason {
                case .deleted: reason = .deleted
                case .purged: reason = .purged
                case .encryptedDataReset: reason = .encryptedDataReset
                @unknown default: reason = .deleted
                }
                await coordinator.handle(.zoneDeleted(zoneName: d.zoneID.zoneName, reason: reason))
            }
        case .fetchedRecordZoneChanges(let e):
            let mods = e.modifications.map { Self.syncRecord($0.record) }
            let dels: [RecordRef] = e.deletions.compactMap { d in
                guard let t = RecordType(rawValue: d.recordType), let id = UUID(uuidString: d.recordID.recordName) else { return nil }
                return RecordRef(t, id)
            }
            await coordinator.handle(.fetched(modifications: mods, deletions: dels))
        case .sentRecordZoneChanges(let e):
            let saved = e.savedRecords.map { Self.syncRecord($0) }
            let failed = e.failedRecordSaves.map { (Self.syncRecord($0.record), Self.map($0.error)) }
            let deleted: [RecordRef] = await e.deletedRecordIDs.asyncCompactMap { await Self.ref($0, coordinator) }
            var failedDeletes: [(RecordRef, SyncSendError)] = []
            for (id, err) in e.failedRecordDeletes { if let r = await Self.ref(id, coordinator) { failedDeletes.append((r, Self.map(err))) } }
            await coordinator.handle(.sent(saved: saved, failed: failed, deleted: deleted, failedDeletes: failedDeletes))
        case .sentDatabaseChanges(let e):
            for f in e.failedZoneSaves { await coordinator.handle(.zoneSaveFailed(zoneName: f.zone.zoneID.zoneName, error: Self.map(f.error))) }
        case .willFetchChanges: await coordinator.handle(.willFetch)
        case .didFetchChanges: await coordinator.handle(.didFetch)
        case .willSendChanges: await coordinator.handle(.willSend)
        case .didSendChanges: await coordinator.handle(.didSend)
        default: break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let coordinator = lock.withLock({ self.coordinator }) else { return nil }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let rec = await coordinator.recordToSend(recordName: recordID.recordName, zoneName: recordID.zoneID.zoneName) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return CloudKitSyncEngine.ckRecord(rec)
        }
    }

    // MARK: Conversion

    static func zoneID(_ name: String) -> CKRecordZone.ID { CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName) }

    static func ref(_ id: CKRecord.ID, _ c: SyncCoordinator) async -> RecordRef? {
        try? await c.processor.ref(forRecordName: id.recordName)
    }

    /// `SyncRecord` → `CKRecord`: starts from the saved system fields (change tag) when known; user content in
    /// `encryptedValues`, `propertyId`/timestamps/`schemaVersion` plain; attachment binary as the `file` asset.
    static func ckRecord(_ r: SyncRecord) -> CKRecord {
        let record: CKRecord
        if let sf = r.systemFields, let restored = decodeSystemFields(sf) {
            record = restored
        } else {
            record = CKRecord(recordType: r.recordType, recordID: CKRecord.ID(recordName: r.recordName, zoneID: zoneID(r.zoneName)))
        }
        for (key, value) in r.fields {
            let obj = objcValue(value)
            if RecordMapper.plainKeys.contains(key) {
                record.setObject(obj, forKey: key)
            } else {
                record.encryptedValues.setObject(obj, forKey: key)
            }
        }
        if let url = r.assetURL { record.setObject(CKAsset(fileURL: url), forKey: RecordMapper.assetKey) }
        return record
    }

    /// `CKRecord` → `SyncRecord` (plain + encrypted keys; asset file URL; system fields archive).
    static func syncRecord(_ record: CKRecord) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        for key in record.allKeys() where key != RecordMapper.assetKey {
            fields[key] = syncValue(record.object(forKey: key))
        }
        for key in record.encryptedValues.allKeys() {
            fields[key] = syncValue(record.encryptedValues.object(forKey: key))
        }
        let asset = record.object(forKey: RecordMapper.assetKey) as? CKAsset
        return SyncRecord(recordType: record.recordType, recordName: record.recordID.recordName,
                          zoneName: record.recordID.zoneID.zoneName, fields: fields, assetURL: asset?.fileURL,
                          systemFields: encodeSystemFields(record))
    }

    static func objcValue(_ v: SyncValue) -> __CKRecordObjCValue? {
        switch v {
        case .null: return nil
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s as NSString
        case .date(let d): return d as NSDate
        case .bytes(let b): return b as NSData
        }
    }

    static func syncValue(_ o: __CKRecordObjCValue?) -> SyncValue {
        guard let o else { return .null }
        if let s = o as? String { return .string(s) }
        if let d = o as? Date { return .date(d) }
        if let n = o as? NSNumber {
            let t = String(cString: n.objCType)
            return (t == "d" || t == "f") ? .double(n.doubleValue) : .int(n.int64Value)
        }
        if let b = o as? Data { return .bytes(b) }
        return .null
    }

    static func encodeSystemFields(_ r: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func map(_ error: Error) -> SyncSendError {
        guard let ck = error as? CKError else { return .other(error.localizedDescription) }
        switch ck.code {
        case .serverRecordChanged:
            if let server = ck.serverRecord { return .serverRecordChanged(server: syncRecord(server)) }
            return .other("serverRecordChanged without server record")
        case .zoneNotFound: return .zoneNotFound
        case .userDeletedZone: return .userDeletedZone
        case .unknownItem: return .unknownItem
        case .quotaExceeded: return .quotaExceeded
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .networkUnavailable
        default: return .other(ck.localizedDescription)
        }
    }
}

private extension Array {
    func asyncCompactMap<T>(_ f: (Element) async -> T?) async -> [T] {
        var out: [T] = []
        for e in self { if let v = await f(e) { out.append(v) } }
        return out
    }
}
#endif
