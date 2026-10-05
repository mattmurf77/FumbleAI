import XCTest
@testable import HomeCore

final class SharedInboxTests: XCTestCase {
    func testOldEntriesDecodeAsTodos() throws {
        // What the share extension stored before kinds and files existed.
        let json = #"[{"text":"Clean gutters\nSeal the deck","createdAt":700000000}]"#
        let entries = try JSONDecoder().decode([SharedInbox.Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "Clean gutters\nSeal the deck")
        XCTAssertEqual(entries[0].kind, .todos)
        XCTAssertEqual(entries[0].files, [])
        XCTAssertTrue(entries[0].isTodoList)
    }

    func testUnknownKindReadsAsTodos() throws {
        let json = #"{"text":"x","createdAt":0,"kind":"voiceMemo","files":[]}"#
        let entry = try JSONDecoder().decode(SharedInbox.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.kind, .todos)
    }

    func testRoundTripWithFiles() throws {
        let file = SharedInbox.File(name: "Invoice.pdf", uti: "com.adobe.pdf", fileExt: "pdf", byteSize: 1234)
        let entry = SharedInbox.Entry(text: "From Mail", createdAt: Date(timeIntervalSince1970: 1_000),
                                      kind: .receipt, files: [file])
        let back = try JSONDecoder().decode(SharedInbox.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back, entry)
        XCTAssertFalse(back.isTodoList)
        XCTAssertTrue(back.files[0].isPDF)
    }

    func testTextWithFilesIsNotATodoList() {
        let file = SharedInbox.File(name: "Photo.jpg", uti: "public.jpeg", fileExt: "jpg", byteSize: 10)
        XCTAssertFalse(SharedInbox.Entry(text: "a", createdAt: Date(), kind: .todos, files: [file]).isTodoList)
        XCTAssertFalse(SharedInbox.Entry(text: "a", createdAt: Date(), kind: .note).isTodoList)
        XCTAssertTrue(file.isImage)
    }

    func testFittedSize() {
        XCTAssertTrue(SharedInbox.fittedSize(width: 4032, height: 3024) == (2000, 1500))
        XCTAssertTrue(SharedInbox.fittedSize(width: 1170, height: 2532) == (924, 2000))
        XCTAssertTrue(SharedInbox.fittedSize(width: 800, height: 600) == (800, 600))
        XCTAssertTrue(SharedInbox.fittedSize(width: 0, height: 0) == (0, 0))
    }

    func testPDFSizeProblem() {
        XCTAssertNil(SharedInbox.pdfSizeProblem(byteSize: 2_000_000, name: "a.pdf"))
        XCTAssertNil(SharedInbox.pdfSizeProblem(byteSize: SharedInbox.maxPDFBytes, name: "a.pdf"))
        let msg = SharedInbox.pdfSizeProblem(byteSize: SharedInbox.maxPDFBytes + 1, name: "Big.pdf")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("Big.pdf"))
        XCTAssertTrue(msg!.contains("8 MB"))
    }

    func testSizeText() {
        XCTAssertEqual(SharedInbox.sizeText(412 * 1024), "412 KB")
        XCTAssertEqual(SharedInbox.sizeText(100), "1 KB")
        XCTAssertEqual(SharedInbox.sizeText(Int(2.5 * 1024 * 1024)), "2.5 MB")
    }

    func testAppendingNote() {
        XCTAssertEqual(SharedInbox.appendingNote("  Can start Monday.  ", to: nil, header: "— Oct 5 —"),
                       "— Oct 5 —\nCan start Monday.")
        XCTAssertEqual(SharedInbox.appendingNote("Quote attached.", to: "Need 3 quotes\n", header: "— Oct 5 —"),
                       "Need 3 quotes\n\n— Oct 5 —\nQuote attached.")
        XCTAssertEqual(SharedInbox.appendingNote("", to: "Old", header: "— Oct 5 —"), "Old\n\n— Oct 5 —")
    }

    func testSuggestedTitle() {
        XCTAssertEqual(SharedInbox.suggestedTitle(vendor: " Hardware Store ", text: "x", kind: .receipt), "Hardware Store")
        XCTAssertEqual(SharedInbox.suggestedTitle(vendor: nil, text: "\n  Re: Deck quote \nHi!", kind: .note), "Re: Deck quote")
        XCTAssertEqual(SharedInbox.suggestedTitle(vendor: "", text: "", kind: .receipt), "New purchase")
        XCTAssertEqual(SharedInbox.suggestedTitle(vendor: nil, text: "", kind: .document), "New project")
    }
}
