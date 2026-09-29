// HTTP handler for the Home helper service. Stateless: nothing about users is stored.
// Only an in-memory cache of public OpenStreetMap lookups, lost on every restart.

import { readFileSync } from 'node:fs';
import { createHash, timingSafeEqual } from 'node:crypto';
import { LruCache } from './cache.js';
import { buildQuery, fetchOverpass, normalize, DEFAULT_OVERPASS_URLS, UpstreamError } from './overpass.js';

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const DAY_MS = 24 * 60 * 60 * 1000;

export function loadTemplates() {
  return JSON.parse(readFileSync(new URL('../data/templates.json', import.meta.url), 'utf8'));
}

function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

function parseCoord(raw, min, max) {
  if (raw === null || raw.trim() === '') return null;
  const n = Number(raw);
  return Number.isFinite(n) && n >= min && n <= max ? n : null;
}

/**
 * @param {{
 *   env?: Record<string, string | undefined>,
 *   fetchImpl?: typeof fetch,
 *   now?: () => number,
 *   log?: (msg: string) => void,
 *   templates?: object,
 * }} [deps]
 */
export function createApp({ env = process.env, fetchImpl = fetch, now = Date.now, log = console.log, templates = loadTemplates() } = {}) {
  const apiKey = env.HOME_API_KEY?.trim() || null;
  const commit = env.RENDER_GIT_COMMIT ? env.RENDER_GIT_COMMIT.slice(0, 7) : null;
  const version = commit ? `${pkg.version}+${commit}` : pkg.version;
  const contact = env.OVERPASS_CONTACT?.trim();
  const userAgent = `HomeServer/${pkg.version} (Home iPhone app footprint lookup; ${contact ? `contact: ${contact}` : 'low-volume, 2-5 users'})`;
  const overpassUrls = env.OVERPASS_URLS
    ? env.OVERPASS_URLS.split(',').map((s) => s.trim()).filter(Boolean)
    : DEFAULT_OVERPASS_URLS;
  const timeoutMs = Number(env.OVERPASS_TIMEOUT_MS) || 15000;

  const cache = new LruCache({ max: 500, ttlMs: DAY_MS, now });
  const inflight = new Map();

  const templatesBody = JSON.stringify(templates);
  const templatesEtag = `"${createHash('sha256').update(templatesBody).digest('hex').slice(0, 16)}"`;

  function send(res, status, body, headers = {}) {
    const text = typeof body === 'string' ? body : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(text),
      'X-Content-Type-Options': 'nosniff',
      ...headers,
    });
    res.end(res.req?.method === 'HEAD' ? undefined : text);
  }

  async function lookupFootprint(lat, lon) {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`;
    const cached = cache.get(key);
    if (cached) return { ...cached, cached: true };
    if (inflight.has(key)) return inflight.get(key);

    const promise = (async () => {
      const rLat = Number(lat.toFixed(5));
      const rLon = Number(lon.toFixed(5));
      const raw = await fetchOverpass(buildQuery(rLat, rLon, Math.ceil(timeoutMs / 1000)), {
        fetchImpl,
        urls: overpassUrls,
        userAgent,
        timeoutMs,
        log,
      });
      const result = normalize(raw, rLat, rLon);
      cache.set(key, result);
      return { ...result, cached: false };
    })();
    inflight.set(key, promise);
    try {
      return await promise;
    } finally {
      inflight.delete(key);
    }
  }

  async function handle(req, res) {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET, HEAD' });
    }

    if (path === '/health' || path === '/') {
      return send(res, 200, { ok: true, version, cacheEntries: cache.size }, { 'Cache-Control': 'no-store' });
    }

    if (!path.startsWith('/v1/')) return send(res, 404, { error: 'not_found' });

    if (apiKey && !safeEqual(req.headers['x-home-key'] ?? '', apiKey)) {
      return send(res, 401, { error: 'unauthorized', message: 'Missing or wrong X-Home-Key header.' });
    }

    if (path === '/v1/templates') {
      if (req.headers['if-none-match'] === templatesEtag) {
        res.writeHead(304, { ETag: templatesEtag });
        return res.end();
      }
      return send(res, 200, templatesBody, { ETag: templatesEtag, 'Cache-Control': 'public, max-age=3600' });
    }

    if (path === '/v1/footprint') {
      const lat = parseCoord(url.searchParams.get('lat'), -90, 90);
      const lon = parseCoord(url.searchParams.get('lon'), -180, 180);
      if (lat === null || lon === null) {
        return send(res, 400, { error: 'bad_request', message: 'lat (-90..90) and lon (-180..180) are required numbers.' });
      }
      try {
        const result = await lookupFootprint(lat, lon);
        const body = {
          query: { lat: Number(lat.toFixed(5)), lon: Number(lon.toFixed(5)) },
          building: result.building,
          roads: result.roads,
          candidateCount: result.candidateCount,
          cached: result.cached,
          attribution: '© OpenStreetMap contributors (ODbL)',
        };
        if (!result.building) {
          return send(res, 404, { error: 'no_building', ...body }, { 'Cache-Control': 'public, max-age=3600' });
        }
        return send(res, 200, body, { 'Cache-Control': 'public, max-age=86400' });
      } catch (err) {
        if (err instanceof UpstreamError) {
          log(`footprint upstream failure: ${err.message}`);
          return err.rateLimited
            ? send(res, 503, { error: 'upstream_rate_limited', message: 'OpenStreetMap is busy. Try again later.' }, { 'Retry-After': '60' })
            : send(res, 502, { error: 'upstream_unavailable', message: 'OpenStreetMap lookup failed. Try again later.' });
        }
        throw err;
      }
    }

    return send(res, 404, { error: 'not_found' });
  }

  return async function handler(req, res) {
    try {
      await handle(req, res);
    } catch (err) {
      log(`unhandled error: ${err?.stack ?? err}`);
      if (!res.headersSent) send(res, 500, { error: 'internal_error' });
      else res.end();
    }
  };
}
