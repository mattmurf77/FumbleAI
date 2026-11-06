import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomeCore

private actor CatalogReplies {
    private var responses: [HomeCatalogClient.Response]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [HomeCatalogClient.Response] = []) { self.responses = responses }
    func send(_ request: URLRequest) throws -> HomeCatalogClient.Response {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}

private func catalogFixture(day: String = "2026-11-05") throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("server/data/home-catalog.json"))
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["version"] = day + ".1"
    json["publishedAt"] = day + "T12:00:00.000Z"
    return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
}

struct HomeCatalogClientTests {
    private let endpoint = URL(string: "https://catalog.test/v1/catalog")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-06T13:00:00Z")! }

    @Test func offlineRefreshKeepsBundledContentAndOnlySendsAPublicContentRequest() async throws {
        let bundled = try HomeContentCatalog.decode(catalogFixture())
        let replies = CatalogReplies()
        let client = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test"), apiKey: "service-key"),
                                       bundled: bundled, transport: { try await replies.send($0) })
        #expect(await client.refresh(now: now) == bundled)
        #expect(await client.refresh(now: now.addingTimeInterval(1)) == bundled)
        let requests = await replies.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.query == nil)
        #expect(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["accept", "x-home-key"])
        #expect(request.value(forHTTPHeaderField: "X-Home-Key") == "service-key")
    }

    @Test func verifiedContentAndEtagSurviveRelaunchAnd304() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("catalog.json")
        let bundled = try HomeContentCatalog.decode(catalogFixture())
        let newerData = try catalogFixture(day: "2026-11-06")
        let newer = try HomeContentCatalog.decode(newerData)
        let firstReplies = CatalogReplies([.init(data: newerData, status: 200, url: endpoint, etag: "\"release-two\"")])
        let first = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test")), bundled: bundled,
                                      cacheURL: cache, transport: { try await firstReplies.send($0) })
        #expect(await first.refresh(now: now) == newer)
        let replies = CatalogReplies([.init(data: Data(), status: 304, url: endpoint)])
        let reopened = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test")), bundled: bundled,
                                         cacheURL: cache, transport: { try await replies.send($0) })
        #expect(await reopened.snapshot(now: now) == newer)
        #expect(await reopened.refresh(now: now) == newer)
        #expect(await replies.requests.first?.value(forHTTPHeaderField: "If-None-Match") == "\"release-two\"")
        #expect(await reopened.snapshot(now: now)?.reviewedOn == newer.reviewedOn)
    }

    @Test func rejectsInvalidOversizedForeignOriginOrDowngradedUpdates() async throws {
        let data = try catalogFixture(day: "2026-11-06")
        let bundled = try HomeContentCatalog.decode(data)
        let cases: [HomeCatalogClient.Response] = [
            .init(data: Data("invalid".utf8), status: 200, url: endpoint),
            .init(data: Data(repeating: 65, count: HomeContentCatalog.maximumBytes + 1), status: 200, url: endpoint),
            .init(data: data, status: 200, url: URL(string: "https://other.test/v1/catalog")),
            .init(data: data, status: 200, url: endpoint, contentType: "application/jsonp"),
            .init(data: data, status: 503, url: endpoint),
            .init(data: try catalogFixture(), status: 200, url: endpoint),
            .init(data: try catalogFixture(day: "2026-12-01"), status: 200, url: endpoint),
        ]
        for response in cases {
            let replies = CatalogReplies([response])
            let client = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test")), bundled: bundled,
                                           transport: { try await replies.send($0) })
            #expect(await client.refresh(now: now) == bundled)
        }
    }

    @Test func cacheIsBoundedAndTiedToItsOrigin() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("catalog.json")
        let bundled = try HomeContentCatalog.decode(catalogFixture())
        let newer = try catalogFixture(day: "2026-11-06")
        let replies = CatalogReplies([.init(data: newer, status: 200, url: endpoint, etag: "\"one\"")])
        let original = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test")), bundled: bundled,
                                         cacheURL: cache, transport: { try await replies.send($0) })
        _ = await original.refresh(now: now)
        let changedServer = HomeCatalogClient(config: .init(serverURL: URL(string: "https://another.test")), bundled: bundled, cacheURL: cache)
        #expect(await changedServer.snapshot(now: now) == bundled)
        try Data(repeating: 65, count: HomeContentCatalog.maximumBytes * 2 + 1).write(to: cache)
        let oversized = HomeCatalogClient(config: .init(serverURL: URL(string: "https://catalog.test")), bundled: bundled, cacheURL: cache)
        #expect(await oversized.snapshot(now: now) == bundled)
    }

    @Test func refusesUnconfiguredOrInsecureEndpoints() async throws {
        let bundled = try HomeContentCatalog.decode(catalogFixture())
        for url in [nil, URL(string: "http://catalog.test"), URL(string: "https://user:password@catalog.test"), URL(string: "https://catalog.test?address=private")] {
            let replies = CatalogReplies()
            let client = HomeCatalogClient(config: .init(serverURL: url), bundled: bundled, transport: { try await replies.send($0) })
            #expect(await client.refresh(now: now) == bundled)
            #expect(await replies.requests.isEmpty)
        }
    }
}

private final class CatalogProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var chunks: [Data] = []
    func set(headers: [String: String], chunks: [Data]) {
        lock.lock(); defer { lock.unlock() }
        self.headers = headers; self.chunks = chunks
    }
    func read() -> ([String: String], [Data]) {
        lock.lock(); defer { lock.unlock() }
        return (headers, chunks)
    }
}

private final class CatalogRequestProtocol: URLProtocol, @unchecked Sendable {
    static let state = CatalogProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (headers, chunks) = Self.state.read()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct HomeCatalogTransportTests {
    @Test func boundsAdvertisedAndActualResponseBytesAndRejectsWrongContentType() async throws {
        let request = URLRequest(url: URL(string: "https://bounded.test/v1/catalog")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRequestProtocol.self]
        CatalogRequestProtocol.state.set(headers: ["Content-Type": "application/json"], chunks: [Data("{}".utf8)])
        let valid = try await HomeCatalogClient.fetch(request, configuration: configuration)
        #expect(valid.status == 200 && valid.data == Data("{}".utf8))
        CatalogRequestProtocol.state.set(headers: ["Content-Type": "application/json", "Content-Length": String(HomeContentCatalog.maximumBytes + 1)], chunks: [])
        await #expect(throws: (any Error).self) { try await HomeCatalogClient.fetch(request, configuration: configuration) }
        CatalogRequestProtocol.state.set(headers: ["Content-Type": "application/json"],
                                         chunks: [Data(repeating: 65, count: HomeContentCatalog.maximumBytes), Data([65])])
        await #expect(throws: (any Error).self) { try await HomeCatalogClient.fetch(request, configuration: configuration) }
        CatalogRequestProtocol.state.set(headers: ["Content-Type": "text/html"], chunks: [Data("{}".utf8)])
        await #expect(throws: (any Error).self) { try await HomeCatalogClient.fetch(request, configuration: configuration) }
    }

    @Test func aPrecancelledTransferCompletesWithoutHanging() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRequestProtocol.self]
        CatalogRequestProtocol.state.set(headers: ["Content-Type": "application/json"], chunks: [Data("{}".utf8)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HomeCatalogClient.fetch(URLRequest(url: URL(string: "https://bounded.test/v1/catalog")!), configuration: configuration)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
