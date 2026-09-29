import Foundation

/// Pure chore rules shared by HomeStore and the in-memory store (LLD §9.1–9.2, §5.4).
public enum ChoreLogic {
    public static func make(from d: ChoreDraft, id: UUID = UUID(), now: Date, engine: RecurrenceEngine) -> Chore {
        Chore(id: id, propertyId: d.propertyId, scope: d.scope, title: d.title, notes: d.notes, assigneeId: d.assigneeId,
              repeatRule: d.repeatRule, startOn: d.startOn, nextDueOn: engine.firstDue(rule: d.repeatRule, start: d.startOn),
              dueMinutes: d.dueMinutes, remindEnabled: d.remindEnabled, remindOffsetMin: d.remindOffsetMin,
              calendarEnabled: d.calendarEnabled, linkedThingId: d.linkedThingId, createdAt: now, updatedAt: now)
    }

    /// Applies a done/skip action. Returns the updated chore and the new completion row.
    /// One-off: sets `closedAt`, clears `nextDueOn`. Recurring: advances with `RecurrenceEngine.nextDue`;
    /// a finished series (past `until`) is closed.
    public static func act(on chore: Chore, outcome: ChoreCompletion.Outcome, by person: UUID?, at date: Date,
                           note: String? = nil, calendar: Calendar, engine: RecurrenceEngine,
                           completionId: UUID = UUID()) -> (Chore, ChoreCompletion) {
        let doneOn = LocalDate(date, calendar: calendar)
        let completion = ChoreCompletion(id: completionId, propertyId: chore.propertyId, choreId: chore.id,
                                         dueOn: chore.nextDueOn, doneAt: date, doneOn: doneOn, doneBy: person,
                                         outcome: outcome, note: note, createdAt: date, updatedAt: date)
        var c = chore
        c.updatedAt = date
        if let rule = chore.repeatRule {
            let next = engine.nextDue(rule: rule, start: chore.startOn, currentDue: chore.nextDueOn ?? doneOn, actedOn: doneOn)
            c.nextDueOn = next
            if next == nil { c.closedAt = date }
        } else {
            c.nextDueOn = nil
            c.closedAt = date
        }
        return (c, completion)
    }

    /// Recomputes `nextDueOn` from the latest completion after a sync merge (§5.4 / §9.2).
    public static func recomputeNextDue(_ chore: Chore, completions: [ChoreCompletion], engine: RecurrenceEngine) -> Chore {
        var c = chore
        let live = completions.filter { $0.choreId == chore.id && $0.deletedAt == nil }
        guard let latest = live.max(by: { $0.doneAt < $1.doneAt }) else {
            if c.repeatRule != nil || c.closedAt == nil { c.nextDueOn = engine.firstDue(rule: c.repeatRule, start: c.startOn) }
            return c
        }
        guard let rule = chore.repeatRule else {
            // One-off: closed if a non-deleted done completion exists.
            if live.contains(where: { $0.outcome == .done }) { c.closedAt = c.closedAt ?? latest.doneAt; c.nextDueOn = nil }
            return c
        }
        let next = engine.nextDue(rule: rule, start: c.startOn, currentDue: latest.dueOn ?? latest.doneOn, actedOn: latest.doneOn)
        c.nextDueOn = next
        if next == nil { c.closedAt = c.closedAt ?? latest.doneAt }
        return c
    }

    /// "Turn into a project" (sets spawned_from_chore_id).
    public static func projectDraft(from chore: Chore) -> ProjectDraft {
        ProjectDraft(propertyId: chore.propertyId, scope: chore.scope, title: chore.title, notes: chore.notes,
                     status: .idea, spawnedFromChoreId: chore.id)
    }
}

/// Pure project rules (LLD §8.1, §5.4 "Paired status/completed_on").
public enum ProjectLogic {
    public static func make(from d: ProjectDraft, id: UUID = UUID(), now: Date, today: LocalDate) -> Project {
        var p = Project(id: id, propertyId: d.propertyId, scope: d.scope, title: d.title, notes: d.notes, status: d.status,
                        priority: d.priority, estCost: d.estCost, actualCost: d.actualCost, estHours: d.estHours,
                        actualHours: d.actualHours, targetOn: d.targetOn, completedOn: d.completedOn, vendor: d.vendor,
                        spawnedFromChoreId: d.spawnedFromChoreId, currencyCode: d.estCost?.currency ?? d.actualCost?.currency ?? "USD",
                        createdAt: now, updatedAt: now)
        p = setStatus(p, d.status, today: today)
        if d.status == .done, let c = d.completedOn { p.completedOn = c }
        return p
    }

    /// Status transition. → inProgress stamps `startedOn`; → done stamps `completedOn` (today if unset);
    /// leaving done clears `completedOn` (actuals are kept).
    public static func setStatus(_ project: Project, _ status: Project.Status, today: LocalDate) -> Project {
        var p = project
        p.status = status
        switch status {
        case .inProgress: if p.startedOn == nil { p.startedOn = today }; p.completedOn = nil
        case .done: if p.completedOn == nil { p.completedOn = today }
        default: p.completedOn = nil
        }
        return p
    }

