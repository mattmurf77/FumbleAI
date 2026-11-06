import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// No household identifiers, addresses, task text or purchase data are sent with a catalog request.
public actor HomeCatalogClient {
    public struct Response: Sendable {
        public let data: Data
        public let status: Int
        public let url: URL?
        public let etag: String?
        public let contentType: String?
        public init(data: Data, status: Int, url: URL?, etag: String? = nil, contentType: String? = "application/json") {
            self.data = data; self.status = status; self.url = url; self.etag = etag; self.contentType = contentType
        }
    }
    public typealias Transport = @Sendable (URLRequest) async throws -> Response
    private struct Cached: Codable {
        let endpoint: URL
        let etag: String?
        let data: Data
    }
    private let endpoint: URL?
    private let apiKey: String?
    private let cacheURL: URL?
    private let transport: Transport
    private var current: HomeContentCatalog?
    private var cached: Cached?
    private var restored = false
    private var lastAttempt: Date?
    private var fetching = false

    public init(config: AppConfig, bundled: HomeContentCatalog?, cacheURL: URL? = nil,
                transport: @escaping Transport = { try await HomeCatalogClient.fetch($0) }) {
        let url = config.serverURL
        if let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {
            endpoint = url.appendingPathComponent("v1/catalog")
        } else { endpoint = nil }
        apiKey = config.apiKey; self.cacheURL = cacheURL; self.transport = transport; current = bundled
    }

    /// Loads a valid cache for this exact server before any network request. Invalid files are ignored.
    public func snapshot(now: Date = Date()) -> HomeContentCatalog? {
        if !restored {
            restored = true
            if let cacheURL, let bytes = Self.readCache(cacheURL),
               let saved = try? JSONDecoder().decode(Cached.self, from: bytes), saved.endpoint == endpoint,
               let catalog = try? HomeContentCatalog.decode(saved.data), accepts(catalog),
               let publication = catalog.publicationDate, publication <= now.addingTimeInterval(86_400) {
                current = catalog
                cached = Cached(endpoint: saved.endpoint, etag: Self.safeEtag(saved.etag), data: saved.data)
            }
        }
        return current
    }

    /// At most one request every six hours per process; failures leave the last valid content in place.
    /// Cached content carries its original review dates, never a newly invented freshness date.
    public func refresh(now: Date = Date(), force: Bool = false) async -> HomeContentCatalog? {
        _ = snapshot(now: now)
        guard let endpoint, !fetching,
              force || lastAttempt.map({ now.timeIntervalSince($0) >= 6 * 3600 }) != false else { return current }
        fetching = true; lastAttempt = now
        defer { fetching = false }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: AppConfig.apiKeyHeader) }
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let response = try await transport(request)
            guard response.url == endpoint else { return current }
            if response.status == 304 { return current }
            guard response.status == 200, response.contentType?.lowercased().split(separator: ";").first?
                    .trimmingCharacters(in: .whitespaces) == "application/json",
                  let catalog = try? HomeContentCatalog.decode(response.data), accepts(catalog),
                  let date = catalog.publicationDate, date <= now.addingTimeInterval(86_400) else { return current }
            let etag = Self.safeEtag(response.etag)
            let saved = Cached(endpoint: endpoint, etag: etag, data: response.data)
            current = catalog; cached = saved
            if let cacheURL, let data = try? JSONEncoder().encode(saved) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        } catch { /* Offline or unavailable: the app keeps the last valid catalog. */ }
        return current
    }

    private func accepts(_ catalog: HomeContentCatalog) -> Bool {
        guard let publication = catalog.publicationDate else { return false }
        return current?.publicationDate.map { publication >= $0 } ?? true
    }

    private static func safeEtag(_ value: String?) -> String? {
        value.flatMap { $0.count <= 200 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? $0 : nil }
    }

    private static func readCache(_ url: URL) -> Data? {
        // Bound the actual read as well as decoded size; file metadata alone can race a replacement.
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let limit = HomeContentCatalog.maximumBytes * 2
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    public static func fetch(_ request: URLRequest) async throws -> Response {
        try await fetch(request, configuration: .ephemeral)
    }

    // Internal configuration injection exercises the real bounded transport with URLProtocol
    // in tests. Production always enters through the ephemeral one-argument method above.
    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Response {
        let transfer = CatalogTransfer(endpoint: request.url, configuration: configuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(request, continuation: $0) }
        } onCancel: {
            transfer.cancel()
        }
    }
}

/// A delegate bounds decompressed bytes as they arrive, even when Content-Length is absent
/// or misleading. Its lock coordinates task cancellation with serial URLSession callbacks.
private final class CatalogTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoint: URL?
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<HomeCatalogClient.Response, Error>?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var finished = false

    init(endpoint: URL?, configuration: URLSessionConfiguration) {
        self.endpoint = endpoint
        self.configuration = configuration
    }

    func start(_ request: URLRequest, continuation: CheckedContinuation<HomeCatalogClient.Response, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<HomeCatalogClient.Response, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func result(_ http: HTTPURLResponse, data: Data = Data()) -> HomeCatalogClient.Response {
        .init(data: data, status: http.statusCode, url: http.url,
              etag: http.value(forHTTPHeaderField: "ETag"), contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == endpoint else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        guard http.statusCode == 200 else {
            // No error-page or 304 body is useful to the caller. Stop receiving it immediately.
            completionHandler(.cancel)
            finish(.success(result(http)))
            return
        }
        guard http.expectedContentLength <= Int64(HomeContentCatalog.maximumBytes),
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces) == "application/json" else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        lock.lock()
        let active = !finished
        if active { self.response = http }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= HomeContentCatalog.maximumBytes - bytes.count else {
            lock.unlock()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let response = self.response
        let bytes = self.bytes
        lock.unlock()
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success(result(response, data: bytes)))
    }

    // Never forward the embedded app key to a redirected host or path.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
