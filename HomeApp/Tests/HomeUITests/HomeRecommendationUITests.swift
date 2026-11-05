import XCTest

final class HomeRecommendationUITests: XCTestCase {
    @MainActor func testHomeRecommendsAnActualOverdueTaskAndOpensIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "home", "-feedback.showButton", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let next = app.buttons["home.nextAction"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "home.nextAction").count, 1)
        let names = ["Change furnace filter", "Replace detector batteries"]
        let selected = try XCTUnwrap(names.first { next.label.contains($0) })
        let schedule = app.staticTexts["home.periodTasks"]
        XCTAssertTrue(schedule.exists)
        XCTAssertLessThan(next.frame.minY, schedule.frame.minY)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Home • recommendation and scheduled tasks"; image.lifetime = .keepAlways; add(image)
        next.tap()
        XCTAssertTrue(app.staticTexts[selected].waitForExistence(timeout: 10))
    }

    @MainActor func testHomeOffersAllRecommendationsWithoutHidingNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "home", "-feedback.showButton", "NO", "-AppleLanguages", "(en)"]
        app.launch()
        let all = app.buttons["home.otherSuggestions"]
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        all.tap()
        XCTAssertTrue(app.navigationBars["All recommendations"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "All homeowner recommendations"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
        for _ in 0..<5 where !app.buttons["home.card.homeHistory"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["home.card.homeHistory"].isHittable)
    }
}
