import Foundation
import PlanKit
import HomeCore

/// Orchestrates coordinate → footprint → projection → yard zones into the "Outside" `LevelDraft` (HLD §4.5).
///
/// Warnings on the returned level:
/// - `.footprintFallback` when no footprint was found or it could not be used (40 × 30 ft block at the pin;
///   UI: "We couldn't find your house outline. Drag the block to match the photo.").
/// - additionally `.other(ExteriorSeeder.networkUnavailableTag)` when the lookup failed (offline, timeout,
///   rate-limited): per FR-EXT-15 the caller should *not* commit and should retry on the next launch.
///
/// The satellite snapshot is not part of the draft (it is local-only and keyed by the committed level id): call
/// `SatelliteSnapshotting.snapshot(center:spanMeters:levelId:)` after commit.
public struct ExteriorSeeder: ExteriorSeeding {
    public static let networkUnavailableTag = ExteriorPlanning.footprintUnavailableTag
    public static let levelName = ExteriorPlanning.levelName

    public var footprints: any FootprintProviding
    public var seeder: any YardSeeding

    public init(footprints: any FootprintProviding = FootprintProvider(), seeder: any YardSeeding = YardSeeder()) {
        self.footprints = footprints; self.seeder = seeder
    }

    public func exteriorLevel(for address: ResolvedAddress) async -> LevelDraft {
        var warnings: [DraftWarning] = []
        var projected: ProjectedFootprint?
        do {
            if let fp = try await footprints.footprint(near: address.coordinate) {
                projected = ProjectedFootprint(fp, origin: address.coordinate)
            }
        } catch {
            warnings.append(.other(Self.networkUnavailableTag))
        }
        if projected == nil { warnings.append(.footprintFallback) }
        let spaces = seeder.seed(footprint: projected?.polygon, frontDir: projected?.frontDir ?? Vec2(0, 1),
                                 roadDistanceIn: projected?.roadDistanceIn)
        return LevelDraft(name: Self.levelName, kind: .exterior, sortOrder: Level.exteriorSortOrder, spaces: spaces,
                          georef: GeoReference(originLat: address.coordinate.latitude, originLon: address.coordinate.longitude),
                          warnings: warnings)
    }

    /// Manual set-up with no lookup ("Geocode fails" state, no address, lookup failed): Outside level with the
    /// default zones around `houseOutline` (the ground floor's outline, re-centered on the pin) or, without one, the
    /// 40 × 30 ft block. See `ExteriorSeeding.exteriorLevelOrFallback` (HomeCore) for the full "always a yard" path.
    public static func fallbackLevel(origin: GeoCoordinate?, houseOutline: Polygon? = nil,
                                     seeder: any YardSeeding = YardSeeder()) -> LevelDraft {
        ExteriorPlanning.fallbackLevel(houseOutline: houseOutline, origin: origin, seeder: seeder)
    }
}
