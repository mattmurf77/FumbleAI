import Foundation
import HomeCore
#if canImport(EventKit)
import EventKit
#endif

/// One-way EventKit calendar sync with the owner-device model (LLD §9.5, ADR-05). The app is the master: edits push
/// to future events only, past occurrences are never rewritten, and events deleted in the Calendar app turn the
/// chore's calendar toggle off ("Removed from your calendar outside Home") instead of being re-created.
///
/// Only the device whose `DeviceIdentity.deviceId` equals `ChoreCalendarLink.ownerDeviceId` touches EventKit for a
/// chore. Other devices see `.ownedByOtherDevice` and can `adoptOwnership`.
public actor CalendarSync: CalendarSyncing {
    public static let homeCalendarTitle = "Home"
    /// App tint used for the suggested "Home" calendar.
    public static let homeCalendarColorHex = "#2F6FDE"
    public static let otherDeviceFallbackName = "another device"

    private let chores: any ChoreRepository
    private let plan: any PlanRepository
    private let settings: any SettingsRepository
    private let device: any DeviceIdentity
    private let clock: any HomeClock
    private let store: any CalendarStoreProtocol
    private let cache: CalendarEventCache

    /// Last EventKit error (Diagnostics "last calendar error", "Couldn't add to calendar").
    public private(set) var lastError: String?
    private var storeChangeTask: Task<Void, Never>?

    public init(chores: any ChoreRepository,
                plan: any PlanRepository,
                settings: any SettingsRepository,
                device: any DeviceIdentity,
                clock: any HomeClock = SystemClock(),
                store: any CalendarStoreProtocol = makeDefaultCalendarStore(),
                localStore: any LocalKeyValueStore = UserDefaultsKeyValueStore()) {
        self.chores = chores; self.plan = plan; self.settings = settings; self.device = device
        self.clock = clock; self.store = store; self.cache = CalendarEventCache(storage: localStore)
    }

    // MARK: Access & calendars

    public func authorizationStatus() async -> PermissionStatus { store.authorizationStatus() }

    public func requestAccess() async throws -> Bool { try await store.requestFullAccess() }

    public func writableCalendars() async -> [CalendarInfo] {
        guard store.authorizationStatus() == .authorized else { return [] }
        return store.writableCalendars()
    }

    public func createHomeCalendar() async throws -> CalendarInfo {
        guard store.authorizationStatus() == .authorized else { throw CalendarStoreError.accessDenied }
        if let existing = CalendarGroup.existingHome(in: store.writableCalendars()) { return existing }
        do {
            return try store.createCalendar(title: CalendarSync.homeCalendarTitle, colorHex: CalendarSync.homeCalendarColorHex)
        } catch {
            lastError = "createHomeCalendar: \(error)"
            throw error
        }
    }

    // MARK: Ownership

    public func ownership(chore: UUID) async -> CalendarOwnership {
        guard let link = try? await chores.calendarLink(chore: chore), link.deletedAt == nil else { return .notEnabled }
        if link.ownerDeviceId == device.deviceId { return .ownedByThisDevice(calendar: link.calendarTitle) }
        return .ownedByOtherDevice(nickname: CalendarSync.otherDeviceFallbackName)
    }

    /// True when this chore's events were removed in the Calendar app (or its calendar vanished) and the toggle was
    /// switched off. The chore form shows "Removed from your calendar outside Home" and then calls `clearRemovedNote`.
    public func wasRemovedOutsideHome(chore: UUID) -> Bool { cache.removedOutside.contains(chore) }
    public func clearRemovedNote(chore: UUID) { cache.setRemovedOutside(chore, false) }

    // MARK: Enable / disable

    public func enable(chore choreId: UUID, calendarId: String) async throws {
        guard store.authorizationStatus() == .authorized else { throw CalendarStoreError.accessDenied }
        guard var chore = try await chores.chore(choreId), chore.deletedAt == nil else {
            throw RepositoryError.notFound(RecordRef(.chore, choreId))
        }
        guard let calendar = store.calendar(id: calendarId) else { throw CalendarStoreError.calendarNotFound(calendarId) }
        let now = clock.now
        let existing = try? await chores.calendarLink(chore: choreId)

        // Same calendar, already ours with a live event → just push any changes.
        if let existing, existing.ownerDeviceId == device.deviceId, existing.calendarIdentifier == calendarId,
           resolve(existing, chore: chore) != nil {
            await push(choreId)
            await rememberDefault(calendarId)
            return
        }
        // Calendar changed (or taking over): remove the future events from the old calendar first.
        if let existing, let occ = resolve(existing, chore: chore), occ.isFuture {
            try? store.removeFuture(occ, url: chore.deepLink)
        }

        let appSettings = await settings.load()
        var link = ChoreCalendarLink(choreId: choreId, propertyId: chore.propertyId, ownerDeviceId: device.deviceId,
                                     calendarTitle: calendar.title, calendarSourceTitle: calendar.sourceTitle,
                                     calendarIdentifier: calendar.id, eventExternalId: nil,
                                     eventMode: RecurrenceToEK.mode(for: chore.repeatRule), seriesSignature: nil,
                                     createdAt: existing?.createdAt ?? now, updatedAt: now)
        cache.set(chore: choreId, eventIdentifier: nil, at: now)
        if chore.isOpen, let spec = CalendarEventSpec.make(chore: chore, alsoAlert: appSettings.alsoAlertFromCalendar) {
            do {
                let created = try store.create(spec, calendarId: calendar.id)
                link.eventExternalId = created.externalId
                link.eventMode = spec.mode
                link.seriesSignature = spec.signature
                cache.set(chore: choreId, eventIdentifier: created.eventIdentifier, at: now)
            } catch {
                lastError = "enable: \(error)"
                throw error
            }
        }
        try await chores.saveCalendarLink(link)
        cache.setRemovedOutside(choreId, false)
        lastError = nil
        if !chore.calendarEnabled {
            chore.calendarEnabled = true
            try await chores.update(chore)
        }
        await rememberDefault(calendarId)
    }

    public func disable(chore choreId: UUID) async {
        guard let link = try? await chores.calendarLink(chore: choreId) else { return }
        // Non-owner devices leave EventKit alone: the owner removes its events when `calendarEnabled == false`
        // (or the delete) syncs in.
        guard link.ownerDeviceId == device.deviceId else { return }
        let chore = try? await chores.chore(choreId)
        if let occ = resolve(link, chore: chore), occ.isFuture {
            do { try store.removeFuture(occ, url: ItemRef.chore(choreId).deepLink) } catch { lastError = "disable: \(error)" }
        }
        try? await chores.deleteCalendarLink(chore: choreId)
        cache.set(chore: choreId, eventIdentifier: nil, at: clock.now)
    }

    // MARK: Changes

    public func choreChanged(_ id: UUID) async { await push(id) }

    /// Series: no-op (the series already holds the next date). Single: moves a future event to the new due date, or
    /// leaves a past one as history and creates a new event. Both fall out of `push` (single signatures include the
    /// due date; series signatures don't).
    public func choreCompleted(_ id: UUID) async { await push(id) }

    public func adoptOwnership(chore choreId: UUID) async throws {
        guard store.authorizationStatus() == .authorized else { throw CalendarStoreError.accessDenied }
        guard var link = try await chores.calendarLink(chore: choreId) else { return }
        guard let chore = try await chores.chore(choreId) else { throw RepositoryError.notFound(RecordRef(.chore, choreId)) }
        let now = clock.now
        link.ownerDeviceId = device.deviceId
        link.updatedAt = now
        if let occ = resolve(link, chore: chore) {
            link.eventExternalId = occ.externalId ?? link.eventExternalId
            if link.calendarIdentifier == nil { link.calendarIdentifier = occ.calendarId }
            cache.set(chore: choreId, eventIdentifier: occ.eventIdentifier, at: now)
            try await chores.saveCalendarLink(link)
            await push(choreId)
            return
        }
        // Not found on this device: create a fresh series from next_due_on in the link's calendar (or the default).
        let appSettings = await settings.load()
        let calendarId = [link.calendarIdentifier, appSettings.defaultCalendarId].compactMap { $0 }
            .first { store.calendar(id: $0) != nil }
        guard let calendarId, let calendar = store.calendar(id: calendarId) else {
            throw CalendarStoreError.calendarNotFound(link.calendarIdentifier ?? "")
        }
        link.calendarIdentifier = calendar.id
        link.calendarTitle = calendar.title
        link.calendarSourceTitle = calendar.sourceTitle
        link.eventExternalId = nil
        link.seriesSignature = nil
        if chore.isOpen, let spec = CalendarEventSpec.make(chore: chore, alsoAlert: appSettings.alsoAlertFromCalendar) {
            let created = try store.create(spec, calendarId: calendar.id)
            link.eventExternalId = created.externalId
            link.eventMode = spec.mode
            link.seriesSignature = spec.signature
            cache.set(chore: choreId, eventIdentifier: created.eventIdentifier, at: now)
        }
        try await chores.saveCalendarLink(link)
    }

    /// Detects events deleted in the Calendar app and calendars that disappeared (account removed), and pushes any
    /// edits that arrived by sync while the app wasn't running. Runs on `.EKEventStoreChanged` (debounced 2 s) and in
    /// the BG refresh task.
    public func reconcileOwned() async {
        guard store.authorizationStatus() == .authorized,
              let property = try? await plan.currentProperty(),
              let list = try? await chores.chores(ChoreQuery(propertyId: property.id, includeClosed: true, includePaused: true))
        else { return }
        for chore in list where chore.calendarEnabled {
            await push(chore.id, verify: true)
        }
    }

    /// Starts listening for `.EKEventStoreChanged` (debounced 2 s → `reconcileOwned`). Call once after launch.
    public func startObservingStoreChanges() {
        #if canImport(EventKit)
        guard storeChangeTask == nil else { return }
        storeChangeTask = Task { [weak self] in
            var debounce: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                debounce?.cancel()
                debounce = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.reconcileOwned()
                }
            }
        }
        #endif
    }

    // MARK: Core

    /// Brings the owner device's events in line with the chore (LLD §9.5 "Operations").
    /// `verify`: also confirm the events still exist when nothing changed (reconcile).
    private func push(_ choreId: UUID, verify: Bool = false) async {
        guard store.authorizationStatus() == .authorized,
              let link = try? await chores.calendarLink(chore: choreId),
              link.ownerDeviceId == device.deviceId else { return }
        let now = clock.now
        guard let chore = try? await chores.chore(choreId), chore.deletedAt == nil else {
            await disable(chore: choreId)                        // deleted → remove future events, drop the link
            return
        }
        if !chore.calendarEnabled { await disable(chore: choreId); return }

        // Calendar gone (account removed / calendar deleted).
        if let calId = link.calendarIdentifier, store.calendar(id: calId) == nil {
            await removedOutside(chore, link: link)
            return
        }

        var updated = link
        let hasEvent = link.eventExternalId != nil || cache.entry(chore: choreId) != nil

        if chore.isPaused {
            // Paused: remove future events but keep the (dormant) link so this device stays the owner and resumes.
            if hasEvent, let occ = resolve(link, chore: chore), occ.isFuture {
                do { try store.removeFuture(occ, url: chore.deepLink) } catch { lastError = "pause: \(error)"; return }
            }
            if hasEvent {
                updated.eventExternalId = nil; updated.seriesSignature = nil
                cache.set(chore: choreId, eventIdentifier: nil, at: now)
                try? await chores.saveCalendarLink(updated)
            }
            return
        }
        guard chore.closedAt == nil else { return }               // done one-off / finished series: keep history
        let alsoAlert = await settings.load().alsoAlertFromCalendar
        guard let spec = CalendarEventSpec.make(chore: chore, alsoAlert: alsoAlert),
              let calendarId = link.calendarIdentifier else { return }

        do {
            if !hasEvent {
                // Resumed (or enabled before a due date existed): create from next_due_on.
                let created = try store.create(spec, calendarId: calendarId)
                apply(created, spec: spec, to: &updated, at: now)
            } else if link.seriesSignature == spec.signature && link.eventMode == spec.mode {
                // Nothing to push; on reconcile, detect events deleted in the Calendar app.
                if verify, resolve(link, chore: chore) == nil { await removedOutside(chore, link: link) }
                return
            } else {
                guard let occ = resolve(link, chore: chore) else {
                    await removedOutside(chore, link: link)
                    return
                }
                if spec.mode != link.eventMode {
                    // series ↔ single: end the old shape, start the new one.
                    if occ.isFuture { try store.removeFuture(occ, url: chore.deepLink) }
                    let created = try store.create(spec, calendarId: calendarId)
                    apply(created, spec: spec, to: &updated, at: now)
                } else if occ.isFuture {
                    let saved = try store.update(occ, url: chore.deepLink, with: splitSpec(spec, chore: chore, at: occ.occurrenceDay))
                    apply(saved, spec: spec, to: &updated, at: now)
                } else {
                    // Only past events remain: leave them as history and start fresh at next_due_on.
                    let created = try store.create(spec, calendarId: calendarId)
                    apply(created, spec: spec, to: &updated, at: now)
                }
            }
            try await chores.saveCalendarLink(updated)
            lastError = nil
        } catch {
            lastError = "push: \(error)"
        }
    }

    /// For a `.futureEvents` edit the new part must not start before the occurrence being edited (an overdue chore's
    /// `next_due_on` can be earlier), so it starts at the first occurrence of the (new) rule on or after that day.
    private func splitSpec(_ spec: CalendarEventSpec, chore: Chore, at day: LocalDate) -> CalendarEventSpec {
        guard spec.recurrence != nil, spec.startDay < day else { return spec }
        var s = spec
        if let rule = chore.repeatRule {
            let engine = RecurrenceEngine(calendar: clock.calendar)
            s.startDay = engine.occurrences(of: rule, start: chore.startOn, from: day).first(where: { _ in true }) ?? day
        } else {
            s.startDay = day
        }
        return s
    }

    private func apply(_ r: ResolvedEvent, spec: CalendarEventSpec, to link: inout ChoreCalendarLink, at now: Date) {
        link.eventExternalId = r.externalId ?? link.eventExternalId
        link.eventMode = spec.mode
        link.seriesSignature = spec.signature
        link.updatedAt = now
        cache.set(chore: link.choreId, eventIdentifier: r.eventIdentifier, at: now)
    }

    private func resolve(_ link: ChoreCalendarLink, chore: Chore?) -> ResolvedEvent? {
        let today = LocalDate(clock.now, calendar: clock.calendar)
        let loc = EventLocator(url: ItemRef.chore(link.choreId).deepLink, eventIdentifier: cache.entry(chore: link.choreId)?.eventIdentifier,
                               externalId: link.eventExternalId, calendarId: link.calendarIdentifier, today: today)
        let r = store.resolve(loc)
        if let r { cache.set(chore: link.choreId, eventIdentifier: r.eventIdentifier, at: clock.now) }
        return r
    }

    /// Step 4 of resolution: the user deleted the events in the Calendar app. Never re-create.
    private func removedOutside(_ chore: Chore, link: ChoreCalendarLink) async {
        try? await chores.deleteCalendarLink(chore: chore.id)
        cache.set(chore: chore.id, eventIdentifier: nil, at: clock.now)
        cache.setRemovedOutside(chore.id, true)
        if chore.calendarEnabled {
            var c = chore
            c.calendarEnabled = false
            try? await chores.update(c)
        }
    }

    private func rememberDefault(_ calendarId: String) async {
        var s = await settings.load()
        guard s.defaultCalendarId != calendarId else { return }
        s.defaultCalendarId = calendarId
        await settings.save(s)
    }
}
