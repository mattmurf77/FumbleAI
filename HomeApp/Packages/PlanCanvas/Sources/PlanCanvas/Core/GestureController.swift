import Foundation
import PlanKit

/// Pan momentum like UIScrollView: displacement `v·τ·(1 − e^(−t/τ))`, τ = 325 ms. LLD §7.1.
public struct Momentum: Hashable, Sendable {
    public static let tau: Double = 0.325
    /// Below this speed (pt/s) no momentum starts.
    public static let minimumSpeed: Double = 120

    /// Initial velocity, points per second.
    public var velocity: CGSize
    public init(velocity: CGSize) { self.velocity = velocity }

    public var isSignificant: Bool {
        (Double(velocity.width * velocity.width + velocity.height * velocity.height)).squareRoot() >= Momentum.minimumSpeed
    }

    /// Total displacement after `t` seconds.
    public func displacement(at t: Double) -> CGSize {
        let k = Momentum.tau * (1 - exp(-max(t, 0) / Momentum.tau))
        return CGSize(width: Double(velocity.width) * k, height: Double(velocity.height) * k)
    }

    /// The decay is finished once the remaining travel is under half a point (≈ 5τ for normal flicks).
    public func isFinished(at t: Double) -> Bool {
        let speed = (Double(velocity.width * velocity.width + velocity.height * velocity.height)).squareRoot()
        return speed * Momentum.tau * exp(-max(t, 0) / Momentum.tau) < 0.5
    }
}

/// Pure pan/pinch state machine. SwiftUI gesture callbacks feed it; it returns the viewport to show.
/// Pan and pinch may run simultaneously: each update is applied relative to the viewport at gesture start.
public struct GestureController: Hashable, Sendable {
    public private(set) var base: Viewport?
    public private(set) var panTranslation: CGSize = .zero
    public private(set) var magnification: Double = 1
    public private(set) var pinchAnchor: CGPoint?
    /// Content bounds used to clamp panning (nil = unclamped).
    public var contentBounds: Rect?

    public init(contentBounds: Rect? = nil) { self.contentBounds = contentBounds }

    public var isActive: Bool { base != nil }
    public var isPinching: Bool { pinchAnchor != nil }

    private mutating func ensureBase(_ current: Viewport) {
        if base == nil { base = current; panTranslation = .zero; magnification = 1; pinchAnchor = nil }
    }

    /// One-finger drag (translation since the drag began).
    public mutating func pan(translation: CGSize, current: Viewport) -> Viewport {
        ensureBase(current)
        panTranslation = translation
        return resolved()
    }

    /// Pinch (cumulative magnification since the pinch began) around `anchor` in canvas points.
    public mutating func pinch(magnification m: Double, anchor: CGPoint, current: Viewport) -> Viewport {
        ensureBase(current)
        if pinchAnchor == nil { pinchAnchor = anchor }
        magnification = m
        return resolved()
    }

    private func resolved() -> Viewport {
        guard var v = base else { return .zero }
        if let a = pinchAnchor { v.zoom(by: magnification, anchor: a) }
        v.pan(by: panTranslation)
        if let c = contentBounds { v = v.clamped(toContent: c) }
        return v
    }

    /// Ends the pan; returns the momentum to run (nil when the flick is too slow or a pinch is in progress).
    public mutating func endPan(velocity: CGSize) -> Momentum? {
        let pinching = isPinching
        if pinching, var b = base {
            // Fold the translation into the base so the ongoing pinch keeps it: zoom(b') == pan(zoom(b)).
            let k = magnification > 0 ? magnification : 1
            var probe = b; probe.zoom(by: magnification, anchor: pinchAnchor ?? .zero)
            let effectiveK = probe.scale / b.scale
            b.pan(by: CGSize(width: Double(panTranslation.width) / (effectiveK > 0 ? effectiveK : k),
                             height: Double(panTranslation.height) / (effectiveK > 0 ? effectiveK : k)))
            base = b
        }
        panTranslation = .zero
        rebaseIfIdle()
        let m = Momentum(velocity: velocity)
        return (!pinching && m.isSignificant) ? m : nil
    }

    public mutating func endPinch() {
        if let a = pinchAnchor, var b = base {
            // Fold the zoom into the base so the ongoing pan keeps it.
            b.zoom(by: magnification, anchor: a)
            base = b
        }
        pinchAnchor = nil
        magnification = 1
        rebaseIfIdle()
    }

    /// Commit the current result as the new base (called when one of two simultaneous gestures ends).
    public mutating func rebase(to current: Viewport) {
        base = current; panTranslation = .zero; magnification = 1
        if pinchAnchor != nil { pinchAnchor = nil }
    }

    private mutating func rebaseIfIdle() {
        if panTranslation == .zero && pinchAnchor == nil { base = nil }
    }

    public mutating func cancel() { base = nil; panTranslation = .zero; magnification = 1; pinchAnchor = nil }

    /// Applies momentum travel to a viewport captured when the decay started.
    public static func apply(_ momentum: Momentum, to start: Viewport, elapsed: Double, contentBounds: Rect?) -> Viewport {
        var v = start
        v.pan(by: momentum.displacement(at: elapsed))
        if let c = contentBounds { v = v.clamped(toContent: c) }
        return v
    }
}
