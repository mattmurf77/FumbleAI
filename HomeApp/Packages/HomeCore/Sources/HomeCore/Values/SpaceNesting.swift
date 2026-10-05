import Foundation
import PlanKit

/// Closets that sit inside a room (founder feedback: "Closets should work like doors. Can be in rooms rather than
/// overlap"). A closet whose polygon lies inside one interior room is *nested*: it is its own space (items, "+",
/// label) drawn on top of the room, it is exempt from the level overlap rule against that room, and its area is not
/// counted a second time in floor totals (the room's polygon already covers it).
///
/// Nothing is stored: nesting is derived from geometry, so closets drawn the old way (beside the room) keep working
/// and a closet dragged out of its room simply stops being nested.
public enum SpaceNesting {
    /// Space types that may sit inside another room.
    public static func canNest(_ type: SpaceType) -> Bool { type == .closet }

    /// Space types that may hold a nested closet (any interior room except closets and stairs).
    public static func canHost(_ type: SpaceType) -> Bool {
        type != .closet && type != .stairs && type != .unknown && !type.isExteriorZone
    }

    /// One interior shape with its identity (lets PlanCanvas reuse the rule for its render model).
    public struct Shape: Hashable, Sendable {
        public var id: UUID
        public var spaceType: SpaceType
        public var isExterior: Bool
        public var polygon: Polygon
        public init(id: UUID, spaceType: SpaceType, isExterior: Bool = false, polygon: Polygon) {
            self.id = id; self.spaceType = spaceType; self.isExterior = isExterior; self.polygon = polygon
        }
        public init(_ s: Space) { self.init(id: s.id, spaceType: s.spaceType, isExterior: s.isExterior, polygon: s.polygon) }
    }

    /// True if `inner` is a closet lying inside the room `outer` (both interior).
    public static func isNested(_ inner: Shape, in outer: Shape) -> Bool {
        inner.id != outer.id && !inner.isExterior && !outer.isExterior
            && canNest(inner.spaceType) && canHost(outer.spaceType)
            && Clip.isContained(inner.polygon, in: outer.polygon)
    }

    /// Nested closet id → host room id, for the interior shapes of one level.
    public static func hosts(_ shapes: [Shape]) -> [UUID: UUID] {
        let interior = shapes.filter { !$0.isExterior }
        var out: [UUID: UUID] = [:]
        for c in interior where canNest(c.spaceType) {
            // Smallest containing room wins (rooms don't overlap, so there is at most one anyway).
            let host = interior.filter { isNested(c, in: $0) }.min { $0.polygon.area < $1.polygon.area }
            if let host { out[c.id] = host.id }
        }
        return out
    }

    public static func hosts(_ spaces: [Space]) -> [UUID: UUID] {
        hosts(spaces.filter { $0.deletedAt == nil }.map(Shape.init))
    }

    /// Interior pairs that break the level overlap rule (> 1 sq in), skipping a closet nested in its room.
    /// Two closets in the same room that overlap each other, or a closet poking out of its room, still count.
    public static func overlappingPairs(_ shapes: [Shape]) -> [(UUID, UUID)] {
        let interior = shapes.filter { !$0.isExterior }
        let nested = hosts(interior)
        var out: [(UUID, UUID)] = []
        for i in interior.indices {
            for j in interior.indices where j > i {
                let a = interior[i], b = interior[j]
                guard a.polygon.bounds.intersects(b.polygon.bounds) else { continue }
                if nested[a.id] == b.id || nested[b.id] == a.id { continue }
                if Clip.overlaps(a.polygon, b.polygon) { out.append((a.id, b.id)) }
            }
        }
        return out
    }

    public static func overlappingPairs(_ spaces: [Space]) -> [(UUID, UUID)] {
        overlappingPairs(spaces.filter { $0.deletedAt == nil }.map(Shape.init))
    }

    /// Interior floor area (sq in) with nested closets counted once (inside their room).
    public static func floorAreaSqIn(_ shapes: [Shape]) -> Double {
        let interior = shapes.filter { !$0.isExterior }
        let nested = hosts(interior)
        return interior.filter { nested[$0.id] == nil }.reduce(0) { $0 + $1.polygon.area }
    }

    public static func floorAreaSqIn(_ spaces: [Space]) -> Double {
        floorAreaSqIn(spaces.filter { $0.deletedAt == nil }.map(Shape.init))
    }
}
