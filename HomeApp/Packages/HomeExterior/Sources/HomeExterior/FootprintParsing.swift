import Foundation
import PlanKit
import HomeCore

// HomeExterior — address → footprint → yard zones (LLD §6.11, HLD §4.5). Public entry points:
//   AddressResolver        (AddressResolving, MapKit)          — AddressResolver.swift
//   FootprintProvider      (FootprintProviding: server or Overpass by AppConfig) — FootprintProviders.swift
//   ServerFootprintProvider / OverpassFootprintProvider         — FootprintProviders.swift
//   SatelliteSnapshotter   (SatelliteSnapshotting, MapKit)      — SatelliteSnapshotter.swift
//   YardSeeder             (YardSeeding, pure)                  — YardSeeder.swift
//   ExteriorSeeder         (ExteriorSeeding)                    — ExteriorSeeder.swift
// Pure parsing / choice logic lives here and is tested on Linux with fixture JSON.

public enum HomeExteriorModule {
    public static let name = "HomeExterior"
}

/// A building candidate from Overpass or the server (ring in lat/lon, open).
public struct BuildingCandidate: Hashable, Sendable {
    public var osmId: Int64
    public var outline: [GeoCoordinate]
    public var buildingType: String?
    /// Filled by `FootprintChooser` relative to the query point.
    public var areaM2: Double = 0
    public var containsPoint = false
    public var centroidDistanceM = Double.infinity
    public init(osmId: Int64, outline: [GeoCoordinate], buildingType: String? = nil) {
        self.osmId = osmId; self.outline = outline; self.buildingType = buildingType
    }
}

public struct RoadCandidate: Hashable, Sendable {
    public var osmId: Int64
    public var name: String?
    public var highway: String?
    public var polyline: [GeoCoordinate]
    public init(osmId: Int64, name: String? = nil, highway: String? = nil, polyline: [GeoCoordinate]) {
        self.osmId = osmId; self.name = name; self.highway = highway; self.polyline = polyline
    }
}

/// Footprint choice (§6.11 / FR-EXT-04) and nearest-road point.
public enum FootprintChooser {
    public static let nearestWithinM = 25.0
    public static let maxPreferredAreaM2 = 1_500.0

    /// Annotates candidates (area, containment, centroid distance) in a tangent plane at `point`.
    public static func annotate(_ cs: [BuildingCandidate], near point: GeoCoordinate) -> [BuildingCandidate] {
        let plane = TangentPlane(origin: point)
        return cs.compactMap { c in
            guard c.outline.count >= 3 else { return nil }
            var c = c
            let ring = c.outline.map(plane.projectMeters)
            c.areaM2 = Area.area(ring)
            c.containsPoint = pointInRing(.zero, ring)
            c.centroidDistanceM = Area.centroid(ring).length
            return c
        }
    }

    /// 1. Buildings containing the point, else those whose centroid is within 25 m.
    /// 2. Among several, the largest under 1,500 m² (else the nearest).
    public static func choose(_ candidates: [BuildingCandidate], near point: GeoCoordinate) -> BuildingCandidate? {
        let cs = annotate(candidates, near: point)
        var pool = cs.filter(\.containsPoint)
        if pool.isEmpty { pool = cs.filter { $0.centroidDistanceM <= nearestWithinM } }
        guard !pool.isEmpty else { return nil }
        if let best = pool.filter({ $0.areaM2 < maxPreferredAreaM2 }).max(by: { ($0.areaM2, -$0.centroidDistanceM) < ($1.areaM2, -$1.centroidDistanceM) }) {
            return best
        }
        return pool.min { $0.centroidDistanceM < $1.centroidDistanceM }
    }

    /// Nearest point on any road polyline to `target` (the footprint centroid).
    public static func nearestRoadPoint(_ roads: [RoadCandidate], to target: GeoCoordinate) -> GeoCoordinate? {
        let plane = TangentPlane(origin: target)
        var best: (Vec2, Double)?
        for r in roads {
            let pts = r.polyline.map(plane.projectMeters)
            let segs: [Segment] = pts.count == 1 ? [Segment(pts[0], pts[0])] : zip(pts, pts.dropFirst()).map { Segment($0, $1) }
            for s in segs {
                let p = s.closestPoint(to: .zero)
                let d = p.length
                if d < (best?.1 ?? .infinity) { best = (p, d) }
            }
        }
        return best.map { plane.unproject($0.0 * TangentPlane.inchesPerMeter) }
    }

    /// Centroid of a lat/lon ring.
    public static func centroid(_ ring: [GeoCoordinate]) -> GeoCoordinate? {
        guard let first = ring.first else { return nil }
        let plane = TangentPlane(origin: first)
        let c = Area.centroid(ring.map(plane.project))
        return plane.unproject(c)
    }

