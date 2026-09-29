# Homeowner App: Merged Plan (v1)

**Inputs:**
- `00-founder-transcript.md`, the founder's original description of the idea
- `01-plan-A.md` and `02-plan-B.md`, the two planners' independent plans
- `03-review-A-of-B.md` and `04-review-B-of-A.md`, each planner's critique of the other plan
- `06-founder-decisions.md`, the founder's calls on the open disagreements

**Status:** planning only. The founder said "Just plan, don't build", so there is no code, no prototype and no scan spike yet.

**Audience for v1:** 2–5 people (the founder's household and friends), installed through TestFlight. No paywall, no App Store launch, and no dates. The founder said the timeline "doesn't matter".

---

## 1. Decision log

| # | Topic | Decision | Source |
|---|---|---|---|
| 1 | Dropdown views | **Plan** (default), **To-Dos**, **Future Projects**, **Past Work**, **Appliances, Electronics & Furniture**, **Inventory** (food and clothing), and **Budget** | Founder; Plan view settled in review |
| 2 | To-dos vs. improvements | **To-dos are recurring household chores** (dishes, laundry), a separate thing from improvements. Improvements go from Future Projects to Past Work. | Founder |
| 3 | Yard/exterior | **Plan B.** The house outline is placed automatically over a satellite image of the address, then the user adjusts the yard zones. | Founder |
| 4 | Server | Data is stored on the phone and synced through the user's iCloud. An **optional** small service on the founder's Render account can handle lookups. It stores no user data. | Founder |
| 5 | Paywall | None for now. Every feature is free. | Founder |
| 6 | Timeline | No dates. Phases below are ordered, not scheduled. | Founder |
| 7 | Room-scan testing | Not now. The plan only. | Founder |
| 8 | Minimum iOS | **iOS 17** | Founder (A) |
| 9 | Household sharing | Later, in v1.2. Housemates are still *labels* in v1 (see §5). | Founder (A) |
| 10 | iPad | v1.2 | Founder (A) |
| 11 | Default floor | **Ground floor.** Users can change it in Settings. | Founder |
| 12 | Changing floors | **Pill tabs only** at launch. Test swipe-to-change after launch. | Founder (B, then A) |
| — | MLS floor plans | Not used as a source. Users create their own plan. | Founder agreed |
| — | Pantry and clothing | **Get dedicated screens**, tracked by housemate and by storage location | Founder overruled both plans |
| — | Platform | iPhone only, with data in iCloud | Founder agreed |
| — | Measurements | **Exact measurements are a first-class feature**: appliance openings, doors, and yard beds | Founder (new) |
| — | Target user | New homebuyers first, but useful to existing owners | Founder |
| — | Chore reminders | Push notifications plus calendar events (Apple and Google Calendar) | Founder |
| — | Public records | Parked | Founder |
| — | Home History Report | A headline feature, but **not in v1** | Founder |
| — | AI with home photos | Allowed, but after v1 | Founder |

**Settled in peer review, carried forward unchanged:**
- SQLite (GRDB) storage with CloudKit sync (`CKSyncEngine`)
- the "rough it in" floor plan option
- receipt scanning in v1
- items scoped to a room, a floor, or the whole house
- time tracked (hours) alongside money
- doors and windows display-only
- the "+" button at the visual center of the room
- a VoiceOver list view
- CSV export

---

## 2. The dropdown views

The canvas always shows the current floor. The dropdown (single choice) changes what is drawn on each room, and what appears in the room sheet that slides up from the bottom.

| View | What it holds | What the plan shows on each room |
|---|---|---|
| **Plan** (default) | Nothing; this is the plain listing-style plan | Room name and dimensions |
| **To-Dos** | Recurring chores and one-off tasks | A count of items due today or this week; a red edge if anything is overdue |
| **Future Projects** | Improvements or repairs you want to do, with an estimated cost and time | Planned cost chip; rooms tinted by planned spend |
| **Past Work** | Completed improvements and repairs, with actual cost, date, receipts and photos | Lifetime spend and the date the room was last worked on |
| **Appliances, Electronics & Furniture** | Durable things: fridge, TV, sofa, light fixtures and bulbs, HVAC and air filters, smoke detectors | Small icons placed where each item sits in the room, plus a count |
| **Inventory** | Consumables and belongings: pantry food, clothing, stored seasonal items | Item count per room or storage spot |
| **Budget** | Calculated from Future Projects and Past Work, never entered directly | Planned vs. spent per room, with floor and property totals in the bottom strip |

The **"+" in each room** offers: To-Do, Future Project, Past Work, Appliance/Electronic/Furniture, Inventory item, and Measurement. It defaults to whichever view is active.

---

## 3. To-dos, projects, and how they connect (new model)

The founder separated two ideas the planners had merged.

- **To-Dos are chores.** Examples: "Do the dishes", "Fold laundry", "Change HVAC filter".
  - Each has an optional **repeat rule**: daily, weekly, every N days, or monthly on day X.
  - Each has an optional **assignee** (a housemate) and a **room**.
  - Completing one logs the completion and schedules the next due date. There is no cost, and chores never enter Budget.
  - A chore can **link to an appliance**. For example, "Change filter" links to the furnace, so the app knows the filter size and when it was last done.
- **Reminders and calendar (founder decision):**
  - Every chore can send a **push notification** when it's due. These are local notifications scheduled by the phone, so no server is needed. Each chore has its own on/off switch and time. When a chore is completed, the next reminder is scheduled.
  - Every chore can also be **added to a calendar** as an event, which repeats if the chore repeats.
    - **Apple Calendar:** uses Apple's built-in calendar access (EventKit) on the phone.
    - **Google Calendar:** if the user's Google account is already added in iPhone Settings › Calendar › Accounts, the same EventKit path writes straight into their Google calendar. There's no Google sign-in and no server. This covers v1.
    - **Direct Google sign-in** (for people who haven't added Google to the iPhone) would need Google's OAuth approval process and is deferred.
  - Users choose which calendar to use (a "Home" calendar is suggested). Editing or deleting the chore updates or removes the event, and completing it doesn't delete past occurrences.
- **Improvements go from Future Projects to Past Work.** This is **one record with a status**: Idea → Planned → In Progress → Done. Marking it Done moves it from Future Projects to Past Work and asks for the actual cost, date and receipt.
  - *Why one record:* the peer review tied on this. Now that to-dos are a separate kind, the "linked pair" argument (keep the to-do that led to the work) mostly goes away.
  - The estimate is kept alongside the actual, so the Home History Report can later show "planned $4k, spent $4.6k".
- **A chore can spawn a project.** An example is "Gutter cleaning found a leak". The user taps "Turn into project" to create a Future Project that links back to the chore.

---

## 4. Floor plan and exterior

### Creating the plan

Four ways, all producing the same editable geometry:
1. **Scan** with a LiDAR iPhone (Apple RoomPlan).
2. **Build with blocks:** drag-and-drop rooms with typed dimensions, starting from house-style templates.
3. **Trace a photo** of a plan you already have (a listing screenshot or closing documents). Two taps and a known length set the scale.
4. **Rough it in:** proportional boxes from approximate square footage. This gives a working canvas in about 60 seconds, and you refine it later.

### Exterior (Plan B)

1. On entering the address, find the house outline from OpenStreetMap or Microsoft Building Footprints.
2. Place it on an Apple Maps satellite snapshot.
3. Pre-create zones for Front yard, Backyard, Side yard L/R, Driveway and Sidewalk. The user drags them to fit and can add more, such as a Patio or Garden bed.

**For 2–5 users:** query OpenStreetMap's free Overpass API directly from the phone. There is no need to host 130M footprints. Hosting the Microsoft dataset only matters at public scale.

### Public records: parked

The founder parked the public-record search (2026-09-29). Plans are built only from the four creation paths above. Assessor data can come back later as a square-footage sanity check.

---

## 5. Measurements (new, first-class)

Founder examples:
- "32 inches of width and 40 inches of depth for my stove/fridge"
- "front door is 72 inches tall, 36 inches wide"
- yard and landscape planning

A **Measurement** is a named set of dimensions (width, depth, height, and optionally a note or photo) attached to one of these:
- a **room** (for example, "Wall behind couch: 118 in")
- a **spot** in a room (for example, "Fridge opening")
- a **door or window**
- a **yard zone** (for example, "Front bed: 24 ft × 4 ft")

Uses:
- **Fit check.** When you log an appliance or piece of furniture with its dimensions, or plan to buy one, the app compares it with the space it's going into. For example: "Fridge 36 in wide won't fit the 32 in opening."
- **Room dimensions** typed on the plan are measurements too, so an accurate plan builds up over time without extra work.
- **Landscaping:** zone areas feed mulch, sod or plant-count estimates later.
- **Tools:** the iPhone Measure app and RoomPlan can pre-fill values. Manual entry always works.

---

## 6. Inventory: pantry and clothing (founder overrode both plans)

The core question is **"Where did I store my winter clothes during the summer?"**

- **Storage locations.** Any room can hold named storage spots, and they can nest. Examples: Attic › Shelf 2 › Bin "Winter – Matt". Kitchen › Pantry › Top shelf.
- **Housemates.** A simple list of people in the home: a name, an optional color, and no accounts. Inventory items, chores and clothing can be tagged to a person. Real multi-device sharing comes later (v1.2).
- **Clothing fields:**
  - owner
  - category
  - season (Summer, Winter, All-year)
  - storage location
  - "in rotation" vs. "stored"

  A **seasonal swap** view lists everything stored for the upcoming season and where it is.
- **Pantry fields:**
  - quantity
  - unit
  - location
  - optional expiration date
  - "running low" flag

  A **shopping list** gathers low items, plus air filters and light bulbs due for replacement.
- **Search** answers "where is…" questions directly. Typing "winter coat" returns *Attic › Bin 3 (Matt)*.
- **Later:** barcode scanning, photo-to-item with AI, and grocery-delivery hand-off (see §8).

---

## 7. Data model (revised)

```
Property 1—* Level (kind: floor|basement|attic|exterior; isDefault)
Level 1—* Space (room | yardZone | driveway | ... ; name; polygon; source)
Space 1—* StorageSpot (name, parentSpotId?)          // nested bins/shelves
Property 1—* Person (name, color)                    // housemates, no accounts in v1
Measurement (id, spaceId? | spotPoint? | openingId?, label, widthIn, depthIn, heightIn, note, photo)

Chore (id, title, spaceId?, levelId?, assigneeId?, repeatRule?, nextDue, linkedThingId?)
  └─ ChoreCompletion (choreId, doneAt, doneBy?)

Project (id, title, scope: space|level|property, status: idea|planned|inProgress|done,
         estCostCents, actualCostCents, estHours, actualHours, startedAt, completedAt,
         spawnedFromChoreId?)
  └─ CostLineItem (label, amountCents, kind: material|labor|permit|other, vendor, receiptId?)

Thing (id, category: appliance|electronic|furniture|fixture|system, spaceId, pinPoint?,
       brand, model, serial, purchaseDate, warrantyEnd, dimensions(w,d,h),
       templateKey?, attributes JSON)             // bulb base, filter 16x25x1 MERV 11, etc.

InventoryItem (id, kind: pantry|clothing|stored|other, ownerId?, storageSpotId | spaceId,
       qty, unit, season?, inRotation?, expiresOn?, lowFlag)

Attachment (photo|receipt|manual) → any of the above
```

This changes the planners' single-table design. Chores, Projects, Things and Inventory now have **clearly different fields and lifecycles**:
- chores repeat
- projects carry cost
- things carry specs and dimensions
- inventory carries quantity, owner and location

Four tables with a shared `Attachment` and search index are clearer than one table with dozens of optional fields. Budget stays a **computed** sum over Projects (never stored), rolled up by room, then floor, then property.

---

## 8. Tech stack

- **App:** native Swift/SwiftUI on iOS 17+, iPhone only.
- **Plan drawing:** SwiftUI `Canvas`, redrawn from the model at every zoom level so lines and text stay sharp. Buttons and chips sit on top as SwiftUI views.
- **Storage:** SQLite via GRDB on the phone, synced through `CKSyncEngine` to the user's private iCloud database. No sign-in screen. Each person's data lives in their own iCloud.
- **Server:** none required for v1. Keep the **Render account in reserve** for these later features, all stateless:
  1. a footprint lookup proxy, if calling Overpass directly becomes a problem
  2. AI features (photo-to-plan, remodel ideas), which the founder has approved
  3. the Home History Report web link
- **Distribution:** TestFlight for 2–5 testers.
- **Frameworks:**
  - RoomPlan (scan)
  - MapKit (satellite snapshot)
  - VisionKit and Vision (plan photos, receipt text)
  - UserNotifications (chore and filter reminders, scheduled on the phone, so no server needed)
  - EventKit (adding chores to the calendars on the phone, which can include Google Calendar)

---

## 9. Roadmap (ordered, no dates)

| Phase | Contents |
|---|---|
| **0. Design** | Figma mockups of the canvas, the seven views, the "+" flow, the room sheet, measurements and storage locations. Walk the 2–5 testers through them. |
| **1. Plan core** | Geometry model; the four creation paths; floor pills; exterior auto-seed on satellite; room rename; Settings (default floor). |
| **2. Tracking core** | Chores with repeats, push reminders and Apple/Google calendar events; Projects with status and costs; Things with templates (bulbs, filters, appliances); Measurements with fit check; Budget rollups; receipt scanning; search; CSV export. |
| **3. Inventory** | Storage spots, housemates, clothing with the seasonal swap view, pantry with the shopping list. |
| **4. TestFlight** | iCloud sync hardening, then 2–5 testers. Then test swipe-to-change-floors (decision #12). |
| **v1.2** | Household sharing across devices, iPad. |
| **Later** | Home History Report (headline feature), AI (photo-to-plan, room photos to 3D, remodel planning), DIY and landscaping guides, and partnerships (see below). |

**Future partnership map (founder):**
- **Real estate agents:** gift the app at closing, with the floor plan pre-loaded.
- **Contractors:** send a Future Project out for quotes.
- **Appliance and furniture retailers:** "fits your 32 in opening" shopping.
- **Grocery delivery:** the pantry shopping list becomes an order.

---

## 10. Founder answers (2026-09-29, round 2)

1. **Public-record search:** parked (see §4).
2. **Chore reminders:** push notifications **and** calendar events for Apple and Google Calendar (see §3).
3. **Housemates as labels until sharing in v1.2:** OK.
4. **Bulbs and filters:** the fixture or appliance spec lives with Appliances/Electronics/Furniture; spare stock is an Inventory item linked to it. Confirmed.

Nothing is open for the founder right now.

## 11. Facts still to verify before building

- Apple's terms for storing Apple Maps satellite snapshots long-term. This is low risk for 5 testers; check before any public release.
- OpenStreetMap Overpass usage policy. It's fine for a handful of users; public scale needs the hosted Microsoft dataset or a paid API.
