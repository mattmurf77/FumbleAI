import Foundation
import PlanKit
import HomeCore

// MARK: - Decoration value types (platform-free; the SwiftUI layer maps roles to theme colors)

/// Chip variants from the mockup (`seven-views.md` §0 "Chips").
public enum ChipStyle: String, Hashable, Sendable {
    /// `--accent` fill, `--on-accent` text.
    case accent
    /// `--danger` fill.
    case danger
    /// `--room` fill with a `--wall` hairline.
    case neutral
    /// `--accent-soft` fill, `--accent` text.
    case soft
}

/// Small status dot drawn on a chip (Inventory "any low" → orange/warn).
public enum ChipDot: String, Hashable, Sendable { case warn, danger }

public struct Chip: Hashable, Sendable {
    public var text: String
    public var style: ChipStyle
    /// Bold text (To-Dos: something is due today).
    public var emphasized: Bool
    public var dot: ChipDot?
    public init(_ text: String, style: ChipStyle, emphasized: Bool = false, dot: ChipDot? = nil) {
        self.text = text; self.style = style; self.emphasized = emphasized; self.dot = dot
    }
}

/// Sequential single-hue tint (`--tint-1…3`); `.none` = default room fill.
public enum TintLevel: Int, Hashable, Sendable, Comparable {
    case none = 0, low = 1, medium = 2, high = 3
    public static func < (a: TintLevel, b: TintLevel) -> Bool { a.rawValue < b.rawValue }

    /// Relative bucket of `value` against `max` (0 → none; (0, ⅓] → low; (⅓, ⅔] → medium; above → high).
    /// `ceiling` limits the ramp (Past Work uses a light ramp: at most `.medium`).
    public static func relative(_ value: Double, max: Double, ceiling: TintLevel = .high) -> TintLevel {
        guard value > 0, max > 0 else { return .none }
        let f = value / max
        let raw: TintLevel = f <= 1.0 / 3 ? .low : (f <= 2.0 / 3 ? .medium : .high)
        return Swift.min(raw, ceiling)
    }
}

/// Inner edge stroke (To-Dos overdue: 2.4 pt `--danger`, inset 2 pt).
public struct EdgeStyle: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case danger, accent }
    public var role: Role
    public var widthPt: Double
    public var insetPt: Double
    public init(role: Role, widthPt: Double = 2.4, insetPt: Double = 2) { self.role = role; self.widthPt = widthPt; self.insetPt = insetPt }
    public static let overdue = EdgeStyle(role: .danger)
}

/// What one lens draws on one room.
public struct SpaceDecoration: Hashable, Sendable {
    /// The single room chip (under the "+").
    public var chip: Chip?
    /// Corner count chip (Appliances view, top-right of the room).
    public var cornerChip: Chip?
    /// Second label line on big rooms (replaces the dimensions). nil → the Plan dimensions.
    public var secondLine: String?
    public var secondLineIsAccent: Bool
    /// Budget big-room lines: "$3.5k planned" (accent) and "$2.8k spent" (dim).
    public var budgetLines: [String]
    public var tint: TintLevel
    public var edge: EdgeStyle?
    /// Nothing for this lens → name fades to `--ink-3`, "+" outline grey.
    public var isQuiet: Bool
    /// VoiceOver value ("3 chores due this week, 1 overdue").
    public var accessibilityValue: String
    /// Used by the "Rooms with overdue chores" rotor.
    public var hasOverdue: Bool

    public init(chip: Chip? = nil, cornerChip: Chip? = nil, secondLine: String? = nil, secondLineIsAccent: Bool = false,
                budgetLines: [String] = [], tint: TintLevel = .none, edge: EdgeStyle? = nil, isQuiet: Bool = false,
                accessibilityValue: String = "", hasOverdue: Bool = false) {
        self.chip = chip; self.cornerChip = cornerChip; self.secondLine = secondLine; self.secondLineIsAccent = secondLineIsAccent
        self.budgetLines = budgetLines; self.tint = tint; self.edge = edge; self.isQuiet = isQuiet
        self.accessibilityValue = accessibilityValue; self.hasOverdue = hasOverdue
    }
    public static let plain = SpaceDecoration()
}

/// A pin on the plan (Things glyphs, storage spots) in model coordinates plus an optional screen offset
/// (unpinned Things sit in a row under the room label).
public struct PinModel: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case thing, spot }
    public var id: String
    public var kind: Kind
    public var itemId: UUID
    public var spaceId: UUID?
    public var symbol: String
    public var anchor: Vec2
    /// Screen-space offset from `toScreen(anchor)` in points.
    public var offsetX: Double
    public var offsetY: Double
    /// Items in the spot subtree (spots) or 1.
    public var count: Int
    /// Planned purchase → dashed outline.
    public var isPlanned: Bool

    public init(kind: Kind, itemId: UUID, spaceId: UUID?, symbol: String, anchor: Vec2, offsetX: Double = 0, offsetY: Double = 0,
                count: Int = 1, isPlanned: Bool = false) {
        self.id = "\(kind.rawValue):\(itemId.uuidString)"
        self.kind = kind; self.itemId = itemId; self.spaceId = spaceId; self.symbol = symbol; self.anchor = anchor
        self.offsetX = offsetX; self.offsetY = offsetY; self.count = count; self.isPlanned = isPlanned
    }
}

