# HomeSchedule + Chores / Projects / Budget — integration notes

Owner: reminders / calendar / chores / projects / budget workstream.
Files: `Packages/HomeSchedule/**`, `App/Features/{Chores,Projects,Budget}/**`.

## 1. Composition root (`App/AppEnvironment.swift`, `AppEnvironment.live()`)

```swift
import HomeSchedule

var d = AppDependencies.inMemory(sample: true, config: config)   // or the HomeStore-backed deps
// … HomeStore swaps first (repositories must be real before these are built) …

// INTEGRATION: HomeSchedule
let device = KeychainDeviceIdentity()                 // Keychain device id + nickname (UserDefaults)
d.device = device
let reminders = ReminderScheduler(chores: d.chores, plan: d.plan, inventory: d.inventory, people: d.people,
                                  settings: d.settings, clock: d.clock)   // live UNUserNotificationCenter, 500 ms debounce
d.reminders = reminders
d.notificationAuth = reminders                        // same actor implements NotificationAuthorizing
let calendarSync = CalendarSync(chores: d.chores, plan: d.plan, settings: d.settings, device: device, clock: d.clock)
d.calendar = calendarSync                             // live EventKitCalendarStore
Task { await calendarSync.startObservingStoreChanges() }   // .EKEventStoreChanged → reconcileOwned (2 s debounce)
```

Full initializer signatures (all extra parameters have defaults; tests inject fakes):

```swift
ReminderScheduler(chores: any ChoreRepository, plan: any PlanRepository,
                  inventory: (any InventoryRepository)? = nil, people: (any PeopleRepository)? = nil,
                  settings: any SettingsRepository, clock: any HomeClock = SystemClock(),
                  center: any NotificationCenterProtocol = makeDefaultNotificationCenter(),
                  localStore: any LocalKeyValueStore = UserDefaultsKeyValueStore(), debounce: TimeInterval = 0.5)

CalendarSync(chores: any ChoreRepository, plan: any PlanRepository, settings: any SettingsRepository,
             device: any DeviceIdentity, clock: any HomeClock = SystemClock(),
             store: any CalendarStoreProtocol = makeDefaultCalendarStore(),
             localStore: any LocalKeyValueStore = UserDefaultsKeyValueStore())
```

`makeDefaultNotificationCenter()` / `makeDefaultCalendarStore()` return the UserNotifications / EventKit implementations on
Apple platforms and in-memory fakes elsewhere (Linux CI).

## 2. Notification delegate (`App/HomeApp.swift`)

```swift
import HomeSchedule

final class AppDelegate: NSObject, UIApplicationDelegate {
    let notificationHandler = NotificationActionHandler()
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        notificationHandler.install()        // sets UNUserNotificationCenter delegate + CHORE_DUE / SYSTEM categories
        return true
    }
}

// HomeApp.body, on the root view:
.task {
    appDelegate.notificationHandler.configure(
        actions: NotificationActions(chores: env.chores, reminders: env.reminders, clock: env.clock),
        onOpen: { url in env.handle(url: url) })          // body tap → home://chore/<uuid> → env.pendingDeepLink
    await env.start()
}
```

`install()` must run before `didFinishLaunching` returns so a "Done" tap that launched the app is delivered. Responses
that arrive before `configure` wait up to ~4 s; body-tap URLs are buffered and replayed on `configure`.
DONE completes with `by: nil` (PRD Q-5) and replans; SNOOZE_1H records a snooze (max 2) and replans; completion handler
is called when done (≈ < 1 s).

## 3. AppEnvironment reaction loop — requested additions (App root is not mine to edit)

- `.syncApplied(recordTypes:ids:)` containing `Chore` / `ChoreCalendarLink`: call `await calendar.reconcileOwned()` (or
  `choreChanged(id)` per chore id). Without it, the owner device only applies edits made on another device at the next
  launch / BG refresh / EKEventStoreChanged (AC-CHR-12 still holds, just later).
- `.restored(.chore(id))` → `await calendar.choreChanged(id)`.
- Post `.timeZoneChanged` (or call `reminders.replan(reason: .timeZoneChanged)`) on `NSSystemTimeZoneDidChange` and
  `UIApplication.significantTimeChangeNotification` (LLD §9.3 replan triggers).
- `Settings › device nickname` should call `KeychainDeviceIdentity.setNickname(_:)` (it is `d.device` in live).

## 4. HomeCore change requests (not made — HomeCore is frozen for this workstream)

1. **Owner nickname on the link.** `ChoreCalendarLink` has no owner nickname, so non-owner devices show
   "Calendar events are managed on ‘another device’". Add `ownerDeviceNickname: String?` (LLD §9.5 says the link stores it);
   `CalendarSync.ownership` and `enable/adoptOwnership` will fill/read it.
