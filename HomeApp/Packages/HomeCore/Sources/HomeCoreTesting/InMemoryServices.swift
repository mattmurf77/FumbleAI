import Foundation
import HomeCore
import PlanKit

// MARK: - Search

/// Token-prefix search over the in-memory rows (mirrors FTS semantics: AND prefix, fallback OR, ≤ 50 hits).
public struct InMemorySearchService: SearchService {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    struct Doc { var type: SearchEntityType; var id: UUID; var title: String; var body: String; var location: String?; var people: String? }

    static func docs(_ s: InMemorySnapshot, property: UUID) -> [Doc] {
        var d: [Doc] = []
        for c in s.liveChores where c.propertyId == property {
            d.append(Doc(type: .chore, id: c.id, title: c.title,
                         body: [c.notes, c.repeatRule?.humanText, c.linkedThingId.flatMap { s.things[$0]?.name }].compactMap { $0 }.joined(separator: " "),
                         location: s.locationText(c.scope), people: s.personName(c.assigneeId)))
        }
        for p in s.liveProjects where p.propertyId == property {
            let lines = s.liveLineItems.filter { $0.projectId == p.id }.map(\.label)
            let ocr = s.liveAttachments.filter { $0.ownerId == p.id }.compactMap(\.ocrText)
            d.append(Doc(type: .project, id: p.id, title: p.title,
                         body: ([p.notes, p.vendor, p.status.displayName].compactMap { $0 } + lines + ocr).joined(separator: " "),
                         location: s.locationText(p.scope), people: nil))
        }
        for t in s.liveThings where t.propertyId == property {
            let attrs = t.attributes.values.map(\.displayText)
            d.append(Doc(type: .thing, id: t.id, title: t.name,
                         body: ([t.brand, t.model, t.serial, t.template?.name, t.notes].compactMap { $0 } + attrs).joined(separator: " "),
                         location: s.locationText(t.scope), people: nil))
        }
        for i in s.liveInventory where i.propertyId == property {
            let loc = [s.spaceName(i.scope.spaceId), s.spotPath(i.storageSpotId)].compactMap { $0 }.joined(separator: " › ")
            let floor = s.levelName(i.scope.levelId)
            d.append(Doc(type: .inventoryItem, id: i.id, title: i.name,
                         body: [i.category, i.season?.rawValue, i.notes, i.unit].compactMap { $0 }.joined(separator: " "),
                         location: [loc.isEmpty ? nil : loc, floor].compactMap { $0 }.joined(separator: " · "),
                         people: s.personName(i.ownerId)))
        }
        for m in s.liveMeasurements where m.propertyId == property {
            d.append(Doc(type: .measurement, id: m.id, title: m.label, body: [m.dims.formatted(), m.note].compactMap { $0 }.joined(separator: " "),
                         location: s.spaceName(m.spaceId), people: nil))
        }
        for sp in s.liveSpaces where sp.propertyId == property {
            d.append(Doc(type: .space, id: sp.id, title: sp.name, body: sp.spaceType.displayName, location: s.levelName(sp.levelId), people: nil))
        }
        for spot in s.liveSpots where spot.propertyId == property {
            d.append(Doc(type: .storageSpot, id: spot.id, title: spot.name, body: "",
                         location: [s.spaceName(spot.spaceId), s.spotPath(spot.id)].compactMap { $0 }.joined(separator: " › "),
                         people: s.personName(spot.ownerId)))
        }
        return d
    }

    public func search(_ text: String, property: UUID) async throws -> [SearchHit] {
        let tokens = SearchQuery.tokens(text)
        guard !tokens.isEmpty else { return [] }
        return store.read { s in
            let docs = Self.docs(s, property: property)
            func words(_ str: String?) -> [String] { SearchQuery.tokens(str ?? "") }
            func score(_ d: Doc, any: Bool) -> Double? {
                let fields: [([String], Double)] = [(words(d.title), 10), (words(d.body), 1), (words(d.location), 3), (words(d.people), 2)]
                var total = 0.0, matched = 0
                for t in tokens {
                    var best = 0.0
                    for (ws, w) in fields where ws.contains(where: { $0.hasPrefix(t) }) { best = max(best, w) }
                    if best > 0 { matched += 1; total += best }
                }
                if any ? matched == 0 : matched < tokens.count { return nil }
                return -total
            }
            var hits = docs.compactMap { d in score(d, any: false).map { (d, $0) } }
            if hits.isEmpty { hits = docs.compactMap { d in score(d, any: true).map { (d, $0) } } }
            return hits.sorted { ($0.1, $0.0.title) < ($1.1, $1.0.title) }.prefix(50).map { d, r in
                SearchHit(entityType: d.type, entityId: d.id, title: d.title, location: d.location,
                          snippet: d.body.isEmpty ? nil : String(d.body.prefix(80)), people: d.people, rank: r)
            }
        }
    }

