# 07 · Measurements and Fit Check

**Priority:** P0 (Measure-app/photo pre-fill P2) · **Phase:** 1 (typed room dimensions become measurements) → 2 (measurements and fit check)
**Sources:** merged plan §1 ("Exact measurements are a first-class feature"), §5; founder decisions ("32 inches of width and 40 inches of depth for my stove/fridge", "front door is 72 inches tall and 36 inches wide", yard/landscape planning); HLD §4.9; LLD `measurement`, `opening`, `thing`, §10.

## Summary
A **Measurement** is a named set of dimensions (width, depth, height; at least one) with an optional note and photo, attached to a **room**, a **spot in a room**, a **door or window**, or a **yard zone**. Typing a dimension on the plan also creates a measurement, so an accurate plan builds up over time. The **fit check** compares a thing's dimensions (owned or planned) with the space it goes into and with the delivery-path door.

## User stories
- As an **owner**, I want to record "Fridge opening: 32 in W × 40 in D" so that I know what fits before shopping.
- As an **owner**, I want to record "Front door: 36 in W × 72 in H" so that I know if furniture can get in.
- As a **shopper**, I want to enter a fridge's dimensions and see immediately whether it fits my opening and my door.
- As a **gardener**, I want "Front bed: 24 ft × 4 ft" so that I can plan plants and mulch.
- As an **owner**, I want the "Wall behind couch: 118 in" saved so that I can buy the right size sofa or art.

## Functional requirements

### Measurement record
- **FR-MSR-01** Fields: label (required, e.g. "Fridge opening"), kind (**opening, wall, door, window, zone, general**), attached to (room, spot in a room via a pin, door/window marker, or yard zone), width, depth, height (at least one > 0), note, photo, "delivery path" flag (doors only). *Measurement kinds and delivery-path flag: assumption pending founder confirmation (HLD §9-11).*
- **FR-MSR-02** Created from "+" → Measurement (defaults to that room), the room sheet's Measurements section, a door/window marker's detail, a thing's "Goes into → New measurement", or the plan editor (typed dimensions).
- **FR-MSR-03** Input accepts `32`, `32"`, `32 in`, `2'8"`, `2' 8`, `81.3cm`, `0.81m`, and fractions `35 3/4` and `35¾`. Values are stored in inches (2 decimals) and displayed per Settings (imperial with fractions to 1/8 in, or metric in cm). *Assumption pending founder confirmation (HLD §9-2).*
- **FR-MSR-04** **Spot in a room:** the user drops a pin on the plan (mockup 4.4) to mark where the measurement is (e.g. the fridge opening).
- **FR-MSR-05** **Doors and windows:** each door/window marker (from a scan or hand-placed in the editor) can hold a measurement. Scanned doors get one automatically (width × height). Non-LiDAR users can hand-place a door marker to attach a measurement to (*assumption pending founder confirmation, HLD §9-13*).
- **FR-MSR-06** **Typed room dimensions** in the plan editor create or update a *wall* measurement for that edge (source "plan edit"). Deleting the room deletes those measurements with it (Recently Deleted).
- **FR-MSR-07** **Zones:** measurements on yard zones are kind *zone*; the room sheet shows area (sq ft) computed from width × depth when both are present.
- **FR-MSR-08** **Pre-fill (P2):** "Use Measure app" opens Apple's Measure app with instructions; the user types the result back. Photos can be attached for reference. (Automatic import from Measure isn't available; RoomPlan values are pre-filled for scanned doors.)
- **FR-MSR-09** Measurements show in the Plan view's room sheet (Measurements section) and are searchable ("fridge opening", "32 × 40").