2. **"Removed from your calendar outside Home" note.** Detected and stored by `CalendarSync` (`wasRemovedOutsideHome(chore:)`,
   `clearRemovedNote(chore:)`), but `CalendarSyncing` has no way to expose it to feature code. Proposed: add
   `case removedOutsideHome` to `CalendarOwnership`, or `func removedOutsideHome(chore:) async -> Bool` to the protocol.
3. **Undo complete/skip (FR-CHR-25).** `ChoreRepository` can't delete a completion. The detail's 5 s Undo currently only
   restores the previous due date via `reschedule`, so the completion stays in history. Proposed:
   `func undoCompletion(_ completionId: UUID, restoreDue: LocalDate?) async throws` (soft-delete + recompute).
4. **Diagnostics.** `ReminderStatus` has no `lastError`; `ReminderScheduler.lastError` / `CalendarSync.lastError` exist on the
   concrete actors. Proposed: `ReminderStatus.lastError: String?` and `CalendarSyncing.diagnostics()`.
5. **"Turn into project" title.** FR-CHR-32 wants "From: <chore title>"; `ChoreLogic.projectDraft` copies the title verbatim.
6. **Local-only tables.** `notification_snooze` and `calendar_event_cache` (LLD §3.3) live in UserDefaults through
   `LocalKeyValueStore` (suite `app.fumble.home.schedule`). HomeStore may provide a GRDB-backed `LocalKeyValueStore` and
   pass it as `localStore:`; nothing else changes.

## 5. Behaviour notes / deviations

- **Pause keeps the link.** On pause the owner removes future events but keeps a dormant link (`eventExternalId = nil`)
  so the same device re-creates the series on resume (FR-CHR-26). Toggle-off and delete soft-delete the link (LLD).
- **Non-owner toggle-off** does not delete the link: the synced `calendarEnabled = false` makes the owner remove its
  events and the link on its next push/reconcile.
- **Series edits** resolve the next occurrence on/after today and save with `.futureEvents`; the new part starts at the
  first occurrence of the (new) rule on/after that day, so an overdue chore never back-fills or duplicates.
- **Single events** (completion-anchored / one-off): completing moves a future event to the new due date, otherwise
  leaves the past one as history and creates a new one (the signature includes the due date).
- `CalendarSync` does not debounce `choreChanged` (only store-change reconcile is debounced 2 s); pushes are no-ops
  when the stored `seriesSignature` matches.
- The Settings reminder defaults (all-day time, offset, badge, pantry digest) are read on every replan; Settings should
  `reminders.replan(reason: .settingsChanged)` after saving (`.settingsChanged` domain event already does it).
- Spare-stock prompt after completing a linked chore (FR-CHR-31, P2) is not implemented.
- Budget drill-down uses `RollupService` only; the per-room project list fetches line items per project to show
  effective spent (fine at v1 scale).

## 6. Feature entry points (App/Features)

```swift
ChoreForm(spaceID: UUID?, levelID: UUID?, onSaved: ((Chore) -> Void)? = nil)      // present modally
ChoreForm(choreID: UUID, onSaved: ((Chore) -> Void)? = nil)                         // edit, modal
ChoreDetailView(choreID: UUID)                                                       // push
ChoreRow(chore: Chore, today: LocalDate, place: String? = nil, assignee: String? = nil, onComplete: (() -> Void)? = nil)
ToDosListView(scope: Scope? = nil, levelID: UUID? = nil, title: String = "To-Dos")   // push
RepeatRulePicker(rule: Binding<RepeatRule?>, startOn: LocalDate)                     // Form rows
ReminderToggle(isOn: Binding<Bool>, offsetMinutes: Binding<Int>, dueMinutes: MinuteOfDay?)
CalendarPicker(selection: Binding<String?>)                                          // push
ChoreCalendarSection(choreId: UUID?, rule: RepeatRule?, isOn: Binding<Bool>, calendarId: Binding<String?>)

ProjectForm(spaceID: UUID?, levelID: UUID?, initialStatus: Project.Status, onSaved: ((Project) -> Void)? = nil)  // modal
ProjectForm(projectID: UUID, onSaved: ((Project) -> Void)? = nil)                   // edit, modal
ProjectDetailView(projectID: UUID)                                                   // push
DoneSheet(project: Project, lineItems: [CostLineItem], onDone: (() -> Void)? = nil)  // modal
ReceiptScanButton(title: String = "Scan receipt", onScanned: (ScannedReceipt) -> Void)  // uses env.receipts

BudgetDrillDown()                                                                    // push
BudgetFloorView(levelID: UUID, levelName: String)
BudgetProjectsList(scope: Scope, title: String)
```