/// A run of footer text with a color role.
public struct TextRun: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case normal, secondary, danger, accent, warn }
    public var text: String
    public var role: Role
    public init(_ text: String, _ role: Role = .normal) { self.text = text; self.role = role }
}

/// The bottom summary strip (two lines, optional spent-share bar).
public struct FooterSummary: Hashable, Sendable {
    public var primary: [TextRun]
    public var secondary: [TextRun]
    /// 0…1 fill of the thin bar (Budget: spent share of planned + spent).
    public var barFraction: Double?
    /// The strip links somewhere (Inventory → Shopping list).
    public var link: FooterLink?
    public init(primary: [TextRun], secondary: [TextRun] = [], barFraction: Double? = nil, link: FooterLink? = nil) {
        self.primary = primary; self.secondary = secondary; self.barFraction = barFraction; self.link = link
    }
    public var primaryText: String { primary.map(\.text).joined() }
    public var secondaryText: String { secondary.map(\.text).joined() }
}

public enum FooterLink: String, Hashable, Sendable { case shoppingList, seasonalSwap, budget, chores }

/// Per-level normalization for tints (the max of the lens metric across rooms).
public struct LensScale: Hashable, Sendable {
    public var maxValue: Double
    public init(maxValue: Double) { self.maxValue = maxValue }
    public static let none = LensScale(maxValue: 0)
}

/// Property-wide numbers some footers show ("Property · 3 levels · 3,600 sq ft · built 1994").
public struct PropertySummary: Hashable, Sendable {
    public var name: String
    public var levelCount: Int
    public var interiorAreaSqIn: Double
    public var yearBuilt: Int?
    public init(name: String = "Property", levelCount: Int, interiorAreaSqIn: Double, yearBuilt: Int? = nil) {
        self.name = name; self.levelCount = levelCount; self.interiorAreaSqIn = interiorAreaSqIn; self.yearBuilt = yearBuilt
    }
}

/// Everything a lens needs besides the stats.
public struct LensContext: Hashable, Sendable {
    public var levelName: String
    public var isExterior: Bool
    public var unitSystem: UnitSystem
    public var currency: String
    public var property: PropertySummary?
    /// Filled from geometry by `RenderModelBuilder`.
    public var roomCount: Int
    public var interiorAreaSqIn: Double
    public var zoneCount: Int
    public var lotAreaSqIn: Double
    /// Budget tints are relative to the property (floors comparable). nil → the level max.
    public var budgetScaleMaxCents: Int64?

    public init(levelName: String, isExterior: Bool = false, unitSystem: UnitSystem = .imperial, currency: String = "USD",
                property: PropertySummary? = nil, roomCount: Int = 0, interiorAreaSqIn: Double = 0, zoneCount: Int = 0,
                lotAreaSqIn: Double = 0, budgetScaleMaxCents: Int64? = nil) {
        self.levelName = levelName; self.isExterior = isExterior; self.unitSystem = unitSystem; self.currency = currency
        self.property = property; self.roomCount = roomCount; self.interiorAreaSqIn = interiorAreaSqIn
        self.zoneCount = zoneCount; self.lotAreaSqIn = lotAreaSqIn; self.budgetScaleMaxCents = budgetScaleMaxCents
    }
}

// MARK: - Lens protocol (LLD §7.4, adapted: pure value outputs, no SwiftUI types)

public protocol PlanLens: Sendable {
    var id: LensID { get }
    /// Per-level normalization for tints.
    func scale(_ stats: LensStats, context: LensContext) -> LensScale
    /// Chip, tint, edge, quiet flag and VoiceOver value for one room.
    func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration
    /// Pins drawn on the level (default: none).
    func pins(_ stats: LensStats, geometry: LevelGeometryRender) -> [PinModel]
    /// The bottom summary strip.
    func footer(_ stats: LensStats, context: LensContext) -> FooterSummary
    /// Count for the "Whole house · N" / "This floor · N" chips; nil → no chip in this lens.
    func scopeCount(_ s: ScopeStats) -> Int?
}

public extension PlanLens {
    var title: String { id.title }
    var symbol: String { id.symbol }
    var addDefault: AddKind? { id.addDefault }
    func scale(_ stats: LensStats, context: LensContext) -> LensScale { .none }
    func pins(_ stats: LensStats, geometry: LevelGeometryRender) -> [PinModel] { [] }
}

/// The seven lens implementations keyed by `LensID`.
public enum LensRegistry {
    public static func lens(for id: LensID) -> any PlanLens {
        switch id {
        case .plan: return PlanViewLens()
        case .todos: return TodosLens()
        case .futureProjects: return FutureProjectsLens()
        case .pastWork: return PastWorkLens()
        case .things: return ThingsLens()
        case .inventory: return InventoryLens()
        case .budget: return BudgetLens()
        }
    }
    public static var all: [any PlanLens] { LensID.allCases.map(lens(for:)) }
}
