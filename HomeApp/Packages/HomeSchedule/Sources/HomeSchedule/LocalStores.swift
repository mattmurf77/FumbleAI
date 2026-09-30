import Foundation
import HomeCore

// Device-local state owned by HomeSchedule. The LLD puts these in SQLite local-only tables
// (`notification_snooze`, `calendar_event_cache`, §3.3); HomeCore exposes no protocol for them, so HomeSchedule keeps
// them in a small key-value store (UserDefaults on device). Swapping in a HomeStore-backed implementation only
// requires conforming to `LocalKeyValueStore`.

/// Minimal Data-valued key-value store.
public protocol LocalKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// UserDefaults-backed store (a dedicated suite keeps these keys out of the app's settings).
public final class UserDefaultsKeyValueStore: LocalKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(suiteName: String? = "app.fumble.home.schedule") {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

public final class InMemoryKeyValueStore: LocalKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

extension LocalKeyValueStore {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let d = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else { set(nil, forKey: key); return }
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}

// MARK: - Snoozes (`notification_snooze`)

/// Active "In 1 hour" snoozes (max 2; a third replaces the oldest). LLD §9.3.
public struct SnoozeStore: Sendable {
    private struct Row: Codable { var id: String; var choreId: UUID; var title: String; var fireAt: Date; var createdAt: Date }
    private static let key = "notification_snooze"
    public let storage: any LocalKeyValueStore
    public init(storage: any LocalKeyValueStore) { self.storage = storage }

    public func all() -> [Snooze] {
        (storage.decode([Row].self, forKey: Self.key) ?? []).map {
            Snooze(id: $0.id, choreId: $0.choreId, title: $0.title, fireAt: $0.fireAt, createdAt: $0.createdAt)
        }
    }

    /// Drops expired rows and returns the active ones.
    public func active(now: Date) -> [Snooze] {
        let live = all().filter { $0.fireAt > now }
        save(live)
        return live
    }

    public func add(_ s: Snooze) {
        var rows = all().filter { $0.choreId != s.choreId }     // one snooze per chore; the newest wins
        rows.append(s)
        rows.sort { $0.createdAt < $1.createdAt }
        if rows.count > NotificationPlanner.maxSnoozes { rows.removeFirst(rows.count - NotificationPlanner.maxSnoozes) }
        save(rows)
    }

    public func remove(chore: UUID) { save(all().filter { $0.choreId != chore }) }

    private func save(_ rows: [Snooze]) {
        storage.encode(rows.map { Row(id: $0.id, choreId: $0.choreId, title: $0.title, fireAt: $0.fireAt, createdAt: $0.createdAt) },
                       forKey: Self.key)
    }
}

// MARK: - Calendar event cache (`calendar_event_cache`) + notes

/// Device-local EventKit identifiers per chore, and the "Removed from your calendar outside Home" notes.
public struct CalendarEventCache: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var eventIdentifier: String
        public var lastVerifiedAt: Date
        public init(eventIdentifier: String, lastVerifiedAt: Date) { self.eventIdentifier = eventIdentifier; self.lastVerifiedAt = lastVerifiedAt }
    }
    private static let key = "calendar_event_cache"
    private static let notesKey = "calendar_removed_outside"
    public let storage: any LocalKeyValueStore
    public init(storage: any LocalKeyValueStore) { self.storage = storage }

    private var all: [String: Entry] { storage.decode([String: Entry].self, forKey: Self.key) ?? [:] }

    public func entry(chore: UUID) -> Entry? { all[chore.uuidString.lowercased()] }

    public func set(chore: UUID, eventIdentifier: String?, at date: Date) {
        var m = all
        m[chore.uuidString.lowercased()] = eventIdentifier.map { Entry(eventIdentifier: $0, lastVerifiedAt: date) }
        storage.encode(m, forKey: Self.key)
    }

    /// Chores whose events were deleted in the Calendar app (or whose calendar vanished).
    public var removedOutside: Set<UUID> { Set(storage.decode([UUID].self, forKey: Self.notesKey) ?? []) }

    public func setRemovedOutside(_ chore: UUID, _ flag: Bool) {
        var s = removedOutside
        if flag { s.insert(chore) } else { s.remove(chore) }
        storage.encode(s.sorted { $0.uuidString < $1.uuidString }, forKey: Self.notesKey)
    }
}
