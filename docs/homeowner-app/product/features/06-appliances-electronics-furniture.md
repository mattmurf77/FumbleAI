# 06 · Appliances, Electronics and Furniture

**Priority:** P0 (spare-stock link and planned purchases P1) · **Phase:** 2 (Tracking core); spare-stock link Phase 3
**Sources:** merged plan §2, §3, §6, §7 (`Thing`), §10 answer 4; founder transcript ("what type of lights are in which room, what type of air filters"); HLD §4.9; LLD `thing`, §7.4, §11.5.

## Summary
**Things** are durable items placed in the house: appliances (fridge, range, washer), electronics (TV, router), furniture (sofa, bed), fixtures (light fixtures and their bulbs, smoke detectors, faucets) and systems (HVAC furnace, water heater, sump pump). Each thing sits in a room (optionally pinned to a spot on the plan) and carries brand, model, serial, purchase and warranty dates, dimensions, and **template fields** (bulb base, filter size and MERV). **Spare stock** (extra filters, bulbs) is an **Inventory item linked to the thing** (founder-confirmed).

## User stories
- As a **new buyer**, I want to record the furnace filter size (16x25x1 MERV 11) so that I buy the right one.
- As an **owner**, I want to know what bulb each light fixture takes so that I don't take a fixture down to go to the store.
- As an **owner**, I want to see which appliances are under warranty so that I call the manufacturer instead of paying.
- As an **owner**, I want appliance icons on the plan where they sit so that the plan looks like my house.
- As a **shopper**, I want to track 3 spare filters linked to the furnace so that I know when to buy more.

## Functional requirements

### Record
- **FR-THG-01** Fields: name (required), category (appliance, electronic, furniture, fixture, system), template (optional), place (room / floor / whole house), pin on the plan (optional), brand, model, serial, purchase date, purchase price, warranty end, width/depth/height, "goes into" measurement (spec 07), ownership (Owned / Planned purchase), notes, photos, manual (PDF).
- **FR-THG-02** Created from "+" → Appliance/Electronic/Furniture (defaults to the room), from accepting a scan suggestion (spec 01), or from a chore's "link appliance" picker.
- **FR-THG-03** **Ownership:** *Owned* (default) or *Planned purchase*. Planned things draw dashed on the plan and are excluded from counts and the "items" strip. Switching to Owned makes them solid. *Assumption pending founder confirmation (HLD §9-10).*

### Templates
- **FR-THG-10** Choosing a template sets category, a default name, an icon, fit-check defaults (spec 07) and extra fields. v1 templates and their fields:

| Template | Category | Template fields |
|---|---|---|
| Light fixture | fixture | bulb base (E26, E12, GU10, GU24, BR30, PAR38, T8, other), bulb count, wattage/equivalent, color temperature (2700K/3000K/4000K/5000K), dimmable (y/n), smart (y/n) |
| HVAC furnace / air handler | system | filter size (W×H×D, e.g. 16x25x1), MERV (1–16), filter location note, fuel (gas/electric/oil/heat pump) |
| HVAC filter (return grille) | fixture | filter size, MERV |
| Water heater | system | type (tank/tankless), fuel, capacity (gal) |
| Water filter / fridge water filter | fixture | filter model |
| Smoke / CO detector | fixture | type (smoke, CO, combo), battery type (9V, AA, sealed 10-yr), hardwired (y/n), install date |
| Refrigerator | appliance | style (French door, side-by-side, top/bottom freezer), water line (y/n) |
| Range / wall oven / cooktop | appliance | fuel (gas/electric/induction) |
| Dishwasher, washer, dryer | appliance | dryer vent type / fuel |
| TV | electronic | screen size (in), mount (wall/stand) |
| Router, thermostat | electronic | – |
| Sofa, bed, table, dresser, chair, desk, shelf | furniture | – |
| Sump pump, dehumidifier, garage door opener, fireplace | system | – |
| Custom | any | none |

- **FR-THG-11** Template fields are optional and editable; unknown values can be left blank.
- **FR-THG-12** Template field values are searchable ("16x25x1", "E26") (spec 09).
- **FR-THG-13** A thing can offer **"Add maintenance chore"** with a suggested rule: filter every 90 days after completion; detector battery every 12 months; water filter every 6 months. The chore is linked to the thing (spec 04).

