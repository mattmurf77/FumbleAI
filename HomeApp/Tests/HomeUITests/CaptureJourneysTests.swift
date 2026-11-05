import XCTest

final class CaptureJourneysTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", fixture, "-feedback.showButton", "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Form and List rows can be lazy. Scroll through the current screen only until the requested control is usable.
    private func reveal(_ item: XCUIElement, in app: XCUIApplication, towardTop: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if item.exists && item.isHittable { return }
        for _ in 0..<7 {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
            if item.exists && item.isHittable { return }
        }
        XCTFail("Expected a visible control: \(item)", file: file, line: line)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let artifact = XCTAttachment(screenshot: app.screenshot())
        artifact.name = name; artifact.lifetime = .keepAlways; add(artifact)
    }

    func testMapSpreadsheetReviewAndConfirmCompletedWorkAppearsInHistory() {
        let app = launch("test-csv-review")
        let column = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "csv.column.Project title", "Project title")).firstMatch
        XCTAssertTrue(column.waitForExistence(timeout: 15))
        reveal(column, in: app); column.tap()
        let chosen = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "1. Worksheet entry")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 5)); chosen.tap()
        if app.navigationBars["Project title"].exists { app.navigationBars["Project title"].buttons.element(boundBy: 0).tap() }
        let ready = element("csv.readyCount", in: app)
        reveal(ready, in: app)
        XCTAssertEqual(ready.value as? String, "2")
        capture("Spreadsheet import · mapped columns and two reviewed projects", app)
        let review = app.buttons["csv.review"]
        reveal(review, in: app); review.tap()
        XCTAssertTrue(app.staticTexts["Replaced west gutter guard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Insulated garage ceiling"].exists)
        app.navigationBars["Review rows"].buttons.element(boundBy: 0).tap()
        let start = app.buttons["csv.import"]
        reveal(start, in: app); start.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "csv.confirm", "Import projects")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let outcome = element("csv.outcome", in: app)
        XCTAssertTrue(outcome.waitForExistence(timeout: 10))
        XCTAssertTrue(outcome.label.contains("Added 2 completed projects"))
        app.buttons["Done"].tap()
        let history = app.buttons["home.card.homeHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 10)); reveal(history, in: app); history.tap()
        XCTAssertTrue(app.buttons["history.log"].waitForExistence(timeout: 10))
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Replaced west gutter guard")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.label.contains("2024")); XCTAssertTrue(record.label.contains("1,250.50"))
        capture("Home History · imported year and actual cost", app)
    }

    func testReadScannedPermitConfirmOneDetailSaveAndReopenOriginal() {
        let app = launch("test-document-review")
        XCTAssertTrue(app.textFields["documents.title"].waitForExistence(timeout: 15))
        let read = app.buttons["documents.read"]
        reveal(read, in: app); read.tap()
        let reference = app.buttons["documents.use.referenceNumber"]
        // The fixture contains image pixels only. No prefilled candidates or mock OCR service are supplied.
        let finished = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "documents.read", "Read again")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 25), "The local scan did not produce a reading")
        reveal(reference, in: app)
        XCTAssertTrue(reference.label.contains("20261428"))
        let issuer = app.buttons["documents.use.issuer"]
        reveal(issuer, in: app)
        XCTAssertTrue(issuer.label.contains("Example Building Office"))
        capture("Documents · on-device permit suggestions before confirmation", app)
        let source = app.buttons["documents.page.issuer"]
        reveal(source, in: app); source.tap()
        XCTAssertTrue(app.navigationBars["Original · Page 1"].waitForExistence(timeout: 5))
        capture("Documents · original scanned permit page", app)
        app.navigationBars["Original · Page 1"].buttons["Done"].tap()
        reveal(reference, in: app, towardTop: true); reference.tap()
        app.buttons["documents.save"].tap()

        let history = app.buttons["home.card.homeHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 10)); reveal(history, in: app); history.tap()
        let intake = app.buttons["history.intake"]
        XCTAssertTrue(intake.waitForExistence(timeout: 10)); reveal(intake, in: app); intake.tap()
        app.buttons["intake.documents"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "documents.item.", "Garage building permit")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); reveal(saved, in: app)
        let originalID = String(saved.identifier.dropFirst("documents.item.".count))
        XCTAssertNotNil(UUID(uuidString: originalID)); saved.tap()
        let retained = element("documents.confirmed.referenceNumber", in: app)
        XCTAssertTrue(retained.waitForExistence(timeout: 5)); XCTAssertEqual(retained.value as? String, "20261428")
        XCTAssertFalse(element("documents.confirmed.issuer", in: app).exists, "An unselected OCR suggestion should stay outside the library metadata")
        capture("Documents · only the owner-confirmed permit detail is retained", app)
        app.buttons["documents.preview"].tap()
        // iOS can present Quick Look with a Share action or the original attachment's filename in its title bar.
        let share = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", "Share", "Share document")).firstMatch
        let filename = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", originalID)).firstMatch
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in share.isHittable || filename.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 10), .completed, "Quick Look did not present the saved original")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
