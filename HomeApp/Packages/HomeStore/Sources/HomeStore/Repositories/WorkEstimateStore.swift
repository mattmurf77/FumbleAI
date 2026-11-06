import Foundation
import GRDB
import HomeCore

public struct WorkEstimateStore: WorkEstimateRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Both the home and live parent must match, including after restore or remote deletion.
    private static func target(_ owner: WorkEstimateOwner, propertyId: UUID, db: Database) throws -> (column: String, id: UUID, currency: String) {
        let column: String, id: UUID, actualProperty: UUID?
        var projectCurrency: String?
        switch owner {
        case .chore(let task):
            column = "chore_id"; id = task
            actualProperty = try Chore.fetchOne(db, id: task, includeDeleted: false)?.propertyId
        case .project(let project):
            column = "project_id"; id = project
            let record = try Project.fetchOne(db, id: project, includeDeleted: false)
            actualProperty = record?.propertyId
            projectCurrency = record?.currencyCode
        }
        guard actualProperty == propertyId, let property = try Property.fetchOne(db, id: propertyId, includeDeleted: false) else {
            throw WorkEstimateError("This project or to-do is unavailable in this home.")
        }
        return (column, id, projectCurrency ?? property.currencyCode)
    }

    public func estimates(owner: WorkEstimateOwner, propertyId: UUID) async throws -> [WorkEstimate] {
        try await db.read { database in
            let parent = try Self.target(owner, propertyId: propertyId, db: database)
            let rows = try Row.fetchAll(database, sql: "SELECT mode, details_json FROM work_estimate WHERE property_id=? AND \(parent.column)=? ORDER BY mode",
                                        arguments: [propertyId.db, parent.id.db])
            return try rows.map { row in
                let estimate = try HomeJSON.decode(WorkEstimate.self, from: row["details_json"])
                guard estimate.mode.rawValue == row["mode"] as String else { throw WorkEstimateError("The saved estimate has an inconsistent work method.") }
                _ = try estimate.totals()
                return estimate
            }
        }
    }

    static func put(_ estimates: [WorkEstimate], owner: WorkEstimateOwner, propertyId: UUID, in database: Database) throws {
        guard !estimates.isEmpty else { return }
        let parent = try target(owner, propertyId: propertyId, db: database)
        try WorkEstimate.validate(estimates, currency: parent.currency)
        for estimate in estimates {
            try database.execute(sql: """
                INSERT INTO work_estimate (property_id, \(parent.column), mode, details_json) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(parent.column), mode) DO UPDATE SET details_json=excluded.details_json
                """, arguments: [propertyId.db, parent.id.db, estimate.mode.rawValue, try HomeJSON.encodeString(estimate)])
        }
    }

    public func saveEstimates(_ estimates: [WorkEstimate], owner: WorkEstimateOwner, propertyId: UUID) async throws {
        try await db.write { tx in try Self.put(estimates, owner: owner, propertyId: propertyId, in: tx.db) }
    }
}
