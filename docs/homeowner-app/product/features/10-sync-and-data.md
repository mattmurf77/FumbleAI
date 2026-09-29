# 10 · Sync and Data

**Priority:** P0 · **Phase:** 1 (basic save/fetch, *assumption HLD §9-1*) → 4 (hardening, account change, restore, Diagnostics)
**Sources:** merged plan §1 (#4, #9), §7, §8; HLD §2, §3.5, §5.2–5.3, ADR-01, ADR-02, ADR-06, ADR-12, ADR-14, R2; LLD §3.3, §5.

## Summary
All data is stored **on the phone** (SQLite) and **synced through the user's own private iCloud**. There is no sign-in, no account and no server. The app works fully offline. Each person's data lives in their own iCloud; **housemates are labels** in v1, and real sharing across Apple IDs arrives in v1.2. The design already keeps one iCloud zone per property so v1.2 sharing needs no data migration.

## User stories
- As an **owner with an iPhone and a second iPhone/work phone**, I want my home on both so that I can use either.
- As a **user who gets a new phone**, I want my home restored automatically so that I don't start over.
- As a **user in a basement with no signal**, I want everything to work offline and sync later.
- As a **privacy-minded owner**, I want my data kept in my own iCloud, encrypted, with no company server.
- As a **user who signs into a different Apple ID**, I want the app to protect my data instead of mixing two homes.
- As a **household**, I understand housemates are names only for now, so that I'm not surprised that my partner's phone doesn't see my data until sharing ships.

## Functional requirements

### Storage and offline
- **FR-SYN-01** Every feature works in airplane mode. Only exterior seeding, satellite images and sync need a network.
- **FR-SYN-02** Every change is saved locally first, together with a durable "to send" record, in one step; if the app is killed, unsent changes are sent on next launch.
- **FR-SYN-03** Photos, receipts and manuals sync as files (photos ≤ 3000 px long edge, HEIC; PDFs ≤ 25 MB). Thumbnails are made locally. A file not yet downloaded shows a placeholder with a download indicator.
- **FR-SYN-04** The satellite image is **not** synced; each device downloads its own. *Assumption pending founder confirmation (HLD §9-18).*
- **FR-SYN-05** Pending notifications and the device's calendar identifiers are per device; they are re-derived on each device from synced data.

### Sync behavior
- **FR-SYN-10** Sync uses the user's private iCloud database, one zone per property; no sign-in screen. Basic save/fetch ships in Phase 1 alongside the schema; conflict handling, orphans and account changes are hardened in Phase 4. *Assumption pending founder confirmation (HLD §9-1).*
- **FR-SYN-11** Changes on one device appear on another within 1 minute when both are online and foregrounded (best effort; iCloud controls timing).
- **FR-SYN-12** **Conflicts merge field by field:** a rename on one phone and a resize on the other both survive. Only a true same-field race resolves to the later sender.
- **FR-SYN-13** Special rules (LLD §5.4): **deletes win** unless the other side explicitly restored afterwards; a chore's next due date is **recomputed** from its rule and latest completion after a merge; completions are append-only (two completions of the same occurrence are both kept); room shapes are replaced whole (no vertex merging); a project's status and completed date move together; an item's location fields move together.
- **FR-SYN-14** Records that arrive before their parent (e.g. a chore before its room) are parked and applied once the parent arrives; nothing is dropped.
- **FR-SYN-15** Record contents are stored in iCloud **encrypted fields** by default (end-to-end with Advanced Data Protection on). *Assumption pending founder confirmation (HLD §9-27).*
- **FR-SYN-16** Settings shows sync status: "Up to date", "Waiting for network", "N changes pending", "iCloud off – not syncing", or "iCloud storage full" (with a banner).

### First launch and restore
- **FR-SYN-20** On first launch on a device, before onboarding, the app checks iCloud for an existing home (≤ 8 s). If found, it shows "Restoring your home…" with progress and opens the canvas when the plan geometry has arrived (items may continue loading). This prevents a second device from creating a duplicate home.
- **FR-SYN-21** If the check times out (no network), onboarding shows a notice "Couldn't check iCloud. If you already use Home on another device, connect to the internet first." with **Try again** and **Start new home**.
- **FR-SYN-22** If the user isn't signed into iCloud, the app works locally and shows "Sign in to iCloud to back up and sync your home" once, then in Settings.

### Account changes
- **FR-SYN-30** **Signed out of iCloud:** sync pauses; local data stays; changes queue; Settings shows "iCloud off".
- **FR-SYN-31** **Signed back in (same account):** everything queued is sent.
- **FR-SYN-32** **Switched to a different Apple ID:** a blocking sheet: "This iPhone is now signed into a different iCloud account. Your home data belongs to the previous account." Options: **Export CSV** (spec 09) and **Erase and use the new account**. The app never merges two Apple IDs' data. *Assumption pending founder confirmation (HLD §9-22).*
- **FR-SYN-33** If the user deletes the app's iCloud data from iOS Settings, the app asks before re-uploading its local copy ("Your iCloud data for Home was deleted. Upload this iPhone's copy again?").

### Housemates as labels
- **FR-SYN-40** Housemates (spec 08) are records inside the owner's data, with no link to any Apple ID. Two phones on **different** Apple IDs do not share data in v1; the Settings › Housemates screen states "Sharing with other people's iPhones is coming later."
- **FR-SYN-41** Workaround for couples before v1.2 (documented in TestFlight notes, not a feature): chores added to a shared calendar reach the partner's calendar through the calendar provider.

### Data integrity
- **FR-SYN-50** Every database change and its sync/search bookkeeping happen in one transaction; a failure leaves no partial write.
- **FR-SYN-51** Schema migrations are append-only and tested from every previous version; newer-version values unknown to an older build are preserved, not dropped.
- **FR-SYN-52** Soft-deleted records are purged 30 days after deletion on all devices (spec 09).

## Acceptance criteria
- **AC-SYN-1** *Given* two iPhones on the same Apple ID, *when* a chore is added on A, *then* it appears on B within 1 minute with both online.
- **AC-SYN-2** *Given* A renames the Kitchen and B resizes it while both are offline, *when* both come online, *then* both devices show the new name and the new size.
- **AC-SYN-3** *Given* A deletes a project and B edits it offline, *when* both sync, *then* the project is deleted on both (delete wins) and is in Recently Deleted.
- **AC-SYN-4** *Given* A and B both complete the same daily chore occurrence offline, *when* both sync, *then* two completions are in history and the next due date is the same on both.
- **AC-SYN-5** *Given* the app is killed right after an edit in airplane mode, *when* it's relaunched online, *then* the edit is sent and Settings reads "Up to date".
- **AC-SYN-6** *Given* a new iPhone signed into the same Apple ID, *when* the app first launches online, *then* "Restoring your home…" appears instead of onboarding, and no second home is created.
- **AC-SYN-7** *Given* the device switches Apple ID, *then* the blocking sheet with Export CSV and Erase appears, and choosing Erase removes local data and runs the restore check for the new account.
- **AC-SYN-8** *Given* a chore record arrives before its room, *then* after the room arrives the chore appears in that room; Diagnostics shows 0 parked records afterwards.
- **AC-SYN-9** *Given* iCloud storage is full, *then* Settings shows "iCloud storage full" with a banner and local use continues.
- **AC-SYN-10** *Given* two devices, *then* each shows its own satellite image for Outside, and no image file is uploaded to iCloud.

## Edge cases
- Very long offline periods (weeks): the queue survives; sync resumes; merges follow FR-SYN-12/13.
- Clock skew between devices: merge rules don't rely on device clocks except "later sender wins" for same-field races.
- Large first sync (thousands of records + photos): geometry first, then items, then files; the canvas is usable once geometry arrives.
- App deleted and reinstalled: restore from iCloud (FR-SYN-20); the calendar owner device ID survives reinstall (Keychain).
- A user with two properties: not exposed in v1 UI (PRD Q-13), but each property is its own zone.

## Empty and error states
| State | Behavior |
|---|---|
| No iCloud account | Local-only; one-time notice; Settings status "iCloud off" |
| Restore check timed out | Notice with Try again / Start new home (FR-SYN-21) |
| Persistent sync error | Settings shows the last error in plain words and "Your data is safe on this iPhone"; Diagnostics has details |
| File download failed | Placeholder with "Tap to retry" |

## Data touched (LLD)
All synced tables (`property`, `level`, `space`, `opening`, `person`, `storage_spot`, `measurement`, `thing`, `chore`, `chore_completion`, `chore_calendar_link`, `project`, `cost_line_item`, `inventory_item`, `attachment`); local-only `sync_state`, `sync_record_meta`, `sync_outbox`, `sync_orphan`, `attachment_local`, `calendar_event_cache`, `map_snapshot_cache`, `notification_snooze`, `app_meta`.

## UI references
Mockup **6.3** Settings (iCloud section). Restore, account-switch and sync-status screens are not in the mockups yet (gap to add in Phase 0 design).

## Analytics / diagnostics
Diagnostics (spec 09) shows account status, last sync, outbox count, parked records, last error. Logs category `sync` with user content marked private. The manual TestFlight checklist includes a two-device sync test and airplane-mode edits (HLD §5.7).

## Out of scope
Household sharing across Apple IDs (v1.2, via iCloud sharing of the property zone); a server or third-party sync; Android/web access; importing another user's home; merging two Apple IDs' data.

## Assumptions pending founder confirmation
HLD §9-1 (sync in Phase 1), §9-18 (satellite not synced), §9-22 (account switch never merges), §9-27 (encrypted fields).
