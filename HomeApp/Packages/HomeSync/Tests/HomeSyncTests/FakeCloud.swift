import Foundation
import HomeCore
import HomeStore
@testable import HomeSync

/// In-memory private database with CloudKit-like semantics: per-record change tags (system fields), changed-keys
/// saves, `serverRecordChanged` on a stale tag, `zoneNotFound`, `unknownItem`, and a change log for fetches.
final class FakeCloud: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var zones: Set<String> = []
    private var records: [String: (record: SyncRecord, tag: Int)] = [:]
    private var log: [(seq: Int, key: String, deleted: RecordRef?)] = []
    private var seq = 0
    var quotaExceeded = false

    static func tag(_ data: Data?) -> Int? { data.flatMap { Int(String(decoding: $0, as: UTF8.self).dropFirst(4)) } }
    static func data(_ tag: Int) -> Data { Data("tag:\(tag)".utf8) }

    func saveZone(_ z: String) { lock.withLock { _ = zones.insert(z) } }
    func deleteZone(_ z: String) {
        lock.withLock {
            zones.remove(z)
            records = records.filter { $0.value.record.zoneName != z }
        }
    }

    func save(_ rec: SyncRecord) -> Result<SyncRecord, SyncSendError> {
        lock.lock(); defer { lock.unlock() }
        if quotaExceeded { return .failure(.quotaExceeded) }
        guard zones.contains(rec.zoneName) else { return .failure(.zoneNotFound) }
        let key = rec.zoneName + "/" + rec.recordName
        if let existing = records[key] {
            guard Self.tag(rec.systemFields) == existing.tag else {
                var server = existing.record; server.systemFields = Self.data(existing.tag)
                return .failure(.serverRecordChanged(server: server))
            }
            var merged = existing.record
            for (k, v) in rec.fields { merged.fields[k] = v }
            if rec.assetURL != nil { merged.assetURL = rec.assetURL }
            records[key] = (merged, existing.tag + 1)
        } else {
            if rec.systemFields != nil { return .failure(.unknownItem) }
            var r = rec; r.systemFields = nil
            records[key] = (r, 1)
        }
        seq += 1; log.append((seq, key, nil))
        var out = records[key]!.record; out.systemFields = Self.data(records[key]!.tag)
        return .success(out)
    }

    func delete(_ ref: RecordRef, zone: String) -> SyncSendError? {
        lock.lock(); defer { lock.unlock() }
        let key = zone + "/" + ref.id.uuidString.lowercased()
        records[key] = nil
        seq += 1; log.append((seq, key, ref))
        return nil
    }

    /// Changes since `cursor` (latest state per record).
    func changes(since cursor: Int) -> (mods: [SyncRecord], dels: [RecordRef], cursor: Int) {
        lock.lock(); defer { lock.unlock() }
        var mods: [String: SyncRecord] = [:], dels: [RecordRef] = []
        for e in log where e.seq > cursor {
            if let d = e.deleted { dels.append(d); mods[e.key] = nil }
            else if let r = records[e.key] { var x = r.record; x.systemFields = Self.data(r.tag); mods[e.key] = x }
        }
        return (Array(mods.values), dels, seq)
    }

    func record(_ zone: String, _ name: String) -> SyncRecord? { lock.withLock { records[zone + "/" + name]?.record } }
    func inject(_ rec: SyncRecord) {
        lock.withLock {
            let key = rec.zoneName + "/" + rec.recordName
            records[key] = (rec, (records[key]?.tag ?? 0) + 1)
            seq += 1; log.append((seq, key, nil))
        }
    }
    var recordCount: Int { lock.withLock { records.count } }
}

/// Fake `SyncEngineDriver` over `FakeCloud` (one per device). Fetch batches can be reversed to force orphans.
final class FakeEngine: SyncEngineDriver, @unchecked Sendable {
    let cloud: FakeCloud
    private let lock = NSLock()
    private var pending: [PendingChange] = []
    private var zoneSaves: [String] = []
    private var cursor = 0
    private weak var coordinator: SyncCoordinator?
    var childrenFirst = false

    init(cloud: FakeCloud) { self.cloud = cloud }

    func start(coordinator: SyncCoordinator, stateSerialization: Data?) async throws {
        lock.withLock { self.coordinator = coordinator }
    }
    func add(pending changes: [PendingChange]) async {
        lock.withLock { for c in changes where !pending.contains(c) { pending.append(c) } }
    }
    func addZoneSaves(_ zoneNames: [String]) async { lock.withLock { zoneSaves += zoneNames } }
    func accountStatus() async -> SyncAccountStatus { .available }
    func zoneNames() async throws -> [String] { Array(cloud.zones) }

    var pendingCount: Int { lock.withLock { pending.count } }

    func sendChanges() async throws {
        guard let c = lock.withLock({ coordinator }) else { return }
        for z in lock.withLock({ () -> [String] in let z = zoneSaves; zoneSaves = []; return z }) { cloud.saveZone(z) }
        var rounds = 0
        while rounds < 10 {
            rounds += 1
            let batch = lock.withLock { () -> [PendingChange] in let b = pending; pending = []; return b }
            if batch.isEmpty { break }
            var saved: [SyncRecord] = [], failed: [(SyncRecord, SyncSendError)] = [], deleted: [RecordRef] = []
            for p in batch {
                if p.op == .delete {
                    _ = cloud.delete(p.ref, zone: p.zoneName); deleted.append(p.ref); continue
                }
                guard let rec = await c.recordToSend(recordName: p.ref.id.uuidString.lowercased(), zoneName: p.zoneName) else { continue }
                switch cloud.save(rec) {
                case .success(let s): saved.append(s)
                case .failure(let e): failed.append((rec, e))
                }
            }
            await c.handle(.sent(saved: saved, failed: failed, deleted: deleted, failedDeletes: []))
            for z in lock.withLock({ () -> [String] in let z = zoneSaves; zoneSaves = []; return z }) { cloud.saveZone(z) }
        }
    }

    func fetchChanges() async throws {
        guard let c = lock.withLock({ coordinator }) else { return }
        let (mods, dels, next) = cloud.changes(since: lock.withLock { cursor })
        lock.withLock { cursor = next }
        let order = Dictionary(uniqueKeysWithValues: SyncSchema.applyOrder.enumerated().map { ($1.rawValue, $0) })
        if childrenFirst {
            // Deliver children in an earlier batch than their parents (orphan parking, AC-SYN-8).
            let sorted = mods.sorted { (order[$0.recordType] ?? 0) > (order[$1.recordType] ?? 0) }
            let half = sorted.count / 2
            await c.handle(.fetched(modifications: Array(sorted[..<half]), deletions: []))
            await c.handle(.fetched(modifications: Array(sorted[half...]), deletions: dels))
        } else {
            await c.handle(.fetched(modifications: mods, deletions: dels))
        }
    }
}
