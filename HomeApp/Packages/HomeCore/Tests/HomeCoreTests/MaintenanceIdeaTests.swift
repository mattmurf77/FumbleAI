import XCTest
import HomeCore

final class MaintenanceIdeaTests: XCTestCase {
    func testSuggestionsRotateBySeasonAndRemainOptional() {
        XCTAssertEqual(MaintenanceIdea.seasonalOrder(month: 11, latitude: 40).first, .gutters)
        XCTAssertEqual(MaintenanceIdea.seasonalOrder(month: 11, latitude: -32).first, .cooling)
        for month in 1...12 {
            let ideas = MaintenanceIdea.seasonalOrder(month: month, latitude: nil)
            XCTAssertEqual(Set(ideas), Set(MaintenanceIdea.allCases))
            XCTAssertEqual(ideas.count, Set(ideas).count)
        }
    }

    func testPropertyChoicesAndScheduledNames() {
        XCTAssertEqual(MaintenanceIdea.titleKey("Clean my gutters"), MaintenanceIdea.titleKey("Clean the gutters"))
        XCTAssertFalse(MaintenanceIdea.visible(month: 11, latitude: 40, hidden: "gutters,dryer").contains(.gutters))
    }

    func testEquipmentCanBeReusedAndRoutineValueIsUnquantified() {
        let kit = MaintenanceIdea.gutters.suggestedSupplyPlan
        XCTAssertEqual(kit.first { $0.name == "Garden hose" }?.isEquipment, true)
        XCTAssertEqual(kit.first { $0.name == "Yard waste bags" }?.isEquipment, false)
        XCTAssertNil(MaintenanceIdea.gutters.resaleScenario(isDIY: false))
        XCTAssertNil(MaintenanceIdea.closet.resaleScenario(isDIY: true))
        XCTAssertEqual(MaintenanceIdea.closet.resaleScenario(isDIY: false), 900...2700)
    }

    func testPublishedRangesHaveAttributionAndDIYCheckHasNoMadeUpPrice() throws {
        for idea in MaintenanceIdea.allCases {
            if let range = idea.rangeUSD {
                XCTAssertGreaterThan(range.lowerBound, 0)
                XCTAssertGreaterThan(range.upperBound, range.lowerBound)
                XCTAssertEqual(try XCTUnwrap(idea.priceSource).scheme, "https")
            }
        }
        XCTAssertNil(MaintenanceIdea.filter.rangeUSD)
        XCTAssertEqual(MaintenanceIdea.filter.suggestedRepeat?.freq, .monthly)
    }
}
