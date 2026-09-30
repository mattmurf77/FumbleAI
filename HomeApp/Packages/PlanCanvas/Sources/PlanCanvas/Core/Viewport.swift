import Foundation
import PlanKit

/// Screen-space insets (points). Platform-free stand-in for SwiftUI `EdgeInsets`.
public struct ViewportInsets: Hashable, Sendable {
    public var top: Double, leading: Double, bottom: Double, trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public init(all v: Double) { self.init(top: v, leading: v, bottom: v, trailing: v) }
    public static let zero = ViewportInsets()
    /// Default canvas padding around a fitted floor.
    public static let canvasDefault = ViewportInsets(top: 28, leading: 16, bottom: 28, trailing: 16)
}

/// Maps level-local model coordinates (inches, y down) to canvas points. LLD §7.1.
/// Pure value type: every mutation is a plain function of its inputs (tested on Linux).
public struct Viewport: Hashable, Sendable {
    /// Points per inch.
    public var scale: Double
    /// Screen position of model (0, 0).
    public var origin: CGPoint
    /// Canvas size in points.
    public var size: CGSize
    /// Height of the room sheet covering the bottom of the canvas (keeps the selection visible).
    public var obscuredBottom: Double
    /// Scale that fits the whole level (drives the zoom limits). 0 until the first `fit`.
    public var fitScale: Double

    public init(scale: Double = 1, origin: CGPoint = .zero, size: CGSize = .zero, obscuredBottom: Double = 0, fitScale: Double = 0) {
        self.scale = scale; self.origin = origin; self.size = size; self.obscuredBottom = obscuredBottom; self.fitScale = fitScale
    }

    public static let zero = Viewport()

    /// True once the viewport has a real size and a fitted scale.
    public var isConfigured: Bool { size.width > 0 && size.height > 0 && fitScale > 0 }

    // MARK: Mapping

    public func toScreen(_ p: Vec2) -> CGPoint {
        CGPoint(x: Double(origin.x) + p.x * scale, y: Double(origin.y) + p.y * scale)
    }

    public func toModel(_ p: CGPoint) -> Vec2 {
        Vec2(x: (Double(p.x) - Double(origin.x)) / scale, y: (Double(p.y) - Double(origin.y)) / scale)
    }

    public func toScreen(_ r: Rect) -> CGRect {
        guard !r.isNull else { return .null }
        let a = toScreen(Vec2(x: r.minX, y: r.minY))
        return CGRect(x: a.x, y: a.y, width: r.width * scale, height: r.height * scale)
    }

    /// Model-space length of `points` screen points.
    public func modelLength(points: Double) -> Double { points / max(scale, 1e-9) }

    /// The model rectangle currently visible on the canvas.
    public var visibleModelRect: Rect {
        let a = toModel(.zero)
        let b = toModel(CGPoint(x: size.width, y: size.height))
        return Rect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }

