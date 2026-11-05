import Foundation
import HomeCore

extension InMemoryProjectRepository {
    public func observeHistory(propertyId: UUID) -> AsyncStream<[HomeHistoryEntry]> {
        store.observe { s in HomeHistoryEntry.history(propertyId: propertyId, projects: s.liveProjects, lines: s.liveLineItems, attachments: s.liveAttachments, documentLinks: s.documentDetails.compactMapValues(\.projectId)) }
    }
}
