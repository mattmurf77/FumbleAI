import XCTest
import PlanKit
@testable import HomeCore

final class LocalDateTests: XCTestCase {
    func testEpochRoundTripAndWeekday() {
        XCTAssertEqual(LocalDate(1970, 1, 1).daysSinceEpoch, 0)
        XCTAssertEqual(LocalDate(1970, 1, 1).weekday, 5) // Thursday
        XCTAssertEqual(LocalDate(2026, 9, 29).weekday, 3) // Tuesday
        for n in stride(from: -800_000, through: 800_000, by: 997) {
            XCTAssertEqual(LocalDate(daysSinceEpoch: n).daysSinceEpoch, n)
        }
        XCTAssertEqual(LocalDate(2024, 2, 28).adding(days: 1), LocalDate(2024, 2, 29))
        XCTAssertEqual(LocalDate(2024, 12, 31).adding(days: 1), LocalDate(2025, 1, 1))
    }

    func testMonthsClampAndParsing() {
        XCTAssertEqual(LocalDate(2026, 1, 31).adding(months: 1), LocalDate(2026, 2, 28))
        XCTAssertEqual(LocalDate(2024, 1, 31).adding(months: 1), LocalDate(2024, 2, 29))
        XCTAssertEqual(LocalDate(2026, 11, 15).adding(months: 3), LocalDate(2027, 2, 15))
        XCTAssertEqual(LocalDate(2026, 2, 15).adding(months: -3), LocalDate(2025, 11, 15))
        XCTAssertEqual(LocalDate(string: "2026-02-29"), nil)
        XCTAssertEqual(LocalDate(string: "2024-02-29"), LocalDate(2024, 2, 29))
        XCTAssertEqual(LocalDate(2026, 3, 4).description, "2026-03-04")
    }

    func testCodableAsString() throws {
        let data = try JSONEncoder().encode(["d": LocalDate(2026, 3, 4)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"d":"2026-03-04"}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: LocalDate].self, from: data)["d"], LocalDate(2026, 3, 4))
    }

    func testFromDateUsesCalendarTimeZone() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let d = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
        XCTAssertEqual(LocalDate(d, calendar: c), LocalDate(2026, 9, 21))
        let back = LocalDate(2026, 9, 21).date(atMinutes: 540, calendar: c)!
        XCTAssertEqual(c.component(.hour, from: back), 9)
    }
}

final class MoneyAndFormatTests: XCTestCase {
    func testMoney() {
        XCTAssertEqual(Money(major: Decimal(string: "4612.5")!).cents, 461_250)
        XCTAssertEqual(Money(cents: 461_200).plainString, "4612.00")
        XCTAssertEqual(Money(cents: -5).plainString, "-0.05")
        XCTAssertEqual(Money(cents: 420_000).compact, "$4.2k")
        XCTAssertEqual(Money(cents: 95_000).compact, "$950")
        XCTAssertEqual(Money(cents: 1_840_000).compact, "$18k")
        XCTAssertEqual(Money(cents: 400_000).compact, "$4k")
        XCTAssertEqual((Money(cents: 100) + Money(cents: 250)).cents, 350)
    }

    func testLengthFormatting() {
        XCTAssertEqual(HomeLengthFormatter.format(148), "12'4\"")
        XCTAssertEqual(HomeLengthFormatter.format(167.6), "14'0\"")
        XCTAssertEqual(HomeLengthFormatter.formatInches(35.75), "35¾ in")
        XCTAssertEqual(HomeLengthFormatter.formatInches(32), "32 in")
        XCTAssertEqual(HomeLengthFormatter.format(148, system: .metric), "3.76 m")
        XCTAssertEqual(HomeLengthFormatter.formatArea(squareInches: 1240 * 144), "1,240 sq ft")
        let p = Polygon(rect: Rect(x: 0, y: 0, width: 148, height: 168))
        XCTAssertEqual(HomeLengthFormatter.dimensionText(for: p, isApproximate: false), "12'4\" × 14'0\"")
        XCTAssertEqual(HomeLengthFormatter.dimensionText(for: p, isApproximate: true), "~12'4\" × 14'0\"")
    }

    func testLengthParsing() throws {
        let cases: [(String, Double)] = [("12'4\"", 148), ("12' 4", 148), ("12.5'", 150), ("148\"", 148), ("148in", 148),
                                         ("148", 148), ("12ft 4in", 148), ("3.76m", 3.76 * 39.3701), ("376cm", 3.76 * 39.3701), ("12’4”", 148)]
        for (s, v) in cases { XCTAssertEqual(try XCTUnwrap(HomeLengthFormatter.parse(s), s), v, accuracy: 0.01, s) }
        XCTAssertNil(HomeLengthFormatter.parse("abc"))
        XCTAssertNil(HomeLengthFormatter.parse(""))
    }

