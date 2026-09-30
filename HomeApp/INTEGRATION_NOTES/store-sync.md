# HomeStore + HomeSync — integration notes

Owner: persistence & sync workstream. Files: `Packages/HomeStore/**`, `Packages/HomeSync/**`.

## 1. Composition root (`App/AppEnvironment.swift`, `AppEnvironment.live()`)

HomeStore must be swapped in **first**: HomeSchedule and every feature take the repositories from `d`.
The domain event bus must be the one HomeStore publishes on, so `d.events = store.database.bus`.

```swift
import HomeStore
import HomeSync

var d = AppDependencies.inMemory(sample: false, config: config)

// INTEGRATION: HomeStore — Application Support/home.sqlite (WAL) + Application Support/Attachments/
let store: HomeStore
do {
    store = try HomeStore.live(directory: HomeStore.defaultDirectory, clock: d.clock, events: d.events)
} catch {
    fatalError("Could not open the database: \(error)")   // or show a recovery screen
}
d.plan = store.plan;               d.planCommitter = store.planCommitter
d.chores = store.chores;           d.projects = store.projects
d.things = store.things;           d.inventory = store.inventory
d.measurements = store.measurements; d.people = store.people
d.attachments = store.attachments; d.settings = store.settings        // UserDefaults-backed
d.recentlyDeleted = store.recentlyDeleted
d.search = store.search;           d.rollups = store.rollups
d.lensStats = store.lensStats;     d.export = store.export
d.diagnostics = store.diagnostics

// INTEGRATION: HomeSync — CKSyncEngine over iCloud.<bundle id>, private DB, zone property-<uuid>
let sync = try SyncCoordinator.live(store: store, containerIdentifier: config.cloudKitContainerIdentifier)
d.sync = sync
```

`HomeStore.live(directory:clock:events:defaults:)` signature: `directory` (Application Support), `clock`
(`any HomeClock`, default `SystemClock()`), `events` (`any DomainEventBus`, default new `BroadcastEventBus`),
`defaults` (`UserDefaults`, default `.standard`). `HomeStore.inMemory(clock:events:defaults:)` is the same over an
in-memory database (tests/previews). The `HomeStore` struct exposes every implementation as a concrete `public let`
(`plan: PlanStore`, `chores: ChoreStore`, …, `sync: SyncStore`) plus `database: AppDatabase` and `files: AttachmentFileStore`.

`AppEnvironment.start()` already calls `sync.start()` and subscribes to `sync.observeStatus()`; nothing else is needed
for normal sync. Also:

- **First launch / onboarding**: `await env.sync.restoreCheck(timeout: 8)` → `.existingHomeFound` ⇒ "Restoring your home…"
  (it also kicks a fetch), `.unavailable` ⇒ FR-SYN-21 notice, `.noExistingHome` ⇒ creation paths.
- **BG refresh**: `try? await env.sync.syncNow()` (CKSyncEngine also syncs automatically on pushes).
- **Account events (not in `SyncServicing`, see §3)**: keep a typed reference to the coordinator and observe
  `sync.observeAccountEvents()`:
  - `.switchedAccounts` → blocking sheet "Export CSV" / "Erase and use the new account" →
    `try await sync.eraseLocalDataForNewAccount()` then re-run `restoreCheck`.
  - `.userDeletedZone(zoneName)` → "Your iCloud data for Home was deleted. Upload this iPhone's copy again?" →
    `try await sync.confirmReupload(zoneName:)`.
- **Diagnostics export**: `DiagnosticsStore` has an `additionalFiles` hook for the 24-hour `OSLogStore` slice (the App owns
  `OSLog`). To use it, build it yourself: `d.diagnostics = DiagnosticsStore(store.database, metricsDirectory: <App Support>/Diagnostics, additionalFiles: { [await writeLogSlice()] })`.
  MetricKit payloads written to `Application Support/Diagnostics/` are included automatically when `live(directory:)` is used.
- **Settings › Diagnostics › Rebuild search index**: `try await env.search.rebuildIndex()`.
- **Settings › Diagnostics › DB size**: `store.database.fileSizeBytes`.

## 2. Behaviour notes for feature owners

- Every write is one transaction: row + `sync_outbox` (changed columns, `local_version`) + FTS reindex (with cascades:
  renaming a room/floor/spot/person reindexes dependents). `DomainEvent`s are published **after** commit on `store.database.bus`.
- `observeX` streams are GRDB `ValueObservation`s (duplicates removed); they yield the current value then every change.
- `updateSpaces` validates the ≤ 1 sq in interior-overlap rule (throws `RepositoryError.overlap`) and **welds** interior
  rooms of every touched level (PlanKit `Weld`); neighbours may move by ≤ 3 in so shared walls coincide (both sides move to
  the cluster mean). `PlanCommitter.commit` welds each draft level's interior rooms the same way.
- Deleting a room/floor re-scopes items (deleted ones too) to `reassignItemsTo`; the room's storage spots are soft-deleted.
- Purge (`RecentlyDeletedStore.purge` / `purgeExpired`) hard-deletes, enqueues CloudKit deletes for the row **and** its FK
  children (spots, measurements, completions, line items…) and owned attachments (files removed), and re-homes rows whose
  scope CHECK would break on `ON DELETE SET NULL`.
- `ExportService` returns `Home-Export-YYYY-MM-DD.zip` on Apple platforms (NSFileCoordinator `.forUploading`); on Linux the folder.
- Unknown enum values from a newer app version (e.g. `space_type = "sunroom"`) cannot be stored locally (the LLD CHECK lists);
  HomeSync parks such records whole in `sync_orphan` (`missing_parent = "schema:space_type=sunroom"`), retries them on every
  launch (so an updated app applies them), and never writes them back. Outgoing saves of existing records send only the
  locally changed columns, so fields/values this build doesn't know keep their server values.

## 3. HomeCore change requests (not made — HomeCore is owned elsewhere)

1. **`SyncStatus`**: add `case accountChanged` (FR-SYN-32 blocking sheet) and `case needsUploadConfirmation` (FR-SYN-33).
   Today the coordinator reports `.error("Waiting for your decision about iCloud data")` while paused for the user.
2. **`SyncServicing`**: add `observeAccountEvents() -> AsyncStream<SyncAccountEvent>`, `eraseLocalDataForNewAccount()` and
   `confirmReupload(zoneName:)` (and move `SyncAccountEvent` to HomeCore) so feature code needn't hold the concrete
   `SyncCoordinator`. `StubSyncService` would get no-op versions.
3. **`InMemoryRecentlyDeletedRepository`** labels measurements `"HomeMeasurement"`; the user-facing label should be
   `"Measurement"` (HomeStore uses "Measurement").
4. **`InMemorySearchService`** (oracle) uses room-only location for measurements and no dims for rooms; LLD §12.1 says
   "room · floor" and "space type, formatted dims" — HomeStore follows the LLD (its results are a superset of the oracle's).
5. Optional: a `SettingsRepository` note — HomeStore's `SettingsStore` stores `AppSettings` as JSON under
   `UserDefaults` key `home.appSettings.v1`.

## 4. Merge-policy deviation (documented)

LLD §5.4 lists groups for inventory location and calendar links. HomeSync also moves these column groups together, to keep
row CHECKs valid and values coherent: the scope triple (`scope`, `space_id`, `level_id`) for chores/projects/things, pins
(`pin_x`, `pin_y`), segments (opening `ax…by`, measurement `seg_*`), thing `purchase_price_cents` + `currency_code`,
and the property address/coordinate columns.
