# Home app — shared contract (v1)

Read this before writing code. It lists every model, value type and protocol the parallel workstreams code
against. Specs remain the source of truth for behaviour: `docs/homeowner-app/design/lld.md` (§ numbers below),
`hld.md`, `product/prd.md`, `product/features/*.md`.

## 0. Ground rules

| Rule | Detail |
|---|---|
| Dependency direction | `App → PlanCanvas / HomeSync / HomeSchedule / HomeCapture / HomeExterior → HomeStore → HomeCore → PlanKit`. PlanCanvas depends only on HomeCore + PlanKit. HomeSchedule depends on HomeCore only (reads data through HomeCore protocols). |
| Program to protocols | Feature code and platform packages depend on the **HomeCore protocols** below, never on another package's concrete types. The app wires concrete types in `App/AppEnvironment.swift` at the `// INTEGRATION:` markers. |
| Pure packages | `PlanKit` and `HomeCore` (+ `HomeCoreTesting`) import Foundation only and pass `swift test` on macOS and Linux. Don't add UIKit/SwiftUI/GRDB/CloudKit/MapKit imports there. |
| Swift mode | Every Package.swift is tools 5.10, `swiftLanguageVersions: [.v5]`, platforms iOS 17 / macOS 14. Models are `Sendable`; services are `Sendable` structs/actors. |
| Units | Geometry is **inches** (`Double`), level-local, x right, **y down**. Money is `Int64` cents + ISO currency. Local dates are `LocalDate` (floating `YYYY-MM-DD`). Time of day is minutes after midnight (`MinuteOfDay`). |
| IDs | `UUID` everywhere; stored lowercase. Draft types use `tempId` mapped to real UUIDs at commit. |
| Deletes | Soft (`deletedAt`), 30-day Recently Deleted. Reads exclude deleted rows. |
| Writes | One transaction per repository call: row + sync outbox + search index. Side effects (reminders, calendar, render rebuilds) react **after commit** to `DomainEvent`s. |
| Observation | `observeX(...)` returns `AsyncStream<T>` that yields the current value immediately, then again after every committed change that could affect it (GRDB `ValueObservation` in HomeStore). Consume in `.task { for await v in stream { ... } }`; cancelling the task ends the observation. |
| Forward-compatible enums | String enums conform to `ForwardCompatibleEnum` and have `case unknown`; unknown raw values decode to `.unknown`. Use `.knownCases` for pickers. HomeSync must preserve the original record value when writing back a row whose enum is `.unknown`. |
| JSON columns | Encode with `HomeJSON.encoder()` (sorted keys). `Polygon` encodes as `[[x,y],...]`; `LocalDate` as `"YYYY-MM-DD"`; `Scope` is stored as three columns (`scope`, `space_id`, `level_id`) — HomeStore record wrappers flatten it; its Codable form (`{kind,spaceId,levelId}`) is for in-memory/tests only. |

### Names that differ from the LLD (on purpose)
| LLD name | Code name | Why |
|---|---|---|
| `Measurement` | **`HomeMeasurement`** | `Foundation.Measurement` makes the bare name ambiguous in every module importing Foundation. |
| `Clock` | **`HomeClock`** | Clashes with the Swift stdlib `Clock` protocol. |
| `LengthFormatter` | **`HomeLengthFormatter`** | Clashes with `Foundation.LengthFormatter`. |
| `ThingDraft` inside `LevelDraft` | **`SuggestedThing`** | `ThingDraft` is the form input for `ThingRepository.create`. |
| `MeasurementDraft` (form input) | **`MeasurementInput`** | `MeasurementDraft` is the PlanDraft element. |
| `*Servicing` (`PlanServicing`, `ChoreServicing`, …) | `*Repository` | Typealiases with the LLD names exist. |
| `BudgetServicing` / `ExportServicing` | `RollupService` / `ExportService` | Typealiases exist. |
| `AsyncValueObservation<T>` | `AsyncStream<T>` | Keeps GRDB out of the contract. |
| `CLLocationCoordinate2D`, `CGPoint`, `CGImage`, `EKEvent`, `UNNotificationRequest`, `CapturedStructure` | `GeoCoordinate`, `Vec2`, `Data`, `CalendarInfo`, `PlannedNotification`, JSON `Data` | Contract stays value-typed and platform-free. Platform types stay inside their package. |
| Clipper2 (vendored C++) | `PlanKit.Clip` (pure Swift) | Dropped per foundation brief: `intersectionArea`, `split`, `unionAdjacent`, `offset`, `simplify`, `convexHull`. |
| `LensID` cases `future`, `past` | `futureProjects`, `pastWork` | Match the product's 7 view names. |

