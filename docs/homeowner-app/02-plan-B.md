# Planner B: Homeowner App ("House OS"), Product and Technical Plan

*Greenfield. Repo contains only `/home/user/FumbleAI/docs/homeowner-app/00-founder-transcript.md`. Decisions below are deliberate and opinionated; they are not hedged toward consensus.*

---

## 0. Thesis in one paragraph

The floor plan is the product's navigation system. It is not decoration. Every record (to-do, past fix, air filter, couch, hydrangea) lives *somewhere* on the plan, and the plan is how you find it again. So v1 has to get a user from install to a believable, listing-style plan of their home in **under 10 minutes**, with no drawing skill needed. Everything else is a filtered list of records pinned to spaces. If the plan feels fake or takes an hour to build, the app fails no matter how good the tracking is.

---

## 1. Product scope and MVP cut

### v1 (launch) is in
- **One property per user** (multi-property comes with Pro later).
- **Levels**: any number of floors plus a fixed **"Outside"** level. Pill tabs at top, defaulting to the ground floor ("Main" or "1").
- **Plan creation**, in priority order: (a) RoomPlan LiDAR scan, (b) shape builder (drag rectangles and L-shapes, snap to each other), (c) photo-of-plan as a traceable underlay. Details in section 2.
- **Outside level**: house footprint plus preset zones (Front yard, Backyard, Side yard L/R, Driveway, Sidewalk, Patio/Deck), all resizable, renameable, deletable, and addable.
- **Rename any space.** A space's name is free text. A separate `SpaceType` (kitchen, bath, bedroom, yard…) drives icons and suggestions.
- **Entries** (one unified record type, see section 4) in these kinds: *To-do, Planned Project, Completed Project/Repair, Furniture, Inventory, Appliance & System, Landscaping Idea.*
- **Layer dropdown** (single-select): *Plan (default), To-dos, Planned Projects, History, Budget, Furniture, Inventory, Appliances & Systems, Plants & Landscaping.* Selecting a layer re-renders the plan with per-room badges/heat and filters the room sheet.
- **"+" in every room**, leading to a kind picker and then a quick-add form.
- **Costs and rollups**: estimated vs. actual per entry, rolled up per space, per level, per property. Budget layer shows a heat-tinted plan.
- **Appliances & Systems templates** with structured fields: light bulbs (base E26/GU10…, wattage, color temp, count, fixture), air filters (dimensions like 16x25x1, MERV, location, replace interval, last replaced), HVAC, water heater, appliances (make/model/serial/purchase date/warranty), smoke/CO detectors (battery type, test date).
- **Photos and receipts** attached to any entry (on-device and in iCloud).
- **Recurring reminders** for maintenance items (filter every 90 days, detector battery yearly). This is cheap to build and is the main retention hook.
- **PDF export**: "Home History Report" (improvements plus costs plus systems).

### Explicitly **not** in v1
- Household sharing (v1.1; architecture supports it from day one).
- AI photo-to-plan vectorization, 3D rooms, AI planning (v2+).
- DIY/landscaping content library (v2).
- Android/web (maybe never; see section 5).
- Doors/windows as editable objects. RoomPlan captures them and we render them read-only. The manual editor skips them in v1.
- Deep kitchen/pantry/clothes inventory UX (barcode scanning, quantities, expiry). v1 supports generic Inventory entries with quantity. Dedicated pantry features are later. **Opinion:** pantry/clothes tracking is a different product with a different usage frequency. Allow it and don't design around it.

---

## 2. Floor-plan sourcing: a frank feasibility assessment

