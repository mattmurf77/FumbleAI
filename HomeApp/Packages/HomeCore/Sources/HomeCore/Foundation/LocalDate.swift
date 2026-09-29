import Foundation

/// A floating calendar date `YYYY-MM-DD` with no time zone (chore due dates, purchase dates, warranty end,
/// expiry). LLD §1. Day arithmetic is pure (proleptic Gregorian), so it is immune to DST.
/// Codable as the string `"YYYY-MM-DD"`.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    /// Creates a date, clamping the day to the month's length (e.g. Feb 31 → Feb 28/29).
    public init(year: Int, month: Int, day: Int) {
        let m = min(max(month, 1), 12)
        self.year = year
        self.month = m
        self.day = min(max(day, 1), LocalDate.daysInMonth(year: year, month: m))
    }

    public init(_ year: Int, _ month: Int, _ day: Int) { self.init(year: year, month: month, day: day) }

    /// Parses `"YYYY-MM-DD"`; returns nil for malformed or out-of-range input.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= LocalDate.daysInMonth(year: y, month: m) else { return nil }
        self.year = y; self.month = m; self.day = d
    }

    /// The local calendar date of `date` in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public init(daysSinceEpoch: Int) {
        // Howard Hinnant's civil_from_days.
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.year = m <= 2 ? y + 1 : y
        self.month = m
        self.day = d
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    public var daysSinceEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// 1 = Sunday … 7 = Saturday (same convention as `Calendar.weekday`).
    public var weekday: Int {
        let d = daysSinceEpoch  // 1970-01-01 was a Thursday (5)
        return ((d % 7 + 7) % 7 + 4) % 7 + 1
    }

    public func adding(days n: Int) -> LocalDate { LocalDate(daysSinceEpoch: daysSinceEpoch + n) }

    /// Adds months, clamping the day to the target month's length (Jan 31 + 1 month = Feb 28/29).
    public func adding(months n: Int) -> LocalDate {
        let total = year * 12 + (month - 1) + n
        let y = Int((Double(total) / 12).rounded(.down))
        let m = total - y * 12 + 1
        return LocalDate(year: y, month: m, day: day)
    }

    public func days(until other: LocalDate) -> Int { other.daysSinceEpoch - daysSinceEpoch }

    public var lastDayOfMonth: Int { LocalDate.daysInMonth(year: year, month: month) }
    public var monthIndex: Int { year * 12 + (month - 1) }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 30
        }
    }

    /// The instant this date + `minutes` after midnight occurs in `calendar`'s time zone.
    public func date(atMinutes minutes: Int = 0, calendar: Calendar) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = minutes / 60; c.minute = minutes % 60
        return calendar.date(from: c)
    }

    /// Floating date components (no time zone) for UNCalendarNotificationTrigger / EventKit.
    public func components(atMinutes minutes: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: minutes / 60, minute: minutes % 60)
    }

    public static func today(_ clock: Clock) -> LocalDate { LocalDate(clock.now, calendar: clock.calendar) }

    public var description: String {
        let y = String(format: "%04d", year), m = String(format: "%02d", month), d = String(format: "%02d", day)
        return "\(y)-\(m)-\(d)"
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

extension LocalDate: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = LocalDate(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid LocalDate '\(s)'")
        }
        self = d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Minutes after local midnight (0–1439). LLD §1 "Time of day".
public typealias MinuteOfDay = Int
