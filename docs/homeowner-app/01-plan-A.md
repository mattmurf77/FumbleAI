# Planner A: Homeowner App Plan (working name "Hearth")

## 0. Thesis

This app is a **spatial ledger for your home**. Lots of apps already let you track to-dos and receipts. None of them organize that information around your actual floor plan. Everything in this plan follows from one decision: **the floor plan is the way you navigate the whole app.** The founder wants it to feel like "you're working on your house." Every item therefore belongs to a place (a room, a yard zone, a floor, or the whole property), and the main way to add something is to tap that place.

A second opinionated call: **getting an accurate floor plan should not depend on outside data.** The founder hopes listing data will provide it, but it won't do so reliably or legally at scale (see section 2). v1 has to get a new user from install to a usable plan in under 5 minutes with no outside source at all.

---

## 1. Product scope and MVP cut

### v1 (MVP, about 4–5 months, solo or small team)
- **One property per account.** Multiple floors plus an "Exterior" level.
- **Creating a floor plan**, three ways:
  1. **LiDAR room scan** using Apple RoomPlan, on Pro iPhones.
  2. **Drag-and-drop room blocks** with typed dimensions (the main path for people who can't draw).
  3. **Trace over a photo** of an existing floor plan (manual tracing on a locked background image; no auto-vectorization yet).
- **Exterior level** created from a template: Front Yard, Backyard, Side Yard (L/R), Driveway, Sidewalk, plus custom zones. The house footprint appears as a gray block.
- **Canvas** with floor pills, a single-select **Layer** dropdown, a per-room "+" button, and room rename.
- **Five layers in v1:** To-Dos, Future Projects, Past Work, Inventory (including Home Systems), and Budget (a computed rollup view rather than an item type).
- **Items** with cost (estimate and actual), status, dates, photos, notes, and receipt attachments.
- **Home Systems inventory:** structured templates for light bulbs, HVAC filters, water filters, appliances, and smoke/CO detectors. Each has a "reorder/replace" reminder.
- **Rollups** of budget and spend per room, per floor, and per property.
- **iCloud sync** across the user's own devices, plus export to CSV and PDF (a "home history report").

### Explicitly deferred (v1.x / v2)
- Furniture layer with placed icons (v1.1). v1 lists furniture under Inventory; showing it spatially comes next.
- Yard Inventory and Landscaping Ideas as separate layers (v1.1). In v1 these are Inventory and Future Projects filtered to the Exterior level.
- Household sharing with a spouse or partner (v1.2, CloudKit sharing).
- Auto-vectorizing a floor-plan photo into rooms (v2, using ML).
- Public-record prefill of square footage, stories, bedrooms and bathrooms (v1.2, as hints only).
- DIY and landscaping content, 3D rooms, and AI planning (v2 and later).
- Pantry and clothing inventory. The data model supports them in v1 (generic Inventory) but they get no special UI. I'm deprioritizing them on purpose: high-churn inventory is a different product (grocery or closet apps) and would dilute the "house" focus.

**Why five layers and not ten:** a dropdown with 10+ entries on day one feels like a spreadsheet. Layers are the product's lens, so each one needs a distinct visual treatment on the canvas. Five that are well designed beat ten generic ones.

---

## 2. Floor-plan sourcing: a frank feasibility assessment

### MLS (Bright MLS and others): **not a viable v1 source.**
- **Access:** Bright MLS data is available only to licensed members and their approved vendors, through RESO Web API or IDX/VOW feeds. A consumer app can't get a feed without partnering with a brokerage, and IDX rules limit display to *active listings for consumer search*. Showing a homeowner's own past listing as the base layer of a personal-data app is outside IDX's intended purpose.
- **Coverage:** floor plans are optional media uploaded by the listing agent. They are more common in mid- to high-end listings from about the last 5 years (from CubiCasa, Matterport, or photographers) and missing from most. Many homes were last sold before floor plans became routine, and some have never been listed at all.
- **Copyright:** floor-plan images usually belong to the photographer or plan vendor and are licensed to the agent, not the homeowner or us. Scraping Zillow, Redfin or Realtor.com for them breaks their terms of service and invites takedowns.
- **Format:** even when one exists, it's a raster image, not vector geometry. We would still have to digitize it.

**Conclusion:** MLS is a user-driven import, not a data pipeline. The user can find their own old listing floor plan (on Zillow, in their closing documents, or from their agent), take a screenshot, and bring it in through the "Trace a photo" flow. We should actively suggest this in onboarding ("Do you have the floor plan from when you bought? Check your old listing or email your agent"), because it's the cheapest high-accuracy input available. For personal use, the user brings their own copy and we never redistribute it.

### Free public data that *is* usable
- **County assessor / CAMA records:** mostly free to view per county. They give finished square footage, number of stories, bedrooms and bathrooms, year built, and sometimes an exterior footprint sketch with wall lengths (common on Vision Government Solutions and similar county portals). But there are 3,000+ counties with inconsistent formats and no unified free API. Aggregators (ATTOM, Regrid, Estated-type APIs) charge for access. **Use:** v1.2 prefill of "3 stories, about 2,100 sq ft" as a sanity check against the drawn plan. No room layouts.
- **Parcel boundaries:** county GIS, often free, and Regrid offers a limited free tier. **Use:** outlining the lot on the Exterior level (v1.1 or later).
- **Building footprints:** Microsoft Global ML Building Footprints (ODbL, free) and OpenStreetMap. **Use:** placing the house block on the Exterior level automatically at the right size and angle. Worth doing in v1.1.
- **Apple RoomPlan (on-device, free):** iOS 16+ on LiDAR iPhones (Pro models since the 12 Pro). It returns walls, doors, windows, openings and major objects (appliances, sofa, bed, etc.) with real dimensions. iOS 17 added multi-room capture into one structure. **This is the most accurate source available and it costs nothing.** Limitation: non-Pro iPhones don't have LiDAR, so it can't be the only path.

### The fallback creation flows (these are the real product)
1. **"Scan my home"** (LiDAR devices): walk room to room. RoomPlan's CapturedStructure is converted into our room polygons, and the user assigns rooms to floors and confirms names (we suggest names from detected objects, e.g. toilet means Bathroom, stove means Kitchen).
2. **"Build with blocks"** (every device): pick a starting template (Colonial 2-story, Ranch, Split-level, Cape, Townhouse, Condo), then adjust. You drag rectangles or L-shapes from a tray, type "12 × 14", and they snap to neighbors along shared walls. No freehand drawing at all. This is the flow for people who can't draw, and it's fastest when paired with a tape measure or the iPhone Measure app.
3. **"Trace my plan"**: import a photo or screenshot, perspective-correct it (VisionKit document scanning), set the scale by tapping two points on a labeled wall and entering its length, then drop room blocks over the image. v2 adds ML auto-detection of rooms (models trained on CubiCasa5k-style datasets) that proposes rooms for the user to confirm.
4. **"Rough it in"**: skip exact geometry. Rooms appear as proportionally sized tiles based on an approximate square footage. Anyone who wants to get to tracking immediately gets a working canvas in 60 seconds and can refine it later. **This matters for activation.**

All four produce the same underlying geometry, so the rest of the app doesn't care where a plan came from.

---

## 3. UI/UX

### Screen map
- **Onboarding:** address (for the Exterior footprint and later prefill), then "How do you want to create your plan?" (Scan / Blocks / Trace / Rough), then the floor setup wizard.
- **Home (the canvas):** the main screen. It stays loaded; everything else is presented over it as a sheet.
- **Room sheet** (bottom sheet, three detents): room name and dimensions, the layer's items for that room, and a room total.
- **Item detail:** fields, photos, receipts, cost, status, recurrence.
- **Plan editor:** a separate mode entered via an "Edit Plan" button. Editing geometry is kept separate from tracking stuff, which prevents accidental wall drags.
- **Rollup / Budget dashboard:** property → floor → room drill-down.
- **Search:** global search across all items ("furnace filter").
- **Settings:** property info, units, export, subscription.

No tab bar in v1. A tab bar would compete with the floor pills and weaken the idea that the house itself is the home screen. Search and the dashboard are toolbar buttons.

### Canvas interaction model
- **Top bar:** property name at the left, and a **Layer dropdown** (single-select SwiftUI `Menu`) at the right showing an icon and name, e.g. "To-Dos ▾".
- **Pill row** below it: `Exterior · Basement · 1st Floor · 2nd Floor · Attic`. Opens on **1st Floor (ground)** by default, and the app remembers the last one chosen. The pills scroll horizontally, and swiping left or right on the canvas also switches floors.
- **Visual style:** it should look like a listing floor plan. White fill, charcoal walls about 6pt thick, door swing arcs, window hatching, room name centered with dimensions (12'4" × 14'0") below it in small caps. Exterior uses soft tints: green for lawn, gray for hardscape, tan for mulch beds.
- **Gestures:** pinch to zoom (0.5×–6×), two-finger pan, a single tap on a room opens the room sheet and highlights it, a long press on a room brings up rename, color, and "Edit shape".
- **"+" button:** a small circular "+" pinned to each room's centroid (hidden when zoomed out too far to fit; a tap on the room still works). Tapping it opens a compact picker of every category: To-Do, Future Project, Past Work, Inventory item, Home System, Furniture. So you can add anything from any layer. The picker defaults to the current layer's category to save a tap.
- **What each layer shows on the canvas:**
  - *To-Dos:* a count badge per room; rooms with overdue items get a red edge.
  - *Future Projects:* a planned-cost chip per room; rooms are shaded by planned spend (heatmap).
  - *Past Work:* a lifetime-spend chip plus a "last touched" date.
  - *Inventory:* item count; Home Systems shown as small glyphs (bulb, filter, detector) at their spots in the room.
  - *Budget:* each room shaded by budget vs. actual. A floor total sits in the pill row and a property total in a footer strip.
- **Floor total footer:** a persistent thin strip at the bottom of the canvas showing the current layer's rollup for that floor ("1st Floor · 7 to-dos · $4,200 planned").

### Plan editor
- Snap-to-grid (6" by default) and snap-to-wall.
- Select a room to show its handles, or tap a wall to type its length.
- Split room / merge rooms, add door or window (from a tray, snapping onto walls), undo/redo.
- An area readout per floor, compared against the assessor square footage when we have it.

---

## 4. Data model

```
Property 1—* Level
Level (id, propertyId, name, kind: floor|basement|attic|exterior, order, isDefault)
Level 1—* Space
Space (id, levelId, name, kind: room|hall|closet|yardZone|driveway|sidewalk|structure|custom,
       polygon: [Point] in inches, label position, fillStyle, source: roomplan|blocks|trace|rough)
Level 1—* Opening (door/window: wallSegment ref, offset, width, swing)
Level 0..1 BackgroundImage (asset, scale, transform) — trace reference

Item (id, propertyId, levelId?, spaceId?, category, title, notes,
      status, priority, dateCreated, dateCompleted?, dueDate?,
      estimatedCost?, actualCost?, currency, costBreakdown: [LineItem]?,
      vendor?, tags[], attachments[], position: Point?)
category ∈ {todo, futureProject, pastWork, inventory, homeSystem, furniture, landscapingIdea}
HomeSystemSpec (itemId, systemType: bulb|hvacFilter|waterFilter|appliance|detector|...,
      attributes: JSON-typed per template — e.g. bulb: base E26, lumens, color temp, wattage, count;
      filter: size 16x25x1, MERV, qty on hand; appliance: brand, model, serial, install date, warranty end)
      replaceIntervalDays?, lastReplaced?, qtyOnHand?, purchaseURL?
Reminder (itemId, rule, nextFire)
Attachment (id, itemId, type: photo|receipt|manual|pdf, localAsset, ocrText?)
ItemLink (fromItemId, toItemId, kind: "resolves"|"spawned") — a to-do that becomes past work
```

**Key decisions:**
- **One `Item` table with a `category` field**, not a separate table per type. Layers are *filters plus a canvas visualization*, not separate data silos. That makes "+ adds to any category" easy, makes cross-layer search trivial, and lets a To-Do be converted into Past Work with one tap ("Mark done → log cost"). That conversion is the app's core loop.
- **Items attach to exactly one scope:** a space, a level (e.g. "repaint whole 2nd floor"), or the property (roof, siding). `spaceId` and `levelId` are optional, and rollups respect the scope.
- **Budget is computed, not stored:**
  - Room = the sum of Items in that space.
  - Floor = the sum of its rooms plus level-scoped items.
  - Property = the sum of its floors plus property-scoped items.
  - We keep estimated and actual separate and never mix them in one number. Past Work sums `actualCost`; Future sums `estimatedCost`; Budget shows both.
- **Geometry is stored in inches in property-local coordinates, with polygons rather than rectangles**, so L-shaped rooms and RoomPlan output don't lose information.
- **Money is stored as integer cents plus a currency code.**

---

## 5. Tech stack

- **Native Swift/SwiftUI, iOS 17+.** Not cross-platform. Reasons: RoomPlan, VisionKit, LiDAR, CloudKit and Live Text are all Apple-native. The founder explicitly asked for an iPhone app. And the canvas is the product, so it needs 120Hz gesture fidelity. Android is a v3 conversation at the earliest.
- **Canvas rendering:** a SwiftUI `Canvas` view drawing paths from our own geometry model. Room hit-testing uses point-in-polygon, and the "+" buttons and chips are SwiftUI overlays positioned in view space. For zoom and pan, wrap it in a `UIScrollView` (via `UIViewRepresentable`) to get native zoom physics and rubber-banding. Why not SpriteKit or SceneKit: our plans are 2D, look like documents, and need crisp text and accessibility. Why not SVG or a web view: poor gesture feel. If profiling shows `Canvas` redraw cost on large plans, fall back to per-room `CAShapeLayer`s. With under 60 rooms that's unlikely.
- **Persistence:** SwiftData on-device as the source of truth.
- **Sync:** **CloudKit** (private database, with a shared zone for household sharing in v1.2). The advantages: no backend to run, no server cost per user, Sign in with Apple is implicit, and user data stays private, which is a real selling point for a home-inventory and insurance-record app.
- **Why no custom backend in v1:** it isn't needed. Add a thin serverless backend (e.g. Cloudflare Workers or Supabase) only when we need public-record lookups, ML vectorization, or AI features (v1.2 and later). Even then it stays stateless, and user data stays in CloudKit.
- **Auth:** Sign in with Apple through the iCloud account. No passwords.
- **Other frameworks:**
  - RoomPlan (scanning)
  - VisionKit `VNDocumentCameraViewController` (plan photos and receipts)
  - Vision text recognition (receipt OCR to prefill cost and date)
  - UserNotifications (filter reminders)
  - StoreKit 2 (subscriptions)
  - TelemetryDeck or PostHog (privacy-light analytics)
- **Testing:** unit tests on the geometry math (snapping, area, polygon operations) and rollup math. Snapshot tests on the canvas rendering.

---

## 6. Phased roadmap

| Phase | Duration | Milestone / exit criteria |
|---|---|---|
| **0: Design spike** | 3 wks | Clickable Figma prototype of the canvas, layers and "+"; 5 homeowner interviews. **Gate:** users recognize their house in a block-built plan in under 5 minutes. |
| **1: Canvas core** | 5 wks | Geometry model, `Canvas` renderer in listing style, floor pills, zoom/pan, room tap/rename, Blocks editor with templates, Rough-it-in mode. |
| **2: Tracking core** | 5 wks | Item model, "+" picker, 5 layers with canvas treatments, room sheet, rollups, to-do→past-work conversion, attachments, receipt OCR. |
| **3: Capture paths** | 4 wks | RoomPlan scan → geometry conversion; Trace-a-photo with scale calibration; Exterior template with yard zones. |
| **4: Home Systems + polish** | 3 wks | Bulb/filter/appliance templates, reminders, CloudKit sync hardening, PDF home-history export, paywall. **TestFlight beta (50 users).** |
| **5: Launch v1.0** | 2 wks | App Store launch. Target metric: 60% of installs finish a plan; 40% add 5+ items in week 1. |
| **v1.1** | +6 wks | Furniture layer with placed icons, Yard Inventory and Landscaping layers, auto-placed building footprint on Exterior, parcel outline. |
| **v1.2** | +6 wks | Household sharing, assessor prefill (paid API, cached), iPad layout. |
| **v2** | +3–4 mo | ML plan-photo vectorization, AI assistant ("what filter does my furnace take?", "estimate this kitchen remodel"), DIY/landscaping content, 3D room view via RoomPlan USDZ. |

---

## 7. Key risks and open questions

### Risks
1. **Onboarding friction is the #1 risk.** If building the plan feels like homework, users churn before they ever see value. Mitigations: Rough-it-in mode, templates, and letting users add items *before* the geometry is exact.
2. **The founder's expectation of MLS floor plans.** It needs resetting now. Building on scraped listing data is a legal and reliability dead end.
3. **RoomPlan limitations:** Pro-only hardware, struggles with open-concept spaces and stairs, and merging floors needs user help. Treat it as a strong accelerator, not the default path.
4. **Scope creep in inventory** (pantry, clothes). These are high-maintenance lists users abandon. Mitigation: keep them generic in v1 and let usage data decide.
5. **Canvas usability on a 6" screen.** Small rooms (closets, half baths) are hard to tap. Mitigations: tap targets with a minimum hit radius, a room list fallback in the room sheet, and zoom-to-room.
6. **CloudKit lock-in:** no web or Android client later without migrating. I accept this for v1 because speed and privacy outweigh it.

### Open questions for the founder
1. Who is the core user: a new homeowner (the "just moved in" moment; great for onboarding) or a long-tenure owner with a lot of history to backfill? My pick is new homeowners in their first 24 months.
2. Is "home history report for resale" a primary value proposition? If so, PDF export moves up in priority and becomes a marketing hook.
3. Is pantry and clothing inventory truly core, or a nice-to-have? I've deprioritized it.
4. Are you open to a brokerage partnership later? Agents could gift the app to buyers at closing and legitimately pre-load the listing floor plan. It's the only realistic MLS route and doubles as a distribution channel.
5. Is iOS-only acceptable for 12+ months?
6. Are household members' devices a v1 requirement?

---

## 8. Monetization (brief)

**Freemium subscription.**
- **Free:** one property, unlimited floors and rooms, up to 50 items, all capture methods.
- **Hearth Plus ($4.99/mo or $39.99/yr):**
  - unlimited items, photo and receipt storage
  - reminders
  - PDF home-history report
  - household sharing
  - later, AI features
- **Secondary revenue (v1.2 and later):** affiliate links on Home Systems reorders ("Reorder 16×25×1 MERV 11, 6-pack"). This fits the product naturally because we know exactly which filter and bulb the user needs.
- **Future B2B channel:** a real-estate agent closing-gift program with a pre-loaded floor plan.

No ads. They would undercut the private "your house's notebook" positioning.

---

### Critical files for implementation
The repo has no code yet (greenfield). The only existing input is the founder transcript:
- /home/user/FumbleAI/docs/homeowner-app/00-founder-transcript.md

The files that will matter most:
- `HomeApp/Model/Geometry.swift` (polygon, snapping and area math)
- `HomeApp/Model/Item.swift` (unified item and rollups)
- `HomeApp/Canvas/FloorPlanCanvasView.swift` (rendering, hit-testing, layer overlays)
- `HomeApp/Capture/RoomPlanImporter.swift` (converting RoomPlan's CapturedStructure into our rooms)
- `HomeApp/Editor/BlockEditorView.swift`

**Note on sources:** the MLS, assessor, footprint and RoomPlan facts above are from my own knowledge (as of mid-2026). I didn't check them against live web sources this session, so they're worth confirming before we share them with the founder.