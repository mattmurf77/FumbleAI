import Foundation
import GRDB
import HomeCore
import PlanKit

// MARK: - Search (LLD §12.2)

/// FTS5 `SearchService`: AND prefix match, OR fallback when empty, ≤ 50 hits by bm25 (weights 10/1/3/2).
public struct FTSSearchService: SearchService {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func search(_ text: String, property: UUID) async throws -> [SearchHit] {
        let tokens = SearchQuery.tokens(text).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !tokens.isEmpty else { return [] }
        let and = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        let or = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        return try await db.read { d in
            let hits = try Self.run(d, match: and, property: property)
            if !hits.isEmpty || tokens.count == 1 { return hits }
            return try Self.run(d, match: or, property: property)
        }
    }

    static func run(_ d: Database, match: String, property: UUID) throws -> [SearchHit] {
        let rows = try Row.fetchAll(d, sql: """
            SELECT entity_type, entity_id, title, location, people,
                   snippet(search_fts, 1, '', '', '…', 8) AS body_snippet,
                   bm25(search_fts, 10.0, 1.0, 3.0, 2.0) AS rank
            FROM search_fts
            WHERE search_fts MATCH ? AND property_id = ?
            ORDER BY rank
            LIMIT 50
            """, arguments: [match, property.db])
        return rows.compactMap { r in
            guard let t = SearchEntityType(rawValue: r["entity_type"] ?? ""), let id = r.uuidOpt("entity_id") else { return nil }
            let loc: String? = r["location"], people: String? = r["people"], snip: String? = r["body_snippet"]
            return SearchHit(entityType: t, entityId: id, title: r["title"] ?? "", location: loc?.isEmpty == false ? loc : nil,
                             snippet: snip?.isEmpty == false ? snip : nil, people: people?.isEmpty == false ? people : nil,
                             rank: r["rank"] ?? 0)
        }
    }

    public func rebuildIndex() async throws {
        try await db.write(origin: .sync) { tx in try SearchIndexer.rebuild(tx.db) }
    }
}

// MARK: - Rollups (LLD §8)

/// Budget rollups with the §8.2 shared CTE and AGG block (plus idea/done counts for `Rollup`).
public struct RollupQueries: RollupService {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static let cte = """
        WITH li AS (
          SELECT project_id, SUM(amount_cents) AS li_cents, SUM(hours) AS li_hours
          FROM cost_line_item WHERE deleted_at IS NULL GROUP BY project_id
        ),
        p AS (
          SELECT pr.id, pr.scope, pr.space_id, pr.level_id, pr.status, pr.completed_on,
                 COALESCE(pr.est_cost_cents, 0)                          AS est,
                 COALESCE(pr.actual_cost_cents, li.li_cents, 0)          AS spent,
                 (pr.est_cost_cents IS NOT NULL)                         AS has_est,
                 COALESCE(pr.est_hours, 0)                               AS est_h,
                 COALESCE(pr.actual_hours, li.li_hours, 0)               AS spent_h
          FROM project pr LEFT JOIN li ON li.project_id = pr.id
          WHERE pr.property_id = :propertyId AND pr.deleted_at IS NULL
        )
        """

    static let agg = """
          SUM(CASE WHEN status IN ('planned','in_progress') THEN est ELSE 0 END)                 AS planned_cents,
          SUM(CASE WHEN status = 'idea' THEN est ELSE 0 END)                                     AS idea_cents,
          SUM(CASE WHEN status IN ('in_progress','done') THEN spent ELSE 0 END)                  AS spent_cents,
          SUM(CASE WHEN status = 'planned' THEN est
                   WHEN status = 'in_progress' THEN MAX(est - spent, 0) ELSE 0 END)              AS remaining_cents,
          SUM(CASE WHEN status = 'done' AND has_est THEN spent - est ELSE 0 END)                 AS variance_cents,
          SUM(CASE WHEN status = 'done' THEN spent ELSE 0 END)                                   AS lifetime_cents,
          MAX(CASE WHEN status = 'done' THEN completed_on END)                                   AS last_completed_on,
          SUM(CASE WHEN status IN ('planned','in_progress') THEN est_h ELSE 0 END)               AS planned_hours,
          SUM(CASE WHEN status IN ('in_progress','done') THEN spent_h ELSE 0 END)                AS spent_hours,
          SUM(status IN ('planned','in_progress'))                                               AS open_count,
          SUM(status = 'in_progress')                                                            AS in_progress_count,
          SUM(status = 'idea')                                                                   AS idea_count,
          SUM(status = 'done')                                                                   AS done_count
        """

