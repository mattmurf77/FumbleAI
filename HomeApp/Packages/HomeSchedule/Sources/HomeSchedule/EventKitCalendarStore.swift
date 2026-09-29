import Foundation
import HomeCore
#if canImport(EventKit)
import EventKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Live EventKit store (LLD §9.5). Requires full access (iOS 17 `requestFullAccessToEvents`); write-only access
/// cannot find, update or delete events. Google calendars appear as ordinary `EKCalendar`s once the account is
/// added in iOS Settings › Calendar › Accounts (ADR-05).
public final class EventKitCalendarStore: CalendarStoreProtocol, @unchecked Sendable {
    public let store: EKEventStore
    private let calendarProvider: @Sendable () -> Calendar
    private let lock = NSLock()

    public init(store: EKEventStore = EKEventStore(), calendar: @escaping @Sendable () -> Calendar = { RecurrenceEngine.defaultCalendar }) {
        self.store = store
        self.calendarProvider = calendar
    }

    private var cal: Calendar { calendarProvider() }

    // MARK: Access

    public func authorizationStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized        // pre-iOS 17 value; not expected on iOS 17
        @unknown default: return .unknown
        }
    }

    public func requestFullAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        if granted { store.refreshSourcesIfNecessary() }
        return granted
    }

    // MARK: Calendars

    public func writableCalendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications && !$0.isSubscribed && !$0.isImmutable }
            .map(Self.info)
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    public func calendar(id: String) -> CalendarInfo? {
        store.calendar(withIdentifier: id).map(Self.info)
    }

    /// iCloud CalDAV source first, then local. Google (CalDAV, non-iCloud) generally refuses new calendars.
    public func createCalendar(title: String, colorHex: String?) throws -> CalendarInfo {
        let sources = store.sources
        let iCloud = sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
        let local = sources.first { $0.sourceType == .local }
        var lastError: Error = CalendarStoreError.noWritableSource
        for source in [iCloud, local].compactMap({ $0 }) {
            let c = EKCalendar(for: .event, eventStore: store)
            c.title = title
            c.source = source
            #if canImport(CoreGraphics)
            if let hex = colorHex, let color = Self.cgColor(hex: hex) { c.cgColor = color }
            #endif
            do {
                try store.saveCalendar(c, commit: true)
                return Self.info(c)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Events

    public func create(_ spec: CalendarEventSpec, calendarId: String) throws -> ResolvedEvent {
        guard let calendar = store.calendar(withIdentifier: calendarId) else { throw CalendarStoreError.calendarNotFound(calendarId) }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        try apply(spec, to: event)
        try store.save(event, span: .futureEvents, commit: true)
        return resolved(event, today: spec.startDay)
    }

    public func resolve(_ loc: EventLocator) -> ResolvedEvent? {
        guard let (event, isFuture) = resolveEvent(loc) else { return nil }
        var r = resolved(event, today: loc.today)
        r.isFuture = isFuture
        return r
    }

    public func update(_ occurrence: ResolvedEvent, url: URL, with spec: CalendarEventSpec) throws -> ResolvedEvent {
        guard let event = occurrenceEvent(occurrence, url: url) else { throw CalendarStoreError.eventNotFound }
        try apply(spec, to: event)
        try store.save(event, span: .futureEvents, commit: true)
        return resolved(event, today: spec.startDay)
    }

    public func removeFuture(_ occurrence: ResolvedEvent, url: URL) throws {
        guard let event = occurrenceEvent(occurrence, url: url) else { return }
        try store.remove(event, span: .futureEvents, commit: true)
    }

    // MARK: Helpers

    private func apply(_ spec: CalendarEventSpec, to event: EKEvent) throws {
        let c = cal
        guard let start = spec.startDate(calendar: c), let end = spec.endDate(calendar: c) else {
            throw CalendarStoreError.saveFailed("invalid date")
        }
        event.title = spec.title
        event.notes = spec.notes
        event.url = spec.url
        event.isAllDay = spec.isAllDay
        event.timeZone = nil                       // floating (ADR-18)
        event.startDate = start
        event.endDate = end
        if let r = spec.recurrence {
            event.recurrenceRules = [r.ekRule(calendar: c)]
        } else if event.hasRecurrenceRules {
            event.recurrenceRules = nil
        }
        if let offset = spec.alarmOffsetMinutes {
            event.alarms = [EKAlarm(relativeOffset: -TimeInterval(offset * 60))]
        } else {
            event.alarms = nil
        }
    }

    /// Steps 1–3 of LLD §9.5 resolution. Returns the earliest occurrence on/after today, else the base event (past).
    private func resolveEvent(_ loc: EventLocator) -> (EKEvent, Bool)? {
        var base: EKEvent?
        if let id = loc.eventIdentifier, let e = store.event(withIdentifier: id), e.url == loc.url { base = e }
        if base == nil, let ext = loc.externalId {
            base = store.calendarItems(withExternalIdentifier: ext).compactMap { $0 as? EKEvent }.first { $0.url == loc.url }
        }
        var calendars: [EKCalendar] = []
        if let c = base?.calendar { calendars = [c] }
        else if let id = loc.calendarId, let c = store.calendar(withIdentifier: id) { calendars = [c] }
        guard !calendars.isEmpty else { return nil }

        let c = cal
        guard let todayStart = loc.today.date(atMinutes: 0, calendar: c),
              let windowEnd = loc.today.adding(days: 400).date(atMinutes: 0, calendar: c),
              let pastStart = loc.today.adding(days: -7).date(atMinutes: 0, calendar: c) else { return nil }
        let future = store.events(matching: store.predicateForEvents(withStart: todayStart, end: windowEnd, calendars: calendars))
            .filter { $0.url == loc.url && $0.startDate >= todayStart }
            .sorted { $0.startDate < $1.startDate }
        if let next = future.first { return (next, true) }
        if let base { return (base, base.startDate >= todayStart) }
        let past = store.events(matching: store.predicateForEvents(withStart: pastStart, end: todayStart, calendars: calendars))
            .filter { $0.url == loc.url }
            .sorted { $0.startDate < $1.startDate }
        return past.last.map { ($0, false) }
    }

    /// Re-fetches the specific occurrence instance (occurrences share `eventIdentifier`).
    private func occurrenceEvent(_ occ: ResolvedEvent, url: URL) -> EKEvent? {
        guard let calendar = store.calendar(withIdentifier: occ.calendarId) else {
            return store.event(withIdentifier: occ.eventIdentifier)
        }
        let start = occ.occurrenceStart.addingTimeInterval(-36 * 3600)
        let end = occ.occurrenceStart.addingTimeInterval(36 * 3600)
        let matches = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
            .filter { $0.url == url }
        return matches.first { $0.eventIdentifier == occ.eventIdentifier && abs($0.startDate.timeIntervalSince(occ.occurrenceStart)) < 60 }
            ?? matches.min { abs($0.startDate.timeIntervalSince(occ.occurrenceStart)) < abs($1.startDate.timeIntervalSince(occ.occurrenceStart)) }
            ?? store.event(withIdentifier: occ.eventIdentifier)
    }

    private func resolved(_ e: EKEvent, today: LocalDate) -> ResolvedEvent {
        let c = cal
        let day = LocalDate(e.startDate, calendar: c)
        return ResolvedEvent(eventIdentifier: e.eventIdentifier ?? "", externalId: e.calendarItemExternalIdentifier,
                             calendarId: e.calendar?.calendarIdentifier ?? "", occurrenceStart: e.startDate,
                             occurrenceDay: day, isRecurring: e.hasRecurrenceRules, isFuture: day >= today)
    }

    static func info(_ c: EKCalendar) -> CalendarInfo {
        CalendarInfo(id: c.calendarIdentifier, title: c.title, sourceTitle: sourceTitle(c.source), colorHex: hex(c.cgColor))
    }

    /// "iCloud", "Gmail – you@…", "Exchange", "On My iPhone".
    static func sourceTitle(_ s: EKSource?) -> String {
        guard let s else { return "Other" }
        switch s.sourceType {
        case .local: return "On My iPhone"
        case .exchange: return s.title.isEmpty ? "Exchange" : s.title
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        default:
            return CalendarSourceNaming.displayTitle(sourceTitle: s.title)
        }
    }

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded()), g = Int((comps[1] * 255).rounded()), b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func cgColor(hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
#endif
