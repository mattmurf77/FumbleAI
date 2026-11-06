import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CatalogValidationError, loadCatalog, validateCatalog, createCatalogResource, catalogResponse } from '../src/catalog.js';

const seed = loadCatalog();
const copy = () => structuredClone(seed);
const guide = (catalog, id) => catalog.costGuides.find((item) => item.id === id);
const idea = (catalog, id) => catalog.recommendations.find((item) => item.id === id);
function invalid(change, pattern) {
  const catalog = copy();
  change(catalog);
  assert.throws(() => validateCatalog(catalog), (error) => error instanceof CatalogValidationError && (!pattern || pattern.test(error.message)));
}

test('shipping catalog preserves the six reviewed maintenance prices and source links', () => {
  assert.deepEqual(seed.recommendations.map((item) => item.id), ['gutters', 'furnace', 'cooling', 'dryer', 'filter', 'closet']);
  const ranges = {
    gutters: [16300, 33300, 0, 5000], furnace: [15000, 20000, 1000, 5000],
    cooling: [7500, 20000, 1000, 5000], dryer: [10400, 18800, 2000, 5000],
    filter: [10000, 25000, 1000, 5000], closet: [104600, 321000, 11900, 20900],
  };
  for (const [id, expected] of Object.entries(ranges)) {
    const pro = guide(seed, `${id}-professional`), diy = guide(seed, `${id}-diy`);
    assert.deepEqual([pro.lowMinor, pro.highMinor, diy.lowMinor, diy.highMinor], expected, id);
    assert.ok(pro.sources.every((source) => source.url.startsWith('https://') && source.reviewedOn === seed.reviewedOn));
    assert.ok(diy.sources.every((source) => source.url.startsWith('https://') && source.reviewedOn === seed.reviewedOn));
  }
  assert.equal(guide(seed, 'filter-professional').unit, 'hour');
  assert.equal(guide(seed, 'filter-professional').basis, 'labor');
  assert.match(guide(seed, 'closet-diy').scope, /2087 and 2091/);
  assert.match(guide(seed, 'gutters-professional').sources[0].url, /thumbtack\.com\/p\/gutter-cleaning-prices$/);
});

test('reviewed custom-work guides distinguish per-pack materials, labor and whole-job comparisons', () => {
  const expected = {
    'trade-handyman': [5000, 8000, 'hour', 'labor'],
    'trade-carpenter': [4000, 10000, 'hour', 'labor'],
    'trade-plumber': [4500, 20000, 'hour', 'labor'],
    'trade-electrician': [5000, 13000, 'hour', 'labor'],
    'scope-interior-paint-material': [2898, 5398, 'gallon', 'retailExample'],
    'scope-interior-paint-professional': [200, 600, 'squareFoot', 'wholeJob'],
    'scope-vinyl-floor-material': [4020, 8040, 'carton', 'materials'],
    'scope-vinyl-floor-labor': [300, 500, 'squareFoot', 'labor'],
    'scope-mulch-material': [397, 397, 'bag', 'retailExample'],
    'scope-mulch-labor': [2000, 5000, 'cubicYard', 'labor'],
    'scope-smallHandyman': [10100, 25700, 'visit', 'wholeJob'],
    'scope-halfDayHandyman': [21200, 56800, 'visit', 'wholeJob'],
    'scope-fullDayHandyman': [65200, 184200, 'visit', 'wholeJob'],
  };
  for (const [id, row] of Object.entries(expected)) {
    const item = guide(seed, id);
    assert.deepEqual([item.lowMinor, item.highMinor, item.unit, item.basis], row, id);
  }
  assert.match(guide(seed, 'scope-interior-paint-professional').scope, /FLOOR/);
  assert.match(guide(seed, 'scope-interior-paint-material').scope, /350/);
  assert.match(guide(seed, 'scope-vinyl-floor-material').scope, /20\.1/);
  assert.match(guide(seed, 'scope-mulch-material').scope, /1\.5/);
});

test('catalog never treats routine maintenance or DIY kits as a supported resale uplift', () => {
  const matched = seed.recommendations.filter((item) => item.resaleAssumptionID !== null);
  assert.deepEqual(matched.map((item) => item.id), ['closet']);
  assert.equal(seed.resaleAssumptions[0].ratioBasisPoints, 8300);
  assert.equal(seed.resaleAssumptions[0].mode, 'hirePro');
  assert.equal(seed.resaleAssumptions[0].costGuideID, 'closet-professional');
  assert.match(seed.resaleAssumptions[0].scope, /not a property valuation/);
  invalid((c) => { idea(c, 'gutters').resaleAssumptionID = c.resaleAssumptions[0].id; }, /resale/);
  invalid((c) => { c.resaleAssumptions[0].costGuideID = 'closet-diy'; }, /installed closet/);
  invalid((c) => { c.resaleAssumptions[0].mode = 'diy'; }, /installed closet/);
});

