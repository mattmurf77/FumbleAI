import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { createApp } from '../src/app.js';
import { validateFeedback, ValidationError, RateLimiter, renderAdminPage, FeedbackStore } from '../src/feedback.js';

const servers = [];
after(() => Promise.all(servers.map((s) => new Promise((r) => s.close(r)))));

/** In-memory stand-in for pg: understands exactly the statements FeedbackStore sends. */
function fakeDb({ failWith } = {}) {
  const rows = [];
  const calls = [];
  let clock = Date.parse('2026-09-01T00:00:00Z');
  return {
    rows,
    calls,
    async query(text, params = []) {
      calls.push({ text, params });
      if (failWith) throw new Error(failWith);
      const sql = text.trim();
      if (sql.startsWith('CREATE TABLE')) return { rows: [] };
      if (sql.startsWith('INSERT INTO feedback')) {
        const [category, message, page, ctx, appVersion, buildNumber, osVersion, deviceModel, installId] = params;
        clock += 1000;
        const row = {
          id: randomUUID(), created_at: new Date(clock), category, message, page,
          screen_context: ctx === null ? null : JSON.parse(ctx), app_version: appVersion, build_number: buildNumber,
          os_version: osVersion, device_model: deviceModel, install_id: installId, status: 'new',
        };
        rows.push(row);
        return { rows: [{ id: row.id, created_at: row.created_at }] };
      }
      if (sql.startsWith('SELECT')) {
        let out = [...rows];
        const limit = params[params.length - 1];
        let i = 0;
        if (/status = \$/.test(sql)) { const v = params[i++]; out = out.filter((r) => r.status === v); }
        if (/category = \$/.test(sql)) { const v = params[i++]; out = out.filter((r) => r.category === v); }
        out.sort((a, b) => b.created_at - a.created_at);
        return { rows: out.slice(0, limit) };
      }
      if (sql.startsWith('UPDATE feedback')) {
        const row = rows.find((r) => r.id === params[0]);
        if (row) row.status = params[1];
        return { rows: row ? [row] : [] };
      }
      throw new Error(`fake db: unexpected SQL ${sql.slice(0, 40)}`);
    },
  };
}

async function start({ env = {}, db = fakeDb() } = {}) {
  const logs = [];
  const server = createServer(createApp({ env, feedbackDb: db, fetchImpl: async () => { throw new Error('no network'); }, log: (m) => logs.push(m) }));
  servers.push(server);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (body, headers = {}) =>
    fetch(`${base}/v1/feedback`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
  return { base, db, logs, post };
}

const good = {
  category: 'bug', message: '  The plan jumps when I pinch.  ', page: 'Plan · Ground floor',
  screenContext: { lens: 'plan', level: 'Ground floor' }, appVersion: '1.0', buildNumber: '42',
  osVersion: '17.5', deviceModel: 'iPhone15,2', installId: '0a1b2c3d-0000-4000-8000-000000000001',
};

test('validateFeedback trims, keeps known fields and rejects bad input', () => {
  const v = validateFeedback({ ...good, extra: 'ignored' });
  assert.equal(v.message, 'The plan jumps when I pinch.');
  assert.equal(v.page, 'Plan · Ground floor');
  assert.equal('extra' in v, false);
  assert.equal(validateFeedback({ category: 'idea', message: 'x' }).page, null);
  for (const bad of [
    null, [], { message: 'x' }, { category: 'rant', message: 'x' }, { category: 'bug', message: '   ' },
    { category: 'bug', message: 'a'.repeat(5001) }, { category: 'bug', message: 'x', page: 5 },
    { category: 'bug', message: 'x', screenContext: [1] }, { category: 'bug', message: 'x', screenContext: { big: 'y'.repeat(5000) } },
  ]) {
    assert.throws(() => validateFeedback(bad), ValidationError, JSON.stringify(bad)?.slice(0, 60));
  }
  assert.equal(validateFeedback({ category: 'polish', message: 'é'.repeat(5000) }).message.length, 5000);
});

test('POST /v1/feedback stores the row and returns 201 with an id', async () => {
  const { post, db } = await start({ env: { HOME_API_KEY: 'app-key' } });
  const res = await post(good, { 'X-Home-Key': 'app-key' });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.match(body.id, /^[0-9a-f-]{36}$/);
  assert.equal(db.rows.length, 1);
  assert.equal(db.rows[0].message, 'The plan jumps when I pinch.');
  assert.deepEqual(db.rows[0].screen_context, { lens: 'plan', level: 'Ground floor' });
  assert.ok(db.calls[0].text.includes('CREATE TABLE IF NOT EXISTS feedback'));
});

test('POST /v1/feedback enforces X-Home-Key, validates and handles bad JSON', async () => {
  const { post } = await start({ env: { HOME_API_KEY: 'app-key' } });
  assert.equal((await post(good)).status, 401);
  assert.equal((await post(good, { 'X-Home-Key': 'nope' })).status, 401);
  const bad = await post({ category: 'bug' }, { 'X-Home-Key': 'app-key' });
  assert.equal(bad.status, 400);
  assert.match((await bad.json()).message, /message/);
  assert.equal((await post('{nope', { 'X-Home-Key': 'app-key' })).status, 400);
  assert.equal((await post('x'.repeat(40 * 1024), { 'X-Home-Key': 'app-key' })).status, 413);
});

test('POST /v1/feedback is 503 when no database is configured', async () => {
  const server = createServer(createApp({ env: {}, log: () => {} }));
  servers.push(server);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const res = await fetch(`http://127.0.0.1:${server.address().port}/v1/feedback`, { method: 'POST', body: JSON.stringify(good) });
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, 'feedback_unavailable');
});

