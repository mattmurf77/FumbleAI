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

    func testFirstHomeCanStartWithWorkBeforeAddingAnyRooms() {
        let app = launch("onboarding")
        open(app.buttons["onboarding.pastWork"], in: app)
        let field = app.textFields["Title, e.g. LVP flooring"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Replaced the roof")
        open(app.buttons["Save"], in: app)
        open(app.buttons["home.card.homeValue"], in: app)
        XCTAssertTrue(app.buttons["value.add"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home value after recording past work"
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
        let task = app.buttons.containing(.staticText, identifier: "Test air filter").firstMatch
        open(task, in: app)
        open(app.buttons["Mark done"], in: app)
        XCTAssertFalse(app.buttons["Mark done"].isHittable)
    }

    func testOwnerEstimateAndHomeBriefNavigation() {
        let app = launch("home")
        open(app.buttons["home.card.homeValue"], in: app)
        open(app.buttons["value.add"], in: app)
        let source = app.textFields["value.source"]
        source.tap()
        source.typeText("Agent review")
        let amount = app.textFields["value.amount"]
        amount.tap()
        amount.typeText("450000")
        open(app.buttons["value.save"], in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Agent review")).firstMatch.waitForExistence(timeout: 10))
        open(app.buttons["value.homeBrief"], in: app)
        XCTAssertTrue(app.buttons["billing.restore"].waitForExistence(timeout: 10))
    }
}