    static func rollup(_ r: Row, currency: String) -> Rollup {
        var x = Rollup(currency: currency)
        x.plannedCents = r["planned_cents"] ?? 0; x.ideaCents = r["idea_cents"] ?? 0; x.spentCents = r["spent_cents"] ?? 0
        x.remainingCents = r["remaining_cents"] ?? 0; x.varianceCents = r["variance_cents"] ?? 0; x.lifetimeCents = r["lifetime_cents"] ?? 0
        x.lastCompletedOn = r.localDateOpt("last_completed_on")
        x.plannedHours = r["planned_hours"] ?? 0; x.spentHours = r["spent_hours"] ?? 0
        x.openCount = r["open_count"] ?? 0; x.inProgressCount = r["in_progress_count"] ?? 0
        x.ideaCount = r["idea_count"] ?? 0; x.doneCount = r["done_count"] ?? 0
        return x
    }

    static func propertyInfo(_ d: Database, level: UUID) throws -> (UUID, String)? {
        guard let row = try Row.fetchOne(d, sql: "SELECT p.id, p.currency_code FROM level l JOIN property p ON p.id = l.property_id WHERE l.id = ?",
                                         arguments: [level.db]), let pid = row.uuidOpt("id") else { return nil }
        return (pid, row["currency_code"] ?? "USD")
    }

    /// §8.3 room rollups for one level.
    static func rooms(_ d: Database, level: UUID) throws -> [UUID: Rollup] {
        guard let (pid, cur) = try propertyInfo(d, level: level) else { return [:] }
        let rows = try Row.fetchAll(d, sql: cte + " SELECT space_id, \(agg) FROM p WHERE scope = 'space' AND level_id = :levelId GROUP BY space_id",
                                    arguments: ["propertyId": pid.db, "levelId": level.db])
        var out: [UUID: Rollup] = [:]
        for r in rows { if let s = r.uuidOpt("space_id") { out[s] = rollup(r, currency: cur) } }
        return out
    }

    /// §8.4 floor rollup: rooms / floor-wide / total.
    static func floor(_ d: Database, level: UUID) throws -> FloorRollup {
        guard let (pid, cur) = try propertyInfo(d, level: level) else {
            return FloorRollup(levelId: level, rooms: .zero, floorWide: .zero, total: .zero)
        }
        let rows = try Row.fetchAll(d, sql: cte + """
             SELECT CASE WHEN scope = 'space' THEN 'rooms' ELSE 'floor_wide' END AS part, \(agg)
            FROM p WHERE level_id = :levelId
            GROUP BY part
            UNION ALL
            SELECT 'floor_total', \(agg) FROM p WHERE level_id = :levelId
            """, arguments: ["propertyId": pid.db, "levelId": level.db])
        var parts: [String: Rollup] = [:]
        for r in rows { if let k: String = r["part"] { parts[k] = rollup(r, currency: cur) } }
        return FloorRollup(levelId: level, rooms: parts["rooms"] ?? Rollup(currency: cur),
                           floorWide: parts["floor_wide"] ?? Rollup(currency: cur), total: parts["floor_total"] ?? Rollup(currency: cur))
    }

