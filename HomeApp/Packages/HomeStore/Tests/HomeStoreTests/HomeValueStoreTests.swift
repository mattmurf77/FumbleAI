import XCTest
import GRDB
import HomeCore
@testable import HomeStore

final class HomeValueStoreTests: XCTestCase {
    func testValuationPersistsWithoutCloudKitAndPreservesExistingProjectData() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let property = Property(name: "House", currencyCode: "EUR"), other = Property(name: "Other")
        let date = LocalDate(2026, 9, 1), cost = Money(cents: 4321, currency: "EUR")
        let ref = HomeValueReference(propertyId: property.id, kind: .appraisal, source: "Agent report", asOf: date, amount: Money(cents: 7_000_000, currency: "EUR"))
        do {
            let store = try HomeStore.live(directory: dir)
            try await store.plan.saveProperty(property); try await store.plan.saveProperty(other)
            let work = try await store.projects.create(.init(propertyId: property.id, scope: .property, title: "Window repair", status: .done, completedOn: date))
            try await store.projects.upsertLineItem(.init(propertyId: property.id, projectId: work.id, label: "Glass", amount: cost))
            _ = try await store.projects.create(.init(propertyId: other.id, scope: .property, title: "Other house", status: .done, completedOn: date))
            let before = try await store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_outbox") }
            let values = HomeValueStore(store.database); try await values.save(ref, replacing: nil)
            let after = try await store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_outbox") }
            XCTAssertEqual(before, after)
        }
        let reopened = try HomeStore.live(directory: dir); let journal = HomeValueStore(reopened.database)
        var iterator = journal.observe(propertyId: property.id).makeAsyncIterator()
        let next = await iterator.next(); let result = try XCTUnwrap(next)
        XCTAssertEqual(result.latestEstimate, ref); XCTAssertEqual(result.investments.map(\.actual), [cost])
        XCTAssertEqual(result.investments.map(\.title), ["Window repair"])
        var edited = ref; edited.source = "Revised agent report"
        try await journal.save(edited, replacing: ref)
        do { try await journal.remove(ref); XCTFail("A stale edit deleted a newer reference") } catch is HomeValueProblem {}
        try await journal.remove(edited)
        var clean = journal.observe(propertyId: property.id).makeAsyncIterator()
        let empty = await clean.next(); XCTAssertEqual(empty?.references.count, 0)
    }
}
