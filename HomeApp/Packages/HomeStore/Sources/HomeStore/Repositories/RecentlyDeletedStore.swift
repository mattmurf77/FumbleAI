import Foundation
import GRDB
import HomeCore

/// GRDB `RecentlyDeletedRepository` (spec 09 FR-SES-60..65): 30-day list, restore with re-homing, hard purge
/// (enqueues CloudKit deletes for the row and the children that cascade with it).
public struct RecentlyDeletedStore: RecentlyDeletedRepository {
    public let db: AppDatabase
    public let files: AttachmentFileStore
    public init(_ db: AppDatabase, files: AttachmentFileStore) { self.db = db; self.files = files }

    /// Record types listed in Recently Deleted, with their user-facing kind label.
    static let listed: [(RecordType, String)] = [
        (.level, "Floor"), (.space, "Room"), (.storageSpot, "Storage spot"), (.chore, "To-Do"), (.project, "Project"),
        (.thing, "Thing"), (.inventoryItem, "Item"), (.measurement, "Measurement"), (.person, "Person")]

    static func entries(_ d: Database, property: UUID) throws -> [DeletedEntry] {
        let L = Lookup(d)
        var out: [DeletedEntry] = []
        let w = "property_id = ? AND deleted_at IS NOT NULL"
        let a: StatementArguments = [property.db]
        func add(_ t: RecordType, _ id: UUID, _ title: String, _ kind: String, _ loc: String?, _ at: Date?) {
            guard let at else { return }
            out.append(DeletedEntry(ref: RecordRef(t, id), title: title, kindLabel: kind, originalLocation: loc, deletedAt: at))
        }
        for x in try Level.fetchAll(d, where: w, a, includeDeleted: true) { add(.level, x.id, x.name, "Floor", nil, x.deletedAt) }
        for x in try Space.fetchAll(d, where: w, a, includeDeleted: true) { add(.space, x.id, x.name, "Room", L.levelName(x.levelId), x.deletedAt) }
        for x in try StorageSpot.fetchAll(d, where: w, a, includeDeleted: true) { add(.storageSpot, x.id, x.name, "Storage spot", L.spaceName(x.spaceId), x.deletedAt) }
        for x in try Chore.fetchAll(d, where: w, a, includeDeleted: true) { add(.chore, x.id, x.title, "To-Do", L.locationText(x.scope), x.deletedAt) }
        for x in try Project.fetchAll(d, where: w, a, includeDeleted: true) { add(.project, x.id, x.title, "Project", L.locationText(x.scope), x.deletedAt) }
        for x in try Thing.fetchAll(d, where: w, a, includeDeleted: true) { add(.thing, x.id, x.name, "Thing", L.locationText(x.scope), x.deletedAt) }
        for x in try InventoryItem.fetchAll(d, where: w, a, includeDeleted: true) { add(.inventoryItem, x.id, x.name, "Item", L.locationText(x.scope), x.deletedAt) }
        for x in try HomeMeasurement.fetchAll(d, where: w, a, includeDeleted: true) { add(.measurement, x.id, x.label, "Measurement", L.spaceName(x.spaceId), x.deletedAt) }
        for x in try Person.fetchAll(d, where: w, a, includeDeleted: true) { add(.person, x.id, x.name, "Person", nil, x.deletedAt) }
        return out.sorted { ($0.deletedAt, $0.ref.id.db) > ($1.deletedAt, $1.ref.id.db) }
    }

    public func deleted(property: UUID) async throws -> [DeletedEntry] { try await db.read { try Self.entries($0, property: property) } }
    public func observeDeleted(property: UUID) -> AsyncStream<[DeletedEntry]> { db.observe { try Self.entries($0, property: property) } }

    public func restore(_ ref: RecordRef) async throws {
        try await db.write { tx in
            try Self.restore(ref, in: tx)
            tx.emit(.recordsChanged([ref]))
            switch ref.type {
            case .chore: tx.emit(.restored(.chore(ref.id)))
            case .project: tx.emit(.restored(.project(ref.id)))
            case .thing: tx.emit(.restored(.thing(ref.id)))
            case .inventoryItem: tx.emit(.restored(.inventory(ref.id)))
            case .measurement: tx.emit(.restored(.measurement(ref.id)))
            default: break
            }
        }
    }

