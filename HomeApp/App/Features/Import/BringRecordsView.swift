import SwiftUI
import HomeCore

/// Entry points for records the owner already has. Each destination reviews a source before filing it.
struct BringRecordsView: View {
    let property: Property
    @State private var manual = false

    var body: some View {
        List {
            Section {
                NavigationLink { ProjectCSVImportView(property: property) } label: {
                    inputLabel("Import a spreadsheet", "Bring past work from an Excel or Google Sheets CSV.", "tablecells")
                }.accessibilityIdentifier("intake.csv")
                NavigationLink { HomeDocumentsView(property: property) } label: {
                    inputLabel("Home documents", "Keep permits, warranties, invoices and inspection reports.", "doc.on.doc")
                }.accessibilityIdentifier("intake.documents")
                Button { manual = true } label: {
                    inputLabel("Record past work", "Start with what changed and add details as you find them.", "hammer")
                }.accessibilityIdentifier("intake.manual")
            }
            Section("Where to find your files") {
                Text("Choose Browse in the Files picker for iCloud Drive and other locations enabled on your iPhone, including third-party file providers. You can also share PDFs and photos to Home Blueprint from apps such as Mail.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Bring in records")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $manual) { ProjectForm(spaceID: nil, levelID: nil, initialStatus: .done) }
    }

    private func inputLabel(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        } icon: { Image(systemName: symbol) }
    }
}

enum OpenSpreadsheet {
    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["csv", "tsv", "tab"].contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) throws -> ProjectCSVFile {
        guard accepts(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try ProjectCSVFile.read(url)
    }

}
