import Foundation
import HomeCore

/// Local-notification scheduler (LLD §9.3). Runs the pure `NotificationPlanner` (60 chore slots over 14 days +
/// sentinel + pantry digest + 2 snoozes) and diffs its output against the pending requests by stable identifier and
/// content hash, so a replan with nothing changed touches nothing.
///
/// Replans are debounced (500 ms by default) and coalesced: callers that arrive while a replan is waiting share it.
/// Also implements `NotificationAuthorizing` so the composition root can use one instance for both.
public actor ReminderScheduler: ReminderScheduling, NotificationAuthorizing {
    private let chores: any ChoreRepository
    private let plan: any PlanRepository
    private let inventory: (any InventoryRepository)?
    private let people: (any PeopleRepository)?
    private let settings: any SettingsRepository
    private let clock: any HomeClock
    private let center: any NotificationCenterProtocol
    private let snoozes: SnoozeStore
    private let debounceNanos: UInt64

    private var pendingReasons: Set<ReplanReason> = []
    private var waiting: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var lastReplanAt: Date?
    private var categoriesRegistered = false

    /// Last scheduling error (Diagnostics: "last error").
    public private(set) var lastError: String?
    /// Reasons handled by the most recent replan (diagnostics / tests).
    public private(set) var lastReasons: Set<ReplanReason> = []
    /// The desired set produced by the most recent replan.
    public private(set) var lastPlan: [PlannedNotification] = []

    public init(chores: any ChoreRepository,
                plan: any PlanRepository,
                inventory: (any InventoryRepository)? = nil,
                people: (any PeopleRepository)? = nil,
                settings: any SettingsRepository,
                clock: any HomeClock = SystemClock(),
                center: any NotificationCenterProtocol = makeDefaultNotificationCenter(),
                localStore: any LocalKeyValueStore = UserDefaultsKeyValueStore(),
                debounce: TimeInterval = 0.5) {
        self.chores = chores; self.plan = plan; self.inventory = inventory; self.people = people
        self.settings = settings; self.clock = clock; self.center = center
        self.snoozes = SnoozeStore(storage: localStore)
        self.debounceNanos = UInt64(max(0, debounce) * 1_000_000_000)
    }

    // MARK: ReminderScheduling

    public func replan(reason: ReplanReason) async {
        pendingReasons.insert(reason)
        if let waiting { await waiting.value; return }
        let delay = debounceNanos
        let t = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            await self?.fire()
        }
        waiting = t
        await t.value
    }

    /// Replans immediately, bypassing the debounce (tests, notification actions that must finish within ~5 s).
    public func replanNow(reason: ReplanReason = .manual) async {
        pendingReasons.insert(reason)
        await fire()
    }

    public func status() async -> ReminderStatus {
        let pending = await center.pendingRequests().filter { NotificationDiff.isOwned($0.id) }.count
        return ReminderStatus(pendingCount: pending, limit: NotificationPlanner.iOSLimit,
                              authorization: await center.authorizationStatus(), lastReplanAt: lastReplanAt)
    }

    public func snooze(chore: UUID, for seconds: TimeInterval) async {
        let now = clock.now
        let title = (try? await chores.chore(chore))?.title ?? "Reminder"
        snoozes.add(Snooze(choreId: chore, title: title, fireAt: now.addingTimeInterval(seconds), createdAt: now))
        await replanNow(reason: .notificationAction)
    }

    // MARK: NotificationAuthorizing

    public func authorizationStatus() async -> PermissionStatus { await center.authorizationStatus() }

    public func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization()
        if granted { await replanNow(reason: .settingsChanged) }
        return granted
    }

    // MARK: Internals

    private func fire() async {
        waiting = nil
        let reasons = pendingReasons
        pendingReasons = []
        let previous = running
        let t = Task { [weak self] in
            await previous?.value
            await self?.perform(reasons: reasons)
        }
        running = t
        await t.value
    }

    private func perform(reasons: Set<ReplanReason>) async {
        if !categoriesRegistered { await center.registerCategories(); categoriesRegistered = true }
        let now = clock.now
        let calendar = clock.calendar
        let today = LocalDate(now, calendar: calendar)
        let appSettings = await settings.load()

        let property: Property?
        do { property = try await plan.currentProperty() } catch {
            lastError = "property: \(error)"
            return                       // don't wipe reminders on a read error
        }

        var allChores: [Chore] = []
        var inputs: [ChoreReminderInput] = []
        var pantryCount = 0
        if let property {
            do {
                allChores = try await chores.chores(ChoreQuery(propertyId: property.id, includeClosed: true, includePaused: true))
            } catch {
                lastError = "chores: \(error)"
                return
            }
            let names = await locationNames(property: property.id)
            let peopleNames = await personNames(property: property.id)
            inputs = allChores.map { c in
                ChoreReminderInput(chore: c, location: ReminderScheduler.bodyPrefix(scope: c.scope, assignee: c.assigneeId,
                                                                                   names: names, people: peopleNames))
            }
            if appSettings.pantryDigestEnabled, let inventory {
                let items = (try? await inventory.items(InventoryQuery(propertyId: property.id, kind: .pantry))) ?? []
                pantryCount = items.filter { $0.deletedAt == nil && $0.isExpiring(today: today, withinDays: 3) }.count
            }
        }

        let active = snoozes.active(now: now)
        let desired = NotificationPlanner(allDayMinutes: appSettings.defaultAllDayMinutes)
            .plan(chores: inputs, snoozes: active,
                  pantryDigest: appSettings.pantryDigestEnabled ? PantryDigest(expiringCount: pantryCount) : nil,
                  now: now, calendar: calendar, engine: RecurrenceEngine(calendar: calendar))

        let pending = await center.pendingRequests()
        let diff = NotificationDiff.diff(desired: desired, pending: pending)
        await center.removePending(ids: diff.remove)
        var failures: [String] = []
        for n in diff.add {
            do { try await center.add(n) } catch { failures.append("\(n.id): \(error)") }
        }
        let stale = NotificationDiff.staleDelivered(await center.deliveredIdentifiers(), chores: allChores, today: today)
        await center.removeDelivered(ids: stale)

        let badge = appSettings.badgeEnabled ? NotificationPlanner.badgeCount(chores: allChores, today: today) : 0
        await center.setBadgeCount(badge)

        lastError = failures.isEmpty ? nil : failures.joined(separator: "; ")
        lastReplanAt = now
        lastReasons = reasons
        lastPlan = desired
    }

    private struct Names { var spaces: [UUID: String] = [:]; var levels: [UUID: String] = [:] }

    private func locationNames(property: UUID) async -> Names {
        var n = Names()
        if let spaces = try? await plan.spaces(property: property) {
            for s in spaces where s.deletedAt == nil { n.spaces[s.id] = s.name }
        }
        if let levels = try? await plan.levels(property: property) {
            for l in levels where l.deletedAt == nil { n.levels[l.id] = l.name }
        }
        return n
    }

    private func personNames(property: UUID) async -> [UUID: String] {
        guard let people, let list = try? await people.people(property: property) else { return [:] }
        return Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Notification body prefix: "Kitchen · Matt" (FR-CHR-42).
    private static func bodyPrefix(scope: Scope, assignee: UUID?, names: Names, people: [UUID: String]) -> String? {
        let place: String?
        switch scope {
        case .space(let s, _): place = names.spaces[s]
        case .level(let l): place = names.levels[l]
        case .property: place = "Whole house"
        }
        let who = assignee.flatMap { people[$0] }
        let parts = [place, who].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
