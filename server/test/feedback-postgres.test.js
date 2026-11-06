import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { FeedbackStore, IdempotencyConflict, validateFeedback } from '../src/feedback.js';

// Opt-in real database test. CI supplies a disposable Postgres service; never use a
// production DATABASE_URL. All test objects live in a unique schema that is removed.
test('Postgres upgrades existing feedback and serializes concurrent idempotent submissions', {
  skip: !process.env.HOME_TEST_DATABASE_URL,
  timeout: 30_000,
}, async () => {
  const { default: pg } = await import('pg');
  const schema = `feedback_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new pg.Pool({ connectionString: process.env.HOME_TEST_DATABASE_URL, max: 1, connectionTimeoutMillis: 5000 });
  let pool;
  try {
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new pg.Pool({ connectionString: process.env.HOME_TEST_DATABASE_URL, max: 5, connectionTimeoutMillis: 5000,
      options: `-c search_path=${schema} -c statement_timeout=10000` });
    // Start from the already-deployed shape with an existing report, not an empty new schema.
    await pool.query(`CREATE TABLE feedback (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT now(),
      category text NOT NULL, message text NOT NULL, page text, screen_context jsonb, app_version text,
      build_number text, os_version text, device_model text, install_id text, status text NOT NULL DEFAULT 'new'
    )`);
    const legacy = await pool.query("INSERT INTO feedback (category,message) VALUES ('idea','Existing report') RETURNING id");
    const store = new FeedbackStore(pool);
    await store.ensureSchema();
    const requestId = randomUUID();
    const feedback = validateFeedback({ category: 'bug', message: 'One report despite a lost response',
      screenContext: { lens: 'history', nested: { a: 1, b: 2 } }, installId: 'test-install' });
    const receipts = await Promise.all(Array.from({ length: 20 }, () => store.insert(feedback, { requestId })));
    assert.equal(new Set(receipts.map((r) => r.id)).size, 1);
    assert.equal(new Set(receipts.map((r) => r.createdAt)).size, 1);
    assert.equal((await pool.query('SELECT count(*)::int AS count FROM feedback')).rows[0].count, 2);
    assert.equal((await pool.query('SELECT message FROM feedback WHERE id=$1', [legacy.rows[0].id])).rows[0].message, 'Existing report');
    await store.setStatus(receipts[0].id, 'triaged');
    const reordered = { ...feedback, screenContext: { nested: { b: 2, a: 1 }, lens: 'history' } };
    assert.deepEqual(await store.insert(reordered, { requestId }), receipts[0]);
    await assert.rejects(store.insert({ ...feedback, message: 'Different report' }, { requestId }), IdempotencyConflict);
    const saved = (await pool.query('SELECT message,status FROM feedback WHERE id=$1', [receipts[0].id])).rows[0];
    assert.deepEqual(saved, { message: feedback.message, status: 'triaged' });
    const independent = await Promise.all([store.insert(feedback), store.insert(feedback)]);
    assert.notEqual(independent[0].id, independent[1].id);
    assert.equal((await pool.query('SELECT count(*)::int AS count FROM feedback')).rows[0].count, 4);
  } finally {
    await pool?.end();
    await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await admin.end();
  }
});
