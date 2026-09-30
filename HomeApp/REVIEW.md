# Home app — integration review (v1, pre-first-macOS-build)

Scope: the six parallel workstreams (canvas/plan, store/sync, schedule/chores/projects/budget, things/inventory/
search/settings, capture/exterior/onboarding, and the foundation) were reviewed and wired together. No Xcode is
available here, so everything Apple-only (SwiftUI, CloudKit, EventKit, UserNotifications, RoomPlan, Vision,
MapKit, PhotosUI) was reviewed by reading against the iOS 17 SDK; everything else was compiled and tested on Linux.

## What was integrated

| Where | Change |
|---|---|
| `App/AppEnvironment.swift` | `AppDependencies.live()` now builds the real stack in the order the notes require: `HomeStore.live` (Application Support/home.sqlite + Attachments; falls back to an in-memory store with a one-time `startupError` if the DB can't open) → `SyncCoordinator.live` (CKSyncEngine, `iCloud.<bundle id>`) → `KeychainDeviceIdentity`, `ReminderScheduler` (also the `NotificationAuthorizing`), `CalendarSync` (+ `startObservingStoreChanges`) → HomeCapture (`RoomPlanImporter`, `RoughInGenerator`, `BlockTemplates`, `PhotoTraceCalibrator`, `ReceiptReader`) → HomeExterior (`AddressResolver`, `FootprintProvider(config:)` = server or Overpass, `SatelliteSnapshotter`, `YardSeeder`, `ExteriorSeeder`). `preview()` stays on HomeCoreTesting. |
| `AppEnvironment.start()` | Reaction loop extended per schedule notes: `.restored(.chore)` → `calendar.choreChanged`; `.syncApplied` with Chore/ChoreCalendarLink → `calendar.reconcileOwned()`; `.timeZoneChanged`, `NSSystemTimeZoneDidChange` and `UIApplication.significantTimeChangeNotification` → `replan(.timeZoneChanged)`. Sync account events (switched Apple ID / user deleted zone) surface as `env.accountPrompt` (app-level `AccountPrompt`, no HomeSync import in features) with `eraseLocalDataForNewAccount()` / `confirmReupload(zoneName:)`. Background refresh also calls `sync.syncNow()`. |
| `App/HomeApp.swift` | `AppDelegate` installs `NotificationActionHandler` (delegate + CHORE_DUE/SYSTEM categories) before launch completes; `HomeApp.body.task` configures it with `NotificationActions` and routes body taps to `env.handle(url:)`. |
| `App/RootView.swift` | Observes `plan.observeCurrentProperty()`: onboarding while there is no property (until `onFinished`), else `PlanScreen`. Presents the iCloud account prompt and the startup error. |
| `Features/Plan/PlanScreen.swift` | Budget footer link now opens `BudgetDrillDown` (was the `INTEGRATION:` hook). |
| `Features/Settings/SettingsView.swift` | Device nickname also written to `KeychainDeviceIdentity.setNickname` via `env.setDeviceNickname`. |
| HomeCore (change requests) | `ChoreLogic.projectDraft` titles the spawned project "From: <chore>" (FR-CHR-32). `InMemoryRecentlyDeletedRepository` labels measurements "Measurement" like HomeStore. |
| `.github/workflows/ios-build.yml` | Adds `-skipMacroValidation`, clears signing identity/team for the simulator build, and runs `swift test` for all eight packages on macOS (the platform packages' macOS builds also compile the CloudKit / EventKit / UserNotifications / MapKit / SwiftUI paths, which Linux cannot). |

Cross-feature names were reconciled by reading every call site against the declaring file: `AddRouter` ↔
`ChoreForm(spaceID:levelID:)`, `ProjectForm(spaceID:levelID:initialStatus:)`, `ThingForm(spaceID:)`,
`InventoryForm(spaceID:)`, `MeasurementForm(spaceID:)`; `ItemDetailRouter` ↔ the `…(xxxID:)` edit inits and
`ChoreDetailView(choreID:)`; `SearchView(onShowLocation:)`; `ToDosListView()`, `ShoppingListView()`,
`SeasonalSwapView()`, `SettingsView()`, `BudgetDrillDown()`. No duplicate top-level type names exist in the App
module and no public type name is duplicated across packages.

## Verification done here

- Linux, Swift 6.4 toolchain, Swift 5 mode: `swift build && swift test` for PlanKit, HomeCore, HomeStore, HomeSync,
  HomeSchedule, HomeCapture, HomeExterior, PlanCanvas (see the run log in the hand-off; all green).
- `server/`: `node --test` — 26/26.
- The non-SwiftUI app files (`AppEnvironment`, `PlanScreenModel`, `RoomSheetModel`, `PlanEditorModel`,
  `OnboardingModel`, `ThingsInventoryKit`) were type-checked together against the real packages in a scratch
  package on Linux, so the new composition root is known to match the package APIs.
- Every SwiftUI/Apple-framework file was read line by line against the HomeCore/PlanKit/PlanCanvas public
  surface (field names, initializer labels/order, enum cases) and the iOS 17 SDK. No API newer than iOS 17 is
  used without a guard.

## Riskiest spots for the first macOS/Xcode build

These compile-by-inspection only; if the first CI run fails, look here first.

1. `Packages/HomeSync/Sources/HomeSync/CloudKitSyncEngine.swift` — `CKSyncEngine` delegate/event case shapes
   (`.accountChange` change types, `.sentRecordZoneChanges` failed-delete dictionary), `CKRecord` ObjC value
   bridging (`__CKRecordObjCValue`, `encryptedValues.setObject`), and the async `RecordZoneChangeBatch` init.
2. `Packages/HomeSchedule/Sources/HomeSchedule/EventKitCalendarStore.swift` — EventKit IUO properties
   (`eventIdentifier`, `startDate`, `calendar`) and `EKRecurrenceRule` full initializer.
3. `App/Features/Onboarding/ScanFlow.swift` — RoomPlan multi-room API (`stop(pauseARSession:)`,
   `StructureBuilder(options: [])`, `RoomCaptureViewDelegate`'s NSCoding requirement).
4. `Packages/PlanCanvas/Sources/PlanCanvas/UI/PlanCanvasView.swift` — accessibility rotor/children modifiers,
   `SpatialTapGesture`/`MagnifyGesture`/`DragGesture.Value.velocity`, `Canvas` renderer closure.
5. `App/Features/Projects/ReceiptScanner.swift` and `App/Features/Onboarding/TraceFlow.swift` — `#if` blocks in
   the middle of modifier chains, `PhotosPicker`, `UIGraphicsPDFRenderer`.
6. `Packages/HomeExterior/Sources/HomeExterior/AddressResolver.swift` — `@MainActor` completer box with
   `nonisolated` delegate methods + `MainActor.assumeIsolated`; `MKMapItem.placemark` is deprecated in the iOS 26
   SDK (warning only).
7. Swift 6.x compilers in Swift 5 mode still enforce actor isolation: `PlanScreenModel` / `RoomSheetModel`
   capture `AppEnvironment` (a `@MainActor` class) inside `@MainActor` task-group children — expected to be fine,
   but any "non-sendable type captured" *warning* here can be ignored; an *error* means a missing `@MainActor`.

## Known gaps (not compile blockers)

- Canvas underlay is not drawn (photo trace image / satellite snapshot); exterior `georef` rotation not applied
  (canvas notes §5). The snapshot is still captured and cached.
- Room-sheet detail screens for projects/things/inventory/measurements open the edit forms (only chores have a
  pushable detail view). Undo snackbar after deletes (FR-SES-62) not implemented; chore Undo restores the due date
  but keeps the completion row.
- Measurement / storage-spot pins on the plan (pin-drop UI), photos/manuals on things and items, "Use Measure
  app", per-item fit clearances: not in v1 code.
- HomeCore requests not taken (documented in `INTEGRATION_NOTES/*.md` §3/§4): `ScopeStats.spotCount`, footer
  detail fields, property-relative budget tint, `DraftWarning.footprintUnavailable` (string tag still used),
  `FootprintResult.candidates`, `SwapLine.ownerId`, `InventoryQuery.linkedThingId`, `SyncStatus.accountChanged`
  (the app handles account events itself), `ReminderStatus.lastError`, cross-room `moveSpot`.
- Exterior seeding "retry on next launch when the footprint lookup failed for network reasons" has no owner yet.
- Diagnostics export does not include the 24-hour `OSLogStore` slice (HomeStore's `additionalFiles` hook is unused).
- `App/Resources/Assets.xcassets/AppIcon.appiconset` has no image files: fine for the simulator build, but App
  Store Connect rejects a TestFlight upload without a 1024×1024 icon.
- Overpass `User-Agent` is a placeholder (`Home/1.0 (iOS; app.fumble.home)`); set a real contact before public
  release (OSM usage policy).

## What the founder must do

1. Push and let `iOS build` run; feed compile errors back (see the risk list above).
2. Add an app icon (1024 px) to `App/Resources/Assets.xcassets/AppIcon.appiconset` before the TestFlight lane.
3. Set the GitHub secrets for `testflight.yml` (`APP_STORE_CONNECT_*`, `HOME_TEAM_ID`, `HOME_BUNDLE_ID`; optional
   `HOME_SERVER_URL` / `HOME_API_KEY`) — see `docs/setup/TESTFLIGHT.md`. In App Store Connect the app needs the
   iCloud (CloudKit) capability and Push Notifications (silent pushes drive CKSyncEngine); the CloudKit container
   `iCloud.<bundle id>` must exist and its schema will be created on first run in the development environment —
   deploy the schema to production before external TestFlight testers.
4. Decide the documented defaults that remain open (HLD §9): Plan-view "+" default (nil vs Measurement), Past
   Work/Budget tints, and whether to keep the "From: <chore>" project title.
