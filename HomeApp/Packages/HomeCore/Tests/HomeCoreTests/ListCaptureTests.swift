import XCTest
@testable import HomeCore
import HomeCoreTesting

final class ListCaptureTests: XCTestCase {
    func testDictationSplitsAtCommasAndOxfordAnd() {
        XCTAssertEqual(ListCapture.items(from: "clean gutters, replace furnace filter and call the plumber."),
                       ["Clean gutters", "Replace furnace filter", "Call the plumber"])
        XCTAssertEqual(ListCapture.items(from: "mow the lawn, edge the beds, and water the tomatoes"),
                       ["Mow the lawn", "Edge the beds", "Water the tomatoes"])
    }

    func testSpokenSeparators() {
        XCTAssertEqual(ListCapture.items(from: "fix the fence and then paint the shed next item buy mulch"),
                       ["Fix the fence", "Paint the shed", "Buy mulch"])
    }

    func testSingleItemKeepsItsAnd() {
        XCTAssertEqual(ListCapture.items(from: "wash and dry the patio cushions"), ["Wash and dry the patio cushions"])
    }

    func testNotesChecklist() {
        let notes = """
        Weekend jobs:
        - [ ] Clean gutters
        - [x] Replace smoke detector battery
        • Call roofer, get quote
        1. Buy furnace filters 16x25x1
        2) Seal the deck
        ☐ Prune the maple
        """
        XCTAssertEqual(ListCapture.items(from: notes), [
            "Clean gutters", "Replace smoke detector battery", "Call roofer, get quote",
            "Buy furnace filters 16x25x1", "Seal the deck", "Prune the maple",
        ])
    }

    func testBlankLinesDuplicatesAndLength() {
        let long = String(repeating: "a", count: 300)
        let items = ListCapture.items(from: "\n  clean gutters \n\nClean Gutters\r\n\(long)\n")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], "Clean gutters")
        XCTAssertEqual(items[1].count, ListCapture.maxTitleLength)
        XCTAssertEqual(ListCapture.items(from: "   \n "), [])
    }

    func testNoDueDateDraft() {
        let pid = UUID()
        let today = LocalDate(2026, 9, 30)
        let engine = RecurrenceEngine(calendar: Calendar(identifier: .gregorian))
        let open = ChoreLogic.make(from: ChoreDraft(propertyId: pid, scope: .property, title: "Clean gutters",
                                                    startOn: today, noDueDate: true), now: Date(), engine: engine)
        XCTAssertNil(open.nextDueOn)
        XCTAssertTrue(open.isOpen)
        let dated = ChoreLogic.make(from: ChoreDraft(propertyId: pid, scope: .property, title: "Clean gutters", startOn: today),
                                    now: Date(), engine: engine)
        XCTAssertEqual(dated.nextDueOn, today)
    }
}