### Fit check
- **FR-MSR-20** A thing (owned or planned) with dimensions can choose **"Goes into"**: a measurement in the same room (default suggestions: kind opening or wall in that room, most recent first). *Assumption pending founder confirmation (HLD §9-11).*
- **FR-MSR-21** The check runs **live** as dimensions are typed and shows a banner: **Fits** (green, spare shown), **Tight** (amber, < ¼ in spare, or the appliance protrudes past the opening's depth), **Won't fit** (red, with the shortfall), or **Unknown** (missing dimensions). Example: "35¾ in wide won't fit the 32 in opening (4¾ in short incl. clearance)."
- **FR-MSR-22** **Clearances:** a default per category/template, editable per item — refrigerator 1 in width / 1 in depth / 1 in height; range, wall oven, cooktop 0; dishwasher ¼ in width and height; washer and dryer 1 in width / 4 in depth; wall TV 2 in width and height; furniture 0; other 0. *Assumption pending founder confirmation (HLD §9-12).*
- **FR-MSR-23** **Orientation:** furniture may rotate (width/depth swap) to fit; front-facing appliances may not. The banner says "Fits if rotated" when rotation was needed.
- **FR-MSR-24** **Depth:** fridges, ranges, washers and dryers deeper than the opening produce a **warning** ("Sticks out 6 in past the opening"), not a failure. *Assumption pending founder confirmation (HLD §9-12).*
- **FR-MSR-25** **Delivery path:** one or more door measurements can be flagged "delivery path" (by default the scanned exterior door). The fit check also tests whether the item passes through each flagged door (smallest two dimensions against door width and height) and shows "Fits through Front door" or "Won't fit through Front door (needs 38 in, door is 36 in)". Tilting/diagonal carries are not modeled.
- **FR-MSR-26** Results are **never stored**; they're recomputed whenever the thing's dimensions, clearances, target measurement or door measurements change.
- **FR-MSR-27** When a measurement changes, every thing that "goes into" it shows the updated result the next time it's viewed, and the room sheet flags any now-failing items with a red "Won't fit" badge.
- **FR-MSR-28** The user can always **Save anyway**; the fit check never blocks saving.

## Acceptance criteria
- **AC-MSR-1** *Given* "+" in Kitchen → Measurement "Fridge opening" 32 W × 40 D × 72 H with a pin, *then* it shows in the Kitchen's room sheet and search "fridge opening" returns it with "Kitchen · Ground".
- **AC-MSR-2** *Given* a planned fridge 35¾ W × 30 D × 70 H going into that opening, *then* the banner is red: width won't fit (needs 36¾ incl. 1 in clearance, has 32, 4¾ short); depth fits; height fits (needs 71, has 72, 1 in spare); overall "Won't fit".
- **AC-MSR-3** *Given* the fridge width changes to 30, *then* width fits with 1 in spare (needs 31, has 32) and the overall banner turns green "Fits".
- **AC-MSR-4** *Given* a sofa 84 W × 38 D × 34 H and a front door 36 W × 80 H flagged as delivery path, *then* "Fits through Front door" (34 ≤ 36, 38 ≤ 80).
- **AC-MSR-5** *Given* a fridge 30 D going into a 24 D opening, *then* depth shows "Sticks out 7 in" (30 + 1 in clearance vs. 24) as a warning, not a failure, and the overall is "Tight", not "Won't fit".
- **AC-MSR-6** *Given* the Kitchen width typed as `12'4"` in the editor, *then* a wall measurement "148 in" exists for that edge with source "plan edit".
- **AC-MSR-7** *Given* the input `35 3/4`, *then* the value is stored as 35.75 in and displayed as 35¾″ (imperial) or 90.8 cm (metric).
- **AC-MSR-8** *Given* a measurement with no dimensions, *then* Save is disabled with "Enter at least one dimension".
- **AC-MSR-9** *Given* a zone measurement 24 ft × 4 ft, *then* its area shows 96 sq ft.
- **AC-MSR-10** *Given* an opening measurement is edited from 32 to 36 in wide, *then* a fridge going into it that previously showed "Won't fit" shows "Fits" on next view.

## Edge cases
- Only width known: width checked; depth and height "Unknown"; overall is the worst known axis, or "Unknown" if none known.
- Target measurement deleted: "Goes into" is cleared; the thing shows "No space chosen".
- Multiple delivery-path doors: each is listed with its own result.
- Metric user entering imperial fractions: accepted.
- Exactly equal dimensions (0 in spare): "Tight".
- Very large zone measurements (feet): displayed in ft/in above 10 ft.

## Empty and error states
| State | Behavior |
|---|---|
| Room has no measurements | Room sheet: "No measurements yet. Add one to check what fits." |
| Thing has dimensions but no target | "Choose where this goes to check the fit" with a picker; create-new option |
| Invalid input (letters, zero) | Inline "Enter a length like 32 or 2′8″" |

## Data touched (LLD)
`measurement` (label, kind, space_id, opening_id, storage_spot_id, pin_x/pin_y, seg_* for walls, width_in/depth_in/height_in, is_delivery_path, source `manual`/`roomplan`/`plan_edit`/`measure_app`), `opening`, `thing` (width_in, depth_in, height_in, fit_measurement_id, template_key), `attachment` (photo), `search_fts`.

## UI references
Mockups **4.3** Appliance detail with fit check (35¾ in fridge vs. 32 × 40 in "Fridge opening"), **4.4** Measurement entry (pinned to a spot; width and depth, height optional; Measure app or photo), **6.2** Plan editor mode (editable dimensions).

## Analytics / diagnostics
Counts-only export: measurements by kind; things with a fit target. FitChecker is table-tested (HLD §5.7).

## Out of scope
Automatic measurement from photos (AI, later); AR measuring inside the app; diagonal/tilt carry rules; stair or hallway turns on the delivery path; mulch/sod/plant-count estimates (later); retailer "fits your opening" shopping (future partnership).

## Assumptions pending founder confirmation
HLD §9-2 (inches, metric toggle), §9-10 (planned purchases), §9-11 (goes-into link, measurement kinds, delivery path), §9-12 (clearance defaults, depth warning), §9-13 (hand-placed doors/windows).