    public func rebuildIndex() async throws {}
}

// MARK: - Rollups

public struct InMemoryRollupService: RollupService {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }
    public func observeRooms(level: UUID) -> AsyncStream<[UUID: Rollup]> {
        store.observe { RollupMath.rooms(level: level, projects: $0.liveProjects, lineItems: $0.liveLineItems) }
    }
    public func observeFloor(level: UUID) -> AsyncStream<FloorRollup> {
        store.observe { RollupMath.floor(level: level, projects: $0.liveProjects, lineItems: $0.liveLineItems) }
    }
    public func observeProperty(_ id: UUID) -> AsyncStream<PropertyRollup> {
        store.observe { RollupMath.property(id, levels: $0.liveLevels, projects: $0.liveProjects, lineItems: $0.liveLineItems) }
    }
}

// MARK: - Lens stats

public struct InMemoryLensStatsService: LensStatsService {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func observeStats(level: UUID, today: LocalDate) -> AsyncStream<LensStats> {
        store.observe { Self.compute($0, level: level, today: today) }
    }

    /// Reference implementation of LLD §7.5 / §8 (also a test oracle for HomeStore's SQL).
    public static func compute(_ s: InMemorySnapshot, level: UUID, today: LocalDate) -> LensStats {
        let propertyId = s.levels[level]?.propertyId
        func stats(where include: (Scope) -> Bool) -> ScopeStats {
            var st = ScopeStats()
            for c in s.liveChores where c.propertyId == propertyId && include(c.scope) && c.isOpen {
                st.openChores += 1
                guard let d = c.nextDueOn else { continue }
                if d < today { st.overdue += 1 }
                if d == today { st.dueToday += 1 }
                if d >= today && d <= today.adding(days: 6) { st.dueWeek += 1 }
            }
            st.rollup = RollupMath.rollup(s.liveProjects.filter { $0.propertyId == propertyId && include($0.scope) }, lineItems: s.liveLineItems)
            for t in s.liveThings where t.propertyId == propertyId && include(t.scope) {
                if t.ownership == .planned { st.plannedThingCount += 1; continue }
                st.thingCount += 1
                if let w = t.warrantyEnd, w >= today, w <= today.adding(days: 60) { st.warrantiesEndingSoon += 1 }
            }
            for i in s.liveInventory where i.propertyId == propertyId && include(i.scope) {
                st.inventoryCount += 1
                if i.isLow { st.lowCount += 1 }
                if i.isExpiring(today: today) { st.expiringCount += 1 }
            }
            return st
        }
        let spaces = s.liveSpaces.filter { $0.levelId == level }
        var perSpace: [UUID: ScopeStats] = [:]
        for sp in spaces { perSpace[sp.id] = stats { $0.spaceId == sp.id } }
        let thingPins = s.liveThings.filter { $0.scope.levelId == level }.map {
            ThingPin(thingId: $0.id, spaceId: $0.scope.spaceId, templateKey: $0.templateKey, category: $0.category,
                     ownership: $0.ownership, pin: $0.pin, symbol: $0.symbol)
        }
        let spaceIds = Set(spaces.map(\.id))
        let spotPins: [SpotPin] = s.liveSpots.filter { spaceIds.contains($0.spaceId) }.compactMap { spot in
            guard let pin = spot.pin else { return nil }
            let sub = Set(InventoryLogic.subtree(of: spot.id, in: s.liveSpots))
            let count = s.liveInventory.filter { $0.storageSpotId.map { sub.contains($0) } ?? false }.count
            return SpotPin(spotId: spot.id, spaceId: spot.spaceId, pin: pin, itemCount: count)
        }
        let interior = spaces.filter { !$0.isExterior }
        return LensStats(levelId: level, today: today, spaces: perSpace,
                         levelScope: stats { $0 == .level(level) },
                         floorTotal: stats { $0.levelId == level },
                         propertyScope: stats { $0 == .property },
                         propertyTotal: stats { _ in true },
                         thingPins: thingPins, spotPins: spotPins,
                         roomCount: interior.count, interiorAreaSqIn: SpaceNesting.floorAreaSqIn(interior))
    }
}

