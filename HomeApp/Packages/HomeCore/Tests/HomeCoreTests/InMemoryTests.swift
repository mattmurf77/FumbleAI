import XCTest
import PlanKit
@testable import HomeCore
@testable import HomeCoreTesting

final class InMemoryRepositoryTests: XCTestCase {
    let today = LocalDate(2026, 9, 29)
    var clock: FixedClock { FixedClock(today, minutes: 8 * 60) }
    func makeHome() -> InMemoryHome { InMemoryHome.sample(clock: clock) }

    func testSampleLoadsAndDefaultLevel() async throws {
        let home = makeHome()
        let p = try await home.plan.currentProperty()
        XCTAssertEqual(p?.id, SampleHome.propertyId)
        let levels = try await home.plan.levels(property: SampleHome.propertyId)
        XCTAssertEqual(levels.map(\.name), ["Basement", "1st Floor", "2nd Floor", "Outside"])
        XCTAssertEqual(levels.defaultLevel(preferred: p?.defaultLevelId)?.id, SampleHome.firstFloorId)
        let g = try await home.plan.geometry(level: SampleHome.firstFloorId)
        XCTAssertEqual(g.spaces.count, 6)
        // Sample plan is valid: walls derive and no interior overlaps.
        let walls = WallDerivation.walls(spaces: g.interiorSpaces.map(\.identifiedPolygon), openings: g.openings.map(\.segment))
        XCTAssertFalse(walls.filter { $0.kind == .interior }.isEmpty)
        for a in g.interiorSpaces { for b in g.interiorSpaces where a.id != b.id { XCTAssertFalse(Clip.overlaps(a.polygon, b.polygon), "\(a.name)/\(b.name)") } }
    }

