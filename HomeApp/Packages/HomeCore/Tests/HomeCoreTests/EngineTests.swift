import XCTest
import PlanKit
@testable import HomeCore

final class RecurrenceTests: XCTestCase {
    var engine: RecurrenceEngine {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return RecurrenceEngine(calendar: c)
    }

    func testRuleJSONMatchesLLDExamples() throws {
        XCTAssertEqual(try HomeJSON.encodeString(RepeatRule.daily), #"{"anchor":"schedule","freq":"daily","interval":1}"#)
        XCTAssertEqual(try HomeJSON.encodeString(RepeatRule.weekly([3, 6])), #"{"anchor":"schedule","freq":"weekly","interval":1,"weekdays":[3,6]}"#)
        XCTAssertEqual(try HomeJSON.encodeString(RepeatRule.everyNDays(90)), #"{"anchor":"completion","freq":"everyNDays","interval":90}"#)
        let r = try HomeJSON.decode(RepeatRule.self, from: #"{"freq":"monthly","interval":12,"dayOfMonth":1,"anchor":"schedule"}"#)
        XCTAssertEqual(r, .monthly(day: 1, every: 12))
        XCTAssertEqual(r.humanText, "Every year on day 1")
        XCTAssertEqual(RepeatRule.everyNDays(90).humanText, "Every 90 days after done")
        XCTAssertEqual(RepeatRule.weekly([6, 3]).humanText, "Every week on Tue, Fri")
    }

    func testDailyAcrossDST() {
        let occ = Array(engine.occurrences(of: .daily, start: LocalDate(2026, 3, 6), from: LocalDate(2026, 3, 7)).prefix(3))
        XCTAssertEqual(occ, [LocalDate(2026, 3, 7), LocalDate(2026, 3, 8), LocalDate(2026, 3, 9)])
        let fall = Array(engine.occurrences(of: .daily, start: LocalDate(2026, 10, 31), from: LocalDate(2026, 11, 1)).prefix(2))
        XCTAssertEqual(fall, [LocalDate(2026, 11, 1), LocalDate(2026, 11, 2)])
    }

    func testWeeklyMultipleWeekdaysAndInterval() {
        // Start Mon 2026-09-28; Tue(3) + Fri(6).
        let occ = Array(engine.occurrences(of: .weekly([3, 6]), start: LocalDate(2026, 9, 28), from: LocalDate(2026, 9, 28)).prefix(4))
        XCTAssertEqual(occ, [LocalDate(2026, 9, 29), LocalDate(2026, 10, 2), LocalDate(2026, 10, 6), LocalDate(2026, 10, 9)])
        let biweekly = Array(engine.occurrences(of: .weekly([2], every: 2), start: LocalDate(2026, 9, 28), from: LocalDate(2026, 10, 1)).prefix(2))
        XCTAssertEqual(biweekly, [LocalDate(2026, 10, 12), LocalDate(2026, 10, 26)])
        // Default weekday = start's weekday.
        let dflt = Array(engine.occurrences(of: RepeatRule(freq: .weekly), start: LocalDate(2026, 9, 30), from: LocalDate(2026, 9, 30)).prefix(2))
        XCTAssertEqual(dflt, [LocalDate(2026, 9, 30), LocalDate(2026, 10, 7)])
    }

    func testMonthlyClampLastDayAndLeapYear() {
        let r31 = RepeatRule.monthly(day: 31)
        let occ = Array(engine.occurrences(of: r31, start: LocalDate(2026, 1, 31), from: LocalDate(2026, 1, 1)).prefix(4))
        XCTAssertEqual(occ, [LocalDate(2026, 1, 31), LocalDate(2026, 2, 28), LocalDate(2026, 3, 31), LocalDate(2026, 4, 30)])
        let last = Array(engine.occurrences(of: .monthly(day: -1), start: LocalDate(2028, 1, 10), from: LocalDate(2028, 1, 10)).prefix(2))
        XCTAssertEqual(last, [LocalDate(2028, 1, 31), LocalDate(2028, 2, 29)])
        let yearly = Array(engine.occurrences(of: .monthly(day: 29, every: 12), start: LocalDate(2024, 2, 29), from: LocalDate(2024, 3, 1)).prefix(2))
        XCTAssertEqual(yearly, [LocalDate(2025, 2, 28), LocalDate(2026, 2, 28)])
    }

    func testUntilBoundary() {
        let r = RepeatRule(freq: .daily, until: LocalDate(2026, 1, 3))
        XCTAssertEqual(Array(engine.occurrences(of: r, start: LocalDate(2026, 1, 1), from: LocalDate(2026, 1, 1))),
                       [LocalDate(2026, 1, 1), LocalDate(2026, 1, 2), LocalDate(2026, 1, 3)])
        XCTAssertEqual(engine.nextDue(rule: r, start: LocalDate(2026, 1, 1), currentDue: LocalDate(2026, 1, 2), actedOn: LocalDate(2026, 1, 2)),
                       LocalDate(2026, 1, 3))
        XCTAssertNil(engine.nextDue(rule: r, start: LocalDate(2026, 1, 1), currentDue: LocalDate(2026, 1, 3), actedOn: LocalDate(2026, 1, 3)))
    }

    func testNextDueScheduleEarlyLateAndCollapsed() {
        let start = LocalDate(2026, 9, 1)
        // Early: completing Tue's trash on Mon → Tue stays? No: pivot = max(currentDue, actedOn) = Tue → next is Fri.
        XCTAssertEqual(engine.nextDue(rule: .weekly([3, 6]), start: start, currentDue: LocalDate(2026, 9, 29), actedOn: LocalDate(2026, 9, 28)),
                       LocalDate(2026, 10, 2))
        // Late mid-week: due Tue, done Thu → Fri.
        XCTAssertEqual(engine.nextDue(rule: .weekly([3, 6]), start: start, currentDue: LocalDate(2026, 9, 29), actedOn: LocalDate(2026, 10, 1)),
                       LocalDate(2026, 10, 2))
        // Daily, 3 cycles late → tomorrow (no stacking).
        XCTAssertEqual(engine.nextDue(rule: .daily, start: start, currentDue: LocalDate(2026, 9, 26), actedOn: LocalDate(2026, 9, 29)),
                       LocalDate(2026, 9, 30))
    }

    func testNextDueCompletionAnchored() {
        XCTAssertEqual(engine.nextDue(rule: .everyNDays(90), start: LocalDate(2026, 1, 1), currentDue: LocalDate(2026, 6, 1), actedOn: LocalDate(2026, 6, 10)),
                       LocalDate(2026, 9, 8))
        XCTAssertEqual(engine.nextDue(rule: RepeatRule(freq: .monthly, interval: 1, anchor: .completion), start: LocalDate(2026, 1, 1),
                                      currentDue: LocalDate(2026, 1, 31), actedOn: LocalDate(2026, 1, 31)), LocalDate(2026, 2, 28))
        XCTAssertEqual(engine.firstDue(rule: .everyNDays(90), start: LocalDate(2026, 1, 5)), LocalDate(2026, 1, 5))
        XCTAssertEqual(engine.firstDue(rule: .weekly([6]), start: LocalDate(2026, 9, 28)), LocalDate(2026, 10, 2))
        XCTAssertEqual(engine.firstDue(rule: nil, start: LocalDate(2026, 9, 28)), LocalDate(2026, 9, 28))
    }

    func testChoreLogic() {
        let cal = engine.calendar
        let at = LocalDate(2026, 9, 29).date(atMinutes: 600, calendar: cal)!
        let oneOff = Chore(propertyId: UUID(), scope: .property, title: "Gutters", startOn: LocalDate(2026, 9, 29), nextDueOn: LocalDate(2026, 9, 29))
        let (closed, comp) = ChoreLogic.act(on: oneOff, outcome: .done, by: nil, at: at, calendar: cal, engine: engine)
        XCTAssertNotNil(closed.closedAt); XCTAssertNil(closed.nextDueOn)
        XCTAssertEqual(comp.dueOn, LocalDate(2026, 9, 29)); XCTAssertEqual(comp.doneOn, LocalDate(2026, 9, 29))

        let daily = Chore(propertyId: UUID(), scope: .property, title: "Dishes", repeatRule: .daily, startOn: LocalDate(2026, 9, 1), nextDueOn: LocalDate(2026, 9, 26))
        let (advanced, _) = ChoreLogic.act(on: daily, outcome: .skipped, by: nil, at: at, calendar: cal, engine: engine)
        XCTAssertEqual(advanced.nextDueOn, LocalDate(2026, 9, 30)); XCTAssertNil(advanced.closedAt)

        let recomputed = ChoreLogic.recomputeNextDue(daily, completions: [comp].map { var c = $0; c.choreId = daily.id; return c }, engine: engine)
        XCTAssertEqual(recomputed.nextDueOn, LocalDate(2026, 9, 30))
    }
}

final class NotificationPlannerTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    var today: LocalDate { LocalDate(2026, 9, 29) }
    var now: Date { today.date(atMinutes: 8 * 60, calendar: calendar)! }
    var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }

    func testOverdueScheduleAndCompletionAnchored() {
        let overdue = ChoreReminderInput(choreId: UUID(), title: "Filter", nextDueOn: today.adding(days: -3), rule: .everyNDays(90), startOn: LocalDate(2026, 6, 1))
        let daily = ChoreReminderInput(choreId: UUID(), title: "Dishes", location: "Kitchen", nextDueOn: today, dueMinutes: 20 * 60, rule: .daily, startOn: LocalDate(2026, 9, 1))
        let plan = NotificationPlanner().plan(chores: [overdue, daily], snoozes: [], pantryDigest: nil, now: now, calendar: calendar, engine: engine)
        let o = plan.first { $0.id == PlannedNotification.overdueId(overdue.choreId) }!
        XCTAssertEqual(o.title, "Overdue: Filter")
        XCTAssertEqual(o.fire.day, 29); XCTAssertEqual(o.fire.hour, 9)
        let dailies = plan.filter { $0.choreId == daily.choreId }
        XCTAssertEqual(dailies.count, 14, "per-chore max within 14-day horizon")
        XCTAssertEqual(dailies.first?.id, PlannedNotification.choreId(daily.choreId, due: today))
        XCTAssertEqual(dailies.first?.body, "Kitchen · Due today")
        XCTAssertNil(dailies.first?.fire.timeZone)
        XCTAssertEqual(plan.map(\.id).count, Set(plan.map(\.id)).count)
        XCTAssertFalse(plan.contains { $0.id == PlannedNotification.sentinelId })
    }

    func testFairnessCapAndSentinel() {
        let chores = (0..<10).map { i in
            ChoreReminderInput(choreId: UUID(), title: "Chore \(i)", nextDueOn: today.adding(days: 1), dueMinutes: 600 + i, rule: .daily, startOn: today)
        }
        let plan = NotificationPlanner().plan(chores: chores, snoozes: [], pantryDigest: PantryDigest(expiringCount: 2),
                                              now: now, calendar: calendar, engine: engine)
        let choreNotes = plan.filter { $0.id.hasPrefix("chore:") }
        XCTAssertEqual(choreNotes.count, 60)
        for c in chores { XCTAssertEqual(choreNotes.filter { $0.choreId == c.choreId }.count, 6) }
        XCTAssertTrue(plan.contains { $0.id == PlannedNotification.sentinelId })
        XCTAssertTrue(plan.contains { $0.id == PlannedNotification.pantryDigestId })
        XCTAssertLessThanOrEqual(plan.count, NotificationPlanner.iOSLimit)
        let fires = choreNotes.map { calendar.date(from: $0.fire)! }
        XCTAssertEqual(fires, fires.sorted())
    }

    func testSnoozesAndStableHash() {
        let s = (0..<3).map { Snooze(choreId: UUID(), title: "S\($0)", fireAt: now.addingTimeInterval(3600), createdAt: now.addingTimeInterval(Double($0))) }
        let plan = NotificationPlanner().plan(chores: [], snoozes: s, pantryDigest: nil, now: now, calendar: calendar, engine: engine)
        XCTAssertEqual(plan.map(\.id), ["sys:snooze-1", "sys:snooze-2"])
        XCTAssertEqual(plan.map(\.title), ["S1", "S2"])
        XCTAssertEqual(PlannedNotification.stableHash("abc"), PlannedNotification.stableHash("abc"))
        XCTAssertEqual(PlannedNotification.stableHash(""), Int(truncatingIfNeeded: UInt64(0xcbf29ce484222325)))
    }

    func testRemindOffsetCrossesMidnight() {
        let c = ChoreReminderInput(choreId: UUID(), title: "Trash", nextDueOn: today.adding(days: 2), dueMinutes: 60, remindOffsetMin: 120, startOn: today)
        let plan = NotificationPlanner().plan(chores: [c], snoozes: [], pantryDigest: nil, now: now, calendar: calendar, engine: engine)
        XCTAssertEqual(plan.first?.fire.day, 30)
        XCTAssertEqual(plan.first?.fire.hour, 23)
        XCTAssertEqual(plan.first?.body, "Due tomorrow")
    }
}

final class FitCheckerTests: XCTestCase {
    let checker = FitChecker()

    func testFridgeTooWideMessage() {
        let fridge = FitPolicy.default(templateKey: "refrigerator", category: .appliance)
        let r = checker.check(item: Dims3(width: 35.75, depth: 30, height: 69), into: Dims3(width: 32, depth: 30, height: 70), policy: fridge)
        XCTAssertEqual(r.overall, .noFit)
        XCTAssertEqual(r.message, "35¾ in wide won't fit the 32 in opening (4¾ in short incl. clearance)")
        guard case .protrudes = r.depth else { return XCTFail("deep fridge protrudes (warning), got \(r.depth)") }
        XCTAssertEqual(r.height, .tight(spare: 0))   // 70 − (69 + 1 in clearance)
    }

    func testTightAndFits() {
        let p = FitPolicy()
        XCTAssertEqual(checker.check(item: Dims3(width: 29.9), into: Dims3(width: 30), policy: p).overall, .tight)
        XCTAssertEqual(checker.check(item: Dims3(width: 20), into: Dims3(width: 30), policy: p).overall, .fits)
        XCTAssertEqual(checker.check(item: Dims3(), into: Dims3(width: 30), policy: p).overall, .unknown)
    }

    func testFurnitureRotates() {
        let sofa = FitPolicy.default(templateKey: "sofa", category: .furniture)
        let r = checker.check(item: Dims3(width: 38, depth: 84), into: Dims3(width: 90, depth: 40), policy: sofa)
        XCTAssertTrue(r.rotated)
        XCTAssertEqual(r.overall, .fits)
        XCTAssertFalse(checker.check(item: Dims3(width: 38, depth: 84), into: Dims3(width: 90, depth: 40), policy: FitPolicy()).overall == .fits)
    }

    func testPassThrough() {
        let door = Dims3(width: 36, height: 80)
        XCTAssertEqual(checker.passThrough(item: Dims3(width: 84, depth: 38, height: 34), door: door).overall, .fits)
        XCTAssertEqual(checker.passThrough(item: Dims3(width: 40, depth: 40, height: 90), door: door).overall, .noFit)
        XCTAssertEqual(checker.passThrough(item: Dims3(width: 35.9, depth: 70, height: 100), door: door).overall, .tight)
        XCTAssertEqual(checker.passThrough(item: Dims3(width: 30), door: door).overall, .unknown)
    }
}

final class RollupTests: XCTestCase {
    func testRollupDefinitions() {
        let pid = UUID(), level = UUID(), room = UUID()
        let planned = Project(propertyId: pid, scope: .space(room, level: level), title: "P", status: .planned, estCost: Money(cents: 1000))
        let idea = Project(propertyId: pid, scope: .level(level), title: "I", status: .idea, estCost: Money(cents: 500))
        var inProg = Project(propertyId: pid, scope: .space(room, level: level), title: "IP", status: .inProgress, estCost: Money(cents: 2000))
        inProg.estHours = 10
        let done = Project(propertyId: pid, scope: .property, title: "D", status: .done, estCost: Money(cents: 3000), completedOn: LocalDate(2026, 3, 1))
        let lines = [CostLineItem(propertyId: pid, projectId: inProg.id, label: "a", amount: Money(cents: 1500), hours: 4),
                     CostLineItem(propertyId: pid, projectId: done.id, label: "b", amount: Money(cents: 3500))]
        let r = RollupMath.rollup([planned, idea, inProg, done], lineItems: lines)
        XCTAssertEqual(r.plannedCents, 3000)
        XCTAssertEqual(r.ideaCents, 500)
        XCTAssertEqual(r.spentCents, 5000)
        XCTAssertEqual(r.remainingCents, 1000 + 500)
        XCTAssertEqual(r.varianceCents, 500)
        XCTAssertEqual(r.lifetimeCents, 3500)
        XCTAssertEqual(r.lastCompletedOn, LocalDate(2026, 3, 1))
        XCTAssertEqual(r.plannedHours, 10); XCTAssertEqual(r.spentHours, 4)
        XCTAssertEqual(r.openCount, 2); XCTAssertEqual(r.inProgressCount, 1)
        let floor = RollupMath.floor(level: level, projects: [planned, idea, inProg, done], lineItems: lines)
        XCTAssertEqual(floor.rooms.plannedCents, 3000); XCTAssertEqual(floor.floorWide.ideaCents, 500)
        XCTAssertEqual(floor.total.openCount, 2)
        XCTAssertEqual(RollupMath.rooms(level: level, projects: [planned, inProg], lineItems: lines)[room]?.plannedCents, 3000)
        // Actual overrides line items.
        var withActual = done; withActual.actualCost = Money(cents: 100)
        XCTAssertEqual(RollupMath.spentCents(withActual, lineItems: lines), 100)
    }

    func testProjectLogic() {
        let p = Project(propertyId: UUID(), scope: .property, title: "x", status: .idea)
        let ip = ProjectLogic.setStatus(p, .inProgress, today: LocalDate(2026, 9, 1))
        XCTAssertEqual(ip.startedOn, LocalDate(2026, 9, 1))
        let done = ProjectLogic.markDone(ip, actual: Money(cents: 5), completedOn: LocalDate(2026, 9, 5), hours: 2)
        XCTAssertEqual(done.status, .done); XCTAssertEqual(done.completedOn, LocalDate(2026, 9, 5))
        let reopened = ProjectLogic.reopen(done, today: LocalDate(2026, 9, 6))
        XCTAssertEqual(reopened.status, .inProgress); XCTAssertNil(reopened.completedOn); XCTAssertEqual(reopened.actualCost, Money(cents: 5))
    }
}
