import Foundation
import GRDB
import HomeCore

extension ProjectStore {
    private static func planCSV(_ rows: [ProjectCSVItem], property: Property, database: Database) throws -> [ProjectCSVDecision] {
        var projects = try Project.fetchAll(database, where: "property_id = ?", [property.id.db], includeDeleted: true)
        let local = Set(projects.map(\.id))
        // Native project exports carry identity. Reject IDs already owned by another home.
        for id in Set(rows.compactMap(\.sourceID)).subtracting(local) {
            if let other = try Project.fetchOne(database, id: id) { projects.append(other) }
        }
        let receipts = Set(try String.fetchAll(database, sql: "SELECT fingerprint FROM project_csv_import WHERE property_id = ?", arguments: [property.id.db]))
        return try ProjectCSVBatch.review(rows, property: property, existing: projects) { receipts.contains(SHA256.hex(Data($0.signature.utf8))) }
    }

    public func reviewCSVImport(_ rows: [ProjectCSVItem], propertyID: UUID) async throws -> [ProjectCSVDecision] {
        try await db.read { database in
            guard let property = try Property.fetchOne(database, id: propertyID, includeDeleted: false) else {
                throw ProjectCSVError("The selected home is no longer available.")
            }
            return try Self.planCSV(rows, property: property, database: database)
        }
    }

    public func importCompletedCSV(_ rows: [ProjectCSVItem], propertyID: UUID) async throws -> [ProjectCSVDecision] {
        try await db.write { tx in
            let property = try tx.require(Property.self, propertyID)
            let decisions = try Self.planCSV(rows, property: property, database: tx.db)
            for result in decisions where result.disposition == .ready {
                let project = try tx.save(result.item.makeProject(property: property, now: tx.now))
                try tx.db.execute(sql: "INSERT INTO project_csv_import(property_id, fingerprint, project_id) VALUES (?, ?, ?)",
                                  arguments: [property.id.db, SHA256.hex(Data(result.item.signature.utf8)), project.id.db])
                tx.emit(.created(.project(project.id)))
            }
            return decisions
        }
    }
}
