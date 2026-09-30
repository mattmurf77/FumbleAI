// HTTP handler for the Home helper service. The map lookup and templates are stateless (only an in-memory
// cache of public OpenStreetMap lookups, lost on every restart). The one thing stored is in-app feedback that
// users choose to send (category, their text, page name, app/OS version, device model, a random install id),
// in Render Postgres (DATABASE_URL).

import { readFileSync } from 'node:fs';
import { createHash, timingSafeEqual } from 'node:crypto';
import { LruCache } from './cache.js';
import { FeedbackStore, RateLimiter, ValidationError, validateFeedback, STATUSES, CATEGORIES, isUuid, createPgPool, renderAdminPage } from './feedback.js';
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

const MAX_BODY_BYTES = 32 * 1024;

class BodyError extends Error {
  constructor(status, error, message) {
    super(message);
    this.status = status;
    this.error = error;
  }
}

/** Reads a JSON request body (max 32 KB). */
async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new BodyError(413, 'payload_too_large', 'Body must be at most 32 KB.');
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  if (!text.trim()) throw new BodyError(400, 'bad_request', 'A JSON body is required.');
  try {
    return JSON.parse(text);
  } catch {
    throw new BodyError(400, 'bad_request', 'Body is not valid JSON.');
  }
}

function clientIp(req) {
  // Render sits behind a proxy; the first X-Forwarded-For entry is the caller.
  const fwd = req.headers['x-forwarded-for'];
  const first = (Array.isArray(fwd) ? fwd[0] : fwd)?.split(',')[0]?.trim();
  return first || req.socket?.remoteAddress || 'unknown';
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
 *   feedbackDb?: { query: (text: string, params?: unknown[]) => Promise<{ rows: any[] }> } | null,
 * }} [deps] `feedbackDb` overrides the Postgres pool built from DATABASE_URL (tests pass a fake).
 */
