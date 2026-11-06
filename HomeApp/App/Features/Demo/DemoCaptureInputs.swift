#if DEBUG
import SwiftUI
import UIKit
import HomeCore

/// Provides synthetic source files only, at the same boundary as the Files picker. The normal import and OCR
/// screens perform all parsing, review, saves and subsequent reads against the demo launch's in-memory home.
struct DemoCaptureInputs: View {
    enum Mode { case csv, permit }
    let mode: Mode
    @Environment(AppEnvironment.self) private var env
    @State private var property: Property?
    @State private var source: DocumentSource?
    @State private var failure: String?

    private static let spreadsheet = ProjectCSVFile(name: "Maintenance log.csv", data: Data("""
        Worksheet entry,Year,Actual cost,Currency
        Replaced west gutter guard,2024,1250.50,USD
        Insulated garage ceiling,2023,480.00,USD
        """.utf8))

    var body: some View {
        NavigationStack {
            if let property {
                if mode == .csv { ProjectCSVImportView(property: property, initialFile: Self.spreadsheet) }
                else if let source { DocumentEditor(propertyId: property.id, source: source, currency: property.currencyCode) }
            } else if let failure { Text(failure) }
            else { ProgressView("Opening example file…") }
        }
        .task {
            do {
                guard let current = try await env.plan.currentProperty() else { throw HomeDocumentError("Demo home unavailable.") }
                if mode == .permit { source = try Self.permitSource() }
                property = current
            } catch { failure = error.localizedDescription }
        }
    }

    /// Embed a raster page without a PDF text layer, so a suggested permit identifier must come from Vision.
    @MainActor private static func permitSource() throws -> DocumentSource {
        let page = CGRect(x: 0, y: 0, width: 1280, height: 1620)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let scan = UIGraphicsImageRenderer(size: page.size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(page)
            for (line, y, size) in [("BUILDING PERMIT", 100, 68), ("Permit Number: 20261428", 270, 52), ("Issued by: Example Building Office", 435, 48)] {
                (line as NSString).draw(at: CGPoint(x: 65, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: CGFloat(size), weight: .medium), .foregroundColor: UIColor.black])
            }
        }
        let bytes = UIGraphicsPDFRenderer(bounds: page).pdfData { renderer in renderer.beginPage(); scan.draw(in: page) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try bytes.write(to: temp, options: .atomic)
        return try DocumentSource.receive(temp, filename: "Garage building permit.pdf")
    }
}
#endif
