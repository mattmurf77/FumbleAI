# Planner B's review of Plan A

## Summary
Plan A and Plan B agree on the big calls:
- MLS is not a viable data source.
- The app is native SwiftUI, with a SwiftUI `Canvas` renderer and CloudKit sync.
- All tracked records live in one unified item table.
- Budgets are computed from the records, not stored.
- There is no tab bar.
- Pricing is freemium at $4.99/mo or $39.99/yr.

The real differences are in four places: how much of the founder's layer list ships in v1, the persistence layer, when the exterior is auto-seeded, and the order of phases. A has several ideas that are better than mine. A also has one technical choice (SwiftData) that I think quietly breaks its own sharing roadmap.

## 1. Where A is stronger than B
- **"Rough it in" mode.** A offers a 60-second canvas built from proportionally sized tiles. I only gestured at this in my risks section. A makes it a real fourth creation path, which is the better activation answer.
- **Scope on items.** A lets an item belong to a space, a floor, or the whole property. B only has space or whole-house, so B cannot represent "repaint the entire 2nd floor". B should adopt A's model.
- **Linking a to-do to the finished work.** A's `ItemLink` ("resolves" / "spawned") keeps the original to-do and its completed-work record as a linked pair. B mutates one entry's status and kind, which loses the fact that a to-do was resolved by a separate job.
- **Receipt OCR and perspective correction in v1.** VisionKit and Vision make these cheap, and they cut data-entry fatigue, which is my risk #5. B deferred OCR to v2. A is right.
- **A Figma gate before any code.** Testing "do users recognize their house?" with a clickable prototype costs less than B's code spikes.
- **Small practical details:**
  - a minimum tap radius for closets
  - a red edge on rooms with overdue items
  - floor area compared against the assessor's square footage
  - CSV export
  - canvas snapshot tests
  - onboarding copy that tells users to find their old listing plan

## 2. Where A is wrong or risky
- **SwiftData with CloudKit sharing in v1.2 (the most serious issue).** SwiftData's CloudKit integration only syncs to the private database. It has no public API for `CKShare` or the shared database; I'm fairly confident of this through iOS 18 and am not aware of it changing. A's household-sharing milestone would therefore force a persistence migration mid-life. SwiftData+CloudKit also rules out unique constraints and requires every relationship to be optional. A also needs aggregate rollups and JSON attribute queries, and SQLite (GRDB) with `CKSyncEngine` handles those directly. The cheap time to choose is now.
- **Five layers contradicts the founder's stated core.** The founder explicitly named furniture, yard inventory and landscaping ideas as views and called them "the core of the product". A defers all three to v1.1. A's model already has `furniture` and `landscapingIdea` categories and a "+" picker offering Furniture, but no layer to show them. A user can add a couch and then never see it on the canvas. The concern about a cluttered dropdown is real, but grouping the menu with sections fixes it. Cutting founder-named features does not need to happen.
- **RoomPlan work is scheduled late (Phase 3, weeks 14–17).** Converting a RoomPlan `CapturedStructure` into clean 2D polygons, including multi-floor alignment and open-plan edge cases, is the hardest geometry problem in the app. Finding its failure modes after the geometry model is frozen is expensive. B spikes it in week 1.
- **Wrapping `Canvas` in a `UIScrollView` for zoom.** UIScrollView zoom scales the already-drawn image, so text and wall strokes go blurry until a redraw at the new scale. The alternative is managing the redraw-on-zoom-end dance yourself. Since the canvas is the product, B's approach is cleaner: keep the viewport transform in the model and redraw vectors every frame.
- **Gesture conflicts.** A uses two-finger pan and also horizontal swipe to change floors. When zoomed in, a one-finger horizontal drag is ambiguous. Choose one: pills for floors, and one-finger pan.
- **The "+" button sits at each room's centroid.** For L-shaped and U-shaped rooms the centroid can fall outside the room. Use the pole of inaccessibility (the interior point farthest from the edges).
- **Opening on the last floor used instead of the ground floor.** The founder said the ground floor should be the default. A small deviation, but it should be flagged to the founder rather than decided silently.
- **Exterior auto-seed deferred to v1.1, with no satellite underlay.** A gray block with template yard zones, and no lot shape or imagery, looks less like "my house" than anything else in the app. MS footprints plus a MapKit snapshot is a few days of work.
- **Assessor prefill through a paid API** is fine as a feature, but it is not the "free public source" the founder asked for. Label it that way.

