import Foundation
import HomeCore

/// How to find a chore's event (LLD §9.5 "Event resolution"): cached `eventIdentifier`, then
/// `calendarItemExternalIdentifier`, then a window search by the `home://chore/<uuid>` URL.
public struct EventLocator: Hashable, Sendable {
    public var url: URL
    public var eventIdentifier: String?
    public var externalId: String?
    public var calendarId: String?
    /// Occurrences on or after this day are "future".
    public var today: LocalDate
    public init(url: URL, eventIdentifier: String?, externalId: String?, calendarId: String?, today: LocalDate) {
        self.url = url; self.eventIdentifier = eventIdentifier; self.externalId = externalId
        self.calendarId = calendarId; self.today = today
    }
}

/// A resolved event occurrence: the earliest one on or after `today`, or (when none is ahead) the latest past one.
public struct ResolvedEvent: Hashable, Sendable {
    public var eventIdentifier: String
    public var externalId: String?
    public var calendarId: String
    /// Occurrence start (instant in the store's calendar).
    public var occurrenceStart: Date
    /// Local day of the occurrence.
    public var occurrenceDay: LocalDate
    public var isRecurring: Bool
    /// Occurrence is on or after `today`.
    public var isFuture: Bool
    public init(eventIdentifier: String, externalId: String?, calendarId: String, occurrenceStart: Date,
                occurrenceDay: LocalDate, isRecurring: Bool, isFuture: Bool) {
        self.eventIdentifier = eventIdentifier; self.externalId = externalId; self.calendarId = calendarId
        self.occurrenceStart = occurrenceStart; self.occurrenceDay = occurrenceDay; self.isRecurring = isRecurring
        self.isFuture = isFuture
    }
}

public enum CalendarStoreError: Error, Hashable, Sendable {
    case accessDenied
    case calendarNotFound(String)
    case noWritableSource
    case eventNotFound
    case saveFailed(String)
}

/// The EventKit operations `CalendarSync` needs, value-typed so the sync logic is testable on Linux.
/// Live: `EventKitCalendarStore`. Tests / non-Apple: `InMemoryCalendarStore`.
public protocol CalendarStoreProtocol: Sendable {
    func authorizationStatus() -> PermissionStatus
    /// iOS 17 `requestFullAccessToEvents`.
    func requestFullAccess() async throws -> Bool
    /// Writable event calendars (`allowsContentModifications`), grouped by `sourceTitle` in the UI.
    func writableCalendars() -> [CalendarInfo]
    func calendar(id: String) -> CalendarInfo?
    /// Creates "Home" in the iCloud CalDAV source, else the local source.
    func createCalendar(title: String, colorHex: String?) throws -> CalendarInfo
    /// `save(event, span: .futureEvents, commit: true)`.
    func create(_ spec: CalendarEventSpec, calendarId: String) throws -> ResolvedEvent
    func resolve(_ locator: EventLocator) -> ResolvedEvent?
    /// Applies `spec` (rule too) to the occurrence and everything after it (`span: .futureEvents`); earlier
    /// occurrences keep their old details. Returns the event after the save (identifiers may change).
    func update(_ occurrence: ResolvedEvent, url: URL, with spec: CalendarEventSpec) throws -> ResolvedEvent
    /// Removes the occurrence and everything after it (`span: .futureEvents`). Past occurrences stay.
    func removeFuture(_ occurrence: ResolvedEvent, url: URL) throws
}

// MARK: - In-memory store (tests, previews, Linux)

/// A small calendar simulator: series expand with `RecurrenceEngine`, `.futureEvents` edits split the series
/// (the old part keeps its details and gets a new end), and ids change on split like EventKit's do.
public final class InMemoryCalendarStore: CalendarStoreProtocol, @unchecked Sendable {
    public struct Event: Hashable, Sendable {
        public var eventIdentifier: String
        public var externalId: String
        public var calendarId: String
        public var spec: CalendarEventSpec
        /// Occurrences on or after this day were removed / split off.
        public var cutoff: LocalDate?
    }

