import Foundation
import HomeCore
#if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
#endif

/// Reads the owner's selected local file. All PDF rendering, OCR and field extraction stay on the device.
public struct HomeDocumentReader: Sendable {
    public enum ReadError: LocalizedError {
        case inaccessible, oversize, unreadable, locked, restricted, unsupported
        public var errorDescription: String? {
            switch self {
            case .inaccessible: return "Open the file on this device and try again."
            case .oversize: return "Document reading supports files up to 25 MB. You can still enter the details yourself."
            case .unreadable: return "This file could not be read. You can enter its details yourself."
            case .locked: return "This PDF is password-protected. You can enter its details yourself."
            case .restricted: return "This PDF restricts text extraction. You can enter its details yourself."
            case .unsupported: return "Document reading is available for PDFs and photos on a supported device."
            }
        }
    }

    public init() {}
    public func read(file: URL) async throws -> DocumentReading {
        let worker = Task.detached(priority: .userInitiated) { try Self.process(file) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Cap each resource independently, including image-only pages within an otherwise small document.
    private static let pageLimit = 12, ocrLimit = 6, pixelEdge = 2000, pageTextLimit = 12_000

    private static func process(_ url: URL) throws -> DocumentReading {
        #if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
        try Task.checkCancellation()
        guard url.isFileURL, let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize else { throw ReadError.inaccessible }
        guard size <= Attachment.maxPDFBytes else { throw ReadError.oversize }
        guard size > 0 else { throw ReadError.unreadable }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= Attachment.maxPDFBytes else { throw ReadError.oversize }
        let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil)
        let type = imageSource.flatMap(CGImageSourceGetType)
        let hasPDFHeader = bytes.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        let pdf: PDFDocument?
        let total: Int
        if type as String? == UTType.pdf.identifier || (type == nil && hasPDFHeader) {
            guard let doc = PDFDocument(data: bytes) else { throw ReadError.unreadable }
            guard !doc.isLocked else { throw ReadError.locked }
            guard doc.allowsCopying else { throw ReadError.restricted }
            total = doc.pageCount
            pdf = doc
        } else if let imageSource {
            pdf = nil
            total = CGImageSourceGetCount(imageSource)
        } else { throw ReadError.unreadable }
        guard total > 0 else { throw ReadError.unreadable }
        var result = DocumentReading()
        result.totalPages = total
        result.truncated = total > pageLimit
        var pages: [DocumentFieldParser.Page] = []
        var ocrCount = 0
        for i in 0..<min(total, pageLimit) {
            try Task.checkCancellation()
            let text: String = autoreleasepool {
                let page = pdf?.page(at: i)
                let count = page?.numberOfCharacters ?? 0
                let native: String
                if count > pageTextLimit {
                    result.truncated = true
                    native = page?.selection(for: NSRange(location: 0, length: pageTextLimit))?.string ?? ""
                } else { native = page?.string ?? "" }
                let visible = native.trimmingCharacters(in: .whitespacesAndNewlines)
                let meaningful = visible.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.prefix(18).count
                if meaningful >= 18 { return native }
                guard ocrCount < ocrLimit else { result.truncated = true; return native }
                guard let raster = page.flatMap(rasterize) ?? imageSource.flatMap({ thumbnail($0, at: i) }) else { return native }
                result.usedOCR = true
                ocrCount += 1
                let recognized = try? ReceiptReader.recognizePage(raster).sorted { $0.y < $1.y }.map(\.text)
                guard let recognized, !recognized.isEmpty else { return native }
                return recognized.joined(separator: "\n")
            }
            if text.count > pageTextLimit { result.truncated = true }
            let lines = text.prefix(pageTextLimit).split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if lines.isEmpty { result.unreadablePages.append(i + 1) }
            else { result.pagesRead += 1; pages.append(.init(number: i + 1, lines: lines)) }
        }
        try Task.checkCancellation()
        result.candidates = DocumentFieldParser.candidates(in: pages)
        if result.candidates.count == 64 { result.truncated = true }
        return result
        #else
        throw ReadError.unsupported
        #endif
    }

    #if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO)
    private static func thumbnail(_ source: CGImageSource, at index: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelEdge, kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
    }

    private static func rasterize(_ page: PDFPage) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let box = ref.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        let rotated = !(ref.rotationAngle / 90).isMultiple(of: 2)
        let longEdge = max(box.width, box.height)
        let w = max(1, Int(((rotated ? box.height : box.width) / longEdge * CGFloat(pixelEdge)).rounded()))
        let h = max(1, Int(((rotated ? box.width : box.height) / longEdge * CGFloat(pixelEdge)).rounded()))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(rect)
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }
    #endif
}
