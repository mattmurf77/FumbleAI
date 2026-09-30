import Foundation

/// Post-commit domain events. Side effects (notification replan, calendar updates, render rebuilds) react to
/// these; they never run inside the write transaction. LLD §14, HLD §3.1.
public enum DomainEvent: Hashable, Sendable {
    case created(ItemRef), updated(ItemRef), deleted(ItemRef), restored(ItemRef)
    case choreCompleted(UUID)
    case geometryChanged(levelId: UUID)
    /// Any other synced rows changed locally (people, spots, levels, property, attachments…).
    case recordsChanged(Set<RecordRef>)
    case syncApplied(recordTypes: Set<String>, ids: Set<UUID>)
    case settingsChanged
    case timeZoneChanged

    /// True if this event can affect chore reminders / calendar events.
    public var affectsChores: Bool {
        switch self {
        case .created(.chore), .updated(.chore), .deleted(.chore), .restored(.chore), .choreCompleted, .timeZoneChanged, .settingsChanged:
            return true
        case .syncApplied(let types, _):
            return types.contains(RecordType.chore.rawValue) || types.contains(RecordType.choreCompletion.rawValue)
        default: return false
        }
    }
}

/// Broadcast bus for `DomainEvent`s. Each access to `events` returns a new subscriber stream.
public protocol DomainEventBus: Sendable {
    func publish(_ e: DomainEvent)
    var events: AsyncStream<DomainEvent> { get }
}

/// Thread-safe in-process broadcast implementation (used by the app and the in-memory stores).
public final class BroadcastEventBus: DomainEventBus, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DomainEvent>.Continuation] = [:]

    public init() {}

    public func publish(_ e: DomainEvent) {
        lock.lock(); let cs = Array(continuations.values); lock.unlock()
        for c in cs { c.yield(e) }
    }

    public var events: AsyncStream<DomainEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }

    public var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return continuations.count }
}
