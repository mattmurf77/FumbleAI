# Homeowner App: Product Requirements Document (v1)

**Status:** planning only. Nothing is being built. The founder said "Just plan, don't build."
**Working name:** "Home" (placeholder, same as the HLD).
**Sources, in precedence order (most recent wins):** `../07-merged-plan.md` → `../06-founder-decisions.md` → `../design/hld.md` → `../design/lld.md` → `../00-founder-transcript.md`. Screen names come from `../mockups/index.html` (sections 2.x–6.x).
**Companion specs:** `features/01-…` to `features/10-…` hold the testable requirements. This PRD holds the why, who, scope, priorities and plan.

> **How assumptions are marked.** The HLD's §9 "Deviations / assumptions" (27 items) are *not* decided. Wherever this PRD or a feature spec relies on one, it says **"Assumption pending founder confirmation (HLD §9-N)"**. New assumptions made by this document are tagged **"PRD assumption"**. §15 lists all of them.

---

## 1. Problem and vision

### 1.1 Problem
A home is a person's biggest purchase and the least organized part of their life.
- **The knowledge is scattered.** Filter sizes live on a sticky note, the fridge opening width is in someone's head, receipts are in a drawer or an inbox, and "where did we put the winter coats?" means opening three bins in the attic.
- **Improvements are forgotten.** Owners can't say what they spent on the kitchen, when the roof was done or what the water heater cost. That matters at tax time, insurance claims and resale.
- **Recurring chores slip.** Dishes and laundry are daily. Filters, detector batteries and gutters are rare enough to forget entirely.
- **Existing apps are lists.** Home-maintenance apps and spreadsheets are flat lists. None of them *feel* like your house. The founder's core insight is that the UI should "feel like I'm really working on my house."

### 1.2 Vision
**Your house's own floor plan is the app.** You open to the ground floor drawn like a real-estate listing, switch floors with pill tabs, and pick one of seven views from a dropdown. The same plan then shows chores due, planned projects and their cost, past work, where the appliances are, what's stored where, and the budget. Each room has a "+" to add anything to it.

Over time, the app becomes the **house's memory**: a complete, dated, receipt-backed record that later becomes the **Home History Report** (the headline future feature), a document that travels with the house when it's sold.

### 1.3 Product principles
1. **UI quality first**, then data safety, then everything else (HLD §1.4).
2. **The plan is the navigation.** Every record is tied to a place: a room, a floor, or the whole house.
3. **Useful in 60 seconds.** A rough plan is better than no plan; accuracy can come later.
4. **Your data stays yours.** It lives on your phone and in your own iCloud. There's no account, no server and no analytics SDK, and you can export everything to CSV.
5. **No paywall now.** Every feature is free during the beta.

---

## 2. Target users

| Segment | Priority | Why |
|---|---|---|
| **New homebuyers** (0–18 months after closing) | Primary | They're learning the house, they have the most unknowns (filter sizes, bulbs, appliance ages), they're planning projects, and they start the History Report on day one. They're the future real-estate-agent channel (the plan gifted at closing). |
| **Existing owners** | Secondary | They get the same value from chores, inventory and appliances, and they want to capture past work retroactively for resale or insurance. |
| **Housemates** (partner, kids, roommates) | Labels only in v1 | They're assigned chores and own clothing and bins, but they don't have their own login until v1.2 sharing. |

