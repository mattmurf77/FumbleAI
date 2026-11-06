// Read-only verification of the configured deployment. Never print credentials or response bodies.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { loadCatalog, validateCatalog } from '../../server/src/catalog.js';

try {
  const base = new URL(process.env.HOME_SERVER_URL || '');
  assert.equal(base.protocol, 'https:', 'A configured HTTPS helper is required');
  assert.ok(!base.username && !base.password && !base.search && !base.hash, 'Invalid helper origin');
  const expected = process.env.EXPECTED_COMMIT || '';
  assert.match(expected, /^[a-f0-9]{7,40}$/, 'A deployed commit is required');
  const key = process.env.HOME_API_KEY?.trim();
  const headers = key ? { 'X-Home-Key': key } : {};
  const request = (path, options = {}) => fetch(new URL(path, base), {
    redirect: 'error', signal: AbortSignal.timeout(90_000), ...options,
  });
  const health = await request('/health');
  assert.equal(health.status, 200, 'Health failed');
  const state = await health.json();
  assert.equal(state.ok, true, 'Service unhealthy');
  assert.ok(state.version.endsWith('+' + expected.slice(0, 7)), 'Deployed commit differs');
  const catalogResponse = await request('/v1/catalog', { headers });
  assert.equal(catalogResponse.status, 200, 'Catalog unavailable');
  const body = await catalogResponse.text();
  const catalog = validateCatalog(JSON.parse(body));
  assert.deepEqual(catalog, loadCatalog(), 'Deployed catalog differs from checked source');
  const etag = catalogResponse.headers.get('etag');
  assert.equal(etag, '"' + createHash('sha256').update(body).digest('hex') + '"', 'Catalog checksum failed');
  const cached = await request('/v1/catalog', { headers: { ...headers, 'If-None-Match': etag } });
  assert.equal(cached.status, 304, 'Conditional request failed');
  assert.equal(await cached.text(), '', 'Conditional request returned a body');
  const head = await request('/v1/catalog', { method: 'HEAD', headers });
  assert.equal(head.status, 200, 'Catalog HEAD failed');
  assert.equal(head.headers.get('etag'), etag, 'Catalog HEAD differs');
  if (key) {
    assert.equal((await request('/v1/catalog')).status, 401, 'Catalog app-key gate failed');
    assert.equal((await request('/v1/catalog', { headers: { 'X-Home-Key': 'invalid-smoke-test-key' } })).status, 401, 'Catalog wrong-key gate failed');
  }
  assert.equal((await request('/v1/templates', { headers })).status, 200, 'Existing templates unavailable');
  for (const path of ['/privacy', '/support']) {
    const response = await request(path);
    assert.equal(response.status, 200, 'Public product page unavailable');
    assert.ok((await response.text()).includes('Home Blueprint'), 'Public product page missing');
  }
  console.log('Verified deployed commit, exact catalog content, checksums, cache/HEAD, app-key gate, templates and public pages.');
} catch {
  // Network errors may include configured URLs. The specific checks above are available in source.
  console.error('Backend verification failed. Check deployment version, configured helper secrets and service availability. No user data was written.');
  process.exitCode = 1;
}
