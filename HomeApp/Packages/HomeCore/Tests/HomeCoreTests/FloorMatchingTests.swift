import XCTest
import PlanKit
@testable import HomeCore
import HomeCoreTesting

final class FloorMatchingTests: XCTestCase {
    func shape(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ t: SpaceType = .room) -> FloorShape {
        FloorShape(polygon: Polygon(rect: Rect(x: x, y: y, width: w, height: h)), spaceType: t)
    }

    /// Ground floor: an L (main block + garage wing) with a stairwell in the hall strip.
    var ground: [FloorShape] {
        [shape(0, 0, 200, 150, .living), shape(200, 0, 160, 150, .kitchen),
         shape(0, 150, 240, 42, .hall), shape(240, 150, 120, 42, .stairs),
         shape(0, 192, 360, 150, .bedroom), shape(360, 0, 264, 264, .garage)]
    }

    func assertNoOverlaps(_ spaces: [SpaceDraft], file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in spaces.enumerated() {
            for b in spaces[(i + 1)...] {
                XCTAssertLessThanOrEqual(Clip.intersectionArea(a.polygon, b.polygon), Tolerance.maxInteriorOverlap,
                                         "\(a.name) overlaps \(b.name)", file: file, line: line)
            }
        }
    }

    func testMatchingOutlineEqualsFloorBelow() throws {
        let below = try XCTUnwrap(FloorMatching.outline(of: ground))
        // True outline, not the hull: the notch under the garage wing is outside.
        XCTAssertFalse(below.contains(Vec2(500, 320)))
        XCTAssertEqual(below.area, 360 * 342 + 264 * 264, accuracy: 1)

        let level = FloorMatching.matchingLevel(reference: ground, name: "2nd Floor", kind: .floor, sortOrder: 1,
                                                outline: true, stairs: true)
        assertNoOverlaps(level.spaces)
        // Stairs at the same position.
        let stairs = level.spaces.filter { $0.spaceType == .stairs }
        XCTAssertEqual(stairs.count, 1)
        XCTAssertEqual(stairs.first?.polygon.bounds, Rect(x: 240, y: 150, width: 120, height: 42))
        // Everything else is unassigned space for the user to split.
        let rest = level.spaces.filter { $0.spaceType != .stairs }
        XCTAssertFalse(rest.isEmpty)
        XCTAssertTrue(rest.allSatisfy { $0.name.hasPrefix(FloorMatching.unassignedName) && $0.spaceType == .room })
        XCTAssertEqual(rest.first?.name, "Unassigned space")
        // The new level's outline equals the floor below within tolerance.
        let above = try XCTUnwrap(FloorMatching.outline(of: level))
        XCTAssertEqual(above.area, below.area, accuracy: 1)
        XCTAssertLessThanOrEqual(abs(Clip.intersectionArea(above, below) - below.area), 1)
        XCTAssertEqual(above.bounds, below.bounds)
    }

    func testOutlineWithoutStairsIsOneRoom() throws {
        let level = FloorMatching.matchingLevel(reference: ground, name: "Attic", kind: .attic, sortOrder: 2,
                                                outline: true, stairs: false)
        XCTAssertEqual(level.spaces.count, 1)
        XCTAssertEqual(level.spaces[0].name, "Unassigned space")
        XCTAssertEqual(level.spaces[0].polygon.area, try XCTUnwrap(FloorMatching.outline(of: ground)).area, accuracy: 1)
    }

    func testStairsOnlyAndMissingStairs() {
        let spaces = FloorMatching.matchingSpaces(reference: ground, outline: false, stairs: true)
        XCTAssertEqual(spaces.map(\.name), ["Stairs"])
        XCTAssertEqual(FloorMatching.missingStairs(reference: ground, target: []).count, 1)
        XCTAssertEqual(FloorMatching.missingStairs(reference: ground, target: spaces.map(FloorShape.init)).count, 0)
        XCTAssertTrue(FloorMatching.matchingSpaces(reference: [], outline: true, stairs: true).isEmpty)
    }

    func testCenteredStairwellLeavesTwoPieces() throws {
        // 3 × 3 grid with the stairs in the middle cell: the remainder can't be one room (it would have a hole).
        var rooms: [FloorShape] = []
        for r in 0..<3 { for c in 0..<3 { rooms.append(shape(Double(c) * 120, Double(r) * 120, 120, 120, r == 1 && c == 1 ? .stairs : .room)) } }
        let spaces = FloorMatching.matchingSpaces(reference: rooms, outline: true, stairs: true)
        assertNoOverlaps(spaces)
        XCTAssertEqual(spaces.reduce(0) { $0 + $1.polygon.area }, 360 * 360, accuracy: 1)
        XCTAssertGreaterThanOrEqual(spaces.filter { $0.spaceType == .room }.count, 2)
    }

    // MARK: HouseStyle

