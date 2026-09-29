import Foundation
import HomeCore

// HomeStore — GRDB persistence (LLD §3, §5.3, §8, §11–13). Every repository/query protocol of HomeCore is
// implemented here over one `AppDatabase`; `HomeStore.live(directory:)` builds them all for the composition root.

public enum HomeStoreModule {
    public static let name = "HomeStore"
}

/// Every HomeStore implementation over one database. The App composition root assigns these to the
/// protocol-typed `AppDependencies` fields; HomeSync takes `store.sync`.
public struct HomeStore: Sendable {
    public let database: AppDatabase
    public let files: AttachmentFileStore

    public let plan: PlanStore
    public let planCommitter: PlanCommitter
    public let chores: ChoreStore
    public let projects: ProjectStore
    public let things: ThingStore
    public let inventory: InventoryStore
    public let measurements: MeasurementStore
    public let people: PeopleStore
    public let attachments: AttachmentStore
    public let settings: SettingsStore
    public let recentlyDeleted: RecentlyDeletedStore

    public let search: FTSSearchService
    public let rollups: RollupQueries
    public let lensStats: LensStatsQueries
    public let export: CSVExporter
    public let diagnostics: DiagnosticsStore

    /// Sync bookkeeping API for HomeSync (outbox, system fields, orphans, applying fetched rows).
    public let sync: SyncStore

    public init(database: AppDatabase, files: AttachmentFileStore, defaults: UserDefaults = .standard,
                metricsDirectory: URL? = nil, exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.database = database
        self.files = files
        plan = PlanStore(database)
        planCommitter = PlanCommitter(database, files: files)
        chores = ChoreStore(database)
        projects = ProjectStore(database, files: files)
        things = ThingStore(database)
        inventory = InventoryStore(database)
        measurements = MeasurementStore(database)
        people = PeopleStore(database)
        attachments = AttachmentStore(database, files: files)
        settings = SettingsStore(defaults: defaults, bus: database.bus)
        recentlyDeleted = RecentlyDeletedStore(database, files: files)
        search = FTSSearchService(database)
        rollups = RollupQueries(database)
        lensStats = LensStatsQueries(database)
        export = CSVExporter(database, files: files, outputDirectory: exportDirectory)
        diagnostics = DiagnosticsStore(database, metricsDirectory: metricsDirectory, outputDirectory: exportDirectory)
        sync = SyncStore(database, files: files)
    }

    /// Opens (or creates) the store under `directory` (the app passes Application Support):
    /// `<directory>/home.sqlite` (WAL), `<directory>/Attachments/`, MetricKit payloads in `<directory>/Diagnostics/`.
    public static func live(directory: URL, clock: HomeClock = SystemClock(), events: DomainEventBus = BroadcastEventBus(),
                            defaults: UserDefaults = .standard) throws -> HomeStore {
        let db = try AppDatabase.open(at: directory.appendingPathComponent("home.sqlite"), clock: clock, bus: events)
        return HomeStore(database: db, files: AttachmentFileStore(directory: directory.appendingPathComponent("Attachments", isDirectory: true)),
                         defaults: defaults, metricsDirectory: directory.appendingPathComponent("Diagnostics", isDirectory: true))
    }

    /// In-memory database with attachments in a temporary folder (tests, previews).
    public static func inMemory(clock: HomeClock = SystemClock(), events: DomainEventBus = BroadcastEventBus(),
                                defaults: UserDefaults? = nil) throws -> HomeStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("homestore-\(UUID().uuidString.lowercased())", isDirectory: true)
        let db = try AppDatabase.inMemory(clock: clock, bus: events)
        let d = defaults ?? UserDefaults(suiteName: "homestore.\(UUID().uuidString)") ?? .standard
        return HomeStore(database: db, files: AttachmentFileStore(directory: tmp.appendingPathComponent("Attachments", isDirectory: true)),
                         defaults: d, exportDirectory: tmp)
    }

    /// Application Support/`Home` — the default `directory` for `live(directory:)`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
    }
}
