import XCTest
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import HomeCapture

final class HomeCaptureTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(HomeCaptureModule.name, "HomeCapture")
    }

    func testFloorNamesAndDuplicates() {
        XCTAssertEqual((0..<4).map(CaptureNaming.floorName(index:)), ["1st Floor", "2nd Floor", "3rd Floor", "4th Floor"])
        XCTAssertEqual(CaptureNaming.numberDuplicates(["Bedroom", "Kitchen", "Bedroom", "Bedroom"]), ["Bedroom", "Kitchen", "Bedroom 2", "Bedroom 3"])
    }
}

// MARK: - Shared assertions

func assertTiles(_ spaces: [SpaceDraft], file: StaticString = #filePath, line: UInt = #line) {
    for (i, a) in spaces.enumerated() {
        XCTAssertNil(Validation.validate(a.polygon.vertices, minArea: Tolerance.minZoneArea), "\(a.name) invalid", file: file, line: line)
        for b in spaces[(i + 1)...] {
            XCTAssertLessThanOrEqual(Clip.intersectionArea(a.polygon, b.polygon), Tolerance.maxInteriorOverlap,
                                     "\(a.name) overlaps \(b.name)", file: file, line: line)
        }
    }
}

// MARK: - Rough it in

final class RoughInGeneratorTests: XCTestCase {
    let gen = RoughInGenerator()

    /// AC-PLN-2: 2 floors, 2,000 sq ft, 3 beds, 2.5 baths, no basement.
    func testAcceptanceTwoFloors() {
        let d = gen.draft(RoughInInput(floors: 2, hasBasement: false, approxSqFt: 2000, bedrooms: 3, bathrooms: 2.5))
        XCTAssertEqual(d.source, .rough)
        XCTAssertEqual(d.levels.map(\.name), ["1st Floor", "2nd Floor"])
        XCTAssertEqual(d.levels.map(\.sortOrder), [0, 1])
        let ground = Set(d.levels[0].spaces.map(\.name)), upper = d.levels[1].spaces
        XCTAssertEqual(ground, ["Living Room", "Kitchen", "Dining Room", "Half Bath", "Laundry", "Hall", "Stairs"])
        XCTAssertEqual(upper.filter { $0.spaceType == .bedroom }.count, 3)
        XCTAssertEqual(upper.filter { $0.spaceType == .bathroom }.count, 2)
        XCTAssertTrue(upper.contains { $0.name == "Primary Bedroom" })
        XCTAssertTrue(d.levels.allSatisfy { $0.spaces.allSatisfy { $0.isApproximate && $0.source == .rough } })
        for l in d.levels { assertTiles(l.spaces) }
        // Deterministic, including temp ids.
        XCTAssertEqual(d, gen.draft(RoughInInput(floors: 2, hasBasement: false, approxSqFt: 2000, bedrooms: 3, bathrooms: 2.5)))
    }

    func testAreaGridAndAspect() {
        let d = gen.draft(RoughInInput(floors: 1, hasBasement: false, approxSqFt: 1500, bedrooms: 3, bathrooms: 2))
        let spaces = d.levels[0].spaces
        let total = spaces.reduce(0) { $0 + $1.polygon.area } / 144
        XCTAssertEqual(total, 1500, accuracy: 1500 * 0.03)
        let b = d.levels[0].bounds
        XCTAssertEqual(b.width / b.height, 1.4, accuracy: 0.05)
        for s in spaces { for v in s.polygon.vertices {
            XCTAssertEqual(v.x.truncatingRemainder(dividingBy: 6), 0, accuracy: 1e-6)
            XCTAssertEqual(v.y.truncatingRemainder(dividingBy: 6), 0, accuracy: 1e-6)
        } }
        XCTAssertEqual(spaces.filter { $0.spaceType == .bathroom }.count, 2)
        XCTAssertEqual(spaces.first { $0.spaceType == .hall }?.polygon.bounds.height, 42)
        assertTiles(spaces)
    }

