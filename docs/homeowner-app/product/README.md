# Homeowner App: Product Docs

Planning only; nothing is being built. These docs turn the merged plan and the HLD/LLD into product requirements for the v1 TestFlight beta (2–5 testers, no paywall, no dates).

**Precedence when documents disagree (most recent wins):** `../07-merged-plan.md` → `../06-founder-decisions.md` → `../design/hld.md` → `../design/lld.md` → `../00-founder-transcript.md`. HLD §9 "Deviations / assumptions" are treated as **assumptions pending founder confirmation**, not decisions, and are marked that way in every spec.

## Index

| Doc | What it covers | Priority | Phase |
|---|---|---|---|
| [prd.md](prd.md) | Problem, vision, users, personas, v1 scope, success metrics, journeys, feature priority map, dependencies, risks, TestFlight release plan, roadmap, **open questions and assumptions (§15)** | – | – |
| [features/01-floor-plan-creation.md](features/01-floor-plan-creation.md) | Scan, Build with blocks, Trace a photo, Rough it in, plan editor, rename | P0 | 1 |
| [features/02-canvas-and-views.md](features/02-canvas-and-views.md) | Floor pills, ground default + setting, 7-view dropdown, "+" picker, room sheet, summary strip, accessibility | P0 | 1–3 |
| [features/03-exterior-and-yard.md](features/03-exterior-and-yard.md) | Address → OSM footprint → satellite → yard zones; zone editing | P0 | 1 |
| [features/04-chores-reminders-calendar.md](features/04-chores-reminders-calendar.md) | Chores, repeat rules, completion, push reminders, Apple/Google calendar via EventKit | P0 | 2 |
| [features/05-projects-and-budget.md](features/05-projects-and-budget.md) | Idea → Planned → In Progress → Done, costs, hours, line items, receipt OCR, budget rollups | P0 | 2 |
| [features/06-appliances-electronics-furniture.md](features/06-appliances-electronics-furniture.md) | Things, templates (bulbs, filters, appliances, detectors), warranties, spare stock link | P0 | 2–3 |
| [features/07-measurements-and-fit-check.md](features/07-measurements-and-fit-check.md) | Measurements on rooms/spots/doors/zones, fit check, delivery path | P0 | 1–2 |
| [features/08-inventory-pantry-clothing.md](features/08-inventory-pantry-clothing.md) | Storage spots, housemates, clothing + seasonal swap, pantry + shopping list | P0 | 3 |
| [features/09-search-export-settings.md](features/09-search-export-settings.md) | Search ("where is…"), CSV export, Settings, Diagnostics, Recently Deleted | P0/P1 | 1–4 |
| [features/10-sync-and-data.md](features/10-sync-and-data.md) | iCloud sync, offline, conflicts, restore, account change, housemates as labels | P0 | 1, 4 |

## Spec conventions
- Requirement IDs: `FR-<AREA>-nn`; acceptance criteria `AC-<AREA>-n` in Given/When/Then. Areas: PLN, CNV, EXT, CHR, PRJ, THG, MSR, INV, SES, SYN.
- **Priority:** P0 = needed for the first useful TestFlight build; P1 = in v1, may land in a later beta build; P2 = first to cut.
- **Phase** = merged plan §9 roadmap: 0 Design · 1 Plan core · 2 Tracking core · 3 Inventory · 4 TestFlight.
- **Data touched** uses LLD table names (`chore`, `project`, `thing`, `inventory_item`, …).
- **UI references** use mockup frame numbers from `../mockups/index.html` (2.x views, 3.x menus and sheets, 4.x details, 5.x inventory, 6.x setup/editor/settings).
- Assumption tags: "Assumption pending founder confirmation (HLD §9-N)" for the HLD's list; "PRD assumption" or "Q-N" for questions raised here.

## Known gaps for Phase 0 design
Screens not yet in the mockups: restore / account-switch / sync status (spec 10), Recently Deleted and Diagnostics (spec 09), Budget drill-down (spec 05), review screen after a scan (spec 01), Done sheet with receipt pre-fill (spec 05).
