import Foundation
import PlanKit

// Persistence protocols (LLD §14 "Domain services"). Real implementations live in HomeStore (GRDB);
// in-memory ones in HomeCoreTesting. Conventions:
// - `observeX` returns an `AsyncStream` that yields the current value immediately and again after every
//   committed change that could affect it (GRDB `ValueObservation` in HomeStore). Cancel the consuming Task to stop.
// - Every write updates `updatedAt`, enqueues sync (HomeStore) and reindexes search in the same transaction,
//   then publishes a `DomainEvent` after commit.
// - Deletes are soft (`deletedAt`); `RecentlyDeletedRepository` restores/purges.
// - Reads exclude soft-deleted rows unless stated.

/// Property, levels, spaces and openings (LLD `PlanServicing`).
public protocol PlanRepository: Sendable {
    // Property
    func properties() async throws -> [Property]
    /// The property shown in the UI (v1: the first non-deleted one).
    func currentProperty() async throws -> Property?
    func observeCurrentProperty() -> AsyncStream<Property?>
    func saveProperty(_ property: Property) async throws
    func setDefaultLevel(_ levelId: UUID, property: UUID) async throws

    // Levels
    func levels(property: UUID) async throws -> [Level]
    func observeLevels(property: UUID) -> AsyncStream<[Level]>
    func saveLevel(_ level: Level) async throws
    /// Soft-deletes the level and its spaces; items move to `reassignItemsTo` (FR-SES-61).
    func deleteLevel(_ id: UUID, reassignItemsTo: Scope) async throws

    // Spaces / openings
    func geometry(level: UUID) async throws -> LevelGeometry
    /// Canvas render input: spaces + openings of a level.
    func observeGeometry(level: UUID) -> AsyncStream<LevelGeometry>
    func space(_ id: UUID) async throws -> Space?
    func spaces(property: UUID) async throws -> [Space]
    /// Validates level rules (no interior overlap > 1 sq in), welds on commit, one transaction.
    func updateSpaces(_ changes: [SpaceChange]) async throws
    func renameSpace(_ id: UUID, to name: String) async throws
    func deleteSpace(_ id: UUID, reassignItemsTo: Scope) async throws
    func saveOpening(_ opening: Opening) async throws
    func deleteOpening(_ id: UUID) async throws
}

/// Writes any `PlanDraft` in one transaction (LLD §6.13). Maps temp IDs → UUIDs, validates level rules, inserts
/// rows + outbox + FTS, creates the CloudKit zone for a new property. Returns the created level ids in draft order.
public protocol PlanCommitting: Sendable {
    func commit(_ draft: PlanDraft, into property: UUID, acceptedSuggestions: Set<UUID>) async throws -> [UUID]
}

/// Chores and completions (LLD `ChoreServicing`).
public protocol ChoreRepository: Sendable {
    func chore(_ id: UUID) async throws -> Chore?
    func chores(_ query: ChoreQuery) async throws -> [Chore]
    func observeChores(_ query: ChoreQuery) -> AsyncStream<[Chore]>
    func completions(chore: UUID) async throws -> [ChoreCompletion]
    func create(_ draft: ChoreDraft) async throws -> Chore
    /// Saves edits; recomputes `nextDueOn` if the rule or start changed.
    func update(_ chore: Chore) async throws
    func complete(_ id: UUID, by person: UUID?, at: Date) async throws -> ChoreCompletion
    func skip(_ id: UUID, at: Date) async throws
    /// Manual "Reschedule to…" (plain overlay field).
    func reschedule(_ id: UUID, to: LocalDate) async throws
    func setPaused(_ id: UUID, _ paused: Bool) async throws
    /// Creates an idea project with `spawnedFromChoreId`.
    func turnIntoProject(_ id: UUID) async throws -> Project
    func delete(_ id: UUID) async throws
    // Calendar link (synced, owner-device model §9.5)
    func calendarLink(chore: UUID) async throws -> ChoreCalendarLink?
    func saveCalendarLink(_ link: ChoreCalendarLink) async throws
    func deleteCalendarLink(chore: UUID) async throws
}

/// Projects and cost line items (LLD `ProjectServicing`).
public protocol ProjectRepository: Sendable {
    func project(_ id: UUID) async throws -> Project?
    func projects(_ query: ProjectQuery) async throws -> [Project]
    func observeProjects(_ query: ProjectQuery) -> AsyncStream<[Project]>
    func create(_ draft: ProjectDraft) async throws -> Project
    func update(_ project: Project) async throws
    /// Non-done transitions (stamps startedOn when entering in-progress).
    func setStatus(_ id: UUID, _ status: Project.Status) async throws
    /// The Done sheet: actual cost, completion date, hours and an optional receipt.
    func markDone(_ id: UUID, actual: Money?, completedOn: LocalDate, hours: Double?, receipt: AttachmentDraft?) async throws
    /// done → in progress, keeps actuals.
    func reopen(_ id: UUID) async throws
    func delete(_ id: UUID) async throws
    func lineItems(project: UUID) async throws -> [CostLineItem]
    func observeLineItems(project: UUID) -> AsyncStream<[CostLineItem]>
    func upsertLineItem(_ item: CostLineItem) async throws
    func deleteLineItem(_ id: UUID) async throws
}

