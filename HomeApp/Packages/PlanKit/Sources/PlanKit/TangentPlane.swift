import Foundation

/// A latitude/longitude pair in degrees (WGS84). Pure replacement for `CLLocationCoordinate2D`.
public struct GeoCoordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Exterior level geo-reference (stored in `level.georef_json`). LLD §6.11.
public struct GeoReference: Hashable, Codable, Sendable {
    public var originLat: Double
    public var originLon: Double
    /// User "rotate plan" (0 = north up), radians.
    public var rotationRad: Double
    public init(originLat: Double, originLon: Double, rotationRad: Double = 0) {
        self.originLat = originLat; self.originLon = originLon; self.rotationRad = rotationRad
    }
    public var origin: GeoCoordinate { GeoCoordinate(latitude: originLat, longitude: originLon) }
    public var plane: TangentPlane { TangentPlane(origin: origin) }
}

/// Local tangent plane (equirectangular approximation, extents < 500 m). LLD §6.11.
/// +x = east, +y = south (y down), inches.
public struct TangentPlane: Hashable, Sendable {
    public static let metersPerDegreeLon: Double = 111_320
    public static let metersPerDegreeLat: Double = 110_574
    public static let inchesPerMeter: Double = 39.3701

    public var origin: GeoCoordinate
    public init(origin: GeoCoordinate) { self.origin = origin }

    private var cosLat: Double { cos(origin.latitude * .pi / 180) }

    /// Meters east/south of the origin.
    public func projectMeters(_ c: GeoCoordinate) -> Vec2 {
        Vec2(x: (c.longitude - origin.longitude) * cosLat * Self.metersPerDegreeLon,
             y: -(c.latitude - origin.latitude) * Self.metersPerDegreeLat)
    }

    /// Level coordinates in inches.
    public func project(_ c: GeoCoordinate) -> Vec2 { projectMeters(c) * Self.inchesPerMeter }

    public func unproject(_ p: Vec2) -> GeoCoordinate {
        let m = p / Self.inchesPerMeter
        let lat = origin.latitude - m.y / Self.metersPerDegreeLat
        let c = cosLat
        let lon = origin.longitude + (c.magnitude > 1e-12 ? m.x / (c * Self.metersPerDegreeLon) : 0)
        return GeoCoordinate(latitude: lat, longitude: lon)
    }

    /// Great-circle-free distance in meters between two coordinates (valid for small extents).
    public func distanceMeters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        projectMeters(a).distance(to: projectMeters(b))
    }
}
