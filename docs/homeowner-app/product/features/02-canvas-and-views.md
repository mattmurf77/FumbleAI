# 02 · Canvas and Views

**Priority:** P0 · **Phase:** 1 (canvas, pills, Plan view, Settings default floor) → 2 (other views, "+", room sheet, strip) → 3 (Inventory view)
**Sources:** merged plan §1 (#1, #11, #12), §2; HLD §3.3, §5.4–5.5, ADR-09, ADR-10; LLD §6.6–6.7, §7.

## Summary
The main screen is the house: the current floor drawn like a listing plan, **floor pills** at the top, a **single-select view dropdown**, a **"+" in each room**, a **room sheet** that slides up when a room is tapped, and a **summary strip** at the bottom. The seven views change what each room shows; the geometry never changes between views.

## User stories
- As a **homeowner**, I want the app to open on my ground floor looking like a listing plan so that it feels like my house.
- As a **homeowner**, I want pill tabs to switch floors so that I can get to the basement or upstairs in one tap.
- As a **homeowner**, I want to pick a view (To-Dos, Budget…) so that the plan shows only what I care about right now.
- As a **homeowner**, I want to tap "+" in a room and add something there so that everything is filed by location without extra steps.
- As a **homeowner**, I want to tap a room and see everything in it for the current view so that I can act on it.
- As a **VoiceOver user**, I want a list version of the plan so that I can use every view without the drawing.
- As a **user whose default floor is the 2nd floor** (e.g. a condo entry level), I want to change which floor the app opens on.

## Functional requirements

### Canvas
- **FR-CNV-01** The canvas draws the active level's spaces as filled polygons with derived walls (shared edges drawn once), room names in small caps and dimensions (`12′4″ × 14′0″`, or "~" for non-rectangles and approximate rooms).
- **FR-CNV-02** Pinch to zoom and drag to pan. Lines and text stay crisp at every zoom. Double-tap zooms to the tapped room; a "fit" button resets to the whole floor.
- **FR-CNV-03** Label visibility depends on the room's on-screen size (LLD §6.7): large rooms show name + dimensions + "+" + chip; medium show name + "+" + chip; small show name only (the "+" moves to the room sheet header); tiny show nothing but stay tappable (22 pt minimum hit radius).
- **FR-CNV-04** Tapping a room selects it (highlight) and opens its room sheet at half height. Tapping empty canvas deselects and closes the sheet.
- **FR-CNV-05** Performance: pan/pinch frame ≤ 8 ms on iPhone 15 Pro at 120 Hz with 60 spaces; cold launch to interactive canvas ≤ 1.0 s on iPhone XS; view switch ≤ 100 ms.

### Floor pills
- **FR-CNV-10** Pills list the levels in elevation order (Basement, Ground/1st Floor, 2nd Floor, Attic) with the exterior level ("Outside") last. *Open question Q-12 (PRD).*
- **FR-CNV-11** Floors change **only** by tapping pills in v1. Horizontal swipes on the canvas pan; they never change floors (decision #12).
- **FR-CNV-12** A trailing pill "+" opens Add floor (spec 01, FR-PLN-06).
- **FR-CNV-13** The app opens on the property's **default floor**, which is Ground unless changed in Settings (spec 09). The last-used view is remembered per device; the floor always resets to the default on cold launch. The default floor is stored once per property and syncs. *Assumption pending founder confirmation (HLD §9-14).*
- **FR-CNV-14** If the default floor was deleted, the app opens on the lowest non-basement floor (sort order 0) and Settings shows the new default.

### View dropdown (seven views)
- **FR-CNV-20** A single-select dropdown (mockup 3.1) lists, in order: **Plan** (default), **To-Dos**, **Future Projects**, **Past Work**, **Appliances, Electronics & Furniture**, **Inventory**, **Budget**. Each has an icon; a checkmark shows the active one.
- **FR-CNV-21** Each view draws per room as follows (merged plan §2, LLD §7.4):

| View | Room chip / badge | Tint / edge / pins | Summary strip example |
|---|---|---|---|
| Plan | none; name + dimensions | listing white | "1st Floor · 1,240 sq ft · 9 rooms" |
| To-Dos | count due in the next 7 days; bold if any due today; "!" if overdue | **red 3 pt edge + "!"** when anything is overdue | "7 due this week · 2 overdue" |
| Future Projects | planned $ (e.g. "$4.2k"), plus count when ≥ 2; "3 ideas" when only ideas | single-hue tint by planned $ (see Q-1) | "$18.4k planned · 3 in progress" |
| Past Work | lifetime spent + month last worked ("$12.1k · Mar ’26") | light tint by spent | "$41.7k spent on this floor since 2019" |
| Appliances, Electronics & Furniture | item count | icon at each thing's pin; unpinned things in a row under the label; planned purchases dashed | "23 items · 2 warranties end in 60 days" |
| Inventory | item count; orange dot if any low | storage-spot pins with counts | "142 items · 5 low · 3 expiring" (strip links to Shopping list and Seasonal swap) |
| Budget | "planned / spent" per room | tint by planned + spent, relative to the property | "Floor: $18.4k / $6.2k · Home: $52k / $48k" |

- **FR-CNV-22** Color is never the only signal: overdue uses edge **and** "!"; tints always have a numeric chip; the tint ramp is color-blind-safe.
- **FR-CNV-23** Rooms with nothing in the current view fade their label to grey (mockup section 01 note). *P2.*
- **FR-CNV-24** Views apply identically on the exterior level (e.g. Future Projects tints the Patio zone).
- **FR-CNV-25** A **"Whole house · N" / "This floor · N"** chip under the pills shows items scoped to the property or the level for the active view; tapping it opens a sheet like the room sheet for that scope.

### "+" add picker
- **FR-CNV-30** Each room shows a 32 pt "+" (44 pt hit area) placed at the room's visual center, below the label.
- **FR-CNV-31** Tapping "+" opens the add picker (mockup 3.2) with six types: **To-Do, Future Project, Past Work, Appliance/Electronic/Furniture, Inventory item, Measurement**.
- **FR-CNV-32** The active view's type is preselected and marked "Default": To-Dos → To-Do; Future Projects → Future Project; Past Work → Past Work; Appliances → Appliance; Inventory → Inventory item; Budget → Future Project; Plan → nothing preselected.
- **FR-CNV-33** The new item's scope is prefilled with that room (and its floor). The form lets the user change scope to "This floor" or "Whole house".
- **FR-CNV-34** A new item needs only a title to save (plus the minimum fields each spec lists). After saving, the room's chip updates within 100 ms without leaving the canvas.
- **FR-CNV-35** Past Work opens the project form with status Done preselected and the Done fields (actual cost, date, receipt) shown.

### Room sheet
- **FR-CNV-40** The room sheet has half and full detents; the selected room stays highlighted and visible above it at half height. It opens in ≤ 150 ms.
- **FR-CNV-41** Header: room name (tap to rename), type, dimensions and area, and a "+" button.
- **FR-CNV-42** Body depends on the active view:
  - Plan: dimensions, measurements, doors/windows, photos, and a count per kind ("3 chores · 2 projects · 5 things · 14 inventory") that switches views on tap.
  - To-Dos: grouped **Overdue / Today / This week / Later** with checkboxes to complete (mockup 3.3).
  - Future Projects: projects by status (In Progress, Planned, Idea) with estimates.
  - Past Work: done projects, newest first, with actual cost and date; room lifetime total.
  - Appliances: things by category, with warranty and fit badges.
  - Inventory: storage spots as an expandable tree with item counts, then loose items.
  - Budget: planned, ideas, spent, remaining, variance, and hours for the room; link to the Budget drill-down (spec 05).
- **FR-CNV-43** Swiping a row offers context actions (complete/skip for chores; mark done for projects; delete for all).

### Accessibility
- **FR-CNV-50** Each room is one accessibility element: label = room name, value = view-dependent summary ("13 by 11 feet, 3 chores due this week, 1 overdue"), actions Open, Add item, Rename.
- **FR-CNV-51** A toolbar toggle switches to a **list view** grouped by floor → room with the same view stats; it is the default when VoiceOver is running.
- **FR-CNV-52** Dynamic Type applies everywhere outside the canvas; canvas labels scale up to 1.4×. Reduce Motion replaces zoom animations with cross-fades.
- **FR-CNV-53** A VoiceOver rotor entry "Rooms with overdue chores".

## Acceptance criteria
- **AC-CNV-1** *Given* a property with Basement, Ground and 2nd Floor and default floor Ground, *when* the app cold-launches, *then* the Ground pill is selected and the Plan view (or the last-used view) is shown.
- **AC-CNV-2** *Given* the user is on Ground, *when* they swipe horizontally on the canvas, *then* the canvas pans and the floor does not change.
- **AC-CNV-3** *Given* the To-Dos view and a Kitchen chore due yesterday, *then* the Kitchen shows a red edge **and** a "!" badge, and its accessibility value includes "1 overdue".
- **AC-CNV-4** *Given* the Inventory view, *when* the user taps "+" in the Attic, *then* the picker opens with "Inventory item" preselected, and the form's location is "Attic".
- **AC-CNV-5** *Given* the Plan view, *when* the user taps "+", *then* no type is preselected.
- **AC-CNV-6** *Given* a closet too small for a "+", *when* the user taps the closet, *then* the room sheet opens and its header has a "+".
- **AC-CNV-7** *Given* the Budget view with Kitchen planned $4,200 and spent $1,100, *then* the Kitchen chip reads "$4.2k / $1.1k" and the strip shows floor and home totals.
- **AC-CNV-8** *Given* a chore scoped to "Whole house", *when* the To-Dos view is active, *then* the "Whole house · 1" chip is shown and no room counts it.
- **AC-CNV-9** *Given* VoiceOver is on, *when* the app launches, *then* the list view is shown instead of the canvas.
- **AC-CNV-10** *Given* the user changes the default floor to 2nd Floor in Settings on iPhone A, *when* iPhone B syncs and cold-launches, *then* it opens on 2nd Floor.

## Edge cases
- A property with only an exterior level (plan skipped): the canvas opens on Outside; "Add a floor" is prominent.
- Two rooms overlap (e.g. garden bed inside backyard): a tap selects the smaller one.
- Pins closer than 20 pt cluster into a count bubble; tapping it zooms in.
- More than 40 overlays visible: chips and pins fade during a pinch and return after (the "+" buttons stay).
- An item scoped to a room that was deleted: shows under the destination the user picked (spec 01, FR-PLN-48).
- Dark mode: all tints and edges keep contrast ≥ 3:1 against the room fill.

## Empty and error states
| State | Behavior |
|---|---|
| View has no data on this floor | Strip shows a friendly zero ("No chores due this week"); every room's label is grey (if FR-CNV-23 ships) |
| Room sheet with nothing for the view | "Nothing here yet" + the view's add button |
| Level geometry fails to render (corrupt polygon) | That room is skipped, the others render, and Diagnostics logs the space ID |

## Data touched (LLD)
Reads `level`, `space`, `opening`, and per-view stats from `chore`, `project`, `cost_line_item`, `thing`, `inventory_item`, `storage_spot`; writes `space.name` (rename), `property.default_level_id`. Preferences (last view) in device-local storage.

## UI references
Mockups **2.1–2.11** (the seven views and other levels), **3.1** View dropdown, **3.2** "+" add picker, **3.3** Room sheet: Kitchen, To-Dos; section 01 live prototype.

## Analytics / diagnostics
Signposts for cold launch, frame time, view switch (≤ 100 ms), room-sheet open (≤ 150 ms). No event tracking. Diagnostics counts: items per kind, scope distribution (room/floor/whole house).

## Out of scope
Swipe to change floors (post-TestFlight experiment); user-defined views; 3D; multi-select views; iPad layout.

## Assumptions pending founder confirmation
HLD §9-14 (default floor stored once per property). Also PRD open questions Q-1 (tint scale) and Q-12 (Outside as a pill).
