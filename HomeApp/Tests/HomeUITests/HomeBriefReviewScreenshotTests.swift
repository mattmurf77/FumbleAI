import StoreKitTest
import XCTest

final class HomeBriefReviewScreenshotTests: XCTestCase {
    @MainActor
    func testCaptureHomeBriefPurchaseForReview() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HomeBrief", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        let app = XCUIApplication()
        app.launchArguments = ["-feedback.showButton", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let start = app.buttons["onboarding.startRecords"]
        let settings = app.buttons["Settings"]
        if !settings.exists && start.waitForExistence(timeout: 20) { start.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "The app must complete onboarding before opening Home history.")

        let history = app.buttons["home.card.homeHistory"]
        for _ in 0..<8 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable, "Home history must be reachable from the Home screen.")
        history.tap()
        let brief = app.buttons["history.homeBrief"]
        XCTAssertTrue(brief.waitForExistence(timeout: 10))
        brief.tap()

        // The purchase button is rendered only after StoreKit returns Product.displayPrice.
        let purchase = app.buttons["billing.buy"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 20), "Apple's local StoreKit catalog must provide the price.")
        XCTAssertTrue(purchase.isHittable)
        XCTAssertTrue(app.buttons["billing.restore"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home Brief - App Review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
