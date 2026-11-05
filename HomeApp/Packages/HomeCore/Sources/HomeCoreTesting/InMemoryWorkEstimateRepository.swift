import Foundation
import HomeCore

public struct InMemoryWorkEstimateRepository: WorkEstimateRepository {
    let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    private static func currency(_ owner: WorkEstimateOwner, propertyId: UUID, snapshot: InMemorySnapshot) throws -> String {
        let actualProperty: UUID?
        var projectCurrency: String?
        switch owner {
        case .chore(let id):
            actualProperty = snapshot.chores[id].flatMap { $0.deletedAt == nil ? $0.propertyId : nil }
        case .project(let id):
            let project = snapshot.projects[id].flatMap { $0.deletedAt == nil ? $0 : nil }
            actualProperty = project?.propertyId
            projectCurrency = project?.currencyCode
        }
        guard actualProperty == propertyId, let home = snapshot.properties[propertyId], home.deletedAt == nil else {
            throw WorkEstimateError("This project or to-do is unavailable in this home.")
        }
        return projectCurrency ?? home.currencyCode
    }

    public func estimates(owner: WorkEstimateOwner, propertyId: UUID) async throws -> [WorkEstimate] {
        try store.read { snapshot in
            _ = try Self.currency(owner, propertyId: propertyId, snapshot: snapshot)
            return Chore.WorkMode.allCases.compactMap { snapshot.workEstimates[owner]?[$0] }
        }
    }

    static func put(_ estimates: [WorkEstimate], owner: WorkEstimateOwner, propertyId: UUID, in snapshot: inout InMemorySnapshot) throws {
        guard !estimates.isEmpty else { return }
        let ownerCurrency = try currency(owner, propertyId: propertyId, snapshot: snapshot)
        try WorkEstimate.validate(estimates, currency: ownerCurrency)
        for estimate in estimates { snapshot.workEstimates[owner, default: [:]][estimate.mode] = estimate }
    }

    public func saveEstimates(_ estimates: [WorkEstimate], owner: WorkEstimateOwner, propertyId: UUID) async throws {
        try store.write { try Self.put(estimates, owner: owner, propertyId: propertyId, in: &$0) }
    }
}
