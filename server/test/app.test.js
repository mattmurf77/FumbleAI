import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createApp } from '../src/app.js';
import { rectWay, roadWay, overpassJson } from '../fixtures/overpass.js';

const servers = [];
after(() => Promise.all(servers.map((s) => new Promise((r) => s.close(r)))));

/** Starts the app on a random port with a mocked Overpass fetch. */
async function start({ env = {}, overpass } = {}) {
  const upstreamCalls = [];
  const fetchImpl = async (url, init) => {
    upstreamCalls.push({ url, init });
    const out = typeof overpass === 'function' ? await overpass(upstreamCalls.length) : overpass;
    if (out instanceof Response) return out;
    return new Response(JSON.stringify(out ?? overpassJson([])), { status: 200 });
  };
  const server = createServer(createApp({ env, fetchImpl, log: () => {} }));
  servers.push(server);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, upstreamCalls, get: (path, headers = {}) => fetch(base + path, { headers }) };
}

const house = overpassJson([rectWay(555, 0, 0, 12, 10), roadWay(9, 'Elm St', -25)]);

test('GET /health returns ok and version', async () => {
  const { get } = await start({ env: { HOME_API_KEY: 'secret', RENDER_GIT_COMMIT: 'abcdef123456' } });
  const res = await get('/health');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.version, '1.0.0+abcdef1');
});

test('GET /v1/footprint returns normalized building and roads', async () => {
  const { get, upstreamCalls } = await start({ overpass: house, env: { OVERPASS_CONTACT: 'ops@example.com' } });
  const res = await get('/v1/footprint?lat=40&lon=-75');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.building.osmId, 555);
  assert.equal(body.building.polygon.length, 4);
  assert.ok(body.building.polygon.every((p) => p.length === 2 && typeof p[0] === 'number'));
  assert.deepEqual(body.roads.map((r) => r.name), ['Elm St']);
  assert.equal(body.cached, false);
  assert.match(body.attribution, /OpenStreetMap/);
  assert.match(upstreamCalls[0].init.headers['User-Agent'], /^HomeServer\/1\.0\.0 .*contact: ops@example\.com/);
  assert.equal(upstreamCalls[0].url, 'https://overpass-api.de/api/interpreter');
  assert.match(decodeURIComponent(upstreamCalls[0].init.body), /around:40,40,-75/);
});

test('footprint results are cached by 5-decimal rounded coordinates', async () => {
  const { get, upstreamCalls } = await start({ overpass: house });
  assert.equal((await get('/v1/footprint?lat=40.000001&lon=-75.000001')).status, 200);
  const second = await (await get('/v1/footprint?lat=40.000004&lon=-74.999996')).json();
  assert.equal(second.cached, true);
  assert.equal(upstreamCalls.length, 1);
  await get('/v1/footprint?lat=40.0001&lon=-75');
  assert.equal(upstreamCalls.length, 2);
});

test('concurrent identical lookups share one upstream call', async () => {
  const { get, upstreamCalls } = await start({ overpass: async () => { await new Promise((r) => setTimeout(r, 30)); return house; } });
  const [a, b] = await Promise.all([get('/v1/footprint?lat=40&lon=-75'), get('/v1/footprint?lat=40&lon=-75')]);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(upstreamCalls.length, 1);
});

test('404 with roads when no building is found', async () => {
  const { get } = await start({ overpass: overpassJson([roadWay(9, 'Elm St', -25)]) });
  const res = await get('/v1/footprint?lat=40&lon=-75');
  assert.equal(res.status, 404);
  const body = await res.json();
  assert.equal(body.error, 'no_building');
  assert.equal(body.building, null);
  assert.equal(body.roads.length, 1);
});

test('400 on missing or invalid coordinates', async () => {
  const { get, upstreamCalls } = await start({ overpass: house });
  for (const q of ['', '?lat=40', '?lat=abc&lon=1', '?lat=91&lon=0', '?lat=0&lon=181', '?lat=&lon=']) {
    assert.equal((await get('/v1/footprint' + q)).status, 400, q);
  }
  assert.equal(upstreamCalls.length, 0);
});