### Spare stock
- **FR-THG-20** From a thing, **"Track spares"** creates an Inventory item (kind *stored* for filters/bulbs) linked to the thing, with name defaulted from the template field ("Furnace filter 16x25x1 MERV 11"), quantity, unit (ea), low threshold (default 1), and storage location. Founder-confirmed.
- **FR-THG-21** The thing detail shows the spare count ("3 spares in Basement › Utility shelf").
- **FR-THG-22** The shopping list (spec 08) includes a thing when a linked chore is due within 14 days and it has no spare stock left.
- **FR-THG-23** Completing a linked chore offers to decrement a spare (spec 04, FR-CHR-31). *Assumption pending founder confirmation (HLD §9-20).*

### Plan and view
- **FR-THG-30** In the *Appliances, Electronics & Furniture* view, each pinned thing shows its icon at its pin; unpinned things show in a row under the room label; the room chip shows the count of owned things.
- **FR-THG-31** Dragging an icon in that view moves its pin (within the room; dropping in another room asks "Move to <room>?").
- **FR-THG-32** Strip: "N items · M warranties end in 60 days".
- **FR-THG-33** The thing detail shows a warranty badge: "Under warranty until Mar 2027", "Ends in 45 days" (amber), "Expired".

## Acceptance criteria
- **AC-THG-1** *Given* "+" in Utility → Appliance → template HVAC furnace, *then* the form shows filter size, MERV, location note and fuel fields, and the thing's icon appears in Utility in the Appliances view after saving.
- **AC-THG-2** *Given* a furnace with filter 16x25x1 MERV 11, *when* the user searches "16x25", *then* the furnace appears in results with its location.
- **AC-THG-3** *Given* a light fixture with bulb base E26, 2700K, *then* the thing detail shows "E26 · 2700K" under the name.
- **AC-THG-4** *Given* "Track spares" on the furnace with quantity 3 in Basement › Utility shelf, *then* an Inventory item exists linked to the furnace and the thing detail shows "3 spares".
- **AC-THG-5** *Given* a linked "Change filter" chore due in 10 days and spares quantity 0, *then* the shopping list includes "Furnace – 16x25x1".
- **AC-THG-6** *Given* a planned-purchase fridge, *then* it draws dashed, isn't in the room count, and switching to Owned makes it solid and counted.
- **AC-THG-7** *Given* two things with warranties ending in 30 and 90 days, *then* the strip says "2 items · 1 warranty ends in 60 days" (counting all items on the floor).
- **AC-THG-8** *Given* "Add maintenance chore" on a smoke detector, *then* a chore "Replace detector battery" every 12 months is prefilled, linked to the detector.

## Edge cases
- A thing without a room (whole-house system like a water main): shows in the Whole house chip.
- Many pins clustering: count bubble (spec 02).
- Deleting a thing with spares: asks "Also delete 3 spares?" (default: keep spares, unlink).
- Deleting a thing with linked chores: chores stay; link cleared.
- Washer/dryer combo from a scan: one suggestion; the user can duplicate into two things.
- Dimensions entered in metric: stored in inches, displayed per Settings.

## Empty and error states
| State | Behavior |
|---|---|
| No things on a floor | Strip: "No appliances yet — tap + to add one"; suggestion to use templates |
| Manual PDF too large (> 25 MB) | Rejected with the size limit |

## Data touched (LLD)
`thing` (category, template_key, attributes_json, ownership, dims, fit_measurement_id, pin_x/pin_y, warranty_end, purchase_*), `inventory_item.linked_thing_id`, `chore.linked_thing_id`, `attachment` (photo, manual), `search_fts`.

## UI references
Mockups **2.5** Appliances, Electronics & Furniture, **2.11** Basement · Appliances, **4.3** Appliance detail with fit check, **5.3** Pantry shopping list (filters and bulbs due).

## Analytics / diagnostics
Counts-only export: things by category and template; things with template fields filled.

## Out of scope
Barcode / model-number lookup; manual download from manufacturers; recall alerts; smart-home integration; retailer "fits your opening" shopping (future partnership); AI photo-to-item.

## Assumptions pending founder confirmation
HLD §9-10 (Owned / Planned purchase), §9-20 (spare-stock prompt). The template list and fields in FR-THG-10 are a **PRD assumption** for founder review.
