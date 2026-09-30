import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildQuery, normalize, fetchOverpass, UpstreamError } from '../src/overpass.js';
import { rectWay, roadWay, overpassJson, ORIGIN } from '../fixtures/overpass.js';

const { lat, lon } = ORIGIN;

test('query matches LLD §6.11', () => {
  const q = buildQuery(40.12345, -75.54321);
  assert.match(q, /^\[out:json\]\[timeout:15\];/);
  assert.match(q, /way\(around:40,40.12345,-75.54321\)\["building"\];/);
  assert.match(q, /way\(around:60,40.12345,-75.54321\)\["highway"~"\^\(residential\|tertiary\|secondary\|primary\|unclassified\|living_street\|service\)\$"\];/);
  assert.match(q, /out geom;$/);
});

test('picks the building containing the point and returns an open ring', () => {
  const r = normalize(overpassJson([rectWay(1, 0, 0, 12, 10), rectWay(2, 20, 0, 6, 6)]), lat, lon);
  assert.equal(r.building.osmId, 1);
  assert.equal(r.building.polygon.length, 4);
  assert.ok(Math.abs(r.building.areaM2 - 120) < 1, `area ${r.building.areaM2}`);
  assert.equal(r.building.containsPoint, true);
  assert.equal(r.candidateCount, 2);
});

test('falls back to nearest within 25 m, preferring the largest under 1,500 m²', () => {
  const r = normalize(
    overpassJson([
      rectWay(10, 15, 0, 5, 5), // garage, 25 m², centroid 15 m away
      rectWay(11, -18, 0, 12, 10), // house, 120 m², 18 m away
      rectWay(12, 0, 38, 10, 10), // too far (38 m)
    ]),
    lat,
    lon,
  );
  assert.equal(r.building.osmId, 11);
  assert.equal(r.building.containsPoint, false);
});

test('skips candidates of 1,500 m² or more when a smaller one exists', () => {
  const r = normalize(overpassJson([rectWay(20, 0, 0, 60, 60), rectWay(21, 0, 0, 20, 20)]), lat, lon);
  assert.equal(r.building.osmId, 21);
});

test('only huge buildings: picks the smallest', () => {
  const r = normalize(overpassJson([rectWay(30, 0, 0, 60, 60), rectWay(31, 0, 0, 50, 50)]), lat, lon);
  assert.equal(r.building.osmId, 31);
});

test('no building returns null; roads sorted by distance with names', () => {
  const r = normalize(
    overpassJson([roadWay(100, 'Far St', 50), roadWay(101, 'Main St', -20), roadWay(102, null, 30, { ref: 'CR 5' }), rectWay(40, 0, 0, 10, 10, { building: 'no' })]),
    lat,
    lon,
  );
  assert.equal(r.building, null);
  assert.deepEqual(r.roads.map((x) => x.name), ['Main St', 'CR 5', 'Far St']);
  assert.ok(Math.abs(r.roads[0].distanceM - 20) < 0.5);
  assert.equal(r.roads[0].polyline.length, 3);
  assert.equal(r.roads[0].highway, 'residential');
});

test('ignores malformed elements', () => {
  const r = normalize({ elements: [null, { type: 'node', id: 1 }, { type: 'way', id: 2, tags: { building: 'yes' }, geometry: [null] }] }, lat, lon);
  assert.equal(r.building, null);
  assert.deepEqual(r.roads, []);
});

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

test('fetchOverpass sends POST form with User-Agent and uses fallback mirror', async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (calls.length === 1) return new Response('busy', { status: 504 });
    return jsonResponse(200, overpassJson([]));
  };
  const json = await fetchOverpass('Q', { fetchImpl, urls: ['https://a/api', 'https://b/api'], userAgent: 'UA/1' });
  assert.deepEqual(json.elements, []);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, 'https://b/api');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers['User-Agent'], 'UA/1');
  assert.equal(calls[0].init.body, 'data=Q');
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});

test('fetchOverpass treats runtime-error remark as failure', async () => {
  let n = 0;
  const fetchImpl = async () => (++n === 1 ? jsonResponse(200, { elements: [], remark: 'runtime error: timeout' }) : jsonResponse(200, overpassJson([rectWay(1, 0, 0, 5, 5)])));
  const json = await fetchOverpass('Q', { fetchImpl, urls: ['https://a', 'https://b'], userAgent: 'UA' });
  assert.equal(json.elements.length, 1);
});

test('fetchOverpass throws rate-limited UpstreamError when all mirrors return 429', async () => {
  const fetchImpl = async () => new Response('slow down', { status: 429 });
  await assert.rejects(fetchOverpass('Q', { fetchImpl, urls: ['https://a', 'https://b'], userAgent: 'UA' }), (err) => err instanceof UpstreamError && err.rateLimited === true);
});

test('fetchOverpass throws UpstreamError on network errors and timeouts', async () => {
  const fetchImpl = async (_url, init) =>
    new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(init.signal.reason)));
  // AbortSignal.timeout timers are unref'd; keep the event loop alive while we wait.
  const keepAlive = setTimeout(() => {}, 5000);
  try {
    await assert.rejects(fetchOverpass('Q', { fetchImpl, urls: ['https://a'], userAgent: 'UA', timeoutMs: 20 }), (err) => err instanceof UpstreamError && !err.rateLimited && /timeout/.test(err.message));
    const failing = async () => { throw new TypeError('fetch failed'); };
    await assert.rejects(fetchOverpass('Q', { fetchImpl: failing, urls: ['https://a'], userAgent: 'UA' }), (err) => err instanceof UpstreamError && /fetch failed/.test(err.message));
  } finally {
    clearTimeout(keepAlive);
  }
});
