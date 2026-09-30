import XCTest
import PlanKit
import HomeCore
import HomeCoreTesting
@testable import PlanCanvas

final class LensTests: XCTestCase {
    let first = SampleHome.firstFloorId

    func testRegistryCoversAllSevenLenses() {
        XCTAssertEqual(LensRegistry.all.map(\.id), LensID.allCases)
        XCTAssertNil(LensRegistry.lens(for: .plan).addDefault)
        XCTAssertEqual(LensRegistry.lens(for: .budget).addDefault, .futureProject)
        XCTAssertEqual(LensRegistry.lens(for: .inventory).addDefault, .inventory)
    }

    func testPlanLensFooterAndNoChips() {
        let m = Fixture.model(first, lens: .plan)
        XCTAssertTrue(m.lens.spaces.values.allSatisfy { $0.chip == nil && $0.tint == .none && !$0.isQuiet })
        XCTAssertEqual(m.lens.footer.primaryText, "1st Floor · 6 rooms · 912 sq ft")
        XCTAssertEqual(m.lens.footer.secondaryText, "Property · 4 levels · 3,600 sq ft · built 1978")
        XCTAssertNil(m.lens.wholeHouseCount)
        XCTAssertEqual(m.lens.decoration(SampleHome.kitchenId).accessibilityValue, "14 by 14 feet")
    }

    func testPlanLensExteriorFooter() {
        let m = Fixture.model(SampleHome.outsideId, lens: .plan)
        XCTAssertTrue(m.lens.footer.primaryText.hasPrefix("Outside · 3 zones · lot "))
    }

    func testTodosOverdueGetsDangerChipEdgeAndValue() {
        var s = ScopeStats(); s.overdue = 1; s.dueWeek = 2; s.dueToday = 1; s.openChores = 3
        let d = TodosLens().decoration(s, scale: .none, context: LensContext(levelName: "G"))
        XCTAssertEqual(d.chip, Chip("! 3 due", style: .danger, emphasized: true))
        XCTAssertEqual(d.edge, .overdue)
        XCTAssertTrue(d.hasOverdue)
        XCTAssertTrue(d.accessibilityValue.contains("1 overdue"))   // AC-CNV-3
        var q = ScopeStats(); q.openChores = 1
        let quiet = TodosLens().decoration(q, scale: .none, context: LensContext(levelName: "G"))
        XCTAssertTrue(quiet.isQuiet); XCTAssertNil(quiet.chip); XCTAssertNil(quiet.edge)
    }

    func testTodosOnSampleHouse() {
        let m = Fixture.model(first, lens: .todos)
        let k = m.lens.decoration(SampleHome.kitchenId)
        XCTAssertEqual(k.chip?.text, "1 due")          // dishes due today
        XCTAssertEqual(k.chip?.style, .accent)
        XCTAssertEqual(k.chip?.emphasized, true)
        XCTAssertTrue(m.lens.decoration(SampleHome.livingId).isQuiet)
        XCTAssertEqual(m.lens.wholeHouseCount, 2)      // trash + gutters (AC-CNV-8)
        XCTAssertEqual(m.lens.footer.primaryText, "1 today · 0 this week")
        let basement = Fixture.model(SampleHome.basementId, lens: .todos)
        XCTAssertEqual(basement.lens.decoration(SampleHome.utilityId).edge, .overdue)
        XCTAssertTrue(basement.lens.footer.primary.contains(TextRun("1 overdue", .danger)))
        let rooms = AccessibilityModel.overdueRooms(model: basement, viewport: Viewport.fit(basement.bounds, in: CGSize(width: 400, height: 400)))
        XCTAssertEqual(rooms.map(\.id), [SampleHome.utilityId])
    }

    func testFutureProjectsFixedTintSteps() {
        XCTAssertEqual(FutureProjectsLens.tint(plannedCents: 0), .none)
        XCTAssertEqual(FutureProjectsLens.tint(plannedCents: 99_999), .low)
        XCTAssertEqual(FutureProjectsLens.tint(plannedCents: 100_000), .medium)
        XCTAssertEqual(FutureProjectsLens.tint(plannedCents: 499_999), .medium)
        XCTAssertEqual(FutureProjectsLens.tint(plannedCents: 500_000), .high)
        var s = ScopeStats(); s.rollup.plannedCents = 350_000; s.rollup.openCount = 2
        let d = FutureProjectsLens().decoration(s, scale: .none, context: LensContext(levelName: "G"))
        XCTAssertEqual(d.chip, Chip("$3.5k · 2", style: .accent))
        XCTAssertEqual(d.secondLine, "2 projects")
        var ideas = ScopeStats(); ideas.rollup.ideaCount = 3
        XCTAssertEqual(FutureProjectsLens().decoration(ideas, scale: .none, context: LensContext(levelName: "G")).chip, Chip("3 ideas", style: .soft))
    }

