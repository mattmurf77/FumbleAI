import XCTest
import HomeCore

final class ProjectScenariosTests: XCTestCase {
    func testRecoveryKeepsCurrencyAndRoundsOnce() {
        let budget = Money(cents: 1_000_001, currency: "USD")
        XCTAssertEqual(ProjectScenarios.recoveredCost(budget, percent: 83), Money(cents: 830_001, currency: "USD"))
        XCTAssertNil(ProjectScenarios.recoveredCost(budget, percent: -1))
        XCTAssertNil(ProjectScenarios.recoveredCost(Money(cents: .max), percent: 200))
    }

    func testFixedLoanPaymentIncludingZeroAndVerySmallRates() {
        let amount = Money(cents: 1_000_000, currency: "USD")
        XCTAssertEqual(ProjectScenarios.monthlyPayment(principal: amount, annualRate: 6, months: 60)?.cents, 19_333)
        XCTAssertEqual(ProjectScenarios.monthlyPayment(principal: amount, annualRate: 0, months: 24)?.cents, 41_667)
        XCTAssertEqual(ProjectScenarios.monthlyPayment(principal: amount, annualRate: 0.00000000001, months: 24)?.cents, 41_667)
        XCTAssertNil(ProjectScenarios.monthlyPayment(principal: amount, annualRate: .infinity, months: 0))
    }
}