// MARK: - Export / diagnostics

/// Writes a few CSVs into a temp folder and returns the folder URL (the real exporter zips; HomeStore).
public struct InMemoryExportService: ExportService {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func exportCSV(property: UUID, options: ExportOptions) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Home-Export-\(store.today)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = store.read { $0 }
        let people = s.livePeople.filter { $0.propertyId == property }.map { [$0.id.uuidString.lowercased(), $0.name] }
        try CSV.file(header: ["id", "name"], rows: people).write(to: dir.appendingPathComponent("people.csv"))
        let chores = s.liveChores.filter { $0.propertyId == property }.map { c in
            [c.id.uuidString.lowercased(), c.title, s.locationText(c.scope), c.repeatRule?.humanText ?? "", c.nextDueOn?.description ?? "", c.notes ?? ""]
        }
        try CSV.file(header: ["id", "title", "location", "repeat", "next_due_on", "notes"], rows: chores).write(to: dir.appendingPathComponent("chores.csv"))
        let projects = s.liveProjects.filter { $0.propertyId == property }.map { p in
            [p.id.uuidString.lowercased(), p.title, p.status.rawValue, p.estCost?.plainString ?? "",
             Money(cents: RollupMath.spentCents(p, lineItems: s.liveLineItems), currency: p.currencyCode).plainString, p.currencyCode]
        }
        try CSV.file(header: ["id", "title", "status", "est_cost", "spent_effective", "currency"], rows: projects).write(to: dir.appendingPathComponent("projects.csv"))
        try Data("Home export (in-memory preview). Lengths in inches; money in major units.\r\n".utf8).write(to: dir.appendingPathComponent("README.txt"))
        return dir
    }
}

public struct InMemoryDiagnosticsService: DiagnosticsService {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }
    public func counts(property: UUID) async throws -> DiagnosticsCounts {
        store.read { s in
            var c = DiagnosticsCounts()
            c.levels = s.liveLevels.filter { $0.propertyId == property }.count
            for sp in s.liveSpaces where sp.propertyId == property { c.spacesBySource[sp.source.rawValue, default: 0] += 1 }
            c.itemsByKind = ["chore": s.liveChores.count, "project": s.liveProjects.count, "thing": s.liveThings.count,
                             "inventory_item": s.liveInventory.count, "measurement": s.liveMeasurements.count]
            c.choresWithReminder = s.liveChores.filter(\.remindEnabled).count
            c.choresWithCalendar = s.liveChores.filter(\.calendarEnabled).count
            c.doneProjectsWithActual = s.liveProjects.filter { $0.status == .done && $0.actualCost != nil }.count
            return c
        }
    }
    public func exportDiagnostics(property: UUID) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-diagnostics.json")
        try HomeJSON.encoder().encode(try await counts(property: property)).write(to: url)
        return url
    }
}

// MARK: - Reminders / notifications / calendar / sync fakes

/// Runs the real `NotificationPlanner` over the store and keeps the desired set in memory (inspect `planned`).
public final class InMemoryReminderScheduler: ReminderScheduling, @unchecked Sendable {
    public let store: InMemoryStore
    private let lock = NSLock()
    private var _planned: [PlannedNotification] = []
    private var _snoozes: [Snooze] = []
    private var lastReplan: Date?
    public init(store: InMemoryStore) { self.store = store }

    public var planned: [PlannedNotification] { lock.withLock { _planned } }

    public func replan(reason: ReplanReason) async {
        let (chores, settings, pantry) = store.read { s -> ([ChoreReminderInput], AppSettings, Int) in
            (s.liveChores.map { ChoreReminderInput(chore: $0, location: s.locationText($0.scope)) }, s.settings,
             s.liveInventory.filter { $0.kind == .pantry && $0.isExpiring(today: store.today, withinDays: 3) }.count)
        }
        let snoozes = lock.withLock { _snoozes }
        let plan = NotificationPlanner(allDayMinutes: settings.defaultAllDayMinutes)
            .plan(chores: chores, snoozes: snoozes, pantryDigest: settings.pantryDigestEnabled ? PantryDigest(expiringCount: pantry) : nil,
                  now: store.now, calendar: store.clock.calendar, engine: store.engine)
        let at = store.now
        lock.withLock { _planned = plan; lastReplan = at }
    }