    func testBasementGarageAndThreeFloors() {
        let d = gen.draft(RoughInInput(floors: 3, hasBasement: true, approxSqFt: 3000, bedrooms: 5, bathrooms: 3.5, includeGarage: true))
        XCTAssertEqual(d.levels.map(\.name), ["Basement", "1st Floor", "2nd Floor", "3rd Floor"])
        XCTAssertEqual(d.levels.map(\.sortOrder), [-1, 0, 1, 2])
        XCTAssertEqual(d.levels[0].kind, .basement)
        XCTAssertEqual(Set(d.levels[0].spaces.map(\.name)), ["Basement", "Utility"])
        let groundArea = d.levels[1].spaces.filter { $0.spaceType != .garage }.reduce(0) { $0 + $1.polygon.area }
        XCTAssertEqual(d.levels[0].spaces.reduce(0) { $0 + $1.polygon.area }, groundArea * 0.7, accuracy: groundArea * 0.05)
        let garage = d.levels[1].spaces.first { $0.spaceType == .garage }
        XCTAssertNotNil(garage)
        XCTAssertEqual(garage?.polygon.bounds.minX, 0)
        XCTAssertEqual(d.allSuggestions.count, 0)
        let bedrooms = d.levels.flatMap(\.spaces).filter { $0.spaceType == .bedroom }
        XCTAssertEqual(bedrooms.count, 5)
        XCTAssertEqual(Set(bedrooms.map(\.name)).count, 5)
        for l in d.levels { assertTiles(l.spaces) }
    }

    func testClampsInputs() {
        let d = gen.draft(RoughInInput(floors: 9, hasBasement: false, approxSqFt: 50, bedrooms: -2, bathrooms: 0))
        XCTAssertEqual(d.levels.count, 3)
        XCTAssertTrue(d.levels.allSatisfy { !$0.spaces.isEmpty })
    }
}

// MARK: - Blocks

final class BlockTemplatesTests: XCTestCase {
    func testEveryStyleProducesValidTiledLevels() {
        for style in HouseStyle.allCases {
            for beds in [0, 1, 3, 5] {
                let d = BlockTemplates().draft(style: style, beds: beds, baths: 2.5)
                XCTAssertEqual(d.source, .blocks)
                XCTAssertFalse(d.levels.isEmpty, "\(style)")
                XCTAssertTrue(d.levels.contains { $0.sortOrder == 0 }, "\(style) needs a ground floor")
                for l in d.levels {
                    XCTAssertFalse(l.spaces.isEmpty, "\(style) \(l.name)")
                    assertTiles(l.spaces)
                    XCTAssertTrue(l.spaces.allSatisfy { $0.source == .blocks && !$0.isApproximate })
                }
                XCTAssertEqual(d.levels.flatMap(\.spaces).filter { $0.spaceType == .bedroom }.count, beds, "\(style) beds")
                XCTAssertEqual(d, BlockTemplates().draft(style: style, beds: beds, baths: 2.5))
            }
        }
    }

    /// AC-PLN-4: Colonial 2-story with 4 beds → 2 floors.
    func testColonialFourBeds() {
        let d = BlockTemplates().draft(style: .twoStory, beds: 4, baths: 2.5)
        XCTAssertEqual(d.levels.count, 2)
        XCTAssertEqual(d.levels[1].spaces.filter { $0.spaceType == .bedroom }.count, 4)
        XCTAssertEqual(d.levels[0].spaces.filter { $0.spaceType == .halfBath }.count, 1)
        XCTAssertEqual(BlockTemplates.displayName(.twoStory), "Colonial 2-story")
        XCTAssertFalse(BlockTemplates.seedsExteriorByDefault(.apartment))
    }

    func testSplitLevelHasThreeLevels() {
        let d = BlockTemplates().draft(style: .splitLevel, beds: 3, baths: 2)
        XCTAssertEqual(d.levels.map(\.name), ["Lower Level", "Main Level", "Upper Level"])
        XCTAssertEqual(d.levels.map(\.sortOrder), [-1, 0, 1])
    }
}

