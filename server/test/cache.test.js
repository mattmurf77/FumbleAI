import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LruCache } from '../src/cache.js';

test('evicts least recently used entry', () => {
  const c = new LruCache({ max: 2 });
  c.set('a', 1);
  c.set('b', 2);
  assert.equal(c.get('a'), 1); // a is now most recent
  c.set('c', 3);
  assert.equal(c.get('b'), undefined);
  assert.equal(c.get('a'), 1);
  assert.equal(c.get('c'), 3);
});

test('expires entries after TTL', () => {
  let t = 0;
  const c = new LruCache({ ttlMs: 1000, now: () => t });
  c.set('k', 'v');
  t = 999;
  assert.equal(c.get('k'), 'v');
  t = 1000;
  assert.equal(c.get('k'), undefined);
  assert.equal(c.size, 0);
});