    public func status() async -> ReminderStatus {
        lock.withLock { ReminderStatus(pendingCount: _planned.count, authorization: .authorized, lastReplanAt: lastReplan) }
    }

    public func snooze(chore: UUID, for seconds: TimeInterval) async {
        let title = store.read { $0.chores[chore]?.title } ?? "Reminder"
        let snooze = Snooze(choreId: chore, title: title, fireAt: store.now.addingTimeInterval(seconds), createdAt: store.now)
        lock.withLock {
            _snoozes.append(snooze)
            if _snoozes.count > NotificationPlanner.maxSnoozes { _snoozes.removeFirst() }
        }
        await replan(reason: .notificationAction)
    }
}

public struct StubNotificationAuthorizer: NotificationAuthorizing {
    public var status: PermissionStatus
    public init(status: PermissionStatus = .authorized) { self.status = status }
    public func authorizationStatus() async -> PermissionStatus { status }
    public func requestAuthorization() async throws -> Bool { status.isGranted }
}

/// Fake calendar sync: two calendars, links written to the store with this device as owner.
public struct InMemoryCalendarSync: CalendarSyncing {
    public let store: InMemoryStore
    public let device: DeviceIdentity
    public init(store: InMemoryStore, device: DeviceIdentity = StaticDeviceIdentity()) { self.store = store; self.device = device }
    public static let calendars = [CalendarInfo(id: "cal-home", title: "Home", sourceTitle: "iCloud", colorHex: "#2F6FDE"),
                                   CalendarInfo(id: "cal-gmail", title: "Family", sourceTitle: "Gmail – you@example.com", colorHex: "#0B8043")]
    public func authorizationStatus() async -> PermissionStatus { .authorized }
    public func requestAccess() async throws -> Bool { true }
    public func writableCalendars() async -> [CalendarInfo] { Self.calendars }
    public func createHomeCalendar() async throws -> CalendarInfo { Self.calendars[0] }
    public func ownership(chore: UUID) async -> CalendarOwnership {
        guard let link = store.read({ $0.calendarLinks[chore] }), link.deletedAt == nil else { return .notEnabled }
        return link.ownerDeviceId == device.deviceId ? .ownedByThisDevice(calendar: link.calendarTitle) : .ownedByOtherDevice(nickname: "another iPhone")
    }
    public func enable(chore: UUID, calendarId: String) async throws {
        guard let c = store.read({ $0.chores[chore] }) else { throw notFound(.chore, chore) }
        let cal = Self.calendars.first { $0.id == calendarId } ?? Self.calendars[0]
        let link = ChoreCalendarLink(choreId: chore, propertyId: c.propertyId, ownerDeviceId: device.deviceId, calendarTitle: cal.title,
                                     calendarSourceTitle: cal.sourceTitle, calendarIdentifier: cal.id, eventExternalId: "ext-\(chore)",
                                     eventMode: c.repeatRule?.anchor == .schedule ? .series : .single)
        try await InMemoryChoreRepository(store: store).saveCalendarLink(link)
    }
    public func choreChanged(_ id: UUID) async {}
    public func choreCompleted(_ id: UUID) async {}
    public func disable(chore: UUID) async { try? await InMemoryChoreRepository(store: store).deleteCalendarLink(chore: chore) }
    public func adoptOwnership(chore: UUID) async throws {
        guard var link = store.read({ $0.calendarLinks[chore] }) else { return }
        link.ownerDeviceId = device.deviceId
        try await InMemoryChoreRepository(store: store).saveCalendarLink(link)
    }
    public func reconcileOwned() async {}
}

public struct StubSyncService: SyncServicing {
    public var status: SyncStatus
    public init(status: SyncStatus = .upToDate(lastSync: nil)) { self.status = status }
    public func start() async throws {}
    public func observeStatus() -> AsyncStream<SyncStatus> { let s = status; return AsyncStream { $0.yield(s); $0.finish() } }
    public func syncNow() async throws {}
    public func restoreCheck(timeout: TimeInterval) async -> RestoreCheckResult { .noExistingHome }
    public func diagnostics() async -> SyncDiagnostics { SyncDiagnostics(accountStatus: "preview") }
}