    private let lock = NSLock()
    private var _calendars: [CalendarInfo]
    private var _events: [String: Event] = [:]
    private var _status: PermissionStatus
    private var nextId = 1
    private let engine: RecurrenceEngine
    private let calendar: Calendar
    public var failCreateInSources: Set<String> = []

    public init(calendars: [CalendarInfo] = InMemoryCalendarStore.sampleCalendars, status: PermissionStatus = .authorized,
                calendar: Calendar = RecurrenceEngine.defaultCalendar) {
        _calendars = calendars; _status = status; self.calendar = calendar
        engine = RecurrenceEngine(calendar: calendar)
    }

    public static let sampleCalendars = [
        CalendarInfo(id: "cal-family", title: "Family", sourceTitle: "iCloud", colorHex: "#4C9A5B"),
        CalendarInfo(id: "cal-house", title: "House", sourceTitle: "Gmail – you@example.com", colorHex: "#3F7FE0"),
    ]

    public var events: [Event] { lock.withLock { _events.values.sorted { $0.eventIdentifier < $1.eventIdentifier } } }

    /// Test hook: simulate the user deleting every event with this URL in the Calendar app.
    public func deleteAllEvents(url: URL) { lock.withLock { _events = _events.filter { $0.value.spec.url != url } } }
    /// Test hook: simulate an account removal.
    public func removeCalendar(id: String) {
        lock.withLock { _calendars.removeAll { $0.id == id }; _events = _events.filter { $0.value.calendarId != id } }
    }

    /// All occurrence days of events with this URL in [from, to] (tests).
    public func occurrenceDays(url: URL, from: LocalDate, to: LocalDate) -> [(day: LocalDate, title: String, minutes: Int?)] {
        lock.withLock {
            var out: [(LocalDate, String, Int?)] = []
            for e in _events.values where e.spec.url == url {
                for d in days(of: e, from: from, to: to) { out.append((d, e.spec.title, e.spec.startMinutes)) }
            }
            return out.sorted { $0.0 < $1.0 }
        }
    }

    public func authorizationStatus() -> PermissionStatus { lock.withLock { _status } }
    public func requestFullAccess() async throws -> Bool {
        lock.withLock { if _status == .notDetermined { _status = .authorized }; return _status == .authorized }
    }
    public func writableCalendars() -> [CalendarInfo] { lock.withLock { _calendars } }
    public func calendar(id: String) -> CalendarInfo? { lock.withLock { _calendars.first { $0.id == id } } }

    public func createCalendar(title: String, colorHex: String?) throws -> CalendarInfo {
        try lock.withLock {
            let source = failCreateInSources.contains("iCloud") ? "On My iPhone" : "iCloud"
            if failCreateInSources.contains(source) { throw CalendarStoreError.noWritableSource }
            let c = CalendarInfo(id: "cal-\(title.lowercased())-\(nextId)", title: title, sourceTitle: source, colorHex: colorHex)
            nextId += 1
            _calendars.insert(c, at: 0)
            return c
        }
    }

    public func create(_ spec: CalendarEventSpec, calendarId: String) throws -> ResolvedEvent {
        try lock.withLock {
            guard _calendars.contains(where: { $0.id == calendarId }) else { throw CalendarStoreError.calendarNotFound(calendarId) }
            let e = newEvent(spec: spec, calendarId: calendarId)
            _events[e.eventIdentifier] = e
            return resolved(e, day: spec.startDay, today: spec.startDay)
        }
    }

    public func resolve(_ locator: EventLocator) -> ResolvedEvent? {
        lock.withLock { resolveLocked(locator) }
    }

    public func update(_ occurrence: ResolvedEvent, url: URL, with spec: CalendarEventSpec) throws -> ResolvedEvent {
        try lock.withLock {
            guard var old = _events[occurrence.eventIdentifier] else { throw CalendarStoreError.eventNotFound }
            if old.spec.recurrence == nil {
                old.spec = spec
                _events[old.eventIdentifier] = old
                return resolved(old, day: spec.startDay, today: spec.startDay)
            }
            // Split: the old part ends before this occurrence; the new part starts at the new spec's start.
            old.cutoff = occurrence.occurrenceDay
            if days(of: old, from: old.spec.startDay, to: occurrence.occurrenceDay.adding(days: -1)).isEmpty {
                _events[old.eventIdentifier] = nil
            } else {
                _events[old.eventIdentifier] = old
            }
            let e = newEvent(spec: spec, calendarId: old.calendarId)
            _events[e.eventIdentifier] = e
            return resolved(e, day: spec.startDay, today: spec.startDay)
        }
    }

