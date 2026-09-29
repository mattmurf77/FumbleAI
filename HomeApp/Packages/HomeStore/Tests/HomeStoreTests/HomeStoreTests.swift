import XCTest
@testable import HomeStore

final class HomeStoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeStoreModule.name, "HomeStore")
    }
}