    func testHouseStyleForwardCompatible() throws {
        XCTAssertEqual(HouseStyle(storedValue: "biLevel"), .biLevel)
        XCTAssertEqual(HouseStyle(storedValue: "geodesicDome"), .unknown)
        let decoded = try JSONDecoder().decode([HouseStyle].self, from: Data(#"["ranch","biLevel","yurt"]"#.utf8))
        XCTAssertEqual(decoded, [.ranch, .biLevel, .unknown])
        XCTAssertFalse(HouseStyle.knownCases.contains(.unknown))
        XCTAssertEqual(Set(HouseStyle.pickerOrder), Set(HouseStyle.knownCases))
        XCTAssertEqual(HouseStyle.biLevel.displayName, "Bi-level")
        XCTAssertEqual(HouseStyle.twoStory.displayName, "Colonial 2-story")
        // RoughInInput stays decodable without the new field.
        let old = #"{"floors":2,"hasBasement":false,"approxSqFt":1800,"bedrooms":3,"bathrooms":2,"includeGarage":false}"#
        XCTAssertNil(try JSONDecoder().decode(RoughInInput.self, from: Data(old.utf8)).style)
    }

    // MARK: Exterior fallback

    struct FailingSeeder: ExteriorSeeding {
        func exteriorLevel(for address: ResolvedAddress) async -> LevelDraft {
            LevelDraft(name: "Outside", kind: .exterior, sortOrder: Level.exteriorSortOrder,
                       georef: GeoReference(originLat: address.coordinate.latitude, originLon: address.coordinate.longitude),
                       warnings: [.other(ExteriorPlanning.footprintUnavailableTag), .footprintFallback])
        }
    }

    let address = ResolvedAddress(address: PostalAddressLite(line: "1 Main St"), coordinate: GeoCoordinate(latitude: 40, longitude: -75),
                                  displayName: "1 Main St")

    func assertYard(_ level: LevelDraft, houseArea: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(level.kind, .exterior, file: file, line: line)
        XCTAssertEqual(level.name, "Outside", file: file, line: line)
        let house = level.spaces.first { $0.spaceType == .footprint }
        XCTAssertEqual(house?.polygon.area ?? 0, houseArea, accuracy: 1, file: file, line: line)
        XCTAssertEqual(house?.polygon.bounds.center.x ?? 99, 0, accuracy: 0.01, file: file, line: line)
        for t: SpaceType in [.frontYard, .backyard, .sideYard, .driveway, .sidewalk] {
            XCTAssertTrue(level.spaces.contains { $0.spaceType == t }, "missing \(t)", file: file, line: line)
        }
        XCTAssertTrue(level.warnings.contains(.footprintFallback), file: file, line: line)
        XCTAssertFalse(level.warnings.contains(.other(ExteriorPlanning.footprintUnavailableTag)), file: file, line: line)
    }

    func testExteriorFallbackWhenLookupFails() async throws {
        let outline = try XCTUnwrap(FloorMatching.outline(of: ground))
        let level = await FailingSeeder().exteriorLevelOrFallback(for: address, groundOutline: outline, yard: StubYardSeeder())
        assertYard(level, houseArea: outline.area)
        XCTAssertEqual(level.georef?.originLat, 40)
    }

    func testExteriorFallbackWithoutAddress() async throws {
        let outline = try XCTUnwrap(FloorMatching.outline(of: ground))
        let level = await FailingSeeder().exteriorLevelOrFallback(for: nil, groundOutline: outline, yard: StubYardSeeder())
        assertYard(level, houseArea: outline.area)
        XCTAssertNil(level.georef)
        // No floor either: the 40 × 30 ft block.
        let blank = await FailingSeeder().exteriorLevelOrFallback(for: nil, groundOutline: nil, yard: StubYardSeeder())
        assertYard(blank, houseArea: 40 * 30 * 144)
    }

    func testExteriorUsesFootprintWhenFound() async {
        let level = await StubExteriorSeeder().exteriorLevelOrFallback(for: address, groundOutline: nil, yard: StubYardSeeder())
        XCTAssertFalse(level.warnings.contains(.footprintFallback))
        XCTAssertTrue(level.spaces.contains { $0.spaceType == .footprint })
    }

    func testGroundLevelIndex() {
        let levels = [LevelDraft(name: "Basement", kind: .basement, sortOrder: -1, spaces: [SpaceDraft(name: "B", polygon: Polygon(rect: Rect(x: 0, y: 0, width: 100, height: 100)), source: .manual)]),
                      LevelDraft(name: "Main", kind: .floor, sortOrder: 0, spaces: [SpaceDraft(name: "M", polygon: Polygon(rect: Rect(x: 0, y: 0, width: 100, height: 100)), source: .manual)])]
        XCTAssertEqual(ExteriorPlanning.groundLevelIndex(levels), 1)
        XCTAssertNil(ExteriorPlanning.groundLevelIndex([LevelDraft(name: "Empty")]))
    }
}