### Bright MLS / MLS listings: **not viable as a data source. Drop it.**
- MLS data is licensed, not public. Access comes through IDX/VOW/RESO Web API feeds and requires a broker/participant relationship and license agreement. Display rules restrict use to active-marketing contexts (IDX) or registered consumers of a brokerage (VOW). An "owner's home tracking app" fits neither.
- Floor-plan images in listings are **copyrighted media**, typically owned by the listing photographer or vendor (Matterport, CubiCasa, Zillow 3D Home), and licensed to the listing agent. Even with an MLS feed, redistributing them to a homeowner years later is legally shaky.
- Only a minority of listings include floor plans at all. Coverage is skewed toward recent, higher-end sales in certain markets. Most homeowners bought years ago, and their listing is gone or archived.
- Zillow/Redfin scraping violates ToS and is actively blocked. Zillow's public API was retired; Bridge/data programs require approved partnerships.
- Even when a plan image exists, it is a **raster image**, not geometry. We'd still need to vectorize it (the same problem as "user uploads a photo").

**Legitimate MLS-adjacent angle (later, not v1):** let the *user* import their own listing plan. They upload a screenshot or PDF they have (often from their closing docs or agent), and we treat it like any photo underlay. The user asserts they have the right to use it for personal purposes. No scraping, no feed.

### Public data that **is** free and useful (for the exterior)
- **Building footprints**: Microsoft Global ML Building Footprints (ODbL, open) and OpenStreetMap buildings. These give a house outline polygon for most US addresses. Good for seeding the Outside level's house shape and orientation.
- **County parcel/GIS layers**: many counties publish parcel polygons via free ArcGIS REST endpoints. Coverage and schemas vary county by county, so this can't be scaled nationally for free (Regrid and others aggregate it for a fee). v1: skip automated parcels. Let the user trace the lot over a **MapKit satellite snapshot** of their address, which gives a far better yard experience anyway.
- **County assessor "building sketches"**: many assessors publish a dimensioned exterior sketch (perimeter with segment lengths, sometimes per-floor area). These are useful as a manual reference for exterior dimensions but have no interior walls, and every county is different. Not worth integrating. Mention it in help text.
- **Building permits / blueprints**: residential plans are generally not publicly downloadable. Some jurisdictions allow in-person/FOIA requests, and most don't retain old residential plans. Not viable.

**Conclusion:** no free public source gives interior floor plans at scale. The strategy is **capture, not sourcing**. We make it trivially easy for the owner to *generate* the plan on-device, and we use open data only for the exterior footprint and satellite context.

### Creation flows (v1)
1. **Scan with iPhone (primary, LiDAR devices).** Apple RoomPlan (iOS 16+; multi-room merging via `StructureBuilder` in iOS 17+) captures walls, doors, windows, openings and major objects (sofa, bed, fridge, stove…) with dimensions. The user walks each floor. We flatten `CapturedStructure` to 2D polygons per room, snap walls, and auto-label rooms from detected objects (a bed means bedroom, a stove means kitchen). RoomPlan-detected objects become **suggested Furniture/Appliance entries** ("We found a refrigerator in Kitchen, add it?"). That is a strong magic moment.
   - *Constraint:* LiDAR exists only on Pro iPhones (12 Pro and later). Most users won't have it, so path 2 must be excellent and not a consolation prize.