// MARK: - Photo trace

final class PhotoTraceCalibratorTests: XCTestCase {
    let cal = PhotoTraceCalibrator()

    /// AC-PLN-5: 13'2" (158 in) between taps; a room drawn over that wall measures 158 ± 1 in.
    func testCalibrationScale() throws {
        let a = Vec2(100, 400), b = Vec2(732, 402)   // ~0.18° off horizontal → straightened
        let t = try cal.calibrate(a: a, b: b, lengthIn: 158, second: nil, imageSize: Vec2(1600, 1200), contentCenter: .zero).get()
        let ma = t.toModel(pixel: a), mb = t.toModel(pixel: b)
        XCTAssertEqual(ma.distance(to: mb), 158, accuracy: 1)
        XCTAssertEqual(ma.y, mb.y, accuracy: 0.01, "segment straightened to horizontal")
        XCTAssertEqual(t.toModel(pixel: Vec2(800, 600)).length, 0, accuracy: 0.01, "image center on content center")
        XCTAssertEqual(t.opacity, 0.5)
    }

    /// AC-PLN-6: scales that differ by 8 % warn.
    func testStretchedWarning() {
        let r = cal.calibrate(a: Vec2(0, 0), b: Vec2(100, 0), lengthIn: 100, second: (Vec2(0, 0), Vec2(0, 100), 108),
                              imageSize: Vec2(1000, 1000), contentCenter: .zero)
        guard case .failure(.possiblyStretched(let ratio)) = r else { return XCTFail("expected warning") }
        XCTAssertEqual(ratio, 0.08, accuracy: 1e-9)
        let detailed = try? cal.calibrateDetailed(a: Vec2(0, 0), b: Vec2(100, 0), lengthIn: 100, second: (Vec2(0, 0), Vec2(0, 100), 108),
                                                  imageSize: Vec2(1000, 1000), contentCenter: .zero).get()
        XCTAssertEqual(detailed?.transform.inchesPerPixel ?? 0, 1.04, accuracy: 1e-9)
        XCTAssertNotNil(detailed?.warning)
        XCTAssertEqual(cal.calibrate(a: .zero, b: .zero, lengthIn: 10, second: nil, imageSize: Vec2(10, 10), contentCenter: .zero),
                       .failure(.invalidInput))
    }

    func testLengthParsing() {
        let cases: [(String, Double)] = [("12'4\"", 148), ("12' 4", 148), ("12.33'", 147.96), ("148\"", 148), ("148in", 148),
                                         ("3.76m", 148.03), ("376cm", 148.03)]
        for (text, inches) in cases {
            XCTAssertEqual(PhotoTraceCalibrator.parseLength(text) ?? -1, inches, accuracy: 0.05, text)
        }
        XCTAssertNil(PhotoTraceCalibrator.parseLength("0"))
        XCTAssertNil(PhotoTraceCalibrator.parseLength("-3'"))
        XCTAssertNil(PhotoTraceCalibrator.parseLength("abc"))
        XCTAssertTrue(PhotoTraceCalibrator.isTooSmall(widthPx: 640, heightPx: 480))
        XCTAssertFalse(PhotoTraceCalibrator.isTooSmall(widthPx: 1200, heightPx: 480))
    }

    func testTraceDraftCarriesUnderlay() {
        let t = UnderlayTransform(inchesPerPixel: 0.25, opacity: 1)
        let d = PhotoTraceCalibrator.draft(image: AttachmentDraft(fileURL: URL(fileURLWithPath: "/tmp/plan.jpg"), kind: .underlay), transform: t)
        XCTAssertEqual(d.source, .trace)
        XCTAssertEqual(d.levels.first?.underlay?.transform.opacity, 0.5)
        let room = PhotoTraceCalibrator.tracedSpace(name: "Kitchen", pixelCorners: [Vec2(0, 0), Vec2(400, 0), Vec2(400, 480), Vec2(0, 480)], transform: t)
        XCTAssertEqual(room?.polygon.rectangleSize?.width ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(room?.source, .trace)
    }
}

// MARK: - Receipts

final class ReceiptParserTests: XCTestCase {
    struct Case: Decodable {
        struct Expect: Decodable { var total: Int64?; var date: String?; var vendor: String? }
        var name: String; var today: String; var expect: Expect; var lines: [OCRLine]
    }

