import XCTest

final class ChoreReadinessUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testArbitraryNewToDoCanChooseDIYAndCheckACustomSupply() {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "todos", "-feedback.showButton", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let addTask = app.buttons["Add to-do"]
        XCTAssertTrue(addTask.waitForExistence(timeout: 15)); addTask.tap()
        let title = app.textFields["Title, e.g. Change HVAC filter"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("Label workshop bins")
        let method = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "todo.workMode", "How will you do it?")).firstMatch
        show(method, in: app); method.tap()
        let diy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "DIY")).firstMatch
        XCTAssertTrue(diy.waitForExistence(timeout: 5)); diy.tap()
        if app.navigationBars["How will you do it?"].exists { app.navigationBars["How will you do it?"].buttons.element(boundBy: 0).tap() }
        let name = app.textFields["supplies.name"]
        show(name, in: app); name.tap(); name.typeText("Weatherproof label sheets\n")
        let readiness = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Check at home")).firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 8), "An unmatched custom item must prompt an at-home check")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "DIY task · check a supply against home inventory"; image.lifetime = .keepAlways; add(image)
        app.buttons["Save"].tap()
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "todo.open.", "Label workshop bins")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 8)); show(task, in: app); task.tap()
        let supply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Weatherproof label sheets")).firstMatch
        show(supply, in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func show(_ control: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if control.exists && control.isHittable { return }
        for _ in 0..<7 {
            app.swipeUp()
            if control.exists && control.isHittable { return }
        }
        XCTFail("Expected visible control: \(control)", file: file, line: line)
    }
}