    static func restore(_ ref: RecordRef, in tx: StoreTx) throws {
        // FR-SES-64: an item whose room is still deleted goes to its floor (or whole house).
        func fix(_ scope: Scope) throws -> Scope {
            switch scope {
            case .space(let sp, let l):
                let spaceLive = try tx.get(Space.self, sp) != nil
                if spaceLive { return scope }
                return try tx.get(Level.self, l) != nil ? .level(l) : .property
            case .level(let l):
                return try tx.get(Level.self, l) != nil ? scope : .property
            case .property: return scope
            }
        }
        func undelete<M: DatabaseModel>(_ t: M.Type, _ f: (inout M) throws -> Void = { _ in }) throws {
            guard var m = try tx.get(t, ref.id, includeDeleted: true) else { throw RepositoryError.notFound(ref) }
            m.deletedAt = nil
            try f(&m)
            try tx.save(m)
        }
        switch ref.type {
        case .level: try undelete(Level.self)
        case .space: try undelete(Space.self)
        case .storageSpot:
            try undelete(StorageSpot.self) { s in
                if let p = s.parentSpotId, try tx.get(StorageSpot.self, p) == nil { s.parentSpotId = nil }
            }
        case .chore: try undelete(Chore.self) { $0.scope = try fix($0.scope) }
        case .project: try undelete(Project.self) { $0.scope = try fix($0.scope) }
        case .thing: try undelete(Thing.self) { $0.scope = try fix($0.scope) }
        case .inventoryItem:
            try undelete(InventoryItem.self) { i in
                let f = try fix(i.scope)
                if f != i.scope { i.storageSpotId = nil }
                if let sid = i.storageSpotId, try tx.get(StorageSpot.self, sid) == nil { i.storageSpotId = nil }
                i.scope = f
            }
        case .measurement: try undelete(HomeMeasurement.self)
        case .person: try undelete(Person.self)
        case .opening: try undelete(Opening.self)
        case .costLineItem: try undelete(CostLineItem.self)
        case .attachment: try undelete(Attachment.self)
        default: throw RepositoryError.invalid("Cannot restore \(ref.type.rawValue)")
        }
    }

    public func purge(_ ref: RecordRef) async throws {
        let removed = try await db.write { tx -> [Attachment] in
            let r = try Self.purge(ref, in: tx)
            tx.emit(.recordsChanged([ref]))
            return r
        }
        for a in removed { files.remove(id: a.id, ext: a.fileExt) }
    }