## 1. Packages and owners

| Package | Status | Contents |
|---|---|---|
| `PlanKit` | **Done** (37 tests) | Geometry: `Vec2`, `Segment`, `Rect`, `Polygon`, `Validation`, `Area`, `Contains`, `HitTester`, `PolyLabel`, `Snapper`, `Weld`, `WallDerivation`, `Treemap`, `TangentPlane`, `GeoReference`, `Transform2D`, `UnderlayTransform`/`UnderlayCalibration`, `Orientation`, `Clip`, `Tolerance`. |
| `HomeCore` | **Done** (45 tests incl. in-memory) | Models, value types, pure engines, **all protocols**. |
| `HomeCoreTesting` | **Done** | `InMemory*` implementations of every repository/service, capture/exterior stubs, `SampleHome`, `InMemoryHome`. |
| `HomeStore` | Skeleton | GRDB: `AppDatabase`, migrations (§3), record wrappers, repositories, outbox, `SearchIndexer`, rollup/lens/storage-tree queries, `CSVExporter`, `AttachmentFileStore`, `PlanCommitter`. Depends on HomeCore + GRDB 7. |
| `HomeSync` | Skeleton | `SyncCoordinator` (CKSyncEngine), mappers, merge policy, orphans, account changes. Implements `SyncServicing`. Depends on HomeStore. |
| `HomeSchedule` | Skeleton | `ReminderScheduler` (`ReminderScheduling`, `NotificationAuthorizing`), `CalendarSync` (`CalendarSyncing`). Depends on HomeCore. |
| `HomeCapture` | Skeleton | `RoomPlanImporter`, `PhotoTraceCalibrator`, `RoughInGenerator`, `BlockTemplates`, `ReceiptReader`, `ReceiptParser`. |
| `HomeExterior` | Skeleton | `AddressResolver`, footprint providers (server + Overpass), `SatelliteSnapshotter`, `YardSeeder`, `ExteriorSeeder`. |
| `PlanCanvas` | Skeleton | `PlanCanvasView`, `Viewport`, gestures, `LevelRenderModel`, the 7 `PlanLens` implementations, overlays, accessibility. Inputs: `LevelGeometry` + `LensStats` values only. |
| App `Home` | Skeleton | `HomeApp` (@main, scene phase, BG refresh, deep links), `AppEnvironment` (composition root), `RootView` placeholder, `Features/<Name>/` folders. |

## 2. Protocols (HomeCore/Sources/HomeCore/Protocols)

### Infrastructure
| Protocol | Purpose |
|---|---|
| `HomeClock` | Injected `now` + Gregorian `calendar` (impl: `SystemClock`, `FixedClock`). |
| `DeviceIdentity` | Install UUID + user nickname for calendar owner-device model (impl: `StaticDeviceIdentity`; real one is Keychain-backed). |
| `DomainEventBus` | Post-commit `DomainEvent` broadcast; each `events` access is a new subscriber (impl: `BroadcastEventBus`). |
| `SyncedModel` | Shape of every synced row: `id`, `propertyId`, `createdAt`, `updatedAt`, `deletedAt`, `static recordType`. |
| `ForwardCompatibleEnum` | String enums decoding unknown values to `.unknown`. |