    /// Screen rectangle not covered by the room sheet.
    public var unobscuredScreenRect: CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: max(0, Double(size.height) - obscuredBottom))
    }

    // MARK: Fit / zoom / pan

    /// Zoom limits `[fitScale·0.8, max(fitScale·8, 12.5)]` (LLD §7.1; 12.5 pt/in = 150 pt per foot).
    public static func zoomLimits(fitScale: Double) -> ClosedRange<Double> {
        let lo = max(fitScale * 0.8, 1e-4)
        return lo...max(fitScale * 8, 12.5, lo)
    }

    public var zoomLimits: ClosedRange<Double> { Viewport.zoomLimits(fitScale: fitScale > 0 ? fitScale : scale) }

    /// Fits `bounds` centered in `size` minus `insets`.
    public static func fit(_ bounds: Rect, in size: CGSize, insets: ViewportInsets = .canvasDefault) -> Viewport {
        let availW = max(1, Double(size.width) - insets.leading - insets.trailing)
        let availH = max(1, Double(size.height) - insets.top - insets.bottom)
        guard !bounds.isNull, bounds.width > 0 || bounds.height > 0 else {
            // Empty level: 1 ft = 30 pt, model origin at the center.
            let s = 2.5
            return Viewport(scale: s, origin: CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2), size: size, fitScale: s)
        }
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let s = min(availW / w, availH / h)
        let cx = insets.leading + availW / 2, cy = insets.top + availH / 2
        let c = bounds.center
        return Viewport(scale: s, origin: CGPoint(x: cx - c.x * s, y: cy - c.y * s), size: size, fitScale: s)
    }

    /// `s' = clamp(s·factor)`, `origin' = anchor − (anchor − origin)·(s'/s)`: the model point under `anchor` stays put.
    public mutating func zoom(by factor: Double, anchor: CGPoint, limits: ClosedRange<Double>? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let lim = limits ?? zoomLimits
        let newScale = min(max(scale * factor, lim.lowerBound), lim.upperBound)
        let k = newScale / scale
        origin = CGPoint(x: Double(anchor.x) - (Double(anchor.x) - Double(origin.x)) * k,
                         y: Double(anchor.y) - (Double(anchor.y) - Double(origin.y)) * k)
        scale = newScale
    }

    public mutating func pan(by delta: CGSize) {
        origin = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
    }

    /// Keeps at least `margin` points of `content` on screen (the plan can't be flung away).
    public func clamped(toContent content: Rect, margin: Double = 64) -> Viewport {
        guard !content.isNull, size.width > 0 else { return self }
        var v = self
        let r = toScreen(content)
        let w = Double(size.width), h = Double(size.height)
        let m = min(margin, Double(r.width) / 2, Double(r.height) / 2)
        var dx = 0.0, dy = 0.0
        if Double(r.maxX) < m { dx = m - Double(r.maxX) }
        if Double(r.minX) > w - m { dx = (w - m) - Double(r.minX) }
        if Double(r.maxY) < m { dy = m - Double(r.maxY) }
        if Double(r.minY) > h - m { dy = (h - m) - Double(r.minY) }
        v.pan(by: CGSize(width: dx, height: dy))
        return v
    }

    /// Zooms and centers on `rect` (double-tap on a room) within the unobscured area, respecting zoom limits.
    public func focusing(on rect: Rect, padding: Double = 32) -> Viewport {
        guard !rect.isNull else { return self }
        let area = unobscuredScreenRect
        let availW = max(1, Double(area.width) - 2 * padding), availH = max(1, Double(area.height) - 2 * padding)
        let lim = zoomLimits
        let s = min(max(min(availW / max(rect.width, 1), availH / max(rect.height, 1)), lim.lowerBound), lim.upperBound)
        var v = self
        v.scale = s
        let c = rect.center
        v.origin = CGPoint(x: Double(area.midX) - c.x * s, y: Double(area.midY) - c.y * s)
        return v
    }

    /// Minimal pan (no zoom change) that brings `rect` fully into the unobscured area; `self` if already visible.
    /// Used when the room sheet opens at the half detent (LLD §7.1 "sheet awareness").
    public func revealing(_ rect: Rect, padding: Double = 16) -> Viewport {
        guard !rect.isNull else { return self }
        let area = unobscuredScreenRect.insetBy(dx: padding, dy: padding)
        let r = toScreen(rect)
        guard area.width > 0, area.height > 0 else { return self }
        if r.width > area.width || r.height > area.height {
            // Too big to reveal at this zoom: center it instead.
            var v = self
            v.pan(by: CGSize(width: Double(area.midX - r.midX), height: Double(area.midY - r.midY)))
            return v
        }
        var dx = 0.0, dy = 0.0
        if r.minX < area.minX { dx = Double(area.minX - r.minX) } else if r.maxX > area.maxX { dx = Double(area.maxX - r.maxX) }
        if r.minY < area.minY { dy = Double(area.minY - r.minY) } else if r.maxY > area.maxY { dy = Double(area.maxY - r.maxY) }
        if dx == 0, dy == 0 { return self }
        var v = self
        v.pan(by: CGSize(width: dx, height: dy))
        return v
    }

    /// Resizes the canvas keeping the model point at the old center in the new center.
    public func resized(to newSize: CGSize) -> Viewport {
        guard size.width > 0, size.height > 0 else { var v = self; v.size = newSize; return v }
        let center = toModel(CGPoint(x: size.width / 2, y: size.height / 2))
        var v = self
        v.size = newSize
        v.origin = CGPoint(x: Double(newSize.width) / 2 - center.x * scale, y: Double(newSize.height) / 2 - center.y * scale)
        return v
    }

    /// Interpolation for animated transitions (Reduce Motion callers skip it).
    public func interpolated(to other: Viewport, _ t: Double) -> Viewport {
        var v = other
        v.scale = scale + (other.scale - scale) * t
        v.origin = CGPoint(x: Double(origin.x) + Double(other.origin.x - origin.x) * t,
                           y: Double(origin.y) + Double(other.origin.y - origin.y) * t)
        return v
    }
}

#if canImport(CoreGraphics)
import CoreGraphics
public extension Viewport {
    /// Model → screen affine transform for `Path.applying`.
    var affine: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y) }
}
#endif
