import Foundation
import Testing
import HomeCore
@testable import Home

private final class FeedbackTestTransport: @unchecked Sendable {
    enum Reply { case lostResponse, accepted, conflict }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var requests: [URLRequest] = []

    func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        requests = []
    }

    func next(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? .lostResponse : replies.removeFirst()
    }

    func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class FeedbackRequestProtocol: URLProtocol, @unchecked Sendable {
    static let transport = FeedbackTestTransport()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feedback.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int, body: String
        switch Self.transport.next(request) {
        case .lostResponse:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case .accepted:
            status = 201
            body = #"{"id":"11111111-2222-4333-8444-555555555555"}"#
        case .conflict:
            status = 409
            body = #"{"error":"idempotency_conflict","message":"This request identifier was already used for different feedback."}"#
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct FeedbackRetryTests {
    @Test func aLostResponseKeepsTheSameRequestIdentifierAfterReopeningTheOfflineQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pending.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FeedbackRequestProtocol.transport.reset([.lostResponse, .accepted])
        let config = AppConfig(serverURL: URL(string: "https://feedback.test"), apiKey: "test-app-key")
        let submission = FeedbackSubmission(category: .bug, message: "The action did not save.")
        let first = FeedbackClient(config: config, session: session, outbox: FeedbackOutbox(fileURL: file), followUpDelaySeconds: 0)
        #expect(try await first.submit(submission).status == .queued)
        #expect(await first.pendingCount() == 1)

        // A fresh actor and outbox read simulate relaunching after the server saved a
        // request but its response never reached the phone.
        let reopened = FeedbackClient(config: config, session: session, outbox: FeedbackOutbox(fileURL: file), followUpDelaySeconds: 0)
        #expect(await reopened.retryPending() == 1)
        #expect(await reopened.pendingCount() == 0)
        let requests = FeedbackRequestProtocol.transport.captured()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Home-Request-ID") == submission.id.uuidString.lowercased() })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Home-Key") == "test-app-key" })
    }

    @Test func conflictingRequestIdentifierIsNotRetriedForever() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FeedbackRequestProtocol.transport.reset([.conflict])
        let client = FeedbackClient(config: AppConfig(serverURL: URL(string: "https://feedback.test")), session: session,
                                    outbox: FeedbackOutbox(fileURL: directory.appendingPathComponent("pending.json")), followUpDelaySeconds: 0)
        await #expect(throws: FeedbackError.self) {
            try await client.submit(FeedbackSubmission(category: .idea, message: "An idea"))
        }
        #expect(await client.pendingCount() == 0)
        #expect(FeedbackRequestProtocol.transport.captured().count == 1)
    }
}
