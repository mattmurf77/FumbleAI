# The Seven Views: Canvas Spec

This is the companion to `index.html` in this folder. It turns §2 of `07-merged-plan.md` into rules that can be built. The example numbers come from the sample house in the mockup (14 Linden Ct, with "today" set to Tue Sep 29, 2026).

---

## 0. Rules shared by every view

**The canvas never changes shape.** The walls, doors, windows and room geometry are the same in all seven views. The dropdown changes only what is drawn on the rooms, the room sheet, the "+" default and the bottom strip.

### Drawing layers, bottom to top

1. Paper background (`--paper`)
2. Room fills (`--room`; closets and stairs use `--room-alt`; unfinished rooms use the `#hatch` pattern)
3. The view's tint, if it has one
4. Walls: interior 1.3 pt and exterior 4.6 pt, both `--wall`
5. Doors and windows (display only)
6. Labels, chips and glyphs
7. The "+" button

### Room label

- The name is set in small caps (Archivo Narrow 600, +0.07em tracking, `--ink`).
- The second line is set smaller, in `--dim`.
- **Big rooms** (at least 7′0″ wide and 8′0″ deep at the default zoom) use this stack around the room's visual center:
  - name
  - second line
  - "+"
  - chip
- **Small rooms** put the name along the top edge and the chip at the bottom. The "+" stays at the center.
- Very narrow rooms, under 5′6″, use a short name ("½ Bath", "Cl.").
- As the user zooms in, rooms cross the size threshold and gain the full stack.

### Quiet rooms

A room with nothing for the current view fades its name to `--ink-3` and its "+" outline to grey. The rooms that matter then stand out without a legend.

### "+" button

- It sits at the room's visual center. For L-shaped or other non-rectangular rooms, use the pole of inaccessibility.
- It is drawn at 16 pt with a 44 pt hit area.
- It is hidden on Stairs and in edit mode.

### Chips

- A chip is a capsule of 11 pt semibold tabular figures.
- Variants:
  - accent (`--accent` on `--on-accent`)
  - danger (`--danger`)
  - neutral (`--room` fill, `--wall` hairline)
  - soft (`--accent-soft` fill, `--accent` text)
- A room shows at most one chip, plus one corner count chip in Appliances view.

### Selection

- The selected room gets `--accent-soft` fill and a 2 pt `--accent` inner stroke while its sheet is open.
- The canvas pans so the room stays above the sheet.

### Exterior level

- The same rules apply to yard zones. They are drawn over a muted satellite snapshot. `--sat` lowers the brightness to 0.72 in dark mode.
- Zones have white 3 pt dashed outlines.
- Labels are white with a dark halo.
- Tints use stronger alpha on imagery (0.25, 0.42 and 0.60).
- Tapping the house footprint jumps to the Ground floor.

### Units

The mockup shows feet and inches with prime marks (13′2″ × 11′6″), width × depth as seen on screen. Areas are in square feet.

---

## 1. Plan (default)

| | |
|---|---|
| **Purpose** | The plain, listing-style floor plan. It orients the user and is the home base. |
| **Data** | Space name and dimensions (from the plan geometry, which counts as a measurement too). |
| **Canvas encoding** | Name plus `W × D` on big rooms, and name only on small ones. There are no tints or chips. |
| **Room sheet** | Dimensions, area and how the room was created ("from Build with blocks"), with an **Edit shape** button, then that room's **Measurements** (for example, Kitchen has "Fridge opening, 32 in W × 40 in D, height not set" and "Window over sink"). |
| **Empty state** | Sheet: "No measurements. Measure openings, walls and doors for fit checks." Canvas without a plan: the onboarding chooser (screen 6.1). |
| **"+" default** | **Measurement** |
| **Summary strip** | `Ground · 10 rooms · 1,200 sq ft` / `Property · 3 levels · 3,600 sq ft · built 1994`. On Exterior: `Exterior · 8 zones · lot 8,050 sq ft` / `House outline from OpenStreetMap · drag zones to fit` |

## 2. To-Dos

