import Foundation
import Observation
import PlanKit
import HomeCore
import HomeCoreTesting
import HomeStore
import HomeSync
import HomeSchedule
import HomeCapture
import HomeExterior
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

/// iCloud account situations the UI must resolve with the user (FR-SYN-32/33). App-level mirror of
/// `HomeSync.SyncAccountEvent` so feature code never imports HomeSync.
enum AccountPrompt: Hashable, Identifiable {
    /// A different Apple ID signed in: offer "Erase and use the new account" (or keep the local data).
    case switchedAccounts
    /// The user deleted Home's iCloud data: ask before re-uploading this iPhone's copy.
    case userDeletedZone(zoneName: String)

    var id: String {
        switch self {
        case .switchedAccounts: return "switched"
        case .userDeletedZone(let z): return "deleted:\(z)"
        }
    }
}

/// Hooks into the concrete sync coordinator that the `SyncServicing` protocol doesn't cover.
struct AccountHooks {
    var events: @Sendable () -> AsyncStream<AccountPrompt>
    var eraseLocalDataForNewAccount: @Sendable () async throws -> Void
    var confirmReupload: @Sendable (String) async throws -> Void
}

/// Every service the app uses, typed by its HomeCore protocol. Built once by `AppEnvironment` (the composition
/// root). Feature code must depend on these protocols only — never on concrete HomeStore/HomeSync/etc. types.
struct AppDependencies {
    var config: AppConfig
    var clock: any HomeClock
    var device: any DeviceIdentity
    var events: any DomainEventBus

    // Persistence (HomeStore)
    var plan: any PlanRepository
    var planCommitter: any PlanCommitting
    var chores: any ChoreRepository
    var projects: any ProjectRepository
    var things: any ThingRepository
    var inventory: any InventoryRepository
    var measurements: any MeasurementRepository
    var people: any PeopleRepository
    var attachments: any AttachmentRepository
    var settings: any SettingsRepository
    var recentlyDeleted: any RecentlyDeletedRepository

    // Queries (HomeStore)
    var search: any SearchService
    var rollups: any RollupService
    var lensStats: any LensStatsService
    var export: any ExportService
    var diagnostics: any DiagnosticsService

    // Platform (HomeSchedule, HomeSync)
    var reminders: any ReminderScheduling
    var notificationAuth: any NotificationAuthorizing
    var calendar: any CalendarSyncing
    var sync: any SyncServicing

    // Capture (HomeCapture)
    var roomPlanImporter: any RoomPlanImporting
    var roughIn: any RoughInGenerating
    var blocks: any BlockTemplating
    var photoTrace: any PhotoTraceCalibrating
    var receipts: any ReceiptReading

    // Exterior (HomeExterior)
    var addresses: any AddressResolving
    var footprints: any FootprintProviding
    var snapshots: any SatelliteSnapshotting
    var yardSeeder: any YardSeeding
    var exteriorSeeder: any ExteriorSeeding

    // In-app feedback (live: Home server + on-device queue; in-memory for previews/tests)
    var feedback: any FeedbackSubmitting = InMemoryFeedbackSubmitter()

    // Extras outside the HomeCore protocols (nil for in-memory wiring)
    var account: AccountHooks? = nil
    var setDeviceNickname: (@Sendable (String) -> Void)? = nil
    /// Non-fatal problem while opening the real store (the app then runs on an in-memory store).
    var startupError: String? = nil

    /// In-memory wiring (HomeCoreTesting). `sample: true` loads the SampleHome house; false starts empty (onboarding).
    static func inMemory(sample: Bool, config: AppConfig = .main, clock: any HomeClock = SystemClock()) -> AppDependencies {
        let home = sample ? InMemoryHome.sample(clock: clock) : InMemoryHome.empty(clock: clock)
        let device = StaticDeviceIdentity(deviceId: "in-memory-device", nickname: "This iPhone")
        return AppDependencies(
            config: config, clock: clock, device: device, events: home.store.bus,
            plan: home.plan, planCommitter: home.plan, chores: home.chores, projects: home.projects, things: home.things,
            inventory: home.inventory, measurements: home.measurements, people: home.people, attachments: home.attachments,
            settings: home.settings, recentlyDeleted: home.recentlyDeleted,
            search: home.search, rollups: home.rollups, lensStats: home.lensStats, export: home.export, diagnostics: home.diagnostics,
            reminders: home.reminders, notificationAuth: StubNotificationAuthorizer(),
            calendar: InMemoryCalendarSync(store: home.store, device: device), sync: StubSyncService(),
            roomPlanImporter: StubRoomPlanImporter(), roughIn: StubRoughInGenerator(), blocks: StubBlockTemplates(),
            photoTrace: StubPhotoTraceCalibrator(), receipts: StubReceiptReader(),
            addresses: StubAddressResolver(), footprints: StubFootprintProvider(), snapshots: StubSatelliteSnapshotter(),
            yardSeeder: StubYardSeeder(), exteriorSeeder: StubExteriorSeeder())
    }