    /// §8.5 property rollup: per level, whole house and total. Levels ordered by sort order.
    static func property(_ d: Database, _ id: UUID) throws -> PropertyRollup {
        let cur = try String.fetchOne(d, sql: "SELECT currency_code FROM property WHERE id = ?", arguments: [id.db]) ?? "USD"
        let rows = try Row.fetchAll(d, sql: cte + """
             SELECT COALESCE(p.level_id, '__property__') AS bucket, \(agg)
            FROM p GROUP BY bucket
            UNION ALL
            SELECT '__total__', \(agg) FROM p
            """, arguments: ["propertyId": id.db])
        var buckets: [String: Rollup] = [:]
        for r in rows { if let k: String = r["bucket"] { buckets[k] = rollup(r, currency: cur) } }
        let levels = try PlanStore.levels(d, property: id).map { l in
            PropertyRollup.LevelRow(levelId: l.id, levelName: l.name, sortOrder: l.sortOrder, rollup: buckets[l.id.db] ?? Rollup(currency: cur))
        }
        return PropertyRollup(propertyId: id, levels: levels, wholeHouse: buckets["__property__"] ?? Rollup(currency: cur),
                              total: buckets["__total__"] ?? Rollup(currency: cur))
    }

    public func observeRooms(level: UUID) -> AsyncStream<[UUID: Rollup]> { db.observe { try Self.rooms($0, level: level) } }
    public func observeFloor(level: UUID) -> AsyncStream<FloorRollup> { db.observe { try Self.floor($0, level: level) } }
    public func observeProperty(_ id: UUID) -> AsyncStream<PropertyRollup> { db.observe { try Self.property($0, id) } }
}

// MARK: - Lens stats (LLD §7.4–7.5)

/// Per-level `LensStats` from grouped SQL (chores, things, inventory) plus the §8 rollup CTE.
public struct LensStatsQueries: LensStatsService {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func observeStats(level: UUID, today: LocalDate) -> AsyncStream<LensStats> {
        db.observe { try Self.compute($0, level: level, today: today) }
    }

    /// Scope buckets: per space on the level, level scope, floor total, property scope, property total.
    enum Bucket: Hashable { case space(UUID), levelScope, floorTotal, propertyScope, propertyTotal }

