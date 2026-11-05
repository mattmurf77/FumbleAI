import Foundation
import HomeCore

extension InMemoryAttachmentRepository {
    public func observeDocuments(propertyId: UUID) -> AsyncStream<[HomeDocument]> {
        store.observe { s in
            let lines = Dictionary(uniqueKeysWithValues: s.liveLineItems.filter { $0.propertyId == propertyId }.map { ($0.id, $0.projectId) })
            return s.liveAttachments.filter { $0.propertyId == propertyId && $0.kind != .underlay }.map {
                HomeDocument(attachment: $0, details: s.documentDetails[$0.id], lineOwners: lines)
            }.sorted { ($0.attachment.createdAt, $0.id.uuidString) > ($1.attachment.createdAt, $1.id.uuidString) }
        }
    }
    public func fileDocument(_ draft: AttachmentDraft, propertyId: UUID, details: HomeDocumentDetails) async throws -> HomeDocument {
        try details.validate()
        var a = try Self.prepare(draft, ownerType: .property, ownerId: propertyId, property: propertyId, now: store.now)
        let bytes = try Data(contentsOf: draft.fileURL)
        a.sha256 = String(PlannedNotification.stableHash(bytes.base64EncodedString()), radix: 16)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(a.fileName)
        try bytes.write(to: dest, options: .atomic)
        do {
            try store.write(events: [.recordsChanged([RecordRef(.attachment, a.id)])]) { s in
                guard s.properties[propertyId] != nil, s.properties[propertyId]?.deletedAt == nil else { throw HomeDocumentError("This home is unavailable.") }
                guard !s.liveAttachments.contains(where: { $0.propertyId == propertyId && $0.sha256 == a.sha256 }) else { throw HomeDocumentError("This file is already in Documents.") }
                if let project = details.projectId, s.projects[project]?.propertyId != propertyId || s.projects[project]?.deletedAt != nil { throw HomeDocumentError("Choose a project in this home.") }
                s.attachments[a.id] = a; s.documentDetails[a.id] = details
            }
            Self.files.set(a.id, dest)
        } catch { try? FileManager.default.removeItem(at: dest); throw error }
        return HomeDocument(attachment: a, details: details)
    }
    public func updateDocument(_ original: HomeDocument, details: HomeDocumentDetails) async throws {
        try details.validate()
        try store.write(events: [.recordsChanged([RecordRef(.attachment, original.id)])]) { s in
            guard let stored = s.attachments[original.id], stored.deletedAt == nil,
                  HomeDocument(attachment: stored, details: s.documentDetails[original.id]).details == original.details,
                  details.originalFilename == original.details.originalFilename else { throw HomeDocumentError("This document changed. Reopen it.") }
            if let project = details.projectId, s.projects[project]?.propertyId != stored.propertyId || s.projects[project]?.deletedAt != nil { throw HomeDocumentError("Choose a project in this home.") }
            s.documentDetails[original.id] = details
        }
    }
}