    public func purgeExpired(before cutoff: Date) async throws -> Int {
        let (count, removed) = try await db.write { tx -> (Int, [Attachment]) in
            var refs: [RecordRef] = []
            for t in RecordType.allCases where t != .property {
                let ids = try String.fetchAll(tx.db, sql: "SELECT id FROM \(t.tableName) WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                                              arguments: [cutoff]).compactMap(UUID.init(uuidString:))
                refs += ids.map { RecordRef(t, $0) }
            }
            var removed: [Attachment] = []
            var n = 0
            for r in refs {
                // A parent purged earlier in this loop may already have cascaded this row away.
                guard try Row.fetchOne(tx.db, sql: "SELECT 1 FROM \(r.type.tableName) WHERE id = ?", arguments: [r.id.db]) != nil else { continue }
                removed += try Self.purge(r, in: tx)
                if Self.listed.contains(where: { $0.0 == r.type }) { n += 1 }
            }
            if !refs.isEmpty { tx.emit(.recordsChanged(Set(refs))) }
            return (n, removed)
        }
        for a in removed { files.remove(id: a.id, ext: a.fileExt) }
        return count
    }

    /// Hard-deletes `ref`, first re-homing rows whose scope CHECK would break on `ON DELETE SET NULL`, enqueuing
    /// deletes for FK-cascaded children and removing owned attachments. Returns the attachments whose files to delete.
    static func purge(_ ref: RecordRef, in tx: StoreTx) throws -> [Attachment] {
        let d = tx.db
        guard let propText = try String.fetchOne(d, sql: "SELECT \(ref.type == .property ? "id" : "property_id") FROM \(ref.type.tableName) WHERE id = ?",
                                                 arguments: [ref.id.db]),
              let property = UUID(uuidString: propText) else { return [] }
        let zone = Property.zoneName(for: property)
        var victims: [RecordRef] = [ref]
        func collect(_ t: RecordType, _ sql: String, _ args: StatementArguments) throws {
            for id in try String.fetchAll(d, sql: sql, arguments: args).compactMap(UUID.init(uuidString:)) {
                let r = RecordRef(t, id)
                if !victims.contains(r) { victims.append(r) }
            }
        }
        // Children removed by ON DELETE CASCADE (synced rows need their own CloudKit delete).
        var frontier = [ref]
        while let r = frontier.popLast() {
            let before = victims.count
            let id: StatementArguments = [r.id.db]
            switch r.type {
            case .level:
                try collect(.space, "SELECT id FROM space WHERE level_id = ?", id)
                try collect(.opening, "SELECT id FROM opening WHERE level_id = ?", id)
            case .space:
                try collect(.storageSpot, "SELECT id FROM storage_spot WHERE space_id = ?", id)
                try collect(.measurement, "SELECT id FROM measurement WHERE space_id = ?", id)
            case .opening: try collect(.measurement, "SELECT id FROM measurement WHERE opening_id = ?", id)
            case .storageSpot: try collect(.storageSpot, "SELECT id FROM storage_spot WHERE parent_spot_id = ?", id)
            case .chore:
                try collect(.choreCompletion, "SELECT id FROM chore_completion WHERE chore_id = ?", id)
                try collect(.choreCalendarLink, "SELECT id FROM chore_calendar_link WHERE chore_id = ?", id)
            case .project: try collect(.costLineItem, "SELECT id FROM cost_line_item WHERE project_id = ?", id)
            default: break
            }
            frontier += victims[before...]
        }
        // Scope re-homing so FK SET NULL never violates the scope CHECK.
        for v in victims {
            switch v.type {
            case .space:
                guard let sp = try Space.fetchOne(d, id: v.id) else { continue }
                try rehome(column: "space_id", v.id, to: .level(sp.levelId), in: tx, levelTarget: sp.levelId)
            case .level:
                try rehome(column: "level_id", v.id, to: .property, in: tx, levelTarget: nil)
            default: break
            }
        }
        // Owned attachments (polymorphic, app-level cascade).
        var attachments: [Attachment] = []
        for v in victims {
            guard let ot = ownerType(v.type) else { continue }
            let owned = try Attachment.fetchAll(d, where: "owner_type = ? AND owner_id = ?", [ot.rawValue, v.id.db], includeDeleted: true)
            attachments += owned
        }
        if ref.type == .attachment, let a = try Attachment.fetchOne(d, id: ref.id) { attachments.append(a) }
        for a in attachments where a.id != ref.id || ref.type != .attachment {
            try d.execute(sql: "DELETE FROM attachment_local WHERE attachment_id = ?", arguments: [a.id.db])
            try tx.hardDelete(RecordRef(.attachment, a.id), zone: zone)
        }
        if ref.type == .attachment { try d.execute(sql: "DELETE FROM attachment_local WHERE attachment_id = ?", arguments: [ref.id.db]) }
        // Children first (their outbox deletes), then the row itself (cascade is then a no-op).
        for v in victims.reversed() { try tx.hardDelete(v, zone: zone) }
        return attachments
    }

    static func rehome(column: String, _ id: UUID, to target: Scope, in tx: StoreTx, levelTarget: UUID?) throws {
        let w = "\(column) = ?"
        for var c in try Chore.fetchAll(tx.db, where: w, [id.db], includeDeleted: true) { c.scope = retarget(c.scope, target); try tx.save(c) }
        for var p in try Project.fetchAll(tx.db, where: w, [id.db], includeDeleted: true) { p.scope = retarget(p.scope, target); try tx.save(p) }
        for var t in try Thing.fetchAll(tx.db, where: w, [id.db], includeDeleted: true) { t.scope = retarget(t.scope, target); try tx.save(t) }
        for var i in try InventoryItem.fetchAll(tx.db, where: w, [id.db], includeDeleted: true) {
            i.scope = retarget(i.scope, target); i.storageSpotId = nil; try tx.save(i)
        }
    }

    static func retarget(_ s: Scope, _ target: Scope) -> Scope { target }

    static func ownerType(_ t: RecordType) -> Attachment.OwnerType? {
        switch t {
        case .chore: return .chore; case .choreCompletion: return .choreCompletion; case .project: return .project
        case .costLineItem: return .costLineItem; case .thing: return .thing; case .inventoryItem: return .inventoryItem
        case .measurement: return .measurement; case .space: return .space; case .level: return .level
        case .storageSpot: return .storageSpot
        default: return nil
        }
    }
}
