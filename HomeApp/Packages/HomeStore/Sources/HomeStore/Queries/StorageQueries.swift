import Foundation
import GRDB
import HomeCore

/// Storage-spot tree and inventory queries (LLD §11) as recursive CTEs.
enum StorageQueries {
    /// §11.1 path of every live spot: id → (label, room, floor, spaceId, levelId).
    static let pathCTE = """
        WITH RECURSIVE path(id, space_id, depth, label) AS (
          SELECT id, space_id, 0, name
          FROM storage_spot WHERE parent_spot_id IS NULL AND deleted_at IS NULL
          UNION ALL
          SELECT c.id, c.space_id, p.depth + 1, p.label || ' › ' || c.name
          FROM storage_spot c JOIN path p ON c.parent_spot_id = p.id
          WHERE c.deleted_at IS NULL AND p.depth < 32
        )
        """

    /// §11.2 subtree (inclusive) of a spot, depth-limited to 32.
    static func subtree(_ db: Database, of spotId: UUID) throws -> [UUID] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE sub(id, depth) AS (
              SELECT ?, 0
              UNION ALL
              SELECT s.id, sub.depth + 1 FROM storage_spot s JOIN sub ON s.parent_spot_id = sub.id
              WHERE s.deleted_at IS NULL AND sub.depth < 32
            )
            SELECT id FROM sub
            """, arguments: [spotId.db]).compactMap(UUID.init(uuidString:))
    }

    static func inList(_ ids: [UUID]) -> (String, StatementArguments) {
        (Array(repeating: "?", count: max(ids.count, 1)).joined(separator: ","), StatementArguments(ids.isEmpty ? [""] : ids.map(\.db)))
    }

    /// §11.3 "Where is…".
    static func locations(_ db: Database, ids: [UUID]) throws -> [ItemLocation] {
        guard !ids.isEmpty else { return [] }
        let (marks, args) = inList(ids)
        let rows = try Row.fetchAll(db, sql: pathCTE + """
            SELECT i.id, i.name, pe.name AS owner, sp.name AS room, lv.name AS floor, path.label AS spot_path,
                   i.level_id, i.space_id, i.storage_spot_id
            FROM inventory_item i
            LEFT JOIN path   ON path.id = i.storage_spot_id
            LEFT JOIN space sp ON sp.id = i.space_id
            LEFT JOIN level lv ON lv.id = i.level_id
            LEFT JOIN person pe ON pe.id = i.owner_id
            WHERE i.id IN (\(marks)) AND i.deleted_at IS NULL
            """, arguments: args)
        let byId = Dictionary(rows.compactMap { r -> (UUID, ItemLocation)? in
            guard let id = r.uuidOpt("id") else { return nil }
            return (id, ItemLocation(itemId: id, name: r["name"] ?? "", owner: r["owner"], room: r["room"], floor: r["floor"],
                                     spotPath: r["spot_path"], levelId: r.uuidOpt("level_id"), spaceId: r.uuidOpt("space_id"),
                                     spotId: r.uuidOpt("storage_spot_id")))
        }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// §11.4 seasonal swap lists.
    static func swapLines(_ db: Database, property: UUID, season: Season, inRotation: Bool) throws -> [SwapLine] {
        try Row.fetchAll(db, sql: pathCTE + """
            SELECT i.id, i.name, i.category, pe.name AS owner, sp.name AS room, path.label AS spot_path
            FROM inventory_item i
            LEFT JOIN path ON path.id = i.storage_spot_id
            LEFT JOIN space sp ON sp.id = i.space_id
            LEFT JOIN person pe ON pe.id = i.owner_id
            WHERE i.property_id = ? AND i.kind = 'clothing' AND i.deleted_at IS NULL
              AND i.season = ? AND i.in_rotation = ?
            ORDER BY owner, room, spot_path, i.name
            """, arguments: [property.db, season.rawValue, inRotation ? 1 : 0]).compactMap { r in
            guard let id = r.uuidOpt("id") else { return nil }
            return SwapLine(itemId: id, name: r["name"] ?? "", category: r["category"], owner: r["owner"], room: r["room"], spotPath: r["spot_path"])
        }
    }

    static func seasonalSwap(_ db: Database, property: UUID, on date: LocalDate) throws -> SeasonalSwap {
        let lat = try Double.fetchOne(db, sql: "SELECT latitude FROM property WHERE id = ?", arguments: [property.db])
        let upcoming = Season.upcoming(on: date, latitude: lat)
        return SeasonalSwap(upcoming: upcoming,
                            getOut: try swapLines(db, property: property, season: upcoming, inRotation: false),
                            putAway: try swapLines(db, property: property, season: upcoming.opposite, inRotation: true))
    }

    static let replacementTemplates = ["hvac_furnace", "hvac_filter", "water_filter", "light_fixture", "smoke_detector", "fridge_water_filter"]

    /// §11.5 shopping list: low items, then things whose linked replacement chore is due within 14 days and that have
    /// no spare in stock (one line per thing).
    static func shoppingList(_ db: Database, property: UUID, on date: LocalDate) throws -> [ShoppingLine] {
        let low = try Row.fetchAll(db, sql: """
            SELECT 'low' AS reason, i.id AS ref_id, 'inventory_item' AS ref_type, i.name AS label, i.quantity, i.unit
            FROM inventory_item i
            WHERE i.property_id = ? AND i.is_low = 1 AND i.deleted_at IS NULL
            ORDER BY i.name
            """, arguments: [property.db]).compactMap { r -> ShoppingLine? in
            guard let id = r.uuidOpt("ref_id") else { return nil }
            return ShoppingLine(reason: .low, ref: .inventory(id), label: r["label"] ?? "", quantity: r["quantity"], unit: r["unit"])
        }
        let templates = replacementTemplates.map { "'\($0)'" }.joined(separator: ",")
        let due = try Row.fetchAll(db, sql: """
            SELECT t.id AS ref_id,
                   t.name || COALESCE(' – ' || json_extract(t.attributes_json, '$.filterSize'),
                                      ' – ' || json_extract(t.attributes_json, '$.bulbBase'), '') AS label,
                   MIN(COALESCE(c.next_due_on, '9999-12-31')) AS first_due, MIN(c.title) AS first_title
            FROM chore c JOIN thing t ON t.id = c.linked_thing_id
            WHERE c.property_id = ? AND c.deleted_at IS NULL AND c.closed_at IS NULL AND t.deleted_at IS NULL
              AND c.next_due_on <= ?
              AND t.template_key IN (\(templates))
              AND NOT EXISTS (SELECT 1 FROM inventory_item s
                              WHERE s.linked_thing_id = t.id AND s.quantity > 0 AND s.deleted_at IS NULL)
            GROUP BY t.id
            ORDER BY first_due, first_title
            """, arguments: [property.db, date.adding(days: 14).description]).compactMap { r -> ShoppingLine? in
            guard let id = r.uuidOpt("ref_id") else { return nil }
            return ShoppingLine(reason: .replacementDue, ref: .thing(id), label: r["label"] ?? "")
        }
        return low + due
    }

    /// Spot tree of one room (`InventoryLogic.tree`), with direct and subtree item counts.
    static func tree(_ db: Database, space: UUID) throws -> [SpotNode] {
        let spots = try StorageSpot.fetchAll(db, where: "space_id = ?", [space.db])
        let items = try InventoryItem.fetchAll(db, where: "storage_spot_id IN (SELECT id FROM storage_spot WHERE space_id = ?)", [space.db])
        return InventoryLogic.tree(space: space, spots: spots, items: items)
    }
}