### Persistence (implemented by HomeStore)
| Protocol | Purpose |
|---|---|
| `PlanRepository` (`PlanServicing`) | Property, levels, spaces, openings; `observeGeometry(level:)` feeds the canvas; `updateSpaces` enforces the ≤ 1 sq in interior-overlap rule and welds; room/level delete reassigns items. |
| `PlanCommitting` | Writes any `PlanDraft` in one transaction (temp ids → UUIDs, accepted suggestions only, zone creation). |
| `ChoreRepository` (`ChoreServicing`) | Chores, completions, done/skip/reschedule/pause, turn into project, calendar link row. |
| `ProjectRepository` (`ProjectServicing`) | Projects (idea → planned → in progress → done), Done sheet (`markDone`), reopen, cost line items. |
| `ThingRepository` (`ThingServicing`) | Appliances/electronics/furniture/fixtures/systems + `fit(for:)` reports (target + delivery paths). |
| `InventoryRepository` (`InventoryServicing`) | Items, storage-spot tree (cycle guard), move, quantity, where-is, seasonal swap, shopping list. |
| `MeasurementRepository` | Measurements per room/property, delivery-path doors. |
| `PeopleRepository` | Housemates (assignees/owners), reorder. |
| `AttachmentRepository` | Photos/receipts/manuals/underlays; copies files into the store; local file URL lookup. |
| `SettingsRepository` | Device-local `AppSettings` (UserDefaults). Synced settings live on `Property`. |
| `RecentlyDeletedRepository` | 30-day list, restore (FR-SES-64 re-homing), purge, purge-expired. |

### Queries (implemented by HomeStore)
| Protocol | Purpose |
|---|---|
| `SearchService` | FTS5 search (AND prefix, fallback OR, ≤ 50), `rebuildIndex()`. |
| `RollupService` (`BudgetServicing`) | Room / floor / property budget rollups (§8). |
| `LensStatsService` | Per-level `LensStats` (to-dos, rollups, things, inventory, pins) for the 7 lenses. |
| `ExportService` (`ExportServicing`) | CSV zip export (§13). |
| `DiagnosticsService` | Counts-only diagnostics JSON and export (FR-SES-41..43). |

### Platform (HomeSchedule, HomeSync)
| Protocol | Purpose |
|---|---|
| `ReminderScheduling` | `replan(reason:)` (debounced diff of `NotificationPlanner` output vs pending), `status()`, `snooze(chore:for:)`. |
| `NotificationAuthorizing` | Notification permission status/request (asked when the first reminder is switched on). |
| `CalendarSyncing` | EventKit full access, calendars list, "Home" calendar, enable/disable/changed/completed, owner-device adoption, reconcile. |
| `SyncServicing` | Start CKSyncEngine, status stream (`SyncStatus`), sync now, first-launch restore check, diagnostics. |

### Capture (HomeCapture)
| Protocol | Purpose |
|---|---|
| `PlanDraftProducing` | Marker for the four creation paths. |
| `RoomPlanImporting` | `CapturedStructure` JSON → `PlanDraft` (§6.12). |
| `RoughInGenerating` | `RoughInInput` → deterministic `PlanDraft` (§6.10). |
| `BlockTemplating` | House style + beds/baths → starting `PlanDraft`. |
| `PhotoTraceCalibrating` | Two-point (± second pair) scale calibration → `UnderlayTransform` (§6.9). |
| `ReceiptReading` | Receipt images → `ReceiptGuess` (OCR + parse, §15). |
| `ReceiptParsing` | Pure parser over `OCRLine`s. |

### Exterior (HomeExterior)
| Protocol | Purpose |
|---|---|
| `AddressResolving` | Address suggestions + resolve to `ResolvedAddress`. |
| `FootprintProviding` | Building outline + nearest road near a coordinate. **Use the Home server `GET {HomeServerURL}/v1/footprint?lat=&lon=` (header `X-Home-Key` when `HomeAPIKey` non-empty) when `AppConfig.serverURL` is set; otherwise call Overpass directly.** |
| `SatelliteSnapshotting` | Cached local satellite image + pixel→model transform (never synced). |
| `YardSeeding` | Footprint + front direction → default exterior `SpaceDraft`s (§6.11). |
| `ExteriorSeeding` | Orchestrates address → footprint → zones into an exterior `LevelDraft`. |

## 3. Models (HomeCore/Sources/HomeCore/Models) — all `Codable, Hashable, Sendable, Identifiable` (UUID)

