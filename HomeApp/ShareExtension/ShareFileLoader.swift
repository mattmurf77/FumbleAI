import UIKit
import ImageIO
import UniformTypeIdentifiers
import HomeCore

/// One file taken from the share: metadata, the (downscaled) bytes to hand to the app, and a small preview.
struct ReceivedFile: Identifiable {
    var file: SharedInbox.File
    var data: Data
    var thumbnail: UIImage?
    var id: UUID { file.id }
}

/// Loads shared photos and PDFs off the main actor and keeps them small: photos are downscaled with ImageIO (long
/// edge ≤ `SharedInbox.maxImageLongEdgePx`, JPEG) without decoding the full image; PDFs over
/// `SharedInbox.maxPDFBytes` are refused with a friendly message. The extension has ~120 MB to work with.
enum ShareFileLoader {
    enum Outcome {
        case file(ReceivedFile)
        case problem(String)
    }

    static func loadPDF(_ provider: NSItemProvider) async -> Outcome {
        var name = displayName(provider.suggestedName, ext: "pdf", fallback: "Document")
        let item: NSSecureCoding
        do {
            item = try await provider.loadItem(forTypeIdentifier: UTType.pdf.identifier)
        } catch {
            return .problem("Couldn’t open “\(name)”. Try sharing it again.")
        }
        var data: Data?
        if let url = item as? URL {
            name = displayName(url.lastPathComponent, ext: "pdf", fallback: "Document")
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if let problem = SharedInbox.pdfSizeProblem(byteSize: size, name: name) { return .problem(problem) }
            data = try? Data(contentsOf: url)
        } else if let d = item as? Data {
            data = d
        }
        guard let data, !data.isEmpty else { return .problem("Couldn’t open “\(name)”. Try sharing it again.") }
        if let problem = SharedInbox.pdfSizeProblem(byteSize: data.count, name: name) { return .problem(problem) }
        let file = SharedInbox.File(name: name, uti: UTType.pdf.identifier, fileExt: "pdf", byteSize: data.count)
        return .file(ReceivedFile(file: file, data: data, thumbnail: pdfThumbnail(data)))
    }

    static func loadImage(_ provider: NSItemProvider, number: Int) async -> Outcome {
        let name = displayName(provider.suggestedName, ext: "jpg", fallback: "Photo \(number)")
        let item: NSSecureCoding
        do {
            item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        } catch {
            return .problem("Couldn’t open “\(name)”. Try sharing it again.")
        }
        var shrunk: (jpeg: Data, preview: UIImage?)?
        if let url = item as? URL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            shrunk = downscale(CGImageSourceCreateWithURL(url as CFURL, nil))
        } else if let data = item as? Data {
            shrunk = downscale(CGImageSourceCreateWithData(data as CFData, nil))
        } else if let image = item as? UIImage {
            // Screenshots shared straight from the screenshot editor arrive as an image, not a file.
            shrunk = downscale(image)
        }
        guard let shrunk else { return .problem("Couldn’t read “\(name)” as a photo.") }
        let file = SharedInbox.File(name: name, uti: UTType.jpeg.identifier, fileExt: "jpg", byteSize: shrunk.jpeg.count)
        return .file(ReceivedFile(file: file, data: shrunk.jpeg, thumbnail: shrunk.preview))
    }

    // MARK: Helpers

    /// "Invoice 1043.pdf" from a suggested name with or without an extension.
    private static func displayName(_ suggested: String?, ext: String, fallback: String) -> String {
        let raw = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (raw as NSString).deletingPathExtension
        let base = raw.isEmpty ? fallback : (stem.isEmpty ? raw : stem)
        return "\(base).\(ext)"
    }

    private static func downscale(_ source: CGImageSource?) -> (jpeg: Data, preview: UIImage?)? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: SharedInbox.maxImageLongEdgePx,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: SharedInbox.jpegQuality) else { return nil }
        return (jpeg, image.preparingThumbnail(of: previewSize(for: image.size)))
    }

    private static func downscale(_ image: UIImage) -> (jpeg: Data, preview: UIImage?)? {
        let px = (width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
        let fitted = SharedInbox.fittedSize(width: px.width, height: px.height)
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: fitted.width, height: fitted.height)
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: SharedInbox.jpegQuality) else { return nil }
        return (jpeg, resized.preparingThumbnail(of: previewSize(for: resized.size)))
    }

    private static func previewSize(for size: CGSize) -> CGSize {
        let longEdge: CGFloat = 180
        guard size.width > 0, size.height > 0 else { return CGSize(width: longEdge, height: longEdge) }
        let scale = min(1, longEdge / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// First page, small, for the preview row.
    private static func pdfThumbnail(_ data: Data) -> UIImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(dataProvider),
              let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = 180 / max(box.width, box.height)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(page)
        }
    }
}
