import Foundation
import HomeCore
#if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
import Vision
import ImageIO
import CoreGraphics
#endif

/// OCR for appliance labels / rating plates ("Scan label" on the item form): Vision text recognition (.accurate,
/// language correction off so model and serial numbers are not "corrected" into words) → rows of text, top to
/// bottom, with pieces on the same row joined left to right (`LabelReader.rows`). Parse the result with
/// `LabelReader.read(lines:)`. Honors the photo's EXIF orientation (camera-roll photos are often stored sideways).
public enum LabelTextRecognizer {
    public enum RecognizerError: Error, Hashable, Sendable {
        /// Vision is not available on this platform (Linux tests).
        case unavailable
        case unreadableImage(index: Int)
    }

    /// Rows for all images in order (several pages from the document camera are read one after another).
    public static func rows(images: [Data]) async throws -> [String] {
        var all: [String] = []
        for (i, data) in images.enumerated() {
            all += try await rows(image: data, index: i)
        }
        return all
    }

    static func rows(image data: Data, index: Int) async throws -> [String] {
        #if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
        return try await Task.detached(priority: .userInitiated) { () throws -> [String] in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RecognizerError.unreadableImage(index: index) }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
            let fragments = (request.results ?? []).compactMap { obs -> LabelReader.Fragment? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                // Vision boxes are normalized (in the oriented image) with the origin at the bottom-left.
                let box = obs.boundingBox
                return LabelReader.Fragment(text: text, x: Double(box.minX), y: 1 - Double(box.midY), height: Double(box.height))
            }
            return LabelReader.rows(from: fragments)
        }.value
        #else
        throw RecognizerError.unavailable
        #endif
    }
}
