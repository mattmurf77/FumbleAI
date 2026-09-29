# 03 · Exterior and Yard

**Priority:** P0 · **Phase:** 1 (Plan core)
**Sources:** merged plan §1 (#3), §4 "Exterior (Plan B)", §11; HLD §4.5, ADR-07, ADR-12, R6–R7; LLD §6.11, `map_snapshot_cache`.

## Summary
When an address is known, the app finds the **house outline** from OpenStreetMap (Overpass API, called directly from the phone), places it on an **Apple Maps satellite snapshot**, and pre-creates yard zones: **Front yard, Backyard, Side yard L, Side yard R, Driveway, Sidewalk**, plus the **House footprint**. The user drags zones to fit and can add more (Patio, Garden bed, Deck, Shed, Pool, Lawn, custom). The exterior is one level ("Outside") that supports all seven views.

## User stories
- As a **new buyer**, I want my yard laid out automatically from my address so that I don't have to draw it.
- As a **gardener**, I want to add a "Front bed" zone with exact size so that I can plan plants and mulch.
- As an **owner**, I want to track exterior projects (patio, fence) and chores (mow, gutters) on the yard plan so that outside work sits with inside work.
- As a **user whose street isn't where the app thinks**, I want to rotate the yard so that the front yard faces the street.

## Functional requirements
- **FR-EXT-01** Seeding runs after plan creation when an address exists, or later from Settings › Home › "Set up outside". It never blocks the indoor canvas.
- **FR-EXT-02** The address is typed with autocomplete; no location permission is requested. *Assumption pending founder confirmation (HLD §9-23).*
- **FR-EXT-03** Geocode the address → coordinate. Only the coordinate is sent to Overpass (one request per property, 15 s timeout, app-identifying User-Agent). Only the address/coordinate is sent to Apple Maps.
- **FR-EXT-04** Footprint choice: the building polygon containing the point, else the nearest within 25 m; among several, the largest under 1,500 m² (avoids the neighbor's garage). Simplify to 6 in.
- **FR-EXT-05** **Orientation:** the front yard faces the nearest road found in the same request (within 60 m). With no road, the front is the bottom of the screen. *Assumption pending founder confirmation (HLD §9-17).*
- **FR-EXT-06** Seed zones per LLD §6.11 (front depth clamped 15–60 ft; side 10 ft; back 30 ft; sidewalk 4 ft; driveway 11 ft wide on the left by default). All zones are marked `autoseed` and are fully editable.
- **FR-EXT-07** **Fallback:** with no footprint found, place a 40 × 30 ft house block at the pin with the same zones and show "We couldn't find your house outline. Drag the block to match the photo."
- **FR-EXT-08** **Satellite image:** a 90 × 90 m satellite snapshot is drawn under the zones (60% opacity, 30% desaturated). It is cached **only on this device**, never synced; each device regenerates it. Regenerated when missing or older than 180 days. *Assumption pending founder confirmation (HLD §9-18).*
- **FR-EXT-09** Attribution "© OpenStreetMap contributors" and the Apple Maps legal attribution are always visible on the exterior level.
- **FR-EXT-10** **Editing:** the plan editor (spec 01) works outdoors: move/resize/reshape zones, add a zone from a palette (Patio, Deck, Garden bed, Lawn, Shed, Pool, Custom), rename, delete, and **Rotate plan** (free rotation with a 90° snap) which rotates zones and the image together.
- **FR-EXT-11** Tapping the **House footprint** zone switches to the default indoor floor (mockup 2.8: "Tap the house to go to Ground").
- **FR-EXT-12** Zones accept every item type through "+" (chores like "Mow front lawn", projects like "Patio extension", things like "Grill", inventory like "Garden hose", measurements like "Front bed 24 ft × 4 ft").
- **FR-EXT-13** Zone area is shown in sq ft (sq m in metric) in the room sheet; zone measurements are kind `zone`.
- **FR-EXT-14** Only one exterior level per property. "Redo outside from address" re-runs seeding after confirmation; existing zones and their items go to the "items go where" prompt (default: keep existing zones, add only missing ones).
- **FR-EXT-15** Offline: if there's no network at seeding time, skip silently, show "Outside will be set up when you're online" on the Outside pill, and retry automatically on the next launch with network (max once per launch).

## Acceptance criteria
- **AC-EXT-1** *Given* an address whose footprint exists in OSM, *when* seeding completes, *then* the Outside level shows the house outline on a satellite image with Front yard, Backyard, Side yard L, Side yard R, Driveway and Sidewalk, and the Front yard is on the side facing the nearest road.
- **AC-EXT-2** *Given* Overpass returns no building, *then* a 40 × 30 ft block with the same six zones is placed and the fallback message is shown.
- **AC-EXT-3** *Given* airplane mode during onboarding, *then* the indoor plan is created normally, and *when* the app next launches online, *then* seeding runs once.
- **AC-EXT-4** *Given* the Outside level, *when* the user adds a Garden bed zone and types 24 ft × 4 ft, *then* the zone is 96 sq ft and a zone measurement "24 ft × 4 ft" is attached.
- **AC-EXT-5** *Given* the user rotates the plan 90°, *then* the zones and satellite image rotate together and the rotation syncs to the user's other device, which regenerates its own image in the same orientation.
- **AC-EXT-6** *Given* the Future Projects view on Outside with a $6,800 "Patio extension" on the Patio, *then* the Patio has the strongest tint and a "$6.8k" chip (mockup 2.9).
- **AC-EXT-7** *Given* the Outside level, *then* OSM and Apple Maps attributions are visible at every zoom.
- **AC-EXT-8** *Given* a user taps the house footprint, *then* the canvas switches to the default indoor floor.

## Edge cases
- Townhouse/condo: footprint is the whole building; the user trims it or deletes zones that don't apply (no yard). The Rough-it-in style "Condo" skips exterior seeding by default and offers it as an option.
- Rural property with no roads within 60 m: front defaults to screen bottom.
- Corner lot: nearest road wins; user can rotate.
- Several candidate buildings (garage, shed): largest under 1,500 m² chosen; the user can tap "Wrong building?" to pick another candidate from the same response.
- Overpass rate-limited (HTTP 429) or down: treated like no network; retry on next launch.
- Address outside the US: works if OSM has data; units follow Settings.
- The satellite image is out of date (new construction): user relies on zones; image can be hidden in the level menu.

## Empty and error states
| State | Behavior |
|---|---|
| No address entered | Outside pill shows "Add your address to set up the yard" |
| Geocode fails | "We couldn't find that address. Check it or set up the yard by hand." → blank Outside level with a 40 × 30 ft block and default zones, no image |
| Snapshot fails | Zones drawn on a neutral background; retry on next open |

## Data touched (LLD)
`property` (address fields, latitude, longitude), `level` (kind `exterior`, `georef_json`), `space` (`is_exterior=1`, space types `footprint`, `front_yard`, `backyard`, `side_yard`, `driveway`, `sidewalk`, `patio`, `deck`, `garden_bed`, `lawn`, `shed`, `pool`, `custom_zone`; `source='autoseed'`), `measurement` (kind `zone`), local-only `map_snapshot_cache`.

## UI references
Mockups **2.8** Exterior · Plan, **2.9** Exterior · Future Projects, **6.2** Plan editor mode.

## Analytics / diagnostics
Log category `exterior`: geocode result, Overpass status and latency, candidate count, fallback used. Diagnostics shows "Outside: seeded / fallback / not set up".

## Out of scope
Public-record lot lines; hosted Microsoft Building Footprints (only needed at public scale); property boundaries; mulch/sod/plant estimates (later); location permission ("Use my current location" later); 3D terrain.

## Facts to verify before any public release
Apple's terms for storing satellite snapshots long-term; Overpass usage policy at scale (merged plan §11).

## Assumptions pending founder confirmation
HLD §9-17 (orientation by nearest road), §9-18 (satellite not synced), §9-23 (typed address, no location).
