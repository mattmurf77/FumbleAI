// OpenStreetMap Overpass lookup: query building, footprint choice and normalization.
// Query and choice rules follow docs/homeowner-app/design/lld.md §6.11.

export const DEFAULT_OVERPASS_URLS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

const BUILDING_RADIUS_M = 40;
const ROAD_RADIUS_M = 60;
const NEAREST_MAX_M = 25;
const MAX_HOUSE_AREA_M2 = 1500;
const ROAD_CLASSES =
  '^(residential|tertiary|secondary|primary|unclassified|living_street|service)$';

export class UpstreamError extends Error {
  /** @param {string} message @param {{ rateLimited?: boolean }} [opts] */
  constructor(message, { rateLimited = false } = {}) {
    super(message);
    this.name = 'UpstreamError';
    this.rateLimited = rateLimited;
  }
}

/** Builds the Overpass QL query from LLD §6.11. */
export function buildQuery(lat, lon, timeoutS = 15) {
  const p = `${lat},${lon}`;
  return [
    `[out:json][timeout:${timeoutS}];`,
    '(',
    `  way(around:${BUILDING_RADIUS_M},${p})["building"];`,
    `  way(around:${ROAD_RADIUS_M},${p})["highway"~"${ROAD_CLASSES}"];`,
    ');',
    'out geom;',
  ].join('\n');
}

/**
 * POSTs the query to each Overpass mirror in turn until one answers.
 * @param {string} query
 * @param {{ fetchImpl?: typeof fetch, urls?: string[], userAgent: string, timeoutMs?: number, log?: (msg: string) => void }} opts
 */
export async function fetchOverpass(query, { fetchImpl = fetch, urls = DEFAULT_OVERPASS_URLS, userAgent, timeoutMs = 15000, log = () => {} }) {
  let allRateLimited = urls.length > 0;
  let lastError = 'no Overpass URLs configured';
  for (const url of urls) {
    const started = Date.now();
    try {
      const res = await fetchImpl(url, {
        method: 'POST',
        headers: {
          'User-Agent': userAgent,
          Accept: 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ data: query }).toString(),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (res.status !== 429) allRateLimited = false;
      if (!res.ok) {
        lastError = `${url} returned HTTP ${res.status}`;
        log(`overpass ${lastError} after ${Date.now() - started} ms`);
        continue;
      }
      const json = await res.json();
      // Overpass can answer 200 with a runtime error in "remark" and no data.
      if (typeof json?.remark === 'string' && /error/i.test(json.remark)) {
        lastError = `${url} remark: ${json.remark}`;
        log(`overpass ${lastError}`);
        continue;
      }
      if (!Array.isArray(json?.elements)) {
        lastError = `${url} returned no elements array`;
        log(`overpass ${lastError}`);
        continue;
      }
      log(`overpass ok ${url} in ${Date.now() - started} ms, ${json.elements.length} elements`);
      return json;
    } catch (err) {
      allRateLimited = false;
      lastError = `${url} failed: ${err?.name === 'TimeoutError' ? 'timeout' : err?.message ?? err}`;
      log(`overpass ${lastError}`);
    }
  }
  throw new UpstreamError(lastError, { rateLimited: allRateLimited });
}

// ---------- geometry helpers (local equirectangular plane, metres) ----------

function projector(lat0, lon0) {
  const kx = Math.cos((lat0 * Math.PI) / 180) * 111320;
  const ky = 110574;
  return ([lat, lon]) => [(lon - lon0) * kx, (lat - lat0) * ky];
}

function signedArea(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) {
    const [x1, y1] = pts[i];
    const [x2, y2] = pts[(i + 1) % pts.length];
    a += x1 * y2 - x2 * y1;
  }
  return a / 2;
}

