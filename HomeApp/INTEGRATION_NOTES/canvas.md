# Canvas & Plan UI — integration notes

Owner: canvas/plan engineer. Files: `Packages/PlanCanvas/**`, `App/Features/{Plan,RoomSheet,Add,Editor}/**`.
No edits were made to HomeCore, PlanKit, project.yml, AppEnvironment, HomeApp or RootView.

## 1. Wiring needed at integration

| Where | Change |
|---|---|
| `App/RootView.swift` | Replace the placeholder body with `PlanScreen()` when a property exists, and the Onboarding flow when `env.plan.currentProperty()` is nil. `PlanScreen` shows a "No home yet" overlay by itself if it runs with no property. |
| Budget drill-down | `PlanScreen.footerTapAction` returns nil for `FooterLink.budget` (marked `INTEGRATION:`). Present the Budget feature's screen there when it lands. |
| Detail screens | `ItemDetailRouter` (`App/Features/RoomSheet/RoomSheet.swift`) pushes `ChoreDetailView(choreID:)`. Projects, Things, Inventory items and Measurements open modally in their edit forms (`ProjectForm(projectID:)`, `ThingForm(thingID:)`, `InventoryForm(itemID:)`, `MeasurementForm(measurementID:)`). Swap these for detail screens as the owning features add them. |
| Settings | "Show plan as a list" reads `AppSettings.showPlanAsList`. The canvas switches to `PlanListView` when that setting is on or VoiceOver is running. The header also has a list/plan toggle for the session. |

Views from other features that this code calls. All of them existed with these signatures when I checked:
`ChoreForm(spaceID:levelID:)`, `ProjectForm(spaceID:levelID:initialStatus:)` (typed `Project.Status`, not `ProjectStatus`; we pass `.idea` / `.done`), `ThingForm(spaceID:)`, `InventoryForm(spaceID:)`, `MeasurementForm(spaceID:)`, `ChoreDetailView(choreID:)`, `SearchView(onShowLocation:)`, `SettingsView()`, `ShoppingListView()`, `SeasonalSwapView()`, `ToDosListView()`.

## 2. Public names (the App target is one module, so these names are taken)

- **Plan**: `PlanScreen()`, `PlanScreenModel`, `RoomSheetTarget`, `AddRequest`, `FooterLinkTarget`
- **RoomSheet**: `RoomSheet(spaceId:lens:onEditShape:)`, `RoomSheet(scope:lens:)`, `RoomSheetModel`, `ItemSheetRef`, `ItemDetailRouter(ref:)`
- **Add**: `enum AddDestination` (`init(kind:spaceID:levelID:)`), `AddRouter(destination:)`, `AddPicker(spaceID:levelID:preselected:placeName:)`, `AddKindInfo`
- **Editor**: `PlanEditorOverlay(geometry:property:viewport:initialSelection:onFinish:onLevelAdded:accessory:)`, `PlanEditorModel`, `AddFloorSheet(property:onAdded:)`

PlanCanvas (public): `PlanCanvasView`, `PlanListView`, `SummaryStripView`, `ScopeChipsView`, `ChipView`, `PinView`, `AddButtonView`, `PlanTheme`, `Painter`, `Viewport`, `GestureController`, `Momentum`, `LevelRenderModel`, `RenderModelBuilder`, `PoleCache`, `PlanLens` plus the 7 lenses (`LensRegistry.lens(for:)`), `OverlayLayout`, `CanvasHitTesting`, `AccessibilityModel`, `PlanEditSession`, `EditorOverlayState`, `LensFormat`, `planSymbolName(_:)`.
PlanCanvas has no `FillStyle` type, because that name clashes with SwiftUI. The room fill enum is called `RoomFill`.

## 3. Requests for HomeCore / HomeStore (I did not edit these; please pick up)

