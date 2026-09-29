# Homeowner App: Low-Level Design (v1)

**Companion to:** `hld.md` in this folder. Section references such as "HLD §5.3" point there.
**Status:** design only. The SQL, Swift and pseudo-code below are specifications, not code that has been compiled. Treat the signatures as the contract and the bodies as guidance.

---

## 1. Conventions

| Topic | Rule |
|---|---|
| IDs | `UUID`, stored as lowercase `TEXT` (36 chars). The same string is the CloudKit `recordName`. They are generated on the client with `UUID()`. |
| Geometry units | **Inches, `Double`**, level-local coordinates with x to the right and y **down**. On the exterior level +x is east and +y is south *before* the level's rotation is applied (§6.11). |
| Polygon storage | JSON text `[[x,y],[x,y],...]`. Rings are not closed (no repeated first vertex). Winding is normalized so the signed area is positive in stored coordinates (§6.2). Up to 2 decimal places. |
| Money | `INTEGER` minor units (cents) plus `currency_code TEXT` (ISO 4217, default `'USD'`). Display uses `Decimal`. Money is never a float. |
| Time: instants | GRDB default `DATETIME` text `YYYY-MM-DD HH:MM:SS.SSS`, in UTC. |
| Time: local dates | `TEXT 'YYYY-MM-DD'`, floating with no zone (chore due dates, purchase dates, warranty end, expiry). |
| Time of day | `INTEGER` minutes after local midnight (0–1439). |
| Booleans | `INTEGER` 0/1 with `CHECK (x IN (0,1))`. |
| Enums | `TEXT` with a `CHECK (x IN (...))`. Swift uses `String`-backed enums. **An unknown value from a newer app version is decoded to `.unknown` and preserved** (forward compatibility). |
| JSON columns | `TEXT` containing JSON. The table names each one `*_json`, or it is documented. Queried with SQLite `json_extract`. |
| Sync columns | Every synced table has `created_at`, `updated_at` (set by the repository on every write) and `deleted_at` (a soft-delete tombstone). |
| Naming | SQL uses `snake_case` singular table names. Swift uses `camelCase`, with `CodingKeys` mapping through GRDB's `databaseColumnDecodingStrategy = .convertFromSnakeCase`. |
| Scope | Chores, projects, things and inventory carry a scope triple: `scope` plus `space_id` plus `level_id` (§3.3 CHECKs). `level_id` is **denormalized** from the space when the scope is `space`. |

---

## 2. Module and folder structure

```
HomeApp/                                   (Xcode workspace root)
├─ Home.xcodeproj
├─ App/                                    (app target "Home")
│  ├─ HomeApp.swift                        @main, scenePhase hooks, BGTask registration
│  ├─ AppEnvironment.swift                 composition root (all services, injected via .environment)
│  ├─ Features/
│  │  ├─ Plan/        PlanScreen, LevelPills, LensMenu, FooterStrip, WholeHouseChip
│  │  ├─ RoomSheet/   RoomSheet, RoomHeader, LensSection, MeasurementsSection
│  │  ├─ Add/         AddPicker, ItemRef routing
│  │  ├─ Chores/      ChoreForm, ChoreRow, RepeatRulePicker, ReminderToggle, CalendarPicker
│  │  ├─ Projects/    ProjectForm, DoneSheet, LineItemsEditor
│  │  ├─ Things/      ThingForm, TemplateFields, FitBanner
│  │  ├─ Inventory/   InventoryForm, StorageTreeView, SeasonalSwapView, ShoppingListView
│  │  ├─ Measurements/MeasurementForm
│  │  ├─ Budget/      BudgetDrillDown
│  │  ├─ Search/      SearchView
│  │  ├─ Onboarding/  AddressStep, PathChooser, ScanFlow, BlocksFlow, TraceFlow, RoughFlow, ReviewDraft
│  │  ├─ Editor/      PlanEditorOverlay, HandleViews, DimensionEntry, UndoStack
│  │  ├─ People/      PeopleEditor
│  │  └─ Settings/    SettingsView, DiagnosticsView, ExportView, RecentlyDeletedView
│  ├─ Resources/      Templates/*.json (thing templates, block styles), Assets.xcassets, Localizable.xcstrings
│  ├─ Info.plist, Home.entitlements, PrivacyInfo.xcprivacy
│  └─ Tests/ (HomeUITests)
└─ Packages/
   ├─ PlanKit/            Sources/PlanKit/{Vec2,Polygon,Validation,Area,Contains,PolyLabel,Snapper,
   │                        Weld,WallDerivation,Treemap,TangentPlane,Transform2D}.swift
   │                      Sources/Clipper2Bridge/ (vendored Clipper2 C++ + C shim header)
   │                      Tests/PlanKitTests/ + Fixtures/*.json
   ├─ HomeCore/           Sources/HomeCore/{Models/*,RepeatRule,RecurrenceEngine,NotificationPlanner,
   │                        FitChecker,Season,Money,LengthFormatter,ItemRef,PlanDraft,DomainEvent}.swift
   ├─ HomeStore/          Sources/HomeStore/{AppDatabase,Migrations,Records/*,Repositories/*,Outbox,
   │                        SearchIndexer,RollupQueries,StorageTreeQueries,LensStatsQueries,
   │                        CSVExporter,AttachmentFileStore,PlanCommitter}.swift
   ├─ HomeSync/           Sources/HomeSync/{SyncCoordinator,SyncEngineProtocol,RecordMapper,Mappers/*,
   │                        MergePolicy,OrphanParking,AccountHandling}.swift
   ├─ HomeSchedule/       Sources/HomeSchedule/{ReminderScheduler,NotificationCenterProtocol,
   │                        NotificationActions,CalendarSync,CalendarStoreProtocol,RecurrenceToEK}.swift
   ├─ HomeCapture/        Sources/HomeCapture/{RoomPlanImporter,RoomPlanLabelMap,PhotoTraceCalibrator,
   │                        RoughInGenerator,BlockTemplates,ReceiptReader,ReceiptParser}.swift
   ├─ HomeExterior/       Sources/HomeExterior/{AddressResolver,OverpassClient,OverpassFootprintProvider,
   │                        SatelliteSnapshotter,YardSeeder}.swift
   └─ PlanCanvas/         Sources/PlanCanvas/{PlanCanvasView,Viewport,GestureController,
                            LevelRenderModel,RenderModelBuilder,Painter,TextCache,
                            Lenses/{PlanLens,PlanLensImpl,ToDoLens,FutureLens,PastLens,
                                    ThingsLens,InventoryLens,BudgetLens},
                            Overlays/{AddButtonOverlay,ChipOverlay,PinOverlay},
                            Accessibility/CanvasAccessibility}.swift
```

Dependency direction is strictly downward: `App → PlanCanvas/HomeSync/HomeSchedule/HomeCapture/HomeExterior → HomeStore → HomeCore → PlanKit`. `PlanCanvas` depends only on `HomeCore` and `PlanKit`; it receives value snapshots and never a database handle.

---

## 3. SQLite schema (GRDB migrations)

### 3.1 Database configuration
```swift
var config = Configuration()
config.foreignKeysEnabled = true           // default in GRDB, stated for clarity
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")    // DatabasePool does this, explicit for clarity
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
}
let pool = try DatabasePool(path: appSupport/"home.sqlite", configuration: config)
```
- Migrations are registered in order. They are **append-only**, and a shipped migration is never edited.
- `migrator.eraseDatabaseOnSchemaChange = true` only in `#if DEBUG` for simulator iteration.

### 3.2 Migration `v1_core`: synced domain tables

