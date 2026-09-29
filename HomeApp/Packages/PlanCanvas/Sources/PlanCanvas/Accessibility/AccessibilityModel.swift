import Foundation
import PlanKit
import HomeCore

/// One VoiceOver element per room (LLD §7.6, FR-CNV-50): label = name, value = dims + lens summary,
/// frame = the room's on-screen bbox grown to at least 44 × 44 pt.
public struct AccessibilityRoom: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var value: String
    public var frame: CGRect
    public var hasOverdue: Bool
}

public enum AccessibilityModel {
    public static let minimumSize: Double = 44

    /// Rooms in reading order (top-to-bottom, then left-to-right by pole).
    public static func rooms(model: LevelRenderModel, viewport v: Viewport) -> [AccessibilityRoom] {
        model.spaces
            .sorted { ($0.pole.y, $0.pole.x) < ($1.pole.y, $1.pole.x) }
            .map { s in
                let d = model.lens.decoration(s.id)
                let r = v.toScreen(s.bbox)
                let w = max(Double(r.width), minimumSize), h = max(Double(r.height), minimumSize)
                return AccessibilityRoom(id: s.id, label: s.name, value: d.accessibilityValue,
                                         frame: CGRect(x: Double(r.midX) - w / 2, y: Double(r.midY) - h / 2, width: w, height: h),
                                         hasOverdue: d.hasOverdue)
            }
    }

    /// Entries for the "Rooms with overdue chores" rotor.
    public static func overdueRooms(model: LevelRenderModel, viewport v: Viewport) -> [AccessibilityRoom] {
        rooms(model: model, viewport: v).filter(\.hasOverdue)
    }

    public struct ListRow: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var value: String
        public var chip: Chip?
    }

    /// List-mirror rows (PlanListView): same lens values without screen frames.
    public static func listRows(model: LevelRenderModel) -> [ListRow] {
        model.spaces
            .sorted { ($0.isExterior ? 1 : 0, $0.name) < ($1.isExterior ? 1 : 0, $1.name) }
            .map { s in
                let d = model.lens.decoration(s.id)
                return ListRow(id: s.id, name: s.name, value: d.accessibilityValue, chip: d.chip ?? d.cornerChip)
            }
    }
}
