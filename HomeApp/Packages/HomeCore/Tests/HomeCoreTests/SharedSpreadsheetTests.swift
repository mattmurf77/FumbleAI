import Foundation
import XCTest
import HomeCore

final class SharedSpreadsheetTests: XCTestCase {
    func testExactlyFourMiBPassesWithoutReencodingAndOversizeOrEmptyFilesFail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(repeating: 0x81, count: ProjectCSV.maxBytes)
        try original.write(to: url)
        let sheet = try SharedInbox.Spreadsheet.read(url, name: "/private/exports/House.v2.TSV", ext: "tsv")
        XCTAssertEqual(sheet.name, "House.v2.TSV")
        XCTAssertEqual(sheet.bytes, original)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ProjectCSV.maxBytes + 1)); try handle.close()
        XCTAssertThrowsError(try SharedInbox.Spreadsheet.read(url, name: "export.tsv", ext: "tsv"))
        try Data().write(to: url)
        XCTAssertThrowsError(try SharedInbox.Spreadsheet.read(url, name: "empty.csv", ext: "csv"))
    }

    func testClassificationUsesExplicitFileEvidenceAndStripsProviderPathsFromName() throws {
        XCTAssertEqual(SharedInbox.Spreadsheet.fileExtension(name: nil, type: "public.tab-separated-values-text"), "tsv")
        XCTAssertEqual(SharedInbox.Spreadsheet.fileExtension(name: "work.CsV", type: "public.text"), "csv")
        XCTAssertNil(SharedInbox.Spreadsheet.fileExtension(name: "Notes.txt", type: "public.text"))
        XCTAssertNil(SharedInbox.Spreadsheet.fileExtension(name: nil, type: "public.url"))
        let sheet = try SharedInbox.Spreadsheet(name: "https://provider.example/tenant/path/Receipts.csv?token=secret",
                                               ext: "csv", bytes: Data([1]))
        XCTAssertEqual(sheet.name, "Receipts.csv")
    }
}
