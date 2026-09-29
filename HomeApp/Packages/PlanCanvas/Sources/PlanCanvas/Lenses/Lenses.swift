import Foundation
import PlanKit
import HomeCore

// The seven lenses (LLD §7.4, `seven-views.md` §1–7). Where the two disagree the mockup spec wins for encodings,
// and PRD Q-1's documented default is used for tints (fixed steps for Future Projects; relative ramps for Past Work
// and Budget).

// MARK: 1. Plan

public struct PlanViewLens: PlanLens {
    public init() {}
    public var id: LensID { .plan }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration { .plain }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        if context.isExterior {
            var a = "\(context.levelName) · \(LensFormat.count(context.zoneCount, "zone"))"
            if context.lotAreaSqIn > 0 { a += " · lot \(LensFormat.area(context.lotAreaSqIn, system: context.unitSystem))" }
            return FooterSummary(primary: [TextRun(a)], secondary: [TextRun("Drag zones to fit in edit mode", .secondary)])
        }
        let rooms = max(context.roomCount, stats.roomCount)
        let area = context.interiorAreaSqIn > 0 ? context.interiorAreaSqIn : stats.interiorAreaSqIn
        let a = "\(context.levelName) · \(LensFormat.count(rooms, "room")) · \(LensFormat.area(area, system: context.unitSystem))"
        var b: [TextRun] = []
        if let p = context.property {
            var t = "\(p.name) · \(LensFormat.count(p.levelCount, "level")) · \(LensFormat.area(p.interiorAreaSqIn, system: context.unitSystem))"
            if let y = p.yearBuilt { t += " · built \(y)" }
            b = [TextRun(t, .secondary)]
        }
        return FooterSummary(primary: [TextRun(a)], secondary: b)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { nil }
}

// MARK: 2. To-Dos

public struct TodosLens: PlanLens {
    public init() {}
    public var id: LensID { .todos }

    /// Chores due by today + 6 (overdue included).
    static func dueCount(_ s: ScopeStats) -> Int { s.overdue + s.dueWeek }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let n = Self.dueCount(s)
        var d = SpaceDecoration(isQuiet: n == 0, accessibilityValue: accessibilityValue(s), hasOverdue: s.overdue > 0)
        if n > 0 {
            d.chip = Chip(s.overdue > 0 ? "! \(n) due" : "\(n) due", style: s.overdue > 0 ? .danger : .accent,
                          emphasized: s.dueToday > 0)
        }
        if s.overdue > 0 { d.edge = .overdue }
        return d
    }

    func accessibilityValue(_ s: ScopeStats) -> String {
        if s.overdue == 0 && s.dueWeek == 0 { return "No chores due this week" }
        var parts = ["\(LensFormat.count(s.dueWeek, "chore")) due this week"]
        if s.dueToday > 0 { parts.append("\(s.dueToday) today") }
        if s.overdue > 0 { parts.append("\(s.overdue) overdue") }
        return parts.joined(separator: ", ")
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal
        var primary: [TextRun]
        if Self.dueCount(f) == 0 {
            primary = [TextRun("No chores due this week")]
        } else {
            primary = [TextRun("\(f.dueToday) today · \(max(0, f.dueWeek - f.dueToday)) this week")]
            if f.overdue > 0 { primary += [TextRun(" · "), TextRun("\(f.overdue) overdue", .danger)] }
        }
        let p = stats.propertyTotal
        var secondary = [TextRun("Home · \(p.dueWeek) due this week", .secondary)]
        if p.overdue > 0 { secondary += [TextRun(" · ", .secondary), TextRun("\(p.overdue) overdue", .danger)] }
        return FooterSummary(primary: primary, secondary: secondary, link: .chores)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.openChores }
}

// MARK: 3. Future Projects

public struct FutureProjectsLens: PlanLens {
    public init() {}
    public var id: LensID { .futureProjects }

    /// PRD Q-1 default: fixed steps (< $1,000 · $1,000–$4,999 · ≥ $5,000).
    public static func tint(plannedCents: Int64) -> TintLevel {
        switch plannedCents {
        case ..<1: return .none
        case ..<100_000: return .low
        case ..<500_000: return .medium
        default: return .high
        }
    }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let r = s.rollup
        let n = r.openCount + r.ideaCount
        var d = SpaceDecoration(tint: Self.tint(plannedCents: r.plannedCents), isQuiet: n == 0)
        if r.plannedCents > 0 {
            d.chip = Chip(LensFormat.compact(r.plannedCents, currency: context.currency) + (n >= 2 ? " · \(n)" : ""), style: .accent)
        } else if r.ideaCount > 0 {
            d.chip = Chip(LensFormat.count(r.ideaCount, "idea"), style: .soft)
        }
        if n > 0 { d.secondLine = LensFormat.count(n, "project") }
        d.accessibilityValue = n == 0 ? "No planned projects"
            : "\(LensFormat.money(r.plannedCents, currency: context.currency)) planned, \(LensFormat.count(n, "project"))"
        return d
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal.rollup, p = stats.propertyTotal.rollup
        let fn = f.openCount + f.ideaCount, pn = p.openCount + p.ideaCount
        var a = "\(context.levelName) planned \(LensFormat.money(f.plannedCents, currency: context.currency)) · \(LensFormat.count(fn, "project"))"
        if f.inProgressCount > 0 { a += " · \(f.inProgressCount) in progress" }
        let b = "Home \(LensFormat.money(p.plannedCents, currency: context.currency)) across \(LensFormat.count(pn, "project"))"
        return FooterSummary(primary: [TextRun(a)], secondary: [TextRun(b, .secondary)], link: .budget)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.rollup.openCount + s.rollup.ideaCount }
}

