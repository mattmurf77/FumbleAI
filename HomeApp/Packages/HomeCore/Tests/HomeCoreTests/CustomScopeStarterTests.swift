import Testing
import HomeCore

struct CustomScopeStarterTests {
    @Test func testTitleOffersMatchingScopeAndExtractsMeasurements() throws {
        #expect(CustomScopeStarter.suggested(for: "Paint my 12 × 14 bedroom", mode: .diy) == .interiorPaint)
        #expect(CustomScopeStarter.suggested(for: "Paint the kitchen cabinets", mode: .hirePro) == nil)
        #expect(CustomScopeStarter.suggested(for: "Repair the vinyl floor", mode: .diy) == nil)
        #expect(CustomScopeStarter.suggested(for: "Install hardwood flooring", mode: .hirePro) == nil)
        let feet = try #require(CustomScopeStarter.roomSize(in: "paint a 12 by 14 ft bedroom"))
        #expect(feet.length == 12); #expect(feet.width == 14)
        let metric = try #require(CustomScopeStarter.roomSize(in: "Mulch a 3 × 4 m bed"))
        #expect(abs(metric.length - (3 / 0.3048)) < 0.00001)
        #expect(abs(metric.width - (4 / 0.3048)) < 0.00001)
        #expect(CustomScopeStarter.roomSize(in: "Replace my 16x25x1 filter") == nil)
    }

    @Test func testPaintComparesBuyableGallonsAgainstInstalledRoomScope() throws {
        var paint = try CustomScopeStarter.interiorPaint.lines(length: 12, width: 14, heightOrDepth: 8,
            coats: 2, openings: 0, currency: "USD", mode: .diy)
        let diy = WorkEstimate(mode: .diy, currency: "USD", lines: paint)
        #expect(try diy.purchaseQuantity(for: paint[0]) == 3)
        #expect(try diy.totals().knownLow?.cents == 8694)
        #expect(try diy.totals().knownHigh?.cents == 16194)
        paint[0].confirmedOnHand = 1
        let onHand = WorkEstimate(mode: .diy, currency: "USD", lines: paint)
        #expect(try onHand.totals().knownLow?.cents == 5796)
        let pro = try CustomScopeStarter.interiorPaint.lines(length: 12, width: 14, heightOrDepth: nil,
            coats: 2, openings: 0, currency: "USD", mode: .hirePro)
        #expect(pro.count == 1); #expect(pro[0].kind == .wholeJob)
        let contractor = WorkEstimate(mode: .hirePro, currency: "USD", lines: pro)
        #expect(try contractor.totals().knownLow?.cents == 33600)
        #expect(try contractor.totals().knownHigh?.cents == 100800)
        #expect(throws: WorkEstimateError.self) { try CustomScopeStarter.interiorPaint.lines(length: 12, width: 14, heightOrDepth: 8,
            coats: 2, openings: 500, currency: "USD", mode: .diy) }
    }

    @Test func testFlooringUsesActualAreaForLaborAndPacksOnlyForMaterials() throws {
        let rows = try CustomScopeStarter.vinylFloor.lines(length: 10, width: 10, heightOrDepth: nil,
            coats: 1, openings: 0, currency: "USD", mode: .hirePro)
        let plan = WorkEstimate(mode: .hirePro, currency: "USD", lines: rows)
        #expect(try plan.purchaseQuantity(for: rows[0]) == 6)
        #expect(rows[1].quantity == 100)
        #expect(try plan.totals().knownLow?.cents == 54120)
        #expect(try plan.totals().knownHigh?.cents == 98240)
    }

    @Test func testMulchAndUnknownCurrencyRetainPhysicalQuantityAndDontInventPrices() throws {
        for currency in ["USD", "CAD"] {
            let rows = try CustomScopeStarter.mulchBeds.lines(length: 12, width: 9, heightOrDepth: 3,
                coats: 1, openings: 0, currency: currency, mode: .hirePro)
            let plan = WorkEstimate(mode: .hirePro, currency: currency, lines: rows)
            #expect(try plan.purchaseQuantity(for: rows[0]) == 18); #expect(rows[1].quantity == 1)
            if currency == "USD" {
                #expect(try plan.totals().knownLow?.cents == 9146); #expect(try plan.totals().knownHigh?.cents == 12146)
            } else {
                #expect(try plan.totals().knownLow == nil); #expect(try plan.totals().unpricedLineCount == 2)
            }
        }
    }

    @Test func testHandymanGuidePricesOneWholeVisitAndRequiresUSProScope() throws {
        let rows = try CustomScopeStarter.halfDayHandyman.lines(length: nil, width: nil, heightOrDepth: nil,
            coats: 1, openings: 0, currency: "USD", mode: .hirePro)
        let plan = WorkEstimate(mode: .hirePro, currency: "USD", lines: rows)
        #expect(rows.count == 1); #expect(try plan.totals().knownHigh?.cents == 56800)
        var duplicate = plan
        duplicate.lines.append(WorkEstimateLine(kind: .labor, name: "Same visit", quantity: 2, unit: "hr", unitPrice: Money(cents: 4200)))
        #expect(throws: WorkEstimateError.self) { try duplicate.totals() }
        #expect(throws: WorkEstimateError.self) { try CustomScopeStarter.fullDayHandyman.lines(length: nil, width: nil, heightOrDepth: nil,
            coats: 1, openings: 0, currency: "USD", mode: .diy) }
    }
}
