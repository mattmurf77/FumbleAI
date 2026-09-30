# Home hub ("What would you like to do?"): integration notes

Owner: home-hub engineer. Files: `App/Features/Home/**` (new) and this note. I made no edits to RootView,
AppEnvironment, HomeApp, `App/Features/Plan/**` or any package.

| File | What it holds |
|---|---|
| `App/Features/Home/HomeHubCatalog.swift` | Pure logic, Foundation + HomeCore only: `HubRoute`, `HubSheet`, `HubAction`, `HubCounts` (the `apply(...)` reducers), `HubCard`, `HubSection`, `HomeHubCatalog` (card list, summary line, subtitle). |
| `App/Features/Home/HomeHubModel.swift` | `@MainActor @Observable HomeHubModel`: observes the current property, then chores, property rollup, things, inventory items, shopping list, seasonal swap, levels and people. |
| `App/Features/Home/HomeHubView.swift` | `HomeHubView` (the landing screen and the app's `NavigationStack` root), `HubCardView`, `HubWideCardView`, `HubSymbolTile`, `HubBadge`, `HubPressStyle`, `HubGridPaper`, `HubPlanHint`, `YardSetupSheet`, and the `#Preview`s. |

New app-module names (all prefixed `Hub`/`HomeHub`, plus `YardSetupSheet`): nothing else in the app uses them.
Run `xcodegen generate` again so the new `Features/Home` group appears. `project.yml` needs no changes because `App/` is already a source path.

## 1. RootView change (required)

In `App/RootView.swift`, show the hub instead of the plan once a property exists. The hub owns its own
`NavigationStack`, so do **not** wrap it in one:

```swift
            } else if showOnboarding {
                OnboardingFlow(onFinished: { showOnboarding = false })
            } else {
-               PlanScreen()
+               HomeHubView()
            }
```

Keep everything else (the `.task` property observation, the alerts, and the feedback overlay that is being added)
around the `Group`. Also update the doc comment ("…else the Plan screen" → "…else the home hub"), and update
the `#Preview`s if you like; they already work unchanged.

## 2. How navigation works

- `HomeHubView` is the **root of a `NavigationStack(path:)`**. Its own navigation bar is hidden (`.toolbar(.hidden, for: .navigationBar)`). It sets
  `navigationTitle("Home")`, so pushed screens show a "‹ Home" back button.
- **Lens cards** (Floor plan, Future Projects, Past Work, Appliances…, plus each "See on floor plan" link) set
  `env.selectedLens = <lens>` and push `PlanScreen()`. `PlanScreenModel.run` reads `env.selectedLens` when it
  starts, so the plan opens on that view. No Plan changes are needed for this.
- **Dedicated list screens** are pushed as the card's primary action. Each such card also has a secondary "See on
  floor plan" link that opens the lens:
  To-Dos → `ToDosListView()`, Budget → `BudgetDrillDown()`, Inventory → `StorageTreeView()`. These three have both.
  Shopping list → `ShoppingListView()`, Seasonal swap → `SeasonalSwapView()`, Housemates → `PeopleEditor()`.
  All six are "pushable" (no NavigationStack of their own).
- **Sheets** (screens that bring their own `NavigationStack`): Search → `SearchView()`, Settings → `SettingsView()`,
  and `YardSetupSheet`.
- **Yard & Exterior**:
  - If the property has an exterior level, the card pushes the plan with that level id (see §3).
  - If it has none, the card opens `YardSetupSheet`, which offers two paths:
    - "Map it from my address" runs the same exterior seeding as onboarding: `env.exteriorSeeder.exteriorLevel(for:)`, then `planCommitter.commit(… source: .autoseed)`, plus a best-effort satellite snapshot. It needs `property.coordinate`.
    - "Draw it myself" opens the editor's existing `AddFloorSheet(property:onAdded:)`, where the user picks Kind › Outside.

    Either path then pushes the plan.
- **Deep links**: `PlanScreen` is no longer always on screen, so the hub watches `env.pendingDeepLink`.
  Notification taps, `home://…` URLs, and chore/project hits from `SearchView` all set it. When it changes (or is already set when the hub appears), the hub dismisses any hub sheet and pushes the plan, unless the plan is already on top. `PlanScreen` then consumes the link as before, through its `onChange(of: model.loaded)` and `onChange(of: env.pendingDeepLink)` handlers.
- **PlanScreen and NavigationStack**: I checked this, and there is no double stack. `PlanScreen` does not wrap itself in a
  `NavigationStack`. Its own presentations (room sheet, add picker, search, settings, add floor, footer links) are
  all sheets, and the ones that need navigation create their own stack inside the sheet. The only visible effect
  of pushing it is a standard inline navigation bar with "‹ Home" above PlanScreen's custom header. The hub gives that bar
  the paper background.

## 3. PlanScreen change (small, for "Yard & Exterior" opening on the Outside level)

Today `PlanScreen` can't be told which floor to open. `PlanScreenModel.observeLevels` always picks
`defaultLevel(preferred: property.defaultLevelId)`. Until the change below lands, the hub pushes the plan and
shows a 5-second hint over it: "Tap “Outside” in the floor pills" (`HubPlanHint`).

**`App/Features/Plan/PlanScreenModel.swift`**:

```swift
    var lens: LensID = .plan
+   /// One-shot floor request (the home hub's "Yard & Exterior" card): used instead of the default floor when the
+   /// levels first load, then cleared.
+   var preferredLevelId: UUID?
```

and in `observeLevels(env:)`:

```swift
                if self.levelId == nil || !sorted.contains(where: { $0.id == self.levelId }) {
                    // Cold launch / deleted level: the property's default floor (FR-CNV-13/14).
-                   if let l = sorted.defaultLevel(preferred: self.property?.defaultLevelId) { self.select(level: l.id, env: env) }
+                   let requested = self.preferredLevelId.flatMap { id in sorted.first { $0.id == id } }
+                   if requested != nil { self.preferredLevelId = nil }
+                   if let l = requested ?? sorted.defaultLevel(preferred: self.property?.defaultLevelId) { self.select(level: l.id, env: env) }
                }
```

**`App/Features/Plan/PlanScreen.swift`**: add a parameter. `PlanScreen` has private `@State` properties, so
the memberwise init would be private. Add an explicit init:

```swift
struct PlanScreen: View {
    @Environment(AppEnvironment.self) private var env
    ...
+   /// Floor to open instead of the default one (the home hub passes the exterior level).
+   private let initialLevelID: UUID?
+
+   init(initialLevelID: UUID? = nil) { self.initialLevelID = initialLevelID }
    ...
-       .task { await model.run(env: env) }
+       .task {
+           model.preferredLevelId = initialLevelID
+           await model.run(env: env)
+       }
```

`PlanScreen()` keeps working everywhere else. Then, in **`App/Features/Home/HomeHubView.swift`**
`planScreen(levelID:)` (marked `INTEGRATION(home-hub)`), replace `PlanScreen()` with
`PlanScreen(initialLevelID: levelID)` and delete the `.overlay(alignment: .bottom) { … HubPlanHint … }` block.
The home-hub owner or the orchestrator can make that edit; it is inside `Features/Home`.

## 4. Optional PlanScreen polish (not required)

- **Edge swipe**: the interactive "swipe from the left edge to go back" now exists on the plan. In QA, check that
  a pan starting at the left edge of the canvas still pans instead of popping. If it conflicts, PlanScreen could hide the bar
  (`.toolbar(.hidden, for: .navigationBar)`) and add a "house" circle button to its header that calls `dismiss()`.
  This would also recover the ~44 pt the navigation bar takes.
- **Lens persistence**: the hub sets `env.selectedLens` but does not write `AppSettings.lastLens`. `PlanScreenModel`
  persists the lens when the user changes it from the dropdown, so the lens a hub card opened is only remembered once
  the user touches the dropdown. This is harmless, because the hub is the landing screen now.

## 5. Verification

- `HomeHubCatalog.swift` and `HomeHubModel.swift` were compiled and run in a scratch SwiftPM package against the
  real `HomeCore`/`HomeCoreTesting` (with a minimal `AppEnvironment` stand-in exposing the same property names).
  On the sample house it prints:
  `Maple Street · 12 Maple St, Springfield, IL 62701` /
  `1 chore due today · 1 overdue · $3.6k planned · 2 running low`, with badges:
  - Floor plan: 3 floors
  - To-Dos: 1 overdue
  - Future Projects: 3
  - Past Work: 1
  - Budget: $3.6k
  - Appliances, Electronics & Furniture: 5
  - Inventory: 2 low
  - Shopping list: 2
  - Seasonal swap: 3
  - Housemates: 2

  With no exterior level, the Yard card's action is `.sheet(.addYard)`.
- `HomeHubView.swift` only got `swiftc -parse` (SwiftUI isn't available on Linux). It uses iOS 17 APIs only:
  `NavigationStack(path:)`, `navigationDestination(for:)`, `Grid`, `ContentUnavailableView`,
  `toolbar(.hidden, for:)`, `toolbarBackground(_:for:)`, `onChange(of:) { _, new in }`. The calls into other features use the
  signatures in the current files: `ToDosListView()`, `BudgetDrillDown()`, `StorageTreeView()`,
  `ShoppingListView()`, `SeasonalSwapView()`, `PeopleEditor()`, `SearchView()`, `SettingsView()`,
  `AddFloorSheet(property:onAdded:)`, `OnboardingModel.footprintUnavailableTag`, `PlanTheme.forScheme(_:)`.
