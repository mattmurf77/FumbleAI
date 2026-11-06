# home-server

Backend helper for the Home Blueprint iPhone app. Node 22, one dependency (`pg`, pinned in `package-lock.json`).
It serves public planning content, appliance templates, OpenStreetMap footprint lookups, privacy/support pages,
and feedback users choose to send. Feedback is the only information persisted in Render Postgres. It includes
the category, submitted text, page name, app/iOS version, device model, random installation identifier and
optional random submission identifier. A submission identifier makes retries safe after a lost response.
The service does not receive household tasks, project budgets, documents, OCR output or inventory for planning.
Those workflows run in the app's repositories. See [backend coverage](../docs/homeowner-app/product/backend-coverage.md).
Deploy: see `docs/setup/RENDER.md` (Blueprint in `/render.yaml`).

## Run and test

```sh
cd server
npm ci               # installs pg
node --test          # unit + HTTP tests; Overpass is mocked
PORT=10000 node src/index.js
```

## Environment

| Name | Required | Meaning |
|---|---|---|
| `PORT` | set by Render | Listen port (default 10000) |
| `HOME_API_KEY` | optional | If set, every `/v1/*` request must send header `X-Home-Key: <value>` (401 otherwise). `/health` is always open. |
| `OVERPASS_CONTACT` | optional | Contact email put in the Overpass `User-Agent`, per the OSM usage policy. |
| `OVERPASS_URLS` | optional | Comma-separated Overpass endpoints tried in order. Default: `overpass-api.de`, then `overpass.private.coffee`. |
| `OVERPASS_TIMEOUT_MS` | optional | Per-mirror timeout, default 15000. |
| `DATABASE_URL` | for feedback | Postgres connection string (Render wires the internal one from the `home-blueprint-db` database). Unset → `POST /v1/feedback` answers `503 feedback_unavailable`. The `feedback` table is created at startup if missing. |
| `DATABASE_SSL` | optional | `true`/`false` to force TLS to Postgres. Default: TLS only for external `*.render.com` hosts (the internal URL needs none). |
| `HOME_ADMIN_KEY` | for admin | Password for `GET /v1/feedback`, `PATCH /v1/feedback/:id` and `/admin/feedback`: header `X-Home-Admin-Key` or `?key=`. Unset → those routes are `404`. |
| `FEEDBACK_RATE_LIMIT` | optional | Feedback posts per install id per hour (default 30; per IP it's 2× this). |

Local run with feedback: `DATABASE_URL=postgres://localhost/home HOME_ADMIN_KEY=dev node src/index.js`.

Set `HOME_TEST_DATABASE_URL` to a disposable test database to also run the real PostgreSQL migration,
concurrent retry and conflict tests. The tests use a temporary schema and remove it afterward. Never use a
production database. GitHub's Server tests workflow provides a disposable PostgreSQL 17 service.

## Public privacy and support pages

The helper serves public `GET` and `HEAD` routes at `/privacy` and `/support`. Both pages work without an API key, database or map service. Home Blueprint bundles the same `data/product-pages.json` for offline reading under Settings › About. Set `HOME_SUPPORT_EMAIL` to a monitored address approved for publication to offer an email contact to people who cannot open the app. The service displays the address on both public pages.

For release, publish the updated helper using the existing deployment procedure. Confirm both URLs return 200 from a signed-out browser and that the public contact works. Use those verified HTTPS URLs for App Store Connect’s Privacy Policy URL and Support URL. An app configured with that HTTPS helper origin also links to the online pages. Rebuild the app when updating the bundled copy.

## API

### `GET /health`
`200 {"ok":true,"version":"1.0.0+<commit>","cacheEntries":0}`

### `GET /v1/footprint?lat=<lat>&lon=<lon>`
Runs the LLD §6.11 Overpass query (buildings within 40 m, roads within 60 m) at the coordinate rounded
to 5 decimals, and applies the footprint choice (contains the point, else nearest centroid within 25 m;
largest under 1,500 m²). Cached in memory for 24 h per rounded coordinate (LRU, 500 entries).

```json
{
  "query": {"lat": 40.0, "lon": -75.0},
  "building": {"osmId": 123, "polygon": [[40.00001, -75.00002], ...], "areaM2": 142.3,
               "containsPoint": true, "buildingType": "house"},
  "roads": [{"osmId": 9, "name": "Elm St", "highway": "residential", "distanceM": 21.4,
             "polyline": [[lat, lon], ...]}],
  "candidateCount": 3,
  "cached": false,
  "attribution": "© OpenStreetMap contributors (ODbL)"
}
```

- `polygon` is an **open** ring (the closing vertex is not repeated), `[lat, lon]` pairs.
- `roads` are sorted nearest first; `name` falls back to `ref`, else `null`.
- `404 {"error":"no_building", "building":null, "roads":[...], ...}` when no building qualifies (roads still included, so the app can orient its 40×30 ft fallback block).
- `400` bad/missing coordinates · `401` wrong `X-Home-Key` · `502 upstream_unavailable` · `503 upstream_rate_limited` (with `Retry-After`). Errors are not cached.

### `GET /v1/templates`
Serves `data/templates.json` (appliance/thing templates from product spec 06, clearances from spec 07,
repeat rules in LLD §9.1 format). Has a `version` string and an `ETag` (send `If-None-Match` for a `304`).
Edit the JSON and bump `version` to publish new templates.

### `POST /v1/feedback` (app → server)
Header `X-Home-Key` when `HOME_API_KEY` is set. JSON body (max 32 KB; unknown fields ignored):

```json
{"category": "bug", "message": "The plan jumps when I pinch.", "page": "Plan · Ground floor",
 "screenContext": {"lens": "plan"}, "appVersion": "1.0", "buildNumber": "42", "osVersion": "17.5",
 "deviceModel": "iPhone15,2", "installId": "6f1c…"}
```

- `category` (required): `bug` | `polish` | `idea`. `message` (required): trimmed, 1–5,000 characters.
- Optional `X-Home-Request-ID: <UUID>` identifies this submission. The iPhone queues and reuses the same UUID
  on retries. Repeating the same normalized content returns the original `id` and `createdAt`, including
  concurrent retries. Reusing the UUID with different content returns `409 idempotency_conflict`. Requests
  from older apps without this header retain the original behavior. A request UUID grants no read access.
- Optional strings: `page` (≤ 200), `appVersion`, `buildNumber`, `osVersion` (≤ 50), `deviceModel`, `installId` (≤ 100). `screenContext`: a JSON object (≤ 4 KB).
- `201 {"id": "<uuid>", "createdAt": "<ISO 8601>"}` · `400 bad_request` · `401` · `413 payload_too_large` ·
  `429 rate_limited` (with `Retry-After`; 30/hour per install id, 60/hour per IP) · `503 feedback_unavailable`
  (no `DATABASE_URL`) · `503 database_unavailable` (Postgres unreachable; the app keeps it queued and retries).

### Admin (needs `HOME_ADMIN_KEY`; `404` when unset, `401` on a wrong key)
Send `X-Home-Admin-Key: <key>` or add `?key=<key>`. The app key is not accepted here.

- `GET /v1/feedback?status=new|triaged|done&category=bug|polish|idea&limit=1..500` (default 100) →
  `{"items": [{id, createdAt, category, message, page, screenContext, appVersion, buildNumber, osVersion, deviceModel, installId, status}], "count": n}`, newest first.
- `PATCH /v1/feedback/<id>` with `{"status": "new" | "triaged" | "done"}` → the updated item, or `404`.
- `GET /admin/feedback?key=…&status=&category=&limit=` → read-only HTML list, newest first, with filter links (default limit 200; `no-store`, `noindex`).

Table (created with `CREATE TABLE IF NOT EXISTS` on startup; `gen_random_uuid()` is built into Postgres 13+):
`feedback(id uuid pk, created_at timestamptz, category text check in (bug, polish, idea), message text 1..5000,
page text, screen_context jsonb, app_version text, build_number text, os_version text, device_model text,
install_id text, status text default 'new' check in (new, triaged, done))`, index on `created_at desc`.
The additive migration also creates nullable `request_id uuid` with a unique index, preserving existing rows.

### `GET /v1/catalog`

Versioned public planning content from `data/home-catalog.json`, validated before the service starts.
`HEAD` is supported. Requests pass the same optional app-key gate as templates. Responses include a strong
SHA-256 `ETag`, `Last-Modified`, `Cache-Control: private, max-age=3600` and `Vary: X-Home-Key`.
Matching conditional requests return `304` without a body. A database is not required.

Schema 1 contains six known recommendations, DIY supplies/equipment, 25 cost guides, source URLs and review
dates, public contractor directories, and the existing scope-specific closet cost-recovery assumption.
Prices use integer minor units, explicit units, country/currency, cost basis and scope. A professional hourly
rate cannot replace a whole-job price. Maintenance has no numeric resale assumption. `referralPartners` must
remain empty in this schema. No partner agreement, provider verification or homeowner lead is implied.

The iPhone bundles the same file and refreshes recommendation guides in the background at most every six
hours per process. It validates the complete response, rejects redirects/older publications/unsupported
schemas, and retains its last valid cache or bundled fallback when offline. It sends no home data. Updated
content never overwrites an owner's saved worksheet, budget, quote, actual spending or shopping selections.
The custom worksheet engine currently uses its bundled scope/rate defaults; the corresponding 13 catalog
guides expose the same definitions for future consumers without changing calculation behavior.

To update content, retain the supported IDs and price units, verify the sources and scope, update each
changed source's `reviewedOn`, advance the catalog `reviewedOn`, `publishedAt` and date/revision `version`, and
run server plus Swift catalog parity/validation tests. Deploy the helper after checks pass. New calculation
types or compensated referral integrations require an app/schema change; a content update cannot add them.
