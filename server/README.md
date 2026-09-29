# home-server

Tiny stateless helper for the Home iPhone app. Node 22, no dependencies. Stores **no user data**:
the only state is an in-memory cache of public OpenStreetMap lookups, wiped on every restart.
Deploy: see `docs/setup/RENDER.md` (Blueprint in `/render.yaml`).

## Run and test

```sh
cd server
node --test          # unit + HTTP tests, Overpass is mocked
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
