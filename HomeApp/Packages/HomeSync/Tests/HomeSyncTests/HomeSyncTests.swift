import XCTest
@testable import HomeSync

final class HomeSyncTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeSyncModule.name, "HomeSync")
    }
}
