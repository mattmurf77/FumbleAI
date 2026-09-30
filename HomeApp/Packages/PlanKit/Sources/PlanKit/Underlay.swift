import Foundation

/// Photo-trace underlay placement (stored in `level.underlay_transform_json`). LLD §6.9.
/// Pixel → model: m = R(rotationRad)·(p·inchesPerPixel) + originIn.
public struct UnderlayTransform: Hashable, Codable, Sendable {
    public var inchesPerPixel: Double
    /// Applied about the image origin.
    public var rotationRad: Double
    /// Where image pixel (0,0) lands in level coordinates.
    public var originIn: Vec2
    /// 0.5 default.
    public var opacity: Double

    public init(inchesPerPixel: Double, rotationRad: Double = 0, originIn: Vec2 = .zero, opacity: Double = 0.5) {
        self.inchesPerPixel = inchesPerPixel; self.rotationRad = rotationRad; self.originIn = originIn; self.opacity = opacity
    }

    public var pixelToModel: Transform2D {
        Transform2D.scale(inchesPerPixel).then(.rotation(rotationRad)).then(.translation(originIn))
    }
    public var modelToPixel: Transform2D { pixelToModel.inverse ?? .identity }

    public func toModel(pixel p: Vec2) -> Vec2 { pixelToModel.apply(p) }
    public func toPixel(model m: Vec2) -> Vec2 { modelToPixel.apply(m) }
}

/// Pure two-point scale calibration math (§6.9 steps 3–5). `HomeCapture.PhotoTraceCalibrator` wraps it.
public enum UnderlayCalibration {
    public enum Warning: Error, Hashable, Sendable {
        /// The two measured scales differ by more than 5 %: "This image may be stretched."
        case possiblyStretched(ratio: Double)
        /// A–B too short or length ≤ 0.
        case invalidInput
    }

    public struct Output: Hashable, Sendable {
        public var transform: UnderlayTransform
        public var warning: Warning?
    }

    /// - Parameters:
    ///   - a, b: pixel points; `lengthIn`: the real length between them.
    ///   - second: optional second calibration pair on a roughly perpendicular wall.
    ///   - imageSize: pixel size, used to center the image on `contentCenter`.
    public static func calibrate(a: Vec2, b: Vec2, lengthIn: Double,
                                 second: (Vec2, Vec2, Double)? = nil,
                                 imageSize: Vec2, contentCenter: Vec2 = .zero) -> Result<Output, Warning> {
        let px = a.distance(to: b)
        guard px > 1, lengthIn > 0 else { return .failure(.invalidInput) }
        var s = lengthIn / px
        var warning: Warning?
        if let (c, d, l2) = second {
            let px2 = c.distance(to: d)
            guard px2 > 1, l2 > 0 else { return .failure(.invalidInput) }
            let s2 = l2 / px2
            let ratio = abs(s - s2) / s
            if ratio > 0.05 { warning = .possiblyStretched(ratio: ratio) }
            s = (s + s2) / 2
        }
        let phi = atan2(b.y - a.y, b.x - a.x)
        let quarter = Double.pi / 2
        let nearest = (phi / quarter).rounded() * quarter
        let rotation = abs(phi - nearest) <= Geometry.radians(5) ? -(phi - nearest) : 0
        var t = UnderlayTransform(inchesPerPixel: s, rotationRad: rotation, originIn: .zero)
        // Place the image center on the content center.
        let centerModel = t.toModel(pixel: imageSize / 2)
        t.originIn = contentCenter - centerModel
        return .success(Output(transform: t, warning: warning))
    }
}
