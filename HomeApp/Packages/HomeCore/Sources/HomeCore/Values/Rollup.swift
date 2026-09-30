import Foundation

/// Budget aggregate for a set of projects (the SQL "AGG" block, LLD §8.2). All money in cents.
public struct Rollup: Hashable, Codable, Sendable {
    /// Σ est where status ∈ {planned, in_progress}.
    public var plannedCents: Int64 = 0
    /// Σ est where status = idea (shown separately, never added to planned).
    public var ideaCents: Int64 = 0
    /// Σ spent where status ∈ {in_progress, done}.
    public var spentCents: Int64 = 0
    public var remainingCents: Int64 = 0
    /// Σ (spent − est) over done projects that have an estimate.
    public var varianceCents: Int64 = 0
    /// Σ spent over done projects (Past Work).
    public var lifetimeCents: Int64 = 0
    public var lastCompletedOn: LocalDate?
    public var plannedHours: Double = 0
    public var spentHours: Double = 0
    public var openCount: Int = 0
    public var inProgressCount: Int = 0
    public var ideaCount: Int = 0
    public var doneCount: Int = 0
    public var currency: String = "USD"
    public init(currency: String = "USD") { self.currency = currency }
    public static let zero = Rollup()

    public var planned: Money { Money(cents: plannedCents, currency: currency) }
    public var ideas: Money { Money(cents: ideaCents, currency: currency) }
    public var spent: Money { Money(cents: spentCents, currency: currency) }
    public var remaining: Money { Money(cents: remainingCents, currency: currency) }
    public var variance: Money { Money(cents: varianceCents, currency: currency) }
    public var lifetime: Money { Money(cents: lifetimeCents, currency: currency) }
    public var isEmpty: Bool { openCount == 0 && ideaCount == 0 && doneCount == 0 }

    public static func + (a: Rollup, b: Rollup) -> Rollup {
        var r = a
        r.plannedCents += b.plannedCents; r.ideaCents += b.ideaCents; r.spentCents += b.spentCents
        r.remainingCents += b.remainingCents; r.varianceCents += b.varianceCents; r.lifetimeCents += b.lifetimeCents
        r.lastCompletedOn = [a.lastCompletedOn, b.lastCompletedOn].compactMap { $0 }.max()
        r.plannedHours += b.plannedHours; r.spentHours += b.spentHours; r.openCount += b.openCount
        r.inProgressCount += b.inProgressCount; r.ideaCount += b.ideaCount; r.doneCount += b.doneCount
        return r
    }
}

/// Floor rollup (§8.4): rooms, floor-wide (level-scope) and total.
public struct FloorRollup: Hashable, Codable, Sendable {
    public var levelId: UUID
    public var rooms: Rollup
    public var floorWide: Rollup
    public var total: Rollup
    public init(levelId: UUID, rooms: Rollup, floorWide: Rollup, total: Rollup) {
        self.levelId = levelId; self.rooms = rooms; self.floorWide = floorWide; self.total = total
    }
}

/// Property rollup (§8.5): per floor, whole-house (property scope) and total.
public struct PropertyRollup: Hashable, Codable, Sendable {
    public struct LevelRow: Hashable, Codable, Sendable, Identifiable {
        public var levelId: UUID
        public var levelName: String
        public var sortOrder: Int
        public var rollup: Rollup
        public var id: UUID { levelId }
        public init(levelId: UUID, levelName: String, sortOrder: Int, rollup: Rollup) {
            self.levelId = levelId; self.levelName = levelName; self.sortOrder = sortOrder; self.rollup = rollup
        }
    }
    public var propertyId: UUID
    /// Ordered by level sort order.
    public var levels: [LevelRow]
    /// "Whole house" (property-scope projects).
    public var wholeHouse: Rollup
    public var total: Rollup
    public init(propertyId: UUID, levels: [LevelRow], wholeHouse: Rollup, total: Rollup) {
        self.propertyId = propertyId; self.levels = levels; self.wholeHouse = wholeHouse; self.total = total
    }
}

