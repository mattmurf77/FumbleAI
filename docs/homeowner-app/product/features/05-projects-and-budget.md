# 05 · Projects and Budget

**Priority:** P0 (receipt OCR P1) · **Phase:** 2 (Tracking core)
**Sources:** merged plan §1 (#2, #5), §2, §3; founder transcript (improvements, cost, budget per room/floor/property); HLD §4.8, ADR-03, ADR-11; LLD `project`, `cost_line_item`, `attachment`, §8, §15.

## Summary
An improvement or repair is **one project record** that moves **Idea → Planned → In Progress → Done**. *Future Projects* shows Idea/Planned/In Progress; *Past Work* shows Done. A project carries an **estimate** (cost and hours) and an **actual** (cost and hours), optional **line items** (material, labor, permit, other) with **receipts**, photos, a vendor and dates. **Budget is computed, never typed in**, and rolls up **room → floor → property**. The estimate is kept next to the actual, so the future Home History Report can show "planned $4k, spent $4.6k".

## User stories
- As a **new buyer**, I want to list projects I'm considering with rough costs so that I can prioritize.
- As an **owner doing a project**, I want to add costs as I go (materials, labor) with receipts so that I know what I actually spent.
- As an **owner**, I want to mark a project done with its final cost and date so that it becomes part of the house's history.
- As a **long-time owner**, I want to log past work from years ago so that my history is complete.
- As a **planner**, I want to see planned vs. spent per room, per floor and for the whole house so that I can budget.
- As an **owner doing DIY**, I want to track hours as well as money so that I know the time investment.

## Functional requirements

### Project record
- **FR-PRJ-01** Fields: title (required), place (room / floor / whole house), status, priority (1–3, optional), estimated cost, estimated hours, actual cost, actual hours, target date, started date, completed date, vendor, notes, photos, receipts, linked chore (if spawned).
- **FR-PRJ-02** Money is entered in the property currency (USD default, PRD Q-15), stored as whole cents; negative amounts are rejected.
- **FR-PRJ-03** Created via "+" → Future Project (status **Idea**, or Planned if an estimate is entered — user can change), "+" → Past Work (status **Done**, completed date defaults to today and is editable to any past date), or "Turn into project" from a chore.

### Status lifecycle
- **FR-PRJ-10** Status can move to any value (including backwards, e.g. Done → In Progress to fix a mistake).
- **FR-PRJ-11** Moving to **In Progress** sets the started date to today if empty.
- **FR-PRJ-12** Moving to **Done** opens the **Done sheet**, prefilled with: actual cost = sum of line items if any, else the estimate; completed date = today; hours = sum of line-item hours, else the estimated hours; option to scan a receipt. The user confirms or edits. A Done project must have a completed date.
- **FR-PRJ-13** Once Done, the project leaves Future Projects and appears in Past Work immediately; the estimate is kept.
- **FR-PRJ-14** Moving Done → another status clears nothing: completed date and actual cost stay visible (greyed) until changed.

### Line items and receipts
- **FR-PRJ-20** A line item has: label (required), amount (required, ≥ 0), kind (material / labor / permit / other), vendor, date, hours, receipt.
- **FR-PRJ-21** **Effective spent** for a project = the actual cost if the user typed one; otherwise the sum of line items. The UI shows which is used ("From 4 line items" vs. "Entered").
- **FR-PRJ-22** **Receipt scan:** the document camera captures pages saved as one PDF; on-device OCR extracts the text; a parser suggests **total**, **date** (≤ today, within 5 years) and **vendor**, each marked "From receipt – check". Nothing is saved without the user confirming. Available on the Done sheet, on line items, and on the project itself. *P1.*
- **FR-PRJ-23** Receipt OCR text is searchable (spec 09).
- **FR-PRJ-24** Photos (before/after) can be attached to a project; up to 3000 px long edge, HEIC.

### Budget (computed)
All definitions below are *Assumption pending founder confirmation (HLD §9-15)*.
- **FR-PRJ-30** **Planned** = sum of estimates of **Planned** and **In Progress** projects.
- **FR-PRJ-31** **Ideas** = sum of estimates of **Idea** projects, shown separately and **never added** to Planned (PRD Q-8).
- **FR-PRJ-32** **Spent** = sum of effective spent of **In Progress** and **Done** projects.
- **FR-PRJ-33** **Remaining** = for In Progress: max(estimate − spent, 0); plus Planned estimates.
- **FR-PRJ-34** **Variance** (Done projects with an estimate) = spent − estimate; shown as "+$612 over" / "$200 under".
- **FR-PRJ-35** **Hours** roll up with the same rules (estimated hours; actual hours or line-item hours).
- **FR-PRJ-36** **Roll-up:** Room = projects in that room; Floor = rooms on that floor + floor-scoped projects; Property = all floors (incl. Outside) + whole-house projects.
- **FR-PRJ-37** Budget is **never stored**; every number is recomputed from projects and line items on each change; rollups respond in ≤ 10 ms at 10k rows.
- **FR-PRJ-38** Things' purchase prices are **not** included in Budget (merged plan §2: Budget is calculated from Future Projects and Past Work). *PRD open question Q-3.*
- **FR-PRJ-39** **Budget drill-down screen** (from the Budget view's strip): per-floor rows and a Whole house row, then total; each row shows Planned, Ideas, Spent, Remaining, Variance and Hours; tapping a floor lists its rooms; tapping a room lists its projects.

### Views
- **FR-PRJ-40** **Future Projects** view: room chip = planned $ (with project count when ≥ 2; "N ideas" if only ideas); tint by planned $ (scale: PRD Q-1); strip "$X planned · N in progress".
- **FR-PRJ-41** **Past Work** view: room chip = lifetime spent + month last worked ("$12.1k · Mar ’26"); strip "$X spent on this floor since <earliest year>".
- **FR-PRJ-42** **Budget** view: room chip "planned / spent"; strip "Floor: $planned / $spent · Home: $planned / $spent".
- **FR-PRJ-43** Amounts in chips abbreviate ($980, $4.2k, $1.2M); detail screens show exact amounts.

## Acceptance criteria
- **AC-PRJ-1** *Given* a Kitchen project Planned with estimate $4,000, *then* Future Projects shows "$4k" on the Kitchen and Budget shows Planned $4,000, Spent $0.
- **AC-PRJ-2** *Given* that project In Progress with line items $180 + $240 + $600, *then* Spent shows $1,020 "From 3 line items" and Remaining $2,980.
- **AC-PRJ-3** *Given* the user marks it Done and enters actual $4,612 with date 2026-09-20 and 14 h, *then* it disappears from Future Projects, appears in Past Work with "$4.6k · Sep ’26", and Variance shows "+$612 over".
- **AC-PRJ-4** *Given* an Idea with estimate $10,000, *then* Budget's Planned excludes it and Ideas shows $10,000.
- **AC-PRJ-5** *Given* projects in two rooms on Ground, one floor-scoped project on Ground, and one whole-house project, *then* the Ground floor total equals the two rooms plus the floor project, and the Home total adds all floors plus the whole-house project.
- **AC-PRJ-6** *Given* a scanned receipt with "TOTAL $1,234.56" and a date of 09/12/2026, *then* the Done sheet shows $1,234.56 and Sep 12, 2026 marked "From receipt – check", and nothing is saved until the user taps Confirm.
- **AC-PRJ-7** *Given* "+" → Past Work in the Bathroom, *then* the form opens with status Done, a completed date field, actual cost and receipt fields shown.
- **AC-PRJ-8** *Given* a Done project is moved back to In Progress, *then* it reappears in Future Projects, and its spent still counts in Spent.
- **AC-PRJ-9** *Given* a negative amount is typed, *then* the field shows "Enter an amount of 0 or more" and Save is disabled.

## Edge cases
- Project with neither estimate nor actual: counts as $0; shown as "No estimate".
- Actual typed and line items also present: actual wins; a note shows "Line items total $X".
- Project moved to another room: rollups update for both rooms.
- The room of a project is deleted: follows the "items go where" choice (spec 01).
- Multi-year past work: Past Work strip uses the earliest completed year.
- Receipt with no recognizable total: fields stay empty; the PDF is still attached.
- Receipt PDF > 25 MB: rejected with "This file is too large (max 25 MB)".
- Currency other than USD: shown with the property's currency code; no conversion.

## Empty and error states
| State | Behavior |
|---|---|
| No projects | Future Projects/Past Work/Budget strips show "No projects yet — tap + in a room"; Budget drill-down shows zeros with guidance |
| Camera denied for receipt | "Camera access is off" + Open Settings; user can pick an image file instead |
| OCR fails | "Couldn't read this receipt. You can still attach it and type the amount." |

## Data touched (LLD)
`project` (status, est_cost_cents, actual_cost_cents, est_hours, actual_hours, target_on, started_on, completed_on, vendor, spawned_from_chore_id), `cost_line_item` (kind, amount_cents, hours, receipt_attachment_id), `attachment` (kind `receipt`/`photo`, `ocr_text`), `search_fts`.

## UI references
Mockups **2.3** Future Projects, **2.4** Past Work, **2.7** Budget, **2.9** Exterior · Future Projects, **4.2** Project detail (Idea → Planned → In Progress → Done, estimate vs. actual, line items, scanned receipt).

## Analytics / diagnostics
No event tracking. Counts-only export: projects by status, Done projects with actual cost, Done projects with a receipt or photo (PRD §5.2 "Past work logged"). Signposts: rollup query ≤ 10 ms.

## Out of scope
Contractor quotes / sending a project out for bids (future partnership); tax categorization; loans/financing; multi-currency conversion; Home History Report output; AI remodel planning; payments.

## Assumptions pending founder confirmation
HLD §9-15 (budget definitions). PRD open questions Q-1 (tint scale), Q-3 (appliance purchase prices), Q-8 (Ideas), Q-15 (currency), Q-16 (spawning chore closure).
