# 01 · Floor Plan Creation and Plan Editor

**Priority:** P0 (Trace a photo, split/merge, hand-placed openings and multi-floor alignment are P1) · **Phase:** 1 (Plan core)
**Sources:** merged plan §4; HLD §4.1–4.4, ADR-08, ADR-17; LLD §3.2 (`property`, `level`, `space`, `opening`), §6.2–6.13.

## Summary
Four ways to create a floor plan, all producing the same editable geometry (a `PlanDraft` committed in one transaction):
1. **Scan** a room with a LiDAR iPhone (Apple RoomPlan).
2. **Build with blocks:** drag rooms from a house-style template and type dimensions.
3. **Trace a photo** of an existing plan (listing screenshot, closing documents), scaled with two taps and a known length.
4. **Rough it in:** proportional boxes from approximate square footage, in about 60 s.

A **plan editor** lets the user fix any plan: move, resize, type dimensions, add, delete, split, merge, rename. MLS and public-record imports are not sources (founder).

## User stories
- As a **new buyer with a LiDAR iPhone**, I want to scan each room so that my plan has real dimensions without measuring by hand.
- As an **owner who is "not good at drawing"**, I want to answer a few questions and get a plan in about a minute so that I can start tracking things right away.
- As an **owner with a listing floor plan**, I want to trace over a photo of it so that my plan matches the real layout.
- As a **user whose plan is wrong**, I want to drag walls and type exact lengths so that the plan matches my house.
- As **any user**, I want to name rooms however I like ("Sewing room", "Kid 1's room") so that the plan reads like my house.
- As a **user who scanned a floor that isn't in the plan yet**, I want to add another floor later so that I can grow the plan over time.

## Functional requirements

### Onboarding entry
- **FR-PLN-01** On first launch, before showing creation paths, the app runs a restore check against iCloud (timeout 8 s). If a home exists, it shows "Restoring your home…" instead (see spec 10, FR-SYN-20).
- **FR-PLN-02** The onboarding screen (mockup 6.1) asks for an optional address (typed, with autocomplete; no location permission — *Assumption pending founder confirmation, HLD §9-23*) and shows four path cards: Scan, Build with blocks, Trace a photo, Rough it in.
- **FR-PLN-03** The Scan card is shown only when `RoomCaptureSession.isSupported` is true. On other devices, Rough it in is visually marked "Suggested".
- **FR-PLN-04** Every path ends by opening the canvas on the property's default floor (Ground) in the Plan view.
- **FR-PLN-05** If an address was entered, exterior seeding (spec 03) starts after the commit and does not block the canvas.
- **FR-PLN-06** The user can add a floor later from the floor-pill "+" (Add floor: Floor above, Basement, Attic), choosing any of the four paths for that floor.

### Rough it in
- **FR-PLN-10** Inputs: floors (1–3), basement (yes/no), approximate total above-grade sq ft (steppers/typing, 400–10,000), bedrooms (0–8), bathrooms in halves (0–6), garage (yes/no).
- **FR-PLN-11** Output follows LLD §6.10: area split per floor, room list and weights, squarified layout on a 6 in grid, a hall strip (with stairs when > 1 floor), basement at 70% of ground floor.
- **FR-PLN-12** The same input always produces the same layout (deterministic).
- **FR-PLN-13** Generated rooms are marked approximate. They draw with dashed walls and "~" dimensions until the user edits that room's geometry, which clears the flag. *Assumption pending founder confirmation (HLD §9-16).*
- **FR-PLN-14** From "Continue" on the inputs to an interactive canvas takes ≤ 60 s for a first-time user (target: under 10 s of app time; the rest is the user answering).
- **FR-PLN-15** The approx sq ft is saved on the property (`approx_sq_ft`) as a sanity reference.

### Build with blocks
- **FR-PLN-20** The user picks a style: Ranch, Colonial 2-story, Cape, Split-level, Townhouse, Condo, or Blank, plus bedroom and bathroom counts.
- **FR-PLN-21** The template produces rectangles at typical sizes on the right number of levels (`source='blocks'`), then opens the editor on the ground floor.
- **FR-PLN-22** A "Room palette" in the editor adds a new room block of a chosen type (Bedroom, Bath, Kitchen, Closet, Hall, Garage, Custom…) at the viewport center.

### Trace a photo
- **FR-PLN-30** Image sources: document camera (perspective-corrected) or the photo picker (screenshots). No photo-library permission is requested.
- **FR-PLN-31** Calibration: the user taps two points on the image (with a magnifier loupe) and types the known length. Accepted formats: `12'4"`, `12' 4`, `12.33'`, `148"`, `148in`, `3.76m`, `376cm`.
- **FR-PLN-32** If the calibration segment is within 5° of horizontal/vertical, the image is straightened automatically.
- **FR-PLN-33** An optional second calibration on a perpendicular wall. If the two scales differ by more than 5%, show: "This image may be stretched. Try the document scanner." With both, use the average.
- **FR-PLN-34** The image is shown under the plan at 50% opacity. The user drops blocks and drags corners to the traced walls (`source='trace'`).
- **FR-PLN-35** When done, the underlay is hidden but kept; the level menu has "Show traced image" to toggle it.