test('POST /v1/feedback is 503 database_unavailable when the database errors', async () => {
  const { post, logs } = await start({ db: fakeDb({ failWith: 'connection refused' }) });
  const res = await post(good);
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, 'database_unavailable');
  assert.ok(logs.some((l) => l.includes('connection refused')));
});

test('POST /v1/feedback rate-limits per install id', async () => {
  const { post } = await start({ env: { FEEDBACK_RATE_LIMIT: '3' } });
  for (let i = 0; i < 3; i++) assert.equal((await post(good)).status, 201);
  const limited = await post(good);
  assert.equal(limited.status, 429);
  assert.ok(Number(limited.headers.get('retry-after')) > 0);
  // Another install on the same IP still gets through (IP limit is 2× the install limit).
  assert.equal((await post({ ...good, installId: 'other-install' })).status, 201);
});

test('RateLimiter resets after the window', () => {
  let t = 0;
  const rl = new RateLimiter({ limit: 2, windowMs: 1000, now: () => t });
  assert.equal(rl.hit('a').ok, true);
  assert.equal(rl.hit('a').ok, true);
  assert.deepEqual(rl.hit('a'), { ok: false, retryAfterS: 1 });
  assert.equal(rl.hit('b').ok, true);
  t = 1000;
  assert.equal(rl.hit('a').ok, true);
});

test('admin routes are 404 when HOME_ADMIN_KEY is unset', async () => {
  const { base } = await start();
  assert.equal((await fetch(`${base}/v1/feedback`)).status, 404);
  assert.equal((await fetch(`${base}/admin/feedback?key=x`)).status, 404);
});

