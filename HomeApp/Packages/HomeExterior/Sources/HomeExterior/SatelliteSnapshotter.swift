import Foundation
import PlanKit
import HomeCore
#if canImport(MapKit) && canImport(UIKit)
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers
#endif

public enum SnapshotError: Error, Hashable, Sendable {
    /// MapKit snapshotting unavailable on this platform.
    case unavailable
    case encodingFailed
}

/// Local-only satellite snapshot cache (ADR-12, FR-EXT-08): `Caches/Snapshots/<levelId>.heic` plus a
/// `<levelId>.json` sidecar holding the `SnapshotImage` metadata (pixel → model transform). Never synced;
/// entries older than 180 days (or with a missing image) are misses. Pure Foundation — tested on Linux.
public struct SnapshotCache: Sendable {
    public var directory: URL
    public var clock: any HomeClock

    public init(directory: URL = SnapshotCache.defaultDirectory, clock: any HomeClock = SystemClock()) {
        self.directory = directory; self.clock = clock
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Snapshots", isDirectory: true)
    }

    public func imageURL(levelId: UUID) -> URL { directory.appendingPathComponent(levelId.uuidString.lowercased() + ".heic") }
    public func metaURL(levelId: UUID) -> URL { directory.appendingPathComponent(levelId.uuidString.lowercased() + ".json") }

    /// A fresh cached snapshot, or nil.
    public func cached(levelId: UUID) -> SnapshotImage? {
        guard let data = try? Data(contentsOf: metaURL(levelId: levelId)),
              let meta = try? JSONDecoder().decode(SnapshotImage.self, from: data),
              FileManager.default.fileExists(atPath: imageURL(levelId: levelId).path) else { return nil }
        let age = clock.now.timeIntervalSince(meta.createdAt)
        guard age < Double(SnapshotImage.maxAgeDays) * 86_400 else { return nil }
        var m = meta
        m.fileURL = imageURL(levelId: levelId)   // container paths change between installs
        return m
    }

    /// Writes image bytes + metadata; returns the stored `SnapshotImage`.
    @discardableResult
    public func store(imageData: Data, levelId: UUID, pixelWidth: Int, pixelHeight: Int, pixelToModel: Transform2D) throws -> SnapshotImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = imageURL(levelId: levelId)
        try imageData.write(to: url, options: .atomic)
        let meta = SnapshotImage(fileURL: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight, pixelToModel: pixelToModel, createdAt: clock.now)
        try HomeJSON.encoder().encode(meta).write(to: metaURL(levelId: levelId), options: .atomic)
        return meta
    }

    public func remove(levelId: UUID) {
        try? FileManager.default.removeItem(at: imageURL(levelId: levelId))
        try? FileManager.default.removeItem(at: metaURL(levelId: levelId))
    }

    /// Pixel → model fit from matching corner points (≥ 3), e.g. `snapshot.point(for:)` × scale ↔ tangent-plane inches.
    public static func pixelToModel(pixels: [Vec2], coordinates: [GeoCoordinate], origin: GeoCoordinate) -> Transform2D? {
        let plane = TangentPlane(origin: origin)
        return Transform2D.fitAffine(from: pixels, to: coordinates.map(plane.project))
    }

    /// The four corners of a square region of `spanMeters` around `center`.
    public static func corners(center: GeoCoordinate, spanMeters: Double) -> [GeoCoordinate] {
        let plane = TangentPlane(origin: center)
        let h = spanMeters / 2 * TangentPlane.inchesPerMeter
        return [Vec2(-h, -h), Vec2(h, -h), Vec2(h, h), Vec2(-h, h)].map(plane.unproject)
    }
}

/// `MKMapSnapshotter` satellite image (§6.11): 90 × 90 m, 1024 pt at scale 2 (2048 px), HEIC in the cache.
/// The canvas draws it under the zones at 60 % opacity, desaturated 30 %, rotated by `georef.rotationRad`,
/// with the Apple Maps legal attribution and "© OpenStreetMap contributors" in the exterior footer.
public struct SatelliteSnapshotter: SatelliteSnapshotting {
    public static let defaultSpanMeters = 90.0
    public static let sizePoints = 1024.0
    public static let scale = 2.0

    public var cache: SnapshotCache
    public init(cache: SnapshotCache = SnapshotCache()) { self.cache = cache }

    public func snapshot(center: GeoCoordinate, spanMeters: Double, levelId: UUID) async throws -> SnapshotImage {
        if let hit = cache.cached(levelId: levelId) { return hit }
        #if canImport(MapKit) && canImport(UIKit)
        let options = MKMapSnapshotter.Options()
        options.preferredConfiguration = MKImageryMapConfiguration()
        let c = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        options.region = MKCoordinateRegion(center: c, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
        options.size = CGSize(width: Self.sizePoints, height: Self.sizePoints)
        options.traitCollection = UITraitCollection(displayScale: Self.scale)
        let snap = try await MKMapSnapshotter(options: options).start()
        guard let cg = snap.image.cgImage else { throw SnapshotError.encodingFailed }
        let corners = SnapshotCache.corners(center: center, spanMeters: spanMeters)
        let scale = Double(cg.width) / Double(snap.image.size.width)
        let pixels = corners.map { g -> Vec2 in
            let p = snap.point(for: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude))
            return Vec2(Double(p.x) * scale, Double(p.y) * scale)
        }
        guard let transform = SnapshotCache.pixelToModel(pixels: pixels, coordinates: corners, origin: center) else {
            throw SnapshotError.encodingFailed
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { throw SnapshotError.encodingFailed }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodingFailed }
        return try cache.store(imageData: data as Data, levelId: levelId, pixelWidth: cg.width, pixelHeight: cg.height, pixelToModel: transform)
        #else
        throw SnapshotError.unavailable
        #endif
    }
}
