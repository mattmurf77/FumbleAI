import Foundation
import HomeCore

public struct InMemoryHomeValueRepository: HomeValueRepository {
    let store: InMemoryStore
    public init(_ store: InMemoryStore) { self.store = store }
    public func observe(propertyId: UUID) -> AsyncStream<HomeValueSnapshot> {
        store.observe { s in HomeValueSnapshot(propertyId: propertyId, references: Array(s.valueReferences.values), projects: s.liveProjects, lines: s.liveLineItems) }
    }
    public func save(_ item: HomeValueReference, replacing original: HomeValueReference?) async throws {
        try item.validate()
        try store.write { s in
            guard s.properties[item.propertyId]?.deletedAt == nil, s.properties[item.propertyId] != nil else { throw HomeValueProblem("This home is no longer available.") }
            guard s.valueReferences[item.id] == original, original == nil || original?.propertyId == item.propertyId else { throw HomeValueProblem.conflict }
            s.valueReferences[item.id] = item
        }
    }
    public func remove(_ original: HomeValueReference) async throws {
        try store.write { s in
            guard s.valueReferences[original.id] == original else { throw HomeValueProblem.conflict }
            s.valueReferences.removeValue(forKey: original.id)
        }
    }
}
