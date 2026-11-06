import Foundation
import GRDB
import HomeCore

extension AttachmentStore {
    static func isDeviceDocument(_ ref: RecordRef, in db: Database) throws -> Bool {
        guard ref.type == .attachment else { return false }
        return try Bool.fetchOne(db, sql: "SELECT owner_type = 'property' FROM attachment WHERE id = ?", arguments: [ref.id.db]) == true
    }

    static func libraryDetails(_ row: Row) throws -> HomeDocumentDetails {
        let json: String = row["details_json"]
        var value = try HomeJSON.decode(HomeDocumentDetails.self, from: json)
        value.projectId = row.uuidOpt("project_id")
        return value
    }

    static func libraryItem(_ a: Attachment, in db: Database) throws -> HomeDocument {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM home_document_local WHERE attachment_id = ?", arguments: [a.id.db])
        var owners: [UUID: UUID] = [:]
        if a.ownerType == .costLineItem, let line = try CostLineItem.fetchOne(db, id: a.ownerId) { owners[a.ownerId] = line.projectId }
        return try HomeDocument(attachment: a, details: row.map(libraryDetails), lineOwners: owners)
    }

    static func documents(_ db: Database, propertyId: UUID) throws -> [HomeDocument] {
        let files = try Attachment.fetchAll(db, where: "property_id = ? AND kind <> 'underlay'", [propertyId.db])
        let rows = try Row.fetchAll(db, sql: "SELECT m.* FROM home_document_local m JOIN attachment a ON a.id = m.attachment_id WHERE a.property_id = ? AND a.deleted_at IS NULL", arguments: [propertyId.db])
        var metadata: [UUID: HomeDocumentDetails] = [:]
        for row in rows { metadata[try row.uuid("attachment_id")] = try libraryDetails(row) }
        let lines = try CostLineItem.fetchAll(db, where: "property_id = ?", [propertyId.db])
        let owners = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.projectId) })
        return files.map { HomeDocument(attachment: $0, details: metadata[$0.id], lineOwners: owners) }.sorted {
            ($0.attachment.createdAt, $0.id.uuidString) > ($1.attachment.createdAt, $1.id.uuidString)
        }
    }

    public func observeDocuments(propertyId: UUID) -> AsyncStream<[HomeDocument]> { db.observe { try Self.documents($0, propertyId: propertyId) } }

    public func fileDocument(_ draft: AttachmentDraft, propertyId: UUID, details: HomeDocumentDetails) async throws -> HomeDocument {
        try details.validate()
        guard draft.fileExt.range(of: #"^[a-zA-Z0-9]{1,8}$"#, options: .regularExpression) != nil,
              let size = try draft.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= Attachment.maxPDFBytes else { throw HomeDocumentError("Choose a PDF or image up to 25 MB.") }
        let file = try Self.prepare(draft, ownerType: .property, ownerId: propertyId, property: propertyId, files: files, now: db.clock.now)
        return try await Self.committing(file, files: files) {
            try await db.write { tx in
                guard file.byteSize <= Attachment.maxPDFBytes else { throw HomeDocumentError("Choose a PDF or image up to 25 MB.") }
                _ = try tx.require(Property.self, propertyId)
                if try Bool.fetchOne(tx.db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE property_id = ? AND sha256 = ? AND deleted_at IS NULL AND kind <> 'underlay')", arguments: [propertyId.db, file.sha256]) == true {
                    throw HomeDocumentError("This file is already in this home's Documents. Find it in the library to edit its details.")
                }
                let saved = try tx.save(file)
                try Self.putDetails(details, attachment: saved, in: tx)
                tx.emit(.recordsChanged([RecordRef(.attachment, saved.id)]))
                return HomeDocument(attachment: saved, details: details)
            }
        }
    }

    static func putDetails(_ entry: HomeDocumentDetails, attachment: Attachment, in tx: StoreTx) throws {
        if let projectId = entry.projectId {
            guard try tx.require(Project.self, projectId).propertyId == attachment.propertyId else { throw HomeDocumentError("Choose a project in this home.") }
        }
        try tx.db.execute(sql: "INSERT INTO home_document_local(attachment_id, project_id, details_json) VALUES (?,?,?) ON CONFLICT(attachment_id) DO UPDATE SET project_id=excluded.project_id, details_json=excluded.details_json", arguments: [attachment.id.db, entry.projectId?.db, try HomeJSON.encodeString(entry)])
    }

    public func updateDocument(_ original: HomeDocument, details: HomeDocumentDetails) async throws {
        try details.validate()
        try await db.write { tx in
            let stored = try tx.require(Attachment.self, original.id)
            guard try Self.libraryItem(stored, in: tx.db).details == original.details else { throw HomeDocumentError("This document changed. Reopen it before editing.") }
            guard details.originalFilename == original.details.originalFilename else { throw HomeDocumentError("The original filename is preserved.") }
            try Self.putDetails(details, attachment: stored, in: tx)
            tx.emit(.recordsChanged([RecordRef(.attachment, stored.id)]))
        }
    }
}
