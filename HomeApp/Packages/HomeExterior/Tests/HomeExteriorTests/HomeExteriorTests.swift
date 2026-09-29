import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import HomeExterior

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

let origin = GeoCoordinate(latitude: 40.0, longitude: -75.0)

/// Records requests and replies with a canned response.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var status: Int
    var body: Data
    var headers: [String: String]
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) { self.status = status; self.body = body; self.headers = headers }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

struct FailingProvider: FootprintProviding {
    func footprint(near: GeoCoordinate) async throws -> FootprintResult? { throw URLError(.notConnectedToInternet) }
}

final class HomeExteriorTests: XCTestCase {
    func testModuleLoads() { XCTAssertEqual(HomeExteriorModule.name, "HomeExterior") }

    func testProtocolConformances() {
        let _: any AddressResolving = AddressResolver()
        let _: any FootprintProviding = FootprintProvider(config: AppConfig())
        let _: any SatelliteSnapshotting = SatelliteSnapshotter()
        let _: any YardSeeding = YardSeeder()
        let _: any ExteriorSeeding = ExteriorSeeder()
    }
}

// MARK: - Overpass / server parsing

final class FootprintParsingTests: XCTestCase {
    func testOverpassPicksContainingHouseAndNearestRoad() throws {
        let parsed = try OverpassParser.parse(fixture("overpass_house"))
        XCTAssertEqual(parsed.buildings.count, 3)
        XCTAssertEqual(parsed.roads.map(\.osmId), [2001], "footway is not a road candidate")
        XCTAssertEqual(parsed.buildings[0].outline.count, 4, "closing vertex dropped")
        let r = try XCTUnwrap(OverpassParser.footprint(from: fixture("overpass_house"), near: origin))
        XCTAssertEqual(r.source, "overpass")
        XCTAssertEqual(r.outline.count, 4)
        let chosen = FootprintChooser.choose(parsed.buildings, near: origin)
        XCTAssertEqual(chosen?.osmId, 1001)
        XCTAssertEqual(chosen?.areaM2 ?? 0, 120, accuracy: 1)
        // Road runs east–west 20 m north of the origin; nearest point is due north of the house centroid.
        let road = try XCTUnwrap(r.nearestRoadPoint)
        let p = TangentPlane(origin: origin).projectMeters(road)
        XCTAssertEqual(p.y, -20, accuracy: 0.05)
        XCTAssertEqual(p.x, 1, accuracy: 0.2)
    }

    func testNearestCandidateWhenNoneContainsPoint() throws {
        let parsed = try OverpassParser.parse(fixture("overpass_nearest"))
        XCTAssertEqual(FootprintChooser.choose(parsed.buildings, near: origin)?.osmId, 3002)
        XCTAssertNil(try OverpassParser.footprint(from: fixture("overpass_empty"), near: origin))
    }

    func testPrefersLargestUnder1500() {
        let plane = TangentPlane(origin: origin)
        func sq(_ side: Double, id: Int64) -> BuildingCandidate {
            let h = side / 2 * TangentPlane.inchesPerMeter
            return BuildingCandidate(osmId: id, outline: [Vec2(-h, -h), Vec2(h, -h), Vec2(h, h), Vec2(-h, h)].map(plane.unproject))
        }
        // Both contain the point: 50 m × 50 m (2,500 m²) and 12 × 12 (144 m²) → the house, not the big one.
        XCTAssertEqual(FootprintChooser.choose([sq(50, id: 1), sq(12, id: 2)], near: origin)?.osmId, 2)
        XCTAssertEqual(FootprintChooser.choose([sq(50, id: 1)], near: origin)?.osmId, 1, "only oversized → still used")
    }

