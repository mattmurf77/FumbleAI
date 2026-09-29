import Foundation
import PlanKit
import HomeCore
#if canImport(SwiftUI)
import SwiftUI
#endif

// PlanCanvas — SwiftUI Canvas renderer, viewport, gestures, the 7 lenses and overlays (LLD §7). Owner fills:
// PlanCanvasView, Viewport, GestureController, LevelRenderModel, RenderModelBuilder, Painter, TextCache,
// Lenses/* (PlanLens protocol keyed by HomeCore.LensID), Overlays/*, Accessibility/*.
// Inputs are value snapshots only: HomeCore.LevelGeometry + HomeCore.LensStats (never a DB handle).
// Geometry: PlanKit.WallDerivation, PolyLabel, HitTester, Snapper.

public enum PlanCanvasModule {
    public static let name = "PlanCanvas"
}
