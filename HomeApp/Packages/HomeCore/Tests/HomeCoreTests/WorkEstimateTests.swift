import Foundation
import Testing
import HomeCore

struct WorkEstimateTests {
    @Test func paintPacksTimeFeesAndMissingPrices() throws {
        let paint = WorkEstimateLine(kind: .material, name: "Paint", quantity: 4.2, unit: "gal", confirmedOnHand: 1.1, packSize: 2,
                                     unitPrice: .init(cents: 3875), highUnitPrice: .init(cents: 4200))
        let labor = WorkEstimateLine(kind: .labor, name: "Paint walls", quantity: 3.5, unit: "hr", unitPrice: .init(cents: 4225))
        let rental = WorkEstimateLine(kind: .equipment, name: "Sprayer rental", quantity: 2, unit: "days", unitPrice: .init(cents: 950))
        let free = WorkEstimateLine(kind: .fee, name: "Delivery", quantity: 1, unitPrice: .zero())
        var estimate = WorkEstimate(mode: .diy, currency: "USD", lines: [paint, labor, rental, free, .init(kind: .fee, name: "Disposal", quantity: 1)])
        #expect(try estimate.purchaseQuantity(for: paint) == 2)
        let diy = try estimate.totals()
        #expect(diy.knownLow?.cents == 9650 && diy.knownHigh?.cents == 10300)
        #expect(diy.ownHours == 3.5 && !diy.isComplete && diy.unpricedLineCount == 1)
        estimate.mode = .hirePro
        estimate.lines.removeLast()
        let pro = try estimate.totals()
        #expect(pro.knownLow?.cents == 24438 && pro.knownHigh?.cents == 25088)
        #expect(pro.isComplete && pro.ownHours == 0)
    }

    @Test func missingPriceZeroPriceOwnedToolAndEmptyEstimateStayDistinct() throws {
        let empty = WorkEstimate(mode: .diy, currency: "EUR")
        #expect(try empty.totals().knownLow == nil)
        let unknown = WorkEstimateLine(kind: .material, name: "Tape", quantity: 2)
        let owned = WorkEstimateLine(kind: .equipment, name: "Ladder", quantity: 1, unit: "each", confirmedOnHand: 1)
        var estimate = WorkEstimate(mode: .diy, currency: "EUR", lines: [unknown])
        #expect(try estimate.totals().knownLow == nil)
        estimate.lines = [owned]
        #expect(try estimate.totals().knownLow == .zero("EUR"))
        #expect(try estimate.totals().isComplete)
        estimate.lines = [.init(kind: .fee, name: "No delivery charge", quantity: 1, unitPrice: .zero("EUR"))]
        #expect(try estimate.totals().isComplete)
        estimate.lines = [.init(kind: .labor, name: "Prep time", unit: "hr")]
        #expect(try estimate.totals().hasUnknownOwnHours)
    }

    @Test func rejectsBadUnitsRangesCurrenciesAndOverflow() {
        let invalid: [WorkEstimateLine] = [
            .init(kind: .equipment, name: "Lift", quantity: 2, unit: "days", confirmedOnHand: 1),
            .init(kind: .material, name: "Paint", quantity: 2, packSize: 0),
            .init(kind: .material, name: "Paint", quantity: 2, confirmedOnHand: -1),
            .init(kind: .fee, name: "Permit", quantity: 1, highUnitPrice: .init(cents: 1)),
            .init(kind: .fee, name: "Permit", quantity: 1, unitPrice: .init(cents: 5), highUnitPrice: .init(cents: 3)),
            .init(kind: .fee, name: "Delivery", quantity: 1, unitPrice: .zero("EUR")),
            .init(kind: .fee, name: "Delivery", quantity: 2, unitPrice: .init(cents: Int64.max))
        ]
        for line in invalid {
            #expect(throws: WorkEstimateError.self) { try WorkEstimate(mode: .hirePro, currency: "USD", lines: [line]).totals() }
        }
    }
    @Test func professionalTradeRatesNeedUSHourlyWorkAndOwnerSuppliedDuration() throws {
        let guide = EstimateTradeRate.carpenter
        #expect(EstimateTradeRate.available(mode: .hirePro, kind: .labor, unit: " Hours ", currency: "USD", country: "US"))
        #expect(!EstimateTradeRate.available(mode: .diy, kind: .labor, unit: "hr", currency: "USD", country: "US"))
        #expect(!EstimateTradeRate.available(mode: .hirePro, kind: .labor, unit: "sq ft", currency: "USD", country: "US"))
        #expect(!EstimateTradeRate.available(mode: .hirePro, kind: .labor, unit: "hr", currency: "USD", country: nil))
        #expect(!EstimateTradeRate.available(mode: .hirePro, kind: .labor, unit: "hr", currency: "CAD", country: "CA"))
        #expect(!EstimateTradeRate.available(mode: .hirePro, kind: .material, unit: "hr", currency: "USD", country: "US"))
        var row = WorkEstimateLine(kind: .labor, name: "Repair a custom bookshelf", unit: "hr",
                                   unitPrice: guide.low, highUnitPrice: guide.high, source: guide.sourceNote)
        func totals(_ row: WorkEstimateLine) throws -> WorkEstimateTotals {
            try WorkEstimate(mode: .hirePro, currency: "USD", lines: [row]).totals()
        }
        #expect(try totals(row).knownLow == nil)
        row.quantity = 3
        #expect(try totals(row).knownLow?.cents == 12_000)
        #expect(try totals(row).knownHigh?.cents == 30_000)
        row.unitPrice = Money(cents: 7750)
        row.highUnitPrice = nil
        #expect(try totals(row).knownLow?.cents == 23_250)
        #expect(try totals(row).knownLow == totals(row).knownHigh)
        #expect(EstimateTradeRate.sourceAfterEditing(guide.sourceNote, low: row.unitPrice, high: nil) == "Owner-edited hourly rate.")
        #expect(EstimateTradeRate.sourceAfterEditing("My carpenter’s quote", low: row.unitPrice, high: nil) == "My carpenter’s quote")
        #expect(EstimateTradeRate.sourceAfterEditing(guide.sourceNote, low: guide.low, high: guide.high) == guide.sourceNote)
    }

}
