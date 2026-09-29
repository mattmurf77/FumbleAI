import XCTest
import HomeCore
import HomeCoreTesting
@testable import HomeSchedule

final class CalendarSyncTests: XCTestCase {
    let today = LocalDate(2026, 9, 29)   // Tuesday

    struct Rig {
        let clock: TestClock
        let home: InMemoryHome
        let store: InMemoryCalendarStore
        let sync: CalendarSync
        let local: InMemoryKeyValueStore
    }

    func makeRig(deviceId: String = "phone-a", store: InMemoryCalendarStore? = nil, home: InMemoryHome? = nil,
                 clock: TestClock? = nil) -> Rig {
        let clock = clock ?? TestClock(today)
        let home = home ?? InMemoryHome.sample(clock: clock)
        let store = store ?? InMemoryCalendarStore(calendar: clock.calendar)
        let local = InMemoryKeyValueStore()
        let sync = CalendarSync(chores: home.chores, plan: home.plan, settings: home.settings,
                                device: StaticDeviceIdentity(deviceId: deviceId, nickname: deviceId), clock: clock,
                                store: store, localStore: local)
        return Rig(clock: clock, home: home, store: store, sync: sync, local: local)
    }

    var trashURL: URL { ItemRef.chore(SampleHome.trashId).deepLink }

    func testCreateHomeCalendarPrefersICloudAndReusesExisting() async throws {
        let rig = makeRig()
        let home = try await rig.sync.createHomeCalendar()
        XCTAssertEqual(home.title, "Home")
        XCTAssertEqual(home.sourceTitle, "iCloud")
        let again = try await rig.sync.createHomeCalendar()
        XCTAssertEqual(again.id, home.id)
        let cals = await rig.sync.writableCalendars()
        XCTAssertTrue(cals.contains { $0.sourceTitle.hasPrefix("Gmail") })   // Google accounts on the device are listed
    }

    func testEnableSeriesWritesLinkAndEvents() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-house")
        let link = try await rig.home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertEqual(link?.ownerDeviceId, "phone-a")
        XCTAssertEqual(link?.eventMode, .series)
        XCTAssertEqual(link?.calendarTitle, "House")
        XCTAssertNotNil(link?.eventExternalId)
        XCTAssertNotNil(link?.seriesSignature)
        let chore = try await rig.home.chores.chore(SampleHome.trashId)
        XCTAssertEqual(chore?.calendarEnabled, true)
        let settings = await rig.home.settings.load()
        XCTAssertEqual(settings.defaultCalendarId, "cal-house")
        let ownership = await rig.sync.ownership(chore: SampleHome.trashId)
        XCTAssertEqual(ownership, .ownedByThisDevice(calendar: "House"))