/// Pure rollup math mirroring the SQL in LLD §8 (used by the in-memory store and as a test oracle for HomeStore).
public enum RollupMath {
    /// Effective spent: actual cost if set, else Σ line items (non-deleted), else 0.
    public static func spentCents(_ p: Project, lineItems: [CostLineItem]) -> Int64 {
        if let a = p.actualCost { return a.cents }
        return lineItems.filter { $0.projectId == p.id && $0.deletedAt == nil }.reduce(0) { $0 + $1.amount.cents }
    }

    public static func spentHours(_ p: Project, lineItems: [CostLineItem]) -> Double {
        if let a = p.actualHours { return a }
        return lineItems.filter { $0.projectId == p.id && $0.deletedAt == nil }.reduce(0) { $0 + ($1.hours ?? 0) }
    }

    public static func rollup(_ projects: [Project], lineItems: [CostLineItem], currency: String = "USD") -> Rollup {
        var r = Rollup(currency: currency)
        for p in projects where p.deletedAt == nil {
            let est = p.estCost?.cents ?? 0
            let spent = spentCents(p, lineItems: lineItems)
            let estH = p.estHours ?? 0, spentH = spentHours(p, lineItems: lineItems)
            switch p.status {
            case .idea:
                r.ideaCents += est; r.ideaCount += 1
            case .planned:
                r.plannedCents += est; r.remainingCents += est; r.plannedHours += estH; r.openCount += 1
            case .inProgress:
                r.plannedCents += est; r.spentCents += spent; r.remainingCents += max(est - spent, 0)
                r.plannedHours += estH; r.spentHours += spentH; r.openCount += 1; r.inProgressCount += 1
            case .done:
                r.spentCents += spent; r.lifetimeCents += spent; r.spentHours += spentH; r.doneCount += 1
                if p.estCost != nil { r.varianceCents += spent - est }
                if let c = p.completedOn { r.lastCompletedOn = max(r.lastCompletedOn ?? c, c) }
            case .unknown:
                break
            }
        }
        return r
    }

    /// Room rollups for one level (§8.3), keyed by space id.
    public static func rooms(level: UUID, projects: [Project], lineItems: [CostLineItem]) -> [UUID: Rollup] {
        var bySpace: [UUID: [Project]] = [:]
        for p in projects where p.deletedAt == nil {
            if case .space(let s, let l) = p.scope, l == level { bySpace[s, default: []].append(p) }
        }
        return bySpace.mapValues { rollup($0, lineItems: lineItems) }
    }

    public static func floor(level: UUID, projects: [Project], lineItems: [CostLineItem]) -> FloorRollup {
        let onLevel = projects.filter { $0.deletedAt == nil && $0.scope.levelId == level }
        let rooms = rollup(onLevel.filter { $0.scope.kind == .space }, lineItems: lineItems)
        let wide = rollup(onLevel.filter { $0.scope.kind == .level }, lineItems: lineItems)
        return FloorRollup(levelId: level, rooms: rooms, floorWide: wide, total: rollup(onLevel, lineItems: lineItems))
    }

    public static func property(_ propertyId: UUID, levels: [Level], projects: [Project], lineItems: [CostLineItem]) -> PropertyRollup {
        let live = projects.filter { $0.deletedAt == nil && $0.propertyId == propertyId }
        let rows = levels.filter { $0.deletedAt == nil && $0.propertyId == propertyId }.sortedForPills.map { l in
            PropertyRollup.LevelRow(levelId: l.id, levelName: l.name, sortOrder: l.sortOrder,
                                    rollup: rollup(live.filter { $0.scope.levelId == l.id }, lineItems: lineItems))
        }
        return PropertyRollup(propertyId: propertyId, levels: rows,
                              wholeHouse: rollup(live.filter { $0.scope == .property }, lineItems: lineItems),
                              total: rollup(live, lineItems: lineItems))
    }
}
