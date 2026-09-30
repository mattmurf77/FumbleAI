import Foundation
import HomeCore
#if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
import Vision
import ImageIO
import CoreGraphics
#endif

/// Receipt OCR (LLD §15 steps 1–3): images (HEIC/JPEG/PNG data, e.g. pages from `DocumentScannerView`) →
/// `VNRecognizeTextRequest` (.accurate, language correction, en-US + the user's locale) → `ReceiptParser`.
/// Multi-page receipts are treated as one tall page (page i occupies y ∈ [i/n, (i+1)/n]).
public struct ReceiptReader: ReceiptReading {
    public enum ReaderError: Error, Hashable, Sendable {
        /// Vision is not available on this platform (Linux tests).
        case unavailable
        case unreadableImage(index: Int)
    }

    public var parser: ReceiptParser
    public var clock: any HomeClock

    public init(parser: ReceiptParser = ReceiptParser(), clock: any HomeClock = SystemClock()) {
        self.parser = parser; self.clock = clock
    }

    public func read(images: [Data]) async throws -> ReceiptGuess {
        let lines = try await Self.recognize(images: images)
        return parser.parse(lines: lines, today: LocalDate.today(clock))
    }

    /// OCR only: recognized lines sorted top → bottom, with y normalized over all pages.
    public static func recognize(images: [Data]) async throws -> [OCRLine] {
        #if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
        let n = Double(max(images.count, 1))
        var all: [OCRLine] = []
        for (i, data) in images.enumerated() {
            let page = try await Task.detached(priority: .userInitiated) { () throws -> [OCRLine] in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ReaderError.unreadableImage(index: i) }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                var langs = ["en-US"]
                let local = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
                if local != "en-US" { langs.append(local) }
                request.recognitionLanguages = langs
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let observations = request.results ?? []
                return observations.compactMap { obs -> OCRLine? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    // Vision boxes are normalized with the origin at the bottom-left.
                    return OCRLine(text: text, y: 1 - Double(obs.boundingBox.midY))
                }
            }.value
            all += page.map { OCRLine(text: $0.text, y: (Double(i) + $0.y) / n) }
        }
        return all.sorted { $0.y < $1.y }
        #else
        throw ReaderError.unavailable
        #endif
    }
}
