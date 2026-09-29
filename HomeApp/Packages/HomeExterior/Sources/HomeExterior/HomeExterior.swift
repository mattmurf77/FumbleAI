import Foundation
import PlanKit
import HomeCore
#if canImport(MapKit)
import MapKit
#endif

// HomeExterior — address → footprint → yard zones (LLD §6.11, HLD §4.5). Owner fills: AddressResolver
// (HomeCore.AddressResolving), OverpassClient + OverpassFootprintProvider and a server-backed provider
// (HomeCore.FootprintProviding — use AppConfig.serverURL /v1/footprint with X-Home-Key when set, else Overpass),
// SatelliteSnapshotter (HomeCore.SatelliteSnapshotting), YardSeeder (HomeCore.YardSeeding),
// ExteriorSeeder (HomeCore.ExteriorSeeding). Geometry via PlanKit.TangentPlane / Orientation / Clip.simplify.

public enum HomeExteriorModule {
    public static let name = "HomeExterior"
}