    public func removeFuture(_ occurrence: ResolvedEvent, url: URL) throws {
        lock.withLock {
            guard var e = _events[occurrence.eventIdentifier] else { return }
            if e.spec.recurrence == nil || days(of: e, from: e.spec.startDay, to: occurrence.occurrenceDay.adding(days: -1)).isEmpty {
                _events[e.eventIdentifier] = nil
            } else {
                e.cutoff = occurrence.occurrenceDay
                _events[e.eventIdentifier] = e
            }
        }
    }

    // MARK: helpers (call with lock held)

    private func newEvent(spec: CalendarEventSpec, calendarId: String) -> Event {
        let id = "evt-\(nextId)"; nextId += 1
        return Event(eventIdentifier: id, externalId: "ext-\(id)", calendarId: calendarId, spec: spec, cutoff: nil)
    }

    private func days(of e: Event, from: LocalDate, to: LocalDate) -> [LocalDate] {
        guard from <= to else { return [] }
        var out: [LocalDate] = []
        if e.spec.recurrence != nil, let rule = e.spec.rule {
            for d in engine.occurrences(of: rule, start: e.spec.startDay, from: max(from, e.spec.startDay)) {
                if d > to { break }
                if let c = e.cutoff, d >= c { break }
                out.append(d)
            }
        } else if e.spec.startDay >= from && e.spec.startDay <= to {
            if e.cutoff.map({ e.spec.startDay < $0 }) ?? true { out.append(e.spec.startDay) }
        }
        return out
    }

    private func resolved(_ e: Event, day: LocalDate, today: LocalDate) -> ResolvedEvent {
        ResolvedEvent(eventIdentifier: e.eventIdentifier, externalId: e.externalId, calendarId: e.calendarId,
                      occurrenceStart: day.date(atMinutes: e.spec.startMinutes ?? 0, calendar: calendar) ?? Date(),
                      occurrenceDay: day, isRecurring: e.spec.recurrence != nil, isFuture: day >= today)
    }

    private func resolveLocked(_ loc: EventLocator) -> ResolvedEvent? {
        var candidates: [Event] = []
        if let id = loc.eventIdentifier, let e = _events[id], e.spec.url == loc.url { candidates = [e] }
        if candidates.isEmpty, let ext = loc.externalId {
            candidates = _events.values.filter { $0.externalId == ext && $0.spec.url == loc.url }
        }
        if candidates.isEmpty {
            candidates = _events.values.filter { e in e.spec.url == loc.url && (loc.calendarId == nil || e.calendarId == loc.calendarId) }
        }
        // Other parts of a split series share the URL: consider all of them for "next occurrence".
        let all = _events.values.filter { e in e.spec.url == loc.url && candidates.contains { $0.calendarId == e.calendarId } }
        let window = loc.today.adding(days: 400)
        var best: (Event, LocalDate)?
        for e in all {
            if let d = days(of: e, from: loc.today, to: window).first, best.map({ d < $0.1 }) ?? true { best = (e, d) }
        }
        if let best { return resolved(best.0, day: best.1, today: loc.today) }
        // Nothing ahead: latest past occurrence (history).
        var past: (Event, LocalDate)?
        for e in all {
            if let d = days(of: e, from: loc.today.adding(days: -7), to: loc.today.adding(days: -1)).last
                ?? (e.spec.startDay < loc.today && e.spec.recurrence == nil ? e.spec.startDay : nil),
               past.map({ d > $0.1 }) ?? true { past = (e, d) }
        }
        return past.map { resolved($0.0, day: $0.1, today: loc.today) }
    }
}

/// Platform default: EventKit on Apple platforms, the in-memory simulator elsewhere.
public func makeDefaultCalendarStore() -> any CalendarStoreProtocol {
    #if canImport(EventKit)
    return EventKitCalendarStore()
    #else
    return InMemoryCalendarStore()
    #endif
}
