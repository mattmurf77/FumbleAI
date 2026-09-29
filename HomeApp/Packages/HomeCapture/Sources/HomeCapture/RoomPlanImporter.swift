import Foundation
import PlanKit
import HomeCore
#if canImport(RoomPlan)
import RoomPlan
import simd
#endif

/// RoomPlan `CapturedStructure` → `PlanDraft` (LLD §6.12). Accepts either Apple's `CapturedStructure` JSON
/// (iOS 17+, bridged by `RPStructure(captured:)`) or the plain `RPStructure` JSON (tests, fixtures).
public struct RoomPlanImporter: RoomPlanImporting {
    public var converter: RoomPlanConverter
    public init(converter: RoomPlanConverter = RoomPlanConverter()) { self.converter = converter }

    public func draft(fromCapturedStructureJSON data: Data, storyMap: [Int: Level.Kind]) throws -> PlanDraft {
        try converter.convert(try Self.decode(data), storyMap: storyMap)
    }

    /// Plain-structure entry point.
    public func draft(from structure: RPStructure, storyMap: [Int: Level.Kind] = [:]) throws -> PlanDraft {
        try converter.convert(structure, storyMap: storyMap)
    }

    public static func decode(_ data: Data) throws -> RPStructure {
        if let plain = try? JSONDecoder().decode(RPStructure.self, from: data) { return plain }
        #if canImport(RoomPlan)
        if #available(iOS 17.0, macOS 14.0, *), let captured = try? JSONDecoder().decode(CapturedStructure.self, from: data) {
            return RPStructure(captured: captured)
        }
        #endif
        throw RoomPlanImportError.unreadable("Unrecognized scan data")
    }

    /// Story indices present in the data (for the review screen's story → floor mapping), ascending.
    public static func stories(in data: Data) -> [Int] {
        guard let s = try? decode(data) else { return [] }
        return Array(Set(s.rooms.map(\.story))).sorted()
    }
}

#if canImport(RoomPlan)
// MARK: - Apple RoomPlan bridge (iOS 17+). Not compiled on Linux.

@available(iOS 17.0, macOS 14.0, *)
extension RPStructure {
    public init(captured s: CapturedStructure) {
        var rooms = s.rooms.map(RPRoom.init(captured:))
        // Objects / surfaces captured at the structure level but not inside any room: attach to the first room of their story.
        if rooms.isEmpty, !s.walls.isEmpty {
            rooms = [RPRoom(story: 0, walls: s.walls.map(RPSurface.init(captured:)), doors: s.doors.map(RPSurface.init(captured:)),
                            windows: s.windows.map(RPSurface.init(captured:)), openings: s.openings.map(RPSurface.init(captured:)),
                            floors: s.floors.map(RPSurface.init(captured:)), objects: s.objects.map(RPObject.init(captured:)))]
        }
        self.init(rooms: rooms, sections: s.sections.map(RPSection.init(captured:)))
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension RPRoom {
    public init(captured r: CapturedRoom) {
        self.init(identifier: r.identifier, story: r.story,
                  walls: r.walls.map(RPSurface.init(captured:)), doors: r.doors.map(RPSurface.init(captured:)),
                  windows: r.windows.map(RPSurface.init(captured:)), openings: r.openings.map(RPSurface.init(captured:)),
                  floors: r.floors.map(RPSurface.init(captured:)), objects: r.objects.map(RPObject.init(captured:)),
                  sections: r.sections.map(RPSection.init(captured:)))
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension RPSurface {
    public init(captured s: CapturedRoom.Surface) {
        var open: Bool?
        if case .door(let isOpen) = s.category { open = isOpen }
        self.init(transform: RPTransform(simd: s.transform), dimensions: RPVec3(simd: s.dimensions),
                  polygonCorners: s.polygonCorners.map(RPVec3.init(simd:)), isOpen: open)
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension RPObject {
    public init(captured o: CapturedRoom.Object) {
        self.init(category: Self.name(o.category), transform: RPTransform(simd: o.transform), dimensions: RPVec3(simd: o.dimensions))
    }

    static func name(_ c: CapturedRoom.Object.Category) -> String {
        switch c {
        case .storage: return "storage"; case .refrigerator: return "refrigerator"; case .stove: return "stove"
        case .bed: return "bed"; case .sink: return "sink"; case .washerDryer: return "washerDryer"
        case .toilet: return "toilet"; case .bathtub: return "bathtub"; case .oven: return "oven"
        case .dishwasher: return "dishwasher"; case .table: return "table"; case .sofa: return "sofa"
        case .chair: return "chair"; case .fireplace: return "fireplace"; case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "unknown"
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension RPSection {
    public init(captured s: CapturedRoom.Section) {
        let label: String
        switch s.label {
        case .bedroom: label = "bedroom"; case .bathroom: label = "bathroom"; case .kitchen: label = "kitchen"
        case .livingRoom: label = "livingRoom"; case .diningRoom: label = "diningRoom"; case .unidentified: label = "unidentified"
        @unknown default: label = "unidentified"
        }
        self.init(label: label, center: RPVec3(simd: s.center), story: s.story)
    }
}

extension RPVec3 {
    init(simd v: simd_float3) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
}

extension RPTransform {
    init(simd t: simd_float4x4) {
        let c = [t.columns.0, t.columns.1, t.columns.2, t.columns.3]
        self.init(columnMajor: c.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] })
    }
}
#endif