| Model | Purpose |
|---|---|
| `Property` | The home: address, coordinate, default level, currency, unit system; `zoneName` = `property-<uuid>`. |
| `Level` (`Kind`: floor/basement/attic/exterior) | A floor; sort order (basement −1, ground 0, exterior 100), underlay, exterior geo-reference. `[Level].sortedForPills`, `.defaultLevel(preferred:)`. |
| `Space` (`Source`) + `SpaceType` | Room or exterior zone: `Polygon` in inches, type, approximate flag, color. |
| `Opening` (`Kind`, `Swing`, `Source`) | Display-only door/window segment on a wall. |
| `Person` | Housemate. |
| `StorageSpot` | Nested storage location in a room (max depth 32), optional plan pin. |
| `HomeMeasurement` (`Kind`, `Source`) + `Dims3` | Opening/wall/door/window/zone measurement; `isDeliveryPath`. |
| `Thing` (`Category`, `Ownership`) + `ThingTemplate` | Durable item with template attributes (`[String: JSONValue]`), dims, fit target, pin. `ThingTemplate.catalog` = v1 templates + SF Symbols + suggested maintenance chores. |
| `Chore` | One-off or recurring to-do (`RepeatRule?`), reminders, calendar flag, linked thing; `deepLink`. |
| `ChoreCompletion` (`Outcome`: done/skipped) | Append-only completion row. |
| `ChoreCalendarLink` (`Mode`: series/single) | Synced owner-device calendar link (id == choreId). |
| `Project` (`Status`) | Idea/planned/in progress/done with est/actual cost & hours, dates, vendor. |
| `CostLineItem` (`Kind`) | Cost line on a project (+ receipt attachment). |
| `InventoryItem` (`Kind`) + `Season` | Pantry/clothing/stored/other item with location, quantity, season/rotation, expiry, low flag, linked thing. |
| `Attachment` (`OwnerType`, `Kind`) | File metadata (photo/receipt/manual/document/underlay); binary in `Attachments/<id>.<ext>`. |
| `AppSettings` | Device-local preferences (all-day reminder time 9:00, badge, pantry digest, default calendar, nickname, list view, last lens). |
| `Scope` | `.space(id, level:)` / `.level(id)` / `.property` placement of chores, projects, things, inventory. |
| `RecordType`, `RecordRef` | The 15 synced record types (CloudKit names, table names) and a typed row reference. |

## 4. Value types (HomeCore/Sources/HomeCore/Values, Foundation)

| Type | Purpose |
|---|---|
| `LocalDate`, `MinuteOfDay` | Floating date with pure day/month arithmetic; minutes after midnight. |
| `Money` | Cents + currency; `plainString` (CSV), `formatted()`, `compact` ("$4.2k"). |
| `UnitSystem`, `HomeLengthFormatter` | Imperial/metric display (`12'4"`, `35¾ in`, `1,240 sq ft`) and typed-dimension parsing. |
| `JSONValue`, `HomeJSON` | Template attribute values; deterministic JSON coding. |
| `AppConfig` | Info.plist config: `HomeServerURL`, `HomeAPIKey` (→ `X-Home-Key`), bundle id → CloudKit container `iCloud.<bundle id>`, BG task ids, URL scheme `home`. `AppConfig.main` reads `Bundle.main` (defaults off-Apple). |
| `ItemRef` | Cross-kind item reference (chore/project/thing/inventory/measurement) + `home://` deep links. |
| `LensID`, `AddKind` | The 7 views (plan, todos, futureProjects, pastWork, things, inventory, budget) with title/symbol/"+" default. |
| `DomainEvent` | created/updated/deleted/restored(ItemRef), choreCompleted, geometryChanged, recordsChanged, syncApplied, settingsChanged, timeZoneChanged; `affectsChores`. |
| `PlanDraft`, `LevelDraft`, `SpaceDraft`, `OpeningDraft`, `SuggestedThing`, `MeasurementDraft`, `UnderlayDraft`, `DraftWarning`, `AttachmentDraft` | Shared output of all plan-creation paths (§6.13) and file-to-attach input. |
| `ChoreDraft`, `ProjectDraft`, `ThingDraft`, `InventoryDraft`, `MeasurementInput` | Create-form inputs. |
| `SpaceChange`, `LevelGeometry`, `RepositoryError` | Geometry edits, canvas render input, repository errors (notFound, invalid, overlap, invalidPolygon, cycle). |
| `ChoreQuery`, `ProjectQuery`, `ThingQuery`, `InventoryQuery`, `scopeMatches` | List filters (exact scope, or everything on a level). |
| `Rollup`, `FloorRollup`, `PropertyRollup`, `RollupMath` | Budget aggregates and the pure reference math (§8). |
| `ScopeStats`, `LensStats`, `ThingPin`, `SpotPin` | Lens statistics per space / floor / property plus pins. |
| `SpotNode`, `ItemLocation`, `SwapLine`, `SeasonalSwap`, `ShoppingLine` | Storage tree, where-is, seasonal swap, shopping list (§11). |
| `SearchEntityType`, `SearchHit`, `SearchQuery` | Search results + shared query normalization / FTS expression (§12). |
| `FitReport`, `DeletedEntry` | Fit results per measurement; Recently Deleted rows. |
| `ReplanReason`, `PermissionStatus`, `ReminderStatus` | Reminder scheduling inputs/diagnostics. |
| `CalendarInfo`, `CalendarOwnership` | Calendar picker rows; who manages a chore's events. |
| `SyncStatus`, `SyncDiagnostics`, `RestoreCheckResult` | Settings sync pill, diagnostics, first-launch restore. |
| `AddressSuggestion`, `ResolvedAddress`, `FootprintResult`, `SnapshotImage` | Exterior inputs/outputs. |
| `RoughInInput`, `HouseStyle`, `TraceWarning`, `ReceiptGuess`, `OCRLine` | Capture inputs/outputs. |
| `ExportOptions`, `DiagnosticsCounts` | Export toggle; counts-only diagnostics payload. |

