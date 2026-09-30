import XCTest
import HomeCore
@testable import Home

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testPreviewEnvironmentLoadsSampleHouse() async throws {
        let env = AppEnvironment.preview()
        let property = try await env.plan.currentProperty()
        XCTAssertEqual(property?.name, "Maple Street")
        let levels = try await env.plan.levels(property: try XCTUnwrap(property?.id))
        XCTAssertEqual(levels.count, 4)
    }

    func testDeepLinkRouting() {
        let env = AppEnvironment.preview(sample: false)
        let id = UUID()
        env.handle(url: URL(string: "home://chore/\(id.uuidString.lowercased())")!)
        XCTAssertEqual(env.pendingDeepLink, .chore(id))
    }
}