/// Appliances, electronics, furniture, fixtures and systems (LLD `ThingServicing`).
public protocol ThingRepository: Sendable {
    func thing(_ id: UUID) async throws -> Thing?
    func things(_ query: ThingQuery) async throws -> [Thing]
    func observeThings(_ query: ThingQuery) -> AsyncStream<[Thing]>
    func create(_ draft: ThingDraft) async throws -> Thing
    func update(_ thing: Thing) async throws
    func delete(_ id: UUID) async throws
    /// Fit against `fitMeasurementId` and every delivery-path measurement (computed, never stored).
    func fit(for id: UUID) async throws -> [FitReport]
}

/// Inventory items and storage spots (LLD `InventoryServicing`, §11).
public protocol InventoryRepository: Sendable {
    func item(_ id: UUID) async throws -> InventoryItem?
    func items(_ query: InventoryQuery) async throws -> [InventoryItem]
    func observeItems(_ query: InventoryQuery) -> AsyncStream<[InventoryItem]>
    func create(_ draft: InventoryDraft) async throws -> InventoryItem
    /// Saves edits; applies the low threshold; derives scope from the spot when set.
    func update(_ item: InventoryItem) async throws
    func delete(_ id: UUID) async throws
    /// Moves items into a spot (nil = room top level keeps current scope). Updates denormalized space/level.
    func move(_ ids: [UUID], to spot: UUID?) async throws
    func adjustQuantity(_ id: UUID, by delta: Double) async throws

    // Storage spots
    func spot(_ id: UUID) async throws -> StorageSpot?
    func spots(space: UUID) async throws -> [StorageSpot]
    func saveSpot(_ spot: StorageSpot) async throws
    /// Soft-deletes the subtree; items move to `moveItemsTo` (a spot id) or to the room when nil.
    func deleteSpot(_ id: UUID, moveItemsTo: UUID?) async throws
    /// Cycle / cross-room guard (§11.2) → `RepositoryError.cycle`.
    func reparentSpot(_ id: UUID, to parent: UUID?) async throws
    func observeSpotTree(space: UUID) -> AsyncStream<[SpotNode]>

    // Queries
    /// "Where is…" for items (§11.3).
    func locations(of ids: [UUID]) async throws -> [ItemLocation]
    func observeSeasonalSwap(property: UUID, on: LocalDate) -> AsyncStream<SeasonalSwap>
    /// Flips `inRotation` for the given items in one transaction ("Swap all").
    func applySwap(itemIds: [UUID], inRotation: Bool) async throws
    func observeShoppingList(property: UUID, on: LocalDate) -> AsyncStream<[ShoppingLine]>
}

/// Measurements (openings, walls, doors, windows, zones).
public protocol MeasurementRepository: Sendable {
    func measurement(_ id: UUID) async throws -> HomeMeasurement?
    func measurements(space: UUID) async throws -> [HomeMeasurement]
    func observeMeasurements(space: UUID) -> AsyncStream<[HomeMeasurement]>
    func measurements(property: UUID) async throws -> [HomeMeasurement]
    /// Measurements flagged `isDeliveryPath`.
    func deliveryPaths(property: UUID) async throws -> [HomeMeasurement]
    func create(_ input: MeasurementInput) async throws -> HomeMeasurement
    func update(_ measurement: HomeMeasurement) async throws
    func delete(_ id: UUID) async throws
}

/// Housemates.
public protocol PeopleRepository: Sendable {
    func people(property: UUID) async throws -> [Person]
    func observePeople(property: UUID) -> AsyncStream<[Person]>
    func save(_ person: Person) async throws
    func delete(_ id: UUID) async throws
    /// Persists `sortOrder` in the given order.
    func reorder(_ ids: [UUID]) async throws
}

/// Photos, receipts, manuals, underlays. Binaries in Application Support/Attachments.
public protocol AttachmentRepository: Sendable {
    func attachments(ownerType: Attachment.OwnerType, ownerId: UUID) async throws -> [Attachment]
    /// Copies the file into the store, computes sha256/size, inserts the row (upload state `needs_upload`).
    func add(_ draft: AttachmentDraft, ownerType: Attachment.OwnerType, ownerId: UUID, property: UUID) async throws -> Attachment
    func delete(_ id: UUID) async throws
    /// Local file URL if the binary is present (nil while `remote_only` / downloading).
    func fileURL(for attachment: Attachment) async -> URL?
}

/// Device-local preferences (UserDefaults).
public protocol SettingsRepository: Sendable {
    func load() async -> AppSettings
    func save(_ settings: AppSettings) async
    func observe() -> AsyncStream<AppSettings>
}

/// Recently Deleted (30 days, FR-SES-60..65).
public protocol RecentlyDeletedRepository: Sendable {
    func deleted(property: UUID) async throws -> [DeletedEntry]
    func observeDeleted(property: UUID) -> AsyncStream<[DeletedEntry]>
    func restore(_ ref: RecordRef) async throws
    /// "Delete now": hard purge (sync sends a delete).
    func purge(_ ref: RecordRef) async throws
    /// Purges rows soft-deleted before `cutoff` (BG refresh task).
    func purgeExpired(before cutoff: Date) async throws -> Int
}

// Traceability aliases to the LLD §14 names.
public typealias PlanServicing = PlanRepository
public typealias ChoreServicing = ChoreRepository
public typealias ProjectServicing = ProjectRepository
public typealias ThingServicing = ThingRepository
public typealias InventoryServicing = InventoryRepository
