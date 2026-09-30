import Foundation
import GRDB
import HomeCore

/// GRDB `AttachmentRepository`: rows in `attachment`, binaries via `AttachmentFileStore`, upload state in
/// `attachment_local` (LLD §3.3, §5.6).
public struct AttachmentStore: AttachmentRepository {
    public let db: AppDatabase
    public let files: AttachmentFileStore
    public init(_ db: AppDatabase, files: AttachmentFileStore) { self.db = db; self.files = files }

    public func attachments(ownerType: Attachment.OwnerType, ownerId: UUID) async throws -> [Attachment] {
        try await db.read { d in
            try Attachment.fetchAll(d, where: "owner_type = ? AND owner_id = ?", [ownerType.rawValue, ownerId.db])
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func add(_ draft: AttachmentDraft, ownerType: Attachment.OwnerType, ownerId: UUID, property: UUID) async throws -> Attachment {
        let a = try Self.prepare(draft, ownerType: ownerType, ownerId: ownerId, property: property, files: files, now: db.clock.now)
        return try await db.write { tx in
            let saved = try Self.insert(a, in: tx)
            tx.emit(.recordsChanged([RecordRef(.attachment, a.id)]))
            return saved
        }
    }

    /// Copies the file into the store and builds the row (outside the transaction: file I/O).
    static func prepare(_ d: AttachmentDraft, ownerType: Attachment.OwnerType, ownerId: UUID, property: UUID,
                        files: AttachmentFileStore, now: Date, id: UUID = UUID()) throws -> Attachment {
        let (size, sha) = try files.importFile(from: d.fileURL, id: id, ext: d.fileExt)
        return Attachment(id: id, propertyId: property, ownerType: ownerType, ownerId: ownerId, kind: d.kind, fileExt: d.fileExt,
                          uti: d.uti, byteSize: size, widthPx: d.widthPx, heightPx: d.heightPx, sha256: sha, caption: d.caption,
                          ocrText: d.ocrText, capturedAt: d.capturedAt, createdAt: now, updatedAt: now)
    }

    /// Inserts the row and marks the binary `needs_upload`.
    @discardableResult
    static func insert(_ a: Attachment, in tx: StoreTx) throws -> Attachment {
        let saved = try tx.save(a)
        try setLocalState(tx.db, id: a.id, state: tx.origin == .local ? "needs_upload" : "remote_only")
        return saved
    }

    static func setLocalState(_ d: Database, id: UUID, state: String) throws {
        try d.execute(sql: """
            INSERT INTO attachment_local (attachment_id, state) VALUES (?, ?)
            ON CONFLICT(attachment_id) DO UPDATE SET state = excluded.state
            """, arguments: [id.db, state])
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            let a = try tx.require(Attachment.self, id, includeDeleted: true)
            try tx.softDelete(a)
            tx.emit(.recordsChanged([RecordRef(.attachment, id)]))
        }
    }

    public func fileURL(for attachment: Attachment) async -> URL? {
        files.exists(attachment) ? files.url(for: attachment) : nil
    }
}
