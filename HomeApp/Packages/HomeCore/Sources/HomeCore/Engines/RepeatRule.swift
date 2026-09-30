import Foundation

/// Repeat rule stored as `chore.repeat_rule_json`. LLD §9.1. A nil rule means a one-off task.
///
/// Examples:
/// `{"anchor":"schedule","freq":"daily","interval":1}` · `{"anchor":"schedule","freq":"weekly","interval":1,"weekdays":[3,6]}` ·
/// `{"anchor":"completion","freq":"everyNDays","interval":90}` · `{"anchor":"schedule","dayOfMonth":-1,"freq":"monthly","interval":1}`
public struct RepeatRule: Codable, Hashable, Sendable {
    public enum Freq: String, Codable, Hashable, Sendable, CaseIterable { case daily, weekly, everyNDays, monthly }
    public enum Anchor: String, Codable, Hashable, Sendable, CaseIterable { case schedule, completion }

    public var freq: Freq
    /// ≥ 1 (every N days / weeks / months).
    public var interval: Int
    /// Weekly only; 1 = Sunday … 7 = Saturday. Default: [weekday(startOn)].
    public var weekdays: [Int]?
    /// Monthly only; 1…31, or -1 = last day. Default: day(startOn).
    public var dayOfMonth: Int?
    /// Default: .schedule, except everyNDays → .completion.
    public var anchor: Anchor
    /// Optional series end (inclusive).
    public var until: LocalDate?

    public init(freq: Freq, interval: Int = 1, weekdays: [Int]? = nil, dayOfMonth: Int? = nil,
                anchor: Anchor? = nil, until: LocalDate? = nil) {
        self.freq = freq
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.anchor = anchor ?? RepeatRule.defaultAnchor(for: freq)
        self.until = until
    }

    public static func defaultAnchor(for f: Freq) -> Anchor { f == .everyNDays ? .completion : .schedule }

    public static let daily = RepeatRule(freq: .daily)
    public static func weekly(_ weekdays: [Int], every n: Int = 1) -> RepeatRule { RepeatRule(freq: .weekly, interval: n, weekdays: weekdays) }
    public static func everyNDays(_ n: Int) -> RepeatRule { RepeatRule(freq: .everyNDays, interval: n) }
    public static func monthly(day: Int, every n: Int = 1) -> RepeatRule { RepeatRule(freq: .monthly, interval: n, dayOfMonth: day) }

    /// Human text used in lists, search and CSV ("Every 90 days after done", "Every week on Tue, Fri").
    public var humanText: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var s: String
        switch freq {
        case .daily: s = interval == 1 ? "Every day" : "Every \(interval) days"
        case .everyNDays: s = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            s = interval == 1 ? "Every week" : "Every \(interval) weeks"
            if let w = weekdays, !w.isEmpty { s += " on " + w.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ") }
        case .monthly:
            if interval == 12 { s = "Every year" } else { s = interval == 1 ? "Every month" : "Every \(interval) months" }
            if let d = dayOfMonth { s += d == -1 ? " on the last day" : " on day \(d)" }
        }
        if anchor == .completion { s += " after done" }
        if let until { s += " until \(until)" }
        return s
    }
}