    func testQueryText() {
        let q = OverpassParser.query(lat: 40, lon: -75)
        XCTAssertTrue(q.contains("way(around:40,40.000000,-75.000000)[\"building\"]"))
        XCTAssertTrue(q.contains("way(around:60,40.000000,-75.000000)[\"highway\"~\"^(residential|tertiary|secondary|primary|unclassified|living_street|service)$\"]"))
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:15];"))
        XCTAssertTrue(q.hasSuffix("out geom;"))
    }

    func testServerParsing() throws {
        let r = try XCTUnwrap(ServerFootprintParser.footprint(from: fixture("server_footprint")))
        XCTAssertEqual(r.source, "server")
        XCTAssertEqual(r.outline.count, 4)
        XCTAssertNotNil(r.nearestRoadPoint)
        XCTAssertNil(try ServerFootprintParser.footprint(from: fixture("server_no_building")))
        XCTAssertEqual(ServerFootprintParser.roads(from: try fixture("server_no_building")).first?.name, "Elm St")
    }
}

// MARK: - Providers

final class FootprintProviderTests: XCTestCase {
    func testServerRequestAndKeyHeader() async throws {
        let t = MockTransport(body: try fixture("server_footprint"))
        let config = AppConfig(serverURL: URL(string: "https://home.example.com")!, apiKey: "sekret")
        let p = FootprintProvider(config: config, transport: t)
        XCTAssertTrue(p.usesServer)
        let r = try await p.footprint(near: origin)
        XCTAssertEqual(r?.source, "server")
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://home.example.com/v1/footprint?lat=40.000000&lon=-75.000000")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Home-Key"), "sekret")
    }

    func testServerNoKeyAndStatuses() async throws {
        let config = AppConfig(serverURL: URL(string: "https://home.example.com/")!, apiKey: "")
        let notFound = MockTransport(status: 404, body: try fixture("server_no_building"))
        let r = try await ServerFootprintProvider(config: config, transport: notFound).footprint(near: origin)
        XCTAssertNil(r)
        XCTAssertNil(notFound.requests.first?.value(forHTTPHeaderField: "X-Home-Key"))
        do {
            _ = try await ServerFootprintProvider(config: config, transport: MockTransport(status: 503, headers: ["Retry-After": "30"])).footprint(near: origin)
            XCTFail("expected rate limit")
        } catch { XCTAssertEqual(error as? FootprintError, .rateLimited(retryAfterSeconds: 30)) }
        do {
            _ = try await ServerFootprintProvider(config: config, transport: MockTransport(status: 401)).footprint(near: origin)
            XCTFail("expected unauthorized")
        } catch { XCTAssertEqual(error as? FootprintError, .unauthorized) }
    }

    func testOverpassRequest() async throws {
        let t = MockTransport(body: try fixture("overpass_house"))
        let p = FootprintProvider(config: AppConfig(), transport: t)
        XCTAssertFalse(p.usesServer)
        let r = try await p.footprint(near: origin)
        XCTAssertEqual(r?.source, "overpass")
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.url, AppConfig.overpassURL)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 15)
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Home/1.0") ?? false)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("data=%5Bout%3Ajson%5D"))
        XCTAssertEqual(body.removingPercentEncoding?.dropFirst(5).description, OverpassParser.query(lat: 40, lon: -75))
    }
}

// MARK: - Yard seeding

final class YardSeederTests: XCTestCase {
    let seeder = YardSeeder()

    func zone(_ zs: [SpaceDraft], _ name: String) -> SpaceDraft? { zs.first { $0.name == name } }

