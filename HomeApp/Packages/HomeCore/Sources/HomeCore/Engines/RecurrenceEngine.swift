import Foundation

/// Pure recurrence math. LLD §9.2. The calendar is injected only for `firstWeekday`; date arithmetic is on
/// floating `LocalDate`s, so results never shift with DST or time zones.
public struct RecurrenceEngine: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = RecurrenceEngine.defaultCalendar) { self.calendar = calendar }

    public static var defaultCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// Schedule-anchored occurrences on or after `max(from, start)`, ascending, ending at `rule.until` (lazy, may be infinite).
    public func occurrences(of rule: RepeatRule, start: LocalDate, from: LocalDate) -> OccurrenceSequence {
        OccurrenceSequence(rule: rule, start: start, from: max(from, start), firstWeekday: calendar.firstWeekday)
    }

    /// First due date for a new chore: one-off → start; completion-anchored → start; schedule → first occurrence ≥ start.
    public func firstDue(rule: RepeatRule?, start: LocalDate) -> LocalDate? {
        guard let rule else { return start }
        let d: LocalDate?
        switch rule.anchor {
        case .completion: d = start
        case .schedule: d = occurrences(of: rule, start: start, from: start).first(where: { _ in true })
        }
        guard let d else { return nil }
        if let until = rule.until, d > until { return nil }
        return d
    }

    /// Next due after an action (done or skip). `currentDue` = chore.next_due_on before the action.
    /// Returns nil when the series is finished (caller sets closed_at).
    public func nextDue(rule: RepeatRule, start: LocalDate, currentDue: LocalDate, actedOn: LocalDate) -> LocalDate? {
        let d: LocalDate?
        switch rule.anchor {
        case .completion:
            let base = actedOn
            switch rule.freq {
            case .daily, .everyNDays: d = base.adding(days: rule.interval)
            case .weekly: d = base.adding(days: 7 * rule.interval)
            case .monthly: d = base.adding(months: rule.interval)
            }
        case .schedule:
            let pivot = max(currentDue, actedOn)          // collapse missed occurrences
            d = occurrences(of: rule, start: start, from: pivot.adding(days: 1)).first(where: { _ in true })
        }
        guard let d else { return nil }
        if let until = rule.until, d > until { return nil }
        return d
    }
}

/// Lazy ascending sequence of schedule-anchored occurrences.
public struct OccurrenceSequence: Sequence, Sendable {
    public let rule: RepeatRule
    public let start: LocalDate
    public let from: LocalDate
    public let firstWeekday: Int

    /// Hard stop to keep accidental infinite loops bounded (~200 years).
    static let maxSpanDays = 365 * 200

    public func makeIterator() -> Iterator { Iterator(self) }

    public struct Iterator: IteratorProtocol, Sendable {
        let s: OccurrenceSequence
        var k: Int = 0                       // daily: step index; weekly: week index; monthly: month step index
        var weekOffsets: [Int] = []
        var offsetIdx: Int = 0
        var done = false

        init(_ s: OccurrenceSequence) {
            self.s = s
            let lower = s.from
            switch s.rule.freq {
            case .daily, .everyNDays:
                let diff = s.start.days(until: lower)
                k = diff <= 0 ? 0 : (diff + s.rule.interval - 1) / s.rule.interval
            case .weekly:
                let wd = (s.rule.weekdays?.isEmpty == false ? s.rule.weekdays! : [s.start.weekday]).filter { (1...7).contains($0) }
                weekOffsets = Array(Set(wd.map { ($0 - s.firstWeekday + 7) % 7 })).sorted()
                let ws0 = Iterator.weekStart(s.start, s.firstWeekday)
                let wl = Iterator.weekStart(lower, s.firstWeekday)
                let weeks = Swift.max(0, ws0.days(until: wl) / 7)
                k = (weeks / s.rule.interval) * s.rule.interval
            case .monthly:
                let diff = lower.monthIndex - s.start.monthIndex
                k = diff <= 0 ? 0 : diff / s.rule.interval
            }
        }

        static func weekStart(_ d: LocalDate, _ firstWeekday: Int) -> LocalDate {
            d.adding(days: -((d.weekday - firstWeekday + 7) % 7))
        }

        public mutating func next() -> LocalDate? {
            guard !done else { return nil }
            let limit = s.from.adding(days: OccurrenceSequence.maxSpanDays)
            while true {
                let candidate: LocalDate
                switch s.rule.freq {
                case .daily, .everyNDays:
                    candidate = s.start.adding(days: k * s.rule.interval)
                    k += 1
                case .weekly:
                    guard !weekOffsets.isEmpty else { done = true; return nil }
                    let ws0 = Iterator.weekStart(s.start, s.firstWeekday)
                    candidate = ws0.adding(days: 7 * k + weekOffsets[offsetIdx])
                    offsetIdx += 1
                    if offsetIdx == weekOffsets.count { offsetIdx = 0; k += s.rule.interval }
                case .monthly:
                    let m = s.start.adding(months: 0)
                    let target = LocalDate(year: m.year, month: m.month, day: 1).adding(months: k * s.rule.interval)
                    let dom = s.rule.dayOfMonth ?? s.start.day
                    let last = target.lastDayOfMonth
                    candidate = LocalDate(year: target.year, month: target.month, day: dom == -1 ? last : Swift.min(Swift.max(dom, 1), last))
                    k += 1
                }
                if let until = s.rule.until, candidate > until { done = true; return nil }
                if candidate > limit { done = true; return nil }
                if candidate >= s.from && candidate >= s.start { return candidate }
            }
        }
    }
}
