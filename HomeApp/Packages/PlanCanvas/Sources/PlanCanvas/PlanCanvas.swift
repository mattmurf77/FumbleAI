import Foundation
import PlanKit
import HomeCore

// PlanCanvas — the floor-plan renderer (LLD §7).
//
// Pure (Linux-tested) layer:
//   Core/Viewport, Core/GestureController (+ Momentum), Model/LevelRenderModel, Model/RenderModelBuilder,
//   Model/LabelLayout, Lenses/* (PlanLens + the 7 lenses), Overlays/OverlayLayout (+ CanvasHitTesting),
//   Accessibility/AccessibilityModel, Editor/PlanEditSession.
// SwiftUI layer (`#if canImport(SwiftUI)`):
//   UI/PlanTheme, UI/Painter, UI/PlanCanvasView, UI/CanvasOverlays, UI/PlanListView.
// Inputs are value snapshots only: HomeCore.LevelGeometry + HomeCore.LensStats (never a DB handle).

public enum PlanCanvasModule {
    public static let name = "PlanCanvas"
}
