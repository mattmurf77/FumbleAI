import Foundation
import XCTest
@testable import HomeCore
import HomeCoreTesting

final class HomeTaskPeriodTests: XCTestCase {
    private let friday = LocalDate(2026, 11, 6)
    private let propertyID = UUID()
    private func calendar(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func task(_ title: String, due: LocalDate?, rule: RepeatRule? = nil) -> Chore {
        Chore(propertyId: propertyID, scope: .property, title: title, repeatRule: rule,
              startOn: LocalDate(2025, 1, 1), nextDueOn: due)
    }

    func testWeekRespectsLocalWeekStartOnFridayAndSunday() {
        let sunday = LocalDate(2026, 11, 8)
        let items = [task("Friday", due: friday), task("Saturday", due: friday.adding(days: 1)),
                     task("Sunday", due: sunday), task("Monday", due: sunday.adding(days: 1))]
        XCTAssertEqual(HomeTaskPeriod.week.tasks(items, today: friday, calendar: calendar(firstWeekday: 1)).due.map(\.title),
                       ["Friday", "Saturday"])
        XCTAssertEqual(HomeTaskPeriod.week.tasks(items, today: friday, calendar: calendar(firstWeekday: 2)).due.map(\.title),
                       ["Friday", "Saturday", "Sunday"])
        let endOfWeek = HomeTaskPeriod.week.tasks(items, today: sunday, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(endOfWeek.due.map(\.title), ["Sunday"])
        XCTAssertEqual(endOfWeek.overdue.map(\.title), ["Friday", "Saturday"])
    }

    func testLeapDayAndYearRollover() {
        let cal = calendar(firstWeekday: 2)
        let last = task("Inspect", due: LocalDate(2024, 2, 29)), next = task("March", due: LocalDate(2024, 3, 1))
        XCTAssertEqual(HomeTaskPeriod.month.tasks([next,last], today: LocalDate(2024,2,28), calendar: cal).due.map(\.title), ["Inspect"])
        XCTAssertEqual(HomeTaskPeriod.month.end(from: LocalDate(2025,2,3), calendar: cal), LocalDate(2025,2,28))
        let eve = LocalDate(2026,12,31)
        let close = task("Year end", due: eve), january = task("January", due: eve.adding(days: 1))
        XCTAssertEqual(HomeTaskPeriod.year.tasks([close,january], today: eve, calendar: cal).due.map(\.title), ["Year end"])
        let rolled = HomeTaskPeriod.year.tasks([close,january], today: LocalDate(2027,1,1), calendar: cal)
        XCTAssertEqual(rolled.due.map(\.title), ["January"]); XCTAssertEqual(rolled.overdue.map(\.title), ["Year end"])
    }

    func testDailyFilterSeparatesOverdueAndUsesOnlyNextRecurringOccurrence() {
        let cal = calendar(firstWeekday: 1)
        var morning = task("Check filter", due: friday, rule: .everyNDays(1)); morning.dueMinutes = 480
        var evening = task("Water garden", due: friday); evening.dueMinutes = 1080
        let future = task("Monthly check", due: LocalDate(2027,1,2), rule: .everyNDays(30))
        let late = task("Missed inspection", due: friday.adding(days: -2), rule: .everyNDays(7))
        var paused = task("Paused", due: friday); paused.isPaused = true
        var closed = task("Done", due: friday); closed.closedAt = Date()
        var gone = task("Deleted", due: friday); gone.deletedAt = Date()
        let items = [evening, morning, morning, late, future, paused, closed, gone, task("Unscheduled", due: nil)]
        let result = HomeTaskPeriod.day.tasks(items, today: friday, calendar: cal)
        XCTAssertEqual(result.due.map(\.id), [morning.id, evening.id])
        XCTAssertEqual(result.overdue.map(\.id), [late.id])
        // A daily recurrence is one actionable task even in a year-long view.
        XCTAssertEqual(HomeTaskPeriod.year.tasks(items, today: friday, calendar: cal).due.map(\.id), [morning.id, evening.id])
    }

    func testCompletingRecurringTaskUpdatesItsNextPeriod() async throws {
        let clock = FixedClock(friday)
        let home = InMemoryHome.sample(clock: clock)
        let query = ChoreQuery(propertyId: SampleHome.propertyId)
        let initial = try await home.chores.chores(query)
        let dish = try XCTUnwrap(initial.first { $0.id == SampleHome.dishesId })
        XCTAssertTrue(HomeTaskPeriod.day.tasks(initial, today: clock.today, calendar: clock.calendar).due.contains(dish))
        _ = try await home.chores.complete(dish.id, by: dish.assigneeId, at: clock.now)
        let updated = try await home.chores.chores(query)
        XCTAssertFalse(HomeTaskPeriod.day.tasks(updated, today: clock.today, calendar: clock.calendar).due.contains { $0.id == dish.id })
        let next = HomeTaskPeriod.month.tasks(updated, today: clock.today, calendar: clock.calendar).due.filter { $0.id == dish.id }
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.nextDueOn, friday.adding(days: 1))
    }

    func testEmptyAndOverdueOnly() {
        let cal = calendar(firstWeekday: 2)
        for period in HomeTaskPeriod.allCases {
            let empty = period.tasks([], today: friday, calendar: cal)
            XCTAssertTrue(empty.due.isEmpty); XCTAssertTrue(empty.overdue.isEmpty)
            let overdue = period.tasks([task("Late", due: friday.adding(days: -1))], today: friday, calendar: cal)
            XCTAssertTrue(overdue.due.isEmpty); XCTAssertEqual(overdue.overdue.map(\.title), ["Late"])
        }
    }
}
