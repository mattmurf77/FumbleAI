import Foundation
import PlanKit
import HomeCore

/// Creates the property's "Outside" level (spec 03) so every home ends up with a yard, even when the address is
/// missing, the geocode / footprint lookup fails, the Home server is cold or offline, or the satellite image is
/// unavailable (founder bug "Exterior/yard is missing"). Used after onboarding, by Add floor › Outside and by the
/// Plan screen's "Add yard" pill.
///
/// Order: footprint lookup when an address is known → otherwise (or on any failure) the ground floor's outline
/// re-centered on the pin → otherwise the 40 × 30 ft block; always with Front Yard, Backyard, Side Yard L/R,
/// Driveway and Sidewalk (`ExteriorSeeding.exteriorLevelOrFallback`). One exterior level per property (FR-EXT-14).
enum ExteriorSetup {
    /// The services the seeding needs, captured so the work can run off the main actor.
    struct Services: Sendable {
        var plan: any PlanRepository
        var committer: any PlanCommitting
        var seeder: any ExteriorSeeding
        var yard: any YardSeeding
        var snapshots: any SatelliteSnapshotting

        @MainActor
        init(_ env: AppEnvironment) {
            plan = env.plan; committer = env.planCommitter; seeder = env.exteriorSeeder
            yard = env.yardSeeder; snapshots = env.snapshots
        }
    }

    /// Adds the Outside level unless one exists; returns its id (the existing one, or the new one). nil only when
    /// the commit itself failed.
    static func ensureOutside(_ s: Services, propertyId: UUID, address: ResolvedAddress?,
                              groundOutline: PlanKit.Polygon?) async -> UUID? {
        let levels = ((try? await s.plan.levels(property: propertyId)) ?? []).filter { $0.deletedAt == nil }
        if let existing = levels.first(where: { $0.isExterior }) { return existing.id }
        var outline = groundOutline
        if outline == nil { outline = await Self.groundOutline(s, levels: levels) }
        let level = await s.seeder.exteriorLevelOrFallback(for: address, groundOutline: outline, yard: s.yard)
        guard let ids = try? await s.committer.commit(PlanDraft(levels: [level], source: .autoseed), into: propertyId,
                                                      acceptedSuggestions: []),
              let levelId = ids.first else { return nil }
        // Local-only satellite image under the zones (best effort; never blocks the yard).
        if let address {
            let snapshots = s.snapshots
            Task.detached(priority: .utility) {
                _ = try? await snapshots.snapshot(center: address.coordinate, spanMeters: 90, levelId: levelId)
            }
        }
        return levelId
    }

    /// Fire-and-forget version for after onboarding's commit (FR-PLN-05: never blocks the canvas).
    static func start(_ s: Services, propertyId: UUID, address: ResolvedAddress?, groundOutline: PlanKit.Polygon?) {
        Task.detached(priority: .utility) {
            _ = await ensureOutside(s, propertyId: propertyId, address: address, groundOutline: groundOutline)
        }
    }

    /// Outline of the property's ground floor (sort order 0, else the lowest floor), from the store.
    static func groundOutline(_ s: Services, levels: [Level]) async -> PlanKit.Polygon? {
        let interior = levels.filter { !$0.isExterior }
        guard let ground = interior.first(where: { $0.sortOrder == 0 })
                ?? interior.filter({ $0.kind == .floor }).min(by: { $0.sortOrder < $1.sortOrder })
                ?? interior.first,
              let g = try? await s.plan.geometry(level: ground.id) else { return nil }
        return FloorMatching.outline(of: g.spaces)
    }

    /// The saved address as a lookup input (nil without a coordinate).
    static func address(of p: Property) -> ResolvedAddress? {
        guard let c = p.coordinate else { return nil }
        let a = p.address ?? PostalAddressLite(line: p.name)
        let display = a.singleLine.isEmpty ? p.name : a.singleLine
        return ResolvedAddress(address: a, coordinate: c, displayName: display)
    }
}