    /// AC-EXT-2: fallback 40 × 30 ft block with the six zones; front = screen bottom.
    func testFallbackZones() throws {
        let zs = seeder.seed(footprint: nil, frontDir: Vec2(0, 1), roadDistanceIn: nil)
        XCTAssertEqual(zs.map(\.name), ["House", "Front Yard", "Driveway", "Sidewalk", "Backyard", "Side Yard L", "Side Yard R"])
        XCTAssertTrue(zs.allSatisfy { $0.isExterior && $0.source == .autoseed })
        XCTAssertEqual(zs[0].spaceType, .footprint)
        XCTAssertEqual(zs[0].polygon.area / 144, 1200, accuracy: 0.1)
        let front = try XCTUnwrap(zone(zs, "Front Yard")).polygon.bounds
        XCTAssertEqual(front.minY, 15 * 12, accuracy: 0.01)
        XCTAssertEqual(front.height, 25 * 12, accuracy: 0.01)
        let drive = try XCTUnwrap(zone(zs, "Driveway")).polygon.bounds
        XCTAssertEqual(drive.width, 11 * 12, accuracy: 0.01)
        XCTAssertEqual(drive.minX, -30 * 12, accuracy: 0.01, "driveway on the left")
        XCTAssertEqual(try XCTUnwrap(zone(zs, "Backyard")).polygon.bounds.height, 30 * 12, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(zone(zs, "Sidewalk")).polygon.bounds.height, 4 * 12, accuracy: 0.01)
        // Zones don't overlap each other or the house (beyond rounding).
        for (i, a) in zs.enumerated() { for b in zs[(i + 1)...] {
            XCTAssertLessThan(Clip.intersectionArea(a.polygon, b.polygon), 1, "\(a.name) × \(b.name)")
        } }
    }

    func testFrontDepthClamp() {
        XCTAssertEqual(YardSeeder.frontDepth(roadDistanceIn: nil, houseDepth: 360), 300)
        XCTAssertEqual(YardSeeder.frontDepth(roadDistanceIn: 100, houseDepth: 360), 180)
        XCTAssertEqual(YardSeeder.frontDepth(roadDistanceIn: 10_000, houseDepth: 360), 720)
        XCTAssertEqual(YardSeeder.frontDepth(roadDistanceIn: 180 + 96 + 400, houseDepth: 360), 400)
    }

    /// Front yard faces the road (here: north / up) for a footprint rotated 20°.
    func testFrontFacesRoad() throws {
        let fp = try XCTUnwrap(OverpassParser.footprint(from: fixture("overpass_house"), near: origin))
        let proj = try XCTUnwrap(ProjectedFootprint(fp, origin: origin))
        XCTAssertEqual(proj.polygon.area / 144 / 10.7639, 120, accuracy: 2, "≈120 m²")
        XCTAssertLessThan(proj.frontDir.y, -0.9, "road is north (screen up)")
        XCTAssertEqual(proj.roadDistanceIn ?? 0, 20 * 39.3701, accuracy: 20)
        let zs = seeder.seed(footprint: proj.polygon, frontDir: proj.frontDir, roadDistanceIn: proj.roadDistanceIn)
        XCTAssertEqual(zs.count, 7)
        let house = proj.polygon.centroid
        let front = try XCTUnwrap(zone(zs, "Front Yard")).polygon.centroid
        let back = try XCTUnwrap(zone(zs, "Backyard")).polygon.centroid
        XCTAssertLessThan(front.y, house.y)
        XCTAssertGreaterThan(back.y, house.y)
        // Zones follow the house's 20° orientation.
        let angle = Geometry.degrees(Orientation.dominantAngle(of: try XCTUnwrap(zone(zs, "Backyard")).polygon))
        XCTAssertEqual(angle, 20, accuracy: 1.5)
        // Front depth = road distance (≈ 20 m) − half the 10 m house depth − 8 ft ≈ 494.5 in.
        let frontPoly = try XCTUnwrap(zone(zs, "Front Yard")).polygon
        let expected = (proj.roadDistanceIn ?? 0) - 10 * 39.3701 / 2 - 96
        XCTAssertEqual(frontPoly.rectangleSize.map { min($0.width, $0.height) } ?? 0, expected, accuracy: 2)
    }

    func testEastRoadRotatesFrame() throws {
        let zs = seeder.seed(footprint: nil, frontDir: Vec2(1, 0.1), roadDistanceIn: nil)
        let front = try XCTUnwrap(zone(zs, "Front Yard")).polygon.centroid
        XCTAssertGreaterThan(front.x, 20 * 12)
    }
}

