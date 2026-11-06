import SwiftUI
import HomeCore

/// This bundled content also supplies the helper server’s public privacy and support pages.
struct ProductInfoView: View {
    enum Page: String { case privacy, support }
    let page: Page
    private struct Content: Decodable {
        struct Paragraph: Decodable {
            var heading: String
            var text: String
        }
        var title: String
        var sections: [Paragraph]
    }

    private static let pages: [String: Content] = {
        guard let url = Bundle.main.url(forResource: "product-pages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pages = try? JSONDecoder().decode([String: Content].self, from: data) else { return [:] }
        return pages
    }()

    var body: some View {
        let content = Self.pages[page.rawValue]
        List {
            if let content {
                ForEach(content.sections, id: \.heading) { paragraph in
                    Section(paragraph.heading) { Text(paragraph.text).textSelection(.enabled) }
                }
            } else {
                Text("The help text could not be opened. Use Send feedback in Settings to contact the publisher.")
            }
            if let base = AppConfig.main.serverURL, base.scheme?.lowercased() == "https" {
                Link(page == .privacy ? "Open privacy policy online" : "Open support online",
                     destination: base.appendingPathComponent(page.rawValue))
            }
        }
        .navigationTitle(content?.title ?? (page == .privacy ? "Privacy policy" : "Support"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
