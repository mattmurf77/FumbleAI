import Foundation
import XCTest

final class ProductInfoResourceTests: XCTestCase {
    func testBothPublicPagesArePackagedForOfflineUse() throws {
        struct Content: Decodable {
            struct Paragraph: Decodable { let heading: String; let text: String }
            let title: String
            let sections: [Paragraph]
        }
        let file = try XCTUnwrap(Bundle.main.url(forResource: "product-pages", withExtension: "json"))
        let pages = try JSONDecoder().decode([String: Content].self, from: Data(contentsOf: file))
        for name in ["privacy", "support"] {
            let page = try XCTUnwrap(pages[name])
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.sections.isEmpty)
            XCTAssertTrue(page.sections.allSatisfy { !$0.heading.isEmpty && !$0.text.isEmpty })
        }
    }
}
