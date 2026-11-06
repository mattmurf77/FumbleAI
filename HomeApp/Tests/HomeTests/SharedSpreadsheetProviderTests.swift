import XCTest
import UniformTypeIdentifiers
import HomeCore
@testable import Home

final class SharedSpreadsheetProviderTests: XCTestCase {
    func testProviderReadsOriginalFileEvenWhenTextPreviewIsAlsoOffered() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        // Larger than the normal 20,000-character share-text limit, with UTF-16 BOM, CRLF and multiline quotes.
        let text = "title,notes\r\nRoof,\"kept\r\n" + String(repeating: "é", count: 24_000) + "\""
        let original = try XCTUnwrap(text.data(using: .utf16))
        try original.write(to: url)
        let provider = NSItemProvider(object: "misleading text preview" as NSString)
        provider.suggestedName = "Home projects.CSV"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.commaSeparatedText.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil); return nil
        }
        guard case .file(let sheet)? = await SharedSpreadsheetProvider.read(provider) else { return XCTFail("Original CSV not selected") }
        XCTAssertEqual(sheet.bytes, original)
        XCTAssertEqual(sheet.name, "Home projects.CSV")
        XCTAssertEqual(try PropertyListDecoder().decode(SharedInbox.Spreadsheet.self, from: PropertyListEncoder().encode(sheet)), sheet)
    }

    func testNamedSpreadsheetWithoutOriginalBytesNeverBecomesTaskText() async {
        let provider = NSItemProvider(object: "title,cost\nRoof,500" as NSString)
        provider.suggestedName = "Export.tsv"
        guard case .problem(let message)? = await SharedSpreadsheetProvider.read(provider) else { return XCTFail("Expected Files handoff") }
        XCTAssertTrue(message.contains("Files"))
        let ordinary = NSItemProvider(object: "Change the filter" as NSString)
        guard case nil = await SharedSpreadsheetProvider.read(ordinary) else { return XCTFail("Normal to-do text should keep its existing route") }
    }
}
