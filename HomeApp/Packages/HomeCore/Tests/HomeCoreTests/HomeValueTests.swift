import XCTest
import HomeCore

final class HomeValueTests: XCTestCase {
    func testEstimatesArePropertyScopedAndSalePricesNeverBecomeEstimates() throws {
        let home = UUID()
        let appraisal = HomeValueReference(propertyId: home, kind: .appraisal, source: "Appraisal", asOf: LocalDate(2026, 1, 1), amount: Money(cents: 50_000_000))
        var purchase = appraisal; purchase.kind = .purchasePrice; purchase.asOf = LocalDate(2026, 5, 1)
        let other = HomeValueReference(propertyId: UUID(), kind: .onlineEstimate, source: "Other", asOf: purchase.asOf, amount: purchase.amount)
        let journal = HomeValueSnapshot(propertyId: home, references: [appraisal, purchase, other], projects: [], lines: [])
        XCTAssertEqual(journal.references.count, 2); XCTAssertEqual(journal.latestEstimate, appraisal)
        purchase.upper = Money(cents: 60_000_000); XCTAssertThrowsError(try purchase.validate())
        var invalid = appraisal; invalid.upper = Money(cents: 10); XCTAssertThrowsError(try invalid.validate())
        invalid = appraisal; invalid.source = "  "; XCTAssertThrowsError(try invalid.validate())
    }
    func testActualOverrideUnknownAndZeroRemainDistinct() {
        let home = UUID(), date = LocalDate(2026, 1, 1)
        let paid = Project(propertyId: home, scope: .property, title: "Paid", status: .done, actualCost: Money(cents: 100, currency: "CAD"), completedOn: date)
        let unknown = Project(propertyId: home, scope: .property, title: "Unknown", status: .done, estCost: Money(cents: 700), completedOn: date)
        let free = Project(propertyId: home, scope: .property, title: "Warranty", status: .done, completedOn: date)
        let lines = [CostLineItem(propertyId: home, projectId: paid.id, label: "Included", amount: Money(cents: 10)),
                     CostLineItem(propertyId: home, projectId: free.id, label: "Covered", amount: .zero("GBP"))]
        let journal = HomeValueSnapshot(propertyId: home, references: [], projects: [paid, unknown, free], lines: lines)
        XCTAssertEqual(journal.investments.first { $0.id == paid.id }?.actual, paid.actualCost)
        XCTAssertNil(journal.investments.first { $0.id == unknown.id }?.actual)
        XCTAssertEqual(journal.investments.first { $0.id == free.id }?.actual, .zero("GBP"))
    }
}
