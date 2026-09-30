# 09 · Search, CSV Export, Settings and Recently Deleted

**Priority:** Search, CSV export, Settings, Diagnostics P0 · Recently Deleted P1 · **Phase:** Settings 1; Search, Export, Recently Deleted 2; Diagnostics 4
**Sources:** merged plan §1 (#11, CSV export), §6 (search), §9; HLD §3.3, §5.6, ADR-14, ADR-15; LLD §12, §13, `search_fts`, `app_meta`.

## Summary
- **Search** covers every record kind and answers "where is…" questions directly with the item's location path.
- **CSV export** gives users all their data as a zip of CSV files.
- **Settings** holds the default floor, units, housemates, reminder and calendar defaults, device nickname, list view, iCloud status, export, Recently Deleted and Diagnostics.
- **Recently Deleted** keeps deleted things recoverable for 30 days.

## User stories
- As an **owner**, I want to type "winter coat" and see where it is so that I don't open every bin.
- As an **owner**, I want to type "16x25" and find the furnace so that I know the filter.
- As a **cautious user**, I want to export all my data to spreadsheets so that I'm never locked in.
- As a **user who opens on a different floor**, I want to choose my default floor.
- As a **user who deleted a room by mistake**, I want to restore it with its items.
- As a **beta tester**, I want to send the founder a diagnostics file without my personal content so that bugs get fixed.

## Functional requirements

### Search
- **FR-SES-01** A search field is available from the main screen toolbar (magnifier) and pulls down from lists.
- **FR-SES-02** It searches chores, projects (incl. line-item labels, vendor and receipt OCR text), things (brand, model, serial, template values), inventory items, measurements, rooms and storage spots, and matches titles, notes, locations and people.
- **FR-SES-03** Matching is prefix-based per word, all words required (e.g. "wint coa" finds "Winter coat"); if nothing matches, any word is allowed. Case and accents are ignored.
- **FR-SES-04** Results update as the user types (120 ms debounce, ≤ 50 ms query at 10k records), grouped by kind, max 50 results.
- **FR-SES-05** **"Where is" answer card:** if the top result is an inventory item or storage spot with a location, show a card at the top: "**Winter coat** → Attic › Shelf 2 › Bin Winter – Matt (Matt)".
- **FR-SES-06** Tapping a result opens it; tapping the card's location switches to that floor, selects the room and flashes the spot pin.
- **FR-SES-07** Renaming a room, spot or person updates every affected result immediately (same save).
- **FR-SES-08** Deleted items are not returned (they're in Recently Deleted).

### CSV export
- **FR-SES-20** Settings › Export data creates `Home-Export-YYYY-MM-DD.zip` and opens the share sheet.
- **FR-SES-21** The zip holds one CSV per record kind: spaces, chores, chore_completions, projects, cost_line_items, things, inventory, measurements, storage_spots, people, budget_summary, plus a README.txt explaining files and units. *Assumption pending founder confirmation (HLD §9-24).*
- **FR-SES-22** Format: RFC 4180, UTF-8 with BOM (opens correctly in Excel and Numbers), header row, ISO dates, money as decimals with a currency column, lengths in inches with 2 decimals plus a display column in the user's units, human-readable room/floor/spot-path columns, IDs included.
- **FR-SES-23** Optional toggle **"Include photos and receipts"** (off by default, PRD Q-11) adds an `attachments/` folder.
- **FR-SES-24** Deleted items are excluded.
- **FR-SES-25** Export works offline and completes in ≤ 5 s for 10k records without attachments, with a progress indicator.

### Settings
- **FR-SES-40** Sections and items (mockup 6.3):
  - **Home:** name, address (edit → offers "Redo outside from address"), **Default floor** (picker of floors; default Ground — the value syncs across devices; *assumption pending founder confirmation, HLD §9-14*), Units (Imperial / Metric; *assumption, HLD §9-2*), Currency (display).
  - **Housemates:** add, rename, color, reorder, delete (spec 08).
  - **Reminders:** default time for all-day chores (9:00), default offset, app badge on/off, pantry expiry digest (off; spec 08).
  - **Calendar:** default calendar, "Manage calendar events on this iPhone" hand-off, this device's nickname (used in "managed on '<nickname>'").
  - **Accessibility:** "Show plan as list" (auto-on with VoiceOver).
  - **iCloud:** sync status ("Up to date", "Waiting for network", "N changes pending", "iCloud off – not syncing"), last sync time.
  - **Data:** Export data, Recently Deleted.
  - **About & Diagnostics:** version/build, Diagnostics, acknowledgments (OSM attribution, GRDB, Clipper2).
- **FR-SES-41** **Diagnostics** screen: iCloud account status, last successful sync, outbox count, parked records, last sync error; pending notifications (x/64); notification and calendar authorization; calendar owner device; database size and schema version; **Export diagnostics** (a zip with a 24-hour log slice, MetricKit payloads and a **counts-only** JSON — no titles, names, notes or photos). Opt-in by the tester. *No analytics SDK — assumption pending founder confirmation (HLD §9-25).*
- **FR-SES-42** The counts-only JSON includes the per-tester signals of PRD §5.2: counts of levels, spaces by source, items by kind, chores with reminder/calendar on, completions per ISO week (last 8 weeks), Done projects with actual cost and with receipts, first-plan creation timestamp (date only). *PRD open question Q-10.*
- **FR-SES-43** Diagnostics offers "Rebuild search index" and "Re-run reminder scheduling".

### Recently Deleted
- **FR-SES-60** Deleting any record (room, floor, spot, chore, project, thing, item, measurement, person) moves it to **Recently Deleted** for **30 days**, then it's permanently removed on every device. *Assumption pending founder confirmation (HLD §9-21).*
- **FR-SES-61** Deleting a room or floor asks where its items go (another room on the floor, or "This floor"/"Whole house"). Deleting a spot asks where its items go (spec 08).
- **FR-SES-62** A 5-second **Undo** snackbar follows every delete.
- **FR-SES-63** Recently Deleted lists items newest first with kind, name, original location and days left; actions: **Restore** and **Delete now** (with confirmation). "Delete all now" requires confirmation.
- **FR-SES-64** Restoring a room restores its geometry; items that were moved elsewhere at deletion stay where they were moved (the user moves them back manually). Restoring an item whose room is still deleted puts it at "This floor" of its original floor (or Whole house if the floor is also deleted).
- **FR-SES-65** Deletes sync: an item deleted on one device disappears from the others and appears in their Recently Deleted.

## Acceptance criteria
- **AC-SES-1** *Given* "Winter coat" stored in Attic › Shelf 2 › Bin Winter – Matt, *when* the user types "winter co", *then* within 200 ms the answer card shows the path with owner Matt.
- **AC-SES-2** *Given* a furnace with filter 16x25x1, *when* the user searches "16x25", *then* the furnace is in the Appliances group with its room.
- **AC-SES-3** *Given* a receipt whose OCR text contains "Sherwin", *when* the user searches "sherwin", *then* the project with that receipt is returned.
- **AC-SES-4** *Given* the user renames "Attic" to "Loft", *then* searching "winter coat" shows "Loft › Shelf 2 › …".
- **AC-SES-5** *Given* data in every kind, *when* the user exports, *then* the zip opens in Files and contains the 11 CSVs and README.txt, and `projects.csv` opens in Excel with correct accents and a `spent_effective` column.
- **AC-SES-6** *Given* the user sets Default floor to 2nd Floor, *when* the app is cold-launched, *then* it opens on 2nd Floor.
- **AC-SES-7** *Given* a chore is deleted, *when* the user opens Recently Deleted and taps Restore, *then* the chore returns with its schedule and history.
- **AC-SES-8** *Given* an item deleted 31 days ago, *then* it's no longer in Recently Deleted on any device.
- **AC-SES-9** *Given* the user taps Export diagnostics, *then* the zip contains no record titles, names, notes, addresses or photos (verified by a test that seeds known strings and asserts they're absent).
- **AC-SES-10** *Given* airplane mode, *when* the user exports CSV, *then* the export succeeds.

## Edge cases
- Search with only punctuation or FTS syntax characters: treated as empty.
- A search result whose room was deleted: not returned (the item moved per the delete prompt, or it's itself deleted).
- Export with attachments over ~1 GB: warn with the size before creating.
- Default floor deleted: falls back to the lowest non-basement floor; Settings shows the new value.
- Metric switch: all displays change; stored values don't.
- Restoring a storage spot whose parent is deleted: it's restored at the room's top level.

## Empty and error states
| State | Behavior |
|---|---|
| No search results | "No matches for '<query>'" + suggestion to check spelling |
| Empty Recently Deleted | "Nothing deleted in the last 30 days" |
| Export fails (disk full) | "Couldn't create the export. Free some space and try again." |
| iCloud off | Settings shows "iCloud off – not syncing" with a link to iOS Settings |

## Data touched (LLD)
`search_fts` (title, body, location, people), `property.default_level_id`, `property.unit_system`, `property.currency_code`, `person`, `app_meta` (device_id, device_nickname, fts_version), `deleted_at` on every synced table, `sync_state`, `sync_outbox`, `sync_orphan` (Diagnostics), all domain tables for export.

## UI references
Mockups **5.1** Storage spot tree and search ("winter coat" resolves to Upstairs › Attic › Shelf 2 › Bin "Winter – Matt"), **6.3** Settings (default floor Ground, housemates, reminder defaults, list view, iCloud, CSV export).

## Analytics / diagnostics
This spec defines the Diagnostics screen and export (FR-SES-41..43). Signposts: search keystroke → results ≤ 50 ms.

## Out of scope
CSV import (IDs are included to allow it later); PDF/Home History Report; natural-language questions; search across multiple properties; cloud backup other than iCloud; analytics SDK.

## Assumptions pending founder confirmation
HLD §9-2 (units), §9-14 (default floor stored once), §9-21 (Recently Deleted 30 days; room-delete prompt), §9-24 (zip of CSVs), §9-25 (no analytics SDK; opt-in diagnostics). PRD open questions Q-10, Q-11.
