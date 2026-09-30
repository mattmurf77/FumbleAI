# 08 · Inventory: Storage Spots, Housemates, Clothing and Pantry

**Priority:** P0 (pantry expiry digest P2) · **Phase:** 3 (Inventory)
**Sources:** merged plan §1 ("Pantry and clothing get dedicated screens"), §6, §10 answers 3–4; founder decisions ("Where did I store my winter clothes during the summer?"); HLD §4.7 (spare prompt), R9; LLD `storage_spot`, `person`, `inventory_item`, §11.

## Summary
Inventory covers consumables and belongings: **pantry food**, **clothing**, **stored items** (seasonal decor, spare filters and bulbs) and **other**. Every item lives in a room, optionally inside a nested **storage spot** (Attic › Shelf 2 › Bin "Winter – Matt"), and can belong to a **housemate** (a label, no account). Clothing has seasons and an in-rotation/stored state with a **seasonal swap** screen. Pantry has quantity, unit, expiry and a "running low" flag feeding a **shopping list**. The founder overrode both plans to give pantry and clothing dedicated screens.

## User stories
- As a **parent**, I want to record which bin holds each kid's winter clothes so that I find them in October.
- As an **owner**, I want to ask "where is the winter coat?" and get "Attic › Shelf 2 › Bin Winter – Matt".
- As a **household organizer**, I want a list of what to get out and put away when the season changes so that the swap takes an hour, not a weekend.
- As a **cook**, I want to mark pantry items as running low so that they land on a shopping list.
- As an **owner**, I want spare filters and bulbs due for replacement on the same shopping list.
- As a **household**, I want each person's things tagged to them so that we can filter by person.

## Functional requirements

### Housemates
- **FR-INV-01** A simple list of people in the home: name (required) and optional color. No accounts, no invitations, no login. Managed in Settings › Housemates (mockup 6.3) and inline from any person picker ("Add person…"). Real multi-device sharing is v1.2 (founder-confirmed).
- **FR-INV-02** Items, storage spots (e.g. "Matt's bin"), chores (assignee) and chore completions (done by) can be tagged to a person.
- **FR-INV-03** Deleting a person untags their items/chores (they become "No owner"/"Unassigned") after confirmation showing counts.

### Storage spots
- **FR-INV-10** Any room or zone can hold named storage spots, nested to any practical depth (limit 32): e.g. Attic › Shelf 2 › Bin "Winter – Matt"; Kitchen › Pantry › Top shelf.
- **FR-INV-11** A spot has a name (required), optional owner, optional pin on the plan, optional photo (e.g. of the bin label).
- **FR-INV-12** The **storage tree** screen (mockup 5.1) shows rooms → spots → sub-spots with item counts (including descendants). Spots can be added, renamed, reordered, moved to another parent or another room (moving a spot moves everything inside it), and deleted.
- **FR-INV-13** A spot can't be moved inside itself or its own descendants.
- **FR-INV-14** Deleting a spot asks "Move N items to <parent or room>?" and then deletes the spot and its sub-spots (Recently Deleted).
- **FR-INV-15** Pinned spots show as box icons with counts in the Inventory view.

### Items (all kinds)
- **FR-INV-20** Common fields: kind (pantry, clothing, stored, other), name (required), category (free text with suggestions), owner, location (room, optional spot; or floor/whole house), quantity (default 1, ≥ 0), unit (ea, pair, lb, oz, can, box, bag, bottle), notes, photo.
- **FR-INV-21** Created via "+" → Inventory item (location = that room), from a spot ("Add item here", location = that spot), from the storage tree, or from a thing's "Track spares" (spec 06).
- **FR-INV-22** "Add another" keeps kind, owner and location for fast entry of many items into one bin.
- **FR-INV-23** Moving items: multi-select in a spot → "Move to…" picks a new spot/room.

### Clothing
- **FR-INV-30** Clothing fields: owner, category (coat, boots, sweaters, shorts, swimwear, etc.), size (free text), **season** (Summer, Winter, All-year), **state** (In rotation / Stored), location.
- **FR-INV-31** **Seasonal swap** screen (mockup 5.2), reachable from the Inventory view strip and the Inventory menu:
  - The **upcoming season** is computed from today's date and the property's hemisphere (from latitude; northern if unknown). *Assumption pending founder confirmation (HLD §9-19); month boundaries are PRD open question Q-2 (default LLD: Mar–Aug → Summer, Sep–Feb → Winter).* The user can override the season with a toggle.
  - **Get out:** items of the upcoming season that are Stored.
  - **Put away:** items of the other season that are In rotation.
  - Both grouped by owner → room → spot path, with counts per spot ("Attic › Shelf 2 › Bin Winter – Matt · 7 items").
  - Filter by housemate.
- **FR-INV-32** **Swap** per item, per spot ("Get out all 7"), or **Swap all**, which flips the state in one step without changing the location. Then a prompt offers "Move put-away items to a spot…".
- **FR-INV-33** All-year items never appear in the swap lists.

### Pantry
- **FR-INV-40** Pantry fields: quantity, unit, location (e.g. Kitchen › Pantry › Top shelf), optional expiration date, **running low** flag, optional low threshold (auto-flag when quantity ≤ threshold).
- **FR-INV-41** Quick +/− steppers on quantity in lists; reaching the threshold sets "running low".
- **FR-INV-42** **Expiring soon:** items expiring in ≤ 7 days show an amber badge; expired items show red. The Inventory strip includes "N expiring".
- **FR-INV-43** **Pantry expiry digest** (P2, off by default): one daily 9 am notification when items expire within 3 days ("3 pantry items expire soon"). *Assumption pending founder confirmation (HLD §9-9).*