test('tools remain reusable equipment while replacement filters and bags remain consumable supplies', () => {
  const filter = idea(seed, 'filter').supplies;
  assert.deepEqual(filter, [
    { name: 'Replacement HVAC filter', quantity: 1, unit: 'ea', isEquipment: false },
    { name: 'Flashlight', quantity: 1, unit: 'ea', isEquipment: true },
  ]);
  assert.equal(idea(seed, 'gutters').supplies.find((supply) => supply.name === 'Yard waste bags').isEquipment, false);
  assert.equal(idea(seed, 'closet').supplies.find((supply) => supply.name === 'Drill').isEquipment, true);
});

test('all recommendations must be complete, unique and known to the installed app', () => {
  invalid((c) => c.recommendations.pop(), /item count/);
  invalid((c) => { c.recommendations[1] = c.recommendations[0]; }, /duplicate/);
  invalid((c) => { c.recommendations[0].id = 'new-task'; }, /unknown maintenance/);
  invalid((c) => { delete c.recommendations[0].diyTitle; }, /fields/);
  invalid((c) => { c.recommendations[0].rankingBoost = 100; }, /fields/);
  invalid((c) => { c.recommendations[0] = null; });
  invalid((c) => { c.recommendations = {}; }, /item count/);
});

test('money is integer minor units, ordered, bounded and national USD only', () => {
  for (const bad of [-1, 0.5, '100', NaN, Infinity, Number.MAX_SAFE_INTEGER]) {
    invalid((c) => { c.costGuides[0].lowMinor = bad; }, /integer/);
  }
  invalid((c) => { c.costGuides[0].highMinor = 1; }, /integer/);
  invalid((c) => { c.costGuides[0].currency = 'CAD'; }, /US dollar/);
  invalid((c) => { c.costGuides[0].country = 'CA'; }, /US dollar/);
  const zero = copy();
  guide(zero, 'gutters-diy').lowMinor = 0;
  assert.doesNotThrow(() => validateCatalog(zero));
});

test('guide references cannot silently swap installed jobs with hourly rates or DIY materials', () => {
  invalid((c) => { c.costGuides = c.costGuides.filter((item) => item.id !== 'furnace-professional'); }, /incompatible/);
  invalid((c) => { idea(c, 'filter').professionalGuideID = 'furnace-professional'; }, /must match/);
  invalid((c) => { guide(c, 'filter-professional').unit = 'job'; }, /incompatible/);
  invalid((c) => { guide(c, 'closet-professional').basis = 'materials'; });
  invalid((c) => { guide(c, 'closet-diy').basis = 'wholeJob'; }, /incompatible/);
  invalid((c) => { c.costGuides[0].sources = []; }, /item count/);
  invalid((c) => { c.costGuides.push(c.costGuides[0]); }, /duplicate/);
});

test('source dates must be real and cannot claim a later review than publication', () => {
  invalid((c) => { c.reviewedOn = '2026-02-30'; }, /calendar date/);
  invalid((c) => { c.reviewedOn = '2027-01-01'; }, /precede publication/);
  invalid((c) => { c.costGuides[0].sources[0].reviewedOn = '2026-11-05'; }, /later/);
  invalid((c) => { c.publishedAt = '2026-11-05T00:00:00-05:00'; }, /UTC timestamp/);
  invalid((c) => { c.version = '2026-11-03.1'; }, /match publication/);
  invalid((c) => { c.schemaVersion = 2; }, /unsupported schema/);
});

test('sources and directory links reject credential URLs, private hosts and unsafe schemes', () => {
  for (const url of ['javascript:alert(1)', 'http://www.angi.com/', 'https://user:secret@www.angi.com/',
    'https://127.0.0.1/', 'https://localhost/', 'https://service.internal/', 'https://www.angi.com:8443/', '/relative']) {
    invalid((c) => { c.costGuides[0].sources[0].url = url; }, /HTTPS/);
    invalid((c) => { c.providerDirectories[0].url = url; }, /HTTPS/);
  }
  invalid((c) => { c.costGuides[0].sources[0].label = '\nFake source'; }, /plain text/);
  invalid((c) => { c.providerDirectories[0].disclosure = ''; }, /plain text/);
  invalid((c) => { idea(c, 'gutters').providerDirectoryID = 'invented-provider'; }, /unknown contractor/);
});

