import XCTest
import HomeCore
@testable import HomeStore

final class ProjectHistoryTests: XCTestCase {
    func testHistoryUpdatesAfterAddingAndRemovingReceiptAndSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let property = Property(name: "House", currencyCode: "EUR"), other = Property(name: "Second house")
        let amount = Money(cents: 499, currency: "EUR")
        do {
            let store = try HomeStore.live(directory: dir)
            try await store.plan.saveProperty(property); try await store.plan.saveProperty(other)
            let work = try await store.projects.create(.init(propertyId: property.id, scope: .property, title: "Boiler", status: .done))
            _ = try await store.projects.create(.init(propertyId: other.id, scope: .property, title: "Other boiler", status: .done))
            var stream = store.projects.observeHistory(propertyId: property.id).makeAsyncIterator()
            let original = await stream.next(); XCTAssertEqual(original?.count, 1); XCTAssertEqual(original?.first?.fileCount, 0)
            let source = dir.appendingPathComponent("invoice.pdf"); try Data("receipt".utf8).write(to: source)
            let item = CostLineItem(propertyId: property.id, projectId: work.id, label: "Replacement", amount: amount)
            try await store.projects.upsertLineItem(item, receipt: AttachmentDraft(fileURL: source, kind: .receipt, uti: "com.adobe.pdf"))
            let revised = await stream.next(); XCTAssertEqual(revised?.first?.actual, amount); XCTAssertEqual(revised?.first?.hasReceipt, true)
            let files = try await store.attachments.attachments(ownerType: .costLineItem, ownerId: item.id)
            try await store.attachments.delete(try XCTUnwrap(files.first?.id))
            let removed = await stream.next(); XCTAssertEqual(removed?.first?.fileCount, 0); XCTAssertEqual(removed?.first?.hasReceipt, false)
        }
        let reopened = try HomeStore.live(directory: dir)
        var stream = reopened.projects.observeHistory(propertyId: property.id).makeAsyncIterator()
        let history = await stream.next(); XCTAssertEqual(history?.map(\.title), ["Boiler"]); XCTAssertEqual(history?.first?.actual, amount)
    }
}