2. **Shape builder (all devices).** Start from a template ("2-story colonial", "ranch", "split-level", or blank). Drag rooms from a palette (rectangle, L-shape, closet, hallway). Rooms **snap edge-to-edge**, shared edges become a single wall, and dimensions show live in feet-inches. Tap a dimension label to type an exact length ("12' 4\""). This keeps drawing to a minimum: users measure with a tape and type numbers. Also: "Pace it out" helper text, and an iPhone Measure-app deep link.
3. **Photo of a plan (all devices).** User photographs or uploads a plan image (listing screenshot, builder brochure, closing docs). It becomes a semi-transparent underlay. The user taps two points on a known wall and enters its length to calibrate scale, then drops shapes over it (path 2). v2 automates this with a vectorization model (evaluate CubiCasa's API vs. a custom model); v1 is manual trace only.
4. **Outside auto-seed.** On address entry, fetch the building footprint (MS/OSM), place it on a MapKit satellite snapshot, and pre-create zones (front yard/backyard/driveway/sidewalk) as rough polygons the user adjusts.

All four paths produce the **same geometry model**, so editing is identical afterward.

---

## 3. UI/UX

### Visual language
The look is a listing floor plan, not CAD: white or off-white room fills, thick charcoal exterior walls, thinner interior walls, room name in small caps with dimensions underneath (`KITCHEN 13'2" × 11'6"`), door swings drawn as arcs, and a north arrow on Outside. The Outside level uses soft green/grey fills over an optional desaturated satellite image. Dark mode inverts to a blueprint feel (navy background, white lines), which is a genuinely nice touch.

### Screen map
```
Onboarding: Address → "How do you want to create your plan?" (Scan / Build / Photo) → Outside auto-seed confirm
Home (Plan Canvas)  ←── the app lives here
 ├─ Top: Level pill tabs [Basement] [Main•] [Upstairs] [Outside]
 ├─ Top-right: Layer dropdown (single-select)
 ├─ Canvas: pan/zoom plan; per-room "+" and layer badge
 ├─ Bottom: property summary strip (context-aware to layer: "7 open to-dos · $18.4k planned")
 └─ Tap room → Room Sheet (bottom sheet, detents: peek / half / full)
       ├─ Header: name (tap to rename), type, dims, area, room cost rollup
       ├─ Segmented by kind (pre-filtered to active layer)
       └─ Entry rows → Entry Detail (form, photos, costs, reminders, history)
Edit Plan mode (explicit toggle; pencil icon) → shape palette, drag handles, dimension entry, add level, underlay tools
Lists tab-less access via toolbar "≡": All Entries (search, filter, sort), Reminders/Upcoming, Budget Summary (property → level → room drill-down table)
Settings: property details, units (imperial/metric), export PDF, subscription, iCloud status
```
**Opinion:** no tab bar. The plan is the single home screen. Lists live one tap away in a toolbar sheet. A tab bar would demote the plan to "one feature among several", which contradicts the founder's core premise.

### Canvas interaction model
- **View mode (default):** one-finger pan, pinch zoom (min = fit level, max ~4x), double-tap to zoom to room. Tapping a room highlights it and opens the Room Sheet at half detent while the canvas scrolls so the room stays visible above the sheet.
- **"+" button:** a small circular badge at each room's visual center (pole-of-inaccessibility, not centroid, so L-shaped rooms work). It hides when the room is too small at the current zoom and folds into the Room Sheet header instead. Tapping it opens a kind picker (7 icons), defaulting to the kind matching the active layer, so in the To-dos layer the "+" goes straight to a to-do form.
- **Layers change what the canvas shows:**
  - *Plan*: names and dimensions.
  - *To-dos / Planned / History / Furniture / Inventory / Appliances*: count badge per room, and room fill tint scaled by count. Entries that have a pinned point (optional) render as small icons at that spot (e.g., a lightbulb icon at the ceiling fixture).
  - *Budget*: each room tinted by planned spend (sequential color scale), showing "$4.2k planned / $1.1k spent". The level total shows in the bottom strip, and the property total shows in the dropdown subtitle.
- **Edit mode:** requires an explicit toggle so accidental drags never corrupt the plan. Edge drag resizes (neighbors that share the wall follow). Corner drag reshapes. Long-press shows Rename, Change type, Split, Merge, Delete. Snapping uses a 1" grid plus magnetic snapping to neighbor edges. Undo/redo is always visible. A haptic tick fires on snap.
- **Accessibility:** every room is also an accessibility element ("Kitchen, 13 by 11 feet, 3 open to-dos"). A "List view" toggle mirrors the canvas for VoiceOver users.

---

## 4. Data model

Units: store geometry in **centimeters (Double)**, money in **integer minor units (cents) + currency code**. Display converts to the user's units.

```
Property (id, name, address, lat/lon, yearBuilt?, sqft?, createdAt)
 └─ Level (id, propertyId, name, sortOrder, elevationIndex, kind: interior|outside, underlayImageId?, underlayTransform?)
     └─ Space (id, levelId, name [user label], spaceType enum, polygon [[x,y]] (cm, level coords),
               isExteriorZone, colorOverride?, sortOrder, source: roomplan|manual|traced|autoseed)
         └─ Opening (id, spaceId, kind door|window|opening, wallSegmentIndex, offset, width, swing?)   // read-only v1
Entry (id, propertyId, spaceId? [null = whole-house], levelId? [derived/denorm for fast rollups],
       kind enum {todo, plannedProject, completedProject, furniture, inventory, applianceSystem, landscapingIdea},
       title, notes, status enum {idea, planned, inProgress, done, archived},
       priority?, dueDate?, completedDate?,
       estimatedCostCents?, actualCostCents?, currency,
       effortHours?,                               // founder: "time or money"
       pinPoint? {x,y} (cm, level coords),
       templateKey? (e.g. "airFilter", "lightBulb", "waterHeater"),
       attributes JSON (template-specific typed fields),
       quantity? (inventory), parentEntryId? (sub-items / line items),
       createdAt, updatedAt)
CostLineItem (id, entryId, label, amountCents, kind: material|labor|permit|other, vendor?, date?, receiptAttachmentId?)
Attachment (id, entryId?, spaceId?, type photo|receipt|document, localPath, ckAssetRef, caption)
Reminder (id, entryId, rule: RRULE-lite {intervalDays | yearly on date}, nextDue, lastCompleted)
Tag (id, name) ↔ EntryTag
Template (static, bundled JSON): key, displayName, kind, fieldSchema [{key,label,type,unit,options}]
```

**Key decisions:**
- **One `Entry` table, not a table per category.** The founder's layers are *lenses on the same stuff*. A planned project becomes a completed project by status change, and it keeps its history, photos and costs. A furniture item and an appliance share 90% of their fields. Separate tables would make rollups, search and "move this to a different room" painful.
- **Layers are not stored data.** A `Layer` is a code-level definition: `{id, title, entryPredicate, badgeMetric, tintMetric}`. "Budget" is a layer whose predicate is `kind in (plannedProject, completedProject, todo) AND cost not null`. Adding a new layer later is a code change, not a migration. (User-defined custom layers backed by Tags come in v2.)
- **Rollups are computed, never stored.** Use SQL `SUM ... GROUP BY spaceId / levelId`. At household scale (thousands of rows) these queries are instant, and there's no cache to invalidate. Entry cost = `actualCostCents ?? sum(lineItems) ?? estimatedCostCents`, shown as separate "planned" vs. "spent" columns, never blended.
- **`spaceId` is nullable** for whole-house items (roof, HVAC, "refinance"). They roll up to the property only and appear in a "Whole House" pseudo-room chip on every level.
- **Walls are derived** from space polygons (shared edges detected at render time), so the model stays simple and room edits can't desync walls.
- **Template attributes as JSON** with a bundled schema. This keeps the Appliances & Systems depth (bulb base, filter size) without schema churn, and it lets queries like "all 16x25x1 filters in the house" run via SQLite JSON functions, which powers a "Shopping list: filters & bulbs" view.

---

## 5. Tech stack

- **Native Swift + SwiftUI, iOS 18+.** Not cross-platform. Reasons: RoomPlan/ARKit are native-only (bridging them into RN/Flutter is fragile), the canvas needs 120Hz gesture fidelity and haptics, and the founder asked for an iPhone app where "UI is most important". iPad support comes nearly free (larger canvas is a selling point). Android is not planned.
- **Plan rendering: SwiftUI `Canvas` (Core Graphics-backed immediate-mode drawing) plus a custom gesture layer and hit-testing in model coordinates.** Not SpriteKit (game-oriented, poor text), not SceneKit/RealityKit (3D is overkill for v1), and not one SwiftUI view per room (layout thrash, and hard to do pixel-exact walls). A single `PlanRenderer` takes `(level, spaces, layer, viewport transform)` and draws walls, fills, labels, badges. Hit-testing uses point-in-polygon on model coords. SwiftUI overlays are used only for the interactive "+" buttons and selection handles, so they stay accessible. The same renderer draws to a PDF context for export. If profiling ever shows problems with huge plans, the renderer can move to Metal behind the same interface.
- **Geometry core**: a pure-Swift module (`PlanKit`) handling polygon ops, snapping, shared-edge detection, area, label placement and RoomPlan-to-2D conversion. It's fully unit-tested with no UI dependency. This is where most bugs will be, so it must be isolated and testable.
- **Persistence: SQLite via GRDB**, local-first. It's chosen over SwiftData because we need real SQL aggregates for rollups, JSON queries on attributes, predictable migrations, and control over sync. SwiftData+CloudKit also forbids unique constraints, forces all-optional relationships, and has weak sharing support.
- **Sync: CloudKit via `CKSyncEngine`** (iOS 17+) into the user's **private database**, and v1.1 household sharing via **`CKShare` on a per-Property zone**. There is **no custom backend in v1**: zero server cost, no auth system, Apple-grade privacy ("your home data stays in your iCloud"), and it's a marketing point. Photos are stored as `CKAsset`s.
- **Auth:** implicit iCloud account. No sign-up screen. (Sign in with Apple is added only if/when a server appears.)
- **Small serverless edge (v1):** one Cloudflare Worker (or similar) that proxies the building-footprint lookup (lat/lon to footprint polygon from a pre-tiled MS Footprints dataset) and hosts template JSON updates. It's stateless and stores no user data.
- **Payments:** StoreKit 2 directly. RevenueCat is optional.
- **Analytics/crash:** TelemetryDeck (privacy-first) and Xcode Organizer/MetricKit.
- **Later AI (v2):** photo-to-plan vectorization and "plan my kitchen remodel" run server-side (an LLM API plus a vision model), and they're opt-in because they need uploading images.

---

## 6. Phased roadmap

| Phase | Duration | Milestone / exit criteria |
|---|---|---|
| **M0: Spikes** | 3 weeks | (a) RoomPlan multi-room scan of a real 2-story house, flattened to clean 2D polygons; (b) Canvas renderer at 120fps with 30 rooms, listing-style labels; (c) shape builder snapping prototype. **Go/no-go:** does the rendered plan look like a listing? Put it in front of 5 homeowners. |
| **M1: Plan foundation** | 5 weeks | Property/Level/Space model, GRDB schema, level pills, view mode, edit mode (resize/rename/add/delete), templates, photo underlay with scale calibration, Outside level with footprint auto-seed and satellite underlay. |
| **M2: Tracking core** | 5 weeks | Entry model, "+" flow, Room Sheet, 9 layers with badges/tints, costs and line items, rollups, Budget layer, Appliance & System templates, attachments, reminders, search. |
| **M3: Sync + polish + beta** | 4 weeks | CKSyncEngine sync, onboarding (<10 min to a plan), PDF Home History Report, accessibility pass, TestFlight with ~50 homeowners (mix of LiDAR/non-LiDAR). Metric: 70% of beta users complete a plan in their first session. |
| **v1.0 launch** | ~17 weeks total | App Store with Pro subscription. |
| **v1.1** | +6 weeks | Household sharing (CKShare), RoomPlan object-to-entry suggestions refined, filter/bulb shopping list, multi-property (Pro). |
| **v2** | +3–4 months | AI photo-to-plan vectorization, "snap a receipt" to cost entry (OCR), DIY/landscaping guides tied to entry templates, custom layers via tags, contractor share links (read-only web view, which is the first real backend). |
| **v3** | exploratory | 3D rooms (RoomPlan USDZ / object capture), AI remodel planning and cost estimation, affiliate replenishment. |

Assumes 1–2 strong iOS engineers plus a part-time designer. The designer is essential from M0; the founder is right that UI is the product.

---

## 7. Key risks and open questions

### Risks
1. **Plan-creation friction (highest risk).** If non-LiDAR users can't make a satisfying plan in about 10 minutes, activation dies. *Mitigation:* house-type templates, typed dimensions, and letting a user start with an "approximate" plan (rooms as boxes) and refine later. Accuracy is optional; recognizability is mandatory.
2. **RoomPlan quality on multi-floor homes.** Stairwells, open plans and level alignment are imperfect. *Mitigation:* scan per floor, align floors manually via the stair location, and always allow post-scan edits.
3. **Founder expectation on MLS/public sourcing.** It won't work, and we should say so now rather than discover it in month 3.
4. **Scope creep into pantry/clothes inventory.** It dilutes the plan-centric UX. Keep it generic.
5. **Data-entry fatigue.** Mitigations: RoomPlan object suggestions, templates, reminders as the recurring reason to open the app, and receipt OCR in v2.
6. **CloudKit limits.** There's no web access to data and no Android. That's acceptable for an iPhone-first product, and it's revisited when the contractor web view arrives.

### Open questions for the founder
1. Is **accuracy** (true dimensions) or **recognizability** (looks like my house) the bar for v1? I recommend recognizability, with dimensions editable.
2. Should **time** be tracked as a first-class cost (hours, and hours × hourly value) in the Budget layer, or only money?
3. Is household sharing (spouse/partner) a v1 must-have? It adds ~4–6 weeks. I've put it in v1.1.
4. Target user: new homebuyers (motivated, just moved, have listing/closing docs) or long-time owners? I recommend new buyers first, with acquisition via realtor/closing gift partnerships.
5. Comfortable with **iOS-only and iCloud-only** storage for v1 (no accounts, no web)?
6. Is the "Home History Report" (for resale/insurance) a core value prop to market, or a side feature?
7. Tolerance for AI features that require uploading home photos to a server (privacy positioning)?

---

## 8. Monetization (brief)

**Freemium subscription.**
- **Free:** one property, full plan creation (including scan), unlimited to-dos, and up to 50 other entries and 50 photos.
- **Pro ($4.99/mo or $39.99/yr, plus a lifetime option around $99 at launch):** unlimited entries/photos, reminders, Budget layer drill-downs, PDF Home History Report, multi-property, household sharing (v1.1), and later AI features.

**Secondary (v2+):** opt-in replenishment affiliate for filters and bulbs. We already know the exact filter size and bulb base, so "Reorder 16x25x1 MERV 11" is a one-tap, high-intent purchase, and it's useful, not ad-like. Also realtor/title-company **B2B gifting**: agents pay to give buyers a year of Pro with the plan pre-built from the listing's scan, which is also the legitimate path to listing floor plans. **No display ads, ever.** They would undercut the "working on my house" feel.

---

### Critical Files for Implementation
Greenfield repo; the only existing file is:
- /home/user/FumbleAI/docs/homeowner-app/00-founder-transcript.md

Proposed first files to create (Xcode project, Swift packages):
- PlanKit/Sources/PlanKit/Geometry.swift (polygons, snapping, shared-edge wall derivation, label placement)
- PlanKit/Sources/PlanKit/RoomPlanImporter.swift (CapturedStructure to 2D Level/Space)
- App/Canvas/PlanRenderer.swift (SwiftUI Canvas renderer plus hit-testing; also used for PDF export)
- App/Data/Schema.swift (GRDB migrations for Property/Level/Space/Entry/CostLineItem/Attachment/Reminder)
- App/Data/Layers.swift (code-defined layer predicates and badge/tint metrics)