## 5. Pure engines (HomeCore/Sources/HomeCore/Engines)

| Type | Purpose |
|---|---|
| `RepeatRule` | §9.1 rule (daily / weekly+weekdays / everyNDays / monthly+dayOfMonth, anchor, until); `humanText`. |
| `RecurrenceEngine`, `OccurrenceSequence` | §9.2 `occurrences`, `firstDue`, `nextDue` (missed occurrences collapse). DST-proof. |
| `NotificationPlanner`, `PlannedNotification`, `ChoreReminderInput`, `Snooze`, `PantryDigest` | §9.3 60 chore slots + sentinel + pantry digest + 2 snoozes; ids `chore:<uuid>:<yyyy-MM-dd>`; stable FNV `contentHash` (never use `hashValue`). |
| `FitChecker`, `FitPolicy`, `FitClearance`, `FitResult`, `AxisVerdict` | §10 fit and delivery-path checks with default clearances per template. |
| `ChoreLogic`, `ProjectLogic`, `InventoryLogic` | Shared business rules (complete/skip, merge recompute, status transitions, low threshold, spot subtree/path/tree, re-parent guard). HomeStore should reuse them. |
| `CSV` | RFC 4180 writer, CRLF, UTF-8 BOM. |

## 6. PlanKit quick reference

`Polygon(_:)` validates (§6.2: dedupe, collinear drop, simple, min area 4 sq ft or `minArea:`, positive winding, 0.01 in rounding; vertex order preserved). `Polygon(unchecked:)` for trusted DB data.
`Contains.contains`, `HitTester.hit` (smallest containing, then 22 pt radius), `PolyLabel.pole(of:)` ("+"/label anchor + inscribed radius), `Snapper.snap(candidate:context:)`, `Weld.weldDetailed(polygons:)`, `WallDerivation.walls(spaces:openings:)` (gaps are **fractions 0…1** along `seg`), `WallDerivation.coincidentEdges` (shared-wall edge drag), `Treemap.squarify(_:in:snap:)`, `TangentPlane.project/unproject`, `Transform2D` (`then`, `inverse`, `fitSimilarity`, `fitAffine`), `UnderlayCalibration.calibrate`, `Orientation.dominantAngle`, `Clip.intersectionArea/overlaps/split/unionAdjacent/offset/simplify/convexHull`.

## 7. In-memory implementations (HomeCoreTesting)

`InMemoryStore` (one snapshot, lock, `observe`, `write(events:)`), `InMemoryPlanRepository` (also `PlanCommitting`), `InMemoryChoreRepository`, `InMemoryProjectRepository`, `InMemoryThingRepository`, `InMemoryInventoryRepository`, `InMemoryMeasurementRepository`, `InMemoryPeopleRepository`, `InMemoryAttachmentRepository`, `InMemorySettingsRepository`, `InMemoryRecentlyDeletedRepository`, `InMemorySearchService`, `InMemoryRollupService`, `InMemoryLensStatsService` (`compute` is a reference oracle), `InMemoryExportService`, `InMemoryDiagnosticsService`, `InMemoryReminderScheduler` (runs the real planner; inspect `planned`), `StubNotificationAuthorizer`, `InMemoryCalendarSync`, `StubSyncService`, `StubRoughInGenerator`, `StubBlockTemplates`, `StubPhotoTraceCalibrator`, `StubRoomPlanImporter`, `StubReceiptReader`, `StubAddressResolver`, `StubFootprintProvider`, `StubSatelliteSnapshotter`, `StubYardSeeder`, `StubExteriorSeeder`.

