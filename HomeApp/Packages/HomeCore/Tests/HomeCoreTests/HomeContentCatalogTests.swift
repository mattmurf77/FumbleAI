import Foundation
import Testing
import HomeCore

struct HomeContentCatalogTests {
    private func fixture() throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("server/data/home-catalog.json"))
    }

    private func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var value = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        edit(&value)
        return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    private func replace(_ section: String, id: String, fields: [String: Any]) throws -> Data {
        try edited { value in
            var rows = value[section] as! [[String: Any]]
            let index = rows.firstIndex { $0["id"] as? String == id }!
            for (key, replacement) in fields { rows[index][key] = replacement }
            value[section] = rows
        }
    }

    @Test func reviewedSnapshotMatchesBundledMaintenanceAndSupplyDefaults() throws {
        let catalog = try HomeContentCatalog.decode(fixture())
        #expect(catalog.recommendations.count == MaintenanceIdea.allCases.count)
        for idea in MaintenanceIdea.allCases {
            let entry = try #require(catalog.recommendation(idea))
            #expect(entry.title == idea.title)
            #expect(entry.detail == idea.detail)
            #expect(entry.diyTitle == idea.diyTitle)
            #expect(entry.symbol == idea.symbol)
            let supplies = idea.suggestedSupplyPlan
            #expect(entry.supplies.count == supplies.count)
            for (remote, bundled) in zip(entry.supplies, supplies) {
                #expect(remote.name == bundled.name)
                #expect(remote.quantity == bundled.quantity)
                #expect(remote.unit == bundled.unit)
                #expect(remote.isEquipment == bundled.isEquipment)
                #expect(remote.suggestion.confirmedOnHand == nil)
                #expect(remote.suggestion.requested == false)
            }
            let pro = try #require(catalog.guide(for: idea, mode: .hirePro))
            #expect(pro.country == "US")
            #expect(pro.currency == "USD")
            #expect(pro.sources.first?.url == idea.priceSource)
            #expect(pro.sources.first?.label == idea.sourceLabel)
            if let range = idea.rangeUSD {
                #expect(pro.lowMinor == Int64(range.lowerBound * 100))
                #expect(pro.highMinor == Int64(range.upperBound * 100))
                #expect(pro.unit == "job")
                #expect(pro.basis == "installed")
            } else {
                #expect(idea == .filter)
                #expect(pro.lowMinor == 10_000)
                #expect(pro.highMinor == 25_000)
                #expect(pro.unit == "hour")
                #expect(pro.basis == "labor")
                #expect(pro.priceLabel.contains("/hour"))
            }
            let diy = try #require(catalog.guide(for: idea, mode: .diy))
            #expect(diy.scope == idea.diyScope)
            #expect(diy.sources.first?.url == idea.diySource)
            #expect(diy.sources.first?.label == idea.diySourceLabel)
            #expect(catalog.directory(for: idea)?.url == idea.providerDirectory)
            #expect(catalog.resaleScenario(for: idea, mode: .hirePro) == idea.resaleScenario(isDIY: false))
            #expect(catalog.resaleScenario(for: idea, mode: .diy) == nil)
        }
    }

    @Test func reviewedHourlyGuidesMatchTheCustomWorkTradeOptions() throws {
        let catalog = try HomeContentCatalog.decode(fixture())
        let pairs: [(String, EstimateTradeRate)] = [
            ("trade-handyman", .handyman), ("trade-carpenter", .carpenter),
            ("trade-plumber", .plumber), ("trade-electrician", .electrician),
        ]
        for (id, bundled) in pairs {
            let guide = try #require(catalog.costGuides.first { $0.id == id })
            #expect(guide.lowMinor == bundled.low.cents)
            #expect(guide.highMinor == bundled.high.cents)
            #expect(guide.unit == "hour")
            #expect(guide.basis == "labor")
            #expect(guide.sources.first?.url == bundled.article)
            #expect(guide.scope.contains(EstimateTradeRate.terms))
        }
    }

    @Test func measuredScopeGuidesPreservePackPricesAndWholeJobDistinction() throws {
        let catalog = try HomeContentCatalog.decode(fixture())
        let cases: [(CustomScopeStarter, Chore.WorkMode, Int, String)] = [
            (.interiorPaint, .diy, 0, "scope-interior-paint-material"),
            (.interiorPaint, .hirePro, 0, "scope-interior-paint-professional"),
            (.vinylFloor, .diy, 0, "scope-vinyl-floor-material"),
            (.vinylFloor, .hirePro, 1, "scope-vinyl-floor-labor"),
            (.mulchBeds, .diy, 0, "scope-mulch-material"),
            (.mulchBeds, .hirePro, 1, "scope-mulch-labor"),
            (.smallHandyman, .hirePro, 0, "scope-smallHandyman"),
            (.halfDayHandyman, .hirePro, 0, "scope-halfDayHandyman"),
            (.fullDayHandyman, .hirePro, 0, "scope-fullDayHandyman"),
        ]
        for (starter, mode, index, id) in cases {
            let lines = try starter.lines(length: 12, width: 14, heightOrDepth: nil,
                                          coats: 2, openings: 0, currency: "USD", mode: mode)
            let line = lines[index]
            let guide = try #require(catalog.costGuides.first { $0.id == id })
            #expect(guide.lowMinor == line.unitPrice?.cents)
            #expect(guide.highMinor == (line.highUnitPrice ?? line.unitPrice)?.cents)
            #expect((guide.basis == "wholeJob") == (line.kind == .wholeJob))
            for source in guide.sources { #expect(line.source?.contains(source.url.absoluteString) == true) }
        }
    }

    @Test func rejectsUnsupportedSchemaAndIncompleteRecommendationSet() throws {
        let schema = try edited { $0["schemaVersion"] = 2 }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(schema) }
        let missing = try edited { value in
            var rows = value["recommendations"] as! [[String: Any]]
            rows.removeLast(); value["recommendations"] = rows
        }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(missing) }
        let duplicate = try edited { value in
            var rows = value["recommendations"] as! [[String: Any]]
            rows[1] = rows[0]; value["recommendations"] = rows
        }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(duplicate) }
        let unknown = try replace("recommendations", id: "gutters", fields: ["id": "unrecognized-task"])
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(unknown) }
    }

    @Test func rejectsForeignPricesNegativeRangesAndMissingGuides() throws {
        for fields: [String: Any] in [["country": "CA"], ["currency": "CAD"], ["lowMinor": -1],
                                      ["highMinor": 1], ["highMinor": 1_000_000_001]] {
            let invalid = try replace("costGuides", id: "gutters-professional", fields: fields)
            #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(invalid) }
        }
        let unknown = try replace("recommendations", id: "gutters", fields: ["professionalGuideID": "missing-guide"])
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(unknown) }
        let duplicate = try edited { value in
            var rows = value["costGuides"] as! [[String: Any]]
            rows.append(rows[0]); value["costGuides"] = rows
        }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(duplicate) }
    }

    @Test func rejectsUnsafeSourcesAndFutureReviewDates() throws {
        for url in ["http://www.angi.com/", "https://user:secret@www.angi.com/", "https://127.0.0.1/",
                    "https://localhost/", "https://www.angi.com:8443/"] {
            let invalid = try edited { value in
                var rows = value["costGuides"] as! [[String: Any]]
                var sources = rows[0]["sources"] as! [[String: Any]]
                sources[0]["url"] = url; rows[0]["sources"] = sources; value["costGuides"] = rows
            }
            #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(invalid) }
        }
        let future = try edited { value in
            var rows = value["costGuides"] as! [[String: Any]]
            var sources = rows[0]["sources"] as! [[String: Any]]
            sources[0]["reviewedOn"] = "2099-01-01"; rows[0]["sources"] = sources; value["costGuides"] = rows
        }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(future) }
        let invalidDate = try edited { $0["reviewedOn"] = "2026-02-30" }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(invalidDate) }
    }

    @Test func rejectsHourlyPricesAsWholeJobsAndSwappedProjectScopes() throws {
        for (id, fields) in [("filter-professional", ["unit": "job"]),
                             ("gutters-professional", ["unit": "hour"]),
                             ("closet-diy", ["basis": "installed"])] {
            let invalid = try replace("costGuides", id: id, fields: fields)
            #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(invalid) }
        }
        let swapped = try replace("recommendations", id: "gutters", fields: ["professionalGuideID": "closet-professional"])
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(swapped) }
    }

    @Test func rejectsBorrowedResaleAssumptionsForMaintenanceAndDIY() throws {
        let maintenance = try edited { value in
            var rows = value["recommendations"] as! [[String: Any]]
            for index in rows.indices {
                rows[index]["resaleAssumptionID"] = (rows[index]["id"] as? String == "gutters") ?
                    "closet-renovation-2025" : NSNull()
            }
            value["recommendations"] = rows
            var assumptions = value["resaleAssumptions"] as! [[String: Any]]
            assumptions[0]["costGuideID"] = "gutters-professional"
            value["resaleAssumptions"] = assumptions
        }
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(maintenance) }
        let diy = try replace("resaleAssumptions", id: "closet-renovation-2025", fields: ["mode": "diy"])
        #expect(throws: HomeContentCatalog.Invalid.self) { try HomeContentCatalog.decode(diy) }
    }
}
