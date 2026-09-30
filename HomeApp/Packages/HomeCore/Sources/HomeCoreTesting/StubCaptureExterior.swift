import Foundation
import HomeCore
import PlanKit

// Preview-quality stand-ins for HomeCapture / HomeExterior. The real implementations follow LLD §6.9–6.12.

/// Simple rough-in: one floor rectangle per floor, rooms by squarified treemap (no hall strip).
public struct StubRoughInGenerator: RoughInGenerating {
    public init() {}
    public func draft(_ input: RoughInInput) -> PlanDraft {
        let floors = min(max(input.floors, 1), 3)
        let perFloorSqIn = Double(input.approxSqFt) * 144 / Double(floors)
        var levels: [LevelDraft] = []
        for f in 0..<floors {
            let w = Geometry.snap((perFloorSqIn * 1.4).squareRoot(), to: 6), h = Geometry.snap(perFloorSqIn / w, to: 6)
            var names: [(String, SpaceType, Double)] = []
            if f == 0 { names += [("Living Room", .living, 1.0), ("Kitchen", .kitchen, 0.7), ("Dining Room", .dining, 0.55)] }
            if f == floors - 1 {
                names.append(("Primary Bedroom", .bedroom, 0.85))
                for b in 1..<max(input.bedrooms, 1) { names.append(("Bedroom \(b + 1)", .bedroom, 0.6)) }
                names.append(("Bathroom", .bathroom, 0.25))
            }
            let rects = Treemap.squarify(names.map(\.2), in: Rect(x: 0, y: 0, width: w, height: h), snap: 6)
            let spaces = zip(names, rects).compactMap { n, r -> SpaceDraft? in
                guard let p = try? Polygon(r.corners, minArea: Tolerance.minZoneArea) else { return nil }
                return SpaceDraft(name: n.0, spaceType: n.1, polygon: p, source: .rough, isApproximate: true)
            }
            levels.append(LevelDraft(name: f == 0 ? "1st Floor" : "\(f + 1)\(f == 1 ? "nd" : "rd") Floor", sortOrder: f, spaces: spaces))
        }
        return PlanDraft(levels: levels, source: .rough)
    }
}

public struct StubBlockTemplates: BlockTemplating {
    public init() {}
    public func draft(style: HouseStyle, beds: Int, baths: Double) -> PlanDraft {
        var d = StubRoughInGenerator().draft(RoughInInput(floors: style.isMultiLevel ? 2 : 1, hasBasement: false, approxSqFt: 1600,
                                                          bedrooms: beds, bathrooms: baths))
        d.source = .blocks
        for l in d.levels.indices { for s in d.levels[l].spaces.indices { d.levels[l].spaces[s].source = .blocks; d.levels[l].spaces[s].isApproximate = false } }
        return d
    }
}

public struct StubPhotoTraceCalibrator: PhotoTraceCalibrating {
    public init() {}
    public func calibrate(a: Vec2, b: Vec2, lengthIn: Double, second: (Vec2, Vec2, Double)?, imageSize: Vec2,
                          contentCenter: Vec2) -> Result<UnderlayTransform, TraceWarning> {
        switch UnderlayCalibration.calibrate(a: a, b: b, lengthIn: lengthIn, second: second, imageSize: imageSize, contentCenter: contentCenter) {
        case .success(let o): return .success(o.transform)
        case .failure(.possiblyStretched(let r)): return .failure(.possiblyStretched(ratio: r))
        case .failure: return .failure(.invalidInput)
        }
    }
}

public struct StubRoomPlanImporter: RoomPlanImporting {
    public init() {}
    public func draft(fromCapturedStructureJSON data: Data, storyMap: [Int: Level.Kind]) throws -> PlanDraft {
        var d = StubRoughInGenerator().draft(RoughInInput(floors: 1, hasBasement: false, approxSqFt: 1200, bedrooms: 2, bathrooms: 1))
        d.source = .roomplan
        return d
    }
}

public struct StubReceiptReader: ReceiptReading {
    public var guess: ReceiptGuess
    public init(guess: ReceiptGuess = ReceiptGuess(total: Money(cents: 4_612_00), date: nil, vendor: "Hardware Store", fullText: "TOTAL 4612.00")) { self.guess = guess }
    public func read(images: [Data]) async throws -> ReceiptGuess { guess }
}

public struct StubAddressResolver: AddressResolving {
    public init() {}
    public func suggestions(for query: String) async throws -> [AddressSuggestion] {
        query.isEmpty ? [] : [AddressSuggestion(title: query, subtitle: "Springfield, IL")]
    }
    public func resolve(_ query: String) async throws -> ResolvedAddress {
        ResolvedAddress(address: PostalAddressLite(line: query, locality: "Springfield", region: "IL", postalCode: "62701", countryCode: "US"),
                        coordinate: GeoCoordinate(latitude: 39.7817, longitude: -89.6501), displayName: query)
    }
}

