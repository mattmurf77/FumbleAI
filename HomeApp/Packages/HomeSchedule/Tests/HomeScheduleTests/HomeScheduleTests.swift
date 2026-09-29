import XCTest
import HomeCore
@testable import HomeSchedule

final class HomeScheduleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeScheduleModule.name, "HomeSchedule")
    }
}

/// Mutable clock shared by stores and services in a test.
final class TestClock: HomeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    let calendar: Calendar
    init(_ day: LocalDate, minutes: Int = 8 * 60, tz: String = "America/New_York") {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 1
        calendar = c
        _now = day.date(atMinutes: minutes, calendar: c)!
    }
    var now: Date { lock.withLock { _now } }
    func set(_ day: LocalDate, minutes: Int = 8 * 60) { lock.withLock { _now = day.date(atMinutes: minutes, calendar: calendar)! } }
    func advance(days: Int) { lock.withLock { _now = _now.addingTimeInterval(TimeInterval(days) * 86_400) } }
}

// MARK: - RecurrenceToEK / CalendarEventSpec (pure)

final class RecurrenceToEKTests: XCTestCase {
    let start = LocalDate(2026, 9, 29) // Tuesday

    func testDailyAndEveryNDaysSchedule() {
        XCTAssertEqual(RecurrenceToEK.spec(for: .daily, start: start), EKRecurrenceSpec(frequency: .daily, interval: 1))
        let everyThree = RepeatRule(freq: .everyNDays, interval: 3, anchor: .schedule)
        XCTAssertEqual(RecurrenceToEK.spec(for: everyThree, start: start), EKRecurrenceSpec(frequency: .daily, interval: 3))
        XCTAssertEqual(RecurrenceToEK.mode(for: everyThree), .series)
    }

    func testCompletionAnchoredAndOneOffAreSingle() {
        XCTAssertNil(RecurrenceToEK.spec(for: .everyNDays(90), start: start))
        XCTAssertEqual(RecurrenceToEK.mode(for: .everyNDays(90)), .single)
        XCTAssertNil(RecurrenceToEK.spec(for: nil, start: start))
        XCTAssertEqual(RecurrenceToEK.mode(for: nil), .single)
        let dailyAfterDone = RepeatRule(freq: .daily, anchor: .completion)
        XCTAssertNil(RecurrenceToEK.spec(for: dailyAfterDone, start: start))
    }

    func testWeeklyDaysAndDefaultWeekday() {
        let s = RecurrenceToEK.spec(for: .weekly([6, 3, 3], every: 2), start: start)
        XCTAssertEqual(s, EKRecurrenceSpec(frequency: .weekly, interval: 2, daysOfWeek: [3, 6]))
        let d = RecurrenceToEK.spec(for: RepeatRule(freq: .weekly), start: start)
        XCTAssertEqual(d?.daysOfWeek, [3])     // Tuesday from start
    }

    func testMonthlyLastDayYearlyAndUntil() {
        let until = LocalDate(2027, 6, 30)
        let last = RecurrenceToEK.spec(for: RepeatRule(freq: .monthly, dayOfMonth: -1, until: until), start: start)
        XCTAssertEqual(last, EKRecurrenceSpec(frequency: .monthly, interval: 1, daysOfMonth: [-1], end: until))
        let yearly = RecurrenceToEK.spec(for: .monthly(day: 1, every: 12), start: start)
        XCTAssertEqual(yearly?.interval, 12)
        XCTAssertEqual(yearly?.daysOfMonth, [1])
        let dflt = RecurrenceToEK.spec(for: RepeatRule(freq: .monthly), start: LocalDate(2026, 1, 31))
        XCTAssertEqual(dflt?.daysOfMonth, [31])
    }

    func testEventSpecContentAndSignature() {
        let id = UUID()
        var chore = Chore(id: id, propertyId: UUID(), scope: .property, title: "Trash", notes: "Bins at curb",
                          repeatRule: .weekly([3, 6]), startOn: start, nextDueOn: start, dueMinutes: 19 * 60, remindOffsetMin: 15)
        let spec = CalendarEventSpec.make(chore: chore, alsoAlert: false)!
        XCTAssertEqual(spec.notes, "Bins at curb\n\nManaged by Home")
        XCTAssertEqual(spec.url.absoluteString, "home://chore/\(id.uuidString.lowercased())")
        XCTAssertFalse(spec.isAllDay)
        XCTAssertEqual(spec.mode, .series)
        XCTAssertNil(spec.alarmOffsetMinutes)
        XCTAssertEqual(CalendarEventSpec.make(chore: chore, alsoAlert: true)?.alarmOffsetMinutes, 15)

        // Series signature ignores the due date (completing advances it) but tracks time/title/rule/notes.
        var advanced = chore; advanced.nextDueOn = start.adding(days: 3)
        XCTAssertEqual(CalendarEventSpec.make(chore: advanced, alsoAlert: false)?.signature, spec.signature)
        var retimed = chore; retimed.dueMinutes = 20 * 60
        XCTAssertNotEqual(CalendarEventSpec.make(chore: retimed, alsoAlert: false)?.signature, spec.signature)
        // Stable across calls (no per-process hashing).
        XCTAssertEqual(CalendarEventSpec.make(chore: chore, alsoAlert: false)?.signature, spec.signature)

        // Single events include the due date.
        chore.repeatRule = .everyNDays(90)
        chore.dueMinutes = nil
        let single = CalendarEventSpec.make(chore: chore, alsoAlert: false)!
        XCTAssertTrue(single.isAllDay)
        XCTAssertEqual(single.mode, .single)
        var moved = chore; moved.nextDueOn = start.adding(days: 90)
        XCTAssertNotEqual(CalendarEventSpec.make(chore: moved, alsoAlert: false)?.signature, single.signature)

        var closed = chore; closed.nextDueOn = nil
        XCTAssertNil(CalendarEventSpec.make(chore: closed, alsoAlert: false))
    }

