import XCTest

final class WorkEstimateUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func newTask(_ title: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "todos", "-feedback.showButton", "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.buttons["Add to-do"], in: app)
        let field = app.textFields["Title, e.g. Change HVAC filter"]
        tap(field, in: app)
        field.typeText(title + "\n")
        tap(app.buttons["estimate.open"], in: app)
        return app
    }

    func testCustomTaskCalculatesItemizedRangeAndReopensStoredInputs() {
        let title = "Seal the potting bench"
        let app = newTask(title)
        tap(app.buttons["estimate.addLine"], in: app)
        let name = app.textFields["estimate.item.name"]
        tap(name, in: app); name.typeText("Wood sealer")
        let quantity = app.textFields["estimate.item.quantity"]
        tap(quantity, in: app)
        quantity.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        let low = app.textFields["estimate.item.low"], high = app.textFields["estimate.item.high"]
        tap(low, in: app); low.typeText("12")
        tap(high, in: app); high.typeText("16")
        tap(app.buttons["estimate.item.save"], in: app)
        let total = app.staticTexts["estimate.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertTrue(total.label.contains("$24") && total.label.contains("$32"), total.label)
        tap(app.buttons["estimate.save"], in: app)
        tap(app.buttons["Save"], in: app)

        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "todo.open.", title)).firstMatch
        tap(saved, in: app)
        tap(app.buttons["estimate.open"], in: app)
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertTrue(total.label.contains("$24") && total.label.contains("$32"), total.label)
        let photo = XCTAttachment(screenshot: app.screenshot())
        photo.name = "Itemized custom work estimate after reopening"
        photo.lifetime = .keepAlways
        add(photo)
        tap(app.buttons["estimate.line.Wood sealer"], in: app)
        XCTAssertEqual(app.textFields["estimate.item.quantity"].value as? String, "2")
        XCTAssertEqual(app.textFields["estimate.item.low"].value as? String, "12")
        XCTAssertEqual(app.textFields["estimate.item.high"].value as? String, "16")
    }

    func testMeasuredPaintGuideShowsPricedRangeBeforeSelection() {
        let app = newTask("Paint my 12 x 14 bedroom")
        let guide = app.staticTexts["estimate.guidePreview"]
        XCTAssertTrue(guide.waitForExistence(timeout: 8))
        XCTAssertTrue(guide.label.contains("86.94") && guide.label.contains("161.94"), guide.label)
        tap(app.buttons["estimate.starter"], in: app)
        let preview = app.staticTexts["estimate.starter.total"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.label.contains("86.94") && preview.label.contains("161.94"), preview.label)
        tap(app.buttons["estimate.starter.apply"], in: app)
        XCTAssertTrue(app.buttons["estimate.line.Interior wall paint"].waitForExistence(timeout: 8))
        let photo = XCTAttachment(screenshot: app.screenshot())
        photo.name = "Measured room with three gallons of wall paint"
        photo.lifetime = .keepAlways; add(photo)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { element.tap(); return }
            if !element.exists { _ = element.waitForExistence(timeout: 1) }
            if element.exists && element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Could not reach " + element.debugDescription, file: file, line: line)
    }
}
