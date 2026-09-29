# Planner A's review of Plan B

## 1. Where B is stronger than A

- **Persistence choice.** B picks GRDB/SQLite with CKSyncEngine, and its argument beats my choice of SwiftData. SwiftData's CloudKit sync doesn't support shared databases, and it forces every property and relationship to be optional or defaulted, with no unique constraints. My plan promised CloudKit household sharing in v1.2 on top of SwiftData, which is a real gap in Plan A. B's stack can actually deliver sharing.
- **Tracking time as well as money.** B adds an `effortHours` field. The founder said "invest either time or money", and I dropped the time half.
- **A "Plan" default layer.** B's canvas opens on names and dimensions only, then you switch to a lens. That matches the founder's "default should look like a general floor plan you'd see on a public listing" better than my plan, which opened straight into To-Dos.
- **Canvas details.**
  - B places the "+" at the pole of inaccessibility rather than the centroid. The centroid of an L-shaped room can fall outside the room.
  - One-finger pan and double-tap-to-zoom-to-room are better than my two-finger pan.
  - B scrolls the canvas so the selected room stays visible above the sheet.
  - B has a VoiceOver list-view mirror.
- **Scope discipline on doors and windows.** B makes them read-only in v1, which is correct. They're a lot of editor work for little tracking value.
- **Planned → completed by status change.** This is simpler than my separate linked items (`ItemLink`), and it keeps photos and cost history on one record.
- **Whole-house items.** B shows a "Whole House" pseudo-room chip on every level. It solves "where do roof and HVAC show up?" better than my plan did.
- **Free tier.** Unlimited to-dos in the free tier is a smarter hook than my flat 50-item cap.

## 2. Where I believe B is wrong or risky

- **Nine layers in v1 is too many.** Furniture, Inventory, Appliances and Plants each get their own layer, but on the canvas they all render the same way: count badge plus tint. That's a filter, not a lens. It spreads design effort thin at exactly the point where the founder says the UI is the product. Five distinct layers beat nine that look the same.
- **Sync arrives too late.** CKSyncEngine sits in M3, but record mapping, conflict handling, and asset upload with a hand-written GRDB layer are what break a schema. Sync has to be designed in M1 alongside the schema, not added at the end.
- **17 weeks is optimistic for B's v1.** It includes nine layers, custom sync, a footprint service, satellite underlays, templates, reminders, PDF export and RoomPlan.
- **The footprint auto-seed service is underpriced.** B budgets it as "one Cloudflare Worker" proxying a pre-tiled MS footprints dataset. But:
  - The US dataset alone is about 130M polygons, so tiling and hosting it is a real data-engineering task.
  - ODbL share-alike and attribution obligations apply to derived databases.
  - ML footprints often don't line up with satellite imagery, so the "magic" can look wrong.

  I'd keep it in v1.1.
- **The MapKit satellite underlay has an unverified terms risk.** Storing `MKMapSnapshotter` imagery long-term as a user underlay may be limited by Apple's MapKit terms. B treats it as settled, and it needs checking.
- **Deriving walls from shared edges is fragile with RoomPlan input.** RoomPlan returns walls with thickness, and adjacent rooms rarely share exact edges; there are gaps and slight overlaps. Deriving walls from coincident polygon edges will produce doubled or missing walls unless there's a tolerance-based merge step. B doesn't mention one.
- **The Budget layer drill-down is behind the paywall.** Budget rollups per room, floor and property are part of the founder's core vision. Charging for them hides the "aha" moment. Charge for storage, reminders, reports and sharing instead.
- **No "rough it in" onboarding path.** B mentions "approximate plan" only as a risk mitigation, not as a designed flow. Its onboarding offers Scan, Build or Photo only, and its target is 10 minutes. I think users who aren't on LiDAR phones need a 60-second option.
- **Receipt OCR is pushed to v2.** Vision text recognition is on-device and cheap. It directly addresses B's own risk #5 (data-entry fatigue), so it belongs in v1.
- **Minimum iOS 18+.** This is defensible, but nothing in B's stack needs 18. CKSyncEngine and StructureBuilder are both iOS 17. The higher floor just excludes users for no benefit.

