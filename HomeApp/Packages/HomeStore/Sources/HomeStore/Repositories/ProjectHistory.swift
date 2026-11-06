import Foundation
import HomeCore
import GRDB

extension ProjectStore {
    public func observeHistory(propertyId: UUID) -> AsyncStream<[HomeHistoryEntry]> {
        db.observe { database in
            let rows = try Row.fetchAll(database, sql: "SELECT m.attachment_id, m.project_id FROM home_document_local m JOIN attachment a ON a.id=m.attachment_id WHERE a.property_id=? AND m.project_id IS NOT NULL", arguments: [propertyId.db])
            let links = try Dictionary(uniqueKeysWithValues: rows.map { (try $0.uuid("attachment_id"), try $0.uuid("project_id")) })
            return try HomeHistoryEntry.history(propertyId: propertyId, projects: Self.query(database, .past(propertyId)),
                                         lines: CostLineItem.fetchAll(database, where: "property_id = ?", [propertyId.db]),
                                         attachments: Attachment.fetchAll(database, where: "property_id = ? AND owner_type IN ('project','cost_line_item','property')", [propertyId.db]), documentLinks: links)
        }
    }
}