function centroid(pts) {
  const a = signedArea(pts);
  if (Math.abs(a) < 1e-9) {
    const n = pts.length;
    return [pts.reduce((s, p) => s + p[0], 0) / n, pts.reduce((s, p) => s + p[1], 0) / n];
  }
  let cx = 0;
  let cy = 0;
  for (let i = 0; i < pts.length; i++) {
    const [x1, y1] = pts[i];
    const [x2, y2] = pts[(i + 1) % pts.length];
    const f = x1 * y2 - x2 * y1;
    cx += (x1 + x2) * f;
    cy += (y1 + y2) * f;
  }
  return [cx / (6 * a), cy / (6 * a)];
}

function containsOrigin(pts) {
  // Ray cast from (0,0) along +x.
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (yi > 0 !== yj > 0 && 0 < ((xj - xi) * (0 - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

function distOriginToPolyline(pts) {
  let best = Infinity;
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i];
    const b = pts[i + 1] ?? a;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, -(a[0] * dx + a[1] * dy) / len2));
    const px = a[0] + t * dx;
    const py = a[1] + t * dy;
    best = Math.min(best, Math.hypot(px, py));
  }
  return best;
}

const round7 = (n) => Math.round(n * 1e7) / 1e7;
const round1 = (n) => Math.round(n * 10) / 10;

function wayCoords(el) {
  if (!Array.isArray(el.geometry)) return [];
  return el.geometry
    .filter((g) => g && Number.isFinite(g.lat) && Number.isFinite(g.lon))
    .map((g) => [round7(g.lat), round7(g.lon)]);
}

/**
 * Turns raw Overpass elements into the API response shape and applies the
 * footprint choice from LLD §6.11:
 *  1. buildings whose polygon contains the point; else those whose centroid is within 25 m;
 *  2. among several, the largest with area under 1,500 m² (else the smallest).
 * Returns { building: {...} | null, roads: [...], candidateCount }.
 */
export function normalize(overpassJson, lat, lon) {
  const project = projector(lat, lon);
  const elements = Array.isArray(overpassJson?.elements) ? overpassJson.elements : [];

  const buildings = [];
  const roads = [];
  for (const el of elements) {
    if (el?.type !== 'way' || !el.tags) continue;
    if (el.tags.building && el.tags.building !== 'no') {
      let ring = wayCoords(el);
      if (ring.length >= 2) {
        const [f, l] = [ring[0], ring[ring.length - 1]];
        if (f[0] === l[0] && f[1] === l[1]) ring = ring.slice(0, -1); // open ring in output
      }
      if (ring.length < 3) continue;
      const xy = ring.map(project);
      const areaM2 = Math.abs(signedArea(xy));
      const [cx, cy] = centroid(xy);
      buildings.push({
        osmId: el.id,
        polygon: ring,
        areaM2,
        contains: containsOrigin(xy),
        centroidDistanceM: Math.hypot(cx, cy),
        tags: el.tags,
      });
    } else if (el.tags.highway) {
      const line = wayCoords(el);
      if (line.length < 2) continue;
      roads.push({
        osmId: el.id,
        name: el.tags.name ?? el.tags.ref ?? null,
        highway: el.tags.highway,
        polyline: line,
        distanceM: round1(distOriginToPolyline(line.map(project))),
      });
    }
  }

  roads.sort((a, b) => a.distanceM - b.distanceM);

  let pool = buildings.filter((b) => b.contains);
  if (pool.length === 0) pool = buildings.filter((b) => b.centroidDistanceM <= NEAREST_MAX_M);

  let chosen = null;
  if (pool.length > 0) {
    const small = pool.filter((b) => b.areaM2 < MAX_HOUSE_AREA_M2);
    chosen = small.length
      ? small.reduce((best, b) => (b.areaM2 > best.areaM2 ? b : best))
      : pool.reduce((best, b) => (b.areaM2 < best.areaM2 ? b : best));
  }

  return {
    building: chosen && {
      osmId: chosen.osmId,
      polygon: chosen.polygon,
      areaM2: round1(chosen.areaM2),
      containsPoint: chosen.contains,
      buildingType: chosen.tags.building,
    },
    roads,
    candidateCount: buildings.length,
  };
}
