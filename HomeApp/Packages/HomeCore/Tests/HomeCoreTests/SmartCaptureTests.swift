import XCTest
@testable import HomeCore

final class SmartCaptureTests: XCTestCase {
    /// Monday 5 October 2026.
    let today = LocalDate(2026, 10, 5)

    private func one(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SmartCapture.Proposal? {
        let all = SmartCapture.proposals(from: text, today: today)
        XCTAssertEqual(all.count, 1, "expected one item from “\(text)”, got \(all.map(\.title))", file: file, line: line)
        return all.first
    }

    // MARK: The founder's sentences

    func testFounderFenceIdea() throws {
        let p = try XCTUnwrap(one("hey we're thinking of getting a new fence in 3 months & wanna spend 10k, could u put in that idea in"))
        XCTAssertEqual(p.kind, .project)
        XCTAssertEqual(p.title, "New fence")
        XCTAssertEqual(p.amount, Money(cents: 1_000_000))
        XCTAssertEqual(p.date, LocalDate(2027, 1, 5))
        XCTAssertNil(p.repeatRule)
        let draft = p.projectDraft(propertyId: UUID(), scope: .property)
        XCTAssertEqual(draft.status, .idea)
        XCTAssertEqual(draft.estCost, Money(cents: 1_000_000))
        XCTAssertEqual(draft.targetOn, LocalDate(2027, 1, 5))
        XCTAssertEqual(draft.title, "New fence")
    }

    func testFounderFenceIdeaAsDictated() throws {
        // What the iPhone recognizer typically returns for the same words.
        let p = try XCTUnwrap(one("Hey, we’re thinking of getting a new fence in three months and want to spend $10,000. Could you put in that idea?"))
        XCTAssertEqual(p.kind, .project)
        XCTAssertEqual(p.title, "New fence")
        XCTAssertEqual(p.amount, Money(cents: 1_000_000))
        XCTAssertEqual(p.date, LocalDate(2027, 1, 5))
    }

    func testFounderHVACTask() throws {
        let p = try XCTUnwrap(one("add task of changing hvac every 3 months"))
        XCTAssertEqual(p.kind, .todo)
        XCTAssertEqual(p.title, "Change HVAC")
        XCTAssertEqual(p.repeatRule, RepeatRule(freq: .monthly, interval: 3))
        XCTAssertNil(p.amount)
        XCTAssertNil(p.date)
        let draft = p.choreDraft(propertyId: UUID(), scope: .property, today: today)
        XCTAssertEqual(draft.repeatRule, RepeatRule(freq: .monthly, interval: 3))
        XCTAssertEqual(draft.startOn, today)
        XCTAssertFalse(draft.noDueDate)
        XCTAssertEqual(draft.title, "Change HVAC")
    }

    func testHVACFilterTask() throws {
        let p = try XCTUnwrap(one("Add a task to change the HVAC filter every three months."))
        XCTAssertEqual(p.kind, .todo)
        XCTAssertEqual(p.title, "Change the HVAC filter")
        XCTAssertEqual(p.repeatRule, RepeatRule(freq: .monthly, interval: 3))
    }

    // MARK: Kind

    func testKinds() {
        let cases: [(String, SmartCapture.Kind)] = [
            ("clean the gutters", .todo),
            ("remind me to call the plumber tomorrow", .todo),
            ("replace the furnace filter", .todo),
            ("water the plants every week", .todo),
            ("new deck", .project),
            ("remodel the kitchen", .project),
            ("install a heat pump", .project),
            ("replace the roof for 20k", .project),
            ("idea: built-in bookshelves", .project),
            ("paint the bedroom as a project", .project),
            ("buy a new couch as a to-do", .todo),
            ("we're considering solar panels next spring", .project),
        ]
        for (text, kind) in cases {
            XCTAssertEqual(SmartCapture.proposals(from: text, today: today).first?.kind, kind, text)
        }
    }

    func testTodoWithNoDateHasNoDueDate() throws {
        let p = try XCTUnwrap(one("clean the gutters"))
        XCTAssertEqual(p.title, "Clean the gutters")
        let draft = p.choreDraft(propertyId: UUID(), scope: .property, today: today)
        XCTAssertTrue(draft.noDueDate)
        XCTAssertNil(draft.repeatRule)
    }

    func testTodoWithDateIsDueThen() throws {
        let p = try XCTUnwrap(one("remind me to call the plumber tomorrow"))
        XCTAssertEqual(p.title, "Call the plumber")
        XCTAssertEqual(p.date, today.adding(days: 1))
        let draft = p.choreDraft(propertyId: UUID(), scope: .property, today: today)
        XCTAssertFalse(draft.noDueDate)
        XCTAssertEqual(draft.startOn, today.adding(days: 1))
    }

    // MARK: Titles

    func testTitleFillerStripped() {
        let cases: [(String, String)] = [
            ("hey could you add a task to clean the dryer vent please", "Clean the dryer vent"),
            ("can you put in a new mailbox", "New mailbox"),
            ("please add a reminder to test the smoke detectors", "Test the smoke detectors"),
            ("we need a new water heater", "New water heater"),
            ("I'd like to get a new fence", "New fence"),
            ("ok so we're planning to replace the roof", "Replace the roof"),
            ("new project: finish the basement", "Finish the basement"),
            ("don't forget to pay the HOA dues", "Pay the HOA dues"),
            ("thinking about a pergola for the backyard", "Pergola for the backyard"),
            ("um add a to-do of washing the windows", "Wash the windows"),
        ]
        for (text, title) in cases {
            XCTAssertEqual(SmartCapture.proposals(from: text, today: today).first?.title, title, text)
        }
    }

    func testFillerOnlyPiecesFoldIntoNeighbour() {
        let p = SmartCapture.proposals(from: "hey, new patio, budget is 5k, thanks", today: today)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.title, "New patio")
        XCTAssertEqual(p.first?.amount, Money(cents: 500_000))
        XCTAssertEqual(p.first?.kind, .project)
    }