**v1 audience:** 2–5 TestFlight testers (the founder's household and friends). There's no public launch, App Store listing, paywall or dates.

---

## 3. Personas

### 3.1 Priya — first-time buyer, detail-oriented (primary)
- 31, product designer. She and her partner Dev closed 3 weeks ago on a 1994 two-story colonial with a finished basement (about 2,100 sq ft).
- She has an **iPhone 15 Pro (LiDAR)**; Dev has an iPhone 13 (no LiDAR).
- **Goals:** learn the house; know the furnace filter size before the store trip; plan the kitchen refresh and the backyard patio with real numbers; set up a shared chore routine with Dev.
- **Frustrations:** the inspection report is a 60-page PDF; the listing floor plan isn't to scale; they already bought a fridge that didn't fit the opening once, in their last apartment.
- **Success for her:** a scanned, accurate plan of two floors in one evening; filter size known; the kitchen project estimate tracked against the actual spend.

### 3.2 Matt — established owner, household organizer (secondary, founder-like)
- 38, lives with his partner and two kids in a 3-bed ranch he's owned for 6 years; attic storage; big backyard.
- **iPhone 13** (no LiDAR). He uses Google Calendar through the iPhone Calendar app, and his partner uses iCloud.
- **Goals:** "Where did I store my winter clothes during the summer?"; kids' clothes by season and size; chores that ping the right person; a record of the 6 years of improvements he can still remember, before he forgets them.
- **Frustrations:** the seasonal swap is a weekend of opening bins; the family chore chart on the fridge is ignored.
- **Success for him:** every bin in the attic is labeled in the app; the seasonal swap list tells him exactly which bins to pull down; chores appear in his Google calendar.

### 3.3 Linda — long-time owner, preparing to sell in a few years (tertiary)
- 62, retired teacher, 24 years in a single-story ranch. **iPhone 12** (no LiDAR), uses **larger text**.
- **Goals:** log the roof (2019), HVAC (2021) and bathroom (2023) with costs and receipts; know which appliances are under warranty; have something to hand a buyer's agent later.
- **Frustrations:** she's "not good at drawing" and dislikes fiddly apps.
- **Success for her:** a usable plan via *Rough it in* in about a minute; past work logged with receipt photos; readable at large Dynamic Type sizes.

---

## 4. v1 scope

### 4.1 In scope (v1 TestFlight)
- iPhone only, **iOS 17+**, native SwiftUI.
- Floor plan created via **Scan (LiDAR)**, **Build with blocks**, **Trace a photo** or **Rough it in**, plus a plan editor.
- **Floor pills** (tabs only, no swipe), **Ground floor default** with a Settings override.
- **Exterior level** seeded from the address: the OpenStreetMap footprint on an Apple Maps satellite image, with the zones Front yard, Backyard, Side yard L/R, Driveway and Sidewalk, all adjustable; users can add zones.
- **Seven views** in a single-choice dropdown: Plan, To-Dos, Future Projects, Past Work, Appliances/Electronics/Furniture, Inventory, Budget.
- **"+" in every room** with six add types: To-Do, Future Project, Past Work, Appliance/Electronic/Furniture, Inventory item, Measurement.
- **Chores** with repeat rules, assignee (housemate label), **local push reminders**, and **calendar events via EventKit** (Apple Calendar and Google calendars added to the iPhone).
- **Projects**: one record Idea → Planned → In Progress → Done, with estimate vs. actual cost and hours, line items, receipt scan with on-device OCR, photos.
- **Budget**: computed from projects, rolled up room → floor → property.
- **Things** (appliances, electronics, furniture, fixtures, systems) with templates (bulbs, filters, appliances) and linked spare stock.
- **Measurements** as a first-class feature, with a **fit check**.
- **Inventory**: nested storage spots, housemates, clothing with a **seasonal swap**, pantry with a **shopping list**.
- **Search** ("where is…"), **CSV export**, **Settings**, **Recently Deleted**.
- **iCloud sync** across one person's devices, with no sign-in.
- **VoiceOver list view** and accessibility baseline.

### 4.2 Non-goals (v1)
| Non-goal | When |
|---|---|
| Paywall, StoreKit, pricing | Not now (founder) |
| App Store public release; dates | Not now (founder) |
| Household sharing across Apple IDs | v1.2 |
| iPad | v1.2 |
| Swipe to change floors | Test after TestFlight (decision #12) |
| Home History Report | Later (headline) |
| AI features (photo-to-plan, room photos to 3D, remodel ideas, photo-to-item) | After v1 |
| MLS or public-listing floor plan import | Not used (founder agreed) |
| Public-record / assessor lookups | Parked |
| Barcode scanning; grocery delivery hand-off | Later |
| Direct Google sign-in for calendars | Deferred |
| Editable door/window geometry (they're display-only) | Not planned |
| Server, accounts, analytics SDK | None in v1 |
| Android, web, Mac | Not planned |
| DIY / landscaping guides; mulch or sod estimates | Later |
| Two-way calendar sync (edits in Calendar flow back) | Not planned |
| Multiple properties in the UI | **PRD assumption:** v1 UI shows one property; schema allows more (open question Q-13) |

---

## 5. Goals and success metrics (tiny beta)

With 2–5 testers, statistics are meaningless. Success is judged by **qualitative evidence** plus a handful of **binary per-tester signals**. There is no analytics SDK (**Assumption pending founder confirmation, HLD §9-25**), so signals come from (a) a short interview after week 1 and week 4, (b) TestFlight feedback and crash reports, and (c) the tester's opt-in **Export diagnostics** file, which carries counts only and no content (see `features/09`, FR-SES-40).

### 5.1 Goals
| # | Goal |
|---|---|
| PG1 | Testers get a plan they recognize as *their* house in their first session. |
| PG2 | The plan-as-navigation idea works: testers use the dropdown and "+" instead of asking for a list. |
| PG3 | Chores become a weekly habit driven by reminders. |
| PG4 | Testers log at least one real past project with a cost and receipt, and one real planned project. |
| PG5 | "Where is…?" gets answered by search at least once in a real situation. |
| PG6 | No data loss, and nothing that erodes trust in sync. |

### 5.2 Measurable signals (per tester)
| Signal | Definition | Target (beta) | Source |
|---|---|---|---|
| **Activation: plan** | A property with ≥1 floor and ≥4 rooms exists at the end of the first session | 5/5 testers (or all) | Diagnostics counts + interview |
| **Time to first plan** | Rough it in: from the first creation screen to the canvas | ≤ 60 s (observed in a walkthrough); any path ≤ 10 min | Moderated walkthrough / signpost |
| **Activation: tracking** | ≥ 10 items across ≥ 3 kinds (chore, project, thing, inventory, measurement) in week 1 | ≥ 4 of 5 testers | Diagnostics counts |
| **Reminder opt-in** | ≥ 1 chore with a reminder or calendar event | ≥ 4 of 5 | Diagnostics counts |
| **Weekly chore loop (retention)** | Chore completions logged in ≥ 3 of the first 4 weeks | ≥ 3 of 5 | Diagnostics: completions per ISO week (counts only) |
| **Past work logged** | ≥ 1 Done project with an actual cost and a receipt or photo | ≥ 3 of 5 | Diagnostics counts |
| **Search used** | ≥ 1 search that led to opening a result | ≥ 3 of 5 | Interview (search isn't logged) |
| **Data trust** | Zero confirmed data-loss or duplication reports; no sync error unresolved for more than 24 h | 0 incidents | TestFlight feedback, Diagnostics |
| **Stability** | Crash-free sessions | ≥ 99% | TestFlight crash reports |

### 5.3 Qualitative questions (week 1 and week 4 interviews)
1. Does the plan feel like your house? What's wrong with it?
2. Which view do you open most? Which have you never opened?
3. What did you try to add that didn't have a place?
4. Did a reminder or calendar event ever get a chore done that otherwise wouldn't have been?
5. Did you ever doubt that your data was saved or synced?
6. What would you show a buyer or an agent from this app?

---

## 6. User journeys

Screen references are to `../mockups/index.html` frame numbers.

### J1. First run to first plan (new buyer, Priya)
1. **Launch.** A restore check runs (up to 8 s). There's no existing iCloud home, so the app shows **Onboarding: create your plan** (6.1).
2. **Address.** She types the address (autocomplete, no location permission, **HLD §9-23**). It's optional and can be skipped.
3. **Pick a path.** Four cards: *Scan* (shown only on LiDAR devices), *Build with blocks*, *Trace a photo*, *Rough it in*. Non-LiDAR devices see *Rough it in* suggested first.
4. **Scan.** Camera permission is requested now. She walks each room, taps Done, then "Finish floor". A **review screen** lets her rename rooms, map scanned stories to floors, and accept or reject each suggested appliance ("We found a refrigerator in Kitchen. Add it?").
5. **Commit.** The canvas opens on the **Ground floor** in the **Plan** view (2.1). In the background the exterior level is seeded from the address (2.8).
6. **Second floor.** She taps the floor pill "+" and scans upstairs. If it's a separate session, she aligns it over the floor below with two points (the stairs) (**HLD §9-26**).
7. **First items.** She switches to *Appliances, Electronics & Furniture*, taps the furnace in Utility, opens the template, and types "16x25x1 MERV 11".
8. **Done** when she recognizes her house and has at least 1 item.

*Alternative (Linda, Rough it in):* floors = 1, ~1,600 sq ft, 3 beds, 2 baths → the canvas appears in under 60 s with dashed "approximate" rooms and "~12′ × 14′" labels. She renames "Bedroom 3" to "Sewing room" and leaves the rest approximate.

### J2. Weekly chore loop (Matt)
1. **Setup (once).** In the *To-Dos* view, he taps "+" in the Kitchen → To-Do: "Run dishwasher", daily, 8 pm, assignee Kid 1, reminder on. Then "Trash out" weekly on Tue and Fri (**HLD §9-3**), assignee Matt, "Add to calendar" on → he picks his Google calendar "Family" (Google caveat, **HLD §9-7**). Then "Change furnace filter" every 90 days after completion, linked to the Furnace thing.
2. **Reminder fires.** At 8 pm a notification says "Run dishwasher · Kitchen". He long-presses → **Done**, without opening the app. The next one is scheduled for tomorrow.
3. **Open the app.** The To-Dos view (2.2) shows chips of "due this week" per room and red edges on rooms with overdue chores. Tapping Laundry opens the **Room sheet** (3.3) grouped Overdue / Today / This week / Later.
4. **Catch up.** "Fold laundry" is 3 days overdue. He checks it off; the next due date is tomorrow, not 3 stacked items (**HLD §9-4**).
5. **Filter.** He completes "Change furnace filter". The app asks "Used a spare 16x25x1? (3 left)" → Yes → 2 left (**HLD §9-20**). The next due date is 90 days from today.
6. **Weekly glance.** The summary strip reads "7 due this week · 2 overdue".

### J3. Logging a completed project (Linda, retroactive; Priya, live)
1. **Retroactive.** In *Past Work*, she taps "+" in the Bathroom → Past Work: "Bathroom remodel", completed 2023-05, actual $14,200, 0 hours (contractor), vendor "Smith & Sons". She scans the invoice: OCR pre-fills total, date and vendor, each marked "From receipt – check". She confirms.
2. **Live (Priya).** The Future Project "Kitchen refresh" (Planned, est. $4,000, 20 h) moves to *In Progress*. She adds line items: paint $180 (material), cabinet hardware $240 (material), electrician $600 (labor, receipt scanned).
3. **Mark Done.** Status → Done. The Done sheet pre-fills the actual cost with the line-item sum ($1,020) or lets her override it ($4,612), the date (today) and hours. She confirms.
4. **Effect.** The project leaves Future Projects and appears in Past Work ("$4.6k · Sep '26"). Budget shows the room's planned vs. spent, and the variance (+$612) is kept (**HLD §9-15**).

### J4. Seasonal clothes swap (Matt, late September)
1. **Storage set up earlier.** Attic › Shelf 2 › Bin "Winter – Matt"; Attic › Shelf 2 › Bin "Winter – Kids"; Primary closet › Top shelf. Clothing items are tagged by owner, category, season and "stored"/"in rotation".
2. **Open Seasonal swap** (5.2) from the Inventory view's strip or the Inventory menu. The upcoming season is **Winter** (from the date and property latitude, **HLD §9-19**).
3. **Two lists.** *Get out*: winter items that are stored, grouped by owner → room → spot path ("Attic › Shelf 2 › Bin Winter – Matt: 2 coats, 1 boots"). *Put away*: summer items in rotation.
4. **Filter** by housemate (Kid 1). He pulls the bins listed.
5. **Swap.** "Swap all" (or per item) flips in-rotation/stored in one step. A prompt offers "Move put-away items to a spot…" → he picks Bin "Summer – Kids".
6. **Later.** In July, search "winter coat" → the answer card "Winter coat → Attic › Shelf 2 › Bin Winter – Matt".

### J5. Buying an appliance with a fit check (Priya)
1. **Measure first.** In the Kitchen, "+" → Measurement "Fridge opening", 32 in W × 40 in D × 72 in H, pinned to the spot on the plan (4.4). She flags the front door measurement (36 × 80 in, from the scan) as the **delivery path** (**HLD §9-11**).
2. **Shopping.** "+" → Appliance → template Refrigerator → ownership **Planned purchase** (**HLD §9-10**), 35¾ W × 30 D × 70 H, "Goes into: Fridge opening".
3. **Fit check.** A live banner (4.3): "35¾ in wide won't fit the 32 in opening (4¾ in short incl. clearance)". Height fits (1 in spare). Delivery path: fits through the front door. The clearances use defaults (fridge 1 in each way, **HLD §9-12**), which she can edit.
4. **Try another.** She edits the dimensions to a 30 in model → green "Fits" (1 in spare on width).
5. **Bought it.** She switches the thing to **Owned**, adds a purchase date, price and warranty end, and attaches the receipt. The planned (dashed) icon becomes solid on the plan.

---

## 7. Feature list, priorities and phase mapping

**Priority key:** **P0** = required for the first TestFlight build to be useful; **P1** = in v1, can land in a later TestFlight build; **P2** = nice-to-have in v1, first to cut.
**Phase key** (merged plan §9, ordered, no dates): **1** Plan core · **2** Tracking core · **3** Inventory · **4** TestFlight hardening.

| Area | Feature | Pri | Phase | Spec |
|---|---|---|---|---|
| Plan creation | Rough it in | P0 | 1 | 01 |
| | Build with blocks (house-style templates) | P0 | 1 | 01 |
| | Scan with RoomPlan (LiDAR) incl. review screen and suggested things | P0 | 1 | 01 |
| | Trace a photo with scale calibration | P1 | 1 | 01 |
| | Plan editor: move, resize, typed dimensions, snap, add/delete, split/merge, undo | P0 (split/merge P1) | 1 | 01 |
| | Rename / relabel rooms | P0 | 1 | 01 |
| | Hand-placed doors and windows (display-only) | P1 | 1 | 01 |
| | Multi-floor alignment for separate scans | P1 | 1 | 01 |
| Canvas | Floor pills, ground default, Settings override | P0 | 1 | 02 |
| | Seven-view dropdown and lens rendering | P0 (Plan in phase 1; others in 2–3) | 1–3 | 02 |
| | "+" add picker with view default | P0 | 2 | 02 |
| | Room sheet (half/full detents) | P0 | 2 | 02 |
| | Summary strip and Whole house / This floor chip | P0 | 2 | 02 |
| | VoiceOver list view | P0 | 2 | 02 |
| | Fade labels of rooms with nothing in the view | P2 | 2 | 02 |
| Exterior | Address → footprint → satellite → seeded zones | P0 | 1 | 03 |
| | Adjust, add, delete zones; rotate | P0 | 1 | 03 |
| | Fallback block when there's no footprint or network | P0 | 1 | 03 |
| Chores | Chores with repeat rules, assignee, room | P0 | 2 | 04 |
| | Complete / skip / snooze; completion history | P0 | 2 | 04 |
| | Local push reminders with Done / Snooze actions | P0 | 2 | 04 |
| | Calendar events via EventKit (Apple + Google on device) | P0 | 2 | 04 |
| | Chore → linked appliance; "Turn into project" | P1 | 2 | 04 |
| | Spare-stock decrement prompt | P2 | 3 | 04 / 06 |
| Projects & budget | Project record with status Idea→Done, est vs. actual cost and hours | P0 | 2 | 05 |
| | Line items | P0 | 2 | 05 |
| | Receipt scan + OCR pre-fill | P1 | 2 | 05 |
| | Budget rollups room → floor → property; Budget view + drill-down | P0 | 2 | 05 |
| Things | Things with categories, pins, specs, warranty | P0 | 2 | 06 |
| | Templates (bulbs, filters, appliances, detectors) | P0 | 2 | 06 |
| | Spare stock link to Inventory | P1 | 3 | 06 |
| | Planned-purchase ownership state | P1 | 2 | 06 |
| Measurements | Measurements on room / spot / door / window / zone | P0 | 2 | 07 |
| | Typed room dimensions become measurements | P0 | 1 | 07 |
| | Fit check incl. delivery path | P0 | 2 | 07 |
| | Pre-fill from Measure app / photo | P2 | 2 | 07 |
| Inventory | Storage spots (nested), housemates | P0 | 3 | 08 |
| | Clothing + seasonal swap | P0 | 3 | 08 |
| | Pantry + shopping list | P0 | 3 | 08 |
| | Pantry expiry digest notification | P2 | 3 | 08 |
| Search/export/settings | Global search with "where is" card | P0 | 2 | 09 |
| | CSV export (zip) | P0 | 2 | 09 |
| | Settings (default floor, units, housemates, reminder defaults, device nickname) | P0 | 1–2 | 09 |
| | Recently Deleted (30 days) | P1 | 2 | 09 |
| | Diagnostics screen + export | P0 | 4 | 09 |
| Sync & data | iCloud sync (basic) | P0 | 1 (**HLD §9-1**) | 10 |
| | Sync hardening, conflict handling, account change | P0 | 4 | 10 |
| | Restore on a new device | P0 | 4 | 10 |

---

## 8. Dependencies and permissions

### 8.1 Platform dependencies
| Dependency | Used for | Risk note |
|---|---|---|
| RoomPlan (LiDAR, iOS 17) | Scan | LiDAR-only (Pro models 12+). Non-LiDAR testers use the other three paths. |
| VisionKit / Vision | Trace a photo, receipt OCR | On-device |
| MapKit (MKLocalSearch, MKMapSnapshotter) | Address, satellite image | Terms for storing snapshots: check before public release |
| OpenStreetMap Overpass API | House footprint, nearest road | Usage policy fine for ≤5 users; attribution required |
| UserNotifications | Chore reminders | 64 pending-notification cap |
| EventKit | Calendar events | Full access required (**HLD §9-6**) |
| CloudKit (CKSyncEngine) | Sync | Tester must be signed in to iCloud with iCloud Drive available |
| BackgroundTasks | Reminder top-up | Best-effort |
| TestFlight / App Store Connect | Distribution, crash reports | Needs an Apple Developer Program membership |

### 8.2 Permissions (all requested in context, never at launch)
| Permission | Trigger | If denied |
|---|---|---|
| Camera | First scan, trace-by-camera, receipt scan, or photo capture | That capture path shows "Camera access is off" with a link to Settings; other paths still work |
| Notifications | First time a chore's reminder is switched on (with an in-app pre-prompt) | The toggle shows "Notifications are off for Home" + Settings link; the chore still saves |
| Calendar (full access) | First time "Add to calendar" is switched on | The toggle reverts, with an explanation + Settings link |
| Photo library | None needed (PHPicker) | – |
| Location | None in v1 (**HLD §9-23**) | – |
| iCloud | Implicit | App works locally; Settings shows "iCloud off – not syncing" |

---

## 9. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| PR1 | **Onboarding friction:** testers give up before having a plan | High | Rough it in (≤60 s) suggested for non-LiDAR; items can be added before geometry is exact |
| PR2 | **Messy scans** (gaps, doubled walls, open plans) | High | Mandatory review screen; editor always available; weld/cleanup (HLD R1) |
| PR3 | **Data loss or duplication in sync** destroys trust | High | Sync built from phase 1; outbox; CSV export; Diagnostics; restore check (HLD R2) |
| PR4 | **Data-entry fatigue:** the app feels like work | High | Templates, "+" preselects the view's type, minimal required fields (title only), scan suggestions |
| PR5 | **Reminders stop** when the app isn't opened for ~2 weeks | Medium | 14-day window, background top-up, sentinel notification (**HLD §9-8**) |
| PR6 | **Google calendar confusion** (can't create a "Home" calendar in Google; Google not added to iPhone) | Medium | Explain in the picker; pick an existing Google calendar (**HLD §9-7**); direct sign-in deferred |
| PR7 | **Scope creep** from inventory (pantry, clothing) | Medium | Fixed field sets; no barcode or AI in v1 |
| PR8 | **Canvas performance** on older phones | Medium | HLD §5.4 budgets; XS as the floor device |
| PR9 | **Overpass unavailable** or wrong footprint | Low | Fallback block; drag to fix; retry from Settings |
| PR10 | **Housemates expect their own phones to work** before v1.2 | Medium | Clear "labels only" copy; calendar events on a shared calendar as a workaround |
| PR11 | **Apple Maps / OSM terms** at public scale | Low now | Snapshot cached locally only; review before public release |

---

## 10. Release plan (TestFlight)

No dates; stages are ordered.

| Stage | Contents | Entry criteria | Exit criteria |
|---|---|---|---|
| **0. Design review** | Mockups (`../mockups/`) walked through with 2–5 testers | Mockups complete | Founder signs off on views, "+" flow, room sheet, measurements, storage; open questions in §15 answered |
| **1. Internal build A (founder only)** | Phase 1: plan creation, canvas (Plan view), exterior, Settings, basic sync | Phase 1 done | Founder can create his own house by 2+ paths; plan survives reinstall via iCloud restore |
| **2. Internal build B (founder household)** | Phase 2: chores, reminders, calendar, projects, budget, things, measurements, search, export | Build A exit | One week of real chore use; no P0 bugs open |
| **3. Beta build C (2–5 testers)** | Phase 3 inventory + Phase 4 hardening, Diagnostics | Build B exit; manual TestFlight checklist (HLD §5.7) passes: real scan, Google calendar via iOS Settings, two-device sync, airplane-mode edits | Four weeks of use; week-1 and week-4 interviews; §5.2 signals reviewed |
| **4. Post-beta** | Swipe-to-change-floors experiment (decision #12); triage; v1.2 planning (sharing, iPad) | Build C exit | Founder decides on v1.2 scope |

**Distribution notes:**
- Testers who are members of the App Store Connect team can be *internal* testers (no Beta App Review). Friends outside the team are *external* testers, and the first external build needs Beta App Review. **PRD assumption:** use an external group for friends; see Q-14.
- Each build ships release notes listing what to try and known issues.
- Testers are asked to keep data they care about exported via CSV during the beta.

---

## 11. Future roadmap (post-v1, not scheduled)

| Theme | Item | Notes |
|---|---|---|
| **Headline** | **Home History Report** | A shareable document (PDF and/or web link) of the plan, past work with dates, costs and receipts, appliance ages and warranties, and maintenance history. The estimate is kept alongside the actual so it can show "planned $4k, spent $4.6k". Likely uses the reserved Render service for the web link. |
| Sharing | Household sharing across Apple IDs (CKShare, zone per property); iPad | v1.2 |
| AI (with home photos, founder-approved) | Photo-to-plan; room photos to 3D; remodel planning; photo-to-item (inventory); smarter receipt parsing | Runs on the Render account (stateless) or on device |
| Data entry | Barcode scanning for pantry and appliances; model-number lookup | |
| Guides | DIY and landscaping resources; mulch, sod and plant-count estimates from zone areas | Uses zone measurements |
| Calendar | Direct Google sign-in | Needs Google OAuth verification |
| Records | Public-record / assessor square-footage sanity check | Parked |
| **Partnerships** | **Real estate agents:** gift the app at closing with the plan pre-loaded. **Contractors:** send a Future Project out for quotes. **Appliance and furniture retailers:** "fits your 32 in opening" shopping from measurements. **Grocery delivery:** the pantry shopping list becomes an order. | Founder's partnership map |
| Monetization | Paywall design | Not now |

---

## 12. Glossary
| Term | Meaning |
|---|---|
| **Level / floor** | A floor, basement, attic or the exterior. The exterior is a level named "Outside". |
| **Space / room** | A polygon on a level: a room indoors, or a zone outdoors. |
| **View** (code: lens) | One of the seven dropdown choices. |
| **Chore / To-Do** | A recurring or one-off household task. Never has a cost. |
| **Project** | An improvement or repair; one record moving Idea → Planned → In Progress → Done. Future Projects and Past Work are views of it. |
| **Thing** | A durable item: appliance, electronic, furniture, fixture, system. |
| **Inventory item** | A consumable or belonging: pantry, clothing, stored, other. |
| **Storage spot** | A named, nestable place inside a room (shelf, bin). |
| **Housemate / person** | A label for a person in the home; no account in v1. |
| **Scope** | What an item is attached to: a room, a floor, or the whole house. |

---

## 13. Traceability to founder statements
| Founder statement (transcript / decisions) | Where addressed |
|---|---|
| "The UI… should feel like I'm really working on my house" | §1.3, spec 02 |
| Ground floor default, pill tabs for floors | spec 02 FR-CNV-01..06 |
| Drag-and-drop shapes / take a picture for people "not very good at drawing" | spec 01 (Blocks, Trace, Rough it in) |
| Front yard, backyard, side yard, driveway, sidewalk | spec 03 |
| Single-select dropdown with different views | spec 02 |
| Budget per improvement, per room, floor, property | spec 05 |
| "+" in each room | spec 02 |
| Label any room | spec 01 FR-PLN-40 |
| Lights and air filters per room | spec 06 templates |
| "32 in wide… front door 72 in tall" | spec 07 |
| "Where did I store my winter clothes during the summer?" | spec 08, spec 09 search |
| Push + Apple/Google calendar | spec 04 |

---

## 14. Constraints recap
- iPhone only, iOS 17 minimum, TestFlight only, 2–5 users.
- No server in v1; the Render account stays in reserve.
- No paywall; no dates.
- About 1 property per user, < 80 spaces, < 10k records (HLD §1.4).

---

## 15. Open questions and assumptions for the founder

### 15.1 HLD §9 assumptions (pending founder confirmation)
Each is used in the specs as a default, not a decision.

| # | Assumption | Where used |
|---|---|---|
| HLD §9-1 | Basic iCloud sync ships in Phase 1 with the schema; Phase 4 hardens it | PRD §7, spec 10 |
| HLD §9-2 | Geometry stored in inches; metric is a display toggle | specs 01, 07, 09 |
| HLD §9-3 | Weekly repeats can pick specific weekdays; monthly takes an interval (every 12 months = yearly); each rule has an anchor (on schedule / after completion) | spec 04 |
| HLD §9-4 | Missed occurrences collapse (no stacking); a "Skip" action exists | spec 04 |
| HLD §9-5 | One device per chore owns its calendar events; hand-off in Settings | spec 04 |
| HLD §9-6 | Calendar needs *full* access, not write-only | spec 04 |
| HLD §9-7 | Google users pick an existing Google calendar; the "Home" calendar is created in iCloud | spec 04 |
| HLD §9-8 | Up to 60 reminders over 14 days, background top-up, "Open Home to keep reminders coming" notice | spec 04 |
| HLD §9-9 | Optional daily pantry expiry digest (off by default) | spec 08 |
| HLD §9-10 | Things have ownership: Owned or Planned purchase; planned ones draw dashed and aren't counted | specs 06, 07 |
| HLD §9-11 | Things can point at the measurement they go into; measurements have a kind; one door can be the "delivery path" | spec 07 |
| HLD §9-12 | Default fit-check clearances per category, editable per item; deep fridges warn, not fail | spec 07 |
| HLD §9-13 | Doors and windows can be hand-placed in edit mode (display-only) | specs 01, 07 |
| HLD §9-14 | Default floor stored once per property (synced), not a per-level flag | specs 02, 09 |
| HLD §9-15 | Budget: Planned = Planned + In Progress estimates; Ideas shown separately; Spent = In Progress + Done actuals (or line-item sum); variance shown for Done; hours roll up the same way | spec 05 |
| HLD §9-16 | Rough-it-in rooms are marked approximate (dashed, "~") until edited | spec 01 |
| HLD §9-17 | Exterior front faces the nearest road | spec 03 |
| HLD §9-18 | Satellite image not synced; each device re-downloads | specs 03, 10 |
| HLD §9-19 | Seasonal swap's "upcoming season" derived from date + hemisphere | spec 08 |
| HLD §9-20 | Completing a chore linked to a thing with spare stock prompts "Used a spare? (N left)" | specs 04, 06 |
| HLD §9-21 | Recently Deleted keeps items 30 days; deleting a room asks where its items go | spec 09, spec 01 |
| HLD §9-22 | Changing iCloud accounts never merges data: export, then erase | spec 10 |
| HLD §9-23 | No location permission; address is typed | spec 03 |
| HLD §9-24 | CSV export is a zip of one CSV per record kind | spec 09 |
| HLD §9-25 | No analytics SDK; TestFlight + opt-in diagnostics file | PRD §5, spec 09 |
| HLD §9-26 | Separately scanned floors are aligned by two matching points | spec 01 |
| HLD §9-27 | CloudKit fields encrypted by default | spec 10 |

### 15.2 Open questions (new, from this PRD)
| # | Question | Default used until answered |
|---|---|---|
| Q-1 | **Budget tint scale.** The mockup (2.3) uses fixed steps (< $1k, $1k–$5k, ≥ $5k); the LLD uses 5 buckets relative to the biggest room on the floor. Which? | Fixed steps from the mockup for Future Projects; relative for Past Work and Budget |
| Q-2 | **Season boundaries.** HLD §9-19 says Mar–May → Summer upcoming, Sep–Nov → Winter upcoming; LLD §11.4 says Mar–Aug → Summer, Sep–Feb → Winter. Which months count as "swap time"? | LLD (Mar–Aug summer, Sep–Feb winter) |
| Q-3 | Should **appliance purchase prices** (Things) count in Budget / Past Work spend, or only Projects? | Projects only (merged plan §2) |
| Q-4 | Should the **seasonal swap** include non-clothing stored items (holiday decor, pool gear)? | Clothing only |
| Q-5 | **Who gets credit** for a completion done from a notification (no person chosen)? | Unassigned; editable in history |
| Q-6 | **Rotating chores** between housemates (e.g. dishes alternate)? | Not in v1 |
| Q-7 | Do testers need **Spring/Fall** seasons, or are Summer/Winter/All-year enough? | Three seasons (merged plan) |
| Q-8 | Should **Ideas** count toward "Planned" in the Budget view? | No, shown separately (HLD §9-15) |
| Q-9 | Default **reminder time** for all-day chores | 9:00 am |
| Q-10 | Are **counts-only diagnostics** acceptable for measuring beta signals (tester opt-in export)? | Yes, opt-in |
| Q-11 | **Attachments in CSV export** on by default? | Off (toggle) |
| Q-12 | Should the **exterior** appear as a floor pill ("Outside") or only via a house-outline tap? | A pill labeled "Outside", last in order |
| Q-13 | **Multiple properties** (vacation home, rental) in v1 UI? | One property in v1 |
| Q-14 | Are all testers on the **App Store Connect team** (internal testing) or friends (external, needs Beta App Review)? | External group |
| Q-15 | **Currency**: USD only for the beta? | USD, from the property setting |
| Q-16 | Should completing a **one-off to-do** that was spawned into a project close the to-do automatically? | No; user closes it |
| Q-17 | **Room photos**: should the room sheet show a photo gallery per room in v1 (attachments on spaces are supported)? | Yes, P2 |
