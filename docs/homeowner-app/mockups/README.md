# Homeowner App: Mockups

These are the Phase 0 design mockups for `07-merged-plan.md`. Figma wasn't available, so they are HTML: one self-contained file with iPhone frames at 393×852 pt.

- **`index.html`**: open it in any browser. The only external request is Google Fonts, and it falls back to system fonts without it. It has light and dark themes (Auto, Light and Dark buttons at the top) and works at phone width.
- **`seven-views.md`**: the spec for each view, covering encoding rules, thresholds, sheets, empty states, "+" defaults, summary strips and the interaction model.

## Screens

| # | Screen | Notes |
|---|---|---|
| 1 | **Interactive canvas** | Clickable: floor pills, view dropdown (7 views), tap a room for its sheet, "+" for the add picker, pencil for edit mode, and tap the house on Exterior to go to Ground |
| 2.1–2.7 | Ground floor in each view | Plan, To-Dos, Future Projects, Past Work, Appliances/Electronics/Furniture, Inventory, Budget |
| 2.8–2.9 | Exterior: Plan, Future Projects | Muted satellite image, house footprint, 8 zones |
| 2.10–2.11 | Upstairs · Inventory, Basement · Appliances | Upstairs and Basement levels |
| 3.1 | View dropdown open | |
| 3.2 | "+" add picker | Kitchen, To-Dos view, so To-Do is the default |
| 3.3 | Room sheet, half height | Kitchen in To-Dos: Overdue / Today / This week / Later |
| 4.1 | Chore detail | Change HVAC filter: repeat, assignee, push reminder, Add to calendar with iCloud "Home" and Google calendars |
| 4.2 | Project detail | LVP flooring: Idea → Planned → In Progress → Done, estimate vs. actual, line items, scanned receipt |
| 4.3 | Appliance detail with fit check | 35¾ in LG fridge against the "Fridge opening 32 × 40 in" measurement, with a warning |
| 4.4 | Measurement entry | Pin on the room plan, W/D/H, unit toggle, Measure app and photo |
| 5.1 | Storage tree and search | "winter coat" leads to Upstairs › Attic › Shelf 2 › Bin "Winter – Matt" |
| 5.2 | Seasonal swap | Summer → Winter, by storage location, filtered by housemate |
| 5.3 | Pantry shopping list | Low items plus filters and bulbs that are due |
| 6.1 | Onboarding | "How do you want to create your plan?": Scan, Build with blocks, Trace a photo, Rough it in |
| 6.2 | Plan editor mode | Grid, handles, dimension chips, toolbar |
| 6.3 | Settings | Default floor = Ground, housemates, reminders, list view, iCloud, CSV |

## Design decisions I made

- **Look:** an architectural listing plan. White rooms, charcoal walls (heavy exterior, light interior), door swings and window symbols, small caps in Archivo Narrow, and dimensions with prime marks (13′2″ × 11′6″). Closets and stairs use a light grey fill, and unfinished basement rooms are hatched.
- **One accent color**, an ink blue (`--accent`), for anything the user can act on and for spend tints. Red (`--danger`) is used only for overdue items and fit failures, amber (`--warn`) for "low" and fit warnings, and green for "fits" and "scanned". There are no gradients.
- **Quiet rooms:** rooms with nothing in the current view grey out their label and "+", so each view reads without a legend.
- **Future Projects tint steps:** under $1k, $1k–$5k, and $5k or more. They are fixed amounts, not relative to the house.
- **"Due" in To-Dos** means overdue, today, or the next 7 days (rolling), not the calendar week.
- **Budget "spent"** includes actuals on In Progress projects, not only Done ones. Budget "planned" is the estimates on projects that aren't done.
- **"+" defaults:** Plan → Measurement, Budget → Future Project. Every other view defaults to its own type.
- **The view dropdown button** shows the icon and full view name without a "View" prefix, so "Appliances, Electronics & Furniture" fits on one line.
- **Edit mode hides the view dropdown and the "+" buttons.** Editing is geometry only, and the pills still work.
- **The Exterior** seeds 6 zones as in the plan. The sample also shows two user-added zones, Patio and Front bed, which is where the plan's "Front bed: 24 ft × 4 ft" example comes from.

## Assumptions to confirm (open questions)

1. **Attic placement.** The pills are Basement · Ground · Upstairs · Exterior, so the attic is modeled as a storage room on Upstairs. The data model allows a separate `attic` level. Should the attic get its own pill when a house has one?
2. **Appliances you plan to buy.** The fit check on screen 4.3 runs on a fridge the user hasn't bought yet ("Planning to buy"). `Thing` has no owned or planned status in §7. Should we add one, or should planned items live only on the Future Project?
3. **Launch view.** The app always opens in Plan on Ground. Should it remember the last view instead?
4. **Stairs have no "+".** They are treated as circulation, not a room. Is that OK?
5. **Tint thresholds** ($1k / $5k) and the 7-day "due" window: are these good defaults, or should they be settings?
6. **Calendar picker.** The mockup lists every writable calendar grouped by account (iCloud: Home, Family; Google: House, Matt), with "Home" suggested. The Google account name is a placeholder.
7. **Housemate colors** (Matt blue, Sam teal) are picked automatically and can be changed in Settings. Is that right?
8. **Sample data.** The house (14 Linden Ct, Annapolis MD), the costs and the brand names are all made up for the mockups.