test('GET /v1/feedback needs the admin key and filters newest first', async () => {
  const { base, post } = await start({ env: { HOME_ADMIN_KEY: 'admin-secret', HOME_API_KEY: 'app-key' } });
  const h = { 'X-Home-Key': 'app-key' };
  await post({ ...good, message: 'first' }, h);
  await post({ ...good, category: 'idea', message: 'second' }, h);
  await post({ ...good, category: 'polish', message: 'third' }, h);

  assert.equal((await fetch(`${base}/v1/feedback`)).status, 401);
  assert.equal((await fetch(`${base}/v1/feedback`, { headers: { 'X-Home-Admin-Key': 'wrong' } })).status, 401);
  // The app key is not an admin key.
  assert.equal((await fetch(`${base}/v1/feedback?key=app-key`)).status, 401);

  const all = await (await fetch(`${base}/v1/feedback`, { headers: { 'X-Home-Admin-Key': 'admin-secret' } })).json();
  assert.deepEqual(all.items.map((f) => f.message), ['third', 'second', 'first']);
  assert.equal(all.items[0].page, 'Plan · Ground floor');
  assert.match(all.items[0].createdAt, /^2026-09-01T/);

  const ideas = await (await fetch(`${base}/v1/feedback?category=idea&key=admin-secret`)).json();
  assert.deepEqual(ideas.items.map((f) => f.message), ['second']);
  const limited = await (await fetch(`${base}/v1/feedback?limit=1&key=admin-secret`)).json();
  assert.equal(limited.count, 1);
  assert.equal((await fetch(`${base}/v1/feedback?status=open&key=admin-secret`)).status, 400);
  assert.equal((await fetch(`${base}/v1/feedback?limit=0&key=admin-secret`)).status, 400);
});

test('PATCH /v1/feedback/:id changes status with the admin key', async () => {
  const { base, post, db } = await start({ env: { HOME_ADMIN_KEY: 'admin-secret' } });
  const { id } = await (await post(good)).json();
  const patch = (target, body, key = 'admin-secret') =>
    fetch(`${base}/v1/feedback/${target}`, { method: 'PATCH', headers: { 'X-Home-Admin-Key': key }, body: JSON.stringify(body) });

  assert.equal((await patch(id, { status: 'done' }, 'wrong')).status, 401);
  assert.equal((await patch(id, { status: 'closed' })).status, 400);
  assert.equal((await patch(randomUUID(), { status: 'done' })).status, 404);
  assert.equal((await patch('not-a-uuid', { status: 'done' })).status, 404);
  const res = await patch(id, { status: 'triaged' });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'triaged');
  assert.equal(db.rows[0].status, 'triaged');
  const triaged = await (await fetch(`${base}/v1/feedback?status=triaged&key=admin-secret`)).json();
  assert.equal(triaged.count, 1);
  assert.equal((await fetch(`${base}/v1/feedback/${id}`, { method: 'DELETE', headers: { 'X-Home-Admin-Key': 'admin-secret' } })).status, 405);
});

test('GET /admin/feedback renders an escaped HTML list with filters', async () => {
  const { base, post } = await start({ env: { HOME_ADMIN_KEY: 'admin-secret' } });
  await post({ ...good, message: '<script>alert(1)</script>', page: 'Chores & To-dos' });
  assert.equal((await fetch(`${base}/admin/feedback`)).status, 401);
  const res = await fetch(`${base}/admin/feedback?key=admin-secret&category=bug`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.match(res.headers.get('content-security-policy'), /default-src 'none'/);
  const html = await res.text();
  assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  assert.ok(!html.includes('<script>alert'));
  assert.ok(html.includes('Chores &amp; To-dos'));
  assert.ok(html.includes('href="/admin/feedback?key=admin-secret&amp;status=new&amp;category=bug"'));
  const viaHeader = await fetch(`${base}/admin/feedback`, { headers: { 'X-Home-Admin-Key': 'admin-secret' } });
  assert.equal(viaHeader.status, 200);
});

test('renderAdminPage shows an empty state', () => {
  const html = renderAdminPage({ items: [], status: null, category: null, limit: 200, key: null });
  assert.ok(html.includes('No feedback yet.'));
});

test('FeedbackStore retries schema creation after a failure', async () => {
  let fail = true;
  const store = new FeedbackStore({ async query() { if (fail) throw new Error('down'); return { rows: [] }; } });
  await assert.rejects(store.ensureSchema(), /down/);
  fail = false;
  await store.ensureSchema();
});

test('non-feedback routes still reject POST', async () => {
  const { base } = await start();
  assert.equal((await fetch(`${base}/v1/templates`, { method: 'POST' })).status, 405);
});
