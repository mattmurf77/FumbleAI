import Foundation
import PlanKit

// Plain, platform-free mirror of the parts of RoomPlan's `CapturedStructure` the importer needs (LLD §6.12).
// On iOS `RoomPlanImporter` decodes Apple's `CapturedStructure` JSON and bridges it into these types
// (RoomPlanBridge.swift); on every platform it also accepts this format directly (test fixtures, Diagnostics
// exports made by `RPStructure.encodeJSON()`). RoomPlan units: meters, world-aligned, y up.

/// A 3D point / vector in meters. JSON: `[x, y, z]`.
public struct RPVec3: Hashable, Sendable, Codable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); z = try c.decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }

    public static func + (a: RPVec3, b: RPVec3) -> RPVec3 { RPVec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func * (a: RPVec3, s: Double) -> RPVec3 { RPVec3(a.x * s, a.y * s, a.z * s) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: RPVec3 { let l = length; return l > 0 ? self * (1 / l) : self }
}

/// A 4×4 rigid transform (simd_float4x4), columns 0–3. JSON: 16 numbers, column-major.
public struct RPTransform: Hashable, Sendable, Codable {
    /// Column-major: m[col * 4 + row].
    public var m: [Double]

    public init(columnMajor m: [Double]) { precondition(m.count == 16); self.m = m }

    /// Builds a transform from basis columns and a translation.
    public init(right: RPVec3, up: RPVec3, forward: RPVec3, position: RPVec3) {
        m = [right.x, right.y, right.z, 0, up.x, up.y, up.z, 0, forward.x, forward.y, forward.z, 0, position.x, position.y, position.z, 1]
    }

    public static let identity = RPTransform(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    /// A transform rotated about +y by `yaw` radians (right = (cos, 0, −sin)) at `position` — typical for walls/objects.
    public static func yaw(_ yaw: Double, at position: RPVec3) -> RPTransform {
        let right = RPVec3(cos(yaw), 0, -sin(yaw))
        let forward = RPVec3(sin(yaw), 0, cos(yaw))
        return RPTransform(right: right, up: RPVec3(0, 1, 0), forward: forward, position: position)
    }

    public var column0: RPVec3 { RPVec3(m[0], m[1], m[2]) }
    public var column1: RPVec3 { RPVec3(m[4], m[5], m[6]) }
    public var column2: RPVec3 { RPVec3(m[8], m[9], m[10]) }
    public var position: RPVec3 { RPVec3(m[12], m[13], m[14]) }

    public func apply(_ p: RPVec3) -> RPVec3 {
        RPVec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
               m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
               m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flat = try? c.decode([Double].self), flat.count == 16 { m = flat; return }
        // Also accept [[c0], [c1], [c2], [c3]].
        let cols = try c.decode([[Double]].self)
        guard cols.count == 4, cols.allSatisfy({ $0.count == 4 }) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "transform must be 16 numbers or 4 columns of 4")
        }
        m = cols.flatMap { $0 }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(m)
    }
}

/// Wall / door / window / opening / floor surface.
public struct RPSurface: Hashable, Sendable, Codable {
    public var transform: RPTransform
    /// x = width, y = height, z = depth (meters).
    public var dimensions: RPVec3
    /// Floor polygon corners in the surface's local frame (iOS 17). Empty when unknown.
    public var polygonCorners: [RPVec3]
    public var isOpen: Bool?

    public init(transform: RPTransform, dimensions: RPVec3, polygonCorners: [RPVec3] = [], isOpen: Bool? = nil) {
        self.transform = transform; self.dimensions = dimensions; self.polygonCorners = polygonCorners; self.isOpen = isOpen
    }

    enum CodingKeys: String, CodingKey { case transform, dimensions, polygonCorners, isOpen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transform = try c.decode(RPTransform.self, forKey: .transform)
        dimensions = try c.decode(RPVec3.self, forKey: .dimensions)
        polygonCorners = try c.decodeIfPresent([RPVec3].self, forKey: .polygonCorners) ?? []
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen)
    }
}

/// A detected object. `category` uses RoomPlan's case names: refrigerator, stove, oven, dishwasher, washerDryer,
/// television, sofa, bed, table, chair, storage, fireplace, sink, toilet, bathtub, stairs.
public struct RPObject: Hashable, Sendable, Codable {
    public var category: String
    public var transform: RPTransform
    public var dimensions: RPVec3
    public init(category: String, transform: RPTransform, dimensions: RPVec3) {
        self.category = category; self.transform = transform; self.dimensions = dimensions
    }
}

/// A room section (iOS 17): label ∈ bedroom, bathroom, kitchen, livingRoom, diningRoom, unidentified.
public struct RPSection: Hashable, Sendable, Codable {
    public var label: String
    public var center: RPVec3
    public var story: Int
    public init(label: String, center: RPVec3, story: Int = 0) { self.label = label; self.center = center; self.story = story }

    enum CodingKeys: String, CodingKey { case label, center, story }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        center = try c.decode(RPVec3.self, forKey: .center)
        story = try c.decodeIfPresent(Int.self, forKey: .story) ?? 0
    }
}

public struct RPRoom: Hashable, Sendable, Codable {
    public var identifier: UUID?
    public var story: Int
    public var walls: [RPSurface]
    public var doors: [RPSurface]
    public var windows: [RPSurface]
    public var openings: [RPSurface]
    public var floors: [RPSurface]
    public var objects: [RPObject]
    public var sections: [RPSection]

    public init(identifier: UUID? = nil, story: Int = 0, walls: [RPSurface] = [], doors: [RPSurface] = [], windows: [RPSurface] = [],
                openings: [RPSurface] = [], floors: [RPSurface] = [], objects: [RPObject] = [], sections: [RPSection] = []) {
        self.identifier = identifier; self.story = story; self.walls = walls; self.doors = doors; self.windows = windows
        self.openings = openings; self.floors = floors; self.objects = objects; self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case identifier, story, walls, doors, windows, openings, floors, objects, sections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decodeIfPresent(UUID.self, forKey: .identifier)
        story = try c.decodeIfPresent(Int.self, forKey: .story) ?? 0
        walls = try c.decodeIfPresent([RPSurface].self, forKey: .walls) ?? []
        doors = try c.decodeIfPresent([RPSurface].self, forKey: .doors) ?? []
        windows = try c.decodeIfPresent([RPSurface].self, forKey: .windows) ?? []
        openings = try c.decodeIfPresent([RPSurface].self, forKey: .openings) ?? []
        floors = try c.decodeIfPresent([RPSurface].self, forKey: .floors) ?? []
        objects = try c.decodeIfPresent([RPObject].self, forKey: .objects) ?? []
        sections = try c.decodeIfPresent([RPSection].self, forKey: .sections) ?? []
    }
}

/// The plain structure. `format` distinguishes it from Apple's JSON (`"home.rp.v1"`).
public struct RPStructure: Hashable, Sendable, Codable {
    public static let formatTag = "home.rp.v1"
    public var format: String
    public var rooms: [RPRoom]
    /// Structure-level sections (iOS 17 `CapturedStructure.sections`).
    public var sections: [RPSection]

    public init(rooms: [RPRoom], sections: [RPSection] = []) {
        self.format = Self.formatTag; self.rooms = rooms; self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case format, rooms, sections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        guard format == Self.formatTag else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "not a \(Self.formatTag) structure")
        }
        rooms = try c.decodeIfPresent([RPRoom].self, forKey: .rooms) ?? []
        sections = try c.decodeIfPresent([RPSection].self, forKey: .sections) ?? []
    }

    public func encodeJSON() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}
