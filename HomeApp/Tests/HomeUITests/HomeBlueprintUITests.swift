import XCTest

final class HomeBlueprintUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", screen,
                               "-feedback.showButton", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func open(_ button: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 15), file: file, line: line)
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstHomeCanStartWithWorkBeforeAddingAnyRooms() {
        let app = launch("onboarding")
        XCTAssertTrue(app.buttons["onboarding.bringRecords"].waitForExistence(timeout: 15))
        capture("Welcome", app: app)
        open(app.buttons["onboarding.bringRecords"], in: app)
        XCTAssertTrue(app.buttons["intake.csv"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["intake.documents"].exists)
        open(app.buttons["intake.manual"], in: app)
        let field = app.textFields["project.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Replaced the roof")
        open(app.buttons["Save"], in: app)
        open(app.buttons["Done"], in: app)
        open(app.buttons["home.card.homeHistory"], in: app)
        XCTAssertTrue(app.buttons["history.log"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home history after recording past work"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        open(app.buttons["Done"], in: app)
        app.tabBars.buttons["Plan"].tap()
        open(app.buttons["plan.firstSetup"], in: app)
        XCTAssertTrue(app.textFields["Street address"].waitForExistence(timeout: 10))
    }

    func testCreateTaskFromToDosAndMarkItDone() {
        let app = launch("todos")
        open(app.buttons["Add to-do"], in: app)
        let field = app.textFields["Title, e.g. Change HVAC filter"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Test air filter")
        open(app.buttons["Save"], in: app)
        let task = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "todo.open.", "Test air filter")
        ).firstMatch
        open(task, in: app)
        open(app.buttons["Mark done"], in: app)
        XCTAssertTrue(app.staticTexts["Marked done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mark done"].isHittable)
        open(app.buttons["Undo"], in: app)
        XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
    }

    func testHomeHistoryAndPrivateBriefAreReachable() {
        let app = launch("home")
        XCTAssertTrue(app.buttons["home.card.homeHistory"].waitForExistence(timeout: 15))
        capture("Home", app: app)
        open(app.buttons["home.card.homeHistory"], in: app)
        XCTAssertTrue(app.buttons["history.log"].waitForExistence(timeout: 10))
        capture("Home History", app: app)
        open(app.buttons["history.homeBrief"], in: app)
        XCTAssertTrue(app.buttons["billing.restore"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["brief.preview"].exists)
    }
}