    public static func markDone(_ project: Project, actual: Money?, completedOn: LocalDate, hours: Double?) -> Project {
        var p = project
        p.status = .done
        p.completedOn = completedOn
        if let actual { p.actualCost = actual }
        if let hours { p.actualHours = hours }
        if p.startedOn == nil { p.startedOn = completedOn }
        return p
    }

    /// done → in progress, keeping actuals.
    public static func reopen(_ project: Project, today: LocalDate) -> Project { setStatus(project, .inProgress, today: today) }
}

/// Pure inventory rules (LLD §11).
public enum InventoryLogic {
    /// `is_low` is set automatically when `low_threshold` is set and quantity ≤ threshold.
    public static func applyLowThreshold(_ item: InventoryItem) -> InventoryItem {
        var i = item
        if let t = i.lowThreshold { i.isLow = i.quantity <= t }
        return i
    }

    public static func make(from d: InventoryDraft, id: UUID = UUID(), now: Date, spotScope: Scope?) -> InventoryItem {
        let item = InventoryItem(id: id, propertyId: d.propertyId, kind: d.kind, name: d.name, category: d.category,
                                 ownerId: d.ownerId, scope: spotScope ?? d.scope, storageSpotId: d.storageSpotId,
                                 quantity: d.quantity, unit: d.unit, season: d.season, inRotation: d.inRotation,
                                 expiresOn: d.expiresOn, isLow: d.isLow, lowThreshold: d.lowThreshold,
                                 linkedThingId: d.linkedThingId, notes: d.notes, createdAt: now, updatedAt: now)
        return applyLowThreshold(item)
    }

    /// Descendant spot ids of `spotId` (inclusive), depth-limited (§11.2).
    public static func subtree(of spotId: UUID, in spots: [StorageSpot]) -> [UUID] {
        var out: [UUID] = [spotId]
        var frontier: [UUID] = [spotId]
        var depth = 0
        let live = spots.filter { $0.deletedAt == nil }
        while !frontier.isEmpty && depth < StorageSpot.maxDepth {
            let next = live.filter { s in s.parentSpotId.map { frontier.contains($0) } ?? false }.map(\.id)
            out.append(contentsOf: next.filter { !out.contains($0) })
            frontier = next
            depth += 1
        }
        return out
    }

    /// Re-parent guard: rejects cycles and cross-room moves (§11.2).
    public static func canReparent(_ spotId: UUID, to parent: UUID?, in spots: [StorageSpot]) -> Bool {
        guard let parent else { return true }
        guard let spot = spots.first(where: { $0.id == spotId }), let p = spots.first(where: { $0.id == parent }) else { return false }
        if p.spaceId != spot.spaceId { return false }
        return !subtree(of: spotId, in: spots).contains(parent)
    }

    /// "Shelf 2 › Bin Winter – Matt" path for a spot (without the room name).
    public static func path(of spotId: UUID, in spots: [StorageSpot]) -> String {
        var names: [String] = []
        var cur = spots.first { $0.id == spotId }
        var guardN = 0
        while let c = cur, guardN < StorageSpot.maxDepth {
            names.append(c.name)
            cur = c.parentSpotId.flatMap { pid in spots.first { $0.id == pid } }
            guardN += 1
        }
        return names.reversed().joined(separator: " › ")
    }

    /// Builds the spot tree of one room with direct and subtree item counts.
    public static func tree(space: UUID, spots: [StorageSpot], items: [InventoryItem]) -> [SpotNode] {
        let live = spots.filter { $0.deletedAt == nil && $0.spaceId == space }
        let liveItems = items.filter { $0.deletedAt == nil }
        func build(_ parent: UUID?, depth: Int, prefix: String) -> [SpotNode] {
            guard depth < StorageSpot.maxDepth else { return [] }
            return live.filter { $0.parentSpotId == parent }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }.map { s in
                let path = prefix.isEmpty ? s.name : prefix + " › " + s.name
                let children = build(s.id, depth: depth + 1, prefix: path)
                let direct = liveItems.filter { $0.storageSpotId == s.id }.count
                return SpotNode(spot: s, depth: depth, path: path, itemCount: direct,
                                subtreeItemCount: direct + children.reduce(0) { $0 + $1.subtreeItemCount }, children: children)
            }
        }
        return build(nil, depth: 0, prefix: "")
    }
}

/// RFC 4180 CSV writer: CRLF line endings, UTF-8 with BOM, quotes doubled. LLD §13.
public enum CSV {
    public static let bom = "\u{FEFF}"

    public static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func encode(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Full file contents including the BOM.
    public static func file(header: [String], rows: [[String]]) -> Data { Data((bom + encode(header: header, rows: rows)).utf8) }

    /// ISO 8601 instant `YYYY-MM-DDTHH:MM:SSZ`.
    public static func instant(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Lengths: inches with 2 decimals.
    public static func inches(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
}
