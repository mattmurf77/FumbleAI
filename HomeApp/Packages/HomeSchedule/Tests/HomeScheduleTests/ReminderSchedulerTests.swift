import XCTest
import HomeCore
import HomeCoreTesting
@testable import HomeSchedule

final class ReminderSchedulerTests: XCTestCase {
    let today = LocalDate(2026, 9, 29)

    struct Rig {
        let clock: TestClock
        let home: InMemoryHome
        let center: InMemoryNotificationCenter
        let scheduler: ReminderScheduler
    }

    func makeRig(sample: Bool = true, debounce: TimeInterval = 0) -> Rig {
        let clock = TestClock(today)
        let home = sample ? InMemoryHome.sample(clock: clock) : InMemoryHome.empty(clock: clock)
        let center = InMemoryNotificationCenter()
        let scheduler = ReminderScheduler(chores: home.chores, plan: home.plan, inventory: home.inventory, people: home.people,
                                          settings: home.settings, clock: clock, center: center,
                                          localStore: InMemoryKeyValueStore(), debounce: debounce)
        return Rig(clock: clock, home: home, center: center, scheduler: scheduler)
    }

    func testReplanSchedulesPlannerOutputAndIsIdempotent() async throws {
        let rig = makeRig()
        await rig.scheduler.replan(reason: .launch)
        let pending = rig.center.pending
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(pending.allSatisfy { NotificationDiff.isOwned($0.id) })
        XCTAssertTrue(rig.center.categoriesRegistered)
        // Dishes daily at 20:00 → today's reminder id with a body "Kitchen · Alex · Due today".
        let dishes = pending.first { $0.id == PlannedNotification.choreId(SampleHome.dishesId, due: today) }
        XCTAssertEqual(dishes?.body, "Kitchen · Alex · Due today")
        XCTAssertEqual(dishes?.categoryId, PlannedNotification.choreCategory)
        // The overdue furnace filter gets one overdue nudge.
        XCTAssertNotNil(pending.first { $0.id == PlannedNotification.overdueId(SampleHome.filterId) })
        // Gutters have reminders off.
        XCTAssertFalse(pending.contains { $0.choreId == SampleHome.gutterId })

        let adds = rig.center.addCount
        await rig.scheduler.replan(reason: .foreground)
        XCTAssertEqual(rig.center.addCount, adds, "second replan must not re-add anything")
        XCTAssertEqual(rig.center.removeCount, 0)

        // Badge = due today + overdue (dishes + trash on Tuesday + overdue filter).
        XCTAssertEqual(rig.center.badge, 3)
        let status = await rig.scheduler.status()
        XCTAssertEqual(status.pendingCount, pending.count)
        XCTAssertEqual(status.limit, 64)
    }

    func testCompletingRemovesStaleRequestsAndDelivered() async throws {
        let rig = makeRig()
        await rig.scheduler.replan(reason: .launch)
        let todayId = PlannedNotification.choreId(SampleHome.dishesId, due: today)
        rig.center.markDelivered([PlannedNotification.choreId(SampleHome.dishesId, due: today.adding(days: -1))])
        _ = try await rig.home.chores.complete(SampleHome.dishesId, by: nil, at: rig.clock.now)
        await rig.scheduler.replan(reason: .choreChanged)
        XCTAssertFalse(rig.center.pending.contains { $0.id == todayId })
        XCTAssertTrue(rig.center.pending.contains { $0.id == PlannedNotification.choreId(SampleHome.dishesId, due: today.adding(days: 1)) })
        XCTAssertTrue(rig.center.delivered.isEmpty, "yesterday's delivered reminder is stale after completion")
    }

    func testPausedAndDeletedChoresHaveNoPending() async throws {
        let rig = makeRig()
        try await rig.home.chores.setPaused(SampleHome.trashId, true)
        try await rig.home.chores.delete(SampleHome.dishesId)
        await rig.scheduler.replan(reason: .choreChanged)
        XCTAssertFalse(rig.center.pending.contains { $0.choreId == SampleHome.trashId })
        XCTAssertFalse(rig.center.pending.contains { $0.choreId == SampleHome.dishesId })
    }

    /// AC-CHR-7: 80 daily chores → exactly 60 chore reminders, fairness, and a sentinel before the first dropped one.
    func testSixtySlotCapWithSentinel() async throws {
        let rig = makeRig(sample: false)
        let property = Property(name: "Test")
        try await rig.home.plan.saveProperty(property)
        for i in 0..<80 {
            _ = try await rig.home.chores.create(ChoreDraft(propertyId: property.id, scope: .property, title: "Chore \(i)",
                                                            repeatRule: .daily, startOn: today, dueMinutes: 20 * 60, remindEnabled: true))
        }
        await rig.scheduler.replan(reason: .manual)
        let pending = rig.center.pending
        let chorePending = pending.filter { $0.id.hasPrefix("chore:") }
        XCTAssertEqual(chorePending.count, 60)
        XCTAssertTrue(pending.contains { $0.id == PlannedNotification.sentinelId })
        XCTAssertLessThanOrEqual(pending.count, 64)
        // Each chore's first (today's) reminder is scheduled before any chore gets a second.
        XCTAssertEqual(Set(chorePending.compactMap(\.choreId)).count, 60)
    }