    static func compute(_ d: Database, level: UUID, today: LocalDate) throws -> LensStats {
        guard let (pid, cur) = try RollupQueries.propertyInfo(d, level: level) else { return LensStats(levelId: level, today: today) }
        let spaces = try Space.fetchAll(d, where: "level_id = ?", [level.db])
        var stats: [Bucket: ScopeStats] = [:]
        for s in spaces { stats[.space(s.id)] = ScopeStats() }
        for b in [Bucket.levelScope, .floorTotal, .propertyScope, .propertyTotal] { stats[b] = ScopeStats() }

        // Bucket predicates, as SQL over the scope triple.
        let preds: [(String, (Row) -> Bucket?)] = [
            ("level_id = :level AND scope = 'space'", { r in r.uuidOpt("space_id").map(Bucket.space) }),
            ("level_id = :level AND scope = 'level'", { _ in .levelScope }),
            ("level_id = :level", { _ in .floorTotal }),
            ("scope = 'property'", { _ in .propertyScope }),
            ("1", { _ in .propertyTotal })]
        let args: StatementArguments = ["pid": pid.db, "level": level.db, "today": today.description,
                                        "week": today.adding(days: 6).description, "plus7": today.adding(days: 7).description,
                                        "plus60": today.adding(days: 60).description]
        for (i, (pred, bucket)) in preds.enumerated() {
            let group = i == 0 ? "GROUP BY space_id" : ""
            // To-Dos (open = not closed, not paused).
            for r in try Row.fetchAll(d, sql: """
                SELECT space_id, COUNT(*) AS open_n,
                       SUM(next_due_on < :today) AS overdue, SUM(next_due_on = :today) AS due_today,
                       SUM(next_due_on BETWEEN :today AND :week) AS due_week
                FROM chore WHERE property_id = :pid AND deleted_at IS NULL AND closed_at IS NULL AND is_paused = 0 AND (\(pred)) \(group)
                """, arguments: args) {
                guard let b = bucket(r), stats[b] != nil else { continue }
                stats[b]!.openChores = r["open_n"] ?? 0; stats[b]!.overdue = r["overdue"] ?? 0
                stats[b]!.dueToday = r["due_today"] ?? 0; stats[b]!.dueWeek = r["due_week"] ?? 0
            }
            // Things (planned counted separately).
            for r in try Row.fetchAll(d, sql: """
                SELECT space_id, SUM(ownership = 'owned') AS owned, SUM(ownership = 'planned') AS planned,
                       SUM(ownership = 'owned' AND warranty_end >= :today AND warranty_end <= :plus60) AS warranty
                FROM thing WHERE property_id = :pid AND deleted_at IS NULL AND (\(pred)) \(group)
                """, arguments: args) {
                guard let b = bucket(r), stats[b] != nil else { continue }
                stats[b]!.thingCount = r["owned"] ?? 0; stats[b]!.plannedThingCount = r["planned"] ?? 0
                stats[b]!.warrantiesEndingSoon = r["warranty"] ?? 0
            }
            // Inventory.
            for r in try Row.fetchAll(d, sql: """
                SELECT space_id, COUNT(*) AS items, SUM(is_low) AS low,
                       SUM(expires_on IS NOT NULL AND expires_on <= :plus7) AS expiring
                FROM inventory_item WHERE property_id = :pid AND deleted_at IS NULL AND (\(pred)) \(group)
                """, arguments: args) {
                guard let b = bucket(r), stats[b] != nil else { continue }
                stats[b]!.inventoryCount = r["items"] ?? 0; stats[b]!.lowCount = r["low"] ?? 0; stats[b]!.expiringCount = r["expiring"] ?? 0
            }
            // Rollups (§8 CTE).
            let rollupSQL = RollupQueries.cte + " SELECT space_id, \(RollupQueries.agg) FROM p WHERE (\(pred.replacingOccurrences(of: ":level", with: ":levelId"))) \(group)"
            for r in try Row.fetchAll(d, sql: rollupSQL, arguments: ["propertyId": pid.db, "levelId": level.db]) {
                guard let b = bucket(r), stats[b] != nil else { continue }
                if i != 0 && (r["open_count"] as Int?) == nil { continue }   // empty aggregate row
                stats[b]!.rollup = RollupQueries.rollup(r, currency: cur)
            }
        }
        for b in stats.keys where stats[b]!.rollup == .zero { stats[b]!.rollup = Rollup(currency: cur) }

        let things = try Thing.fetchAll(d, where: "level_id = ?", [level.db]).sorted { $0.name < $1.name }
        let thingPins = things.map {
            ThingPin(thingId: $0.id, spaceId: $0.scope.spaceId, templateKey: $0.templateKey, category: $0.category,
                     ownership: $0.ownership, pin: $0.pin, symbol: $0.symbol)
        }
        var spotPins: [SpotPin] = []
        for spot in try StorageSpot.fetchAll(d, where: "space_id IN (SELECT id FROM space WHERE level_id = ? AND deleted_at IS NULL) AND pin_x IS NOT NULL AND pin_y IS NOT NULL", [level.db]) {
            guard let pin = spot.pin else { continue }
            let sub = try StorageQueries.subtree(d, of: spot.id)
            let (marks, a) = StorageQueries.inList(sub)
            let count = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM inventory_item WHERE deleted_at IS NULL AND storage_spot_id IN (\(marks))", arguments: a) ?? 0
            spotPins.append(SpotPin(spotId: spot.id, spaceId: spot.spaceId, pin: pin, itemCount: count))
        }
        spotPins.sort { $0.spotId.db < $1.spotId.db }
        let interior = spaces.filter { !$0.isExterior }
        var perSpace: [UUID: ScopeStats] = [:]
        for s in spaces { perSpace[s.id] = stats[.space(s.id)] }
        return LensStats(levelId: level, today: today, spaces: perSpace, levelScope: stats[.levelScope]!, floorTotal: stats[.floorTotal]!,
                         propertyScope: stats[.propertyScope]!, propertyTotal: stats[.propertyTotal]!,
                         thingPins: thingPins, spotPins: spotPins, roomCount: interior.count,
                         interiorAreaSqIn: SpaceNesting.floorAreaSqIn(interior))
    }
}
