import Foundation

/// Calendar periods in the household clock's local time. Overdue tasks are a separate group.
public enum HomeTaskPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, year
    public var id: Self { self }
    public var label: String { rawValue.capitalized }
    public var dueLabel: String { self == .day ? "Due today" : "Due this " + rawValue }

    public func end(from today: LocalDate, calendar: Calendar) -> LocalDate {
        switch self {
        case .day: return today
        case .week:
            let daysSinceWeekStart = (today.weekday - calendar.firstWeekday + 7) % 7
            return today.adding(days: 6 - daysSinceWeekStart)
        case .month: return LocalDate(today.year, today.month, today.lastDayOfMonth)
        case .year: return LocalDate(today.year, 12, 31)
        }
    }

    /// A recurring task appears once under its stored next occurrence. Schedule changes and completions
    /// flow through the repository, so projecting future repeats would double-count work the owner can act on.
    public func tasks(_ chores: [Chore], today: LocalDate, calendar: Calendar) -> PeriodTasks {
        let last = end(from: today, calendar: calendar)
        var due: [Chore] = [], overdue: [Chore] = []
        var seen = Set<UUID>()
        for chore in chores where chore.isOpen {
            guard let date = chore.nextDueOn, seen.insert(chore.id).inserted else { continue }
            if date < today { overdue.append(chore) }
            else if date <= last { due.append(chore) }
        }
        return PeriodTasks(due: due.sorted(by: PeriodTasks.precedes), overdue: overdue.sorted(by: PeriodTasks.precedes))
    }
}

public struct PeriodTasks: Sendable {
    public let due: [Chore]
    public let overdue: [Chore]
    fileprivate static func precedes(_ lhs: Chore, _ rhs: Chore) -> Bool {
        if lhs.nextDueOn != rhs.nextDueOn {
            return (lhs.nextDueOn ?? lhs.startOn) < (rhs.nextDueOn ?? rhs.startOn)
        }
        if lhs.dueMinutes != rhs.dueMinutes { return (lhs.dueMinutes ?? -1) < (rhs.dueMinutes ?? -1) }
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
}
