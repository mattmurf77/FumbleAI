import Foundation
import GRDB
import HomeCore

/// Who is writing: local writes enqueue sync; sync applies never re-enqueue (LLD §5.3).
public enum WriteOrigin: Sendable { case local, sync }

/// One SQLite file (WAL `DatabasePool`) or an in-memory queue for tests. LLD §3.1, §14.
public final class AppDatabase: @unchecked Sendable {
    let writer: any DatabaseWriter
    public let clock: HomeClock
    public let bus: DomainEventBus
    public let engine: RecurrenceEngine

    private let lock = NSLock()
    private var localChangeListeners: [UUID: @Sendable (Set<RecordRef>) -> Void] = [:]
    private let observationQueue = DispatchQueue(label: "app.fumble.home.db.observation")

    init(writer: any DatabaseWriter, clock: HomeClock, bus: DomainEventBus) throws {
        self.writer = writer
        self.clock = clock
        self.bus = bus
        self.engine = RecurrenceEngine(calendar: clock.calendar)
        try Migrations.migrator.migrate(writer)
        try writer.write { db in try SearchIndexer.rebuildIfNeeded(db) }
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
        }
        return config
    }

    /// Opens (creating if needed) `home.sqlite` at `url` in WAL mode and runs migrations.
    public static func open(at url: URL, clock: HomeClock = SystemClock(), bus: DomainEventBus = BroadcastEventBus()) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        return try AppDatabase(writer: pool, clock: clock, bus: bus)
    }

    /// In-memory database (tests, previews).
    public static func inMemory(clock: HomeClock = SystemClock(), bus: DomainEventBus = BroadcastEventBus()) throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration()), clock: clock, bus: bus)
    }

    // MARK: Read / write

    func read<T>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    /// Runs `body` in one transaction: rows + outbox + FTS (flushed before commit). After commit, publishes the
    /// collected `DomainEvent`s and notifies sync listeners of outbox changes.
    @discardableResult
    func write<T>(origin: WriteOrigin = .local, _ body: @escaping @Sendable (StoreTx) throws -> T) async throws -> T {
        let now = clock.now
        let engine = engine
        let calendar = clock.calendar
        let (result, events, touched) = try await writer.write { db -> (T, [DomainEvent], Set<RecordRef>) in
            let tx = StoreTx(db: db, origin: origin, now: now, engine: engine, calendar: calendar)
            let r = try body(tx)
            try tx.flush()
            return (r, tx.events, tx.outboxTouched)
        }
        for e in events { bus.publish(e) }
        if !touched.isEmpty { notifyLocalChanges(touched) }
        return result
    }

    // MARK: Observation

    /// `AsyncStream` over a GRDB `ValueObservation`: yields the current value, then after every committed change
    /// to the tables `fetch` reads (duplicates removed). Cancelling the consuming task stops the observation.
    func observe<T: Equatable & Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncStream<T> {
        let writer = self.writer
        let queue = observationQueue
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = ValueObservation.tracking(fetch).removeDuplicates()
            let cancellable = observation.start(
                in: writer, scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { continuation.yield($0) })
            let box = CancellableBox(cancellable)
            continuation.onTermination = { _ in box.cancel() }
        }
    }

    // MARK: Local change listeners (HomeSync)

    /// Registers a callback invoked after every local commit that touched the outbox (record refs changed).
    @discardableResult
    public func addLocalChangeListener(_ f: @escaping @Sendable (Set<RecordRef>) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); localChangeListeners[id] = f; lock.unlock()
        return id
    }

    public func removeLocalChangeListener(_ id: UUID) {
        lock.lock(); localChangeListeners[id] = nil; lock.unlock()
    }

    func notifyLocalChanges(_ refs: Set<RecordRef>) {
        lock.lock(); let ls = Array(localChangeListeners.values); lock.unlock()
        for l in ls { l(refs) }
    }

    /// Size of the database file(s) on disk (Diagnostics).
    public var fileSizeBytes: Int64 {
        guard let pool = writer as? DatabasePool else { return 0 }
        let path = pool.path
        return ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }
}

final class CancellableBox: @unchecked Sendable {
    private let c: AnyDatabaseCancellable
    init(_ c: AnyDatabaseCancellable) { self.c = c }
    func cancel() { c.cancel() }
}
