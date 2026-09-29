import Foundation
import GRDB
import HomeCore

/// Name lookups shared by FTS, export and Recently Deleted (names include soft-deleted rows, like the oracle).
struct Lookup {
    let db: Database

    init(_ db: Database) { self.db = db }

    func spaceName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return try? String.fetchOne(db, sql: "SELECT name FROM space WHERE id = ?", arguments: [id.db])
    }
    func levelName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return try? String.fetchOne(db, sql: "SELECT name FROM level WHERE id = ?", arguments: [id.db])
    }
    func personName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return try? String.fetchOne(db, sql: "SELECT name FROM person WHERE id = ?", arguments: [id.db])
    }
    func thingName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return try? String.fetchOne(db, sql: "SELECT name FROM thing WHERE id = ?", arguments: [id.db])
    }

    /// "Kitchen · 1st Floor" / "1st Floor" / "Whole house".
    func locationText(_ scope: Scope) -> String {
        switch scope {
        case .space(let s, let l): return [spaceName(s), levelName(l)].compactMap { $0 }.joined(separator: " · ")
        case .level(let l): return levelName(l) ?? "This floor"
        case .property: return "Whole house"
        }
    }

    /// "Shelf 2 › Bin Winter – Matt" (without the room) — `InventoryLogic.path` over the spot's room.
    func spotPath(_ spotId: UUID?) -> String? {
        guard let spotId,
              let spaceId = try? String.fetchOne(db, sql: "SELECT space_id FROM storage_spot WHERE id = ?", arguments: [spotId.db]) else { return nil }
        let spots = (try? StorageSpot.fetchAll(db, where: "space_id = ?", [spaceId], includeDeleted: true)) ?? []
        return InventoryLogic.path(of: spotId, in: spots)
    }
}

/// Maintains `search_fts` inside each write transaction (LLD §12.1).
enum SearchIndexer {
    static func entityType(_ t: RecordType) -> SearchEntityType? {
        switch t {
        case .chore: return .chore; case .project: return .project; case .thing: return .thing
        case .inventoryItem: return .inventoryItem; case .measurement: return .measurement; case .space: return .space
        case .storageSpot: return .storageSpot
        default: return nil
        }
    }

    static func remove(_ db: Database, _ ref: RecordRef) throws {
        guard let et = entityType(ref.type) else { return }
        try db.execute(sql: "DELETE FROM search_fts WHERE entity_type = ? AND entity_id = ?", arguments: [et.rawValue, ref.id.db])
    }

    /// Reindexes `refs` plus the rows whose index text depends on them (cascades, §12.1).
    static func reindex(_ db: Database, refs: Set<RecordRef>) throws {
        var all = Set<RecordRef>()
        for r in refs { all.formUnion(try expand(db, r)) }
        for r in all where entityType(r.type) != nil { try index(db, r) }
    }