`SampleHome.snapshot(today:now:)` — deterministic house (ids `SampleHome.id(n)`): Basement/1st/2nd/Outside, 12 rooms + 4 yard zones, Matt & Alex, 5 chores (furnace filter overdue), 4 projects (one per status, bathroom remodel done with line items), 6 things (incl. a planned fridge that doesn't fit), fridge-opening + front-door (delivery path) measurements, a storage spot tree with winter clothes, pantry and a low furnace filter.
`InMemoryHome.sample(clock:)` / `.empty(clock:)` bundles every service over one store.

Preview pattern:
```swift
#Preview { RoomSheet(spaceId: SampleHome.kitchenId).environment(AppEnvironment.preview()) }
```

## 8. App wiring

- `AppEnvironment` (`@MainActor @Observable`) holds every service as `any <Protocol>`; read it with `@Environment(AppEnvironment.self) private var env`. `AppEnvironment.preview(sample:)` for previews; `.live()` for the app.
- `// INTEGRATION:` markers in `AppEnvironment.live()` and `HomeApp.AppDelegate` show where each package swaps in its real implementation. Change `let d` to `var d` there when you add the first one.
- `AppEnvironment.start()` runs the post-commit reaction loop: chore-affecting events → `reminders.replan`, chore completed/updated/deleted → calendar calls; subscribes to `sync.observeStatus()`.
- Deep links `home://chore/<uuid>` set `env.pendingDeepLink`; Plan screen consumes it.
- BG refresh: `.backgroundTask(.appRefresh("app.fumble.home.refresh"))` → `runBackgroundRefresh()` (replan, calendar reconcile, purge > 30 days). `app.fumble.home.maintenance` (BGProcessing) is permitted for heavy work (FTS rebuild) if needed.
- Features go in `App/Features/<Name>/` (Plan, RoomSheet, Add, Chores, Projects, Things, Inventory, Measurements, Budget, Search, Onboarding, Editor, People, Settings). Thing template JSON / block styles go in `App/Resources/Templates/`.

## 9. Build & test

```bash
# Pure packages (macOS or Linux):
cd HomeApp/Packages/PlanKit  && swift test
cd HomeApp/Packages/HomeCore && swift test
# Skeletons build on Linux too (GRDB 7 resolves): cd HomeApp/Packages/HomeStore && swift build
# App (macOS + Xcode 16):
cd HomeApp && xcodegen generate && xcodebuild -project Home.xcodeproj -scheme Home \
  -destination 'platform=iOS Simulator,name=iPhone 16' HOME_TEAM_ID=XXXXXXXXXX test
```
Build settings: `HOME_BUNDLE_ID` (default `app.fumble.home`), `HOME_TEAM_ID`, `HOME_SERVER_URL`, `HOME_API_KEY`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`. Entitlement container is `iCloud.$(HOME_BUNDLE_ID)`; `aps-environment` is `development` (switch to `production` for App Store/TestFlight signing via the provisioning profile / export options). In `.xcconfig` files write URLs as `https:/$()/host` (`//` starts a comment).

## 10. Decisions / defaults taken

- Founder open questions use the documented defaults (HLD §9, PRD §15): inches storage, 9:00 all-day reminder, Recently Deleted 30 days, pantry digest off, attachments not in CSV by default, one property in the UI, no analytics SDK, no location permission.
- Info.plist: no photo-library key (PHPicker/PhotosPicker need none, HLD §5.1); background modes `remote-notification`, `fetch`, `processing`.
- `Validation.normalize` preserves vertex order (editor handle indices stay stable). T-junction vertices inserted by `Weld` are collinear and get dropped again by normalization; wall derivation handles T-junctions by interval sweep, and `Clip.unionAdjacent` re-subdivides edges itself.
- Pass-through fit also tries the swapped carry orientation (item's second-smallest dim against door width).
- `Season.upcoming`: Mar–Aug → summer, Sep–Feb → winter; latitude < 0 flips.
- In-memory `updateSpaces` enforces the overlap rule but does not weld; HomeStore must weld on commit.