test('supply defaults require positive counts, unambiguous units and no private user fields', () => {
  invalid((c) => { c.recommendations[0].supplies[0].quantity = 0; }, /integer/);
  invalid((c) => { c.recommendations[0].supplies[0].quantity = 1.2; }, /integer/);
  invalid((c) => { c.recommendations[0].supplies[0].unit = 'each'; }, /individually counted/);
  invalid((c) => { c.recommendations[0].supplies[0].isEquipment = 'yes'; }, /individually counted/);
  invalid((c) => { c.recommendations[0].supplies[0].confirmedOnHand = 2; }, /fields/);
  invalid((c) => { c.recommendations[0].supplies.push({ ...c.recommendations[0].supplies[0], name: 'WORK GLOVES' }); }, /duplicate/);
  invalid((c) => { c.recommendations[0].supplies[0].name = 42; }, /plain text/);
});

test('no paid referral is activated by a content update and no private fields can be added', () => {
  assert.deepEqual(seed.referralPartners, []);
  invalid((c) => { c.referralPartners.push({ name: 'Unconfigured partner', url: 'https://provider.com/' }); }, /item count/);
  invalid((c) => { c.homeAddress = 'Unrequested private field'; }, /fields/);
  invalid((c) => { c.recommendations[0].ownerID = 'owner'; }, /fields/);
});

test('resource snapshot stays atomic if the caller later mutates the input', () => {
  const input = copy(), resource = createCatalogResource(input);
  input.costGuides[0].lowMinor = 999999;
  assert.equal(JSON.parse(resource.body).costGuides[0].lowMinor, seed.costGuides[0].lowMinor);
  assert.ok(Object.isFrozen(resource));
  assert.equal(resource.etag, createCatalogResource(seed).etag);
  const next = copy(); next.costGuides[0].lowMinor += 100;
  assert.notEqual(createCatalogResource(next).etag, resource.etag);
});

test('GET returns explicit UTF-8 content length and private conditional-cache headers', () => {
  const resource = createCatalogResource(seed);
  const response = catalogResponse(resource);
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.body), seed);
  assert.equal(response.headers['Content-Length'], String(Buffer.byteLength(response.body)));
  assert.equal(response.headers['Cache-Control'], 'private, max-age=3600');
  assert.equal(response.headers.Vary, 'X-Home-Key');
  assert.equal(response.headers['X-Content-Type-Options'], 'nosniff');
  assert.equal(response.headers['Last-Modified'], 'Thu, 05 Nov 2026 00:00:00 GMT');
  assert.match(response.headers.ETag, /^"[0-9a-f]{64}"$/);
});

test('conditional reads support weak and multiple tags and give ETag precedence over date', () => {
  const resource = createCatalogResource(seed);
  for (const value of [resource.etag, `W/${resource.etag}`, `"old", W/${resource.etag}`, '*']) {
    const response = catalogResponse(resource, { headers: { 'If-None-Match': value } });
    assert.equal(response.status, 304, value);
    assert.equal(response.body, null);
    assert.equal(response.headers['Content-Length'], undefined);
    assert.equal(response.headers.ETag, resource.etag);
  }
  assert.equal(catalogResponse(resource, { headers: { 'if-modified-since': resource.lastModified } }).status, 304);
  assert.equal(catalogResponse(resource, { headers: { 'if-none-match': '"old"', 'if-modified-since': resource.lastModified } }).status, 200);
  assert.equal(catalogResponse(resource, { headers: { 'if-modified-since': 'invalid date' } }).status, 200);
  assert.equal(catalogResponse(resource, { headers: { 'if-modified-since': 'Wed, 04 Nov 2026 00:00:00 GMT' } }).status, 200);
  assert.equal(catalogResponse(resource, { headers: new Headers({ 'If-None-Match': resource.etag }) }).status, 304);
});

test('HEAD has GET metadata and no body; write methods cannot change the catalog', () => {
  const resource = createCatalogResource(seed);
  const get = catalogResponse(resource), head = catalogResponse(resource, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.body, null);
  assert.deepEqual(head.headers, get.headers);
  assert.equal(catalogResponse(resource, { method: 'HEAD', headers: { 'if-none-match': resource.etag } }).status, 304);
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    const response = catalogResponse(resource, { method });
    assert.equal(response.status, 405);
    assert.equal(response.headers.Allow, 'GET, HEAD');
    assert.deepEqual(JSON.parse(response.body), { error: 'method_not_allowed' });
  }
  assert.equal(catalogResponse(resource).body, get.body);
});