```sql
-- ───────────────────────── property / levels / spaces ─────────────────────────
CREATE TABLE property (
  id                TEXT PRIMARY KEY NOT NULL,
  name              TEXT NOT NULL DEFAULT 'My Home',
  address_line      TEXT,
  locality          TEXT,
  region            TEXT,
  postal_code       TEXT,
  country_code      TEXT,                              -- ISO 3166-1 alpha-2
  latitude          REAL,
  longitude         REAL,
  year_built        INTEGER,
  approx_sq_ft      INTEGER,                           -- from Rough-it-in / user; sanity check only
  default_level_id  TEXT,                              -- app-validated (no FK: avoids cycle); fallback = level with sort_order 0
  currency_code     TEXT NOT NULL DEFAULT 'USD',
  unit_system       TEXT NOT NULL DEFAULT 'imperial' CHECK (unit_system IN ('imperial','metric')),
  created_at        DATETIME NOT NULL,
  updated_at        DATETIME NOT NULL,
  deleted_at        DATETIME
);

CREATE TABLE level (
  id                      TEXT PRIMARY KEY NOT NULL,
  property_id             TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  name                    TEXT NOT NULL,               -- "1st Floor", "Basement", "Outside"
  kind                    TEXT NOT NULL CHECK (kind IN ('floor','basement','attic','exterior')),
  sort_order              INTEGER NOT NULL,            -- elevation index: basement -1, ground 0, 2nd 1, attic 2; exterior 100
  underlay_attachment_id  TEXT REFERENCES attachment(id) ON DELETE SET NULL,
  underlay_transform_json TEXT,                        -- UnderlayTransform (§6.9)
  underlay_visible        INTEGER NOT NULL DEFAULT 1 CHECK (underlay_visible IN (0,1)),
  georef_json             TEXT,                        -- exterior only: GeoReference (§6.11)
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX level_property ON level(property_id, sort_order) WHERE deleted_at IS NULL;
-- one exterior level per property
CREATE UNIQUE INDEX level_one_exterior ON level(property_id) WHERE kind = 'exterior' AND deleted_at IS NULL;

CREATE TABLE space (
  id              TEXT PRIMARY KEY NOT NULL,
  property_id     TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  level_id        TEXT NOT NULL REFERENCES level(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,                       -- free text, user label
  space_type      TEXT NOT NULL DEFAULT 'room' CHECK (space_type IN (
                    'room','kitchen','bedroom','bathroom','half_bath','living','dining','family','office',
                    'laundry','closet','hall','stairs','garage','utility','mudroom','storage',
                    'footprint','front_yard','backyard','side_yard','driveway','sidewalk','patio','deck',
                    'garden_bed','lawn','shed','pool','custom_zone')),
  is_exterior     INTEGER NOT NULL DEFAULT 0 CHECK (is_exterior IN (0,1)),
  polygon_json    TEXT NOT NULL,                       -- [[x,y],...] inches, level coords
  source          TEXT NOT NULL CHECK (source IN ('roomplan','blocks','trace','rough','autoseed','manual')),
  is_approximate  INTEGER NOT NULL DEFAULT 0 CHECK (is_approximate IN (0,1)),
  color_hex       TEXT,                                -- optional override fill (exterior zones mostly)
  sort_order      INTEGER NOT NULL DEFAULT 0,
  -- local derived caches (NOT synced; recomputed on every write/apply from polygon_json)
  area_sq_in      REAL NOT NULL DEFAULT 0,
  min_x REAL NOT NULL DEFAULT 0, min_y REAL NOT NULL DEFAULT 0,
  max_x REAL NOT NULL DEFAULT 0, max_y REAL NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX space_level ON space(level_id) WHERE deleted_at IS NULL;

-- display-only doors/windows (RoomPlan or hand-placed); stored as a segment, snapped to nearest wall at render
CREATE TABLE opening (
  id           TEXT PRIMARY KEY NOT NULL,
  property_id  TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  level_id     TEXT NOT NULL REFERENCES level(id) ON DELETE CASCADE,
  space_id     TEXT REFERENCES space(id) ON DELETE SET NULL,   -- primary room (for sheet listing)
  kind         TEXT NOT NULL CHECK (kind IN ('door','window','opening')),
  ax REAL NOT NULL, ay REAL NOT NULL, bx REAL NOT NULL, by REAL NOT NULL,  -- inches, along wall
  height_in    REAL,
  sill_in      REAL,                                   -- windows
  swing        TEXT CHECK (swing IN ('left_in','right_in','left_out','right_out','sliding','none')),
  is_exterior_door INTEGER NOT NULL DEFAULT 0 CHECK (is_exterior_door IN (0,1)),
  source       TEXT NOT NULL CHECK (source IN ('roomplan','manual')),
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX opening_level ON opening(level_id) WHERE deleted_at IS NULL;

-- ───────────────────────── people / storage / measurement ─────────────────────────
CREATE TABLE person (
  id           TEXT PRIMARY KEY NOT NULL,
  property_id  TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  color_hex    TEXT,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);

CREATE TABLE storage_spot (
  id              TEXT PRIMARY KEY NOT NULL,
  property_id     TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  space_id        TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE,
  parent_spot_id  TEXT REFERENCES storage_spot(id) ON DELETE CASCADE,  -- NULL = top-level in space
  name            TEXT NOT NULL,                       -- "Shelf 2", "Bin 'Winter – Matt'"
  owner_id        TEXT REFERENCES person(id) ON DELETE SET NULL,       -- optional ("Matt's bin")
  pin_x REAL, pin_y REAL,                              -- optional point on plan (inches)
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK (parent_spot_id IS NULL OR parent_spot_id <> id)
);
CREATE INDEX storage_spot_space  ON storage_spot(space_id) WHERE deleted_at IS NULL;
CREATE INDEX storage_spot_parent ON storage_spot(parent_spot_id) WHERE deleted_at IS NULL;

CREATE TABLE measurement (
  id               TEXT PRIMARY KEY NOT NULL,
  property_id      TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  label            TEXT NOT NULL,                      -- "Fridge opening", "Front bed"
  kind             TEXT NOT NULL DEFAULT 'general' CHECK (kind IN ('opening','wall','door','window','zone','general')),
  space_id         TEXT REFERENCES space(id) ON DELETE CASCADE,
  opening_id       TEXT REFERENCES opening(id) ON DELETE CASCADE,
  storage_spot_id  TEXT REFERENCES storage_spot(id) ON DELETE SET NULL,
  pin_x REAL, pin_y REAL,                              -- "spot in a room"
  seg_ax REAL, seg_ay REAL, seg_bx REAL, seg_by REAL,  -- kind='wall': the edge it describes
  width_in         REAL CHECK (width_in  IS NULL OR width_in  > 0),
  depth_in         REAL CHECK (depth_in  IS NULL OR depth_in  > 0),
  height_in        REAL CHECK (height_in IS NULL OR height_in > 0),
  is_delivery_path INTEGER NOT NULL DEFAULT 0 CHECK (is_delivery_path IN (0,1)),
  note             TEXT,
  source           TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','roomplan','plan_edit','measure_app')),
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK (space_id IS NOT NULL OR opening_id IS NOT NULL),
  CHECK (width_in IS NOT NULL OR depth_in IS NOT NULL OR height_in IS NOT NULL)
);
CREATE INDEX measurement_space   ON measurement(space_id)   WHERE deleted_at IS NULL;
CREATE INDEX measurement_opening ON measurement(opening_id) WHERE deleted_at IS NULL;

-- ───────────────────────── the four item tables ─────────────────────────
-- Shared scope CHECK (repeated per table):
--   (scope='space'    AND space_id IS NOT NULL AND level_id IS NOT NULL) OR
--   (scope='level'    AND space_id IS NULL     AND level_id IS NOT NULL) OR
--   (scope='property' AND space_id IS NULL     AND level_id IS NULL)

CREATE TABLE thing (
  id                  TEXT PRIMARY KEY NOT NULL,
  property_id         TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  scope               TEXT NOT NULL CHECK (scope IN ('space','level','property')),
  space_id            TEXT REFERENCES space(id) ON DELETE SET NULL,
  level_id            TEXT REFERENCES level(id) ON DELETE SET NULL,
  category            TEXT NOT NULL CHECK (category IN ('appliance','electronic','furniture','fixture','system')),
  name                TEXT NOT NULL,                   -- "Refrigerator", "Hallway ceiling light"
  ownership           TEXT NOT NULL DEFAULT 'owned' CHECK (ownership IN ('owned','planned')),
  template_key        TEXT,                            -- 'refrigerator','light_fixture','hvac_furnace','smoke_detector',...
  attributes_json     TEXT NOT NULL DEFAULT '{}',      -- template fields: {"bulbBase":"E26","filterSize":"16x25x1","merv":11}
  brand TEXT, model TEXT, serial TEXT,
  purchase_date       TEXT,                            -- 'YYYY-MM-DD'
  purchase_price_cents INTEGER,
  currency_code       TEXT NOT NULL DEFAULT 'USD',
  warranty_end        TEXT,                            -- 'YYYY-MM-DD'
  width_in REAL, depth_in REAL, height_in REAL,
  fit_measurement_id  TEXT REFERENCES measurement(id) ON DELETE SET NULL,
  pin_x REAL, pin_y REAL,                              -- icon position on plan (inches)
  notes               TEXT,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK ((scope='space' AND space_id IS NOT NULL AND level_id IS NOT NULL) OR
         (scope='level' AND space_id IS NULL AND level_id IS NOT NULL) OR
         (scope='property' AND space_id IS NULL AND level_id IS NULL)),
  CHECK (json_valid(attributes_json))
);
CREATE INDEX thing_space    ON thing(space_id)     WHERE deleted_at IS NULL;
CREATE INDEX thing_level    ON thing(level_id)     WHERE deleted_at IS NULL;
CREATE INDEX thing_template ON thing(template_key) WHERE deleted_at IS NULL;

CREATE TABLE chore (
  id                 TEXT PRIMARY KEY NOT NULL,
  property_id        TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  scope              TEXT NOT NULL CHECK (scope IN ('space','level','property')),
  space_id           TEXT REFERENCES space(id) ON DELETE SET NULL,
  level_id           TEXT REFERENCES level(id) ON DELETE SET NULL,
  title              TEXT NOT NULL,
  notes              TEXT,
  assignee_id        TEXT REFERENCES person(id) ON DELETE SET NULL,
  repeat_rule_json   TEXT,                             -- NULL = one-off task (§9.1)
  start_on           TEXT NOT NULL,                    -- 'YYYY-MM-DD', rule anchor
  next_due_on        TEXT,                             -- 'YYYY-MM-DD'; NULL = no due date / closed
  due_minutes        INTEGER CHECK (due_minutes IS NULL OR due_minutes BETWEEN 0 AND 1439), -- NULL = all-day
  remind_enabled     INTEGER NOT NULL DEFAULT 0 CHECK (remind_enabled IN (0,1)),
  remind_offset_min  INTEGER NOT NULL DEFAULT 0,       -- minutes before due time (0 = at time)
  calendar_enabled   INTEGER NOT NULL DEFAULT 0 CHECK (calendar_enabled IN (0,1)),
  linked_thing_id    TEXT REFERENCES thing(id) ON DELETE SET NULL,   -- "Change filter" → furnace
  is_paused          INTEGER NOT NULL DEFAULT 0 CHECK (is_paused IN (0,1)),
  closed_at          DATETIME,                         -- one-off completed, or archived
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK ((scope='space' AND space_id IS NOT NULL AND level_id IS NOT NULL) OR
         (scope='level' AND space_id IS NULL AND level_id IS NOT NULL) OR
         (scope='property' AND space_id IS NULL AND level_id IS NULL)),
  CHECK (repeat_rule_json IS NULL OR json_valid(repeat_rule_json))
);
CREATE INDEX chore_due   ON chore(property_id, next_due_on) WHERE deleted_at IS NULL AND closed_at IS NULL;
CREATE INDEX chore_space ON chore(space_id) WHERE deleted_at IS NULL;
CREATE INDEX chore_level ON chore(level_id) WHERE deleted_at IS NULL;
CREATE INDEX chore_thing ON chore(linked_thing_id) WHERE linked_thing_id IS NOT NULL;

CREATE TABLE chore_completion (                        -- append-only
  id           TEXT PRIMARY KEY NOT NULL,
  property_id  TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  chore_id     TEXT NOT NULL REFERENCES chore(id) ON DELETE CASCADE,
  due_on       TEXT,                                   -- occurrence it satisfied ('YYYY-MM-DD')
  done_at      DATETIME NOT NULL,
  done_on      TEXT NOT NULL,                          -- local date of done_at (for recurrence math)
  done_by      TEXT REFERENCES person(id) ON DELETE SET NULL,
  outcome      TEXT NOT NULL DEFAULT 'done' CHECK (outcome IN ('done','skipped')),
  note         TEXT,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX chore_completion_chore ON chore_completion(chore_id, done_at DESC) WHERE deleted_at IS NULL;

-- calendar link: synced so any device can find/adopt the events (§9.5)
CREATE TABLE chore_calendar_link (
  id                     TEXT PRIMARY KEY NOT NULL,    -- == chore_id (1:1)
  property_id            TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  chore_id               TEXT NOT NULL UNIQUE REFERENCES chore(id) ON DELETE CASCADE,
  owner_device_id        TEXT NOT NULL,                -- Keychain-stored install UUID (§9.5)
  calendar_title         TEXT NOT NULL,                -- for display on non-owner devices
  calendar_source_title  TEXT,                         -- "iCloud", "Gmail – matt@..."
  calendar_identifier    TEXT,                         -- EKCalendar.calendarIdentifier (owner device)
  event_external_id      TEXT,                         -- EKEvent.calendarItemExternalIdentifier
  event_mode             TEXT NOT NULL CHECK (event_mode IN ('series','single')),
  series_signature       TEXT,                         -- hash(rule,start,time,title) at last write
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);

CREATE TABLE project (
  id                    TEXT PRIMARY KEY NOT NULL,
  property_id           TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  scope                 TEXT NOT NULL CHECK (scope IN ('space','level','property')),
  space_id              TEXT REFERENCES space(id) ON DELETE SET NULL,
  level_id              TEXT REFERENCES level(id) ON DELETE SET NULL,
  title                 TEXT NOT NULL,
  notes                 TEXT,
  status                TEXT NOT NULL DEFAULT 'idea' CHECK (status IN ('idea','planned','in_progress','done')),
  priority              INTEGER CHECK (priority IS NULL OR priority BETWEEN 1 AND 3),
  est_cost_cents        INTEGER CHECK (est_cost_cents IS NULL OR est_cost_cents >= 0),
  actual_cost_cents     INTEGER CHECK (actual_cost_cents IS NULL OR actual_cost_cents >= 0),
  currency_code         TEXT NOT NULL DEFAULT 'USD',
  est_hours             REAL,
  actual_hours          REAL,
  target_on             TEXT,                          -- 'YYYY-MM-DD'
  started_on            TEXT,
  completed_on          TEXT,                          -- set when status → done
  vendor                TEXT,
  spawned_from_chore_id TEXT REFERENCES chore(id) ON DELETE SET NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK ((scope='space' AND space_id IS NOT NULL AND level_id IS NOT NULL) OR
         (scope='level' AND space_id IS NULL AND level_id IS NOT NULL) OR
         (scope='property' AND space_id IS NULL AND level_id IS NULL)),
  CHECK (status <> 'done' OR completed_on IS NOT NULL)
);
CREATE INDEX project_space_status ON project(space_id, status)    WHERE deleted_at IS NULL;
CREATE INDEX project_level_status ON project(level_id, status)    WHERE deleted_at IS NULL;
CREATE INDEX project_prop_status  ON project(property_id, status) WHERE deleted_at IS NULL;

CREATE TABLE cost_line_item (
  id                     TEXT PRIMARY KEY NOT NULL,
  property_id            TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  project_id             TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  label                  TEXT NOT NULL,
  amount_cents           INTEGER NOT NULL CHECK (amount_cents >= 0),
  kind                   TEXT NOT NULL DEFAULT 'other' CHECK (kind IN ('material','labor','permit','other')),
  vendor                 TEXT,
  incurred_on            TEXT,
  hours                  REAL,
  receipt_attachment_id  TEXT REFERENCES attachment(id) ON DELETE SET NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX cost_line_item_project ON cost_line_item(project_id) WHERE deleted_at IS NULL;

CREATE TABLE inventory_item (
  id               TEXT PRIMARY KEY NOT NULL,
  property_id      TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL CHECK (kind IN ('pantry','clothing','stored','other')),
  name             TEXT NOT NULL,
  category         TEXT,                               -- clothing: 'coat','boots',...; pantry: 'canned','spices',...
  owner_id         TEXT REFERENCES person(id) ON DELETE SET NULL,
  scope            TEXT NOT NULL DEFAULT 'space' CHECK (scope IN ('space','level','property')),
  space_id         TEXT REFERENCES space(id) ON DELETE SET NULL,     -- denormalized from spot when spot set
  level_id         TEXT REFERENCES level(id) ON DELETE SET NULL,     -- denormalized
  storage_spot_id  TEXT REFERENCES storage_spot(id) ON DELETE SET NULL,
  quantity         REAL NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  unit             TEXT,                               -- 'ea','lb','oz','can','box','pair'
  season           TEXT CHECK (season IN ('summer','winter','all_year')),
  in_rotation      INTEGER CHECK (in_rotation IN (0,1)),              -- clothing: 1 in rotation, 0 stored
  expires_on       TEXT,                               -- pantry
  is_low           INTEGER NOT NULL DEFAULT 0 CHECK (is_low IN (0,1)),
  low_threshold    REAL,                               -- optional: auto-flag low when quantity <= threshold
  linked_thing_id  TEXT REFERENCES thing(id) ON DELETE SET NULL,     -- spare filters/bulbs for a fixture
  notes            TEXT,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME,
  CHECK ((scope='space' AND space_id IS NOT NULL AND level_id IS NOT NULL) OR
         (scope='level' AND space_id IS NULL AND level_id IS NOT NULL) OR
         (scope='property' AND space_id IS NULL AND level_id IS NULL)),
  CHECK (storage_spot_id IS NULL OR scope = 'space')
);
CREATE INDEX inventory_spot    ON inventory_item(storage_spot_id) WHERE deleted_at IS NULL;
CREATE INDEX inventory_space   ON inventory_item(space_id)        WHERE deleted_at IS NULL;
CREATE INDEX inventory_owner   ON inventory_item(owner_id)        WHERE deleted_at IS NULL;
CREATE INDEX inventory_season  ON inventory_item(kind, season, in_rotation) WHERE deleted_at IS NULL;
CREATE INDEX inventory_low     ON inventory_item(property_id) WHERE is_low = 1 AND deleted_at IS NULL;
CREATE INDEX inventory_expiry  ON inventory_item(expires_on)  WHERE expires_on IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX inventory_thing   ON inventory_item(linked_thing_id) WHERE linked_thing_id IS NOT NULL;

-- ───────────────────────── attachments (polymorphic) ─────────────────────────
CREATE TABLE attachment (
  id            TEXT PRIMARY KEY NOT NULL,
  property_id   TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
  owner_type    TEXT NOT NULL CHECK (owner_type IN ('chore','chore_completion','project','cost_line_item',
                   'thing','inventory_item','measurement','space','level','storage_spot')),
  owner_id      TEXT NOT NULL,                         -- polymorphic: no FK; app-level cascade on purge
  kind          TEXT NOT NULL CHECK (kind IN ('photo','receipt','manual','document','underlay')),
  file_ext      TEXT NOT NULL,                         -- 'heic','jpg','pdf','png'
  uti           TEXT NOT NULL,
  byte_size     INTEGER NOT NULL,
  width_px      INTEGER, height_px INTEGER,
  sha256        TEXT NOT NULL,                         -- dedupe + integrity
  caption       TEXT,
  ocr_text      TEXT,                                  -- Vision output (receipts, manuals)
  captured_at   DATETIME,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, deleted_at DATETIME
);
CREATE INDEX attachment_owner ON attachment(owner_type, owner_id) WHERE deleted_at IS NULL;
```

Note on FK ordering: `level.underlay_attachment_id` and `cost_line_item.receipt_attachment_id` reference `attachment`, which is created later in the same migration. SQLite resolves FK targets when rows are written, not when tables are created, so the order is legal.

### 3.3 Migration `v1_local`: local-only tables (never synced)
```sql
CREATE TABLE sync_state (                 -- single row
  id                  INTEGER PRIMARY KEY CHECK (id = 1),
  engine_state        BLOB,               -- CKSyncEngine.State.Serialization (Codable → JSON/plist data)
  account_record_name TEXT,               -- CKCurrentUserDefaultName resolved; detects account switch
  last_fetch_at       DATETIME,
  last_send_at        DATETIME,
  last_error          TEXT
);

CREATE TABLE sync_record_meta (           -- per synced row: CloudKit system fields (change tag etc.)
  record_name    TEXT NOT NULL,
  record_type    TEXT NOT NULL,
  zone_name      TEXT NOT NULL,
  system_fields  BLOB NOT NULL,           -- CKRecord.encodeSystemFields(with:) archive
  PRIMARY KEY (record_type, record_name)
);

CREATE TABLE sync_outbox (                -- durable pending changes (source of truth for "unsent")
  record_type    TEXT NOT NULL,
  record_name    TEXT NOT NULL,
  zone_name      TEXT NOT NULL,
  op             TEXT NOT NULL CHECK (op IN ('save','delete')),
  changed_fields TEXT NOT NULL DEFAULT '[]',  -- JSON array of column names (union of unsent edits)
  local_version  INTEGER NOT NULL,        -- bumps on each local write; send clears only if unchanged
  enqueued_at    DATETIME NOT NULL,
  PRIMARY KEY (record_type, record_name)
);

CREATE TABLE sync_orphan (                -- fetched records whose parent row hasn't arrived yet
  record_type    TEXT NOT NULL,
  record_name    TEXT NOT NULL,
  record_archive BLOB NOT NULL,           -- NSKeyedArchiver(CKRecord)
  missing_parent TEXT NOT NULL,           -- "space/<uuid>"
  first_seen_at  DATETIME NOT NULL,
  PRIMARY KEY (record_type, record_name)
);

CREATE TABLE calendar_event_cache (       -- device-local EventKit ids
  chore_id         TEXT PRIMARY KEY NOT NULL,
  event_identifier TEXT NOT NULL,         -- EKEvent.eventIdentifier (may change; re-resolved)
  last_verified_at DATETIME NOT NULL
);

CREATE TABLE attachment_local (           -- download/upload state of binaries
  attachment_id  TEXT PRIMARY KEY NOT NULL,
  state          TEXT NOT NULL CHECK (state IN ('local','needs_upload','remote_only','downloading','missing')),
  thumb_ready    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE map_snapshot_cache (
  level_id       TEXT PRIMARY KEY NOT NULL,
  file_name      TEXT NOT NULL,           -- Caches/Snapshots/<levelId>.heic
  region_json    TEXT NOT NULL,           -- center lat/lon, span meters, pixel size, pts-per-meter
  created_at     DATETIME NOT NULL
);

CREATE TABLE notification_snooze (       -- active "Snooze 1h" requests (max 2, §9.3)
  id        TEXT PRIMARY KEY NOT NULL,
  chore_id  TEXT NOT NULL,
  fire_at   DATETIME NOT NULL
);

CREATE TABLE app_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);  -- device_id, device_nickname, fts_version...
```

### 3.4 Migration `v1_search`: FTS5 (local-only, rebuildable)
```sql
CREATE VIRTUAL TABLE search_fts USING fts5(
  title,                                   -- weight 10
  body,                                    -- notes, attributes values, brand/model, OCR text; weight 1
  location,                                -- "Attic › Shelf 2 › Bin Winter – Matt · 2nd Floor"; weight 3
  people,                                  -- assignee/owner names; weight 2
  entity_type UNINDEXED,                   -- 'chore','project','thing','inventory_item','measurement','space','storage_spot'
  entity_id   UNINDEXED,
  property_id UNINDEXED,
  tokenize = 'porter unicode61 remove_diacritics 2',
  prefix   = '2 3'
);
```

### 3.5 Migration hygiene
- Each migration has a golden test: build an empty DB, migrate, and compare `sqlite_master` against a checked-in `schema_vN.sql`.
- A second test migrates a seeded fixture DB from each prior version.
- **Adding a column:** add it as nullable or with a default. CloudKit mappers must tolerate the field being missing, for older clients.
- **Removing a column:** it becomes unused and is never dropped until v2.

