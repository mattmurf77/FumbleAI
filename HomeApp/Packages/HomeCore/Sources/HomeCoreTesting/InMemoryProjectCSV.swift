import Foundation
import HomeCore

extension InMemoryProjectRepository {
    private static func planCSV(_ rows: [ProjectCSVItem], propertyID: UUID, snapshot: InMemorySnapshot) throws -> (Property, [ProjectCSVDecision]) {
        guard let property = snapshot.properties[propertyID], property.deletedAt == nil else {
            throw ProjectCSVError("The selected home is no longer available.")
        }
        let known = snapshot.csvImportSignatures[propertyID, default: []]
        return try (property, ProjectCSVBatch.review(rows, property: property, existing: Array(snapshot.projects.values)) { known.contains($0.signature) })
    }

    public func reviewCSVImport(_ rows: [ProjectCSVItem], propertyID: UUID) async throws -> [ProjectCSVDecision] {
        try store.read { try Self.planCSV(rows, propertyID: propertyID, snapshot: $0).1 }
    }

    public func importCompletedCSV(_ rows: [ProjectCSVItem], propertyID: UUID) async throws -> [ProjectCSVDecision] {
        let now = store.now
        let (decisions, created) = try store.write { snapshot -> ([ProjectCSVDecision], [UUID]) in
            let (property, decisions) = try Self.planCSV(rows, propertyID: propertyID, snapshot: snapshot)
            var ids: [UUID] = []
            for result in decisions where result.disposition == .ready {
                let project = result.item.makeProject(property: property, now: now)
                snapshot.projects[project.id] = project
                snapshot.csvImportSignatures[propertyID, default: []].insert(result.item.signature)
                ids.append(project.id)
            }
            return (decisions, ids)
        }
        for id in created { store.bus.publish(.created(.project(id))) }
        return decisions
    }
}
