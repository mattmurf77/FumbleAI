import XCTest
@testable import HomeCapture

final class HomeCaptureTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeCaptureModule.name, "HomeCapture")
    }
}