    static func ids(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> [UUID] {
        try String.fetchAll(db, sql: sql, arguments: args).compactMap(UUID.init(uuidString:))
    }

    static func expand(_ db: Database, _ r: RecordRef) throws -> Set<RecordRef> {
        var out: Set<RecordRef> = [r]
        let id = r.id.db
        func add(_ t: RecordType, _ sql: String, _ args: StatementArguments) throws {
            for i in try ids(db, sql, args) { out.insert(RecordRef(t, i)) }
        }
        func itemsWhere(_ col: String, _ v: String) throws {
            for t in [RecordType.chore, .project, .thing, .inventoryItem] {
                try add(t, "SELECT id FROM \(t.tableName) WHERE \(col) = ?", [v])
            }
        }
        switch r.type {
        case .space:
            try add(.storageSpot, "SELECT id FROM storage_spot WHERE space_id = ?", [id])
            try add(.measurement, "SELECT id FROM measurement WHERE space_id = ?", [id])
            try itemsWhere("space_id", id)
        case .level:
            try add(.space, "SELECT id FROM space WHERE level_id = ?", [id])
            try add(.storageSpot, "SELECT s.id FROM storage_spot s JOIN space sp ON sp.id = s.space_id WHERE sp.level_id = ?", [id])
            try add(.measurement, "SELECT m.id FROM measurement m JOIN space sp ON sp.id = m.space_id WHERE sp.level_id = ?", [id])
            try itemsWhere("level_id", id)
        case .storageSpot:
            let sub = try StorageQueries.subtree(db, of: r.id)
            for s in sub { out.insert(RecordRef(.storageSpot, s)) }
            if !sub.isEmpty {
                let marks = Array(repeating: "?", count: sub.count).joined(separator: ",")
                try add(.inventoryItem, "SELECT id FROM inventory_item WHERE storage_spot_id IN (\(marks))", StatementArguments(sub.map(\.db)))
            }
        case .person:
            try add(.chore, "SELECT id FROM chore WHERE assignee_id = ?", [id])
            try add(.inventoryItem, "SELECT id FROM inventory_item WHERE owner_id = ?", [id])
            try add(.storageSpot, "SELECT id FROM storage_spot WHERE owner_id = ?", [id])
        case .thing:
            try add(.chore, "SELECT id FROM chore WHERE linked_thing_id = ?", [id])
        case .costLineItem:
            try add(.project, "SELECT project_id FROM cost_line_item WHERE id = ?", [id])
        case .attachment:
            try add(.project, "SELECT owner_id FROM attachment WHERE id = ? AND owner_type = 'project'", [id])
            try add(.project, "SELECT li.project_id FROM attachment a JOIN cost_line_item li ON li.id = a.owner_id WHERE a.id = ? AND a.owner_type = 'cost_line_item'", [id])
            try add(.project, "SELECT li.project_id FROM cost_line_item li WHERE li.receipt_attachment_id = ?", [id])
        default: break
        }
        return out
    }

    struct Doc { var title: String; var body: String; var location: String?; var people: String?; var propertyId: UUID }

    static func index(_ db: Database, _ r: RecordRef) throws {
        try remove(db, r)
        guard let et = entityType(r.type), let doc = try document(db, r) else { return }
        try db.execute(sql: """
            INSERT INTO search_fts (title, body, location, people, entity_type, entity_id, property_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [doc.title, doc.body, doc.location ?? "", doc.people ?? "", et.rawValue, r.id.db, doc.propertyId.db])
    }

    static func joined(_ parts: [String?]) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }

    /// Index row for a live entity (nil when deleted or missing).
    static func document(_ db: Database, _ r: RecordRef) throws -> Doc? {
        let L = Lookup(db)
        switch r.type {
        case .chore:
            guard let c = try Chore.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            return Doc(title: c.title, body: joined([c.notes, c.repeatRule?.humanText, L.thingName(c.linkedThingId)]),
                       location: L.locationText(c.scope), people: L.personName(c.assigneeId), propertyId: c.propertyId)
        case .project:
            guard let p = try Project.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let lines = try String.fetchAll(db, sql: "SELECT label FROM cost_line_item WHERE project_id = ? AND deleted_at IS NULL ORDER BY created_at", arguments: [p.id.db])
            let ocr = try String.fetchAll(db, sql: """
                SELECT ocr_text FROM attachment WHERE deleted_at IS NULL AND ocr_text IS NOT NULL AND (
                  (owner_type = 'project' AND owner_id = ?1) OR
                  (owner_type = 'cost_line_item' AND owner_id IN (SELECT id FROM cost_line_item WHERE project_id = ?1)) OR
                  id IN (SELECT receipt_attachment_id FROM cost_line_item WHERE project_id = ?1))
                """, arguments: [p.id.db])
            return Doc(title: p.title, body: joined([p.notes, p.vendor, p.status.displayName] + lines + ocr),
                       location: L.locationText(p.scope), people: nil, propertyId: p.propertyId)
        case .thing:
            guard let t = try Thing.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let attrs = t.attributes.keys.sorted().map { t.attributes[$0]!.displayText }
            return Doc(title: t.name, body: joined([t.brand, t.model, t.serial, t.template?.name, t.notes] + attrs),
                       location: L.locationText(t.scope), people: nil, propertyId: t.propertyId)
        case .inventoryItem:
            guard let i = try InventoryItem.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let loc = [L.spaceName(i.scope.spaceId), L.spotPath(i.storageSpotId)].compactMap { $0 }.joined(separator: " › ")
            let location = [loc.isEmpty ? nil : loc, L.levelName(i.scope.levelId)].compactMap { $0 }.joined(separator: " · ")
            return Doc(title: i.name, body: joined([i.category, i.season?.rawValue, i.notes, i.unit]),
                       location: location, people: L.personName(i.ownerId), propertyId: i.propertyId)
        case .measurement:
            guard let m = try HomeMeasurement.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let level = try m.spaceId.flatMap { try String.fetchOne(db, sql: "SELECT level_id FROM space WHERE id = ?", arguments: [$0.db]) }
                .flatMap(UUID.init(uuidString:))
            let location = [L.spaceName(m.spaceId), L.levelName(level)].compactMap { $0 }.joined(separator: " · ")
            return Doc(title: m.label, body: joined([m.dims.formatted(), m.note]), location: location, people: nil, propertyId: m.propertyId)
        case .space:
            guard let s = try Space.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let dims = HomeLengthFormatter.dimensionText(for: s.polygon, isApproximate: s.isApproximate)
            return Doc(title: s.name, body: joined([s.spaceType.displayName, dims]), location: L.levelName(s.levelId), people: nil, propertyId: s.propertyId)
        case .storageSpot:
            guard let s = try StorageSpot.fetchOne(db, id: r.id, includeDeleted: false) else { return nil }
            let location = [L.spaceName(s.spaceId), L.spotPath(s.id)].compactMap { $0 }.joined(separator: " › ")
            return Doc(title: s.name, body: "", location: location, people: L.personName(s.ownerId), propertyId: s.propertyId)
        default:
            return nil
        }
    }

    /// Full rebuild (Diagnostics, or when `app_meta.fts_version` is behind). ~200 ms at 10k rows.
    static func rebuild(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM search_fts")
        for t in [RecordType.chore, .project, .thing, .inventoryItem, .measurement, .space, .storageSpot] {
            for id in try ids(db, "SELECT id FROM \(t.tableName) WHERE deleted_at IS NULL", []) { try index(db, RecordRef(t, id)) }
        }
        try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES ('fts_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [String(Migrations.ftsVersion)])
    }

    static func rebuildIfNeeded(_ db: Database) throws {
        let v = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = 'fts_version'").flatMap(Int.init)
        if v != Migrations.ftsVersion { try rebuild(db) }
    }
}
