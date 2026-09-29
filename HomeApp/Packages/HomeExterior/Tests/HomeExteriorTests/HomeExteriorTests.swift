import XCTest
@testable import HomeExterior

final class HomeExteriorTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeExteriorModule.name, "HomeExterior")
    }
}