test('falls back to the second mirror, and 502 when all fail (not cached)', async () => {
  const ok = await start({ overpass: (n) => (n === 1 ? new Response('down', { status: 503 }) : house) });
  const res = await ok.get('/v1/footprint?lat=40&lon=-75');
  assert.equal(res.status, 200);
  assert.equal(ok.upstreamCalls[1].url, 'https://overpass.private.coffee/api/interpreter');

  const bad = await start({ overpass: () => new Response('down', { status: 500 }) });
  assert.equal((await bad.get('/v1/footprint?lat=40&lon=-75')).status, 502);
  assert.equal((await bad.get('/v1/footprint?lat=40&lon=-75')).status, 502);
  assert.equal(bad.upstreamCalls.length, 4); // 2 mirrors x 2 requests: failures are not cached
});

test('503 with Retry-After when every mirror rate-limits', async () => {
  const { get } = await start({ overpass: () => new Response('', { status: 429 }) });
  const res = await get('/v1/footprint?lat=40&lon=-75');
  assert.equal(res.status, 503);
  assert.equal(res.headers.get('retry-after'), '60');
});

test('OVERPASS_URLS overrides the mirror list', async () => {
  const { get, upstreamCalls } = await start({ overpass: house, env: { OVERPASS_URLS: 'https://mirror.test/api/interpreter' } });
  await get('/v1/footprint?lat=40&lon=-75');
  assert.equal(upstreamCalls[0].url, 'https://mirror.test/api/interpreter');
});

test('GET /v1/templates serves versioned templates with ETag', async () => {
  const { get } = await start();
  const res = await get('/v1/templates');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(typeof body.version, 'string');
  const keys = body.templates.map((t) => t.key);
  for (const k of ['light_fixture', 'hvac_furnace', 'hvac_filter', 'water_filter', 'refrigerator', 'dishwasher', 'washer', 'dryer', 'range', 'water_heater', 'smoke_detector', 'tv', 'sofa', 'bed', 'custom']) {
    assert.ok(keys.includes(k), `missing template ${k}`);
  }
  const furnace = body.templates.find((t) => t.key === 'hvac_furnace');
  assert.deepEqual(furnace.fields.map((f) => f.key), ['filterSize', 'merv', 'filterLocation', 'fuel']);
  assert.deepEqual(furnace.suggestedChore.repeatRule, { freq: 'everyNDays', interval: 90, anchor: 'completion' });
  for (const t of body.templates) {
    assert.ok(['appliance', 'electronic', 'furniture', 'fixture', 'system', 'any'].includes(t.category), t.key);
    for (const f of t.fields) assert.ok(Object.hasOwn(body.fieldTypes, f.type), `${t.key}.${f.key} type ${f.type}`);
  }
  assert.equal(new Set(keys).size, keys.length, 'template keys are unique');

  const etag = res.headers.get('etag');
  assert.ok(etag);
  assert.equal((await get('/v1/templates', { 'If-None-Match': etag })).status, 304);
});

test('X-Home-Key is enforced on /v1/* when HOME_API_KEY is set, never on /health', async () => {
  const { get } = await start({ env: { HOME_API_KEY: 's3cret' }, overpass: house });
  assert.equal((await get('/health')).status, 200);
  assert.equal((await get('/v1/templates')).status, 401);
  assert.equal((await get('/v1/templates', { 'X-Home-Key': 'wrong' })).status, 401);
  assert.equal((await get('/v1/templates', { 'X-Home-Key': 's3cret' })).status, 200);
  assert.equal((await get('/v1/footprint?lat=40&lon=-75')).status, 401);
  assert.equal((await get('/v1/footprint?lat=40&lon=-75', { 'X-Home-Key': 's3cret' })).status, 200);
});

test('no key required when HOME_API_KEY is unset', async () => {
  const { get } = await start();
  assert.equal((await get('/v1/templates')).status, 200);
});

test('unknown routes 404 and non-GET 405', async () => {
  const { base, get } = await start();
  assert.equal((await get('/nope')).status, 404);
  assert.equal((await get('/v1/nope')).status, 404);
  assert.equal((await fetch(base + '/v1/templates', { method: 'POST' })).status, 405);
});