---

## 4. Swift model structs (HomeCore, with GRDB conformances in HomeStore)

```swift
public typealias ID<T> = Tagged<T, UUID>          // tiny in-house Tagged; or plain UUID + typealiases
public struct LocalDate: Hashable, Codable, Comparable, Sendable {   // floating 'YYYY-MM-DD'
    public var year: Int, month: Int, day: Int
}
public struct Money: Hashable, Codable, Sendable { public var cents: Int64; public var currency: String }

public enum Scope: Hashable, Sendable {
    case space(Space.ID, level: Level.ID)
    case level(Level.ID)
    case property
}

public struct Property: Identifiable, Codable, Sendable {
    public var id: UUID; public var name: String
    public var address: PostalAddressLite?; public var latitude: Double?; public var longitude: Double?
    public var yearBuilt: Int?; public var approxSqFt: Int?
    public var defaultLevelId: UUID?; public var currencyCode: String; public var unitSystem: UnitSystem
    public var createdAt: Date; public var updatedAt: Date; public var deletedAt: Date?
}

public struct Level: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case floor, basement, attic, exterior, unknown }
    public var id: UUID; public var propertyId: UUID; public var name: String; public var kind: Kind
    public var sortOrder: Int
    public var underlayAttachmentId: UUID?; public var underlayTransform: UnderlayTransform?; public var underlayVisible: Bool
    public var georef: GeoReference?
    public var createdAt: Date; public var updatedAt: Date; public var deletedAt: Date?
}

public struct Space: Identifiable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case roomplan, blocks, trace, rough, autoseed, manual, unknown }
    public var id: UUID; public var propertyId: UUID; public var levelId: UUID
    public var name: String; public var spaceType: SpaceType; public var isExterior: Bool
    public var polygon: Polygon                        // PlanKit
    public var source: Source; public var isApproximate: Bool; public var colorHex: String?; public var sortOrder: Int
    public var createdAt: Date; public var updatedAt: Date; public var deletedAt: Date?
}

public struct Opening: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case door, window, opening, unknown }
    public var id: UUID; public var propertyId: UUID; public var levelId: UUID; public var spaceId: UUID?
    public var kind: Kind; public var segment: Segment; public var heightIn: Double?; public var sillIn: Double?
    public var swing: Swing?; public var isExteriorDoor: Bool; public var source: String
    public var createdAt: Date; public var updatedAt: Date; public var deletedAt: Date?
}

public struct Person: Identifiable, Codable, Sendable { public var id: UUID; public var propertyId: UUID; public var name: String; public var colorHex: String?; public var sortOrder: Int; /* timestamps */ }

public struct StorageSpot: Identifiable, Codable, Sendable {
    public var id: UUID; public var propertyId: UUID; public var spaceId: UUID; public var parentSpotId: UUID?
    public var name: String; public var ownerId: UUID?; public var pin: Vec2?; public var sortOrder: Int
    /* timestamps */
}

public struct Measurement: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case opening, wall, door, window, zone, general, unknown }
    public var id: UUID; public var propertyId: UUID; public var label: String; public var kind: Kind
    public var spaceId: UUID?; public var openingId: UUID?; public var storageSpotId: UUID?
    public var pin: Vec2?; public var segment: Segment?
    public var dims: Dims3                             // widthIn/depthIn/heightIn optionals
    public var isDeliveryPath: Bool; public var note: String?; public var source: String
    /* timestamps */
}
public struct Dims3: Hashable, Codable, Sendable { public var width: Double?; public var depth: Double?; public var height: Double? }

public struct Thing: Identifiable, Codable, Sendable {
    public enum Category: String, Codable, Sendable { case appliance, electronic, furniture, fixture, system, unknown }
    public enum Ownership: String, Codable, Sendable { case owned, planned }
    public var id: UUID; public var propertyId: UUID; public var scope: Scope
    public var category: Category; public var name: String; public var ownership: Ownership
    public var templateKey: String?; public var attributes: [String: JSONValue]
    public var brand: String?; public var model: String?; public var serial: String?
    public var purchaseDate: LocalDate?; public var purchasePrice: Money?; public var warrantyEnd: LocalDate?
    public var dims: Dims3; public var fitMeasurementId: UUID?; public var pin: Vec2?; public var notes: String?
    /* timestamps */
}

public struct Chore: Identifiable, Codable, Sendable {
    public var id: UUID; public var propertyId: UUID; public var scope: Scope
    public var title: String; public var notes: String?; public var assigneeId: UUID?
    public var repeatRule: RepeatRule?                 // §9.1
    public var startOn: LocalDate; public var nextDueOn: LocalDate?; public var dueMinutes: Int?
    public var remindEnabled: Bool; public var remindOffsetMin: Int; public var calendarEnabled: Bool
    public var linkedThingId: UUID?; public var isPaused: Bool; public var closedAt: Date?
    /* timestamps */
}
public struct ChoreCompletion: Identifiable, Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case done, skipped }
    public var id: UUID; public var propertyId: UUID; public var choreId: UUID; public var dueOn: LocalDate?
    public var doneAt: Date; public var doneOn: LocalDate; public var doneBy: UUID?; public var outcome: Outcome; public var note: String?
    /* timestamps */
}
public struct ChoreCalendarLink: Identifiable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case series, single }
    public var id: UUID /* == choreId */; public var propertyId: UUID; public var choreId: UUID
    public var ownerDeviceId: String; public var calendarTitle: String; public var calendarSourceTitle: String?
    public var calendarIdentifier: String?; public var eventExternalId: String?; public var eventMode: Mode; public var seriesSignature: String?
    /* timestamps */
}

public struct Project: Identifiable, Codable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable { case idea, planned, inProgress = "in_progress", done }
    public var id: UUID; public var propertyId: UUID; public var scope: Scope
    public var title: String; public var notes: String?; public var status: Status; public var priority: Int?
    public var estCost: Money?; public var actualCost: Money?; public var estHours: Double?; public var actualHours: Double?
    public var targetOn: LocalDate?; public var startedOn: LocalDate?; public var completedOn: LocalDate?
    public var vendor: String?; public var spawnedFromChoreId: UUID?
    /* timestamps */
}
public struct CostLineItem: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case material, labor, permit, other }
    public var id: UUID; public var propertyId: UUID; public var projectId: UUID; public var label: String
    public var amount: Money; public var kind: Kind; public var vendor: String?; public var incurredOn: LocalDate?
    public var hours: Double?; public var receiptAttachmentId: UUID?
    /* timestamps */
}

public struct InventoryItem: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pantry, clothing, stored, other }
    public enum Season: String, Codable, Sendable { case summer, winter, allYear = "all_year" }
    public var id: UUID; public var propertyId: UUID; public var kind: Kind; public var name: String; public var category: String?
    public var ownerId: UUID?; public var scope: Scope; public var storageSpotId: UUID?
    public var quantity: Double; public var unit: String?; public var season: Season?; public var inRotation: Bool?
    public var expiresOn: LocalDate?; public var isLow: Bool; public var lowThreshold: Double?
    public var linkedThingId: UUID?; public var notes: String?
    /* timestamps */
}

public struct Attachment: Identifiable, Codable, Sendable {
    public enum OwnerType: String, Codable, Sendable { case chore, choreCompletion = "chore_completion", project, costLineItem = "cost_line_item", thing, inventoryItem = "inventory_item", measurement, space, level, storageSpot = "storage_spot" }
    public enum Kind: String, Codable, Sendable { case photo, receipt, manual, document, underlay }
    public var id: UUID; public var propertyId: UUID; public var ownerType: OwnerType; public var ownerId: UUID
    public var kind: Kind; public var fileExt: String; public var uti: String; public var byteSize: Int
    public var widthPx: Int?; public var heightPx: Int?; public var sha256: String; public var caption: String?; public var ocrText: String?
    public var capturedAt: Date?
    /* timestamps */
}

/// Cross-kind reference used by "+", search, room sheet, attachments.
public enum ItemRef: Hashable, Sendable {
    case chore(UUID), project(UUID), thing(UUID), inventory(UUID), measurement(UUID)
}
```

**GRDB mapping.**
- `Scope` is stored as three columns. A `Record` wrapper type in `HomeStore` (e.g. `ChoreRecord: Codable, FetchableRecord, MutablePersistableRecord`) converts between the flat columns and the domain struct.
- JSON fields (`attributes`, `repeatRule`, `polygon`, `underlayTransform`, `georef`) are encoded with a shared `JSONEncoder` using `.sortedKeys`, so the stored text is deterministic and diffs cleanly.

---

## 5. CloudKit sync (HomeSync)

### 5.1 Container, zone and records
- **Container:** `iCloud.app.fumble.home`, using `privateCloudDatabase`.
- **Zones:** one per property, `CKRecordZone.ID(zoneName: "property-<propertyUUID>")`. The zone is created with `state.add(pendingDatabaseChanges: [.saveZone(zone)])` when the property is committed.
- **recordName** is the row `id`, so the `CKRecord.ID` is `(recordName: id, zoneID: propertyZone)`.
- **Record types** match the tables in PascalCase: `Property, Level, Space, Opening, Person, StorageSpot, Measurement, Thing, Chore, ChoreCompletion, ChoreCalendarLink, Project, CostLineItem, InventoryItem, Attachment`.
- **Record fields:**
  - Every column except `id` and the local derived caches (`area_sq_in`, bbox) is written as a `camelCase` key.
  - **User-content fields go into `record.encryptedValues`**. That is every field except `propertyId`, `createdAt`, `updatedAt`, `deletedAt` and `schemaVersion`, which stay plain for diagnostics.
  - `schemaVersion: Int64` (plain) is written on every record, so older clients can detect newer data.
- **Type mapping:**

| SQLite | CKRecord value |
|---|---|
| TEXT id / FK | `String` (not `CKRecord.Reference`: avoids CloudKit cascade semantics and the 750-reference limit) |
| TEXT enum / JSON / LocalDate | `String` |
| INTEGER / bool | `Int64` |
| REAL | `Double` |
| DATETIME | `Date` |
| `attachment` binary | `file: CKAsset(fileURL: Attachments/<id>.<ext>)` |

### 5.2 Engine wiring
```swift
actor SyncCoordinator: CKSyncEngineDelegate {
    let db: AppDatabase
    let mappers: RecordMapperRegistry
    var engine: SyncEngineProtocol!                       // wraps CKSyncEngine for tests

    func start() async throws {
        let saved = try await db.read { try SyncStateRecord.fetchOne($0)?.engineState }
        var cfg = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                             stateSerialization: saved.flatMap(decodeState),
                                             delegate: self)
        cfg.automaticallySync = true
        engine = CKSyncEngine(cfg)
        try await reenqueueOutbox()                       // idempotent: every outbox row → state.add(...)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):          persist(e.stateSerialization)
        case .accountChange(let e):        await handleAccountChange(e)            // HLD §5.2
        case .fetchedDatabaseChanges(let e): await applyZoneDeletions(e.deletions)
        case .fetchedRecordZoneChanges(let e): await apply(modifications: e.modifications, deletions: e.deletions)
        case .sentRecordZoneChanges(let e): await handleSent(e)
        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges: break
        @unknown default: break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.buildRecord(for: recordID)        // row + sync_record_meta system fields → CKRecord; nil if row gone
        }
    }
}
```

### 5.3 Local write path (outbox)
Every repository write goes through the same function:
```swift
func save<R: SyncedRecord>(_ record: inout R, in db: Database, origin: WriteOrigin) throws {
    record.updatedAt = clock.now
    let changes = try record.updateChangesAndReturnColumns(db)     // GRDB databaseChanges keys; insert = all columns
    guard origin == .local else { return }                         // sync applies never re-enqueue
    try Outbox.upsert(db, type: R.recordType, name: record.id, zone: record.zoneName,
                      op: .save, addChangedFields: changes)       // union with existing set, local_version += 1
    try SearchIndexer.reindex(db, R.self, id: record.id)           // same transaction
}
// after commit (db.afterNextTransaction): SyncCoordinator.enqueue(recordIDs) → engine.state.add(.saveRecord(id))
```
- **Soft delete** sets `deleted_at` (a save).
- **Hard purge** happens after 30 days. It runs through `Outbox.upsert(op: .delete)` plus a local `DELETE` (children cascade), and the engine sends `.deleteRecord`.

**Sent handling:**
- **Success:** store `encodeSystemFields` in `sync_record_meta`, then delete the outbox row `WHERE local_version = sentVersion`. If the version has moved on, keep the row: newer edits are still pending.
- **`serverRecordChanged`:** merge (§5.4), apply the merged row locally with `origin: .sync`, store the server system fields, **keep** the outbox row with its changed fields, and call `state.add(.saveRecord)` again.
- **`zoneNotFound` / `userDeletedZone`:**
  - `zoneNotFound`: re-create the zone, then re-enqueue every row of that property. This is the recovery path.
  - `userDeletedZone`: the user wiped the data from iCloud settings. Ask the user before re-uploading.
- **`unknownItem` on save:** the record was hard-deleted on the server (a purge). With delete-wins, apply the delete locally. The one exception is a pending local *restore*: the outbox lists `deleted_at` as a changed field and the local value is NULL. In that case, clear the system fields and re-save as a new record.
- **`quotaExceeded`:** pause sync and show a banner in Settings.
- **Transient errors:** the engine retries.

