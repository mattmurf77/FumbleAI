import Foundation
import PlanKit

/// Level of detail for a room label at the current zoom (LLD §6.7 visibility rules, `r_pt = radius · scale`).
public enum LabelLOD: Int, Hashable, Sendable, Comparable {
    /// < 11 pt: nothing drawn (room still tappable).
    case hidden = 0
    /// 11–30 pt: name only (caption2); "+" hidden (the room sheet header has one). Halls and small yard zones
    /// land here: a caption fits in a 22 pt band, so they keep their name.
    case nameOnly = 1
    /// 30–48 pt: name + "+"; the chip replaces the dimensions.
    case medium = 2
    /// ≥ 48 pt: name + dims/second line + "+" + chip.
    case full = 3

    public static func < (a: LabelLOD, b: LabelLOD) -> Bool { a.rawValue < b.rawValue }

    public static func forRadius(points r: Double) -> LabelLOD {
        switch r {
        case 48...: return .full
        case 30..<48: return .medium
        case 11..<30: return .nameOnly
        default: return .hidden
        }
    }

    public var showsAddButton: Bool { self >= .medium }
    public var showsChip: Bool { self >= .medium }
    public var showsSecondLine: Bool { self == .full }
}

/// Screen-space layout of the label stack around the pole (points, relative to `toScreen(pole)`).
/// Mockup stack (big rooms): name, second line, "+", chip.
public struct LabelLayout: Hashable, Sendable {
    public var lod: LabelLOD
    public var nameOffsetY: Double
    public var secondLineOffsetY: Double?
    public var addOffsetY: Double?
    public var chipOffsetY: Double?
    /// Budget big-room lines below the "+".
    public var budgetLinesOffsetY: Double?

    /// Visible "+" diameter and hit area.
    public static let addVisibleSize: Double = 28
    public static let addHitSize: Double = 44
    public static let lineHeight: Double = 13

    public static func layout(radiusPoints r: Double, hasChip: Bool, hasBudgetLines: Bool = false, allowsAdd: Bool = true) -> LabelLayout {
        let lod = LabelLOD.forRadius(points: r)
        switch lod {
        case .hidden:
            return LabelLayout(lod: lod, nameOffsetY: 0)
        case .nameOnly:
            return LabelLayout(lod: lod, nameOffsetY: 0)
        case .medium:
            // name, chip (in place of dims), "+"
            return LabelLayout(lod: lod, nameOffsetY: -16, secondLineOffsetY: nil,
                               addOffsetY: allowsAdd ? 16 : nil, chipOffsetY: hasChip ? (allowsAdd ? -1 : 4) : nil)
        case .full:
            // LLD: label block at pole − 14 pt, "+" at pole + 18 pt; chip under the "+".
            if hasBudgetLines {
                return LabelLayout(lod: lod, nameOffsetY: -30, secondLineOffsetY: -16, addOffsetY: allowsAdd ? 6 : nil,
                                   chipOffsetY: nil, budgetLinesOffsetY: allowsAdd ? 28 : 6)
            }
            return LabelLayout(lod: lod, nameOffsetY: -22, secondLineOffsetY: -8, addOffsetY: allowsAdd ? 16 : nil,
                               chipOffsetY: hasChip ? (allowsAdd ? 40 : 12) : nil)
        }
    }

    /// Anchor in screen points given the pole's screen position.
    public static func point(_ pole: CGPoint, dy: Double) -> CGPoint { CGPoint(x: pole.x, y: Double(pole.y) + dy) }
}

/// Room-name abbreviations for very narrow rooms (< 5′6″ = 66 in). `seven-views.md` §0.
public enum ShortNames {
    public static let narrowThresholdIn: Double = 66

    public static func short(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "half bath", "half bathroom", "powder room": return "½ Bath"
        case "closet", "coat closet", "linen closet": return "Cl."
        case "laundry", "laundry room": return "Ldy."
        case "bathroom", "full bath": return "Bath"
        case "storage": return "Stor."
        case "hallway", "hall": return "Hall"
        case "pantry": return "Pan."
        case "mudroom": return "Mud"
        case "utility": return "Util."
        default:
            if name.count <= 6 { return name }
            return String(name.prefix(4)) + "."
        }
    }
}
