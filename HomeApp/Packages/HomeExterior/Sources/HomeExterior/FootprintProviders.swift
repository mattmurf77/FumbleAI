import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlanKit
import HomeCore

public enum FootprintError: Error, Hashable, Sendable {
    /// HTTP 429 / 503 `upstream_rate_limited`: treat like no network, retry next launch (spec 03).
    case rateLimited(retryAfterSeconds: Int?)
    /// HTTP 401 from the Home server (wrong `X-Home-Key`).
    case unauthorized
    /// Other non-success status (e.g. 502 `upstream_unavailable`).
    case http(status: Int)
    case badResponse
}

/// Minimal HTTP seam so request construction and status handling are testable without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return cont.resume(throwing: error) }
                guard let http = response as? HTTPURLResponse else { return cont.resume(throwing: FootprintError.badResponse) }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}

/// Home server: `GET {serverURL}/v1/footprint?lat=&lon=` with `X-Home-Key` when configured (server/README.md).
/// 404 `no_building` → nil (the caller places the 40 × 30 ft fallback block).
public struct ServerFootprintProvider: FootprintProviding {
    public var config: AppConfig
    public var transport: any HTTPTransport
    public var timeout: TimeInterval

    public init(config: AppConfig, transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 20) {
        self.config = config; self.transport = transport; self.timeout = timeout
    }

    public func request(near c: GeoCoordinate) -> URLRequest? {
        guard let base = config.serverURL else { return nil }
        let url = base.appendingPathComponent("v1").appendingPathComponent("footprint")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.6f", c.latitude)),
                            URLQueryItem(name: "lon", value: String(format: "%.6f", c.longitude))]
        guard let u = comps.url else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(OverpassFootprintProvider.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in config.serverHeaders { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    public func footprint(near c: GeoCoordinate) async throws -> FootprintResult? {
        guard let req = request(near: c) else { throw FootprintError.badResponse }
        let (data, http) = try await transport.send(req)
        switch http.statusCode {
        case 200: return try ServerFootprintParser.footprint(from: data)
        case 404: return nil
        case 401: throw FootprintError.unauthorized
        case 429, 503: throw FootprintError.rateLimited(retryAfterSeconds: (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) })
        default: throw FootprintError.http(status: http.statusCode)
        }
    }
}

/// Direct Overpass: one POST to `AppConfig.overpassURL`, 15 s timeout, app-identifying User-Agent (§6.11).
public struct OverpassFootprintProvider: FootprintProviding {
    public static let defaultUserAgent = "Home/1.0 (iOS; app.fumble.home)"
    public var endpoint: URL
    public var userAgent: String
    public var transport: any HTTPTransport

    public init(endpoint: URL = AppConfig.overpassURL, userAgent: String = OverpassFootprintProvider.defaultUserAgent,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint; self.userAgent = userAgent; self.transport = transport
    }

    public func request(near c: GeoCoordinate) -> URLRequest {
        var r = URLRequest(url: endpoint, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let q = OverpassParser.query(lat: c.latitude, lon: c.longitude).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        r.httpBody = Data(("data=" + q).utf8)
        return r
    }

    public func footprint(near c: GeoCoordinate) async throws -> FootprintResult? {
        let (data, http) = try await transport.send(request(near: c))
        switch http.statusCode {
        case 200: return try OverpassParser.footprint(from: data, near: c)
        case 429, 503, 504: throw FootprintError.rateLimited(retryAfterSeconds: (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) })
        default: throw FootprintError.http(status: http.statusCode)
        }
    }
}

/// The provider the app wires: the Home server when `AppConfig.usesServer`, otherwise Overpass directly.
public struct FootprintProvider: FootprintProviding {
    public let base: any FootprintProviding
    public var usesServer: Bool

    public init(config: AppConfig = .main, transport: any HTTPTransport = URLSessionTransport()) {
        if config.usesServer {
            base = ServerFootprintProvider(config: config, transport: transport); usesServer = true
        } else {
            base = OverpassFootprintProvider(transport: transport); usesServer = false
        }
    }

    public func footprint(near c: GeoCoordinate) async throws -> FootprintResult? { try await base.footprint(near: c) }
}