        // Tue + Fri at 19:00.
        let occ = rig.store.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 13))
        XCTAssertEqual(occ.map(\.day.weekday), [3, 6, 3, 6])
        XCTAssertTrue(occ.allSatisfy { $0.minutes == 19 * 60 })

        // Completing a series chore does nothing to the calendar.
        let before = rig.store.events
        _ = try await rig.home.chores.complete(SampleHome.trashId, by: nil, at: rig.clock.now)
        await rig.sync.choreCompleted(SampleHome.trashId)
        XCTAssertEqual(rig.store.events, before)
    }

    /// AC-CHR-9: time change moves future events only.
    func testEditUpdatesFutureOnlyAndPastKeepsOldTime() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
        rig.clock.set(today.adding(days: 7))                      // a week later
        var chore = try await rig.home.chores.chore(SampleHome.trashId)!
        chore.dueMinutes = 20 * 60
        try await rig.home.chores.update(chore)
        await rig.sync.choreChanged(SampleHome.trashId)

        let occ = rig.store.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 20))
        let past = occ.filter { $0.day < today.adding(days: 7) }
        let future = occ.filter { $0.day >= today.adding(days: 7) }
        XCTAssertFalse(past.isEmpty)
        XCTAssertTrue(past.allSatisfy { $0.minutes == 19 * 60 })
        XCTAssertFalse(future.isEmpty)
        XCTAssertTrue(future.allSatisfy { $0.minutes == 20 * 60 })
        XCTAssertEqual(Set(occ.map(\.day)).count, occ.count, "no duplicate occurrences after the split")
    }

    /// AC-CHR-10: delete removes future events; past stay.
    func testDeleteRemovesFutureKeepsPast() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
        rig.clock.set(today.adding(days: 7))
        try await rig.home.chores.delete(SampleHome.trashId)
        await rig.sync.disable(chore: SampleHome.trashId)
        let occ = rig.store.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 30))
        XCTAssertFalse(occ.isEmpty)
        XCTAssertTrue(occ.allSatisfy { $0.day < today.adding(days: 7) })
        let link = try await rig.home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertNil(link)
    }

    /// AC-CHR-11: events deleted in the Calendar app → toggle off + note, never re-created.
    func testDeletedOutsideHomeTurnsToggleOff() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
        rig.store.deleteAllEvents(url: trashURL)
        await rig.sync.reconcileOwned()
        let chore = try await rig.home.chores.chore(SampleHome.trashId)
        XCTAssertEqual(chore?.calendarEnabled, false)
        let link = try await rig.home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertNil(link)
        let removed = await rig.sync.wasRemovedOutsideHome(chore: SampleHome.trashId)
        XCTAssertTrue(removed)
        XCTAssertTrue(rig.store.events.isEmpty)
        await rig.sync.clearRemovedNote(chore: SampleHome.trashId)
        let cleared = await rig.sync.wasRemovedOutsideHome(chore: SampleHome.trashId)
        XCTAssertFalse(cleared)
    }

    func testCalendarRemovedTurnsToggleOff() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-house")
        rig.store.removeCalendar(id: "cal-house")
        await rig.sync.reconcileOwned()
        let chore = try await rig.home.chores.chore(SampleHome.trashId)
        XCTAssertEqual(chore?.calendarEnabled, false)
    }

    /// AC-CHR-12: a non-owner device never writes to the calendar.
    func testNonOwnerDoesNotTouchEventKit() async throws {
        let clock = TestClock(today)
        let home = InMemoryHome.sample(clock: clock)
        let storeA = InMemoryCalendarStore(calendar: clock.calendar)
        let storeB = InMemoryCalendarStore(calendar: clock.calendar)
        let a = makeRig(deviceId: "phone-a", store: storeA, home: home, clock: clock)
        let b = makeRig(deviceId: "phone-b", store: storeB, home: home, clock: clock)
        try await a.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")

        var chore = try await home.chores.chore(SampleHome.trashId)!
        chore.title = "Trash + recycling"
        try await home.chores.update(chore)
        await b.sync.choreChanged(SampleHome.trashId)
        XCTAssertTrue(storeB.events.isEmpty)
        let own = await b.sync.ownership(chore: SampleHome.trashId)
        XCTAssertEqual(own, .ownedByOtherDevice(nickname: CalendarSync.otherDeviceFallbackName))
        await b.sync.disable(chore: SampleHome.trashId)
        let stillLinked = try await home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertNotNil(stillLinked, "non-owner leaves the link for the owner")

        // The owner applies the synced edit.
        await a.sync.choreChanged(SampleHome.trashId)
        XCTAssertTrue(storeA.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 7)).allSatisfy { $0.title == "Trash + recycling" })

        // "Manage from this iPhone" on B: nothing found in B's store → fresh series.
        try await b.sync.adoptOwnership(chore: SampleHome.trashId)
        let link = try await home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertEqual(link?.ownerDeviceId, "phone-b")
        XCTAssertFalse(storeB.events.isEmpty)
    }

    /// FR-CHR-57: completion-anchored single event moves when in the future; past ones stay as history.
    func testCompletionAnchoredSingleEvent() async throws {
        let rig = makeRig()
        // Furnace filter: every 90 days after done, 3 days overdue.
        try await rig.sync.enable(chore: SampleHome.filterId, calendarId: "cal-family")
        let link = try await rig.home.chores.calendarLink(chore: SampleHome.filterId)
        XCTAssertEqual(link?.eventMode, .single)
        let url = ItemRef.chore(SampleHome.filterId).deepLink
        XCTAssertEqual(rig.store.events.count, 1)

        _ = try await rig.home.chores.complete(SampleHome.filterId, by: nil, at: rig.clock.now)
        await rig.sync.choreCompleted(SampleHome.filterId)
        let days = rig.store.occurrenceDays(url: url, from: today.adding(days: -30), to: today.adding(days: 120)).map(\.day)
        // The past (overdue) event stays as history; a new one at the new due date.
        XCTAssertEqual(days, [today.adding(days: -3), today.adding(days: 90)])

        // Reschedule the (future) event: it moves rather than duplicating.
        try await rig.home.chores.reschedule(SampleHome.filterId, to: today.adding(days: 95))
        await rig.sync.choreChanged(SampleHome.filterId)
        let moved = rig.store.occurrenceDays(url: url, from: today.adding(days: -30), to: today.adding(days: 120)).map(\.day)
        XCTAssertEqual(moved, [today.adding(days: -3), today.adding(days: 95)])
    }

    /// AC-CHR-16 / FR-CHR-26: pause removes future events; resume recreates from next due.
    func testPauseAndResume() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
        try await rig.home.chores.setPaused(SampleHome.trashId, true)
        await rig.sync.choreChanged(SampleHome.trashId)
        XCTAssertTrue(rig.store.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 30)).isEmpty)
        let dormant = try await rig.home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertEqual(dormant?.ownerDeviceId, "phone-a")
        XCTAssertNil(dormant?.eventExternalId)

        try await rig.home.chores.setPaused(SampleHome.trashId, false)
        await rig.sync.choreChanged(SampleHome.trashId)
        XCTAssertFalse(rig.store.occurrenceDays(url: trashURL, from: today, to: today.adding(days: 30)).isEmpty)
    }

    func testChangingCalendarMovesFutureEvents() async throws {
        let rig = makeRig()
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
        try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-house")
        let calendars = Set(rig.store.events.map(\.calendarId))
        XCTAssertEqual(calendars, ["cal-house"])
        let link = try await rig.home.chores.calendarLink(chore: SampleHome.trashId)
        XCTAssertEqual(link?.calendarIdentifier, "cal-house")
    }

    func testAccessDenied() async throws {
        let rig = makeRig(store: InMemoryCalendarStore(status: .denied))
        do {
            try await rig.sync.enable(chore: SampleHome.trashId, calendarId: "cal-family")
            XCTFail("expected accessDenied")
        } catch let e as CalendarStoreError {
            XCTAssertEqual(e, .accessDenied)
        }
        let cals = await rig.sync.writableCalendars()
        XCTAssertTrue(cals.isEmpty)
    }
}
