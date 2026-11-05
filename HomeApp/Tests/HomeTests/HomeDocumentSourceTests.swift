import XCTest
import UIKit
import PDFKit
import UniformTypeIdentifiers
@testable import Home

final class HomeDocumentSourceTests: XCTestCase {
    func testProviderOriginalStaysReadableAfterProviderFileIsGone() throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 120, height: 70)).pdfData { $0.beginPage(); $0.beginPage() }
        try bytes.write(to: original)
        let staged = try DocumentSource.receive(original, filename: "Kitchen permit.pdf")
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(staged.type, .pdf); XCTAssertEqual(staged.filename, "Kitchen permit.pdf"); XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        XCTAssertEqual(PDFDocument(url: staged.url)?.pageCount, 2)
    }

    func testMalformedFileIsNotAcceptedBasedOnItsExtension() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: fake) }
        try Data("not a PDF".utf8).write(to: fake)
        XCTAssertThrowsError(try DocumentSource.receive(fake))
    }
}
