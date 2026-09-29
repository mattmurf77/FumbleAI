import XCTest
@testable import PlanCanvas

final class PlanCanvasTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(PlanCanvasModule.name, "PlanCanvas")
    }
}