1. **`ScopeStats.spotCount`.** The Inventory view's second line should read "N spots" (seven-views §6). Stats don't carry that number today, so the line shows "N low" instead.
2. **Footer detail.** Optional `LensStats` fields for the To-Dos strip ("Next: Do the dishes · Sam · today") and the Things strip ("Furnace filter 16×25×1 due Oct 2"). Until then these lines show home-wide totals.
3. **Budget tint relative to the property.** PRD Q-1 says the Budget tint is relative to the property. `LensContext.budgetScaleMaxCents` is already wired. It needs the largest per-room `planned + spent` across all levels, for example as a `LensStats` field. Until then the tint is relative to the busiest room on the current level.
4. **Editor persistence** goes through `PlanRepository.updateSpaces` / `saveOpening` / `deleteOpening`, saving each time a finger lifts. `PlanCommitting` only creates new levels, so it is used only by **Add floor**. HomeStore needs to support two things:
   - Editor **Cancel** restores rooms deleted during the session by sending `.insert(originalSpace)` for a soft-deleted id. HomeStore's `updateSpaces` must treat that as an upsert/restore, as the in-memory implementation does.
   - When HomeStore welds on commit, the editor keeps its own working copy. That is harmless: the next save sends the editor's shapes again.
5. **Plan view "+" default.** The code uses `LensID.addDefault` (nil for Plan, matching AC-CNV-5). `seven-views.md` §1 says Measurement. If the founder wants Measurement, change it in HomeCore and nothing else needs to change.

## 4. Decisions and deviations (documented defaults)

- **Tints** follow the PRD Q-1 default: fixed steps for Future Projects (< $1k, $1k–$5k, ≥ $5k). Past Work gets a light relative ramp (up to tint-2). Budget gets a relative ramp. seven-views gives Past Work and Budget no tint, but the PRD default wins.
- **Walls.** Perimeter width is `clamp(6 in·s, 2, 9)` pt as in the LLD. Interior walls use `clamp(1.7 in·s, 1.1, 4)` pt to match the listing-plan look in the mockup (1.3 pt at the default zoom) instead of the LLD's 4.5 in. Approximate rooms get dashed walls.
- **Theme.** Colors come from the mockup tokens (`--paper`, `--wall`, `--accent`, `--tint-*`, …). Dark mode uses the mockup's dark palette, not the LLD's navy "blueprint".
- **Label LOD** follows LLD §6.7 (radius ≥ 48 / 30 / 18 pt). Very narrow rooms (under 5′6″) get short names ("½ Bath", "Cl."). The seven-views "small rooms put the name on the top edge" variant is not implemented. Canvas text is a fixed point size and does not yet scale 1.4× with Dynamic Type (FR-CNV-52).
- **Momentum and animations** run in a `@MainActor` Task loop (8 ms steps) instead of `TimelineView`. Reduce Motion jumps straight to the target.
- **Zoom limits** are `[fit·0.8, max(fit·8, 12.5)]` (LLD). Pan is always allowed but clamped so at least 64 pt of the plan stays on screen. Floors never change on swipe.
- **Editor snapping.** The grid is 6 in, or 1 in with **Fine**. The drawn grid is 1 ft. Corner drags keep axis-aligned edges orthogonal by moving the neighbouring vertices with them. Edge drags move shared walls together and stop at the last valid position. A drag may not turn a room inside out. Overlapping rooms block saving: they get a red outline and a banner, and Done offers "Discard changes".
- **Typed dimensions** move the right or bottom wall, taking neighbours along. They upsert a `HomeMeasurement(kind: .wall, source: .planEdit, label: "<room> width|depth")`.

## 5. Not done / stubbed

- The underlay is not drawn: no photo-trace image and no exterior satellite snapshot. Adding it needs the image (`AttachmentRepository.fileURL`, `SatelliteSnapshotting`) plus a `LevelRenderModel` underlay field; the Painter would draw it as layer 1.
- The exterior `georef` rotation is not applied.
- The Budget drill-down link is still a hook (see §1).

## 6. Tests

`cd HomeApp/Packages/PlanCanvas && swift test` runs 49 tests, all passing on Linux (Swift 6.4, Swift 5 mode). They cover viewport math, gestures and momentum, the render model and walls/doors, all 7 lenses (including AC-CNV-3/5/7/8), label LOD and overlay layout, pin clustering, hit-testing, accessibility, and the editor (edge drag with shared walls, clamping, orthogonal corner drag, move with snapping, typed dimensions, add/split/merge/delete diff, door placement, undo limit).
The SwiftUI files only get a syntax check (`swiftc -parse`) on Linux. `PlanScreenModel`, `RoomSheetModel` and `PlanEditorModel` type-check together with `AppEnvironment.swift` in a scratch package against the real HomeCore/PlanCanvas modules.