// MARK: - Exterior seeder

final class ExteriorSeederTests: XCTestCase {
    let address = ResolvedAddress(address: PostalAddressLite(line: "14 Linden Ct"), coordinate: origin, displayName: "14 Linden Ct")

    func testSeedsFromOverpass() async throws {
        let provider = OverpassFootprintProvider(transport: MockTransport(body: try fixture("overpass_house")))
        let level = await ExteriorSeeder(footprints: provider).exteriorLevel(for: address)
        XCTAssertEqual(level.name, "Outside")
        XCTAssertEqual(level.kind, .exterior)
        XCTAssertEqual(level.sortOrder, Level.exteriorSortOrder)
        XCTAssertEqual(level.georef?.originLat, 40)
        XCTAssertTrue(level.warnings.isEmpty)
        XCTAssertEqual(level.spaces.count, 7)
        XCTAssertEqual(level.spaces.first?.polygon.count, 4)
    }

    func testFallbacks() async throws {
        let none = await ExteriorSeeder(footprints: OverpassFootprintProvider(transport: MockTransport(body: try fixture("overpass_empty"))))
            .exteriorLevel(for: address)
        XCTAssertEqual(none.warnings, [.footprintFallback])
        XCTAssertEqual(none.spaces.first?.polygon.area ?? 0, 1200 * 144, accuracy: 1)

        let offline = await ExteriorSeeder(footprints: FailingProvider()).exteriorLevel(for: address)
        XCTAssertEqual(offline.warnings, [.other(ExteriorSeeder.networkUnavailableTag), .footprintFallback])
        XCTAssertEqual(offline.spaces.count, 7)
        XCTAssertEqual(ExteriorSeeder.fallbackLevel(origin: nil).spaces.count, 7)
    }
}

// MARK: - Snapshot cache

final class SnapshotCacheTests: XCTestCase {
    func testStoreHitAndExpiry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let level = UUID()
        let cache = SnapshotCache(directory: dir, clock: FixedClock(now: t0))
        XCTAssertNil(cache.cached(levelId: level))
        let corners = SnapshotCache.corners(center: origin, spanMeters: 90)
        let px = [Vec2(0, 0), Vec2(2048, 0), Vec2(2048, 2048), Vec2(0, 2048)]
        let fit = try XCTUnwrap(SnapshotCache.pixelToModel(pixels: px, coordinates: corners, origin: origin))
        XCTAssertEqual(fit.apply(Vec2(1024, 1024)).length, 0, accuracy: 0.5, "center pixel → origin")
        XCTAssertEqual(fit.apply(Vec2(2048, 1024)).x, 45 * 39.3701, accuracy: 0.5)
        try cache.store(imageData: Data([1, 2, 3]), levelId: level, pixelWidth: 2048, pixelHeight: 2048, pixelToModel: fit)
        XCTAssertEqual(cache.cached(levelId: level)?.pixelWidth, 2048)
        let later = SnapshotCache(directory: dir, clock: FixedClock(now: t0.addingTimeInterval(181 * 86_400)))
        XCTAssertNil(later.cached(levelId: level), "older than 180 days")
        cache.remove(levelId: level)
        XCTAssertNil(cache.cached(levelId: level))
    }

    func testSnapshotterUnavailableOnLinux() async {
        #if !canImport(MapKit)
        do { _ = try await SatelliteSnapshotter(cache: SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
                .snapshot(center: origin, spanMeters: 90, levelId: UUID()); XCTFail() }
        catch { XCTAssertEqual(error as? SnapshotError, .unavailable) }
        do { _ = try await AddressResolver().resolve("14 Linden Ct"); XCTFail() }
        catch { XCTAssertEqual(error as? AddressError, .unavailable) }
        #endif
    }
}
