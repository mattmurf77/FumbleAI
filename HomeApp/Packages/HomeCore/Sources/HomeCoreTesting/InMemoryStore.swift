import Foundation
import HomeCore
import PlanKit

/// All rows of the in-memory database (soft-deleted rows included, like SQLite).
public struct InMemorySnapshot: Sendable, Equatable {
    public var properties: [UUID: Property] = [:]
    public var levels: [UUID: Level] = [:]
    public var spaces: [UUID: Space] = [:]
    public var openings: [UUID: Opening] = [:]
    public var people: [UUID: Person] = [:]
    public var spots: [UUID: StorageSpot] = [:]
    public var measurements: [UUID: HomeMeasurement] = [:]
    public var things: [UUID: Thing] = [:]
    public var chores: [UUID: Chore] = [:]
    public var completions: [UUID: ChoreCompletion] = [:]
    public var calendarLinks: [UUID: ChoreCalendarLink] = [:]
    public var projects: [UUID: Project] = [:]
    public var lineItems: [UUID: CostLineItem] = [:]
    public var inventory: [UUID: InventoryItem] = [:]
    public var attachments: [UUID: Attachment] = [:]
    public var settings = AppSettings()
    public init() {}

    // Live (non-deleted) accessors.
    public var liveProperties: [Property] { properties.values.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt } }
    public var liveLevels: [Level] { levels.values.filter { $0.deletedAt == nil }.sortedForPills }
    public var liveSpaces: [Space] { spaces.values.filter { $0.deletedAt == nil }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    public var liveOpenings: [Opening] { openings.values.filter { $0.deletedAt == nil } }
    public var livePeople: [Person] { people.values.filter { $0.deletedAt == nil }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    public var liveSpots: [StorageSpot] { spots.values.filter { $0.deletedAt == nil } }
    public var liveMeasurements: [HomeMeasurement] { measurements.values.filter { $0.deletedAt == nil }.sorted { $0.label < $1.label } }
    public var liveThings: [Thing] { things.values.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name } }
    public var liveChores: [Chore] {
        chores.values.filter { $0.deletedAt == nil }
            .sorted { ($0.nextDueOn ?? LocalDate(9999, 12, 31), $0.title) < ($1.nextDueOn ?? LocalDate(9999, 12, 31), $1.title) }
    }
    public var liveCompletions: [ChoreCompletion] { completions.values.filter { $0.deletedAt == nil }.sorted { $0.doneAt > $1.doneAt } }
    public var liveProjects: [Project] { projects.values.filter { $0.deletedAt == nil }.sorted { $0.title < $1.title } }
    public var liveLineItems: [CostLineItem] { lineItems.values.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt } }
    public var liveInventory: [InventoryItem] { inventory.values.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name } }
    public var liveAttachments: [Attachment] { attachments.values.filter { $0.deletedAt == nil } }

    // Display helpers.
    public func spaceName(_ id: UUID?) -> String? { id.flatMap { spaces[$0]?.name } }
    public func levelName(_ id: UUID?) -> String? { id.flatMap { levels[$0]?.name } }
    public func personName(_ id: UUID?) -> String? { id.flatMap { people[$0]?.name } }

    /// "Kitchen · 1st Floor" / "1st Floor" / "Whole house".
    public func locationText(_ scope: Scope) -> String {
        switch scope {
        case .space(let s, let l): return [spaceName(s), levelName(l)].compactMap { $0 }.joined(separator: " · ")
        case .level(let l): return levelName(l) ?? "This floor"
        case .property: return "Whole house"
        }
    }

    public func spotPath(_ spotId: UUID?) -> String? {
        guard let spotId else { return nil }
        return InventoryLogic.path(of: spotId, in: Array(spots.values))
    }
}

/// Thread-safe in-memory database with change observation. Backs every `InMemory*` repository so cross-entity
/// queries (rollups, lens stats, search) see one consistent state — like a single SQLite file.
public final class InMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: InMemorySnapshot
    private var observers: [UUID: (InMemorySnapshot) -> Void] = [:]

    public let clock: HomeClock
    public let engine: RecurrenceEngine
    public let bus: DomainEventBus

    public init(_ snapshot: InMemorySnapshot = InMemorySnapshot(), clock: HomeClock = SystemClock(), bus: DomainEventBus = BroadcastEventBus()) {
        self.snapshot = snapshot
        self.clock = clock
        self.engine = RecurrenceEngine(calendar: clock.calendar)
        self.bus = bus
    }

    public var now: Date { clock.now }
    public var today: LocalDate { clock.today }

    public func read<T>(_ body: (InMemorySnapshot) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(snapshot)
    }

    /// Mutates atomically, notifies observers, then publishes `events` (post-commit, like HomeStore).
    @discardableResult
    public func write<T>(events: [DomainEvent] = [], _ body: (inout InMemorySnapshot) throws -> T) rethrows -> T {
        lock.lock()
        var copy = snapshot
        let result: T
        do { result = try body(&copy) } catch { lock.unlock(); throw error }
        snapshot = copy
        let obs = Array(observers.values)
        lock.unlock()
        for o in obs { o(copy) }
        for e in events { bus.publish(e) }
        return result
    }

    /// Yields `map(snapshot)` now and after every write that changes it.
    public func observe<T: Equatable & Sendable>(_ map: @escaping @Sendable (InMemorySnapshot) -> T) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let last = LastValue<T>()
            let emit: (InMemorySnapshot) -> Void = { snap in
                let v = map(snap)
                if last.swap(v) { continuation.yield(v) }
            }
            lock.lock()
            observers[id] = emit
            let current = snapshot
            lock.unlock()
            emit(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.observers[id] = nil; self.lock.unlock()
            }
        }
    }

    public var observerCount: Int { lock.lock(); defer { lock.unlock() }; return observers.count }
}

/// Dedupe helper for observations.
final class LastValue<T: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    /// Stores `v`; returns true if it differs from the previous value.
    func swap(_ v: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let value, value == v { return false }
        value = v
        return true
    }
}

func notFound(_ type: RecordType, _ id: UUID) -> RepositoryError { .notFound(RecordRef(type, id)) }
