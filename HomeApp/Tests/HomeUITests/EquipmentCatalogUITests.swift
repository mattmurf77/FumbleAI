import XCTest

final class EquipmentCatalogUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testStartWithoutRoomsAndAddFindAndEditOwnedTool() {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "onboarding", "-feedback.showButton", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let quickstart = app.buttons["onboarding.startRecords"]
        XCTAssertTrue(quickstart.waitForExistence(timeout: 15)); quickstart.tap()
        let stuff = app.tabBars.buttons["Stuff"]
        XCTAssertTrue(stuff.waitForExistence(timeout: 12)); stuff.tap()
        let catalog = app.buttons["hub.row.storage"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 8)); catalog.tap()
        let add = app.buttons["equipment.addStock"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["equipment.rooms"].exists)
        add.tap()
        let name = app.textFields["inventory.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8)); XCTAssertTrue(app.navigationBars["New Stored Item"].exists)
        name.tap(); name.typeText("Telescoping gutter wand")
        app.navigationBars.buttons["Save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "equipment.item.inventory.", "Telescoping gutter wand")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.label.contains("Whole house")); XCTAssertTrue(row.label.contains("On hand")); XCTAssertTrue(row.label.contains("1"))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Whole-home inventory before creating a floor plan"; image.lifetime = .keepAlways; self.add(image)
        row.tap(); XCTAssertTrue(name.waitForExistence(timeout: 8)); XCTAssertEqual(name.value as? String, "Telescoping gutter wand")
        let category = app.textFields["Category"]
        category.tap(); category.typeText("Workshop gear"); app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        XCTAssertTrue(category.waitForExistence(timeout: 8)); XCTAssertEqual(category.value as? String, "Workshop gear")
    }
}