    static func pointInRing(_ p: Vec2, _ ring: [Vec2]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Builds the contract result from a chosen building + roads.
    public static func result(building: BuildingCandidate, roads: [RoadCandidate], source: String) -> FootprintResult {
        let center = centroid(building.outline) ?? building.outline[0]
        return FootprintResult(outline: building.outline, nearestRoadPoint: nearestRoadPoint(roads, to: center), source: source)
    }
}

// MARK: - Overpass JSON

/// Parses an Overpass `out geom;` response (§6.11 query).
public enum OverpassParser {
    struct Response: Decodable {
        struct Element: Decodable {
            struct LatLon: Decodable { var lat: Double; var lon: Double }
            var type: String
            var id: Int64
            var tags: [String: String]?
            var geometry: [LatLon?]?
        }
        var elements: [Element]
    }

    public struct Parsed: Sendable {
        public var buildings: [BuildingCandidate]
        public var roads: [RoadCandidate]
    }

    public static let highwayPattern = #"^(residential|tertiary|secondary|primary|unclassified|living_street|service)$"#

    public static func parse(_ data: Data) throws -> Parsed {
        let r = try JSONDecoder().decode(Response.self, from: data)
        var buildings: [BuildingCandidate] = [], roads: [RoadCandidate] = []
        for e in r.elements where e.type == "way" {
            let pts = (e.geometry ?? []).compactMap { $0 }.map { GeoCoordinate(latitude: $0.lat, longitude: $0.lon) }
            guard !pts.isEmpty else { continue }
            let tags = e.tags ?? [:]
            if let b = tags["building"] {
                var ring = pts
                if ring.count > 1, ring.first == ring.last { ring.removeLast() }
                guard ring.count >= 3 else { continue }
                buildings.append(BuildingCandidate(osmId: e.id, outline: ring, buildingType: b))
            } else if let h = tags["highway"], h.range(of: highwayPattern, options: .regularExpression) != nil {
                roads.append(RoadCandidate(osmId: e.id, name: tags["name"] ?? tags["ref"], highway: h, polyline: pts))
            }
        }
        return Parsed(buildings: buildings, roads: roads)
    }

    /// Full pipeline: parse → choose → nearest road. nil when no building qualifies.
    public static func footprint(from data: Data, near point: GeoCoordinate) throws -> FootprintResult? {
        let p = try parse(data)
        guard let b = FootprintChooser.choose(p.buildings, near: point) else { return nil }
        return FootprintChooser.result(building: b, roads: p.roads, source: "overpass")
    }

    /// The §6.11 query text.
    public static func query(lat: Double, lon: Double) -> String {
        let la = String(format: "%.6f", lat), lo = String(format: "%.6f", lon)
        return """
        [out:json][timeout:15];
        (
          way(around:40,\(la),\(lo))["building"];
          way(around:60,\(la),\(lo))["highway"~"\(highwayPattern)"];
        );
        out geom;
        """
    }
}

// MARK: - Home server JSON

/// Parses `GET /v1/footprint` (server/README.md). The server already applied the footprint choice.
public enum ServerFootprintParser {
    struct Response: Decodable {
        struct Building: Decodable {
            var osmId: Int64?
            var polygon: [[Double]]
            var buildingType: String?
        }
        struct Road: Decodable {
            var osmId: Int64?
            var name: String?
            var highway: String?
            var polyline: [[Double]]
        }
        var building: Building?
        var roads: [Road]?
        var error: String?
    }

    /// Roads-only view of a response (also present on 404 `no_building`).
    public static func roads(from data: Data) -> [RoadCandidate] {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (r.roads ?? []).map { road in
            RoadCandidate(osmId: road.osmId ?? 0, name: road.name, highway: road.highway,
                          polyline: road.polyline.compactMap { $0.count >= 2 ? GeoCoordinate(latitude: $0[0], longitude: $0[1]) : nil })
        }
    }

    public static func footprint(from data: Data) throws -> FootprintResult? {
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let b = r.building else { return nil }
        var ring = b.polygon.compactMap { $0.count >= 2 ? GeoCoordinate(latitude: $0[0], longitude: $0[1]) : nil }
        if ring.count > 1, ring.first == ring.last { ring.removeLast() }
        guard ring.count >= 3 else { return nil }
        let building = BuildingCandidate(osmId: b.osmId ?? 0, outline: ring, buildingType: b.buildingType)
        return FootprintChooser.result(building: building, roads: roads(from: data), source: "server")
    }
}
