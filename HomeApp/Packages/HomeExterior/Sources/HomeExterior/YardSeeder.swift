import Foundation
import PlanKit
import HomeCore

/// Default yard zones around a footprint (LLD §6.11, FR-EXT-06/07). Pure.
///
/// The footprint's dominant orientation α gives a frame F in which the house is axis-aligned; F is then turned by a
/// multiple of 90° so the side closest to `frontDir` (toward the nearest road) faces +y (screen-down). Zones are
/// rectangles in F mapped back to level inches: House (the footprint itself), Front Yard (minus the driveway),
/// Driveway (11 ft, left from the street), Sidewalk (4 ft), Backyard (30 ft), Side Yard L / R (10 ft).
public struct YardSeeder: YardSeeding {
    public static let ft = 12.0
    public static let side = 10 * ft, back = 30 * ft, sidewalk = 4 * ft, drivewayWidth = 11 * ft
    public static let defaultFront = 25 * ft, minFront = 15 * ft, maxFront = 60 * ft, roadSetback = 8 * ft
    public static let lawnHex = "#CFE8C4", hardscapeHex = "#D9D9D9", houseHex = "#E9E4DA"
    /// 40 × 30 ft fallback block centered at the origin (the geocoded pin).
    public static let fallbackFootprint = Polygon(rect: Rect(x: -20 * ft, y: -15 * ft, width: 40 * ft, height: 30 * ft))

    public init() {}

    /// Level → F transform for a footprint and front direction.
    public static func frame(footprint: Polygon, frontDir: Vec2) -> Transform2D {
        var alpha = Orientation.dominantAngle(of: footprint)
        if alpha > .pi / 4 { alpha -= .pi / 2 }
        let c = footprint.centroid
        let align = Transform2D.translation(-c).then(.rotation(-alpha))
        let f = align.applyToVector(frontDir.normalized == .zero ? Vec2(0, 1) : frontDir.normalized)
        // Axis direction closest to the front; rotate it onto +y.
        let beta: Double
        if abs(f.y) >= abs(f.x) { beta = f.y >= 0 ? 0 : .pi } else { beta = f.x >= 0 ? .pi / 2 : -.pi / 2 }
        return align.then(.rotation(beta))
    }

    /// Front yard depth: `clamp(dist(centroid, road) − depth/2 − 8 ft, 15 ft, 60 ft)`, or 25 ft without a road.
    public static func frontDepth(roadDistanceIn: Double?, houseDepth: Double) -> Double {
        guard let d = roadDistanceIn else { return defaultFront }
        return min(max(d - houseDepth / 2 - roadSetback, minFront), maxFront)
    }

    public func seed(footprint: Polygon?, frontDir: Vec2, roadDistanceIn: Double?) -> [SpaceDraft] {
        let fp = footprint ?? Self.fallbackFootprint
        let toF = Self.frame(footprint: fp, frontDir: frontDir)
        let fromF = toF.inverse ?? .identity
        let b = Rect(points: fp.vertices.map(toF.apply))
        let x0 = b.minX, x1 = b.maxX, y0 = b.minY, y1 = b.maxY
        let front = Self.frontDepth(roadDistanceIn: roadDistanceIn, houseDepth: y1 - y0)
        let s = Self.side

        func zone(_ name: String, _ type: SpaceType, _ r: Rect, _ color: String) -> SpaceDraft? {
            let pts = r.corners.map { fromF.apply($0).rounded(to: 0.01) }
            guard let p = try? Polygon(pts, minArea: Tolerance.minZoneArea) else { return nil }
            return SpaceDraft(name: name, spaceType: type, isExterior: true, polygon: p, source: .autoseed, colorHex: color)
        }
        let house = (try? Polygon(fp.vertices, minArea: Tolerance.minZoneArea)) ?? fp
        return [SpaceDraft(name: "House", spaceType: .footprint, isExterior: true, polygon: house, source: .autoseed, colorHex: Self.houseHex)] + [
            zone("Front Yard", .frontYard, Rect(minX: x0 - s + Self.drivewayWidth, minY: y1, maxX: x1 + s, maxY: y1 + front), Self.lawnHex),
            zone("Driveway", .driveway, Rect(minX: x0 - s, minY: y1, maxX: x0 - s + Self.drivewayWidth, maxY: y1 + front), Self.hardscapeHex),
            zone("Sidewalk", .sidewalk, Rect(minX: x0 - s, minY: y1 + front, maxX: x1 + s, maxY: y1 + front + Self.sidewalk), Self.hardscapeHex),
            zone("Backyard", .backyard, Rect(minX: x0 - s, minY: y0 - Self.back, maxX: x1 + s, maxY: y0), Self.lawnHex),
            zone("Side Yard L", .sideYard, Rect(minX: x0 - s, minY: y0, maxX: x0, maxY: y1), Self.lawnHex),
            zone("Side Yard R", .sideYard, Rect(minX: x1, minY: y0, maxX: x1 + s, maxY: y1), Self.lawnHex),
        ].compactMap { $0 }
    }
}

/// Projection of a `FootprintResult` into level inches (§6.11): tangent plane at the geocoded point, `Validation`
/// normalize, Douglas–Peucker at 6 in; front direction and distance from the footprint centroid to the road.
public struct ProjectedFootprint: Hashable, Sendable {
    public var polygon: Polygon
    public var frontDir: Vec2
    public var roadDistanceIn: Double?

    public static let simplifyIn = 6.0

    public init?(_ r: FootprintResult, origin: GeoCoordinate) {
        let plane = TangentPlane(origin: origin)
        let raw = r.outline.map(plane.project)
        guard let normalized = try? Polygon(raw, minArea: Tolerance.minZoneArea) else { return nil }
        let simplified = Clip.simplify(normalized.vertices, tolerance: Self.simplifyIn)
        polygon = (try? Polygon(simplified, minArea: Tolerance.minZoneArea)) ?? normalized
        let c = polygon.centroid
        if let road = r.nearestRoadPoint {
            let p = plane.project(road)
            let d = p - c
            frontDir = d.length > 1 ? d.normalized : Vec2(0, 1)
            roadDistanceIn = d.length > 1 ? d.length : nil
        } else {
            frontDir = Vec2(0, 1); roadDistanceIn = nil
        }
    }
}