    func testTemplateCatalogKeysAndOutdoor() {
        let keys = ThingTemplate.catalog.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        let outdoor = ThingTemplate.catalog.filter { $0.category == .outdoor }
        XCTAssertGreaterThanOrEqual(outdoor.count, 19)
        for k in ["tree", "flower_bed", "patio", "fire_pit", "shed", "pool"] { XCTAssertEqual(ThingTemplate.find(k)?.category, .outdoor, k) }
        XCTAssertEqual(ThingTemplate.defaultSymbol(for: .outdoor), "tree")
        XCTAssertEqual(try JSONDecoder().decode(Thing.Category.self, from: Data(#""outdoor""#.utf8)), .outdoor)
    }

    func testForwardCompatibleEnumsAndScope() throws {
        let decoded = try JSONDecoder().decode([Level.Kind].self, from: Data(#"["floor","mezzanine"]"#.utf8))
        XCTAssertEqual(decoded, [.floor, .unknown])
        XCTAssertFalse(Level.Kind.knownCases.contains(.unknown))
        XCTAssertEqual(try JSONEncoder().encode(Project.Status.inProgress), Data(#""in_progress""#.utf8))

        let s = Scope.space(SampleHomeIDs.a, level: SampleHomeIDs.b)
        let back = try JSONDecoder().decode(Scope.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertThrowsError(try Scope(kind: .level, spaceId: SampleHomeIDs.a, levelId: SampleHomeIDs.b))
        XCTAssertEqual(try Scope(kind: .property, spaceId: nil, levelId: nil), .property)
    }

    func testModelsRoundTripJSON() throws {
        let c = Chore(propertyId: SampleHomeIDs.a, scope: .level(SampleHomeIDs.b), title: "Filter", repeatRule: .everyNDays(90),
                      startOn: LocalDate(2026, 1, 1), nextDueOn: LocalDate(2026, 4, 1), createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try JSONDecoder().decode(Chore.self, from: try JSONEncoder().encode(c)), c)
        let t = Thing(propertyId: SampleHomeIDs.a, scope: .property, category: .system, name: "Furnace", templateKey: "hvac_furnace",
                      attributes: ["filterSize": "16x25x1", "merv": 11, "smart": true])
        XCTAssertEqual(try JSONDecoder().decode(Thing.self, from: try JSONEncoder().encode(t)), t)
        XCTAssertEqual(t.symbol, "fan")
        XCTAssertEqual(try HomeJSON.encodeString(t.attributes), #"{"filterSize":"16x25x1","merv":11,"smart":true}"#)
    }

    func testAppConfig() {
        let c = AppConfig(infoDictionary: ["HomeServerURL": "https://home.example.com", "HomeAPIKey": "k1",
                                           "CFBundleIdentifier": "com.test.home", "CFBundleVersion": "42"])
        XCTAssertTrue(c.usesServer)
        XCTAssertEqual(c.serverHeaders, ["X-Home-Key": "k1"])
        XCTAssertEqual(c.cloudKitContainerIdentifier, "iCloud.com.test.home")
        XCTAssertEqual(c.buildNumber, "42")
        let empty = AppConfig(infoDictionary: ["HomeServerURL": "", "HomeAPIKey": "$(HOME_API_KEY)"])
        XCTAssertFalse(empty.usesServer)
        XCTAssertTrue(empty.serverHeaders.isEmpty)
        XCTAssertEqual(empty.cloudKitContainerIdentifier, "iCloud.app.fumble.home")
    }

    func testItemRefDeepLinks() {
        let id = UUID()
        XCTAssertEqual(ItemRef(url: ItemRef.chore(id).deepLink), .chore(id))
        XCTAssertEqual(ItemRef.chore(id).deepLink.absoluteString, "home://chore/\(id.uuidString.lowercased())")
    }

    func testSearchTokens() {
        XCTAssertEqual(SearchQuery.tokens("  Wínter  CO(at)* "), ["winter", "co", "at"])
        XCTAssertEqual(SearchQuery.ftsExpression("wint coa"), "\"wint\"* \"coa\"*")
        XCTAssertNil(SearchQuery.ftsExpression("*()"))
    }

    func testCSV() {
        let s = CSV.encode(header: ["a", "b"], rows: [["x,y", "say \"hi\""]])
        XCTAssertEqual(s, "a,b\r\n\"x,y\",\"say \"\"hi\"\"\"\r\n")
        XCTAssertEqual(CSV.file(header: ["a"], rows: []).prefix(3), Data([0xEF, 0xBB, 0xBF]))
    }

    func testSeason() {
        XCTAssertEqual(Season.upcoming(on: LocalDate(2026, 4, 1)), .summer)
        XCTAssertEqual(Season.upcoming(on: LocalDate(2026, 10, 1)), .winter)
        XCTAssertEqual(Season.upcoming(on: LocalDate(2026, 10, 1), latitude: -33.9), .summer)
    }
}

enum SampleHomeIDs {
    static let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
}
