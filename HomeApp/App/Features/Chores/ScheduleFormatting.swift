import SwiftUI
import HomeCore
#if canImport(UIKit)
import UIKit
#endif

/// Display helpers shared by the Chores, Projects and Budget features.
enum ScheduleFormat {
    static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// "Fri, Oct 2" (adds the year when it differs from `today`).
    static func day(_ d: LocalDate, today: LocalDate? = nil) -> String {
        var s = "\(shortWeekdays[d.weekday - 1]), \(shortMonths[d.month - 1]) \(d.day)"
        if let today, today.year != d.year { s += ", \(d.year)" }
        return s
    }

    /// "Sep 20, 2026".
    static func longDay(_ d: LocalDate) -> String { "\(shortMonths[d.month - 1]) \(d.day), \(d.year)" }

    /// "Today", "Tomorrow", "Yesterday", "in 3 days", "3 days ago".
    static func relative(_ d: LocalDate, today: LocalDate) -> String {
        let n = today.days(until: d)
        switch n {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...: return "in \(n) days"
        default: return "\(-n) days ago"
        }
    }

    /// "7:00 PM" for minutes after midnight.
    static func time(_ minutes: MinuteOfDay) -> String {
        let h = (minutes / 60) % 24, m = minutes % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    /// Due line for a chore: "Due Fri, Oct 2 · 7:00 PM", "Overdue since Sep 26", "No due date".
    static func due(_ chore: Chore, today: LocalDate) -> String {
        if chore.isPaused { return "Paused" }
        guard let d = chore.nextDueOn else { return chore.closedAt != nil ? "Done" : "No due date" }
        let time = chore.dueMinutes.map { " · " + ScheduleFormat.time($0) } ?? ""
        if d < today { return "Overdue since \(shortMonths[d.month - 1]) \(d.day)" }
        if d == today { return "Due today" + time }
        if d == today.adding(days: 1) { return "Due tomorrow" + time }
        return "Due \(day(d, today: today))" + time
    }

    static func hours(_ h: Double?) -> String? {
        guard let h, h > 0 else { return nil }
        return h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }

    static func money(_ m: Money?) -> String { (m ?? .zero()).formatted(showCents: false) }

    /// "+$612 over" / "$200 under" / "On budget".
    static func variance(_ cents: Int64, currency: String) -> String {
        if cents == 0 { return "On budget" }
        let m = Money(cents: abs(cents), currency: currency).formatted(showCents: false)
        return cents > 0 ? "+\(m) over" : "\(m) under"
    }

    /// Reminder offset labels (FR-CHR-01): at time, 15 min, 1 h, 1 day before.
    static let reminderOffsets: [(minutes: Int, label: String)] = [
        (0, "At time of event"), (15, "15 minutes before"), (60, "1 hour before"), (1440, "1 day before"),
    ]
    static func offsetLabel(_ m: Int) -> String {
        reminderOffsets.first { $0.minutes == m }?.label ?? "\(m) minutes before"
    }
}

/// Converting between floating `LocalDate` / `MinuteOfDay` and `Date` for pickers, in the app clock's calendar.
extension Binding where Value == LocalDate {
    func scheduleDate(_ calendar: Calendar) -> Binding<Date> {
        Binding<Date>(
            get: { wrappedValue.date(atMinutes: 12 * 60, calendar: calendar) ?? Date() },
            set: { wrappedValue = LocalDate($0, calendar: calendar) })
    }
}

extension Binding where Value == MinuteOfDay {
    func scheduleTime(_ calendar: Calendar) -> Binding<Date> {
        Binding<Date>(
            get: {
                let start = calendar.startOfDay(for: Date())
                return calendar.date(byAdding: .minute, value: wrappedValue, to: start) ?? start
            },
            set: {
                let c = calendar.dateComponents([.hour, .minute], from: $0)
                wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// Names for scopes ("Kitchen", "1st Floor", "Whole house") loaded once per screen.
struct SchedulePlaceNames: Equatable {
    var spaces: [UUID: String] = [:]
    var levels: [UUID: String] = [:]

    func name(_ scope: Scope) -> String {
        switch scope {
        case .space(let s, _): return spaces[s] ?? "Room"
        case .level(let l): return levels[l].map { "\($0) (whole floor)" } ?? "This floor"
        case .property: return "Whole house"
        }
    }

    /// "Basement · Utility".
    func path(_ scope: Scope) -> String {
        switch scope {
        case .space(let s, let l): return [levels[l], spaces[s]].compactMap { $0 }.joined(separator: " · ")
        case .level(let l): return levels[l] ?? "This floor"
        case .property: return "Whole house"
        }
    }

    @MainActor
    static func load(_ env: AppEnvironment, property: UUID) async -> SchedulePlaceNames {
        var n = SchedulePlaceNames()
        if let spaces = try? await env.plan.spaces(property: property) {
            for s in spaces where s.deletedAt == nil { n.spaces[s.id] = s.name }
        }
        if let levels = try? await env.plan.levels(property: property) {
            for l in levels where l.deletedAt == nil { n.levels[l.id] = l.name }
        }
        return n
    }
}

/// Opens the iOS Settings page for this app ("Open Settings" links).
struct ScheduleSettingsLink: View {
    var title = "Open Settings"
    var body: some View {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link(title, destination: url)
        }
        #else
        EmptyView()
        #endif
    }
}
