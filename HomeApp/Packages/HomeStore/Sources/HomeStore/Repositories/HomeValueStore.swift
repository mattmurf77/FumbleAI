import Foundation
import GRDB
import HomeCore

/// Private device data. The property FK handles account erasure and property purge; it never touches the sync outbox.
public struct HomeValueStore: HomeValueRepository {
    let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func observe(propertyId: UUID) -> AsyncStream<HomeValueSnapshot> {
        database.observe { db in
            let json = try String.fetchAll(db, sql: "SELECT payload FROM home_value_reference WHERE property_id = ?", arguments: [propertyId.db])
            let entries = try json.map { try HomeJSON.decode(HomeValueReference.self, from: $0) }
            return try HomeValueSnapshot(propertyId: propertyId, references: entries, projects: ProjectStore.query(db, .past(propertyId)),
                                         lines: CostLineItem.fetchAll(db, where: "property_id = ?", [propertyId.db]))
        }
    }

    public func save(_ item: HomeValueReference, replacing original: HomeValueReference?) async throws {
        try item.validate()
        try await database.write { tx in
            let db = tx.db
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM property WHERE id = ? AND deleted_at IS NULL", arguments: [item.propertyId.db]) == 1 else {
                throw HomeValueProblem("This home is no longer available.")
            }
            let newJSON = try HomeJSON.encodeString(item)
            if let original {
                guard item.id == original.id, item.propertyId == original.propertyId else { throw HomeValueProblem.conflict }
                try db.execute(sql: "UPDATE home_value_reference SET payload = ? WHERE id = ? AND property_id = ? AND payload = ?",
                               arguments: [newJSON, item.id.db, item.propertyId.db, try HomeJSON.encodeString(original)])
                guard db.changesCount == 1 else { throw HomeValueProblem.conflict }
            } else {
                try db.execute(sql: "INSERT INTO home_value_reference(id, property_id, payload) VALUES (?, ?, ?)", arguments: [item.id.db, item.propertyId.db, newJSON])
            }
        }
    }

    public func remove(_ original: HomeValueReference) async throws {
        try await database.write { tx in
            try tx.db.execute(sql: "DELETE FROM home_value_reference WHERE id = ? AND property_id = ? AND payload = ?",
                              arguments: [original.id.db, original.propertyId.db, try HomeJSON.encodeString(original)])
            guard tx.db.changesCount == 1 else { throw HomeValueProblem.conflict }
        }
    }
}