/// Returns a 12 × 10 m rectangle around the coordinate and a road point 25 m south.
public struct StubFootprintProvider: FootprintProviding {
    public init() {}
    public func footprint(near c: GeoCoordinate) async throws -> FootprintResult? {
        let plane = TangentPlane(origin: c)
        let hw = 6 * TangentPlane.inchesPerMeter, hh = 5 * TangentPlane.inchesPerMeter
        let ring = [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map(plane.unproject)
        return FootprintResult(outline: ring, nearestRoadPoint: plane.unproject(Vec2(0, 25 * TangentPlane.inchesPerMeter)), source: "stub")
    }
}

public struct StubSatelliteSnapshotter: SatelliteSnapshotting {
    public struct Unavailable: Error {}
    public init() {}
    public func snapshot(center: GeoCoordinate, spanMeters: Double, levelId: UUID) async throws -> SnapshotImage { throw Unavailable() }
}

/// Axis-aligned yard zones around the footprint bbox (front = +y). The real seeder aligns to the footprint and road.
public struct StubYardSeeder: YardSeeding {
    public init() {}
    public func seed(footprint: Polygon?, frontDir: Vec2, roadDistanceIn: Double?) -> [SpaceDraft] {
        let ft = 12.0
        let fp = footprint ?? Polygon(rect: Rect(x: -20 * ft, y: -15 * ft, width: 40 * ft, height: 30 * ft))
        let b = fp.bounds, side = 10 * ft, front = 25 * ft, back = 30 * ft
        func zone(_ name: String, _ t: SpaceType, _ r: Rect, _ color: String) -> SpaceDraft? {
            guard let p = try? Polygon(r.corners, minArea: Tolerance.minZoneArea) else { return nil }
            return SpaceDraft(name: name, spaceType: t, isExterior: true, polygon: p, source: .autoseed, colorHex: color)
        }
        return [SpaceDraft(name: "House", spaceType: .footprint, isExterior: true, polygon: fp, source: .autoseed)] + [
            zone("Front Yard", .frontYard, Rect(minX: b.minX - side + 11 * ft, minY: b.maxY, maxX: b.maxX + side, maxY: b.maxY + front), "#CFE8C4"),
            zone("Driveway", .driveway, Rect(minX: b.minX - side, minY: b.maxY, maxX: b.minX - side + 11 * ft, maxY: b.maxY + front), "#D9D9D9"),
            zone("Sidewalk", .sidewalk, Rect(minX: b.minX - side, minY: b.maxY + front, maxX: b.maxX + side, maxY: b.maxY + front + 4 * ft), "#D9D9D9"),
            zone("Backyard", .backyard, Rect(minX: b.minX - side, minY: b.minY - back, maxX: b.maxX + side, maxY: b.minY), "#CFE8C4"),
            zone("Side Yard", .sideYard, Rect(minX: b.minX - side, minY: b.minY, maxX: b.minX, maxY: b.maxY), "#CFE8C4"),
            zone("Side Yard", .sideYard, Rect(minX: b.maxX, minY: b.minY, maxX: b.maxX + side, maxY: b.maxY), "#CFE8C4"),
        ].compactMap { $0 }
    }
}

public struct StubExteriorSeeder: ExteriorSeeding {
    public var footprints: FootprintProviding
    public var seeder: YardSeeding
    public init(footprints: FootprintProviding = StubFootprintProvider(), seeder: YardSeeding = StubYardSeeder()) {
        self.footprints = footprints; self.seeder = seeder
    }
    public func exteriorLevel(for address: ResolvedAddress) async -> LevelDraft {
        let plane = TangentPlane(origin: address.coordinate)
        var warnings: [DraftWarning] = []
        var polygon: Polygon?
        if let fp = try? await footprints.footprint(near: address.coordinate) {
            polygon = try? Polygon(fp.outline.map(plane.project), minArea: Tolerance.minZoneArea)
        }
        if polygon == nil { warnings.append(.footprintFallback) }
        return LevelDraft(name: "Outside", kind: .exterior, sortOrder: Level.exteriorSortOrder,
                          spaces: seeder.seed(footprint: polygon, frontDir: Vec2(0, 1), roadDistanceIn: nil),
                          georef: GeoReference(originLat: address.coordinate.latitude, originLon: address.coordinate.longitude),
                          warnings: warnings)
    }
}
