# Where Plan A and Plan B Disagree (for the founder)

**Sources:** Plan A (`01-plan-A.md`), Plan B (`02-plan-B.md`), A's review of B (`03-review-A-of-B.md`), and B's review of A (`04-review-B-of-A.md`). As you asked, the planners did **not** resolve their disagreements. This page lays them out for you to decide.

---

## 1. Open disagreements: your call

| # | Topic | Plan A | Plan B | After peer review |
|---|---|---|---|---|
| 1 | **How many "views" in the dropdown for v1** | **5**: To-Dos, Future Projects, Past Work, Inventory (includes appliances/systems), Budget. Furniture, Yard Inventory and Landscaping come in v1.1. | **9**: Plan (default), To-dos, Planned, History, Budget, Furniture, Inventory, Appliances & Systems, Plants & Landscaping | **Still split.** A: five distinct views beat nine that look alike. B: you named furniture, yard and landscaping as "the core of the product", so cutting them contradicts you. |
| 2 | **Turning a to-do into a completed improvement** | Two linked records: the to-do, plus a separate "past work" entry that resolves it | One record whose status changes from planned to done | **They each switched to the other's view.** A now prefers B's single record (simpler, and it keeps photos and costs together). B now prefers A's linked pair (it keeps the audit trail). A genuine tie. |
| 3 | **Yard/exterior setup in v1** | Template zones (front yard, backyard, driveway…) around a gray house box. Satellite and footprint come in v1.1. | Automatically place the house footprint from free Microsoft/OpenStreetMap data over an Apple Maps satellite image of your address | **Still split.** B: this is what makes the yard look like *your* yard. A: hosting the data is a real engineering job, the data license has obligations, and Apple's terms on storing satellite snapshots are unverified. |
| 4 | **Does v1 need any server at all?** | None | One small stateless server, for the footprint lookup and template updates | Follows from #3 |
| 5 | **Should Budget rollups be behind the paywall?** | No. Budgets are the core "aha", so charge for storage, reminders, reports and sharing. | Budget drill-downs are part of Pro | A raised this; B didn't respond |
| 6 | **Timeline to v1 launch** | About 22 weeks | About 17 weeks | **Both reviews say A's 22 weeks is more realistic**, especially with B's larger scope |
| 7 | **When to prototype the room scan (RoomPlan)** | Phase 3 (around weeks 14–17), after a Figma clickable-prototype test | Week 1 code spike | B: it's the hardest technical risk, so test it first. A didn't respond. A combined path is possible: Figma for the UX plus an early scan spike. |
| 8 | **Minimum iOS version** | iOS 17 (reaches more phones) | iOS 18 (fewer devices to test) | Minor, still split |
| 9 | **Household sharing (spouse/partner)** | v1.2 | v1.1 | B wants it sooner ("spouses co-own houses") |
| 10 | **iPad** | v1.2 | Nearly free at launch | Minor |
| 11 | **Which floor opens by default** | The last floor you viewed | Always the ground floor | You said ground floor. B flagged A for drifting from that. |
| 12 | **Swipe to change floors** | Swipe or pill tabs | Pill tabs only (swiping conflicts with panning the plan) | Minor UX |

## 2. Where both plans push back on your idea

Both planners made the same call here, but it differs from what you described, so you should confirm it:

- **Bright MLS and other public floor plans won't work as an automatic source.** MLS data is licensed to brokers, not public. Listing floor plans are copyrighted by the photographer or vendor, and most homes don't have one. Both plans replace this with:
  - a LiDAR room scan (Pro iPhones only)
  - drag-and-drop room blocks with typed dimensions
  - tracing over a photo of a plan you already own
  - a 60-second rough version you refine later

  The only legitimate MLS route either plan found is a later partnership with real estate agents, where the agent gifts the app to the buyer at closing.
- **Pantry and clothing inventory gets no dedicated screens.** Both plans still allow those items, but treat them as generic inventory. Both argue it's a different, high-upkeep product that dilutes the house focus. You listed them as examples, so confirm you're OK with that.
- **iPhone only, with data stored in the user's iCloud.** Neither plan has Android, a web version, or accounts in v1.

## 3. Resolved in peer review (one planner conceded)

- **Storage technology:** A conceded to B. A's choice couldn't support household sharing later.
- **The floor plan opens on a plain "Plan" view** (names and dimensions, like a listing) before any view is chosen: A conceded to B.
- **A 60-second "rough it in" floor-plan option:** B conceded to A.
- **Receipt scanning in v1:** B conceded to A.
- **Items can belong to a room, a whole floor, or the whole house:** B conceded to A.
- **Track time as well as money** (you said "time or money"): A conceded to B.
- **Free tier includes unlimited to-dos,** plus a lifetime-purchase option: A conceded to B.
- **Doors and windows are display-only in v1:** A conceded to B.
- **Smaller wins:** the "+" button sits in the true visual center of oddly shaped rooms, an accessibility list view, and CSV export.

## 4. Questions only you can answer (raised by one or both plans)

1. **Target user:** new homebuyers (both recommend this) or long-time owners?
2. **Accuracy or recognizability** as the v1 bar: exact dimensions, or "looks like my house"?
3. **A "Home History Report" for resale or insurance:** a headline feature or a side feature?
4. **Brokerage or agent partnerships** later: open to them?
5. **AI features that upload photos of your home to a server:** OK, given the privacy positioning?

## 5. Facts to verify before relying on them

The planners flagged each other's claims, but **neither checked live sources**:

- Whether SwiftData (A's original storage choice) can support household sharing. B says no, and A agreed.
- Plan A said "Sign in with Apple is implicit" with iCloud. B says that's wrong: they are separate mechanisms.
- Whether Regrid has a usable free tier (B doubts it).
- Apple's terms on storing Apple Maps satellite snapshots long-term (a risk to B's exterior plan).
- The Microsoft Building Footprints data license and the effort to host it (a risk to B's exterior plan).
- Whether B's floor-plan drawing code can export straight to PDF. A says it needs an extra rendering step.
