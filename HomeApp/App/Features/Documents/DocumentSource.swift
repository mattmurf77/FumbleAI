import Foundation
import UIKit
import ImageIO
import PDFKit
import HomeCore
import UniformTypeIdentifiers

/// A private copy keeps a Files provider's original available throughout review and local text extraction.
final class DocumentSource: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let filename: String
    let type: UTType
    private init(data: Data, filename: String) throws {
        guard !data.isEmpty, data.count <= Attachment.maxPDFBytes else { throw HomeDocumentError("Choose a PDF or image up to 25 MB.") }
        if data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil, PDFDocument(data: data) != nil { type = .pdf }
        else if let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source),
                (identifier as String) != UTType.pdf.identifier, CGImageSourceGetCount(source) > 0, let supported = UTType(identifier as String) { type = supported }
        else { throw HomeDocumentError("Choose a readable PDF or image.") }
        self.filename = filename
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "img")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    static func receive(_ url: URL, filename: String? = nil) throws -> DocumentSource {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var err: NSError?, result: Result<DocumentSource, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { current in
            result = Result {
                let file = try FileHandle(forReadingFrom: current); defer { try? file.close() }
                var data = Data()
                while let chunk = try file.read(upToCount: min(1024 * 1024, Attachment.maxPDFBytes - data.count + 1)), !chunk.isEmpty {
                    guard data.count + chunk.count <= Attachment.maxPDFBytes else { throw HomeDocumentError("Choose a PDF or image up to 25 MB.") }
                    data.append(chunk)
                }
                return try DocumentSource(data: data, filename: filename ?? url.lastPathComponent)
            }
        }
        if let err { throw err }; guard let result else { throw HomeDocumentError("Files could not open this document. Download it from its provider and try again.") }
        return try result.get()
    }
    static func scan(_ pages: [UIImage]) throws -> DocumentSource {
        guard !pages.isEmpty, pages.count <= 25 else { throw HomeDocumentError("Scan between 1 and 25 pages per document.") }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            for image in pages {
                let factor = 1100 / max(1, max(image.size.width, image.size.height))
                let page = CGRect(origin: .zero, size: CGSize(width: image.size.width * factor, height: image.size.height * factor))
                ctx.beginPage(withBounds: page, pageInfo: [:]); image.draw(in: page)
            }
        }
        return try DocumentSource(data: pdf, filename: "Scan \(Date().formatted(.iso8601.year().month().day())).pdf")
    }
}
