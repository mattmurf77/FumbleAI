# UI: Things, Measurements, Inventory, Search, People & Settings — integration notes

Owner folders: `App/Features/{Things,Measurements,Inventory,Search,People,Settings}/`. Everything reads
`@Environment(AppEnvironment.self)` and talks to HomeCore protocols only. Shared helpers live in
`App/Features/Things/Shared/` under the `TIK` namespace (pure logic in `ThingsInventoryKit.swift`, SwiftUI bits in
`ThingsInventoryKitViews.swift`), so they can't clash with other feature folders.

## Entry points for other features

| Where | Call | Presentation |
|---|---|---|
| "+" → Appliance / Electronic / Furniture | `ThingForm(spaceID: UUID?, onSaved: ((Thing) -> Void)? = nil)` | sheet (has its own NavigationStack) |
| Thing detail / deep link `home://thing/<id>` | `ThingForm(thingID: UUID, onSaved:)` | sheet |
| "+" → Measurement, room sheet Measurements | `MeasurementForm(spaceID: UUID?, onSaved: ((HomeMeasurement) -> Void)? = nil)` | sheet |
| Measurement row / `home://measurement/<id>` | `MeasurementForm(measurementID: UUID, onSaved:)` | sheet |
| "+" → Inventory item | `InventoryForm(spaceID: UUID?, onSaved: ((InventoryItem) -> Void)? = nil)` | sheet |
| "Add item here" on a spot | `InventoryForm(spotID: UUID, onSaved:)` | sheet |
| Thing "Track spares" | `InventoryForm(spareFor: Thing, onSaved:)` | sheet |
| Item row / `home://inventory/<id>` | `InventoryForm(itemID: UUID, onSaved:)` | sheet |
| Room sheet storage / Inventory menu | `StorageTreeView(spaceID: UUID? = nil)` (nil = all rooms) | push (no NavigationStack) |
| Items of one spot (multi-select → Move to…) | `StorageSpotItemsView(spotID:title:path:)` | push |
| Room sheet item rows | `TIK.InventoryRow(item:subtitle:)` | row view |
| Inventory strip | `SeasonalSwapView()`, `ShoppingListView()` | push |
| Toolbar magnifier | `SearchView(query: String = "", onOpen: ((SearchHit) -> Void)? = nil, onShowLocation: ((ItemLocation) -> Void)? = nil)` | sheet / full-screen cover |
| Toolbar gear | `SettingsView()` | sheet (has NavigationStack + Done) |
| Settings children | `PeopleEditor()`, `ExportView()`, `RecentlyDeletedView()`, `DiagnosticsView()` | push |
| Live fit banner (e.g. room sheet for planned things) | `FitBanner(item: Dims3, policy: FitPolicy, target: HomeMeasurement?, deliveryPaths: [HomeMeasurement])` | inline |
| Template fields in another form | `TemplateFields(template:attributes:calendar:today:)`, `TemplatePickerSheet(selectedKey:onPick:)` | inline / sheet |

**Plan (SearchView routing):** without `onOpen`, SearchView opens things/items/measurements in their forms, spots and
rooms in `StorageTreeView(spaceID:)`, and hands chores/projects to `env.pendingDeepLink` then dismisses. The plan
should pass `onShowLocation` to implement FR-SES-06 (switch floor → select room → flash spot pin), and `onOpen` for
room hits (open the room sheet). `pendingDeepLink` can also carry `.thing/.inventory/.measurement` refs — the plan
should open the forms above for those.

## HomeCore / HomeStore change requests

1. **Delete a person untags their items/chores (FR-INV-03).** `InMemoryPeopleRepository.delete` only soft-deletes the
   person; HomeStore should null `inventory_item.owner_id`, `storage_spot.owner_id`, `chore.assignee_id` in the same
   transaction (PeopleEditor's confirmation already tells the user this happens).
2. **Move a spot to another room (FR-INV-12, AC-INV-8).** `reparentSpot` rejects cross-room moves by design.
   Proposal: `InventoryRepository.moveSpot(_ id: UUID, toSpace: UUID, parent: UUID?)` that moves the subtree and
   updates denormalized `space_id/level_id` of the items inside + reindexes search. The UI currently only offers
   same-room moves (MoveSpotSheet).
3. **`InventoryQuery.linkedThingId`.** ThingForm (spares) and ShoppingListView ("Bought" → add spares) fetch all
   property items and filter by `linkedThingId` client-side. Add the filter for a cheap query.
4. **Per-item fit clearances (FR-MSR-22 "editable per item").** `Thing` has no clearance field; the UI uses
   `FitPolicy.default(templateKey:category:)` and shows the clearance it applies. Proposal: optional
   `thing.fit_policy_json` (`FitPolicy` is already Codable) or reserved `attributes["fitClearance"]`.
5. **Fractions in `HomeLengthFormatter.parse`.** FR-MSR-03 inputs `35 3/4`, `35¾`, `2'8½"` aren't parsed by HomeCore;
   `TIK.LengthInput.normalizeFractions` pre-normalizes them in the app (verified against HomeCore on Linux). Consider
   moving it into `HomeLengthFormatter` so the plan editor gets it too.
6. **Diagnostics: database size + schema version (FR-SES-41).** Not in `DiagnosticsService`/`DiagnosticsCounts`;
   DiagnosticsView shows everything else. Proposal: `DiagnosticsService.databaseInfo() -> (bytes: Int, schemaVersion: Int)`.
7. **`SwapLine.ownerId`.** SwapLine only carries the owner *name*, so the housemate filter matches by name (two
   housemates with the same name would be merged). Adding `ownerId` fixes it.
8. **`RecentlyDeletedRepository.purgeAll(property:)`.** "Delete all now" loops `purge` per entry.
9. **Settings events.** SettingsView calls `reminders.replan(reason: .settingsChanged)` after each save; HomeStore's
   `SettingsRepository.save` should also publish `DomainEvent.settingsChanged` for other listeners.
10. **Template catalog drift.** `server/data/templates.json` and `ThingTemplate.catalog` disagree on field keys
    (`colorTemperature` vs `colorTemp`, `screenSizeIn` vs `screenSize`), fuel options for water heaters, and which
    templates exist (server: `custom`; HomeCore: `wall_oven`, `cooktop`, `sink`, `toilet`, `bathtub`). The UI uses
    the **HomeCore catalog** for field keys (those are what gets stored/searched) and did not bundle the server JSON
    in `Resources/Templates/` to avoid a second source of truth. Server-only extras (default names like "Furnace",
    units, spare-stock name formats such as "Furnace filter {filterSize} MERV {merv}") are mirrored in
    `TIK.templateExtras`. Align the server file to the HomeCore keys (or add a HomeCore loader) before
    `/v1/templates` overrides are enabled.

## Not done here (owned elsewhere / later)

- Measurement / spot **pins on the plan** (FR-MSR-04, FR-INV-11/15): needs the PlanCanvas pin-drop UI.
- **Undo snackbar** after deletes (FR-SES-62): app-level; forms just dismiss after a soft delete.
- **Photos / manuals** on things, items, measurements, spots (AttachmentRepository UI) and "Use Measure app".
- Settings › Home **address edit / "Redo outside from address"** (Onboarding/Exterior) and the per-chore
  "Manage calendar events on this iPhone" hand-off (Chores).
- Spot **owner** editing (new sub-spots inherit the parent's owner).
- Warranty strip / thing counts on the canvas (PlanCanvas + LensStats).
