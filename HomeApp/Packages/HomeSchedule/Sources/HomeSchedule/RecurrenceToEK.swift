import Foundation
import HomeCore
#if canImport(EventKit)
import EventKit
#endif

/// EventKit-free description of an `EKRecurrenceRule` (LLD §9.5 "Rule mapping").
public struct EKRecurrenceSpec: Hashable, Sendable, Codable {
    public enum Frequency: String, Hashable, Sendable, Codable { case daily, weekly, monthly }
    public var frequency: Frequency
    public var interval: Int
    /// Weekly only: 1 = Sunday … 7 = Saturday (== `EKWeekday.rawValue`).
    public var daysOfWeek: [Int]?
    /// Monthly only: 1…31 or -1 (last day; supported by EventKit).
    public var daysOfMonth: [Int]?
    /// Inclusive series end.
    public var end: LocalDate?

    public init(frequency: Frequency, interval: Int, daysOfWeek: [Int]? = nil, daysOfMonth: [Int]? = nil, end: LocalDate? = nil) {
        self.frequency = frequency; self.interval = interval; self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth; self.end = end
    }
}

/// RepeatRule → calendar event shape.
public enum RecurrenceToEK {
    /// Series mode for schedule-anchored rules; single for completion-anchored or one-off.
    public static func mode(for rule: RepeatRule?) -> ChoreCalendarLink.Mode {
        guard let rule, rule.anchor == .schedule else { return .single }
        return .series
    }

    /// nil = no recurrence (single event). `start` supplies default weekday / day-of-month.
    public static func spec(for rule: RepeatRule?, start: LocalDate) -> EKRecurrenceSpec? {
        guard let rule, rule.anchor == .schedule else { return nil }
        let interval = max(1, rule.interval)
        switch rule.freq {
        case .daily, .everyNDays:
            return EKRecurrenceSpec(frequency: .daily, interval: interval, end: rule.until)
        case .weekly:
            let days = (rule.weekdays?.isEmpty == false ? rule.weekdays! : [start.weekday]).filter { (1...7).contains($0) }
            return EKRecurrenceSpec(frequency: .weekly, interval: interval, daysOfWeek: Array(Set(days)).sorted(), end: rule.until)
        case .monthly:
            var day = rule.dayOfMonth ?? start.day
            if day != -1 { day = min(max(day, 1), 31) }
            return EKRecurrenceSpec(frequency: .monthly, interval: interval, daysOfMonth: [day], end: rule.until)
        }
    }
}

#if canImport(EventKit)
public extension EKRecurrenceSpec {
    /// Builds the EventKit rule. `calendar` resolves the inclusive end date to the end of that day.
    func ekRule(calendar: Calendar) -> EKRecurrenceRule {
        let recurrenceEnd: EKRecurrenceEnd? = end.flatMap { d in
            d.date(atMinutes: 23 * 60 + 59, calendar: calendar).map { EKRecurrenceEnd(end: $0) }
        }
        let freq: EKRecurrenceFrequency
        switch frequency { case .daily: freq = .daily; case .weekly: freq = .weekly; case .monthly: freq = .monthly }
        let dow = daysOfWeek?.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
        let dom = daysOfMonth?.map { NSNumber(value: $0) }
        return EKRecurrenceRule(recurrenceWith: freq, interval: interval,
                                daysOfTheWeek: frequency == .weekly ? dow : nil,
                                daysOfTheMonth: frequency == .monthly ? dom : nil,
                                monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                end: recurrenceEnd)
    }
}
#endif

/// Everything written into one calendar event for a chore (LLD §9.5 "Event content").
public struct CalendarEventSpec: Hashable, Sendable {
    public var choreId: UUID
    public var title: String
    public var notes: String
    /// `home://chore/<uuid>` — dedupe key and deep link.
    public var url: URL
    /// First (or only) occurrence day = the chore's current `nextDueOn`.
    public var startDay: LocalDate
    /// nil = all-day.
    public var startMinutes: MinuteOfDay?
    public var durationMinutes: Int
    public var recurrence: EKRecurrenceSpec?
    /// Source rule (kept for fakes and diagnostics).
    public var rule: RepeatRule?
    /// "Also alert from Calendar": `EKAlarm(relativeOffset: -offset*60)`; nil = no alarm.
    public var alarmOffsetMinutes: Int?

    public static let managedFooter = "Managed by Home"
    public static let defaultDurationMinutes = 30

    public var isAllDay: Bool { startMinutes == nil }
    public var mode: ChoreCalendarLink.Mode { recurrence == nil ? .single : .series }

    public init(choreId: UUID, title: String, notes: String, url: URL, startDay: LocalDate, startMinutes: MinuteOfDay?,
                durationMinutes: Int = CalendarEventSpec.defaultDurationMinutes, recurrence: EKRecurrenceSpec?,
                rule: RepeatRule?, alarmOffsetMinutes: Int?) {
        self.choreId = choreId; self.title = title; self.notes = notes; self.url = url; self.startDay = startDay
        self.startMinutes = startMinutes; self.durationMinutes = durationMinutes; self.recurrence = recurrence
        self.rule = rule; self.alarmOffsetMinutes = alarmOffsetMinutes
    }

    /// nil when the chore has no due date (closed).
    public static func make(chore: Chore, alsoAlert: Bool) -> CalendarEventSpec? {
        guard let due = chore.nextDueOn else { return nil }
        let trimmed = (chore.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = trimmed.isEmpty ? managedFooter : trimmed + "\n\n" + managedFooter
        return CalendarEventSpec(choreId: chore.id, title: chore.title, notes: notes, url: chore.deepLink,
                                 startDay: due, startMinutes: chore.dueMinutes,
                                 recurrence: RecurrenceToEK.spec(for: chore.repeatRule, start: chore.startOn),
                                 rule: chore.repeatRule, alarmOffsetMinutes: alsoAlert ? chore.remindOffsetMin : nil)
    }

    /// `series_signature`: changes when anything that must be pushed to the calendar changes. For series the
    /// due date is excluded (completing advances it without touching the series); for single events it's included.
    public var signature: String {
        var parts: [String] = [title, notes, startMinutes.map(String.init) ?? "allday", alarmOffsetMinutes.map(String.init) ?? "-"]
        if let r = recurrence {
            parts.append("\(r.frequency.rawValue)/\(r.interval)/\(r.daysOfWeek ?? [])/\(r.daysOfMonth ?? [])/\(r.end?.description ?? "")")
        } else {
            parts.append("single@\(startDay)")
        }
        let h = PlannedNotification.stableHash(parts.joined(separator: "|"))
        return String(UInt64(bitPattern: Int64(h)), radix: 16)
    }

    /// Start instant in `calendar`'s time zone (all-day: start of day).
    public func startDate(calendar: Calendar) -> Date? { startDay.date(atMinutes: startMinutes ?? 0, calendar: calendar) }

    /// End instant (all-day: same day → start of day; EventKit treats all-day events as whole days).
    public func endDate(calendar: Calendar) -> Date? {
        guard let s = startDate(calendar: calendar) else { return nil }
        return isAllDay ? s : s.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}
