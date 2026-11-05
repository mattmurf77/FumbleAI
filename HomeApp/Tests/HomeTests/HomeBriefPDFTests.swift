import XCTest
import HomeCore
import PDFKit
@testable import Home

final class HomeBriefPDFTests: XCTestCase {
    func testSelectedProjectsAreTheOnlyFactsSharedAndCostsRequireOptIn() throws {
        let property = UUID(), date = LocalDate(2026, 10, 12)
        let selected = Project(propertyId: property, scope: .property, title: "Replaced roof", notes: "Alarm code secret", status: .done, actualCost: Money(cents: 12345, currency: "EUR"), vendor: "Private Vendor")
        let planned = Project(propertyId: property, scope: .property, title: "Unfinished", status: .planned)
        let skipped = Project(propertyId: property, scope: .property, title: "Unselected", status: .done)
        let data = HomeValueSnapshot(propertyId: property, references: [], projects: [selected, planned, skipped], lines: [])
        let ids: Set<UUID> = [selected.id, planned.id]
        let pdf = try XCTUnwrap(PDFDocument(data: HomeBriefPDF.make(from: data.investments, selected: ids, includeCosts: false, prepared: date)))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Replaced roof")); XCTAssertTrue(text.contains("Completion date unrecorded"))
        for privateField in ["Alarm code secret", "Private Vendor", "Unfinished", "Unselected", "123.45", "EUR"] { XCTAssertFalse(text.contains(privateField)) }
        let shared = try XCTUnwrap(PDFDocument(data: HomeBriefPDF.make(from: data.investments, selected: ids, includeCosts: true, prepared: date))?.string)
        XCTAssertTrue(shared.contains("EUR")); XCTAssertFalse(shared.contains("Private Vendor"))
        XCTAssertThrowsError(try HomeBriefPDF.make(from: data.investments, selected: [], includeCosts: true, prepared: date))
    }

    func testLongBriefRetainsProjectsAcrossPages() throws {
        let owner = UUID(), date = LocalDate(2026, 2, 2)
        let projects = (1...90).map { Project(propertyId: owner, scope: .property, title: "Improvement-ref-\($0)-end", status: .done, completedOn: date) }
        let journal = HomeValueSnapshot(propertyId: owner, references: [], projects: projects, lines: [])
        let pdf = try XCTUnwrap(PDFDocument(data: HomeBriefPDF.make(from: journal.investments, selected: Set(projects.map(\.id)), includeCosts: false, prepared: date)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let text = try XCTUnwrap(pdf.string)
        for project in projects { XCTAssertTrue(text.contains(project.title)) }
    }
}
