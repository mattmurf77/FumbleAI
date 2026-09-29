import Foundation
import PlanKit
import HomeCore
#if canImport(RoomPlan)
import RoomPlan
#endif
#if canImport(Vision)
import Vision
#endif

// HomeCapture — the plan-creation paths and receipt OCR (LLD §6.9, §6.10, §6.12, §15). Owner fills:
// RoomPlanImporter (HomeCore.RoomPlanImporting), RoomPlanLabelMap, PhotoTraceCalibrator
// (HomeCore.PhotoTraceCalibrating, wraps PlanKit.UnderlayCalibration), RoughInGenerator
// (HomeCore.RoughInGenerating, uses PlanKit.Treemap), BlockTemplates (HomeCore.BlockTemplating),
// ReceiptReader (HomeCore.ReceiptReading), ReceiptParser (HomeCore.ReceiptParsing, pure).
// All paths output HomeCore.PlanDraft.

public enum HomeCaptureModule {
    public static let name = "HomeCapture"
}
