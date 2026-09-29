import Foundation
import HomeCore
import HomeStore

/// iCloud account state as seen by the engine driver.
public enum SyncAccountStatus: String, Hashable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine, unsupported
}

/// Why a property zone disappeared from the server (`CKSyncEngine` database deletions).
public enum ZoneDeletionReason: Hashable, Sendable { case deleted, purged, encryptedDataReset }

/// Events from the engine driver (CKSyncEngine delegate callbacks, or a test fake) into the coordinator.
public enum SyncEngineEvent: Sendable {
    case stateSerialization(Data)
    case accountSignedIn(userRecordName: String)
    case accountSignedOut
    case accountSwitched(userRecordName: String)
    case zoneDeleted(zoneName: String, reason: ZoneDeletionReason)
    case fetched(modifications: [SyncRecord], deletions: [RecordRef])
    case sent(saved: [SyncRecord], failed: [(SyncRecord, SyncSendError)], deleted: [RecordRef], failedDeletes: [(RecordRef, SyncSendError)])
    case zoneSaveFailed(zoneName: String, error: SyncSendError)
    case willFetch, didFetch, willSend, didSend
}

/// Abstraction over `CKSyncEngine` (LLD §14 `SyncEngineProtocol`) so the coordinator is testable with a fake.
public protocol SyncEngineDriver: AnyObject, Sendable {
    /// Creates the engine with the saved state serialization; events flow to `coordinator.handle(_:)` and records
    /// are pulled with `coordinator.recordToSend(recordName:zoneName:)`.
    func start(coordinator: SyncCoordinator, stateSerialization: Data?) async throws
    func add(pending: [PendingChange]) async
    func addZoneSaves(_ zoneNames: [String]) async
    func fetchChanges() async throws
    func sendChanges() async throws
    func accountStatus() async -> SyncAccountStatus
    /// Zone names in the private database (first-launch restore check).
    func zoneNames() async throws -> [String]
}

/// Account events the UI must react to (blocking sheet, re-upload prompt) — see INTEGRATION_NOTES/store-sync.md.
public enum SyncAccountEvent: Hashable, Sendable {
    /// Different Apple ID: offer "Export CSV" / "Erase and use the new account" (FR-SYN-32).
    case switchedAccounts
    /// The user deleted Home's iCloud data: ask before re-uploading (FR-SYN-33). Call `confirmReupload(zoneName:)`.
    case userDeletedZone(zoneName: String)
}

