import XCTest
import HomeCore
import HomeCoreTesting

final class FeedbackTests: XCTestCase {
    func testCategoriesMatchServer() {
        XCTAssertEqual(FeedbackCategory.allCases.map(\.rawValue), ["bug", "polish", "idea"])
        XCTAssertEqual(FeedbackCategory.allCases.map(\.displayName), ["Bug", "Polish", "Idea"])
        XCTAssertTrue(FeedbackCategory.allCases.allSatisfy { !$0.symbolName.isEmpty && !$0.prompt.isEmpty })
    }

    func testValidation() {
        XCTAssertFalse(FeedbackSubmission(category: .bug, message: "  \n ").isValid)
        XCTAssertTrue(FeedbackSubmission(category: .bug, message: " x ").isValid)
        XCTAssertTrue(FeedbackSubmission(category: .idea, message: String(repeating: "é", count: 5000)).isValid)
        XCTAssertFalse(FeedbackSubmission(category: .idea, message: String(repeating: "a", count: 5001)).isValid)
    }

    func testRequestBodyShape() throws {
        let s = FeedbackSubmission(
            category: .polish, message: "  Tighter spacing  ", page: "  Plan · Ground floor ",
            screenContext: ["lens": "plan"], appVersion: "1.0", buildNumber: "7", osVersion: "17.5.1",
            deviceModel: "iPhone15,2", installId: "abc", createdAt: Date(timeIntervalSince1970: 0))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: s.requestBody()) as? [String: Any])
        XCTAssertEqual(json["category"] as? String, "polish")
        XCTAssertEqual(json["message"] as? String, "Tighter spacing")
        XCTAssertEqual(json["page"] as? String, "Plan · Ground floor")
        XCTAssertEqual(json["appVersion"] as? String, "1.0")
        XCTAssertEqual(json["buildNumber"] as? String, "7")
        XCTAssertEqual(json["osVersion"] as? String, "17.5.1")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(json["installId"] as? String, "abc")
        XCTAssertNil(json["id"], "client id stays on device")
        let ctx = try XCTUnwrap(json["screenContext"] as? [String: String])
        XCTAssertEqual(ctx["lens"], "plan")
        XCTAssertEqual(ctx["clientCreatedAt"], "1970-01-01T00:00:00Z")
    }

    func testEmptyPageIsOmitted() throws {
        let s = FeedbackSubmission(category: .bug, message: "x", page: "   ")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: s.requestBody()) as? [String: Any])
        XCTAssertNil(json["page"])
    }

    func testSubmissionRoundTripsForTheQueue() throws {
        let s = FeedbackSubmission(category: .idea, message: "Dark plan", page: "Settings", screenContext: ["a": "b"])
        let back = try JSONDecoder().decode(FeedbackSubmission.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.id, s.id)
        XCTAssertEqual(back.category, .idea)
        XCTAssertEqual(back.page, "Settings")
    }

    func testInMemorySubmitterQueuesWhileOffline() async throws {
        let sub = InMemoryFeedbackSubmitter(offline: true)
        let r1 = try await sub.submit(FeedbackSubmission(category: .bug, message: "one"))
        XCTAssertEqual(r1.status, .queued)
        let pendingCount = await sub.pendingCount()
        XCTAssertEqual(pendingCount, 1)
        let none = await sub.retryPending()
        XCTAssertEqual(none, 0)
        sub.offline = false
        let sentCount = await sub.retryPending()
        XCTAssertEqual(sentCount, 1)
        let r2 = try await sub.submit(FeedbackSubmission(category: .idea, message: "two"))
        XCTAssertEqual(r2.status, .sent)
        XCTAssertEqual(sub.sent.map(\.message), ["one", "two"])
        do {
            _ = try await sub.submit(FeedbackSubmission(category: .idea, message: " "))
            XCTFail("expected invalidMessage")
        } catch {
            XCTAssertEqual(error as? FeedbackError, .invalidMessage)
        }
    }
}
