import XCTest
import HomeCore

final class HomeHistoryTests: XCTestCase {
    func testEvidenceAndSpendingFollowLiveCompletedProjectsInThisHome() {
        let home = UUID(), other = UUID()
        let work = Project(propertyId: home, scope: .property, title: "Roof", status: .done)
        let warranty = Project(propertyId: home, scope: .property, title: "Warranty", status: .done, actualCost: .zero("EUR"))
        let unknown = Project(propertyId: home, scope: .property, title: "Painting", status: .done, estCost: Money(cents: 500))
        let planned = Project(propertyId: home, scope: .property, title: "Deck", status: .planned)
        let unrelated = Project(propertyId: other, scope: .property, title: "Other", status: .done)
        let amount = Money(cents: 7_654, currency: "CAD")
        let line = CostLineItem(propertyId: home, projectId: work.id, label: "Labor", amount: amount)
        let override = CostLineItem(propertyId: home, projectId: warranty.id, label: "Override", amount: amount)
        var oldLine = line; oldLine.id = UUID(); oldLine.deletedAt = Date()
        func file(_ owner: Attachment.OwnerType, id: UUID, kind: Attachment.Kind) -> Attachment {
            Attachment(propertyId: home, ownerType: owner, ownerId: id, kind: kind, fileExt: "pdf", uti: "com.adobe.pdf", byteSize: 200, sha256: "hash", caption: "Private")
        }
        let photo = file(.project, id: work.id, kind: .photo), receipt = file(.costLineItem, id: line.id, kind: .receipt)
        var removed = receipt; removed.deletedAt = Date()
        let orphan = file(.costLineItem, id: oldLine.id, kind: .receipt)
        var otherFile = receipt; otherFile.propertyId = other
        let history = HomeHistoryEntry.history(propertyId: home, projects: [work, warranty, unknown, planned, unrelated], lines: [line, override, oldLine], attachments: [photo, receipt, removed, orphan, otherFile])
        XCTAssertEqual(history.count, 3)
        let row = history.first { $0.id == work.id }
        XCTAssertEqual(row?.actual, amount); XCTAssertEqual(row?.fileCount, 2); XCTAssertEqual(row?.hasReceipt, true)
        XCTAssertEqual(history.first { $0.id == warranty.id }?.actual, .zero("EUR"))
        XCTAssertNil(history.first { $0.id == unknown.id }?.actual)
    }
}