/// `SyncServicing` over CKSyncEngine (LLD §5): private database, one zone per property, encrypted fields,
/// column-overlay merge, orphan parking, account-change handling. All CloudKit specifics live in the driver
/// (`CloudKitSyncEngine`, compiled only where CloudKit exists); without it the coordinator reports "iCloud off".
public actor SyncCoordinator: SyncServicing {
    public nonisolated let store: HomeStore
    public nonisolated let processor: SyncProcessor
    let driver: SyncEngineDriver?

    private var startTask: Task<Void, Error>?
    private var knownZones: Set<String> = []
    private var account: SyncAccountStatus = .couldNotDetermine
    private var busy = 0
    private var quotaExceeded = false
    private var networkWaiting = false
    private var pausedForUser = false
    private var lastError: String?
    private var lastSync: Date?
    private var statusContinuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var accountContinuations: [UUID: AsyncStream<SyncAccountEvent>.Continuation] = [:]
    private var lastStatus: SyncStatus = .upToDate(lastSync: nil)
    private var listenerId: UUID?

    /// Test / custom-engine initializer.
    public init(store: HomeStore, driver: SyncEngineDriver?) throws {
        self.store = store
        self.processor = try SyncProcessor(store: store.sync)
        self.driver = driver
    }

    /// Production entry point: CloudKit container `containerIdentifier` (`AppConfig.cloudKitContainerIdentifier`).
    /// On platforms without CloudKit the coordinator runs with no engine (status "iCloud off").
    public static func live(store: HomeStore, containerIdentifier: String) throws -> SyncCoordinator {
        #if canImport(CloudKit)
        return try SyncCoordinator(store: store, driver: CloudKitSyncEngine(containerIdentifier: containerIdentifier))
        #else
        return try SyncCoordinator(store: store, driver: nil)
        #endif
    }

    // MARK: SyncServicing

    /// Idempotent; concurrent callers await the same start.
    public func start() async throws {
        if let t = startTask { return try await t.value }
        let t = Task { try await self.performStart() }
        startTask = t
        try await t.value
    }

    private func performStart() async throws {
        guard let driver else { account = .unsupported; publish(); return }
        account = await driver.accountStatus()
        let state = try await store.sync.state()
        lastSync = state.lastFetchAt ?? state.lastSendAt
        lastError = state.lastError
        try await driver.start(coordinator: self, stateSerialization: state.engineState)
        listenerId = store.database.addLocalChangeListener { [weak self] refs in
            guard let self else { return }
            Task { await self.localChanged(refs) }
        }
        _ = try? await processor.retryOrphans()
        // Idempotent: every outbox row → engine pending changes; every local property zone exists.
        let zones = try await store.sync.propertyIds().map(Property.zoneName(for:))
        await ensureZones(zones)
        await enqueue(try await processor.pendingChanges())
        publish()
    }

    public nonisolated func observeStatus() -> AsyncStream<SyncStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            Task { await self.addStatus(id, c) }
            c.onTermination = { _ in Task { await self.removeStatus(id) } }
        }
    }

    private func addStatus(_ id: UUID, _ c: AsyncStream<SyncStatus>.Continuation) async {
        statusContinuations[id] = c
        c.yield(await computeStatus())
    }
    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    /// Account events (switched Apple ID, user-deleted zone) for blocking UI.
    public nonisolated func observeAccountEvents() -> AsyncStream<SyncAccountEvent> {
        let id = UUID()
        return AsyncStream { c in
            Task { await self.addAccount(id, c) }
            c.onTermination = { _ in Task { await self.removeAccount(id) } }
        }
    }
    private func addAccount(_ id: UUID, _ c: AsyncStream<SyncAccountEvent>.Continuation) { accountContinuations[id] = c }
    private func removeAccount(_ id: UUID) { accountContinuations[id] = nil }

    public func syncNow() async throws {
        guard let driver else { return }
        try await start()
        busy += 1; publish()
        defer { busy -= 1; publish() }
        do {
            try await driver.fetchChanges()
            try await driver.sendChanges()
            networkWaiting = false
        } catch {
            lastError = String(describing: error)
            try? await store.sync.updateState { $0.lastError = String(describing: error) }
            throw error
        }
    }

    /// First launch: look for `property-*` zones with `timeout` (8 s in the app, HLD §5.2).
    public func restoreCheck(timeout: TimeInterval) async -> RestoreCheckResult {
        guard let driver else { return .unavailable }
        guard await driver.accountStatus() == .available else { return .unavailable }
        let names: [String]? = await withTaskGroup(of: [String]?.self) { g in
            g.addTask { try? await driver.zoneNames() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let names else { return .unavailable }
        for n in names where n.hasPrefix("property-") {
            if let id = UUID(uuidString: String(n.dropFirst("property-".count))) {
                Task { try? await self.syncNow() }
                return .existingHomeFound(propertyId: id)
            }
        }
        return .noExistingHome
    }

    public func diagnostics() async -> SyncDiagnostics {
        let state = (try? await store.sync.state()) ?? SyncStateRecord()
        return SyncDiagnostics(accountStatus: account.rawValue, lastFetchAt: state.lastFetchAt, lastSendAt: state.lastSendAt,
                               outboxCount: (try? await store.sync.outboxCount()) ?? 0,
                               parkedOrphans: (try? await store.sync.orphanCount()) ?? 0,
                               lastError: lastError ?? state.lastError)
    }

    // MARK: User decisions

    /// "Erase and use the new account" (FR-SYN-32): wipes local data; the app then re-runs `restoreCheck`.
    public func eraseLocalDataForNewAccount() async throws {
        try await store.sync.eraseAllData()
        knownZones = []
        pausedForUser = false
        publish()
    }

    /// "Upload this iPhone's copy again?" → yes (FR-SYN-33).
    public func confirmReupload(zoneName: String) async throws {
        pausedForUser = false
        guard let pid = UUID(uuidString: String(zoneName.dropFirst("property-".count))) else { return }
        knownZones.remove(zoneName)
        await ensureZones([zoneName])
        await enqueue(try await processor.markAllPending(property: pid, forgetSystemFields: true))
        publish()
    }

    // MARK: Engine callbacks

    /// Record provider for the engine's send batches (nil when the row is gone or unknown).
    public func recordToSend(recordName: String, zoneName: String) async -> SyncRecord? {
        guard !pausedForUser, let ref = try? await processor.ref(forRecordName: recordName) else { return nil }
        return try? await processor.buildRecord(ref)
    }

    public func handle(_ event: SyncEngineEvent) async {
        do {
            switch event {
            case .stateSerialization(let data):
                try await store.sync.updateState { $0.engineState = data }
            case .accountSignedIn(let user):
                account = .available
                let state = try await store.sync.state()
                if state.accountRecordName == nil || state.accountRecordName == user {
                    try await store.sync.updateState { $0.accountRecordName = user }
                    let zones = try await store.sync.propertyIds().map(Property.zoneName(for:))
                    await ensureZones(zones)
                    await enqueue(try await processor.markAllPending())
                } else {
                    pausedForUser = true
                    emit(.switchedAccounts)
                }
            case .accountSignedOut:
                account = .noAccount
            case .accountSwitched:
                account = .available
                pausedForUser = true
                emit(.switchedAccounts)
            case .zoneDeleted(let zone, let reason):
                knownZones.remove(zone)
                guard let pid = UUID(uuidString: String(zone.dropFirst("property-".count))) else { break }
                if reason == .encryptedDataReset {
                    await ensureZones([zone])
                    await enqueue(try await processor.markAllPending(property: pid, forgetSystemFields: true))
                } else {
                    pausedForUser = true
                    emit(.userDeletedZone(zoneName: zone))
                }
            case .fetched(let mods, let dels):
                let out = try await processor.applyFetched(modifications: mods, deletions: dels)
                await enqueue(out.resend)
            case .sent(let saved, let failed, let deleted, let failedDeletes):
                for r in saved { try await processor.handleSaved(r) }
                for r in deleted { try await processor.handleDeleted(r) }
                for (rec, err) in failed { await follow(try await processor.handleFailedSave(rec, error: err)) }
                for (ref, err) in failedDeletes {
                    if err == .unknownItem { try await processor.handleDeleted(ref) } else { note(err) }
                }
                if !saved.isEmpty || !deleted.isEmpty {
                    quotaExceeded = false
                    try await store.sync.updateState { $0.lastSendAt = Date() }
                }
            case .zoneSaveFailed(_, let err):
                note(err)
            case .willFetch, .willSend:
                busy += 1
            case .didFetch, .didSend:
                busy = max(0, busy - 1)
                lastSync = Date()
                networkWaiting = false
            }
        } catch {
            lastError = String(describing: error)
        }
        publish()
    }

    private func follow(_ f: SyncProcessor.FollowUp) async {
        switch f {
        case .none: break
        case .resend(let p): await enqueue([p])
        case .recreateZone(let zone):
            knownZones.remove(zone)
            await ensureZones([zone])
            if let pid = UUID(uuidString: String(zone.dropFirst("property-".count))) {
                await enqueue((try? await processor.markAllPending(property: pid, forgetSystemFields: true)) ?? [])
            }
        case .userDeletedZone(let zone):
            pausedForUser = true
            emit(.userDeletedZone(zoneName: zone))
        case .quotaExceeded: quotaExceeded = true
        case .retryLater: networkWaiting = true
        case .failed(let msg): lastError = msg
        }
    }

    private func note(_ err: SyncSendError) {
        switch err {
        case .quotaExceeded: quotaExceeded = true
        case .networkUnavailable: networkWaiting = true
        default: lastError = "\(err)"
        }
    }

    // MARK: Local changes → engine

    func localChanged(_ refs: Set<RecordRef>) async {
        guard let pending = try? await processor.pendingChanges(for: refs) else { return }
        await ensureZones(pending.map(\.zoneName))
        await enqueue(pending)
        publish()
    }

    private func ensureZones(_ zones: [String]) async {
        let new = Set(zones).subtracting(knownZones)
        guard !new.isEmpty, let driver else { return }
        knownZones.formUnion(new)
        await driver.addZoneSaves(new.sorted())
    }

    private func enqueue(_ changes: [PendingChange]) async {
        guard !changes.isEmpty, let driver else { return }
        await ensureZones(changes.map(\.zoneName))
        await driver.add(pending: changes)
    }

    // MARK: Status

    private func emit(_ e: SyncAccountEvent) { for c in accountContinuations.values { c.yield(e) } }

    func computeStatus() async -> SyncStatus {
        if driver == nil || account == .noAccount || account == .restricted || account == .unsupported { return .iCloudOff }
        if quotaExceeded { return .quotaExceeded }
        if pausedForUser { return .error("Waiting for your decision about iCloud data") }
        if busy > 0 { return .syncing }
        let pending = (try? await store.sync.outboxCount()) ?? 0
        if networkWaiting && pending > 0 { return .waitingForNetwork }
        if pending > 0 { return .pending(count: pending) }
        return .upToDate(lastSync: lastSync)
    }

    private func publish() {
        Task { await self.publishNow() }
    }

    private func publishNow() async {
        let s = await computeStatus()
        guard s != lastStatus else { return }
        lastStatus = s
        for c in statusContinuations.values { c.yield(s) }
    }
}
