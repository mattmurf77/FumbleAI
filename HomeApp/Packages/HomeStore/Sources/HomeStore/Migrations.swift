import Foundation
import GRDB

/// Schema migrations (LLD §3). Append-only: a shipped migration is never edited. The SQL below is the LLD text
/// verbatim (comments stripped from the FTS5 declaration, whose module arguments must not contain comments).
enum Migrations {
    static let v1Core = "v1_core"
    static let v1Local = "v1_local"
    static let v1Search = "v1_search"

    /// Current FTS index layout version (`app_meta.fts_version`). Bump to force a rebuild on launch.
    static let ftsVersion = 1

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration(v1Core) { db in try db.execute(sql: coreSQL) }
        m.registerMigration(v1Local) { db in try db.execute(sql: localSQL) }
        m.registerMigration(v1Search) { db in try db.execute(sql: searchSQL) }
        return m
    }

    // MARK: v1_core — synced domain tables (LLD §3.2)
    static let coreSQL = #"""
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
"""#

    // MARK: v1_local — local-only tables, never synced (LLD §3.3)
    static let localSQL = #"""
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
"""#

    // MARK: v1_search — FTS5, local-only and rebuildable (LLD §3.4)
    static let searchSQL = #"""
CREATE VIRTUAL TABLE search_fts USING fts5(
  title,
  body,
  location,
  people,
  entity_type UNINDEXED,
  entity_id   UNINDEXED,
  property_id UNINDEXED,
  tokenize = 'porter unicode61 remove_diacritics 2',
  prefix   = '2 3'
);
"""#
}