    func testSnoozeUsesReservedSlotsMaxTwo() async throws {
        let rig = makeRig()
        await rig.scheduler.snooze(chore: SampleHome.dishesId, for: 3600)
        await rig.scheduler.snooze(chore: SampleHome.trashId, for: 3600)
        await rig.scheduler.snooze(chore: SampleHome.filterId, for: 3600)
        let snoozes = rig.center.pending.filter { $0.id.hasPrefix("sys:snooze-") }
        XCTAssertEqual(snoozes.count, 2)
        XCTAssertEqual(Set(snoozes.compactMap(\.choreId)), [SampleHome.trashId, SampleHome.filterId])
        // Expire.
        rig.clock.advance(days: 1)
        await rig.scheduler.replan(reason: .foreground)
        XCTAssertTrue(rig.center.pending.filter { $0.id.hasPrefix("sys:snooze-") }.isEmpty)
    }

    func testDebounceCoalescesReasons() async throws {
        let rig = makeRig(debounce: 0.2)
        async let a: Void = rig.scheduler.replan(reason: .launch)
        async let b: Void = rig.scheduler.replan(reason: .foreground)
        async let c: Void = rig.scheduler.replan(reason: .choreChanged)
        _ = await (a, b, c)
        let reasons = await rig.scheduler.lastReasons
        XCTAssertEqual(reasons, [.launch, .foreground, .choreChanged])
        XCTAssertFalse(rig.center.pending.isEmpty)
    }

    func testAuthorization() async throws {
        let center = InMemoryNotificationCenter(status: .notDetermined, grantOnRequest: false)
        let home = InMemoryHome.sample(clock: TestClock(today))
        let s = ReminderScheduler(chores: home.chores, plan: home.plan, settings: home.settings, center: center,
                                  localStore: InMemoryKeyValueStore(), debounce: 0)
        let before = await s.authorizationStatus()
        XCTAssertEqual(before, .notDetermined)
        let granted = try await s.requestAuthorization()
        XCTAssertFalse(granted)
        let after = await s.authorizationStatus()
        XCTAssertEqual(after, .denied)
    }

    func testPantryDigestWhenEnabled() async throws {
        let rig = makeRig()
        var settings = await rig.home.settings.load()
        settings.pantryDigestEnabled = true
        await rig.home.settings.save(settings)
        _ = try await rig.home.inventory.create(InventoryDraft(propertyId: SampleHome.propertyId, kind: .pantry, name: "Milk",
                                                               scope: .property, expiresOn: today.adding(days: 1)))
        await rig.scheduler.replan(reason: .settingsChanged)
        XCTAssertTrue(rig.center.pending.contains { $0.id == PlannedNotification.pantryDigestId })
    }
}

final class NotificationActionsTests: XCTestCase {
    let today = LocalDate(2026, 9, 29)

    func testDoneSnoozeAndOpen() async throws {
        let clock = TestClock(today)
        let home = InMemoryHome.sample(clock: clock)
        let center = InMemoryNotificationCenter()
        let scheduler = ReminderScheduler(chores: home.chores, plan: home.plan, settings: home.settings, clock: clock,
                                          center: center, localStore: InMemoryKeyValueStore(), debounce: 0)
        let actions = NotificationActions(chores: home.chores, reminders: scheduler, clock: clock)
        let id = PlannedNotification.choreId(SampleHome.dishesId, due: today)

        // AC-CHR-6: Done from the notification logs a completion and schedules tomorrow.
        let done = await actions.handle(actionIdentifier: PlannedNotification.doneAction, requestIdentifier: id, userInfo: [:])
        XCTAssertEqual(done, .completed(SampleHome.dishesId))
        let completions = try await home.chores.completions(chore: SampleHome.dishesId)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first?.doneBy)
        XCTAssertTrue(center.pending.contains { $0.id == PlannedNotification.choreId(SampleHome.dishesId, due: today.adding(days: 1)) })

        // Snooze from a snooze notification (id without the chore) uses userInfo.
        let snoozed = await actions.handle(actionIdentifier: PlannedNotification.snoozeAction, requestIdentifier: "sys:snooze-1",
                                           userInfo: [NotificationUserInfoKey.choreId: SampleHome.trashId.uuidString])
        XCTAssertEqual(snoozed, .snoozed(SampleHome.trashId))
        XCTAssertTrue(center.pending.contains { $0.id == "sys:snooze-1" && $0.choreId == SampleHome.trashId })

        let open = await actions.handle(actionIdentifier: NotificationActions.defaultActionIdentifier, requestIdentifier: id, userInfo: [:])
        XCTAssertEqual(open, .open(ItemRef.chore(SampleHome.dishesId).deepLink))

        let unknown = await actions.handle(actionIdentifier: "other", requestIdentifier: id, userInfo: [:])
        XCTAssertEqual(unknown, .ignored)
    }

    func testUserInfoRoundTrip() {
        let cid = UUID()
        let n = PlannedNotification(id: "sys:snooze-1", fire: DateComponents(year: 2026, month: 1, day: 1, hour: 9, minute: 0),
                                    title: "t", body: "b", categoryId: "CHORE_DUE", threadId: "x", choreId: cid,
                                    deepLink: ItemRef.chore(cid).deepLink)
        let info: [AnyHashable: Any] = n.userInfo
        XCTAssertEqual(NotificationPayload.choreId(identifier: n.id, userInfo: info), cid)
        XCTAssertEqual(NotificationPayload.hash(from: info), n.contentHash)
        XCTAssertEqual(NotificationPayload.deepLink(identifier: n.id, userInfo: info), ItemRef.chore(cid).deepLink)
    }
}
