import Foundation
import Observation
import PlanKit
import HomeCore
import HomeCoreTesting
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

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

    let fitChecker = FitChecker()
    let recurrence: RecurrenceEngine

    // MARK: App-wide UI state (observable)

    /// Set by `onOpenURL` / notification taps (`home://chore/<uuid>`); the Plan screen consumes and clears it.
    var pendingDeepLink: ItemRef?
    /// Lens currently shown on the plan (persisted via SettingsRepository.lastLens).
    var selectedLens: LensID = .plan
    var syncStatus: SyncStatus = .upToDate(lastSync: nil)

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var syncStatusTask: Task<Void, Never>?
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
        recurrence = RecurrenceEngine(calendar: d.clock.calendar)
    }

    /// The running app. Until the real packages land, everything is in-memory with the sample house.
    static func live() -> AppEnvironment {
        let config = AppConfig.main
        // INTEGRATION: change `let d` to `var d` when the first real implementation is swapped in below.
        let d = AppDependencies.inMemory(sample: true, config: config)

        // INTEGRATION: HomeStore — open the database and swap every repository/query service:
        //   let db = try AppDatabase.open(at: AppPaths.databaseURL)            // Application Support/home.sqlite
        //   d.plan = PlanStore(db, events: d.events); d.planCommitter = PlanCommitter(db, events: d.events)
        //   d.chores = ChoreStore(db, ...); d.projects = ...; d.things = ...; d.inventory = ...; d.measurements = ...
        //   d.people = ...; d.attachments = AttachmentFileStore(...); d.recentlyDeleted = ...
        //   d.search = FTSSearchService(db); d.rollups = RollupQueries(db); d.lensStats = LensStatsQueries(db)
        //   d.export = CSVExporter(db); d.diagnostics = ...
        //   d.settings = UserDefaultsSettingsRepository()

        // INTEGRATION: HomeSync — d.sync = SyncCoordinator(db: db, containerIdentifier: config.cloudKitContainerIdentifier)

        // INTEGRATION: HomeSchedule — d.reminders = ReminderScheduler(chores: d.chores, inventory: d.inventory, settings: d.settings, clock: d.clock)
        //   d.notificationAuth = <same ReminderScheduler or a UNUserNotificationCenter wrapper>
        //   d.calendar = CalendarSync(chores: d.chores, device: KeychainDeviceIdentity(), settings: d.settings)

        // INTEGRATION: HomeCapture — d.roomPlanImporter = RoomPlanImporter(); d.roughIn = RoughInGenerator();
        //   d.blocks = BlockTemplates(); d.photoTrace = PhotoTraceCalibrator(); d.receipts = ReceiptReader()

        // INTEGRATION: HomeExterior — d.addresses = AddressResolver();
        //   d.footprints = config.usesServer ? ServerFootprintProvider(config: config) : OverpassFootprintProvider()
        //   d.snapshots = SatelliteSnapshotter(); d.yardSeeder = YardSeeder();
        //   d.exteriorSeeder = ExteriorSeeder(footprints: d.footprints, seeder: d.yardSeeder)

        return AppEnvironment(d)
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
                case .deleted(.chore(let id)): await calendar.disable(chore: id)
                default: break
                }
            }
        }
        let statusStream = sync.observeStatus()
        syncStatusTask = Task { [weak self] in
            for await s in statusStream { self?.syncStatus = s }
        }
        await reminders.replan(reason: .launch)
        scheduleAppRefresh()
    }

    func sceneBecameActive() async {
        await reminders.replan(reason: .foreground)
    }

    /// `home://chore/<uuid>` etc.
    func handle(url: URL) {
        if let ref = ItemRef(url: url) { pendingDeepLink = ref }
    }

    // MARK: Background refresh (LLD §9.3)

    func scheduleAppRefresh() {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// BGAppRefresh body: replan, reconcile calendar, purge > 30-day deletes, then reschedule.
    func runBackgroundRefresh() async {
        scheduleAppRefresh()
        await reminders.replan(reason: .backgroundRefresh)
        await calendar.reconcileOwned()
        let cutoff = clock.now.addingTimeInterval(-Double(DeletedEntry.retentionDays) * 86_400)
        _ = try? await recentlyDeleted.purgeExpired(before: cutoff)
    }
}
