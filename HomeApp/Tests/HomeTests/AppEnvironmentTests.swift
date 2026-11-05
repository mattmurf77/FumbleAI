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

extension AppEnvironmentTests {
    func testExpenseInputDoesNotSilentlyChangeMalformedOrNegativeAmounts() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(ProjectInput.money("$1,234.56", currency: "USD", locale: us), .value(Money(cents: 123456)))
        XCTAssertEqual(ProjectInput.money("1.234,56", currency: "EUR", locale: Locale(identifier: "de_DE")), .value(Money(cents: 123456, currency: "EUR")))
        XCTAssertEqual(ProjectInput.money("1 234,56", currency: "EUR", locale: Locale(identifier: "fr_FR")), .value(Money(cents: 123456, currency: "EUR")))
        XCTAssertEqual(ProjectInput.money("0.00", currency: "USD", locale: us), .value(Money(cents: 0)))
        XCTAssertEqual(ProjectInput.money("", currency: "USD", locale: us), .empty)
        for text in ["$-15", "1.2.3", "3cats4", "2,40", "12.456", "999999999999999999999999999999999"] {
            guard case .invalid = ProjectInput.money(text, currency: "USD", locale: us) else { XCTFail(text); continue }
        }
    }
}
