import Foundation
import XCTest
import HomeCore
@testable import HomeCapture
#if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#endif

final class DocumentReadingTests: XCTestCase {
    func testLabelsDoNotTurnPermitIssuanceOrInspectionIntoCompletedWork() {
        let candidates = DocumentFieldParser.candidates(in: [.init(number: 3, lines: [
            "Building Permit", "Permit Number: BP-70785", "Issued by: City of Cedar Bay",
            "Contractor: Harbor Roofing", "Issue Date: July 18, 2022", "Inspection Date: 2023-03-10",
            "Final Approval Date: 2023-03-15", "Estimated work completion date: 2023-03-29", "Permit fee: $80.00"
        ])])
        XCTAssertTrue(candidates.contains { $0.field == .referenceNumber && $0.value == "BP-70785" && $0.page == 3 })
        XCTAssertTrue(candidates.contains { $0.field == .issuedDate && $0.value == "2022-07-18" })
        XCTAssertTrue(candidates.contains { $0.field == .inspectionDate && $0.value == "2023-03-10" })
        XCTAssertTrue(candidates.contains { $0.field == .finalDate && $0.value == "2023-03-15" })
        XCTAssertFalse(candidates.contains { [.completionDate, .invoiceTotal, .receiptTotal].contains($0.field) })
        XCTAssertTrue(candidates.allSatisfy { !$0.excerpt.isEmpty && $0.page == 3 })
    }

    func testAmountsRequireLabeledTotalsAndDatesRequireUnambiguousEvidence() {
        let lines = ["Invoice", "Invoice No. A991", "Subtotal: $875.20", "Tax: $75.00", "Invoice Total: $950.20",
                     "Invoice Date: 03/04/2024", "Work Completed: 2024-06-13", "Warranty Expires: December 15, 2027"]
        let values = DocumentFieldParser.candidates(in: [.init(number: 1, lines: lines)])
        XCTAssertTrue(values.contains { $0.field == .invoiceTotal && $0.value == "$950.20" })
        XCTAssertFalse(values.contains { $0.field == .receiptTotal || $0.field == .invoiceDate })
        XCTAssertTrue(values.contains { $0.field == .completionDate && $0.value == "2024-06-13" })
        XCTAssertTrue(values.contains { $0.field == .warrantyEnd && $0.value == "2027-12-15" })
        XCTAssertTrue(DocumentFieldParser.candidates(in: [.init(number: 1, lines: ["nothing recognizable", "3796.44"])]).isEmpty)
    }

    func testQuoteIsOnlyAProposedAmountAndMixedPacketsKeepPageContext() {
        let result = DocumentFieldParser.candidates(in: [
            .init(number: 1, lines: ["Contractor Estimate", "Quoted Price: $1,250.00"]),
            .init(number: 2, lines: ["Invoice", "Grand Total: $1,100.00"]),
            .init(number: 3, lines: ["Sales Receipt", "Total: $500.00", "Quoted Price: $750.00"]),
            .init(number: 4, lines: ["Inspection Report", "Total: $400.00"])
        ])
        XCTAssertTrue(result.contains { $0.page == 1 && $0.field == .category && $0.value == "estimate" })
        XCTAssertTrue(result.contains { $0.page == 1 && $0.field == .estimateTotal && $0.value == "$1,250.00" })
        XCTAssertTrue(result.contains { $0.page == 2 && $0.field == .invoiceTotal && $0.value == "$1,100.00" })
        XCTAssertTrue(result.contains { $0.page == 3 && $0.field == .receiptTotal && $0.value == "$500.00" })
        XCTAssertFalse(result.contains { $0.value == "$750.00" })
        XCTAssertFalse(result.contains { $0.page == 4 && [.receiptTotal, .invoiceTotal, .estimateTotal].contains($0.field) })
    }

    #if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
    private let permit = ["Building Permit", "Permit Number: BP-70785", "Issued by: City of Cedar Bay",
                          "Issue Date: July 18, 2022", "Contractor: Harbor Roofing"]
    private let pageRect = CGRect(x: 0, y: 0, width: 1000, height: 1150)

    private func draw(_ lines: [String], to context: CGContext) {
        context.setFillColor(gray: 1, alpha: 1); context.fill(pageRect)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 38, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        for (index, string) in lines.enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 30, y: 1030 - index * 90)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs)), context)
        }
    }

    private func bitmap(_ lines: [String]) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: Int(pageRect.width), height: Int(pageRect.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        draw(lines, to: ctx)
        return try XCTUnwrap(ctx.makeImage())
    }

    private func pdf(at url: URL, pages: [[String]], raster: Bool) throws {
        var box = pageRect
        let sink = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let ctx = try XCTUnwrap(CGContext(consumer: sink, mediaBox: &box, nil))
        for lines in pages {
            ctx.beginPDFPage(nil)
            if raster { ctx.draw(try bitmap(lines), in: pageRect) }
            else { draw(lines, to: ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    func testNativePDFPreservesSourcePageAndCapsLargeDocuments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var pages = Array(repeating: ["Maintenance documents for the property"], count: 14)
        pages[2] = permit
        pages[13] = ["Permit Number: OMITTED-789"]
        try pdf(at: url, pages: pages, raster: false)
        let result = try await HomeDocumentReader().read(file: url)
        XCTAssertEqual(result.totalPages, 14); XCTAssertEqual(result.pagesRead, 12)
        XCTAssertTrue(result.truncated); XCTAssertFalse(result.usedOCR)
        XCTAssertTrue(result.candidates.contains { $0.field == .referenceNumber && $0.value == "BP-70785" && $0.page == 3 })
        XCTAssertFalse(result.candidates.contains { $0.value.contains("OMITTED") })
    }

    func testScannedPDFAndPNGUseRealOnDeviceOCR() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanned = dir.appendingPathComponent("scan.pdf")
        try pdf(at: scanned, pages: [permit], raster: true)
        let photo = dir.appendingPathComponent("photo.png")
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try bitmap(permit), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        for file in [scanned, photo] {
            let result = try await HomeDocumentReader().read(file: file)
            XCTAssertEqual(result.totalPages, 1); XCTAssertEqual(result.pagesRead, 1)
            XCTAssertTrue(result.usedOCR)
            XCTAssertTrue(result.candidates.contains { $0.field == .category && $0.value == "permit" })
            XCTAssertTrue(result.candidates.contains { $0.field == .referenceNumber && $0.value == "BP-70785" })
        }
    }

    func testInvalidAndOversizeFilesAreRecoverable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bad document".utf8).write(to: url)
        do { _ = try await HomeDocumentReader().read(file: url); XCTFail("Unreadable file") }
        catch HomeDocumentReader.ReadError.unreadable {}
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(Attachment.maxPDFBytes + 1)); try file.close()
        do { _ = try await HomeDocumentReader().read(file: url); XCTFail("Oversize file") }
        catch HomeDocumentReader.ReadError.oversize {}
    }
    #endif
}