### Scan (RoomPlan)
- **FR-PLN-36** Camera permission is requested when the user starts the first scan, with the purpose string from HLD §5.1.
- **FR-PLN-37** The user scans rooms one at a time on a floor (multi-room session), then taps "Finish floor".
- **FR-PLN-38** A **review screen** is mandatory before commit. It shows: detected rooms with suggested names (editable), each scanned story mapped to a floor (default: lowest story → Ground), draft warnings (overlap, fallback outline) highlighted, and **suggested things** as a checklist ("We found a refrigerator in Kitchen. Add it?"), all unchecked by default. Nothing is added without acceptance.
- **FR-PLN-39** Detected doors create display-only door markers and door measurements (width × height, `source='roomplan'`) automatically.
- **FR-PLN-39a** Floors scanned in separate sessions are aligned in a review step: drag the new floor over the ghosted floor below, or tap 2 matching points (stairs suggested). *Assumption pending founder confirmation (HLD §9-26).*
- **FR-PLN-39b** RoomPlan-to-draft conversion completes in ≤ 2 s per floor on an iPhone 12 Pro.

### Plan editor (all paths)
- **FR-PLN-40** **Rename** any room from the room sheet header, the canvas (long-press → Rename), or the VoiceOver action "Rename". Names are free text, 1–60 characters. Room type is a separate optional picker (Kitchen, Bedroom, …) used for icons and defaults.
- **FR-PLN-41** Enter edit mode from the toolbar "Edit plan" (mockup 6.2). The summary strip is replaced by the editor toolbar: Add room, Split, Merge, Door/Window, Fine grid, Undo, Redo, Done.
- **FR-PLN-42** **Move a room** by dragging its interior; **reshape** by dragging a corner handle; **resize** by dragging an edge. Handles have ≥ 44 pt hit areas.
- **FR-PLN-43** Snapping per LLD §6.8: vertex → edge → alignment (guide lines) → 6 in grid (1 in while "Fine" is on); orthogonal edges stay orthogonal by default. A haptic tick fires when the snap target changes.
- **FR-PLN-44** **Shared walls move together.** Dragging an edge that coincides with a neighbor's edge moves both. A drag that would make any room invalid (self-intersecting, zero area) stops at the last valid position.
- **FR-PLN-45** **Typed dimensions.** Tapping a dimension label opens a field. Entering a length resizes the room by moving the edge opposite the anchor (left/top stays fixed) and records a wall measurement for that edge (`source='plan_edit'`).
- **FR-PLN-46** **Split** a room along a user-drawn straight orthogonal line; both halves keep items per the "items go where" prompt (default: the half containing each item's pin; unpinned items stay with the half that keeps the original name).
- **FR-PLN-47** **Merge** two adjacent rooms; allowed only if the result is one simple polygon. Items from both rooms move to the merged room.
- **FR-PLN-48** **Delete a room:** a confirmation asks where its items go (another room on this floor, or "This floor"); the room goes to Recently Deleted. *Assumption pending founder confirmation (HLD §9-21).*
- **FR-PLN-49** **Doors and windows** can be placed by hand in edit mode as display-only markers on a wall (kind, width, optional height). They never change room geometry. *Assumption pending founder confirmation (HLD §9-13).*
- **FR-PLN-50** **Undo/redo** covers every edit in the current edit session (at least 50 steps). Leaving edit mode commits.
- **FR-PLN-51** Edits are saved when the finger lifts (not only on "Done"), so a crash loses at most the in-flight drag.
- **FR-PLN-52** Floors can be renamed, reordered (elevation) and deleted (with the same item prompt as rooms) from the level menu.
- **FR-PLN-53** Units: geometry is stored in inches; display follows Settings (imperial default, metric toggle). *Assumption pending founder confirmation (HLD §9-2).*

## Acceptance criteria
- **AC-PLN-1** *Given* a non-LiDAR iPhone, *when* onboarding opens, *then* the Scan card is not shown and Rough it in is marked "Suggested".
- **AC-PLN-2** *Given* inputs 2 floors, 2,000 sq ft, 3 beds, 2.5 baths, no basement, *when* the user taps Continue, *then* the canvas shows Ground and 2nd Floor pills, Ground holds Living, Kitchen, Dining, Half bath, Laundry and a hall with stairs, the 2nd floor holds the primary bedroom, 2 bedrooms and 2 full baths, every room has dashed walls and "~" dimensions, and running it again gives identical geometry.
- **AC-PLN-3** *Given* an approximate room, *when* the user drags one of its edges and lifts, *then* that room's walls turn solid and its "~" disappears, while untouched approximate rooms stay dashed.
- **AC-PLN-4** *Given* the Colonial 2-story style with 4 beds, *when* the user confirms, *then* 2 floors of rectangles are created and the editor opens on Ground.
- **AC-PLN-5** *Given* a traced image calibrated with 13′2″ between two taps, *when* the user draws a room over a 13′2″ wall, *then* the typed-in dimension label reads 13′2″ ± 1″.
- **AC-PLN-6** *Given* two calibrations whose scales differ by 8%, *when* the second one is entered, *then* the "may be stretched" warning is shown.
- **AC-PLN-7** *Given* a finished RoomPlan scan with a detected refrigerator, *when* the review screen opens, *then* "refrigerator in Kitchen" is listed unchecked, and *when* the user commits without checking it, *then* no thing is created.
- **AC-PLN-8** *Given* the Kitchen shares an edge with the Dining room, *when* the user drags that edge 12 in, *then* both rooms change and no gap or overlap appears between them.
- **AC-PLN-9** *Given* the user taps the Kitchen's width label and types `12'4"`, *then* the room's width becomes 148 in, the right edge moves, and a wall measurement of 148 in exists for that edge.
- **AC-PLN-10** *Given* a room with 3 chores and 2 things, *when* the user deletes it and chooses "Move to This floor", *then* those 5 items appear under "This floor" and the room appears in Recently Deleted.
- **AC-PLN-11** *Given* two adjacent rooms whose union is not a simple polygon, *when* the user taps Merge, *then* merge is refused with "These rooms can't be merged into one shape."
- **AC-PLN-12** *Given* the user renames "Bedroom 3" to "Sewing room", *then* the new name shows on the canvas, in search, and in every item's location line.

## Edge cases
- Open-plan scans where kitchen and living share no wall: accepted as one room or split by the user; the review screen flags overlaps > 1 sq ft.
- Rooms smaller than the "+" visibility threshold (closets): the "+" moves to the room sheet header (spec 02).
- L-shaped and irregular rooms: supported as simple polygons; dimension label shows "~" bbox dimensions.
- Stairs across floors: a "Stairs" room on each floor; used as the default alignment hint.
- Scan interrupted (phone call, app backgrounded): rooms captured so far are kept in the session; the user can resume or finish the floor.
- Scan of a floor that already has rooms: offered as "Replace this floor" or "Add as new floor"; replace sends old rooms to Recently Deleted after the item prompt.
- Very large homes (> 80 spaces): allowed; performance budgets are defined at 60 spaces per level (HLD §5.4).
- Typed length of 0 or negative: rejected inline ("Enter a length greater than 0").
- Metric input while in imperial mode (e.g. `3.76m`): accepted and converted.

## Empty and error states
| State | Behavior |
|---|---|
| Camera permission denied | Scan and "Trace → camera" show "Camera access is off" with Open Settings; other paths remain |
| RoomPlan fails mid-session (tracking lost) | "Scanning paused — move slowly and point at walls"; after 3 failures offer "Finish with what we have" or "Try another way" |
| Scan returns no rooms | "We couldn't find any rooms. Try again with more light, or use Build with blocks." |
| Trace image unreadable/too small (< 800 px long edge) | "This image is too small to trace accurately" (allowed to continue) |
| Level with no rooms | Canvas shows "No rooms on this floor yet" with Add room / Scan / Rough it in buttons |
| Draft commit fails | Nothing is written (one transaction); "Couldn't save your plan. Try again." with the draft kept in memory |

## Data touched (LLD)
`property` (address, approx_sq_ft, default_level_id), `level` (kind, sort_order, underlay_*), `space` (polygon_json, source, is_approximate, name, space_type), `opening`, `measurement` (kind `door`/`wall`, source `roomplan`/`plan_edit`), `thing` (accepted scan suggestions), `attachment` (kind `underlay`), `sync_outbox`, `search_fts`.

## UI references
- Mockup **6.1** Onboarding: create your plan.
- Mockup **6.2** Plan editor mode (grid, wall handles, editable dimensions, toolbar replaces the strip).
- Mockup **2.1** Plan (default) for the result.
- Mockup section 01 (live prototype) for canvas behavior.

## Analytics / diagnostics
No analytics SDK. Signposts: RoomPlan structure → draft (≤ 2 s/floor), level render rebuild after edit (≤ 30 ms). Diagnostics counts include levels, spaces by `source`, approximate spaces remaining. Diagnostics can export a raw scan (`CapturedStructure` JSON) only when the tester explicitly chooses to, for fixture collection.

## Out of scope
MLS/public-listing import; public-record square footage checks; AI photo-to-plan; 3D views; curved walls; editable door/window geometry that changes rooms; swipe to change floors; iPad editor.

## Assumptions pending founder confirmation
HLD §9-2 (inches), §9-13 (hand-placed doors/windows), §9-16 (approximate rooms), §9-21 (room delete prompt + Recently Deleted), §9-23 (typed address), §9-26 (two-point alignment).