// MARK: 4. Past Work

public struct PastWorkLens: PlanLens {
    public init() {}
    public var id: LensID { .pastWork }

    public func scale(_ stats: LensStats, context: LensContext) -> LensScale {
        LensScale(maxValue: Double(stats.spaces.values.map(\.rollup.lifetimeCents).max() ?? 0))
    }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let r = s.rollup
        var d = SpaceDecoration(isQuiet: r.doneCount == 0)
        guard r.doneCount > 0 else { d.accessibilityValue = "No past work"; return d }
        d.chip = Chip(r.lifetimeCents > 0 ? LensFormat.compact(r.lifetimeCents, currency: context.currency)
                                          : LensFormat.count(r.doneCount, "job"), style: .neutral)
        if let last = r.lastCompletedOn { d.secondLine = "last \(LensFormat.monthYear(last))" }
        // Light ramp relative to the busiest room on the floor (PRD Q-1 default).
        d.tint = TintLevel.relative(Double(r.lifetimeCents), max: scale.maxValue, ceiling: .medium)
        var v = "\(LensFormat.money(r.lifetimeCents, currency: context.currency)) spent, \(LensFormat.count(r.doneCount, "project")) done"
        if let last = r.lastCompletedOn { v += ", last \(LensFormat.monthYear(last))" }
        d.accessibilityValue = v
        return d
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal.rollup, p = stats.propertyTotal.rollup
        var a = "\(context.levelName) lifetime \(LensFormat.money(f.lifetimeCents, currency: context.currency))"
        if let last = f.lastCompletedOn { a += " · last \(LensFormat.monthYear(last))" }
        let b = "Home lifetime \(LensFormat.money(p.lifetimeCents, currency: context.currency)) · \(LensFormat.count(p.doneCount, "project")) done"
        return FooterSummary(primary: [TextRun(a)], secondary: [TextRun(b, .secondary)], link: .budget)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.rollup.doneCount }
}

// MARK: 5. Appliances, Electronics & Furniture

public struct ThingsLens: PlanLens {
    public init() {}
    public var id: LensID { .things }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let total = s.thingCount + s.plannedThingCount
        var d = SpaceDecoration(isQuiet: total == 0)
        if total > 0 { d.cornerChip = Chip("\(total)", style: .neutral) }
        var v = total == 0 ? "Nothing tracked" : LensFormat.count(s.thingCount, "item")
        if s.plannedThingCount > 0 { v += ", \(s.plannedThingCount) planned" }
        if s.warrantiesEndingSoon > 0 { v += ", \(LensFormat.count(s.warrantiesEndingSoon, "warranty", "warranties")) ending soon" }
        d.accessibilityValue = v
        return d
    }

    /// Pinned Things at their pin; unpinned ones in a row 30 pt under the room label (20 pt apart).
    public func pins(_ stats: LensStats, geometry: LevelGeometryRender) -> [PinModel] {
        var out: [PinModel] = []
        var unpinned: [UUID: [ThingPin]] = [:]
        let spaceIds = Set(geometry.spaces.map(\.id))
        for t in stats.thingPins {
            if let p = t.pin {
                out.append(PinModel(kind: .thing, itemId: t.thingId, spaceId: t.spaceId, symbol: t.symbol, anchor: p,
                                    isPlanned: t.ownership == .planned))
            } else if let s = t.spaceId, spaceIds.contains(s) {
                unpinned[s, default: []].append(t)
            }
        }
        for sp in geometry.spaces {
            guard let row = unpinned[sp.id], !row.isEmpty else { continue }
            let n = Double(row.count)
            for (i, t) in row.enumerated() {
                out.append(PinModel(kind: .thing, itemId: t.thingId, spaceId: sp.id, symbol: t.symbol, anchor: sp.pole,
                                    offsetX: (Double(i) - (n - 1) / 2) * 20, offsetY: 30, isPlanned: t.ownership == .planned))
            }
        }
        return out
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal
        let a = "\(context.levelName) · \(LensFormat.count(f.thingCount, "item"))"
        let p = stats.propertyTotal
        let b: [TextRun]
        if p.warrantiesEndingSoon > 0 {
            b = [TextRun("\(LensFormat.count(p.warrantiesEndingSoon, "warranty", "warranties")) ending soon", .warn)]
        } else if p.plannedThingCount > 0 {
            b = [TextRun("\(LensFormat.count(p.plannedThingCount, "planned purchase")) · Home \(LensFormat.count(p.thingCount, "item"))", .secondary)]
        } else {
            b = [TextRun("Home · \(LensFormat.count(p.thingCount, "item"))", .secondary)]
        }
        return FooterSummary(primary: [TextRun(a)], secondary: b)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.thingCount + s.plannedThingCount }
}