    func testObserveEmitsAfterWrite() async throws {
        let home = makeHome()
        let stream = home.chores.observeChores(ChoreQuery(propertyId: SampleHome.propertyId))
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.count, 5)
        _ = try await home.chores.create(ChoreDraft(propertyId: SampleHome.propertyId, scope: .property, title: "Mow", startOn: today))
        let second = await it.next()
        XCTAssertEqual(second?.count, 6)
    }

    func testCompleteRecurringAndOneOff() async throws {
        let home = makeHome()
        let at = clock.now
        _ = try await home.chores.complete(SampleHome.filterId, by: SampleHome.mattId, at: at)
        let filter = try await home.chores.chore(SampleHome.filterId)
        XCTAssertEqual(filter?.nextDueOn, today.adding(days: 90))
        _ = try await home.chores.complete(SampleHome.gutterId, by: nil, at: at)
        let open = try await home.chores.chores(ChoreQuery(propertyId: SampleHome.propertyId))
        XCTAssertFalse(open.contains { $0.id == SampleHome.gutterId })
        let completions = try await home.chores.completions(chore: SampleHome.filterId)
        XCTAssertEqual(completions.count, 1)
    }

    func testEventsPublishedAfterCommit() async throws {
        let home = makeHome()
        var events = home.store.bus.events.makeAsyncIterator()
        _ = try await home.chores.complete(SampleHome.dishesId, by: nil, at: clock.now)
        let e = await events.next()
        XCTAssertEqual(e, .choreCompleted(SampleHome.dishesId))
        XCTAssertTrue(e?.affectsChores ?? false)
    }

    func testSearchWhereIs() async throws {
        let home = makeHome()
        let hits = try await home.search.search("winter co", property: SampleHome.propertyId)
        let top = try XCTUnwrap(hits.first)
        XCTAssertEqual(top.title, "Winter coat")
        XCTAssertTrue(top.qualifiesForWhereIsCard)
        XCTAssertEqual(top.location, "Storage › Shelf 2 › Bin Winter – Matt · Basement")
        XCTAssertEqual(top.people, "Matt")
        let furnace = try await home.search.search("16x25", property: SampleHome.propertyId)
        XCTAssertTrue(furnace.contains { $0.entityType == .thing && $0.title == "Furnace" })
        let none = try await home.search.search("*()", property: SampleHome.propertyId)
        XCTAssertTrue(none.isEmpty)
    }

    func testLensStatsAndRollups() async throws {
        let home = makeHome()
        let s = InMemoryLensStatsService.compute(home.store.read { $0 }, level: SampleHome.basementId, today: today)
        XCTAssertEqual(s.stats(for: SampleHome.utilityId).overdue, 1)
        XCTAssertEqual(s.stats(for: SampleHome.storageId).inventoryCount, 3)
        XCTAssertEqual(s.stats(for: SampleHome.storageId).lowCount, 1)
        XCTAssertEqual(s.spotPins.first?.itemCount, 3)
        let first = InMemoryLensStatsService.compute(home.store.read { $0 }, level: SampleHome.firstFloorId, today: today)
        XCTAssertEqual(first.stats(for: SampleHome.kitchenId).thingCount, 1)
        XCTAssertEqual(first.stats(for: SampleHome.kitchenId).plannedThingCount, 1)
        XCTAssertEqual(first.stats(for: SampleHome.kitchenId).warrantiesEndingSoon, 1)
        XCTAssertEqual(first.stats(for: SampleHome.kitchenId).rollup.plannedCents, 3_600_00)
        XCTAssertEqual(first.roomCount, 6)
        var it = home.rollups.observeProperty(SampleHome.propertyId).makeAsyncIterator()
        let pr_ = await it.next()
        let pr = try XCTUnwrap(pr_)
        XCTAssertEqual(pr.total.lifetimeCents, 12_100_00)
        XCTAssertEqual(pr.wholeHouse.ideaCents, 8_000_00)
        XCTAssertEqual(pr.levels.map(\.levelName), ["Basement", "1st Floor", "2nd Floor", "Outside"])
    }

    func testInventoryQueries() async throws {
        let home = makeHome()
        var shop = home.inventory.observeShoppingList(property: SampleHome.propertyId, on: today).makeAsyncIterator()
        let lines_ = await shop.next()
        let lines = try XCTUnwrap(lines_)
        XCTAssertEqual(Set(lines.map(\.label)), ["Furnace filter 16x25x1 MERV 11", "Olive oil"])
        var swap = home.inventory.observeSeasonalSwap(property: SampleHome.propertyId, on: today).makeAsyncIterator()
        let sw_ = await swap.next()
        let sw = try XCTUnwrap(sw_)
        XCTAssertEqual(sw.upcoming, .winter)
        XCTAssertEqual(sw.getOut.map(\.name), ["Snow boots", "Winter coat"])
        XCTAssertEqual(sw.putAway.map(\.name), ["Swim trunks"])
        let loc = try await home.inventory.locations(of: [SampleHome.id(120)])
        XCTAssertEqual(loc.first?.displayPath, "Storage › Shelf 2 › Bin Winter – Matt")
        // Cycle guard.
        do { try await home.inventory.reparentSpot(SampleHome.shelfId, to: SampleHome.winterBinId); XCTFail("expected cycle") }
        catch { XCTAssertEqual(error as? RepositoryError, .cycle) }
        // Quantity → low flag.
        try await home.inventory.adjustQuantity(SampleHome.id(123), by: 3)
        let filter = try await home.inventory.item(SampleHome.id(123))
        XCTAssertEqual(filter?.isLow, false)
        var tree = home.inventory.observeSpotTree(space: SampleHome.storageId).makeAsyncIterator()
        let nodes_ = await tree.next()
        let nodes = try XCTUnwrap(nodes_)
        XCTAssertEqual(nodes.first?.subtreeItemCount, 3)
        XCTAssertEqual(nodes.first?.children.first?.path, "Shelf 2 › Bin Winter – Matt")
    }

    func testOverlapRuleAndCommitDraft() async throws {
        let home = makeHome()
        let overlapping = Space(propertyId: SampleHome.propertyId, levelId: SampleHome.firstFloorId, name: "Bad",
                                polygon: Polygon(rect: Rect(x: 12, y: 12, width: 60, height: 60)))
        do { try await home.plan.updateSpaces([.insert(overlapping)]); XCTFail("expected overlap") }
        catch { guard case RepositoryError.overlap = error else { return XCTFail("\(error)") } }

        let empty = InMemoryHome.empty(clock: clock)
        let prop = Property(name: "New")
        try await empty.plan.saveProperty(prop)
        let draft = StubRoughInGenerator().draft(RoughInInput(floors: 2, hasBasement: false, approxSqFt: 1800, bedrooms: 3, bathrooms: 2))
        let ids = try await empty.plan.commit(draft, into: prop.id, acceptedSuggestions: [])
        XCTAssertEqual(ids.count, 2)
        let g = try await empty.plan.geometry(level: ids[0])
        XCTAssertTrue(g.spaces.allSatisfy { $0.isApproximate && $0.source == .rough })
        let current = try await empty.plan.currentProperty()
        XCTAssertEqual(current?.defaultLevelId, ids[0])
    }

    func testDeleteRoomReassignsAndRestore() async throws {
        let home = makeHome()
        try await home.plan.deleteSpace(SampleHome.utilityId, reassignItemsTo: .level(SampleHome.basementId))
        let furnace = try await home.things.thing(SampleHome.furnaceId)
        XCTAssertEqual(furnace?.scope, .level(SampleHome.basementId))
        let deleted = try await home.recentlyDeleted.deleted(property: SampleHome.propertyId)
        XCTAssertEqual(deleted.first?.title, "Utility")
        try await home.recentlyDeleted.restore(RecordRef(.space, SampleHome.utilityId))
        let restored = try await home.plan.space(SampleHome.utilityId)
        XCTAssertNotNil(restored)
    }

    func testFitReports() async throws {
        let home = makeHome()
        let reports = try await home.things.fit(for: SampleHome.plannedFridgeId)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first { $0.role == .target }?.result.overall, .noFit)   // 36 + 1 in clearance > 36
        XCTAssertEqual(reports.first { $0.role == .deliveryPath }?.result.overall, .fits)
    }

    func testReminderSchedulerPlansFromStore() async throws {
        let home = makeHome()
        await home.reminders.replan(reason: .launch)
        let planned = home.reminders.planned
        XCTAssertTrue(planned.contains { $0.id == PlannedNotification.overdueId(SampleHome.filterId) })
        XCTAssertFalse(planned.contains { $0.choreId == SampleHome.gutterId }, "reminder off")
        XCTAssertLessThanOrEqual(planned.count, 64)
    }

    func testProjectsFlow() async throws {
        let home = makeHome()
        try await home.projects.markDone(SampleHome.fridgeProjectId, actual: Money(cents: 2_199_00), completedOn: today, hours: 3, receipt: nil)
        let past = try await home.projects.projects(.past(SampleHome.propertyId))
        XCTAssertEqual(Set(past.map(\.id)), [SampleHome.bathRemodelId, SampleHome.fridgeProjectId])
        let project = try await home.chores.turnIntoProject(SampleHome.gutterId)
        XCTAssertEqual(project.spawnedFromChoreId, SampleHome.gutterId)
        XCTAssertEqual(project.status, .idea)
    }

    func testExportWritesCSV() async throws {
        let home = makeHome()
        let dir = try await home.export.exportCSV(property: SampleHome.propertyId, options: ExportOptions())
        let people = try String(contentsOf: dir.appendingPathComponent("people.csv"), encoding: .utf8)
        XCTAssertTrue(people.contains("Matt"))
    }
}