    /// Production wiring: GRDB store, CKSyncEngine, UserNotifications/EventKit, RoomPlan/Vision, MapKit/Overpass.
    /// Order matters: HomeStore first (everything else takes the repositories from `d`), then HomeSchedule.
    static func live(config: AppConfig = .main) -> AppDependencies {
        var d = AppDependencies.inMemory(sample: false, config: config)

        // INTEGRATION: HomeStore — Application Support/home.sqlite (WAL) + Application Support/Attachments/
        let store: HomeStore
        do {
            let directory = HomeStore.defaultDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try HomeStore.live(directory: directory, clock: d.clock, events: d.events)
        } catch {
            // Keep the app usable (in-memory) and tell the user; data would be lost on relaunch.
            d.startupError = "Couldn’t open the Home database: \(error.localizedDescription)"
            do {
                store = try HomeStore.inMemory(clock: d.clock, events: d.events)
            } catch {
                return d   // in-memory HomeCoreTesting wiring as the last resort
            }
        }
        d.events = store.database.bus
        d.plan = store.plan;                 d.planCommitter = store.planCommitter
        d.chores = store.chores;             d.projects = store.projects
        d.things = store.things;             d.inventory = store.inventory
        d.measurements = store.measurements; d.people = store.people
        d.attachments = store.attachments;   d.settings = store.settings
        d.recentlyDeleted = store.recentlyDeleted
        d.search = store.search;             d.rollups = store.rollups
        d.lensStats = store.lensStats;       d.export = store.export
        d.diagnostics = store.diagnostics

        // INTEGRATION: HomeSync — CKSyncEngine over iCloud.<bundle id>, private DB, zone property-<uuid>
        if config.cloudSyncEnabled, let sync = try? SyncCoordinator.live(store: store, containerIdentifier: config.cloudKitContainerIdentifier) {
            d.sync = sync
            d.account = AccountHooks(
                events: {
                    AsyncStream { continuation in
                        let task = Task {
                            for await e in sync.observeAccountEvents() {
                                switch e {
                                case .switchedAccounts: continuation.yield(.switchedAccounts)
                                case .userDeletedZone(let zone): continuation.yield(.userDeletedZone(zoneName: zone))
                                }
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                },
                eraseLocalDataForNewAccount: { try await sync.eraseLocalDataForNewAccount() },
                confirmReupload: { zone in try await sync.confirmReupload(zoneName: zone) })
        } else if d.startupError == nil {
            d.startupError = "iCloud sync couldn’t start. Your data stays on this iPhone."
        }

        // INTEGRATION: HomeSchedule — Keychain device id, UNUserNotificationCenter scheduler, EventKit calendar sync
        let device = KeychainDeviceIdentity()
        d.device = device
        d.setDeviceNickname = { name in device.setNickname(name) }
        let reminders = ReminderScheduler(chores: d.chores, plan: d.plan, inventory: d.inventory, people: d.people,
                                          settings: d.settings, clock: d.clock)
        d.reminders = reminders
        d.notificationAuth = reminders
        let calendarSync = CalendarSync(chores: d.chores, plan: d.plan, settings: d.settings, device: device, clock: d.clock)
        d.calendar = calendarSync
        Task { await calendarSync.startObservingStoreChanges() }

        // INTEGRATION: HomeCapture
        d.roomPlanImporter = RoomPlanImporter()
        d.roughIn = RoughInGenerator()
        d.blocks = BlockTemplates()
        d.photoTrace = PhotoTraceCalibrator()
        d.receipts = ReceiptReader(clock: d.clock)

        // INTEGRATION: HomeExterior — Home server when AppConfig.usesServer, else Overpass directly
        d.addresses = AddressResolver()
        d.footprints = FootprintProvider(config: config)
        d.snapshots = SatelliteSnapshotter()
        d.yardSeeder = YardSeeder()
        d.exteriorSeeder = ExteriorSeeder(footprints: d.footprints, seeder: d.yardSeeder)

        // INTEGRATION: Feedback — POST {HomeServerURL}/v1/feedback; queued in Application Support/Feedback when offline
        d.feedback = FeedbackClient(config: config)
        return d
    }
}

/// Composition root (LLD §2): holds protocol-typed services and app-wide UI state; injected with
/// `.environment(env)` and read in views with `@Environment(AppEnvironment.self) private var env`.
@MainActor
@Observable
final class AppEnvironment {
    let config: AppConfig
    let clock: any HomeClock
    let device: any DeviceIdentity
    let events: any DomainEventBus

    let plan: any PlanRepository
    let planCommitter: any PlanCommitting
    let chores: any ChoreRepository
    let projects: any ProjectRepository
    let things: any ThingRepository
    let inventory: any InventoryRepository
    let measurements: any MeasurementRepository
    let people: any PeopleRepository
    let attachments: any AttachmentRepository
    let settings: any SettingsRepository
    let recentlyDeleted: any RecentlyDeletedRepository

    let search: any SearchService
    let rollups: any RollupService
    let lensStats: any LensStatsService
    let export: any ExportService
    let diagnostics: any DiagnosticsService

    let reminders: any ReminderScheduling
    let notificationAuth: any NotificationAuthorizing
    let calendar: any CalendarSyncing
    let sync: any SyncServicing

    let roomPlanImporter: any RoomPlanImporting
    let roughIn: any RoughInGenerating
    let blocks: any BlockTemplating
    let photoTrace: any PhotoTraceCalibrating
    let receipts: any ReceiptReading

    let addresses: any AddressResolving
    let footprints: any FootprintProviding
    let snapshots: any SatelliteSnapshotting
    let yardSeeder: any YardSeeding
    let exteriorSeeder: any ExteriorSeeding

    let feedback: any FeedbackSubmitting

    let fitChecker = FitChecker()
    let recurrence: RecurrenceEngine

    @ObservationIgnored private let account: AccountHooks?
    @ObservationIgnored private let nicknameWriter: (@Sendable (String) -> Void)?

    // MARK: App-wide UI state (observable)

    /// Set by `onOpenURL` / notification taps (`home://chore/<uuid>`); the Plan screen consumes and clears it.
    var pendingDeepLink: ItemRef?
    /// Floor the Plan tab should switch to (e.g. the Outside level from "Yard & Exterior"); the Plan screen consumes
    /// and clears it.
    var pendingLevelID: UUID?
    /// Lens currently shown on the plan (persisted via SettingsRepository.lastLens).
    var selectedLens: LensID = .plan
    var syncStatus: SyncStatus = .upToDate(lastSync: nil)
    /// iCloud account situation waiting for the user's decision (FR-SYN-32/33); RootView presents it.
    var accountPrompt: AccountPrompt?
    /// Non-fatal startup problem to show once (database could not be opened, sync unavailable).
    var startupError: String?

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var syncStatusTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var timeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init(_ d: AppDependencies) {
        config = d.config; clock = d.clock; device = d.device; events = d.events
        plan = d.plan; planCommitter = d.planCommitter; chores = d.chores; projects = d.projects; things = d.things
        inventory = d.inventory; measurements = d.measurements; people = d.people; attachments = d.attachments
        settings = d.settings; recentlyDeleted = d.recentlyDeleted
        search = d.search; rollups = d.rollups; lensStats = d.lensStats; export = d.export; diagnostics = d.diagnostics
        reminders = d.reminders; notificationAuth = d.notificationAuth; calendar = d.calendar; sync = d.sync
        roomPlanImporter = d.roomPlanImporter; roughIn = d.roughIn; blocks = d.blocks; photoTrace = d.photoTrace; receipts = d.receipts
        addresses = d.addresses; footprints = d.footprints; snapshots = d.snapshots; yardSeeder = d.yardSeeder; exteriorSeeder = d.exteriorSeeder
        feedback = d.feedback
        recurrence = RecurrenceEngine(calendar: d.clock.calendar)
        account = d.account
        nicknameWriter = d.setDeviceNickname
        startupError = d.startupError
    }

    /// The running app: real store, sync, scheduling, capture and exterior services.
    static func live() -> AppEnvironment {
        AppEnvironment(.live(config: .main))
    }

    /// SwiftUI previews: in-memory sample house (or empty for onboarding previews).
    static func preview(sample: Bool = true) -> AppEnvironment {
        AppEnvironment(.inMemory(sample: sample))
    }

    // MARK: Lifecycle

    /// Called once from the root view's `.task`. Starts sync and the post-commit reaction loop (HLD §3.1).
    func start() async {
        guard !started else { return }
        started = true
        try? await sync.start()
        selectedLens = await settings.load().lastLens
        let stream = events.events
        let reminders = self.reminders
        let calendar = self.calendar
        eventTask = Task {
            for await event in stream {
                if event.affectsChores { await reminders.replan(reason: .choreChanged) }
                switch event {
                case .choreCompleted(let id): await calendar.choreCompleted(id)
                case .updated(.chore(let id)): await calendar.choreChanged(id)
                case .restored(.chore(let id)): await calendar.choreChanged(id)
                case .deleted(.chore(let id)): await calendar.disable(chore: id)
                case .syncApplied(let types, _):
                    // Edits made on another device: the owner device applies them to its calendar (AC-CHR-12).
                    if types.contains(RecordType.chore.rawValue) || types.contains(RecordType.choreCalendarLink.rawValue) {
                        await calendar.reconcileOwned()
                    }
                case .timeZoneChanged:
                    await reminders.replan(reason: .timeZoneChanged)
                default: break
                }
            }
        }
        let statusStream = sync.observeStatus()
        syncStatusTask = Task { [weak self] in
            for await s in statusStream { self?.syncStatus = s }
        }
        if let account {
            let prompts = account.events()
            accountTask = Task { [weak self] in
                for await p in prompts { self?.accountPrompt = p }
            }
        }
        observeTimeChanges()
        retryPendingFeedback()
        await reminders.replan(reason: .launch)
        scheduleAppRefresh()
    }

    /// LLD §9.3 replan triggers: system time zone / significant time changes.
    private func observeTimeChanges() {
        guard timeObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in await self?.reminders.replan(reason: .timeZoneChanged) }
        }
        timeObservers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: handler))
        #if canImport(UIKit)
        timeObservers.append(center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main, using: handler))
        #endif
    }

    func sceneBecameActive() async {
        retryPendingFeedback()
        await reminders.replan(reason: .foreground)
    }

    /// Sends feedback saved while offline (in the background; a sleeping server can take a while to answer).
    private func retryPendingFeedback() {
        let feedback = self.feedback
        Task.detached(priority: .utility) { await feedback.retryPending() }
    }

    /// `home://chore/<uuid>` etc.
    func handle(url: URL) {
        if let ref = ItemRef(url: url) { pendingDeepLink = ref }
    }

    /// Settings › "This iPhone's name": stored in `AppSettings` and mirrored to the device identity used by
    /// calendar ownership messages on other devices.
    func setDeviceNickname(_ name: String) {
        nicknameWriter?(name)
    }

    // MARK: iCloud account decisions (FR-SYN-32/33)

    /// "Erase and use the new account": drops the local copy so the new Apple ID's data can come down.
    func eraseLocalDataForNewAccount() async throws {
        try await account?.eraseLocalDataForNewAccount()
        accountPrompt = nil
    }

    /// "Upload this iPhone's copy again" after the user deleted Home's iCloud data.
    func confirmReupload(zoneName: String) async throws {
        try await account?.confirmReupload(zoneName)
        accountPrompt = nil
    }

    // MARK: Background refresh (LLD §9.3)

    func scheduleAppRefresh() {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// BGAppRefresh body: replan, reconcile calendar, sync, purge > 30-day deletes, then reschedule.
    func runBackgroundRefresh() async {
        scheduleAppRefresh()
        await reminders.replan(reason: .backgroundRefresh)
        await calendar.reconcileOwned()
        try? await sync.syncNow()
        let cutoff = clock.now.addingTimeInterval(-Double(DeletedEntry.retentionDays) * 86_400)
        _ = try? await recentlyDeleted.purgeExpired(before: cutoff)
    }
}