### Shopping list
- **FR-INV-50** The **Shopping list** screen (mockup 5.3) gathers: (a) every inventory item flagged running low, and (b) filters and bulbs due for replacement — things whose linked chore is due within 14 days and that have no spare stock left (spec 06, FR-THG-22). Filters/bulbs are listed first.
- **FR-INV-51** Checking an item off ("Bought") clears its low flag and asks for the new quantity (default: +1 unit, or back above threshold). For replacement-due things, "Bought" asks "Add N spares?" and creates/updates the linked spare item.
- **FR-INV-52** Share the list as plain text via the share sheet (e.g. to Notes or Messages). Grocery-delivery hand-off is later.

### Inventory view on the plan
- **FR-INV-60** Room chip = item count (including items in its spots), orange dot if anything is low; pinned spots show with counts; strip "N items · M low · K expiring" with links to Shopping list and Seasonal swap.
- **FR-INV-61** The room sheet shows the storage tree for that room, then loose items.

## Acceptance criteria
- **AC-INV-1** *Given* spots Attic › Shelf 2 › Bin "Winter – Matt" containing "Winter coat" (owner Matt, Winter, Stored), *when* the user searches "winter coat", *then* the top result card reads "Winter coat → Attic › Shelf 2 › Bin Winter – Matt" with owner Matt, and tapping it opens the Attic's floor with the spot highlighted.
- **AC-INV-2** *Given* today is Sep 29 in the northern hemisphere, *when* Seasonal swap opens, *then* the upcoming season is Winter, "Get out" lists stored Winter items, and "Put away" lists in-rotation Summer items, grouped by owner then spot.
- **AC-INV-3** *Given* 7 stored winter items in one bin, *when* the user taps "Get out all 7", *then* all 7 become In rotation and keep their location.
- **AC-INV-4** *Given* a filter for housemate "Kid 1", *then* only Kid 1's items appear in both lists.
- **AC-INV-5** *Given* a pantry item "Olive oil" with quantity 2 and threshold 1, *when* the user taps − once, *then* it's flagged running low and appears on the shopping list.
- **AC-INV-6** *Given* "Olive oil" is on the shopping list, *when* it's checked off as Bought with quantity 3, *then* the low flag clears and it leaves the list.
- **AC-INV-7** *Given* a spot is dragged into one of its own sub-spots, *then* the move is refused with "A spot can't go inside itself."
- **AC-INV-8** *Given* the Shelf 2 spot is moved from Attic to Basement, *then* every item inside its subtree shows Basement in its location and search.
- **AC-INV-9** *Given* a spot with 12 items is deleted, *then* the user is asked to move the 12 items to the parent, and after confirming, the items show the parent as their location.
- **AC-INV-10** *Given* an All-year item, *then* it never appears in either swap list.

## Edge cases
- An item in a room with no spot: location shows just the room.
- Same spot name in two rooms ("Top shelf"): locations always include the room; the floor is added when room names are also ambiguous.
- Quantity 0 on a pantry item: kept (and flagged low if a threshold exists); the user can delete it.
- Clothing with no season: treated like All-year for the swap.
- Southern-hemisphere address: seasons shift by six months.
- A housemate with the same name as another: allowed; colors distinguish them.
- Concurrent quantity edits on two devices: last writer wins (accepted at this scale, LLD §5.4).

## Empty and error states
| State | Behavior |
|---|---|
| No storage spots | Storage tree: "Add a shelf, closet or bin to start tracking where things are" |
| Seasonal swap with nothing to do | "Nothing to swap for Winter. Mark clothing as Stored or In rotation to use this." |
| Shopping list empty | "You're stocked up." |
| No housemates | Person pickers show "Add person…" only; lists aren't grouped by owner |

## Data touched (LLD)
`person`, `storage_spot` (parent_spot_id, owner_id, pin_x/pin_y), `inventory_item` (kind, category, owner_id, storage_spot_id, space_id/level_id denormalized, quantity, unit, season, in_rotation, expires_on, is_low, low_threshold, linked_thing_id), `thing`/`chore` (shopping list replacement-due), `attachment` (photo), `search_fts` (location path column), `notification_snooze`/reserved slot for the digest.

## UI references
Mockups **2.6** Inventory, **2.10** Upstairs · Inventory, **5.1** Storage spot tree and search, **5.2** Seasonal swap, **5.3** Pantry shopping list, **6.3** Settings (housemates as labels).

## Analytics / diagnostics
Counts-only export: items by kind, spots, max spot depth, clothing items with season set.

## Out of scope
Barcode scanning; photo-to-item with AI; grocery-delivery ordering (later partnership); nutrition or recipes; clothing sizes tracking over time; valuations for insurance; housemate accounts (v1.2); Spring/Fall seasons (PRD Q-7).

## Assumptions pending founder confirmation
HLD §9-9 (pantry expiry digest), §9-19 (upcoming season from date + hemisphere; see Q-2 on month boundaries), §9-20 (spare-stock prompt, via spec 04). PRD open questions Q-4 (swap for non-clothing stored items), Q-7 (seasons).