    func testPastWorkChipSecondLineAndRelativeTint() {
        var s = ScopeStats(); s.rollup.lifetimeCents = 280_000; s.rollup.doneCount = 1; s.rollup.lastCompletedOn = LocalDate(2026, 3, 14)
        let d = PastWorkLens().decoration(s, scale: LensScale(maxValue: 280_000), context: LensContext(levelName: "G"))
        XCTAssertEqual(d.chip, Chip("$2.8k", style: .neutral))
        XCTAssertEqual(d.secondLine, "last Mar ’26")
        XCTAssertEqual(d.tint, .medium)   // light ramp ceiling
        XCTAssertEqual(TintLevel.relative(1, max: 3), .low)
        XCTAssertEqual(TintLevel.relative(2, max: 3), .medium)
        XCTAssertEqual(TintLevel.relative(3, max: 3), .high)
        XCTAssertEqual(TintLevel.relative(0, max: 3), .none)
    }

    func testThingsPinsAndCornerChip() {
        let m = Fixture.model(first, lens: .things)
        let kitchen = m.lens.decoration(SampleHome.kitchenId)
        XCTAssertEqual(kitchen.cornerChip?.text, "2")   // fridge + planned fridge
        let pins = m.lens.pins
        XCTAssertTrue(pins.contains { $0.itemId == SampleHome.fridgeId && $0.offsetY == 0 })
        let planned = pins.first { $0.itemId == SampleHome.plannedFridgeId }!
        XCTAssertTrue(planned.isPlanned)
        XCTAssertEqual(planned.offsetY, 30)              // unpinned → row under the label
        XCTAssertEqual(planned.anchor, m.geometry.space(SampleHome.kitchenId)!.pole)
    }

    func testInventoryChipDotAndPins() {
        var s = ScopeStats(); s.inventoryCount = 14; s.lowCount = 2; s.expiringCount = 1
        let d = InventoryLens().decoration(s, scale: .none, context: LensContext(levelName: "G"))
        XCTAssertEqual(d.chip, Chip("14 items", style: .neutral, dot: .warn))
        XCTAssertEqual(d.accessibilityValue, "14 items, 2 low, 1 expiring")
        let f = InventoryLens().footer(Fixture.stats(first), context: LensContext(levelName: "1st Floor"))
        XCTAssertEqual(f.link, .shoppingList)
    }

    func testBudgetChipMatchesAcceptanceCriterion() {
        var s = ScopeStats(); s.rollup.plannedCents = 420_000; s.rollup.spentCents = 110_000
        let d = BudgetLens().decoration(s, scale: LensScale(maxValue: 530_000), context: LensContext(levelName: "G"))
        XCTAssertEqual(d.chip?.text, "$4.2k / $1.1k")    // AC-CNV-7
        XCTAssertEqual(d.budgetLines, ["$4.2k planned", "$1.1k spent"])
        XCTAssertEqual(d.tint, .high)
        let m = Fixture.model(first, lens: .budget)
        XCTAssertTrue(m.lens.footer.primaryText.hasPrefix("1st Floor: $"))
        XCTAssertTrue(m.lens.footer.secondaryText.hasPrefix("Home: $"))
        if let f = m.lens.footer.barFraction { XCTAssertTrue((0...1).contains(f)) }
    }

    func testBudgetUsesPropertyScaleWhenGiven() {
        var ctx = LensContext(levelName: "G"); ctx.budgetScaleMaxCents = 1_000_000
        let stats = Fixture.stats(first)
        XCTAssertEqual(BudgetLens().scale(stats, context: ctx).maxValue, 1_000_000)
    }

    func testFormatting() {
        XCTAssertEqual(LensFormat.money(581_000), "$5,810")
        XCTAssertEqual(LensFormat.money(3_168_049), "$31,680")
        XCTAssertEqual(LensFormat.money(-12_345_600), "-$123,456")
        XCTAssertEqual(LensFormat.compact(420_000), "$4.2k")
        XCTAssertEqual(LensFormat.monthYear(LocalDate(2025, 4, 2)), "Apr ’25")
        XCTAssertEqual(LensFormat.primes("12'4\" × 14'0\""), "12′4″ × 14′0″")
    }
}