    func testDetailsAfterCommaJoinTheItem() {
        let p = SmartCapture.proposals(from: "change the water filter, every 6 months", today: today)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.repeatRule, RepeatRule(freq: .monthly, interval: 6))
        XCTAssertEqual(p.first?.kind, .todo)
    }

    func testNothingButFiller() {
        XCTAssertTrue(SmartCapture.proposals(from: "hey could you put that in please", today: today).isEmpty)
        XCTAssertTrue(SmartCapture.proposals(from: "   ", today: today).isEmpty)
        XCTAssertNil(SmartCapture.parse("thanks", today: today))
    }

    // MARK: Several items

    func testSeveralItems() {
        let p = SmartCapture.proposals(
            from: "add task of changing hvac every 3 months and also add a new fence for 10k next summer", today: today)
        XCTAssertEqual(p.map(\.title), ["Change HVAC", "New fence"])
        XCTAssertEqual(p.map(\.kind), [.todo, .project])
        XCTAssertEqual(p[1].amount, Money(cents: 1_000_000))
        XCTAssertEqual(p[1].date, LocalDate(2027, 6, 1))
    }

    func testListOfLines() {
        let text = """
        Clean gutters
        Remodel the bathroom for $25,000 by June
        Mow the lawn weekly
        """
        let p = SmartCapture.proposals(from: text, today: today)
        XCTAssertEqual(p.map(\.title), ["Clean gutters", "Remodel the bathroom", "Mow the lawn"])
        XCTAssertEqual(p.map(\.kind), [.todo, .project, .todo])
        XCTAssertEqual(p[1].amount, Money(cents: 2_500_000))
        XCTAssertEqual(p[1].date, LocalDate(2027, 6, 1))
        XCTAssertEqual(p[2].repeatRule, RepeatRule(freq: .weekly, interval: 1))
    }

    // MARK: Money

    func testMoney() {
        let cases: [(String, Int64)] = [
            ("$10k", 1_000_000), ("10k", 1_000_000), ("10K", 1_000_000), ("$10,000", 1_000_000),
            ("10,000 dollars", 1_000_000), ("10000 dollars", 1_000_000), ("ten thousand", 1_000_000),
            ("ten thousand dollars", 1_000_000), ("$1.5k", 150_000), ("5 grand", 500_000), ("five grand", 500_000),
            ("$450", 45_000), ("fifteen hundred bucks", 150_000), ("twenty five thousand", 2_500_000),
            ("a thousand dollars", 100_000), ("$1.2 million", 120_000_000), ("10 thousand", 1_000_000),
            ("spend about 800 bucks", 80_000), ("twenty dollars", 2_000),
        ]
        for (text, cents) in cases {
            XCTAssertEqual(SmartCapture.money(in: text), Money(cents: cents), text)
        }
        XCTAssertNil(SmartCapture.money(in: "a new fence in three months"))
        XCTAssertNil(SmartCapture.money(in: "every 3 months"))
        XCTAssertEqual(SmartCapture.money(in: "$200", currency: "EUR")?.currency, "EUR")
    }

    func testMoneyDoesNotLeaveSpendInTitle() {
        XCTAssertEqual(SmartCapture.parse("new shed and we want to spend around $3k", today: today)?.title, "New shed")
        XCTAssertEqual(SmartCapture.parse("new shed with a budget of 3k", today: today)?.title, "New shed")
    }

    // MARK: Dates

    func testDates() {
        // Monday 2026-10-05.
        let cases: [(String, LocalDate)] = [
            ("in 3 months", LocalDate(2027, 1, 5)),
            ("in three months", LocalDate(2027, 1, 5)),
            ("in two weeks", LocalDate(2026, 10, 19)),
            ("in a couple of weeks", LocalDate(2026, 10, 19)),
            ("in 10 days", LocalDate(2026, 10, 15)),
            ("in a year", LocalDate(2027, 10, 5)),
            ("next month", LocalDate(2026, 11, 5)),
            ("next week", LocalDate(2026, 10, 12)),
            ("next year", LocalDate(2027, 10, 5)),
            ("tomorrow", LocalDate(2026, 10, 6)),
            ("today", LocalDate(2026, 10, 5)),
            ("this weekend", LocalDate(2026, 10, 10)),
            ("next weekend", LocalDate(2026, 10, 17)),
            ("by June", LocalDate(2027, 6, 1)),
            ("in December", LocalDate(2026, 12, 1)),
            ("by october", LocalDate(2026, 10, 5)),
            ("in March 2028", LocalDate(2028, 3, 1)),
            ("next spring", LocalDate(2027, 3, 1)),
            ("this winter", LocalDate(2026, 12, 1)),
            ("on saturday", LocalDate(2026, 10, 10)),
            ("next monday", LocalDate(2026, 10, 12)),
            ("by the end of the month", LocalDate(2026, 10, 31)),
            ("by the end of the year", LocalDate(2026, 12, 31)),
        ]
        for (text, date) in cases {
            XCTAssertEqual(SmartCapture.date(in: text, today: today), date, text)
        }
        XCTAssertNil(SmartCapture.date(in: "we may need a new fence", today: today))
        XCTAssertNil(SmartCapture.date(in: "every 3 months", today: today))
    }

    func testThisWeekendOnSaturdayAndSunday() {
        XCTAssertEqual(SmartCapture.date(in: "this weekend", today: LocalDate(2026, 10, 10)), LocalDate(2026, 10, 10))
        XCTAssertEqual(SmartCapture.date(in: "this weekend", today: LocalDate(2026, 10, 11)), LocalDate(2026, 10, 17))
    }

    // MARK: Recurrence

    func testRecurrence() {
        let cases: [(String, RepeatRule)] = [
            ("every 3 months", RepeatRule(freq: .monthly, interval: 3)),
            ("every three months", RepeatRule(freq: .monthly, interval: 3)),
            ("every month", RepeatRule(freq: .monthly, interval: 1)),
            ("monthly", RepeatRule(freq: .monthly, interval: 1)),
            ("every week", RepeatRule(freq: .weekly, interval: 1)),
            ("weekly", RepeatRule(freq: .weekly, interval: 1)),
            ("every 2 weeks", RepeatRule(freq: .weekly, interval: 2)),
            ("every other week", RepeatRule(freq: .weekly, interval: 2)),
            ("biweekly", RepeatRule(freq: .weekly, interval: 2)),
            ("every year", RepeatRule(freq: .monthly, interval: 12)),
            ("yearly", RepeatRule(freq: .monthly, interval: 12)),
            ("annually", RepeatRule(freq: .monthly, interval: 12)),
            ("once a year", RepeatRule(freq: .monthly, interval: 12)),
            ("twice a year", RepeatRule(freq: .monthly, interval: 6)),
            ("every 90 days", .everyNDays(90)),
            ("every day", .daily),
            ("daily", .daily),
            ("quarterly", RepeatRule(freq: .monthly, interval: 3)),
            ("every quarter", RepeatRule(freq: .monthly, interval: 3)),
            ("every saturday", .weekly([7])),
            ("every fall", RepeatRule(freq: .monthly, interval: 12)),
        ]
        for (text, rule) in cases {
            XCTAssertEqual(SmartCapture.recurrence(in: text), rule, text)
        }
        XCTAssertNil(SmartCapture.recurrence(in: "in 3 months"))
        XCTAssertEqual(RepeatRule(freq: .monthly, interval: 12).humanText, "Every year")
    }

    func testRecurringTodoWithStartDate() throws {
        let p = try XCTUnwrap(one("flush the water heater every year starting next month"))
        XCTAssertEqual(p.kind, .todo)
        XCTAssertEqual(p.title, "Flush the water heater")
        XCTAssertEqual(p.repeatRule, RepeatRule(freq: .monthly, interval: 12))
        XCTAssertEqual(p.date, LocalDate(2026, 11, 5))
    }

    // MARK: Numbers

    func testNumbers() {
        XCTAssertEqual(SmartCapture.number("ten"), 10)
        XCTAssertEqual(SmartCapture.number("twenty-five"), 25)
        XCTAssertEqual(SmartCapture.number("fifteen hundred"), 1500)
        XCTAssertEqual(SmartCapture.number("ten thousand"), 10_000)
        XCTAssertEqual(SmartCapture.number("a couple of"), 2)
        XCTAssertEqual(SmartCapture.number("42"), 42)
        XCTAssertNil(SmartCapture.number("fence"))
    }

    // MARK: Drafts

    func testProjectDraftDropsZeroAmountAndTodoKeepsBudgetInNotes() {
        let project = SmartCapture.Proposal(kind: .project, title: "Patio", amount: .zero())
        XCTAssertNil(project.projectDraft(propertyId: UUID(), scope: .property).estCost)
        let todo = SmartCapture.Proposal(kind: .todo, title: "Buy mulch", amount: Money(cents: 20_000))
        XCTAssertEqual(todo.choreDraft(propertyId: UUID(), scope: .property, today: today).notes, "Budget: $200")
    }
}