    func testFixtureReceipts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "receipts", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for c in cases {
            let g = ReceiptParser().parse(lines: c.lines.shuffled(), today: LocalDate(string: c.today)!)
            XCTAssertEqual(g.total?.cents, c.expect.total, c.name)
            XCTAssertEqual(g.date, c.expect.date.flatMap(LocalDate.init(string:)), c.name)
            XCTAssertEqual(g.vendor, c.expect.vendor, c.name)
            XCTAssertEqual(g.total?.currency ?? "USD", "USD")
            XCTAssertTrue(g.fullText.hasPrefix(c.lines.min { $0.y < $1.y }!.text), c.name)
        }
    }

    func testAmountRegex() {
        XCTAssertEqual(ReceiptParser.amounts(in: "$1,234.56 and 7.00 but not 1.234 or 12.3 or 3.456"), [123456, 700])
        XCTAssertEqual(ReceiptParser.amounts(in: "Item 12345.67"), [1234567])
    }

    func testDateFormats() {
        XCTAssertEqual(ReceiptParser.dates(in: "09/18/26"), [LocalDate(2026, 9, 18)])
        XCTAssertEqual(ReceiptParser.dates(in: "18/09/2026"), [LocalDate(2026, 9, 18)])
        XCTAssertEqual(ReceiptParser.dates(in: "18 Sept 2026"), [LocalDate(2026, 9, 18)])
        XCTAssertEqual(ReceiptParser.dates(in: "September 3rd, 2026"), [LocalDate(2026, 9, 3)])
        XCTAssertEqual(ReceiptParser.dates(in: "2026-02-30"), [])
    }

    func testReaderWithoutVisionThrowsOnLinux() async {
        #if !canImport(Vision)
        do { _ = try await ReceiptReader().read(images: [Data()]); XCTFail("expected unavailable") }
        catch { XCTAssertEqual(error as? ReceiptReader.ReaderError, .unavailable) }
        #endif
    }
}

// MARK: - RoomPlan import

final class RoomPlanImporterTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "two_rooms_two_stories", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testConvertsFixture() throws {
        let d = try RoomPlanImporter().draft(fromCapturedStructureJSON: fixture(), storyMap: [:])
        XCTAssertEqual(d.source, .roomplan)
        XCTAssertEqual(d.levels.map(\.name), ["1st Floor", "2nd Floor"])
        XCTAssertEqual(d.levels.map(\.storyIndex), [0, 1])
        let ground = d.levels[0]
        XCTAssertEqual(Set(ground.spaces.map(\.name)), ["Kitchen", "Bedroom"])
        let kitchen = try XCTUnwrap(ground.spaces.first { $0.name == "Kitchen" })
        let bedroom = try XCTUnwrap(ground.spaces.first { $0.name == "Bedroom" })
        XCTAssertEqual(kitchen.spaceType, .kitchen)
        XCTAssertEqual(bedroom.spaceType, .bedroom)
        // 10° scan rotation removed: axis-aligned rectangles.
        for s in ground.spaces {
            let size = try XCTUnwrap(s.polygon.rectangleSize, s.name)
            XCTAssertTrue(s.polygon.edges.allSatisfy { abs($0.vector.x) < 0.02 || abs($0.vector.y) < 0.02 }, s.name)
            _ = size
        }
        // 4 m × 3.5 m interior + 2.25 in each side.
        let k = kitchen.polygon.rectangleSize!
        XCTAssertEqual(max(k.width, k.height), 157.48 + 4.5, accuracy: 3.5)
        XCTAssertEqual(min(k.width, k.height), 137.80 + 4.5, accuracy: 3.5)
        // Wall-loop fallback room (no floor polygon) welded to its neighbor: no overlap, shared wall.
        XCTAssertLessThanOrEqual(Clip.intersectionArea(kitchen.polygon, bedroom.polygon), Tolerance.maxInteriorOverlap)
        let gap = kitchen.polygon.vertices.map { v in bedroom.polygon.distanceToEdge(v) }.min()!
        XCTAssertLessThan(gap, 0.5)
        XCTAssertFalse(ground.warnings.contains { if case .hullFallback = $0 { return true }; return false })