| | |
|---|---|
| **Purpose** | Recurring household chores and one-off tasks. What needs doing, where, and by whom. |
| **Data** | `Chore`: title, room, assignee, repeat rule, next due date, linked Thing. Chores never carry cost and never enter Budget. |
| **Canvas encoding** | **Chip:** `N due`, where N counts chores due by today + 7 days, overdue ones included. The chip is accent-colored, or `--danger` if any are overdue. **Red edge:** a 2.4 pt `--danger` inner stroke inset 2 pt when at least one chore is overdue. A room with no chore due within 7 days is quiet, and later chores appear only in the sheet. |
| **Room sheet** | Grouped **Overdue** (red header), **Today**, **This week**, **Later**. Each row has a completion circle, title, repeat rule plus linked item ("Every 6 months · Fridge"), assignee avatar (Matt blue, Sam teal) and when it is due ("9d late", "Today", "Thu 1"). Tapping the circle completes the chore, logs a `ChoreCompletion` and reschedules it. |
| **Empty state** | "No chores here yet. Add a repeating chore like 'Wipe counters, daily.'" |
| **"+" default** | **To-Do** |
| **Summary strip** | `4 today · 5 this week · 3 overdue` (the overdue count in `--danger`) / `Next: Do the dishes · Sam · today` |

## 3. Future Projects

| | |
|---|---|
| **Purpose** | Improvements or repairs the household wants to do, with an estimated cost and time. |
| **Data** | `Project` with status Idea, Planned or In Progress: estimated cost and hours, line items, and the chore it came from, if any. |
| **Canvas encoding** | **Tint** by the sum of estimates for projects that aren't done: `--tint-1` under $1,000, `--tint-2` from $1,000 to $4,999, `--tint-3` at $5,000 or more. **Chip:** accent, `$3.5k`, adding `· N` when there are 2 or more projects. Big rooms also show "2 projects" on the second line. |
| **Room sheet** | Project rows with a status tag (In Progress uses the accent tag) and the estimate on the right. The header shows the count and the planned total. |
| **Empty state** | "No planned projects. Add an idea with a rough estimate. You can refine it later." |
| **"+" default** | **Future Project** |
| **Summary strip** | `Ground planned $5,810 · 5 projects` / `Property $31,680 across 14 projects` |

## 4. Past Work

| | |
|---|---|
| **Purpose** | The record of finished improvements and repairs, and the raw material for the future Home History Report. |
| **Data** | `Project` with status Done: actual cost and hours, completion date, receipts and photos. The estimate is kept for comparison. |
| **Canvas encoding** | **Chip:** neutral, lifetime spend (`$2.8k`). The second line on big rooms shows the last worked date (`last Mar '26`). There is no tint, because past spending shouldn't read as a warning. |
| **Room sheet** | Rows with the date, "est $950" and the actual cost on the right. The header shows the count and the lifetime total. |
| **Empty state** | "No past work logged. Log finished work with its cost, date and receipt." |
| **"+" default** | **Past Work** |
| **Summary strip** | `Ground lifetime $11,435 · last Apr 25` / `Property lifetime $16,905 · receipts on 11 of 14` |

## 5. Appliances, Electronics & Furniture

| | |
|---|---|
| **Purpose** | Durable things and their specs. Examples: fridge, TV, sofa, light fixtures and bulb types, furnace and filter size, smoke detectors. |
| **Data** | `Thing`: category, pin point, brand, model, serial, purchase date, warranty, dimensions, and attributes (bulb base, filter 16×25×1 MERV 11). |
| **Canvas encoding** | **Glyph** at each Thing's pin point: a 14 pt plan symbol on a `--room` backing, stroked in `--accent`. Symbols include fridge, range, dishwasher, washer, TV, sofa, chair, bed, table, ceiling light (circle with an X), fan, smoke detector, furnace, water heater, sump, desk, router and a generic box. **Count chip:** neutral, in the room's top-right corner. When zoomed out, glyphs thin out, keeping the count chip. |
| **Room sheet** | One row per item: glyph, name, and a one-line spec ("Carrier 59SC5 · filter 16×25×1 MERV 11"). A row opens the detail screen, where the fit check lives (screen 4.3). |
| **Empty state** | "Nothing tracked here. Add appliances, bulbs, filters or furniture." |
| **"+" default** | **Appliance/Electronic/Furniture**. The user then drops a pin in the room. |
| **Summary strip** | `Ground · 18 items` / the next consumable due, such as `Furnace filter 16×25×1 due Oct 2 · 1 spare`. A warranty ending within 90 days takes this slot when there is one. |

## 6. Inventory (pantry, clothing, stored items)