// MARK: 6. Inventory

public struct InventoryLens: PlanLens {
    public init() {}
    public var id: LensID { .inventory }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let n = s.inventoryCount
        var d = SpaceDecoration(isQuiet: n == 0)
        if n > 0 { d.chip = Chip(LensFormat.count(n, "item"), style: .neutral, dot: s.lowCount > 0 ? .warn : nil) }
        if s.lowCount > 0 { d.secondLine = "\(s.lowCount) low" }
        var v = n == 0 ? "No items" : LensFormat.count(n, "item")
        if s.lowCount > 0 { v += ", \(s.lowCount) low" }
        if s.expiringCount > 0 { v += ", \(s.expiringCount) expiring" }
        d.accessibilityValue = v
        return d
    }

    public func pins(_ stats: LensStats, geometry: LevelGeometryRender) -> [PinModel] {
        stats.spotPins.map { PinModel(kind: .spot, itemId: $0.spotId, spaceId: $0.spaceId, symbol: "shippingbox", anchor: $0.pin, count: $0.itemCount) }
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal
        var a = "\(context.levelName) · \(LensFormat.count(f.inventoryCount, "item"))"
        if f.lowCount > 0 { a += " · \(f.lowCount) low" }
        if f.expiringCount > 0 { a += " · \(f.expiringCount) expiring" }
        let low = stats.propertyTotal.lowCount
        let b = low > 0 ? "\(low) low · Shopping list" : "Shopping list · Seasonal swap"
        return FooterSummary(primary: [TextRun(a)], secondary: [TextRun(b, .accent)], link: .shoppingList)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.inventoryCount }
}

// MARK: 7. Budget

public struct BudgetLens: PlanLens {
    public init() {}
    public var id: LensID { .budget }

    static func metric(_ r: Rollup) -> Int64 { r.plannedCents + r.spentCents }

    public func scale(_ stats: LensStats, context: LensContext) -> LensScale {
        if let m = context.budgetScaleMaxCents { return LensScale(maxValue: Double(m)) }
        return LensScale(maxValue: Double(stats.spaces.values.map { Self.metric($0.rollup) }.max() ?? 0))
    }

    public func decoration(_ s: ScopeStats, scale: LensScale, context: LensContext) -> SpaceDecoration {
        let r = s.rollup
        let quiet = r.plannedCents == 0 && r.spentCents == 0
        var d = SpaceDecoration(isQuiet: quiet)
        guard !quiet else { d.accessibilityValue = "No money tracked"; return d }
        let c = context.currency
        d.chip = Chip("\(LensFormat.compact(r.plannedCents, currency: c)) / \(LensFormat.compact(r.spentCents, currency: c))", style: .soft)
        d.budgetLines = ["\(LensFormat.compact(r.plannedCents, currency: c)) planned", "\(LensFormat.compact(r.spentCents, currency: c)) spent"]
        d.tint = TintLevel.relative(Double(Self.metric(r)), max: scale.maxValue)
        d.accessibilityValue = "\(LensFormat.money(r.plannedCents, currency: c)) planned, \(LensFormat.money(r.spentCents, currency: c)) spent"
        return d
    }

    public func footer(_ stats: LensStats, context: LensContext) -> FooterSummary {
        let f = stats.floorTotal.rollup, p = stats.propertyTotal.rollup, c = context.currency
        let a = "\(context.levelName): \(LensFormat.money(f.plannedCents, currency: c)) planned · \(LensFormat.money(f.spentCents, currency: c)) spent"
        let b = "Home: \(LensFormat.money(p.plannedCents, currency: c)) planned · \(LensFormat.money(p.spentCents, currency: c)) spent"
        let total = p.plannedCents + p.spentCents
        return FooterSummary(primary: [TextRun(a)], secondary: [TextRun(b, .secondary)],
                             barFraction: total > 0 ? Double(p.spentCents) / Double(total) : nil, link: .budget)
    }

    public func scopeCount(_ s: ScopeStats) -> Int? { s.rollup.openCount + s.rollup.ideaCount + s.rollup.doneCount }
}
