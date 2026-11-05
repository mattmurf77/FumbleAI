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
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Label workshop bins\n")

        let method = app.segmentedControls["todo.workMode"]
        show(method, in: app)
        method.buttons["DIY"].tap()
        let itemName = "Weatherproof label sheets"
        let name = app.textFields["supplies.name"]
        show(name, in: app)
        name.tap()
        name.typeText(itemName)
        app.buttons["supplies.add"].tap()

        let supplyRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", itemName + " ·")).firstMatch
        XCTAssertTrue(supplyRow.waitForExistence(timeout: 8))
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Check at home"), object: supplyRow)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 8), .completed)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "DIY task · check a supply against home inventory"
        image.lifetime = .keepAlways
        add(image)

        app.buttons["Save"].tap()
        let task = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "todo.open.", "Label workshop bins")
        ).firstMatch
        show(task, in: app)
        task.tap()
        let detail = app.descendants(matching: .any).matching(identifier: "todo.supplyDetail." + itemName).firstMatch
        for _ in 0..<4 where !detail.exists { app.swipeUp() }
        XCTAssertTrue(detail.exists)
        XCTAssertEqual(detail.label, itemName)
        XCTAssertEqual(detail.value as? String, "1 ea")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testRecommendationUsesTheActualFilterOnTheShelfAndOnlyShopsForTheMissingTool() {
        let app = XCUIApplication()
        app.launchArguments = ["-HomeDemo", "YES", "-HomeDemoScreen", "home", "-feedback.showButton", "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let all = app.buttons["home.otherSuggestions"]
        XCTAssertTrue(all.waitForExistence(timeout: 15)); all.tap()
        let suggestion = app.buttons["maintenance.furnace"]
        show(suggestion, in: app); suggestion.tap()
        let diy = app.buttons["DIY"]
        XCTAssertTrue(diy.waitForExistence(timeout: 5)); diy.tap()

        func supplyRow(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "supplies.row." + name, name + " ·")).firstMatch
        }
        let match = app.buttons["supplies.possible.Replacement HVAC filter"]
        show(match, in: app); match.tap()
        let homeFilter = "Furnace filter 16x25x1 MERV 11"
        let option = app.buttons["supplies.option." + homeFilter]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); option.tap()
        let owned = supplyRow(homeFilter)
        show(owned, in: app)
        XCTAssertTrue(owned.label.contains("Ready"), owned.label)
        XCTAssertFalse(app.switches["supplies.request." + homeFilter].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DIY readiness · homeowner-matched filter in storage"
        shot.lifetime = .keepAlways; add(shot)

        let light = supplyRow("Flashlight")
        show(light, in: app); light.tap()
        let request = app.switches["supplies.request.Flashlight"]
        show(request, in: app); request.tap()
        let schedule = app.buttons["maintenance.addTask"]
        show(schedule, in: app); schedule.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8)); save.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.navigationBars["New To-Do"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 8), .completed)
        if !app.navigationBars["All recommendations"].exists {
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }
        app.buttons["Done"].tap()
        app.tabBars.buttons["Stuff"].tap()
        let shopping = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shopping list")).firstMatch
        show(shopping, in: app); shopping.tap()
        XCTAssertTrue(app.buttons["shopping.todo.Flashlight"].waitForExistence(timeout: 8))
        // The owned filter may already have an independent running-low alert. Only DIY purchases belong in this section.
        XCTAssertFalse(app.buttons["shopping.todo." + homeFilter].exists)
        app.buttons["shopping.todo.Flashlight"].tap()
        app.buttons["Record purchase"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["shopping.todo.Flashlight"])
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 8), .completed)
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