## 3. Discrepancies

| Topic | A | B | I'd defend | Why |
|---|---|---|---|---|
| v1 layers | 5 (To-Dos, Future, Past, Inventory+Systems, Budget) | 9 incl. Furniture, Plants/Landscaping, Appliances separate | B | Founder named these as core; model already supports them |
| Creation paths | Scan, Blocks, Trace, Rough-it-in | Scan, Shapes, Photo underlay, Outside auto-seed | A's Rough-it-in and B's auto-seed | Both help activation. Merge them. |
| Exterior footprint/satellite | v1.1, no satellite | v1, MS/OSM footprint and MapKit satellite | B | Cheap, and it makes the Outside view recognizable |
| Parcel outline | v1.1 via county GIS/Regrid | User traces lot on satellite | B | No free national parcel API |
| Persistence | SwiftData | SQLite/GRDB | B | Sharing, SQL rollups, JSON queries, migrations |
| Sync | SwiftData+CloudKit | CKSyncEngine | B | Supports CKShare |
| Min iOS | 17 | 18 | Either; slight B | Both have CKSyncEngine and multi-room RoomPlan. 18 cuts the test matrix. |
| Zoom implementation | UIScrollView wrapper | Model-space transform, redraw | B | Crisp vectors and text |
| "+" placement | Centroid | Pole of inaccessibility | B | Works for non-convex rooms |
| Default floor | Last used | Ground floor | B | Founder's spec |
| Geometry units | Inches | Centimeters (Double) | Neutral | Both fine; display converts |
| Scope | Space, level or property | Space or property | A | Handles floor-wide items |
| To-do to done | Separate items with ItemLink | Same entry changes status | A | Keeps the audit trail |
| Home-system attributes | `HomeSystemSpec` side table | JSON on Entry plus template schema | B, mildly | One table, and it queries directly for a shopping list |
| Receipt OCR | v1 | v2 | A | Cheap, cuts entry fatigue |
| Doors/windows | Editable in v1 editor | Read-only v1 (RoomPlan only) | B | Scope. Plans look fine without them. |
| Validation gate | Figma prototype | Code spikes | Both | Figma for UX, a code spike for RoomPlan |
| RoomPlan timing | Phase 3 | M0 spike | B | Highest technical risk |
| Timeline to launch | ~22 wks | ~17 wks | A is more realistic | B's estimate is optimistic |
| Onboarding target | <5 min | <10 min | A's aspiration with Rough mode | |
| Household sharing | v1.2 | v1.1 | B | Spouses co-own houses |
| iPad | v1.2 | Near-free at launch | B | Same SwiftUI code |
| Free tier | 50 items total | Unlimited to-dos + 50 others | B | To-dos drive the daily habit |
| Export | PDF and CSV | PDF | A | CSV is trivial and wanted |
| Floor switching | Pills and swipe | Pills only | B | Avoids the gesture conflict |

## 4. Factual claims in A I believe are incorrect or need checking
1. **"CloudKit (…shared zone for household sharing)" with SwiftData.** I believe SwiftData does not support the CloudKit shared database or CKShare. Verify this against the current SDK before committing.
2. **"Sign in with Apple is implicit."** This is wrong. The iCloud account CloudKit uses and Sign in with Apple are separate mechanisms. With CloudKit there is simply no sign-in. Sign in with Apple is an explicit flow, needed only once a server exists.
3. **"Regrid offers a limited free tier."** Regrid's consumer map viewer is free to browse, but its API/data access is paid. Any free program is restricted, and even if one exists it is not usable for a commercial app. Verify.
4. **`VNDocumentCameraViewController` described as "VisionKit".** This is correct, but the "VN" prefix does not mean it is part of the Vision framework, so avoid mixing up Vision and VisionKit in the implementation notes.
5. **Minor.** RoomPlan object categories do include toilet, stove, bed and similar, so the name-suggestion idea is valid. Just confirm the category list against the current SDK.

A's MLS, copyright, MS Footprints and RoomPlan hardware claims all match my understanding. Neither plan's facts were verified against live web sources this session.