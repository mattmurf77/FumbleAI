import Foundation
import PlanKit
import HomeCore

/// Photo-trace calibration (LLD §6.9, FR-PLN-30..35). Wraps `PlanKit.UnderlayCalibration` and builds the
/// trace `PlanDraft` (one level carrying the underlay; rooms are then drawn in the editor with `source = .trace`).
public struct PhotoTraceCalibrator: PhotoTraceCalibrating {
    /// Images whose long edge is below this get "This image is too small to trace accurately" (still allowed).
    public static let minimumLongEdgePx = 800
    public static let stretchedMessage = "This image may be stretched. Try the document scanner."
    public static let tooSmallMessage = "This image is too small to trace accurately"

    public init() {}

    public func calibrate(a: Vec2, b: Vec2, lengthIn: Double, second: (Vec2, Vec2, Double)?, imageSize: Vec2,
                          contentCenter: Vec2) -> Result<UnderlayTransform, TraceWarning> {
        let out = calibrateDetailed(a: a, b: b, lengthIn: lengthIn, second: second, imageSize: imageSize, contentCenter: contentCenter)
        switch out {
        case .failure(let w): return .failure(w)
        case .success(let o):
            if let w = o.warning { return .failure(w) }
            return .success(o.transform)
        }
    }

    /// Calibration that keeps the (averaged) transform even when the two scales disagree by > 5 %, so the UI can
    /// warn *and* continue ("Use anyway").
    public struct Calibration: Hashable, Sendable {
        public var transform: UnderlayTransform
        public var warning: TraceWarning?
    }

    public func calibrateDetailed(a: Vec2, b: Vec2, lengthIn: Double, second: (Vec2, Vec2, Double)?, imageSize: Vec2,
                                  contentCenter: Vec2) -> Result<Calibration, TraceWarning> {
        switch UnderlayCalibration.calibrate(a: a, b: b, lengthIn: lengthIn, second: second, imageSize: imageSize, contentCenter: contentCenter) {
        case .success(let o):
            let w: TraceWarning? = o.warning.map { if case .possiblyStretched(let r) = $0 { return .possiblyStretched(ratio: r) } else { return .invalidInput } }
            return .success(Calibration(transform: o.transform, warning: w))
        case .failure(.possiblyStretched(let r)): return .failure(.possiblyStretched(ratio: r))
        case .failure: return .failure(.invalidInput)
        }
    }

    /// Parses a typed calibration length to inches (FR-PLN-31: `12'4"`, `12' 4`, `12.33'`, `148"`, `148in`, `3.76m`,
    /// `376cm`). Returns nil for unparseable or ≤ 0 input ("Enter a length greater than 0").
    public static func parseLength(_ text: String, bareUnit: UnitSystem = .imperial) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        // "12' 4" (feet then bare inches) — handled here because a bare trailing number is ambiguous elsewhere.
        if let r = t.range(of: #"^(\d+(?:\.\d+)?)\s*(?:'|ft|feet|′)\s*(\d+(?:\.\d+)?)\s*(?:"|in|inches|″)?$"#, options: .regularExpression) {
            let s = String(t[r])
            let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.compactMap(Double.init)
            if nums.count == 2 { let v = nums[0] * 12 + nums[1]; return v > 0 ? v : nil }
        }
        if let v = HomeLengthFormatter.parse(text, bareUnit: bareUnit), v > 0 { return v }
        // Fallbacks for units the shared parser may not cover.
        let scanner: [(String, Double)] = [("cm", 1 / 2.54), ("mm", 1 / 25.4), ("m", HomeLengthFormatter.inchesPerMeter),
                                            ("in", 1), ("\"", 1), ("ft", 12), ("'", 12)]
        for (suffix, factor) in scanner where t.hasSuffix(suffix) {
            if let v = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)), v > 0 { return v * factor }
        }
        return nil
    }

    /// True when the image's long edge is below 800 px.
    public static func isTooSmall(widthPx: Int, heightPx: Int) -> Bool { max(widthPx, heightPx) < minimumLongEdgePx }

    /// The trace draft: one floor level carrying the underlay (50 % opacity), no rooms yet.
    public static func draft(image: AttachmentDraft, transform: UnderlayTransform, levelName: String = CaptureNaming.floorName(index: 0),
                             kind: Level.Kind = .floor, sortOrder: Int = 0) -> PlanDraft {
        var t = transform
        t.opacity = 0.5
        let level = LevelDraft(name: levelName, kind: kind, sortOrder: sortOrder, underlay: UnderlayDraft(image: image, transform: t))
        return PlanDraft(levels: [level], source: .trace)
    }

    /// A traced room: a rectangle drawn over the underlay in pixel space, mapped into level inches.
    public static func tracedSpace(name: String, type: SpaceType = .room, pixelCorners: [Vec2], transform: UnderlayTransform) -> SpaceDraft? {
        let pts = pixelCorners.map(transform.toModel(pixel:)).map { $0.rounded(to: 0.5) }
        guard let p = try? Polygon(pts) else { return nil }
        return SpaceDraft(name: name, spaceType: type, polygon: p, source: .trace)
    }
}