| | |
|---|---|
| **Purpose** | Consumables and belongings, and where they are. The key question is "Where did I store my winter clothes during the summer?" |
| **Data** | `StorageSpot` (nested) and `InventoryItem`: kind, owner, quantity and unit, season, in rotation or stored, expiry date, low flag. |
| **Canvas encoding** | **Chip:** neutral, `N items`. The second line on big rooms shows `N spots`. There is no tint. A room with no storage spots is quiet. |
| **Room sheet** | One row per top-level storage spot, with its item count and a `--warn` tag such as "4 low" for flagged items. A row drills into the spot tree (screen 5.1). |
| **Empty state** | "No storage spots. Add a shelf, bin or drawer, then add items to it." |
| **"+" default** | **Inventory item**. The spot picker starts on this room. |
| **Summary strip** | `Ground · 167 items in 10 spots` / `7 pantry items low · Shopping list` (accent, taps through to screen 5.3) |

Dedicated screens (founder override): **Storage** (tree plus "where is…" search), **Seasonal swap** and **Shopping list**.

## 7. Budget

| | |
|---|---|
| **Purpose** | Money only, rolled up per room, per floor and for the whole property. The user never types into it directly. |
| **Data** | Computed from Projects. **Planned** is the sum of estimates on projects that aren't done. **Spent** is the sum of actuals on Done and In Progress projects. |
| **Canvas encoding** | **Big rooms:** two lines below the "+": `$3.5k planned` in `--accent` semibold, then `$2.8k spent` in `--dim`. **Small rooms:** a soft chip, `$420 / $0`. There is no tint. A room with neither amount is quiet. |
| **Room sheet** | A card with Planned (accent) and Spent (actuals), then every project in the room labelled with its status. Planned rows show the estimate in accent and done rows show the actual. |
| **Empty state** | "No money tracked in this room yet. Add a Future Project to start a budget." |
| **"+" default** | **Future Project**, because Budget can't be edited directly |
| **Summary strip** | `Ground: $5,810 plan · $11,649 spent` / `Property: $31,680 planned · $20,299 spent`, with a thin bar showing the spent share of (planned + spent) |

---

## 8. Interaction model

### Launch and navigation

- **Launch:** the app opens on the **default floor**, which is **Ground** and can be changed in Settings. It opens in the **Plan** view.
- **Changing floors:** pill tabs only (Basement · Ground · Upstairs · Exterior), per decision #12. There is no horizontal swipe between floors. Swipe is tested after TestFlight.
- **View dropdown:** an iOS pull-down menu with a single choice, a checkmark on the active view, and an icon for each view. The button shows the view's icon and full name. The view persists across floor changes.

### Gestures on the canvas

- **Pinch:** zoom from 1× to 4×.
- **Drag:** pan, only when zoomed in.
- **Double-tap:** zoom to the room.
- **Tap a room:** opens the room sheet at half height.
- **Tap "+":** opens the add picker.
- **Long-press a room:** context menu with Rename, Edit shape and Add measurement.
- **Tap the house on Exterior:** jumps to Ground.

### Room sheet

- It opens at the half-height detent. Drag it up for the full detent, or down to dismiss.
- The canvas pans so the selected room stays visible above it.
- Its footer button adds an item of the active view's type.

### Add picker

A sheet with the six types: To-Do, Future Project, Past Work, Appliance/Electronic/Furniture, Inventory item and Measurement. The active view's type is highlighted and badged **Default**.

### Edit mode

- The pencil in the header toggles edit mode.
- **In edit mode:**
  - The header becomes Cancel / Edit {Floor} / Done.
  - The view dropdown is hidden, because editing is geometry only.
  - A 1 ft grid appears.
  - The "+" buttons are hidden.
  - Tapping a room selects it, with 8 handles and editable width and depth chips. Walls snap to 1 inch.
  - An inspector card (name, dimensions, Rename) and a toolbar (Room, Split, Door, Window, Measure, Undo) replace the summary strip.
- Doors and windows stay display-only. The Door and Window tools only place symbols.
- Pills still work, so the user can edit another floor.

### Accessibility

- **List view:** Settings › Show plan as a list. It turns on automatically with VoiceOver. It shows each floor as a list of rooms carrying the same per-view values as the chips.
- **Contrast:** the chips and the red edge never rely on color alone. The chip text always states the count.

### Theme

All colors are tokens. Dark mode inverts the paper and walls (`--wall` becomes light) and dims the satellite imagery.