**Apply fetched changes:** each batch runs in one transaction.
1. For each modification, find its mapper by `recordType` and decode it to a row. If a required parent row is missing (e.g. a `space` whose `level_id` doesn't exist), park the record in `sync_orphan` and continue.
2. Upsert with `origin: .sync`. If the row has **pending local changes** (an outbox row exists), use the same merge as for `serverRecordChanged`.
3. Store the system fields.
4. Retry orphans until no progress is made.
5. Recompute derived columns (space area/bbox, `chore.next_due_on` for chores touched by completions) and reindex FTS.
6. After commit, emit `DomainEvent.syncApplied(types:ids:)`.
7. For deletions: hard-delete the local row, then its children cascade.

### 5.4 Merge policy per field
The default rule is the **column overlay**:
- `merged = server`.
- For each column in `outbox.changed_fields`, set `merged[c] = local[c]`.

| Record | Field(s) | Policy |
|---|---|---|
| all | `deleted_at` | **Delete wins.** If the server has `deletedAt != nil` and `deleted_at` is not in local changed_fields, the merged row is deleted. If local set `deleted_at = NULL` explicitly (restore) *after* the server deletion, the restore wins. |
| all | `updated_at` | `max(local, server)` |
| all | `created_at` | `min(local, server)` |
| Space | `polygon_json` | Whole-value overlay (no vertex merge). After the merge, the level's walls are re-derived. |
| Space | `name`, `space_type`, `color_hex` | Overlay (independent of polygon) |
| Chore | `next_due_on` | **Derived when the inputs changed.** If the merge brought new completions or a changed `repeat_rule_json`/`start_on`, recompute it with `RecurrenceEngine` from the latest completion (§9.2). Otherwise it is an ordinary overlay field (a manual "Reschedule"). |
| Chore | `closed_at` | Derived for one-offs: set if a non-deleted completion with outcome done exists. Otherwise overlay (archive). |
| Chore | `repeat_rule_json`, `due_minutes`, `remind_*`, `calendar_enabled` | Overlay. A post-merge `DomainEvent` triggers a replan and a calendar update (owner device only). |
| ChoreCompletion | all | Immutable after creation. A conflict can only be a delete; delete wins. |
| ChoreCalendarLink | `owner_device_id` + `calendar_*` + `event_*` | **Moved as a group.** If any of them changed locally, all of them come from local. This keeps the event reference consistent. |
| Project | `status`, `completed_on` | **Paired.** If either is in local changed_fields, take both from local. After the merge, if `status == done && completed_on == nil`, set `completed_on` from the other side, or today. |
| Project | `actual_cost_cents`, `est_cost_cents`, hours | Overlay |
| CostLineItem | all | Overlay (rows are small and independent) |
| Thing | `attributes_json` | **Key-level overlay.** Parse both JSON objects, and for each key the local edit changed, take local. (The outbox stores `attributes_json.<key>` entries for this.) |
| InventoryItem | `quantity` | Overlay (LWW). A concurrent decrement can be lost; that is accepted at this scale. |
| InventoryItem | `storage_spot_id` + `space_id` + `level_id` + `scope` | Moved as a group (location consistency) |
| Attachment | `file` asset | Immutable. A new photo means a new attachment row. |
| Property | `default_level_id` | Overlay. If the level doesn't exist after the merge, fall back to sort_order 0. |

### 5.5 Account changes
| `CKSyncEngine.Event.AccountChange` | Action |
|---|---|
| `.signIn(currentUser)` with no stored account, or the same account | Mark all rows as pending (full outbox) and ensure the zones exist. |
| `.signOut` | Pause UI sync status ("iCloud off"). Keep the data and keep the outbox growing. |
| `.switchAccounts` | Blocking sheet: "Export CSV" / "Erase and use new account". Erasing deletes the DB file and the attachments, then re-runs the restore check. |

### 5.6 Attachments
- **Write:** save the file to `Attachments/<id>.<ext>`, insert the attachment row (`attachment_local.state = needs_upload`), and let the mapper attach a `CKAsset` pointing at that file.
- **Fetch:** the `CKAsset.fileURL` is a temporary file. Move it into `Attachments/` inside the apply transaction's post-commit hook and set the state to `local`.
- **Size limits:**
  - Photos are downsampled to a 3000 px long edge, HEIC quality 0.8.
  - PDFs are capped at 25 MB (a larger one is rejected with a message).
  - Thumbnails (400 px) are generated locally and never synced.

---

## 6. Geometry (PlanKit)

### 6.1 Core types
```swift
public struct Vec2: Hashable, Codable, Sendable { public var x: Double; public var y: Double }   // inches
public struct Segment: Hashable, Codable, Sendable { public var a: Vec2; public var b: Vec2 }
public struct Polygon: Hashable, Codable, Sendable {
    public private(set) var vertices: [Vec2]            // open ring, normalized winding
    public init(_ v: [Vec2]) throws                     // runs Validation.normalize (§6.2)
    public var edges: [Segment] { get }
    public var bounds: Rect { get }
    public var area: Double { get }                     // sq in, always ≥ 0
}
public struct Rect: Hashable, Codable, Sendable { public var minX, minY, maxX, maxY: Double }
public struct Transform2D: Hashable, Codable, Sendable { public var a, b, c, d, tx, ty: Double }  // affine
public enum Tolerance {
    public static let weld: Double = 3.0          // in: vertex/edge merge at import
    public static let wallMerge: Double = 3.0     // in: render-time coincident edge tolerance
    public static let angleDeg: Double = 1.0      // collinearity
    public static let collinearDrop: Double = 0.25// in: drop near-collinear vertices
    public static let minRoomArea: Double = 4*144 // 4 sq ft
}
```

### 6.2 Invariants and validation (`Validation.normalize`)
1. Remove consecutive duplicates (distance < 0.01 in).
2. Remove near-collinear vertices, i.e. those whose distance to the chord (prev, next) is below 0.25 in.
3. Require at least 3 vertices, and `area >= minRoomArea` (exterior zones: 1 sq ft).
4. Require a simple polygon: no self-intersections. A sweep over the edges is O(n²) at n ≤ 64, which is fine. Anything else throws `.selfIntersecting`.
5. Normalize winding so the shoelace signed area in stored (y-down) coordinates is **positive**, which is visually clockwise on screen.
6. Round coordinates to 0.01 in.
7. **Level-level rule** (checked by `PlanService`, not by `Polygon`): interior spaces on the same level may not overlap by more than 1 sq in (Clipper2 intersection area). Exterior zones may overlap each other and the footprint, because a garden bed can sit inside the backyard.

### 6.3 Area, bounds, containment
- **Area** uses the shoelace formula: `A = ½ Σ (xᵢ·yᵢ₊₁ − xᵢ₊₁·yᵢ)`. Display converts square inches to square feet (÷144) or square meters (× 0.00064516).
- **Point-in-polygon** uses the winding-number rule, with points on an edge (within 0.01 in) counting as inside. A bbox pre-check comes first.
- **Distance to polygon edge** is the min over the edges of the point-to-segment distance. Polylabel and hit-testing use it.

### 6.4 Wall derivation (shared-edge rendering with tolerance merge)
Walls are **derived per level** by `WallDerivation.walls(spaces:openings:) -> [WallSegment]` whenever the level's geometry changes. The result is cached in `LevelRenderModel`.

```swift
public struct WallSegment: Sendable {
    public enum Kind: Sendable { case perimeter, interior }
    public var seg: Segment; public var kind: Kind
    public var thicknessIn: Double          // perimeter 6.0, interior 4.5
    public var gaps: [ClosedRange<Double>]  // param t along seg where openings cut the wall
    public var spaceIds: [UUID]             // 1 (perimeter) or 2+ (interior)
}
```

**Algorithm.** The input is the interior spaces on the level (`is_exterior == 0`). Exterior levels draw no walls; their zones are drawn as fills with a hairline outline.

1. **Collect edges.** Build `E = [(seg, spaceId)]` from every polygon.
2. **Canonicalize direction.** For each edge, compute the angle θ = atan2(dy, dx) folded into [0, π). Flip the edge if needed, so each edge's direction is canonical. Unit direction `u = (cos θ, sin θ)`, normal `n = (−sin θ, cos θ)`, offset `d = n·a`.
3. **Cluster into lines.** Sort the edges by (θ, d). Walk the sorted list, starting a new cluster whenever |Δθ| > 1° (with wraparound near 0 and π) or |Δd| > `wallMerge` (3 in). Each cluster gets a representative line: the length-weighted mean θ and d.
4. **Project to intervals.** For each edge in a cluster, t₀ = u·a and t₁ = u·b (sorted), giving an interval with its owner `spaceId`.
5. **Sweep.** Sort all interval endpoints. For each elementary span [tₖ, tₖ₊₁] of length > 0.5 in, compute `owners`, the set of spaceIds whose interval covers the span.
   - `|owners| >= 2` → **interior** wall.
   - `|owners| == 1` → **perimeter** wall. This includes a room edge facing unmodeled space. It is drawn heavy on purpose, because it nudges the user to add the hallway.
6. **Merge.** Consecutive spans with the same kind (and, for interior, the same owner set) are merged into one `WallSegment`. The segment is mapped back to model space as `a = d·n + t₀·u` and `b = d·n + t₁·u`.
7. **Openings.** For each opening, find the wall segments in the cluster whose line is within `wallMerge` of the opening's segment and whose angle is within 1°. The opening's projected [t₀, t₁] becomes a gap. The opening glyph is drawn in that gap: a door swing arc, or window double lines.
8. **Cost** is O(E log E). At E ≤ 500 this is well under 1 ms.

**Why this is robust.** Most gaps are fixed at import (§6.5 weld). The 3 in render tolerance absorbs the remaining sub-wall-thickness slop, so the renderer never draws two parallel walls a few inches apart for one physical wall.

### 6.5 Import-time weld (RoomPlan, trace, and editor commits)
`Weld.weld(polygons: [Polygon], tolerance: 3.0) -> [Polygon]`:
1. **Vertex clustering.** Put all vertices in a grid hash (cell = tolerance). Union-find joins vertices within `tolerance` that belong to *different* polygons. Each cluster is replaced by its mean.
2. **T-junction snap.** For each vertex v of polygon P and each edge e of every other polygon Q: if dist(v, e) < tolerance and the projection falls strictly inside e, move v onto e **and** insert a copy of v into Q's ring at e. This makes shared sub-edges identical on both sides.
3. **Axis straightening.** For each edge within 1.5° of horizontal or vertical, snap it exactly. Straighten one axis at a time (x for vertical edges, y for horizontal), with shared vertices moving together (a union-find over the vertex ids from step 1).
4. Re-run `Validation.normalize` on every polygon. If a polygon fails, keep its pre-weld version and flag it in the review screen.

### 6.6 Hit-testing
Input: a screen point `p` and the viewport.
1. Convert to model coordinates: `m = viewport.toModel(p)`.
2. Candidates are the spaces whose bbox contains `m`, expanded by `22pt / scale`.
3. **Containment first.** Among the spaces that contain `m`, pick the one with the **smallest area**, so a garden bed wins over the backyard.
4. **Minimum hit radius.** If none contains `m`, pick the space with the smallest edge distance, provided `distance · scale ≤ 22 pt`. This makes closets tappable when zoomed out.
5. **Overlays first.** SwiftUI overlays ("+", pins, chips) receive the tap before the canvas, because they sit on top.
6. **Edit mode:** hit-test vertex handles (22 pt radius), then edges (distance ≤ 16 pt / scale), then the space interior.

### 6.7 "+" and label placement: pole of inaccessibility
`PolyLabel.pole(of: Polygon, precision: 1.0) -> (point: Vec2, radius: Double)`. This is the Mapbox polylabel algorithm, a quadtree search with a priority queue:
1. Start with a cell size of `min(w, h)` over the bbox. Seed the queue with cells covering the bbox, plus the centroid cell and the bbox-center cell.
2. For each cell: `d` = signed distance from the cell center to the polygon (negative outside), and `max = d + half·√2`.
3. Pop the cell with the best `max`. If `max − best.d > precision`, split it into 4 and push the children. Update `best` whenever `d > best.d`.
4. Stop when the queue is empty. Return `best.center` and `best.d`, where `radius` is the inscribed radius.

The result is cached per space, keyed by a hash of `polygon_json`.

**Layout at a given scale s (points per inch):**
- The label block (name, plus the dimension line when it fits) is centered at `pole + (0, −14pt/s)`.
- The "+" (32 pt visible) is centered at `pole + (0, +18pt/s)`.

**Visibility rules** (`r_pt = radius · s`):
| r_pt | Shown |
|---|---|
| ≥ 48 | name + dims + "+" + lens chip |
| 30–48 | name + "+" (dims hidden), chip replaces dims |
| 18–30 | name only (caption2); "+" hidden → the room sheet header shows a "+" |
| < 18 | nothing; the room is still tappable (§6.6) |

The **dimension string** comes from the polygon:
- **Rectangle** (4 vertices, all right angles): `W × H` from its edges, formatted `12'4" × 14'0"`.
- **Other shapes:** the bbox, prefixed with "~".
- **Approximate rooms** always get "~".

### 6.8 Snapping (editor)
`Snapper.snap(candidate: Vec2, context: SnapContext) -> SnapResult`:
```swift
public struct SnapContext {
    var vertices: [Vec2]        // other spaces' vertices on level (excluding dragged)
    var edges: [Segment]        // other spaces' edges
    var gridIn: Double          // 6 (default), 1 (fine: while "Fine" toggle held)
    var scale: Double           // pt per inch (radius conversion)
    var axisOrigin: Vec2?       // for orthogonal constraint when dragging a vertex from a known neighbor
    var orthogonal: Bool        // default true
}
public struct SnapResult { var point: Vec2; var kind: Kind /* vertex, edge, alignment, grid, none */; var guides: [Segment] }
```
The **radius** is `12pt / scale` inches. Candidates are tried in priority order, and the first hit within the radius wins:
1. **Vertex.** The nearest other vertex.
2. **Edge.** The perpendicular projection onto the nearest edge (the result stays on the edge).
3. **Alignment.** The x or y equals some other vertex's x or y, independently per axis. Guide lines are drawn Figma-style.
4. **Grid.** Round to `gridIn`.
5. **Orthogonal constraint.** When on, the dragged vertex's two edges keep their axis alignment; the constraint is solved before steps 1–4, by moving along the allowed axis only.

A haptic `.selectionChanged()` fires each time the snap `kind` or target changes.

**Edge drag (resize):**
1. Move the edge along its normal by δ, which is snapped to the grid and to neighbor edges.
2. Every other space that has a sub-edge coincident with the dragged edge (same cluster in §6.4, overlapping interval) gets that edge moved by the same δ. **Shared walls move together.**
3. Validate all affected polygons. If any fails, the drag is clamped at the last valid δ.

**Typed dimension:** after a tap on a dimension label, entering `12'4"` resizes the room by moving the edge opposite the anchor edge (the left or top edge stays fixed). The parser accepts `12'4"`, `12' 4`, `12.33'`, `148"`, `148in`, `3.76m` and `376cm`. It also upserts a `measurement(kind='wall', source='plan_edit')` for that edge.

**Split and merge:**
- **Split** along a user-drawn orthogonal line uses a Clipper2 intersection with two half-planes.
- **Merge** of two adjacent rooms uses a Clipper2 union. It is accepted only if the result is one simple polygon.

### 6.9 Photo-trace scale calibration
```swift
public struct UnderlayTransform: Codable, Sendable {
    public var inchesPerPixel: Double
    public var rotationRad: Double          // applied about image origin
    public var originIn: Vec2               // where image pixel (0,0) lands in level coords
    public var opacity: Double              // 0.5 default
}
```
1. The image comes from `VNDocumentCameraViewController` (already perspective-corrected) or from PHPicker (a screenshot, taken as-is). It is stored as `attachment(kind='underlay')`, and `level.underlay_attachment_id` is set.
2. The user taps A and B on the image (in pixel coordinates, with a magnifier loupe) and enters length L in inches.
3. The scale is `s = L / |B − A|`. The segment angle is `φ = atan2(B.y − A.y, B.x − A.x)`. If φ is within 5° of a multiple of 90°, set `rotationRad = −(φ − round90(φ))` to straighten the image. Otherwise set 0 and don't auto-rotate.
4. **Optional second calibration.** A second pair (C, D, L₂) on a roughly perpendicular wall gives `s₂`. If `|s − s₂| / s > 5 %`, show a warning: "This image may be stretched. Try the document scanner." With both pairs, use `s = (s + s₂) / 2`.
5. Set `originIn` so that the image center maps to the level's content center (the origin if the level is empty).
6. Mapping from pixel `p` to model: `m = R(rotationRad)·(p·s) + originIn`. The inverse is used when drawing.
7. **Rendering.** The image is drawn first in the Canvas, under the fills, using `context.draw(Image, in: rect)` inside a transformed context: `viewportTransform ∘ T(originIn) ∘ R ∘ S(s)`.

### 6.10 Rough it in (`RoughInGenerator`)
**Input:** `floors: Int` (1–3), `hasBasement: Bool`, `approxSqFt: Int` (total above grade), `bedrooms`, `bathrooms` (with half baths as .5).

1. **Per-floor area.**
   - 1 floor: 100 %.
   - 2 floors: 50/50 (ranch-style layouts stay 1-floor).
   - 3 floors: 40/40/20.
   - Basement: 70 % of the ground floor's area, as a single "Basement" space plus "Utility".
2. **Room lists and weights.**

| Room | Weight | Placement |
|---|---|---|
| Living | 1.00 | ground |
| Kitchen | 0.70 | ground |
| Dining | 0.55 | ground |
| Primary bedroom | 0.85 | top floor (ground if 1 floor) |
| Bedroom (each extra) | 0.60 | top floor, overflow to ground |
| Full bath | 0.25 | 1 on ground if 1 floor else top; extras top |
| Half bath | 0.12 | ground |
| Laundry | 0.18 | ground |
| Hall/Stairs | 12 % of floor area, fixed | each floor (stairs if >1 floor) |
| Garage (optional toggle) | 1.10 | ground, placed on left edge, is_exterior=0 |

3. **Floor rectangle.** Area `A_f` (in sq in); aspect 1.4 : 1, so `W = √(A_f·1.4)`, `H = A_f / W`, both rounded to 6 in.
4. **Squarified treemap** (Bruls, Huizing and van Wijk) of the weights, excluding the hall, over the rectangle minus a hall strip. The hall is a 42 in-wide horizontal strip through the middle (2-story: it holds the stairs), and the rooms are laid out in the two resulting sub-rectangles, split by weight. Every coordinate snaps to 6 in, and any residual goes to the last room in each row.
5. All spaces get `source='rough'`, `is_approximate=1`, and names from the table ("Bedroom 2", …).
6. **Output:** a `PlanDraft`. The result is deterministic for the same input, which golden tests rely on.

Approximate rooms render with dashed walls (`[6, 4]` pt dash) and "~" dimensions. Editing a room's geometry by hand clears its `is_approximate`.

### 6.11 Exterior: projection, footprint and yard seeding
**Local tangent plane (`TangentPlane`).** The origin is the geocoded coordinate (lat₀, lon₀). For small extents (under 500 m) an equirectangular approximation is used:
```
x_m =  (lon − lon0) · cos(lat0·π/180) · 111_320
y_m = −(lat − lat0) · 110_574            // y down = south
x_in = x_m · 39.3701 ;  y_in = y_m · 39.3701
```
```swift
public struct GeoReference: Codable, Sendable {
    public var originLat: Double, originLon: Double
    public var rotationRad: Double        // user "rotate plan" (0 = north up)
}
```

**Overpass request** (one POST to `https://overpass-api.de/api/interpreter`, 15 s timeout, `User-Agent: Home/1.0 (TestFlight; contact@…)`):
```
[out:json][timeout:15];
(
  way(around:40,{lat},{lon})["building"];
  way(around:60,{lat},{lon})["highway"~"^(residential|tertiary|secondary|primary|unclassified|living_street|service)$"];
);
out geom;
```
**Footprint choice:**
1. Take the building ways whose polygon contains the geocoded point. If none does, take the nearest by centroid distance within 25 m.
2. Among several candidates, prefer the one with the largest area that is under 1,500 m². This avoids picking the neighbor's garage.
3. Project the chosen polygon, run `Validation.normalize` on it, and simplify it with Douglas–Peucker at 6 in.

**Road direction.** For each highway way, find the nearest point to the footprint centroid. `frontDir` is the unit vector from the centroid toward that point. If there are no roads, `frontDir = (0, 1)` (screen bottom).

**`YardSeeder.seed(footprint:, frontDir:) -> [SpaceDraft]`**
1. Compute the footprint's **dominant orientation**: the length-weighted histogram of edge angles mod 90° gives α. Build the frame `F` rotated by α so the footprint is axis-aligned. In `F`, choose the "front" side as whichever of the 4 axis directions is closest to `frontDir`, then rotate `F` by a multiple of 90° so the front faces +y (down).
2. In `F`, with the footprint bbox `[x0, x1] × [y0, y1]`, width `w` and depth `dpt`:
   - `front_depth = clamp(dist(centroid, road) − dpt/2 − 8 ft, 15 ft, 60 ft)`, or 25 ft if there is no road.
   - `side = 10 ft`, `back = 30 ft`, `sidewalk = 4 ft` wide.
3. Zones, all rectangles in `F`, then mapped back to level coordinates:

| Zone | Rect in F |
|---|---|
| House footprint | the projected polygon itself (space_type `footprint`, not a rectangle) |
| Front yard | `[x0−side, x1+side] × [y1, y1+front_depth]` minus driveway |
| Driveway | `[x0−side, x0−side+11ft] × [y1, y1+front_depth]` (left side by default) |
| Sidewalk | `[x0−side, x1+side] × [y1+front_depth, y1+front_depth+sidewalk]` |
| Backyard | `[x0−side, x1+side] × [y0−back, y0]` |
| Side yard L | `[x0−side, x0] × [y0, y1]` |
| Side yard R | `[x1, x1+side] × [y0, y1]` |

4. Every zone gets `source='autoseed'` and `is_exterior=1`. Fill tints: lawn green for the yards, hardscape gray for the driveway and sidewalk.
5. **Fallback:** with no footprint, use a 40 × 30 ft rectangle centered at the origin, plus the same zones.

**Satellite snapshot (`SatelliteSnapshotter`).**
- `MKMapSnapshotter.Options`: `preferredConfiguration = MKImageryMapConfiguration()`, `region` = 90 × 90 m around the origin, `size` = 1024 × 1024 pt at scale 2, so 2048 px.
- The result is stored in `Caches/Snapshots/<levelId>.heic` with `region_json`.
- **Drawn under** the zones at 60 % opacity, desaturated 30 %, and rotated by `rotationRad`.
- The pixel ↔ model mapping uses `snapshot.point(for: coordinate)` at the 4 corners, fitted to an affine transform.
- It is regenerated if the cache is missing or older than 180 days.
- The canvas shows "© OpenStreetMap contributors" and the Apple Maps legal attribution (`MKMapSnapshotter` attribution) in the exterior footer.

### 6.12 RoomPlan `CapturedStructure` → `PlanDraft` (`RoomPlanImporter`)
**Capture:**
- `RoomCaptureView` with a single `RoomCaptureSession`, reusing its `ARSession` across rooms on one floor (the iOS 17 multi-room flow).
- After each room, `RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)`.
- At the end of the floor, `StructureBuilder(options: []).capturedStructure(from: rooms)`.
- The raw `CapturedStructure` JSON (it is `Codable`) is kept in a temp file until the user commits, and optionally exported for debugging fixtures from Diagnostics.

**Conversion steps.** RoomPlan works in meters, world-aligned, with y up. The importer produces inches, level coordinates, y down.
1. **Story grouping.** Group `structure.rooms` by `room.story` (iOS 17). Each distinct story becomes a `LevelDraft`, and the user maps stories to floors in the review screen. The default is: lowest story → ground, unless the user started in the basement.
2. **2D projection.** For any `CapturedRoom.Surface` or `Object` with `transform` (simd_float4x4) and `dimensions` (x = width, y = height, z = depth), `center = transform.columns.3.xyz` and `right = normalize(transform.columns.0.xyz)`. A wall's endpoints are `center ± right·(dimensions.x / 2)`. Project to 2D as `(x, z)`, then convert: `x_in = x·39.3701` and `y_in = z·39.3701`. Seen from above (looking down −y), +x is right and +z is screen-down, so no mirroring is needed.
3. **Dominant rotation.** Take every wall's 2D angle mod 90° and build a length-weighted histogram with 1° bins and circular smoothing. The peak is α. Rotate all geometry by −α, then snap each wall angle within 3° of a multiple of 90° to exactly that multiple.
4. **Room polygons**, per `CapturedRoom`:
   - **a. Preferred:** `room.floors.first?.polygonCorners` (iOS 17), mapped through the floor surface's transform into world coordinates, then projected and rotated.
   - **b. Fallback:** build the polygon from the wall centerlines. Extend or trim adjacent walls to their pairwise intersections (walls within 12 in of each other at the endpoints count as adjacent), then extract the outer face of the planar graph (walk it with left-most turns).
   - **c.** If both fail, use the convex hull of the wall endpoints and flag it for review.
5. **Wall-thickness offset.** RoomPlan floor polygons follow the interior faces of the walls, so neighboring rooms sit about 4–6 in apart. Offset every room polygon outward by **2.25 in** (half a typical interior wall) with Clipper2 `InflatePaths`, using a miter join with limit 2, so adjacent rooms meet at the wall centerline.
6. **Weld** (§6.5, tolerance 3 in), then check for overlaps. Overlaps under 1 sq ft are trimmed by clipping the smaller room against the larger one. Larger overlaps are flagged for review.
7. **Names.**
   - **a.** From `structure.sections` (iOS 17, `label`: bedroom, bathroom, kitchen, livingRoom, diningRoom, unidentified): a section whose `center` falls inside the room polygon supplies the name. A space that holds several sections gets the section with the largest share.
   - **b.** Otherwise, fall back to objects: toilet, bathtub or sink plus toilet → "Bathroom"; bed → "Bedroom"; stove, oven, refrigerator or dishwasher → "Kitchen"; sofa plus television → "Living Room"; washerDryer → "Laundry"; stairs → "Stairs"; otherwise "Room N".
   - **c.** Duplicate names get numbered ("Bedroom 2").
8. **Openings.** Each door, window and opening surface becomes an `OpeningDraft`: its 2D segment is (center ± right·w/2), and it is assigned to the nearest room edge within 8 in. `heightIn` is `dimensions.y`, and for windows `sillIn` is the bottom of the surface minus the floor height. **Doors also produce `MeasurementDraft(kind='door', width, height, source='roomplan')`.**
9. **Objects become suggested Things.**

| RoomPlan category | Thing category / template |
|---|---|
| refrigerator | appliance / `refrigerator` |
| stove, oven | appliance / `range` / `wall_oven` |
| dishwasher | appliance / `dishwasher` |
| washerDryer | appliance / `washer` (user splits) |
| television | electronic / `tv` |
| sofa, bed, table, chair, storage | furniture / matching template |
| fireplace | system / `fireplace` |
| sink, toilet, bathtub | fixture / matching template |
| stairs | not a Thing; stored as a level-alignment hint |

   Each suggestion gets `dims = dimensions` (w, d, h in inches) and `pin` = its projected center. **The user must accept each one** on the review screen ("We found a refrigerator in Kitchen. Add it?"); none is added automatically.
10. **Multi-floor alignment.** Stories captured in one `StructureBuilder` pass share a world frame, so they align automatically. Floors captured in separate sessions are aligned in a review step: the user drags the new floor over the ghosted floor below, or taps 2 matching points (the stairs are suggested). The result is a rigid 2D transform.
11. The output is a `PlanDraft` with `source='roomplan'`. The raw per-room `CapturedRoom` is **not** persisted in v1 (it is large). A v2 3D view would need a re-scan or opt-in storage.

### 6.13 `PlanDraft` (shared contract for all four paths)
```swift
public struct PlanDraft: Sendable, Codable {
    public var levels: [LevelDraft]
    public var source: Space.Source
}
public struct LevelDraft: Sendable, Codable {
    public var tempId: UUID; public var name: String; public var kind: Level.Kind; public var sortOrder: Int
    public var spaces: [SpaceDraft]; public var openings: [OpeningDraft]
    public var suggestedThings: [ThingDraft]; public var measurements: [MeasurementDraft]
    public var underlay: UnderlayDraft?; public var georef: GeoReference?
    public var warnings: [DraftWarning]      // .overlap(spaceIds), .weldFailed(spaceId), .hullFallback(spaceId)
}
public protocol PlanCommitting: Sendable {
    /// One write transaction. Maps temp IDs → UUIDs, validates level rules, inserts rows + outbox + FTS, creates zone.
    func commit(_ draft: PlanDraft, into property: UUID, acceptedSuggestions: Set<UUID>) async throws -> [Level.ID]
}
```

---

## 7. Canvas renderer (PlanCanvas)

### 7.1 Viewport
```swift
public struct Viewport: Equatable, Sendable {
    public var scale: Double          // points per inch
    public var origin: CGPoint        // screen position of model (0,0)
    public var size: CGSize           // canvas size in points
    public var obscuredBottom: CGFloat// room-sheet height (keeps selection visible)

    public func toScreen(_ p: Vec2) -> CGPoint { CGPoint(x: origin.x + p.x*scale, y: origin.y + p.y*scale) }
    public func toModel(_ p: CGPoint) -> Vec2  { Vec2(x: (p.x-origin.x)/scale, y: (p.y-origin.y)/scale) }
    public var affine: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y) }
    public var visibleModelRect: Rect { get }

    public static func fit(_ bounds: Rect, in size: CGSize, insets: EdgeInsets) -> Viewport
    public mutating func zoom(by factor: Double, anchor: CGPoint, limits: ClosedRange<Double>)
        // s' = clamp(s·factor); origin' = anchor − (anchor − origin)·(s'/s)
    public mutating func pan(by delta: CGSize)
    public func focusing(on rect: Rect, padding: CGFloat) -> Viewport   // double-tap and sheet-aware selection
}
```
- **Zoom limits:** `[fitScale·0.8, max(fitScale·8, 12.5)]`. At 12.5 pt/in, one foot is 150 pt.
- **Rotation** is applied only on the exterior level (the `georef.rotationRad` model transform), never as a gesture.
- **Gestures:** `SpatialTapGesture` (select), a double tap (focus room), `DragGesture(minimumDistance: 4)` (one-finger pan) and `MagnifyGesture` (anchor = `startAnchor`, mapped to the view), running simultaneously. The last pan velocity drives a momentum decay (τ = 325 ms, like UIScrollView) through a `TimelineView(.animation)` that runs only while decaying.
- **Sheet awareness.** When the room sheet opens at the half detent, `obscuredBottom` is set, and if the selected room's bbox is hidden the viewport animates with `focusing(on:)`.

### 7.2 Render model and redraw strategy
**Split: expensive work on change, cheap work per frame.**
```swift
public struct LevelRenderModel: Sendable {          // built off-main; immutable
    public var levelId: UUID; public var bounds: Rect
    public var spaces: [SpaceRender]                 // id, polygon, cgPath (model coords), bbox, pole, radius, name, dimsText, isApprox, fillStyle
    public var walls: [WallSegment]
    public var openings: [OpeningGlyph]
    public var underlay: UnderlayRender?             // CGImage + transform
    public var lens: LensDecorations                 // per-space badge/tint/edge + pins + footer (from §7.4)
    public var version: Int
}
actor RenderModelBuilder {
    func build(level: Level, spaces: [Space], openings: [Opening], lensStats: LensStats, lens: PlanLens) -> LevelRenderModel
}
```
**Rebuild triggers:**
- a GRDB `ValueObservation` on this level's `space`/`opening` rows (geometry)
- lens-stats observation (§7.4): only the `lens` part is rebuilt, and geometry is reused
- a lens change
- a Dynamic Type change (the text cache is invalidated)

**Per-frame Canvas closure.** The model, not the Canvas view, owns state, so the closure reads a `@State` viewport and the current `LevelRenderModel`.
```swift
Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
    let t = viewport.affine
    let visible = viewport.visibleModelRect.insetBy(-24/viewport.scale)
    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.background))
    if let u = model.underlay, u.visible { drawUnderlay(ctx, u, t) }                 // 1
    for s in model.spaces where s.bbox.intersects(visible) {                          // 2 fills + lens tint
        let p = s.cgPath.applying(t)
        ctx.fill(p, with: .color(model.lens.tint[s.id] ?? theme.roomFill(s.fillStyle)))
    }
    drawWalls(ctx, model.walls, t, scale: viewport.scale, visible)                    // 3 (screen-space widths)
    drawOpenings(ctx, model.openings, t, visible)                                     // 4
    for s in visibleSpaces { if let e = model.lens.edge[s.id] { ctx.stroke(s.cgPath.applying(t), with: .color(e.color), style: e.style) } } // 5
    drawLabels(ctx, visibleSpaces, viewport, textCache)                               // 6 LOD per §6.7
    if isEditing { drawEditorGuides(ctx, editorState, t) }                             // 7
}
```
- **Stroke widths are in screen space.** Perimeter walls use `clamp(6in·scale, 2.0, 9.0)` pt and interior walls `clamp(4.5in·scale, 1.25, 6.0)` pt. The butt cap is extended by half the width at the ends so corners join cleanly. Dashed strokes are used for approximate spaces.
- **Text cache.** `TextCache` keys are `(string, fontStyle, sizeBucket)`, and entries are `GraphicsContext.ResolvedText`. The cache is **per frame-context**, because resolved text can't outlive its context. The expensive part (measuring) is memoized as `CGSize` in the model instead. The font size stays constant in points and never scales with zoom (listing-plan look); LOD rules hide labels that don't fit.
- **Culling:** everything is bbox-tested against `visibleModelRect`.
- **Budget check:** 60 spaces, 300 walls and 60 labels come to about 500 path operations, which fits the Canvas budget of ≤ 4 ms (HLD §5.4). If profiling fails the budget, the fallback is `PlanRenderer` protocol → `LayerPlanRenderer` (a `UIViewRepresentable` with one `CAShapeLayer` per space and wall batch, where transforms move layers without re-tessellating).
- **Theme:**
  - Light: white fills, charcoal walls (#2B2B2B).
  - Dark: the blueprint look, navy (#0F1B2D) with white lines.
  - Exterior tints: lawn #CFE8C4, hardscape #D9D9D9, mulch #E6D3B3, and their dark-mode equivalents.

### 7.3 Overlays
Overlays are SwiftUI views in a `ZStack` above the `Canvas`:
- `AddButtonOverlay`: one 32 pt "+" per visible space that passes the §6.7 radius rule.
- `ChipOverlay`: the lens chip (count, "$4.2k", "!"), placed under the name.
- `PinOverlay`: Things and storage-spot pins (SF Symbols such as `refrigerator`, `tv`, `sofa`, `lightbulb`, `fan`, `flame`, `sensor`, `shippingbox`), drawn at `toScreen(pin)`. Pins closer than 20 pt to each other cluster into a count bubble.
- `WholeHouseChip`: fixed top-left under the pills. It shows property-scope and level-scope items for the active lens ("Whole house · 3", "This floor · 1").

**Position updates.** Each overlay's `.position(viewport.toScreen(anchor))` depends on the viewport. If more than 40 overlays are visible, chips and pins fade out (0.12 s) while a pinch is in progress and come back when it ends. "+" buttons stay visible.

### 7.4 Lens protocol and the 7 lenses
```swift
public enum LensID: String, CaseIterable, Sendable { case plan, todos, future, past, things, inventory, budget }

public protocol PlanLens: Sendable {
    var id: LensID { get }
    var title: LocalizedStringResource { get }
    var symbol: String { get }                               // SF Symbol for menu
    var addDefault: AddKind? { get }                         // "+" preselection; nil → picker without preselect
    /// Observed query (GRDB) returning per-space and per-level stats for a level.
    func statsRequest(levelId: UUID, today: LocalDate) -> LensStatsRequest
    func badge(_ s: SpaceStats) -> Badge?                    // chip text + style
    func tint(_ s: SpaceStats, scale: LensScale) -> Color?   // nil = default fill
    func edge(_ s: SpaceStats) -> EdgeStyle?                 // e.g. overdue red
    func pins(_ s: LevelStats) -> [Pin]
    func footer(_ s: LevelStats, property: PropertyStats) -> String
    func accessibilityValue(_ s: SpaceStats) -> String
}
public enum AddKind: Sendable { case todo, futureProject, pastWork, thing, inventory, measurement }
```

| Lens | Stats predicate (SQL in §8 and §7.5) | Badge / chip | Tint | Edge | Pins | Footer strip | "+" default |
|---|---|---|---|---|---|---|---|
| **Plan** | none (geometry only) | none. The label shows name + dims | none (listing white) | none | none | "1st Floor · 1,240 sq ft · 9 rooms" | none (picker with no preselection) |
| **To-Dos** | `chore` open (`closed_at IS NULL`, not paused, not deleted), `next_due_on <= today+6` | count due this week; bold if any are due today; "!" if overdue | none | **red 3 pt** if overdue > 0 | none | "7 due this week · 2 overdue" (floor) | To-Do |
| **Future Projects** | `project.status IN (idea, planned, in_progress)` | "$4.2k" planned (est of planned + in progress). Ideas with no planned cost show "3 ideas" | Sequential single-hue ramp by planned $ relative to the max room on the level (5 buckets, 0 = no tint) | none | none | "$18.4k planned · 3 in progress" | Future Project |
| **Past Work** | `project.status = done` | "$12.1k · Mar '26" (lifetime spent + last `completed_on`) | Light ramp by lifetime spent | none | none | "$41.7k spent on this floor since 2019" | Past Work |
| **Appliances, Electronics & Furniture** | `thing` (owned; planned ones shown dashed) | count | none | none | **SF Symbol per template at `pin`**. Things without a pin sit in a row under the label | "23 items · 2 warranties end in 60 days" | Thing |
| **Inventory** | `inventory_item` by `space_id` (spot descendants included via denormalized space_id) | count; an orange dot if any is low | none | none | storage spots with a pin (`shippingbox` + count) | "142 items · 5 low · 3 expiring" | Inventory item |
| **Budget** | all non-deleted projects | "$4.2k / $1.1k" (planned / spent) | Ramp by planned + spent | none | none | "Floor: $18.4k planned / $6.2k spent · Home: $52k / $48k" | Future Project |

`LensScale` is computed per level: the max of the metric across spaces, so tints are relative within the floor. Budget uses the property max, so floors are comparable.

### 7.5 Lens stats queries (examples)
To-Dos per space on a level (`:weekEnd` = today + 6):
```sql
SELECT space_id,
       SUM(next_due_on <  :today)                   AS overdue,
       SUM(next_due_on =  :today)                   AS due_today,
       SUM(next_due_on BETWEEN :today AND :weekEnd) AS due_week
FROM chore
WHERE level_id = :levelId AND scope = 'space'
  AND deleted_at IS NULL AND closed_at IS NULL AND is_paused = 0 AND next_due_on IS NOT NULL
GROUP BY space_id;
```
Things with pins on a level:
```sql
SELECT id, space_id, template_key, category, pin_x, pin_y, ownership
FROM thing WHERE level_id = :levelId AND deleted_at IS NULL;
```
Inventory per space:
```sql
SELECT space_id, COUNT(*) AS items, SUM(is_low) AS low,
       SUM(expires_on IS NOT NULL AND expires_on <= :todayPlus7) AS expiring
FROM inventory_item WHERE level_id = :levelId AND scope = 'space' AND deleted_at IS NULL
GROUP BY space_id;
```
Future Projects, Past Work and Budget use the rollup CTE in §8.

### 7.6 Canvas accessibility
```swift
canvas.accessibilityChildren {
    ZStack(alignment: .topLeading) {                      // children laid out in canvas coordinates
        ForEach(model.spaces) { s in
            let r = viewport.toScreen(s.bbox)               // CGRect
            Color.clear
                .frame(width: max(r.width, 44), height: max(r.height, 44))
                .position(x: r.midX, y: r.midY)
                .accessibilityElement()
                .accessibilityLabel(s.name)
                .accessibilityValue(lens.accessibilityValue(stats[s.id]))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onSelect(s.id) }
                .accessibilityAction(named: "Add item") { onAdd(s.id) }
                .accessibilityAction(named: "Rename") { onRename(s.id) }
        }
    }
}
```
- The **list mirror** (`PlanListView`) is backed by the same `LevelRenderModel`, and it is the default when `UIAccessibility.isVoiceOverRunning`.
- The **rotor** has a custom "Rooms with overdue chores" entry.

---

## 8. Budget rollup queries

### 8.1 Definitions
Money never mixes planned and actual figures in one number.
- **est:** `project.est_cost_cents`, with 0 when NULL.
- **spent:** `COALESCE(project.actual_cost_cents, SUM(cost_line_item.amount_cents), 0)`. The UI keeps `actual_cost_cents` NULL while line items drive the total. When the user types an actual cost, it overrides the line items.
- **Planned (open):** Σ est where status ∈ {planned, in_progress}.
- **Ideas:** Σ est where status = idea. Shown separately, never added to Planned.
- **Spent:** Σ spent where status ∈ {in_progress, done}.
- **Remaining:** Σ max(est − spent, 0) over in_progress projects, plus Σ est over planned projects.
- **Variance (done):** Σ spent − Σ est over done projects that have an estimate.
- **Hours:** the same shapes, using `est_hours` and `COALESCE(actual_hours, SUM(line.hours))`.
- **Scope roll-up:**
  - **Room** = projects with `scope='space'` and that `space_id`.
  - **Floor** = the rooms on that level plus `scope='level'` projects on it.
  - **Property** = all floors plus `scope='property'` projects.

### 8.2 Shared CTE
```sql
WITH li AS (
  SELECT project_id, SUM(amount_cents) AS li_cents, SUM(hours) AS li_hours
  FROM cost_line_item WHERE deleted_at IS NULL GROUP BY project_id
),
p AS (
  SELECT pr.id, pr.scope, pr.space_id, pr.level_id, pr.status, pr.completed_on,
         COALESCE(pr.est_cost_cents, 0)                          AS est,
         COALESCE(pr.actual_cost_cents, li.li_cents, 0)          AS spent,
         (pr.est_cost_cents IS NOT NULL)                         AS has_est,
         COALESCE(pr.est_hours, 0)                               AS est_h,
         COALESCE(pr.actual_hours, li.li_hours, 0)               AS spent_h
  FROM project pr LEFT JOIN li ON li.project_id = pr.id
  WHERE pr.property_id = :propertyId AND pr.deleted_at IS NULL
)
```
The aggregate column block below is referred to as **AGG**:
```sql
  SUM(CASE WHEN status IN ('planned','in_progress') THEN est ELSE 0 END)                 AS planned_cents,
  SUM(CASE WHEN status = 'idea' THEN est ELSE 0 END)                                     AS idea_cents,
  SUM(CASE WHEN status IN ('in_progress','done') THEN spent ELSE 0 END)                  AS spent_cents,
  SUM(CASE WHEN status = 'planned' THEN est
           WHEN status = 'in_progress' THEN MAX(est - spent, 0) ELSE 0 END)              AS remaining_cents,
  SUM(CASE WHEN status = 'done' AND has_est THEN spent - est ELSE 0 END)                 AS variance_cents,
  SUM(CASE WHEN status = 'done' THEN spent ELSE 0 END)                                   AS lifetime_cents,
  MAX(CASE WHEN status = 'done' THEN completed_on END)                                   AS last_completed_on,
  SUM(CASE WHEN status IN ('planned','in_progress') THEN est_h ELSE 0 END)               AS planned_hours,
  SUM(CASE WHEN status IN ('in_progress','done') THEN spent_h ELSE 0 END)                AS spent_hours,
  SUM(status IN ('planned','in_progress'))                                               AS open_count,
  SUM(status = 'in_progress')                                                            AS in_progress_count
```
(The two-argument `MAX(a, b)` is SQLite's scalar max, not the aggregate.)

### 8.3 Room rollup (for one level; feeds the Future, Past and Budget lenses)
```sql
<shared CTE>
SELECT space_id, AGG
FROM p WHERE scope = 'space' AND level_id = :levelId
GROUP BY space_id;
```

### 8.4 Floor rollup (footer strip; "This floor" chip = the `level` row)
```sql
<shared CTE>
SELECT CASE WHEN scope = 'space' THEN 'rooms' ELSE 'floor_wide' END AS part, AGG
FROM p WHERE level_id = :levelId
GROUP BY part
UNION ALL
SELECT 'floor_total', AGG FROM p WHERE level_id = :levelId;
```

### 8.5 Property rollup (Budget drill-down: per floor plus whole-house plus total)
```sql
<shared CTE>
SELECT COALESCE(p.level_id, '__property__') AS bucket, AGG
FROM p GROUP BY bucket
UNION ALL
SELECT '__total__', AGG FROM p;
```
The Swift layer joins the level names and orders buckets by `level.sort_order`, with `__property__` shown as "Whole house". The drill-down goes property → floor (§8.5) → room (§8.3) → project list.

**Performance:** the indexes `project_level_status`, `project_space_status` and `cost_line_item_project` cover these queries. At 2k projects and 10k line items each one runs in under 5 ms. The queries run through GRDB `ValueObservation.tracking` over `project` and `cost_line_item`, so any write re-emits.

---

## 9. Recurrence engine, notifications and calendar

### 9.1 Repeat rule format (`chore.repeat_rule_json`)
```swift
public struct RepeatRule: Codable, Hashable, Sendable {
    public enum Freq: String, Codable, Sendable { case daily, weekly, everyNDays, monthly }
    public enum Anchor: String, Codable, Sendable { case schedule, completion }
    public var freq: Freq
    public var interval: Int                 // ≥ 1 (every N days / weeks / months)
    public var weekdays: [Int]?              // weekly only; 1 = Sunday … 7 = Saturday (Calendar.weekday); default [weekday(startOn)]
    public var dayOfMonth: Int?              // monthly only; 1…31, or -1 = last day
    public var anchor: Anchor                // default: .schedule, except everyNDays → .completion
    public var until: LocalDate?             // optional series end
}
```
Examples:
```json
{"freq":"daily","interval":1,"anchor":"schedule"}                                  // Do the dishes
{"freq":"weekly","interval":1,"weekdays":[3,6],"anchor":"schedule"}                // Trash: Tue + Fri
{"freq":"everyNDays","interval":90,"anchor":"completion"}                          // HVAC filter
{"freq":"monthly","interval":1,"dayOfMonth":-1,"anchor":"schedule"}                // Last day of month
{"freq":"monthly","interval":12,"dayOfMonth":1,"anchor":"schedule"}                // Yearly detector battery
```
A NULL rule means a one-off task. Completing it sets `closed_at` and clears `next_due_on`.

### 9.2 `RecurrenceEngine` (pure, HomeCore)
```swift
public struct RecurrenceEngine: Sendable {
    public let calendar: Calendar            // Gregorian, injected (tests fix firstWeekday + timeZone)

    /// Schedule-anchored occurrences on or after `from`, in order (lazy).
    public func occurrences(of rule: RepeatRule, start: LocalDate, from: LocalDate) -> some Sequence<LocalDate>

    /// First due date for a new chore.
    public func firstDue(rule: RepeatRule?, start: LocalDate) -> LocalDate?

    /// Next due after an action. `currentDue` = chore.next_due_on before the action.
    public func nextDue(rule: RepeatRule, start: LocalDate, currentDue: LocalDate, actedOn: LocalDate) -> LocalDate?
}
```
**Occurrence math** for schedule-anchored rules, with k ≥ 0:
- **daily / everyNDays:** `start + k·interval` days.
- **weekly:** the weeks `w` where `weeksBetween(weekStart(start), w) % interval == 0` (week start = `calendar.firstWeekday`), and within those weeks the days in `weekdays`, on or after `start`.
- **monthly:** the months `m` where `monthsBetween(start.month, m) % interval == 0`. The day is `dayOfMonth == -1 ? lastDay(m) : min(dayOfMonth, lastDay(m))`, so the 31st clamps to the 30th, or to Feb 28/29.

**Next due:**
```
nextDue(rule, start, currentDue, actedOn):
  switch rule.anchor
  case .completion:
      base = actedOn
      d = switch freq { daily, everyNDays: base + interval days
                        weekly:            base + 7·interval days
                        monthly:           addMonthsClamped(base, interval) }
  case .schedule:
      pivot = max(currentDue, actedOn)                     // collapse missed occurrences
      d = first occurrence(rule, start) strictly > pivot
  return (rule.until != nil && d > rule.until) ? nil : d   // nil ⇒ series finished ⇒ closed_at = now
```
- **Skip** uses the same formula, with a completion row whose `outcome='skipped'`.
- **Derivation after a sync merge:** `next_due_on` is recomputed only when the merge brought in new completions or a changed `repeat_rule_json`/`start_on`. The latest completion by `done_at` supplies `(currentDue: c.due_on ?? c.done_on, actedOn: c.done_on)`. A manual "Reschedule to…" sets `next_due_on` as an ordinary overlay field.
- **Test matrix:**
  - DST weeks (US spring forward and fall back)
  - Feb 29
  - the 31st
  - `until` boundaries
  - completing early, late, and 3 cycles late
  - weekly with several weekdays, where completion falls mid-week

### 9.3 Local notifications: planner (pure) + scheduler
**Constraint:** iOS keeps at most **64 pending** local notification requests per app, keeping the soonest ones. The budget is split into:
- **60 slots** for chore reminders.
- **4 reserved slots:**
  - `sys:sentinel`
  - `sys:pantry-digest`
  - `sys:snooze-<n>` ×2. There are at most 2 concurrent snoozes; a third replaces the oldest.

```swift
public struct PlannedNotification: Hashable, Sendable {
    public var id: String                    // "chore:<uuid>:<yyyy-MM-dd>" | "sys:sentinel" | ...
    public var fire: DateComponents          // year, month, day, hour, minute — floating (no timeZone)
    public var title: String; public var body: String
    public var categoryId: String            // "CHORE_DUE"
    public var threadId: String              // "chore:<uuid>" (groups in Notification Center)
    public var contentHash: Int              // title+body+fire; stored in userInfo["h"]
}

public struct NotificationPlanner: Sendable {
    public static let choreSlots = 60, horizonDays = 14, perChoreMax = 14
    public func plan(chores: [ChoreReminderInput], snoozes: [Snooze], pantryDigest: PantryDigest?,
                     now: Date, calendar: Calendar, engine: RecurrenceEngine) -> [PlannedNotification]
}
```
**Algorithm:**
1. **Eligible chores:** `remind_enabled`, not paused, not closed, not deleted, and `next_due_on` set.
2. **Fire time per occurrence** is `date + (due_minutes ?? 540) − remind_offset_min` (all-day chores default to 9:00).
   - **Overdue** (`next_due_on < today`): one "Overdue: <title>" reminder at today's fire time if that's still ahead, otherwise tomorrow's.
   - **Schedule-anchored:** `next_due_on` and the following occurrences from `engine.occurrences`, within `now … now+14d`, capped at `perChoreMax`.
   - **Completion-anchored:** only `next_due_on`. The later ones depend on when the chore is completed.
3. **Fairness.** Each candidate gets `rank = (occurrenceIndex, fireDate)`. Sort by rank and take the first 60, so every chore gets its *next* reminder before any chore gets its second. Then sort those 60 by fire date.
4. **Sentinel.** If any candidate was dropped, add `sys:sentinel` at the earliest dropped fire time minus 1 minute: "Open Home to keep your reminders coming."
5. **Pantry digest** (opt-in): `sys:pantry-digest` at 9:00 tomorrow if items expire within 3 days.
6. **Snoozes:** active ones come from the local `notification_snooze` table (below).

The `notification_snooze` table is defined in `v1_local` (§3.3).

**Scheduler (actor, HomeSchedule):**
```swift
public actor ReminderScheduler: ReminderScheduling {
    public func replan(reason: ReplanReason) async   // debounced 500 ms, coalesces reasons
}
```
**Diff:**
1. Read `pending = await center.pendingNotificationRequests()` and keep only the requests whose id starts with `chore:` or `sys:`.
2. **Remove** the ids that are not in the desired set, or whose `userInfo["h"]` differs from the desired hash.
3. **Add** the desired requests that are missing, each with `UNCalendarNotificationTrigger(dateMatching: fire, repeats: false)`. `repeats` is never true, because the planner owns repetition.
4. On completion, also call `removeDeliveredNotifications(withIdentifiers:)` for that chore's past ids.

**Replan triggers:**
- app launch, and `scenePhase == .active`
- any chore or completion write (`DomainEvent`)
- a sync apply that touches chores
- `NSSystemTimeZoneDidChange` and `significantTimeChangeNotification`
- a notification action
- the BGAppRefresh task

**Actions:** the category `CHORE_DUE` has these actions:
- `DONE` ("Done", background): the `UNUserNotificationCenterDelegate.didReceive` handler runs `ChoreService.complete(choreId, by: nil, at: now)` and replans, then calls the completion handler within about 5 s.
- `SNOOZE_1H` ("In 1 hour"): inserts a snooze row and replans.
- Tapping the notification body deep-links to `home://chore/<uuid>`.

**Background refresh:** `BGAppRefreshTaskRequest(identifier: "app.fumble.home.refresh")`, with `earliestBeginDate = now + 12h` and a new request scheduled at the end of each run. The task body:
- replan
- `CalendarSync.reconcileOwned()`
- purge soft-deleted rows older than 30 days
- expire snoozes

**Authorization:** `requestAuthorization(options: [.alert, .sound, .badge])` is requested only when the first reminder is switched on. If it is denied, the toggle shows "Notifications are off for Home" with a link to Settings. The badge count is set to the number of chores due today plus overdue on each replan (`setBadgeCount`, iOS 17).

### 9.4 Stored notification identifiers
The identifier is deterministic, so no table is needed: `chore:<choreUUID>:<yyyy-MM-dd>`, or `...:overdue` for the overdue nudge. This makes the diff idempotent across launches and devices. Each device plans its own notifications, and a completion that syncs in from another device removes the pending ones through replan.

### 9.5 EventKit calendar events
**Access and calendar choice**
- Access uses `try await store.requestFullAccessToEvents()`, and the app requires `.fullAccess` (write-only can't find, update or delete events).
- The calendar picker lists `store.calendars(for: .event).filter(\.allowsContentModifications)`, grouped by `calendar.source.title`: "iCloud", "Gmail – you@…", "Exchange"… Google calendars appear here when the account is added in iOS Settings.
- **"Create 'Home' calendar"** is offered first:
  - `EKCalendar(for: .event, eventStore:)` with `source` = the iCloud CalDAV source, or `.local` if there isn't one, and `cgColor` = the app tint. Then `saveCalendar(_:commit:)`.
  - If saving to the chosen source fails (typical for Google), fall back to picking an existing calendar.
  - The last choice is remembered as the default for new chores (`UserDefaults`).

**Event content**

| EKEvent field | Value |
|---|---|
| `title` | chore.title |
| `notes` | chore.notes + "\n\nManaged by Home" |
| `url` | `home://chore/<uuid>` (**dedupe key** and deep link) |
| `isAllDay` | `due_minutes == nil` |
| `startDate` | `next_due_on` at `due_minutes` in the current calendar (all-day: start of day) |
| `endDate` | start + 30 min (all-day: same day) |
| `timeZone` | `nil`, i.e. **floating**, to match ADR-18 |
| `alarms` | none by default: the app's own notification already alerts, so there's no double buzz. The option "Also alert from Calendar" adds `EKAlarm(relativeOffset: -remind_offset_min*60)` |
| `recurrenceRules` | per the table below |

**Rule mapping**

| RepeatRule | EKRecurrenceRule | Mode |
|---|---|---|
| daily(i), schedule | `EKRecurrenceRule(recurrenceWith: .daily, interval: i, end: until.map(EKRecurrenceEnd.init(end:)))` | series |
| everyNDays(N), schedule | `.daily`, interval N | series |
| weekly(i, days), schedule | `EKRecurrenceRule(recurrenceWith: .weekly, interval: i, daysOfTheWeek: days.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: …)` | series |
| monthly(i, day), schedule | `.monthly`, interval i, `daysOfTheMonth: [NSNumber(value: day)]` (−1 = last day is supported by EventKit) | series |
| any rule, anchor = completion | none (single event at `next_due_on`) | single |
| one-off (no rule) | none | single |

The series `startDate` is the **current `next_due_on`** when the event is created, so past events are never back-filled.

**Operations** (`CalendarSync`, owner device only):

| Trigger | Series mode | Single mode |
|---|---|---|
| Calendar toggled on | Create the event. `save(event, span: .futureEvents, commit: true)`. Write `chore_calendar_link` (owner = this device, `event_external_id = event.calendarItemExternalIdentifier`, `series_signature`) and `calendar_event_cache.event_identifier` | Same, no recurrence |
| Chore edited (signature changes: title, time, rule, notes) | Resolve the **next occurrence on or after today** (below). Apply the changes to it (rule too), then `save(occ, span: .futureEvents)`. EventKit splits the series, so **past occurrences keep their old details** | Update the single event |
| Calendar changed | Remove future events from the old calendar (as in "deleted"), then create in the new one | Same |
| Chore completed | No change (the series already holds the next date) | If the linked event is in the future, move it to the new `next_due_on`. Otherwise leave it as history and create a new single event at the new due date, then update the link |
| Chore paused, calendar toggled off, or chore deleted | Resolve the next occurrence on or after today, then `remove(occ, span: .futureEvents)`. **Past occurrences stay.** Delete the link (soft) | Remove if it's in the future; otherwise leave it |
| Chore resumed | Create a new series from `next_due_on` | Create |

**Event resolution (robust against identifier churn):**
1. `store.event(withIdentifier: cache.event_identifier)`, if cached.
2. `store.calendarItems(withExternalIdentifier: link.event_external_id)`, filtered to `EKEvent` with a matching `url`.
3. `store.events(matching: predicateForEvents(withStart: today−7d, end: today+400d, calendars: [linkCalendar]))`, filtered by `url == home://chore/<uuid>`, earliest on or after today.
4. **If nothing is found**, treat it as *deleted by the user in the Calendar app*: set `chore.calendar_enabled = 0`, soft-delete the link, and show the note "Removed from your calendar outside Home". The app never silently re-creates events.
5. Refresh `calendar_event_cache` and `link.event_external_id` on every successful resolution.

**One-way sync.** The app is the master. Changes made in the Calendar app to time or title are not imported. On `.EKEventStoreChanged` (debounced 2 s), the app runs `reconcileOwned()`, which only detects deletions (step 4) and calendar removal.

**Owner device**
- `device_id` is a UUID created on first launch and stored in the Keychain (`kSecAttrSynchronizable = false`), so it survives reinstalls.
- Non-owner devices do **not** touch EventKit for that chore. The chore form shows "Calendar events are managed on 'Matt's iPhone'" with the button **Manage from this iPhone**, which does:
  - `owner_device_id = mine`
  - resolve by external id or URL
  - if not found, create a fresh series from `next_due_on`
- The device name comes from `UIDevice.current.name` (on iOS 16+ this returns the generic "iPhone" unless the app has the entitlement). The link row therefore stores a user-editable device nickname, entered once in Settings and cached in `app_meta`.

---

## 10. Fit check (`FitChecker`, pure)

```swift
public struct FitPolicy: Sendable {
    public var clearance: (width: Double, depth: Double, height: Double)   // total inches added to item
    public var rotatable: Bool           // may swap width/depth (furniture yes, front-facing appliances no)
    public var depthMayProtrude: Bool    // appliances may stick out past counter depth → warning not failure
    public static func `default`(templateKey: String?, category: Thing.Category) -> FitPolicy
}
public enum AxisVerdict: Sendable { case fits(spare: Double), tight(spare: Double), tooBig(by: Double), protrudes(by: Double), unknown }
public struct FitResult: Sendable {
    public var width: AxisVerdict, depth: AxisVerdict, height: AxisVerdict
    public var rotated: Bool
    public var overall: Overall          // .fits, .tight, .noFit, .unknown  (worst axis; protrudes counts as .tight)
    public var message: String           // "36 in wide won't fit the 32 in opening (5 in short incl. clearance)"
}
public struct FitChecker: Sendable {
    public var tightTolerance: Double = 0.25
    public func check(item: Dims3, into target: Dims3, policy: FitPolicy) -> FitResult
    public func passThrough(item: Dims3, door: Dims3) -> FitResult      // door: width × height
}
```

**Default policy table** (the user can edit clearances per item):

| template / category | clearance w / d / h (in) | rotatable | depth may protrude |
|---|---|---|---|
| refrigerator | 1.0 / 1.0 / 1.0 | no | yes |
| range, wall_oven, cooktop | 0 / 0 / 0 | no | yes (range) / no (wall oven) |
| dishwasher | 0.25 / 0 / 0.25 | no | no |
| washer, dryer | 1.0 / 4.0 / 0 | no | yes |
| tv (wall) | 2.0 / – / 2.0 | no | – |
| furniture (any) | 0 / 0 / 0 | **yes** | no |
| other | 0 / 0 / 0 | no | no |

**Algorithm:**
```
check(item I, target T, policy P):
  orientations = P.rotatable ? [(I.w, I.d), (I.d, I.w)] : [(I.w, I.d)]
  for (w, d) in orientations:
     vW = axis(need: w + P.cw, have: T.width)
     vD = axis(need: d + P.cd, have: T.depth, protrudeOK: P.depthMayProtrude)
     vH = axis(need: I.h + P.ch, have: T.height)
     score = min spare across known axes (tooBig negative)
  choose orientation with max score; rotated = (chosen is swapped)
axis(need, have, protrudeOK=false):
  if need == nil || have == nil → .unknown
  spare = have − need
  spare ≥ tol        → .fits(spare)
  0 ≤ spare < tol    → .tight(spare)
  spare < 0          → protrudeOK ? .protrudes(−spare) : .tooBig(−spare)
overall = worst of (tooBig → noFit) > (tight | protrudes → tight) > fits; all unknown → unknown
```

**Pass-through (delivery path):**
- Sort the item dims ascending as a ≤ b ≤ c. The item is carried with its longest dimension c along the direction of travel.
- It **fits** if `a ≤ door.width` and `b ≤ door.height`. It is **tight** if either margin is under 0.25 in, and **noFit** otherwise.
- Tilting sofas diagonally through a door (the "sofa diagonal" rule) is out of scope for v1.
- The check runs against every `measurement` with `is_delivery_path = 1` (by default, the exterior door measurement created by RoomPlan, or the one the user flags).

**Where it runs:**
- in `ThingForm`, live as dimensions change
- in the room sheet for planned Things
- when a `measurement` changes (all Things whose `fit_measurement_id` points to it)

Results are **never stored**.

---

## 11. Storage spots and inventory queries

### 11.1 Path of every spot (top-down build, no `group_concat` ordering issues)
```sql
WITH RECURSIVE path(id, space_id, depth, label) AS (
  SELECT id, space_id, 0, name
  FROM storage_spot WHERE parent_spot_id IS NULL AND deleted_at IS NULL
  UNION ALL
  SELECT c.id, c.space_id, p.depth + 1, p.label || ' › ' || c.name
  FROM storage_spot c JOIN path p ON c.parent_spot_id = p.id
  WHERE c.deleted_at IS NULL AND p.depth < 32
)
SELECT path.id, path.label, sp.name AS room, lv.name AS floor
FROM path JOIN space sp ON sp.id = path.space_id JOIN level lv ON lv.id = sp.level_id
WHERE sp.property_id = :propertyId;
```
The display string is `"<room> › <label>"`, e.g. "Attic › Shelf 2 › Bin Winter – Matt". The floor is added only when room names are ambiguous.

### 11.2 Subtree (descendants) of a spot, used for move, delete, counts and the cycle guard
```sql
WITH RECURSIVE sub(id, depth) AS (
  SELECT :spotId, 0
  UNION ALL
  SELECT s.id, sub.depth + 1 FROM storage_spot s JOIN sub ON s.parent_spot_id = sub.id
  WHERE s.deleted_at IS NULL AND sub.depth < 32
)
SELECT id FROM sub;
```
- **Re-parent guard:** reject a move if `:newParentId IN (subtree(:spotId))`, or if the new parent is in a different space. (Moving a spot to another room moves its whole subtree and updates the denormalized `inventory_item.space_id` and `level_id` of the items inside.)
- **Items in a subtree:** `SELECT * FROM inventory_item WHERE storage_spot_id IN (subtree) AND deleted_at IS NULL`.
- **Deleting a spot** asks: "Move N items to <parent or room>?" Then soft-delete the subtree.

### 11.3 "Where is…" (item → location)
```sql
WITH RECURSIVE path(...) AS (/* §11.1 */)
SELECT i.id, i.name, pe.name AS owner, sp.name AS room, lv.name AS floor, path.label AS spot_path
FROM inventory_item i
LEFT JOIN path   ON path.id = i.storage_spot_id
LEFT JOIN space sp ON sp.id = i.space_id
LEFT JOIN level lv ON lv.id = i.level_id
LEFT JOIN person pe ON pe.id = i.owner_id
WHERE i.id IN (:ids) AND i.deleted_at IS NULL;
```

### 11.4 Seasonal swap
- `Season.upcoming(on: LocalDate, latitude: Double) -> InventoryItem.Season`, northern hemisphere (southern shifts by 6 months):
  - Mar–Aug → `.summer`
  - Sep–Feb → `.winter`
- The screen has two lists: **"Get out"** (`season = upcoming AND in_rotation = 0`) and **"Put away"** (`season = opposite(upcoming) AND in_rotation = 1`). Both are grouped by owner, then room and spot path.
- "Swap all" flips `in_rotation` in one transaction and leaves the location unchanged. A prompt offers "Move put-away items to a spot…".

```sql
WITH RECURSIVE path(...) AS (/* §11.1 */)
SELECT i.id, i.name, i.category, pe.name AS owner, sp.name AS room, path.label AS spot_path
FROM inventory_item i
LEFT JOIN path ON path.id = i.storage_spot_id
LEFT JOIN space sp ON sp.id = i.space_id
LEFT JOIN person pe ON pe.id = i.owner_id
WHERE i.property_id = :pid AND i.kind = 'clothing' AND i.deleted_at IS NULL
  AND i.season = :season AND i.in_rotation = :inRotation
ORDER BY owner, room, spot_path, i.name;
```

### 11.5 Shopping list
```sql
SELECT 'low' AS reason, i.id AS ref_id, 'inventory_item' AS ref_type, i.name AS label, i.quantity, i.unit
FROM inventory_item i
WHERE i.property_id = :pid AND i.is_low = 1 AND i.deleted_at IS NULL
UNION ALL
SELECT 'replacement_due', t.id, 'thing',
       t.name || COALESCE(' – ' || json_extract(t.attributes_json, '$.filterSize'),
                          ' – ' || json_extract(t.attributes_json, '$.bulbBase'), ''),
       NULL, NULL
FROM chore c JOIN thing t ON t.id = c.linked_thing_id
WHERE c.property_id = :pid AND c.deleted_at IS NULL AND c.closed_at IS NULL
  AND c.next_due_on <= :todayPlus14
  AND t.template_key IN ('hvac_furnace','hvac_filter','water_filter','light_fixture','smoke_detector','fridge_water_filter')
  AND NOT EXISTS (SELECT 1 FROM inventory_item s
                  WHERE s.linked_thing_id = t.id AND s.quantity > 0 AND s.deleted_at IS NULL);
```
`is_low` is set by the user, or automatically by the repository when `low_threshold IS NOT NULL AND quantity <= low_threshold`.

---

## 12. Search (FTS5)

### 12.1 Index rows (maintained by `SearchIndexer` inside each write transaction)
| entity_type | title | body | location | people |
|---|---|---|---|---|
| `chore` | title | notes, linked thing name, rule text ("every 90 days") | "Kitchen · 1st Floor" / "Whole house" | assignee |
| `project` | title | notes, vendor, line-item labels, status, receipt `ocr_text` | room · floor | – |
| `thing` | name | brand, model, serial, template display name, attribute values ("E26 2700K", "16x25x1 MERV 11"), notes | room · floor | – |
| `inventory_item` | name | category, season, notes, unit | "<room> › <spot path> · <floor>" | owner |
| `measurement` | label | formatted dims ("32 × 40 in"), note | room · floor | – |
| `space` | name | space type, formatted dims | floor | – |
| `storage_spot` | name | – | "<room> › <path>" | owner |

**Cascading reindex** (in the same transaction):
- Renaming a space reindexes its spots and every item scoped to it.
- Renaming or moving a spot reindexes the items in its subtree.
- Renaming a person reindexes everything that person owns or is assigned.
- Deleting (soft) an entity removes its FTS row, and restoring it re-adds the row.

**Full rebuild** happens when `app_meta.fts_version` is behind the code constant, and from Diagnostics. It takes about 200 ms at 10k rows.

### 12.2 Query
The query is built by `SearchService`:
1. Normalize with NFKC and lowercase. Strip the FTS syntax characters `"*():^-+`.
2. Split on whitespace and drop empty tokens.
3. Turn each token into `"tok"*` (a prefix match) and join them with spaces, which means AND.
4. If there are no results, retry with ` OR `.

```sql
SELECT entity_type, entity_id, title, location,
       snippet(search_fts, 1, '', '', '…', 8)       AS body_snippet,
       bm25(search_fts, 10.0, 1.0, 3.0, 2.0)          AS rank
FROM search_fts
WHERE search_fts MATCH :q AND property_id = :pid
ORDER BY rank
LIMIT 50;
```
- Results are grouped by entity type in the UI.
- **The "where is" answer card:** if the top result is an `inventory_item` or `storage_spot` with a non-empty location, it is shown as a card: "**Winter coat** → Attic › Bin 3 (Matt)". Tapping it switches to that floor, selects the room, and flashes the spot pin.
- Latency: under 50 ms at 10k rows. The query runs on each keystroke with a 120 ms debounce.

---

## 13. CSV export

**Output:** `Home-Export-YYYY-MM-DD.zip`. It is made by writing CSVs into a temp folder, then `NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading)`, which gives a zipped copy without a third-party zip library. The zip is shared through `ShareLink`.

**Format rules:**
- RFC 4180, CRLF line endings, UTF-8 **with BOM** (so Excel opens it correctly).
- A header row with snake_case names.
- Fields containing a comma, quote or newline are quoted, and quotes are doubled.
- Dates are ISO 8601: `YYYY-MM-DD` for local dates, and `YYYY-MM-DDTHH:MM:SSZ` for instants.
- Money is a decimal major-unit string (`4612.00`) plus a `currency` column.
- Lengths are in inches with 2 decimals, plus a `*_display` column in the user's units (`12'4"`).
- IDs are included for re-import in a later version.
- Soft-deleted rows are excluded.

| File | Columns |
|---|---|
| `spaces.csv` | id, floor, name, type, is_exterior, area_sq_ft, width_display, depth_display, source, is_approximate |
| `chores.csv` | id, title, room, floor, scope, assignee, repeat (human text, e.g. "Every 90 days after done"), next_due_on, due_time, reminder_on, calendar_on, linked_thing, paused, closed_at, notes |
| `chore_completions.csv` | id, chore_id, chore_title, due_on, done_at, done_by, outcome, note |
| `projects.csv` | id, title, room, floor, scope, status, est_cost, actual_cost, spent_effective, currency, est_hours, actual_hours, target_on, started_on, completed_on, vendor, spawned_from_chore, notes |
| `cost_line_items.csv` | id, project_id, project_title, label, kind, amount, currency, vendor, incurred_on, hours, receipt_file |
| `things.csv` | id, category, name, ownership, room, floor, template, brand, model, serial, purchase_date, purchase_price, warranty_end, width_in, depth_in, height_in, attributes_json, notes |
| `inventory.csv` | id, kind, name, category, owner, floor, room, spot_path, quantity, unit, season, in_rotation, expires_on, is_low, linked_thing, notes |
| `measurements.csv` | id, label, kind, floor, room, attached_to (door/window/spot), width_in, depth_in, height_in, width_display, depth_display, height_display, delivery_path, note |
| `storage_spots.csv` | id, floor, room, path, owner |
| `people.csv` | id, name |
| `budget_summary.csv` | bucket (Room / Floor / Whole house / Total), floor, room, planned, ideas, spent, remaining, variance, planned_hours, spent_hours |
| `attachments/` (optional toggle, off by default) | original files named `<owner_type>-<owner_id>-<attachment_id>.<ext>` |

A `README.txt` in the zip explains the files and the units.

---

## 14. Key protocols and interfaces

```swift
// ── Time / identity ───────────────────────────────────────────────
public protocol Clock: Sendable { var now: Date { get }; var calendar: Calendar { get } }
public protocol DeviceIdentity: Sendable { var deviceId: String { get }; var nickname: String { get } }

// ── Persistence ────────────────────────────────────────────────────
public enum WriteOrigin: Sendable { case local, sync }
public protocol SyncedRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable where ID == UUID {
    static var recordType: String { get }             // "Chore"
    var propertyId: UUID { get }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
}
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public static func open(at url: URL) throws -> AppDatabase
    public static func inMemory() throws -> AppDatabase   // tests
    public func write<T>(origin: WriteOrigin, _ body: @Sendable (Database) throws -> T) async throws -> T
    public func read<T>(_ body: @Sendable (Database) throws -> T) async throws -> T
    public func observe<T: Sendable>(_ region: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T>
}

// ── Domain services ────────────────────────────────────────────────
public protocol PlanServicing: Sendable {
    func levels(property: UUID) -> AsyncValueObservation<[Level]>
    func renderInput(level: UUID) -> AsyncValueObservation<LevelGeometry>     // spaces + openings + underlay
    func updateSpaces(_ changes: [SpaceChange]) async throws                  // validates level rules, weld on commit
    func renameSpace(_ id: UUID, to name: String) async throws
    func deleteSpace(_ id: UUID, reassignItemsTo: Scope) async throws
    func setDefaultLevel(_ id: UUID) async throws
}
public protocol ChoreServicing: Sendable {
    func create(_ draft: ChoreDraft) async throws -> Chore
    func update(_ chore: Chore) async throws
    func complete(_ id: UUID, by person: UUID?, at: Date) async throws -> ChoreCompletion
    func skip(_ id: UUID, at: Date) async throws
    func reschedule(_ id: UUID, to: LocalDate) async throws
    func turnIntoProject(_ id: UUID) async throws -> Project                  // sets spawned_from_chore_id
    func delete(_ id: UUID) async throws
}
public protocol ProjectServicing: Sendable {
    func create(_ draft: ProjectDraft) async throws -> Project
    func setStatus(_ id: UUID, _ status: Project.Status) async throws         // non-done transitions
    func markDone(_ id: UUID, actual: Money?, completedOn: LocalDate, hours: Double?, receipt: AttachmentDraft?) async throws
    func reopen(_ id: UUID) async throws                                      // done → in_progress, keeps actuals
    func upsertLineItem(_ item: CostLineItem) async throws
}
public protocol ThingServicing: Sendable { func create(_ d: ThingDraft) async throws -> Thing; func update(_ t: Thing) async throws; func fit(for id: UUID) async throws -> [FitReport] }
public protocol InventoryServicing: Sendable {
    func create(_ d: InventoryDraft) async throws -> InventoryItem
    func move(_ ids: [UUID], to spot: UUID?) async throws
    func adjustQuantity(_ id: UUID, by delta: Double) async throws
    func spotTree(space: UUID) -> AsyncValueObservation<[SpotNode]>
    func seasonalSwap(on: LocalDate) -> AsyncValueObservation<SeasonalSwap>
    func shoppingList(on: LocalDate) -> AsyncValueObservation<[ShoppingLine]>
    func reparentSpot(_ id: UUID, to parent: UUID?) async throws               // cycle guard §11.2
}
public protocol BudgetServicing: Sendable {
    func rooms(level: UUID) -> AsyncValueObservation<[UUID: Rollup]>
    func floor(level: UUID) -> AsyncValueObservation<FloorRollup>
    func property(_ id: UUID) -> AsyncValueObservation<PropertyRollup>
}
public protocol SearchServicing: Sendable { func search(_ text: String, property: UUID) async throws -> [SearchHit] }
public protocol ExportServicing: Sendable { func exportCSV(property: UUID, includeAttachments: Bool) async throws -> URL }

// ── Pure engines (HomeCore) ────────────────────────────────────────
// RecurrenceEngine §9.2, NotificationPlanner §9.3, FitChecker §10, Season §11.4

// ── Scheduling adapters ────────────────────────────────────────────
public protocol NotificationCenterProtocol: Sendable {               // wraps UNUserNotificationCenter
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ r: UNNotificationRequest) async throws
    func removePending(_ ids: [String]); func removeDelivered(_ ids: [String])
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
}
public protocol ReminderScheduling: Sendable { func replan(reason: ReplanReason) async }

public protocol CalendarStoreProtocol: Sendable {                    // wraps EKEventStore
    func requestFullAccess() async throws -> Bool
    func writableCalendars() -> [CalendarInfo]
    func createHomeCalendar() throws -> CalendarInfo
    func event(identifier: String) -> EKEvent?
    func events(externalIdentifier: String) -> [EKEvent]
    func events(in calendarId: String, from: Date, to: Date) -> [EKEvent]
    func save(_ e: EKEvent, span: EKSpan) throws
    func remove(_ e: EKEvent, span: EKSpan) throws
}
public protocol CalendarSyncing: Sendable {
    func enable(chore: UUID, calendarId: String) async throws
    func choreChanged(_ id: UUID) async
    func choreCompleted(_ id: UUID) async
    func disable(chore: UUID) async
    func adoptOwnership(chore: UUID) async throws
    func reconcileOwned() async
}

// ── Sync ───────────────────────────────────────────────────────────
public protocol SyncEngineProtocol: AnyObject, Sendable {             // CKSyncEngine or test fake
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func fetchChanges() async throws
    func sendChanges() async throws
}
public protocol RecordMapper: Sendable {
    associatedtype Row: SyncedRecord
    static var recordType: String { get }
    func record(from row: Row, systemFields: Data?, zone: CKRecordZone.ID) -> CKRecord
    func row(from record: CKRecord) throws -> Row
    func parentKeys(of record: CKRecord) -> [(type: String, id: UUID)]      // for orphan parking
    func merge(server: CKRecord, local: Row, changedFields: Set<String>) -> Row   // §5.4
}

// ── Capture / exterior ─────────────────────────────────────────────
public protocol PlanDraftProducing: Sendable { }                         // marker for the 4 paths
public protocol RoomPlanImporting: Sendable { func draft(from s: CapturedStructure, storyMap: [Int: Level.Kind]) throws -> PlanDraft }
public protocol RoughInGenerating: Sendable { func draft(_ input: RoughInInput) -> PlanDraft }
public protocol BlockTemplating: Sendable { func draft(style: HouseStyle, beds: Int, baths: Double) -> PlanDraft }
public protocol PhotoTraceCalibrating: Sendable { func calibrate(a: CGPoint, b: CGPoint, lengthIn: Double, second: (CGPoint, CGPoint, Double)?) -> Result<UnderlayTransform, TraceWarning> }
public protocol ReceiptReading: Sendable { func read(_ images: [CGImage]) async throws -> ReceiptGuess }   // §15
public protocol AddressResolving: Sendable { func resolve(_ query: String) async throws -> ResolvedAddress }
public protocol FootprintProviding: Sendable {                            // Overpass now; Render proxy later
    func footprint(near: CLLocationCoordinate2D) async throws -> FootprintResult?   // polygon + nearest road point
}
public protocol SatelliteSnapshotting: Sendable { func snapshot(center: CLLocationCoordinate2D, spanMeters: Double) async throws -> SnapshotImage }

// ── Canvas ─────────────────────────────────────────────────────────
public protocol PlanRenderer {                                           // Canvas impl now; CALayer fallback
    func render(_ model: LevelRenderModel, viewport: Viewport, editing: EditorState?) -> AnyView
}
// PlanLens: §7.4

// ── Events ─────────────────────────────────────────────────────────
public enum DomainEvent: Sendable {
    case created(ItemRef), updated(ItemRef), deleted(ItemRef)
    case choreCompleted(UUID), geometryChanged(levelId: UUID)
    case syncApplied(recordTypes: Set<String>, ids: Set<UUID>)
    case timeZoneChanged
}
public protocol DomainEventBus: Sendable { func publish(_ e: DomainEvent); var events: AsyncStream<DomainEvent> { get } }
```

---

## 15. Receipt OCR (`ReceiptReader`)
1. **Capture** with `VNDocumentCameraViewController`. Each page becomes a `CGImage` and is also saved as one PDF attachment (`kind='receipt'`).
2. **Recognize** with `VNRecognizeTextRequest`: `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, and `recognitionLanguages = ["en-US"]` plus the user's locale. Observations are sorted top to bottom, and the full text is joined into `attachment.ocr_text`, which is indexed for search.
3. **Parse** (`ReceiptParser`, pure, table-tested on 30 sample receipts):
   - **Amounts:** match the regex `(?<!\d)\$?\s?(\d{1,3}(,\d{3})*|\d+)\.\d{2}(?!\d)`.
   - **Total:** the largest amount on lines matching `(?i)\b(grand\s+)?total\b|amount\s+due|balance\s+due`. If there are none, use the largest amount in the bottom 40 % of the page.
   - **Date:** the first `NSDataDetector(.date)` hit that is ≤ today and within the last 5 years.
   - **Vendor:** the first line in the top 20 % of the page that has 3–40 characters, at least 50 % letters, and no amount.
4. **Pre-fill** the Done sheet or line item with the parsed values, each marked "From receipt – check". Nothing is saved without the user confirming.
