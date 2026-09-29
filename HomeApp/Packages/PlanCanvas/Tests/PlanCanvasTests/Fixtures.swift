import Foundation
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import PlanCanvas

enum Fixture {
    static let today = LocalDate(2026, 9, 29)
    static let snapshot = SampleHome.snapshot(today: today)

    static func geometry(_ level: UUID) -> LevelGeometry {
        let s = snapshot
        return LevelGeometry(level: s.levels[level]!,
                             spaces: s.liveSpaces.filter { $0.levelId == level },
                             openings: s.liveOpenings.filter { $0.levelId == level })
    }

    static func stats(_ level: UUID) -> LensStats { InMemoryLensStatsService.compute(snapshot, level: level, today: today) }

    static func context(_ level: UUID) -> LensContext {
        LensContext(levelName: snapshot.levels[level]!.name,
                    property: PropertySummary(name: "Property", levelCount: 4, interiorAreaSqIn: 3_600 * 144, yearBuilt: 1978))
    }

    static func model(_ level: UUID, lens: LensID) -> LevelRenderModel {
        RenderModelBuilder.build(geometry: geometry(level), stats: stats(level), lens: lens, context: context(level))
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Polygon {
        Polygon(rect: Rect(x: x * 12, y: y * 12, width: w * 12, height: h * 12))
    }

    static let propertyId = UUID()
    static let levelId = UUID()
    static func level(exterior: Bool = false) -> Level {
        Level(id: levelId, propertyId: propertyId, name: exterior ? "Outside" : "Ground", kind: exterior ? .exterior : .floor, sortOrder: exterior ? 100 : 0)
    }
    static func space(_ name: String, _ poly: Polygon, id: UUID = UUID(), type: SpaceType = .room) -> Space {
        Space(id: id, propertyId: propertyId, levelId: levelId, name: name, spaceType: type, polygon: poly)
    }
}