        // Openings: the shared door reported by both rooms is kept once; the window has a sill.
        XCTAssertEqual(ground.openings.filter { $0.kind == .door }.count, 1)
        let window = try XCTUnwrap(ground.openings.first { $0.kind == .window })
        XCTAssertEqual(window.sillIn ?? 0, 0.9 * 39.3701, accuracy: 0.5)
        XCTAssertEqual(window.segment.length, 1.2 * 39.3701, accuracy: 0.5)
        let door = try XCTUnwrap(ground.openings.first { $0.kind == .door })
        XCTAssertFalse(door.isExteriorDoor)
        XCTAssertEqual(door.heightIn ?? 0, 78.74, accuracy: 0.1)
        let m = try XCTUnwrap(ground.measurements.first)
        XCTAssertEqual(m.kind, .door)
        XCTAssertEqual(m.source, .roomplan)
        XCTAssertEqual(m.openingTempId, door.tempId)
        XCTAssertEqual(m.dims.width ?? 0, 0.9 * 39.3701, accuracy: 0.5)

        // Suggested things: refrigerator in Kitchen, bed in Bedroom; stairs skipped.
        XCTAssertEqual(ground.suggestedThings.count, 2)
        let fridge = try XCTUnwrap(ground.suggestedThings.first { $0.templateKey == "refrigerator" })
        XCTAssertEqual(fridge.spaceTempId, kitchen.tempId)
        XCTAssertEqual(fridge.category, .appliance)
        XCTAssertEqual(fridge.dims.height ?? 0, 70.87, accuracy: 0.1)
        XCTAssertEqual(ground.suggestedThings.first { $0.templateKey == "bed" }?.spaceTempId, bedroom.tempId)