export function createApp({ env = process.env, fetchImpl = fetch, now = Date.now, log = console.log, templates = loadTemplates(), feedbackDb } = {}) {
  const apiKey = env.HOME_API_KEY?.trim() || null;
  const adminKey = env.HOME_ADMIN_KEY?.trim() || null;
  const databaseUrl = env.DATABASE_URL?.trim() || null;
  const feedbackLimit = Number(env.FEEDBACK_RATE_LIMIT) || 30;
  // Per install id (30/hour) and per IP (2× that, since testers may share a home network).
  const installLimiter = new RateLimiter({ limit: feedbackLimit, now });
  const ipLimiter = new RateLimiter({ limit: feedbackLimit * 2, now });

  let feedbackStorePromise = null;
  /** The FeedbackStore, or null when no database is configured. */
  function getFeedbackStore() {
    if (feedbackDb) return (feedbackStorePromise ??= Promise.resolve(new FeedbackStore(feedbackDb)));
    if (!databaseUrl) return null;
    feedbackStorePromise ??= createPgPool(databaseUrl, env, log).then(
      (pool) => new FeedbackStore(pool),
      (err) => {
        feedbackStorePromise = null;
        throw err;
      },
    );
    return feedbackStorePromise;
  }
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

  function sendHtml(res, status, html) {
    res.writeHead(status, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(html),
      'X-Content-Type-Options': 'nosniff',
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer',
      'X-Robots-Tag': 'noindex',
      'X-Frame-Options': 'DENY',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
    });
    res.end(res.req?.method === 'HEAD' ? undefined : html);
  }

  const dbUnavailable = (res) =>
    send(res, 503, { error: 'feedback_unavailable', message: 'Feedback storage is not configured on this server (DATABASE_URL is unset).' });

  /** Admin gate: 404 when HOME_ADMIN_KEY is unset, 401 unless the header or ?key= matches. Returns true if allowed. */
  function checkAdmin(req, res, url) {
    if (!adminKey) {
      send(res, 404, { error: 'not_found' });
      return false;
    }
    const given = req.headers['x-home-admin-key'] ?? url.searchParams.get('key') ?? '';
    if (!safeEqual(given, adminKey)) {
      send(res, 401, { error: 'unauthorized', message: 'Missing or wrong X-Home-Admin-Key header (or ?key=).' });
      return false;
    }
    return true;
  }

  /** Parses ?status=&category=&limit= for the admin list; sends 400 and returns null when invalid. */
  function parseListQuery(url, res, defaultLimit) {
    const status = url.searchParams.get('status') || null;
    const category = url.searchParams.get('category') || null;
    const rawLimit = url.searchParams.get('limit');
    const limit = rawLimit ? Number(rawLimit) : defaultLimit;
    if (status && !STATUSES.includes(status)) {
      send(res, 400, { error: 'bad_request', message: `status must be one of ${STATUSES.join(', ')}.` });
      return null;
    }
    if (category && !CATEGORIES.includes(category)) {
      send(res, 400, { error: 'bad_request', message: `category must be one of ${CATEGORIES.join(', ')}.` });
      return null;
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
      send(res, 400, { error: 'bad_request', message: 'limit must be an integer from 1 to 500.' });
      return null;
    }
    return { status, category, limit };
  }

  async function withStore(res, fn) {
    const storePromise = getFeedbackStore();
    if (!storePromise) return dbUnavailable(res);
    try {
      return await fn(await storePromise);
    } catch (err) {
      if (err instanceof ValidationError || err instanceof BodyError) throw err;
      log(`feedback database error: ${err?.message ?? err}`);
      return send(res, 503, { error: 'database_unavailable', message: 'The feedback database is not reachable. Try again later.' });
    }
  }

  async function postFeedback(req, res) {
    if (!getFeedbackStore()) return dbUnavailable(res);
    const ipHit = ipLimiter.hit(`ip:${clientIp(req)}`);
    if (!ipHit.ok) return send(res, 429, { error: 'rate_limited', message: 'Too much feedback at once. Try again later.' }, { 'Retry-After': String(ipHit.retryAfterS) });
    let feedback;
    try {
      feedback = validateFeedback(await readJson(req));
    } catch (err) {
      if (err instanceof BodyError) return send(res, err.status, { error: err.error, message: err.message });
      if (err instanceof ValidationError) return send(res, 400, { error: 'bad_request', message: err.message });
      throw err;
    }
    if (feedback.installId) {
      const hit = installLimiter.hit(`install:${feedback.installId}`);
      if (!hit.ok) return send(res, 429, { error: 'rate_limited', message: 'Too much feedback at once. Try again later.' }, { 'Retry-After': String(hit.retryAfterS) });
    }
    return withStore(res, async (store) => {
      const saved = await store.insert(feedback);
      return send(res, 201, { id: saved.id, createdAt: saved.createdAt }, { 'Cache-Control': 'no-store' });
    });
  }

  async function handleFeedback(req, res, url, path) {
    if (path === '/admin/feedback') {
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET, HEAD' });
      if (!checkAdmin(req, res, url)) return;
      const q = parseListQuery(url, res, 200);
      if (!q) return;
      return withStore(res, async (store) => {
        const items = await store.list(q);
        return sendHtml(res, 200, renderAdminPage({ items, ...q, key: url.searchParams.get('key') }));
      });
    }

    if (path === '/v1/feedback') {
      if (req.method === 'POST') {
        if (apiKey && !safeEqual(req.headers['x-home-key'] ?? '', apiKey)) {
          return send(res, 401, { error: 'unauthorized', message: 'Missing or wrong X-Home-Key header.' });
        }
        return postFeedback(req, res);
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET, HEAD, POST' });
      if (!checkAdmin(req, res, url)) return;
      const q = parseListQuery(url, res, 100);
      if (!q) return;
      return withStore(res, async (store) => {
        const items = await store.list(q);
        return send(res, 200, { items, count: items.length }, { 'Cache-Control': 'no-store' });
      });
    }

    // /v1/feedback/:id
    const id = path.slice('/v1/feedback/'.length);
    if (req.method !== 'PATCH') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'PATCH' });
    if (!checkAdmin(req, res, url)) return;
    if (!isUuid(id)) return send(res, 404, { error: 'not_found' });
    let body;
    try {
      body = await readJson(req);
    } catch (err) {
      if (err instanceof BodyError) return send(res, err.status, { error: err.error, message: err.message });
      throw err;
    }
    if (!STATUSES.includes(body?.status)) {
      return send(res, 400, { error: 'bad_request', message: `status must be one of ${STATUSES.join(', ')}.` });
    }
    return withStore(res, async (store) => {
      const updated = await store.setStatus(id.toLowerCase(), body.status);
      return updated ? send(res, 200, updated, { 'Cache-Control': 'no-store' }) : send(res, 404, { error: 'not_found' });
    });
  }

  async function handle(req, res) {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (path === '/v1/feedback' || path === '/admin/feedback' || /^\/v1\/feedback\/[^/]+$/.test(path)) {
      return handleFeedback(req, res, url, path);
    }

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

  async function handler(req, res) {
    try {
      await handle(req, res);
    } catch (err) {
      log(`unhandled error: ${err?.stack ?? err}`);
      if (!res.headersSent) send(res, 500, { error: 'internal_error' });
      else res.end();
    }
  }

  /**
   * Creates the feedback table at startup when a database is configured. Never throws: on failure the
   * table is created on the first feedback request instead. Resolves to a short status line for the log.
   */
  handler.initFeedback = async () => {
    const storePromise = getFeedbackStore();
    if (!storePromise) return 'feedback disabled (no DATABASE_URL)';
    try {
      await (await storePromise).ensureSchema();
      return 'feedback table ready';
    } catch (err) {
      return `feedback table not ready yet: ${err?.message ?? err}`;
    }
  };

  return handler;
}