    func testCalendarGroupingAndNaming() {
        let cals = [CalendarInfo(id: "3", title: "Work", sourceTitle: "Exchange"),
                    CalendarInfo(id: "2", title: "matt", sourceTitle: CalendarSourceNaming.displayTitle(sourceTitle: "matt@gmail.com")),
                    CalendarInfo(id: "1", title: "Home", sourceTitle: "iCloud"),
                    CalendarInfo(id: "0", title: "Family", sourceTitle: "iCloud")]
        let groups = CalendarGroup.group(cals)
        XCTAssertEqual(groups.map(\.sourceTitle), ["iCloud", "Exchange", "Gmail – matt@gmail.com"])
        XCTAssertEqual(groups[0].calendars.map(\.title), ["Family", "Home"])
        XCTAssertTrue(groups[2].isGoogle)
        XCTAssertEqual(CalendarGroup.existingHome(in: cals)?.id, "1")
    }
}

// MARK: - NotificationDiff (pure)

final class NotificationDiffTests: XCTestCase {
    func note(_ id: String, title: String = "T", day: Int = 1) -> PlannedNotification {
        PlannedNotification(id: id, fire: DateComponents(year: 2026, month: 10, day: day, hour: 9, minute: 0), title: title,
                            body: "b", categoryId: PlannedNotification.choreCategory, threadId: "t")
    }

    func testIdempotentAndChanged() {
        let a = note("chore:a:2026-10-01"), b = note("chore:b:2026-10-02", day: 2)
        let first = NotificationDiff.diff(desired: [a, b], pending: [])
        XCTAssertEqual(first.add.map(\.id), [a.id, b.id])
        XCTAssertTrue(first.remove.isEmpty)

        let pending = [a, b].map { PendingNotification(id: $0.id, contentHash: $0.contentHash) }
        XCTAssertTrue(NotificationDiff.diff(desired: [a, b], pending: pending).isEmpty)

        let b2 = note(b.id, title: "Renamed", day: 2)
        let changed = NotificationDiff.diff(desired: [a, b2], pending: pending)
        XCTAssertEqual(changed.remove, [b.id])
        XCTAssertEqual(changed.add.map(\.title), ["Renamed"])
    }

    func testRemovesStaleButNeverForeignIds() {
        let pending = [PendingNotification(id: "chore:x:2026-10-01", contentHash: 1),
                       PendingNotification(id: "sys:sentinel", contentHash: 2),
                       PendingNotification(id: "someone-else", contentHash: nil)]
        let d = NotificationDiff.diff(desired: [], pending: pending)
        XCTAssertEqual(d.remove, ["chore:x:2026-10-01", "sys:sentinel"])
    }

    func testStaleDelivered() {
        let today = LocalDate(2026, 9, 29)
        let open = Chore(propertyId: UUID(), scope: .property, title: "A", repeatRule: .daily, startOn: today,
                         nextDueOn: today.adding(days: 1), remindEnabled: true)
        var paused = open; paused.id = UUID(); paused.isPaused = true
        let aid = open.id.uuidString.lowercased(), pid = paused.id.uuidString.lowercased()
        let gone = UUID().uuidString.lowercased()
        let delivered = ["chore:\(aid):2026-09-29", "chore:\(aid):2026-09-30", "chore:\(aid):overdue",
                         "chore:\(pid):2026-09-29", "chore:\(gone):2026-09-29", "sys:snooze-1"]
        let stale = NotificationDiff.staleDelivered(delivered, chores: [open, paused], today: today)
        XCTAssertEqual(Set(stale), ["chore:\(aid):2026-09-29", "chore:\(aid):overdue", "chore:\(pid):2026-09-29", "chore:\(gone):2026-09-29"])
    }
}