        // Second story named from its section; the two stories stack (same frame).
        XCTAssertEqual(d.levels[1].spaces.map(\.name), ["Bedroom"])
        let upper = d.levels[1].spaces[0].polygon.bounds
        XCTAssertEqual(upper.minX, kitchen.polygon.bounds.minX, accuracy: 3)
        XCTAssertEqual(upper.minY, kitchen.polygon.bounds.minY, accuracy: 3)
    }

    func testStoryMapBasement() throws {
        let d = try RoomPlanImporter().draft(fromCapturedStructureJSON: fixture(), storyMap: [0: .basement])
        XCTAssertEqual(d.levels.map(\.name), ["Basement", "1st Floor"])
        XCTAssertEqual(d.levels.map(\.sortOrder), [-1, 0])
        XCTAssertEqual(d.levels.map(\.kind), [.basement, .floor])
        XCTAssertEqual(RoomPlanImporter.stories(in: try fixture()), [0, 1])
    }

    func testRoundTripAndErrors() throws {
        let s = try RoomPlanImporter.decode(fixture())
        let again = try RoomPlanImporter.decode(s.encodeJSON())
        XCTAssertEqual(s, again)
        XCTAssertThrowsError(try RoomPlanImporter().draft(fromCapturedStructureJSON: Data("{}".utf8), storyMap: [:]))
        XCTAssertThrowsError(try RoomPlanImporter().draft(from: RPStructure(rooms: []))) { e in
            XCTAssertEqual(e as? RoomPlanImportError, .noRooms)
        }
    }

    func testHullFallbackAndObjectNaming() throws {
        // Three disconnected walls: no loop, no floor → convex hull, flagged. Toilet → "Bathroom".
        let walls = [RPSurface(transform: .yaw(0, at: RPVec3(1, 1.2, 0)), dimensions: RPVec3(2, 2.4, 0)),
                     RPSurface(transform: .yaw(.pi / 2, at: RPVec3(2.5, 1.2, 1.5)), dimensions: RPVec3(1, 2.4, 0)),
                     RPSurface(transform: .yaw(0, at: RPVec3(0.5, 1.2, 3)), dimensions: RPVec3(1, 2.4, 0))]
        let room = RPRoom(story: 0, walls: walls, objects: [RPObject(category: "toilet", transform: .yaw(0, at: RPVec3(1, 0.4, 1.5)), dimensions: RPVec3(0.4, 0.8, 0.7))])
        let d = try RoomPlanImporter().draft(from: RPStructure(rooms: [room, room]))
        let l = d.levels[0]
        XCTAssertTrue(l.warnings.contains { if case .hullFallback = $0 { return true }; return false })
        XCTAssertEqual(l.spaces.map(\.name), ["Bathroom", "Bathroom 2"])
        XCTAssertTrue(l.warnings.contains { if case .overlap = $0 { return true }; return false })
    }

    func testWallLoopFallbackOnLShape() throws {
        // An L-shaped room from six walls (no floor polygon).
        let pts: [(Double, Double)] = [(0, 0), (4, 0), (4, 2), (2, 2), (2, 4), (0, 4)]
        var walls: [RPSurface] = []
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let len = hypot(b.0 - a.0, b.1 - a.1)
            let yaw = -atan2(b.1 - a.1, b.0 - a.0)
            walls.append(RPSurface(transform: .yaw(yaw, at: RPVec3((a.0 + b.0) / 2, 1.2, (a.1 + b.1) / 2)), dimensions: RPVec3(len * 0.97, 2.4, 0)))
        }
        let d = try RoomPlanImporter().draft(from: RPStructure(rooms: [RPRoom(walls: walls)]))
        let s = d.levels[0].spaces[0]
        XCTAssertEqual(s.polygon.count, 6)
        XCTAssertEqual(s.polygon.area / 144, (12 * 39.3701 * 39.3701) / 144, accuracy: 12)   // + offset ring ≈ 7 sq ft
        XCTAssertEqual(s.name, "Room 1")
    }

    func testLabelMap() {
        XCTAssertEqual(RoomPlanLabelMap.thing(forObject: "washerDryer")?.templateKey, "washer")
        XCTAssertEqual(RoomPlanLabelMap.thing(forObject: "stove")?.templateKey, "range")
        XCTAssertNil(RoomPlanLabelMap.thing(forObject: "stairs"))
        XCTAssertEqual(RoomPlanLabelMap.room(forSection: "livingRoom")?.type, .living)
        XCTAssertNil(RoomPlanLabelMap.room(forSection: "unidentified"))
        XCTAssertEqual(RoomPlanLabelMap.room(forObjects: ["sofa", "television"])?.name, "Living Room")
        XCTAssertEqual(RoomPlanLabelMap.room(forObjects: ["sofa"])?.name, nil)
        XCTAssertEqual(RoomPlanLabelMap.promptNoun(forObject: "refrigerator"), "refrigerator")
    }

    /// Stub conformance compiles against the HomeCore protocol (composition-root sanity check).
    func testProtocolConformances() {
        let _: any RoomPlanImporting = RoomPlanImporter()
        let _: any RoughInGenerating = RoughInGenerator()
        let _: any BlockTemplating = BlockTemplates()
        let _: any PhotoTraceCalibrating = PhotoTraceCalibrator()
        let _: any ReceiptReading = ReceiptReader()
        let _: any ReceiptParsing = ReceiptParser()
    }
}