## 3. Discrepancy table

| Topic | A | B | I'd defend | Why |
|---|---|---|---|---|
| Persistence | SwiftData | GRDB/SQLite | **B** | Supports sharing, SQL aggregates, JSON queries |
| Sync mechanism | CloudKit via SwiftData | CKSyncEngine, built in M3 | B's mechanism, A's timing | Build sync early |
| Minimum iOS | 17 | 18 | A | No iOS 18 dependency |
| Geometry units | Inches | Centimeters (Double) | Neutral | Either works; display converts |
| v1 layer count | 5 | 9 (including a Plan layer) | A, plus B's Plan layer | Distinct lenses over filters |
| Default layer | To-Dos | Plan (names and dimensions) | **B** | Matches the founder's wording |
| Onboarding target | Under 5 min, with Rough-it-in flow | Under 10 min, 3 flows | A | Activation for non-LiDAR users |
| Photo-trace calibration | Two-point scale | Two-point scale | Agree | |
| Exterior auto-seed | v1.1 | v1 (footprint and satellite) | A | Data-engineering and licensing cost |
| Parcel data | v1.1 or later | Skip; trace on satellite | Neutral | |
| Doors/windows in v1 | Editable | Read-only | **B** | Scope |
| Converting to-do to done | Separate linked items | Status change on one record | **B** | Simpler history |
| Time/effort field | Missing | `effortHours` | **B** | Founder asked for it |
| Receipt OCR | v1 | v2 | A | Cheap, on-device, fights entry fatigue |
| RoomPlan object → entry suggestions | Name suggestions only | Suggests furniture/appliance entries | **B** | Strong first-run moment |
| "+" placement | Centroid | Pole of inaccessibility | **B** | Works for L-shaped rooms |
| Pan gesture | Two-finger | One-finger | **B** | |
| Wall model | Stored per room polygon | Derived from shared edges | A (or B plus a tolerance merge) | Doesn't break on RoomPlan's gaps |
| Backend in v1 | None | Stateless Worker (footprints, templates) | A | Nothing in v1 needs it |
| Household sharing | v1.2 | v1.1 | B, if on GRDB | A's SwiftData can't do it |
| Multi-property | Not planned | Pro in v1.1 | Neutral | |
| Furniture layer | v1.1 | v1 | A | Five-layer focus |
| Pricing | $4.99 / $39.99 | Same, plus ~$99 lifetime | B | A lifetime option helps early conversion |
| Paywalled features | Items over 50, reminders, report, sharing | Adds budget drill-down | A | Budget rollups are the core value |
| Timeline to v1 | About 22 weeks | About 17 weeks | A | B's scope is larger |
| Accessibility | Not specified | List-view mirror | **B** | |

## 4. Factual claims in B to check

Most of B's facts look right to me:
- RoomPlan requires iOS 16, and `StructureBuilder` multi-room merging arrived in iOS 17.
- `CKSyncEngine` is available from iOS 17.
- LiDAR is on Pro models from the iPhone 12 Pro onward.
- SwiftData with CloudKit disallows unique constraints and requires optional or defaulted properties.
- MLS access requires IDX/VOW/RESO licensing.
- Zillow's public API was retired.

Claims to double-check:
- **"The same renderer draws to a PDF context":** a SwiftUI `Canvas` doesn't draw directly into a PDF context. You'd need `ImageRenderer.render` or a shared Core Graphics drawing routine. It's doable, but not free.
- **Pre-tiled MS footprints and MapKit snapshots:** the licensing and storage concerns above aren't factually wrong in B, just unaddressed.
- **"Household sharing adds ~4–6 weeks":** plausible with `CKShare`. It doesn't hold for any SwiftData-based stack.

These fact checks come from my own knowledge. I didn't verify them against live sources this session.