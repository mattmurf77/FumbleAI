import XCTest
@testable import HomeSchedule

final class HomeScheduleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeScheduleModule.name, "HomeSchedule")
    }
}
