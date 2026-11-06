// Public planning content only. Home records, addresses, receipts, device identifiers,
// recommendation ranking and owner-confirmed values never enter this catalog.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

export const CATALOG_SCHEMA_VERSION = 1;
export const RECOMMENDATION_IDS = Object.freeze(['gutters', 'furnace', 'cooling', 'dryer', 'filter', 'closet']);
const MAX_CATALOG_BYTES = 512 * 1024;
const MAX_MONEY_MINOR = 1_000_000_000;
const UNITS = new Set(['job', 'hour', 'item', 'gallon', 'carton', 'bag', 'squareFoot', 'cubicYard', 'visit']);
const BASES = new Set(['installed', 'materials', 'labor', 'wholeJob', 'retailExample']);

export class CatalogValidationError extends Error {
  constructor(path, problem) { super(`${path}: ${problem}`); this.name = 'CatalogValidationError'; }
}

function check(condition, path, problem) {
  if (!condition) throw new CatalogValidationError(path, problem);
}
function object(value, path, keys) {
  check(value !== null && typeof value === 'object' && !Array.isArray(value), path, 'must be an object');
  const own = Object.keys(value);
  check(own.length === keys.length && keys.every((key) => Object.hasOwn(value, key)), path, 'has missing or unsupported fields');
}
function text(value, path, max = 2000) {
  check(typeof value === 'string' && value === value.trim() && value.length > 0 && value.length <= max &&
    !/[\u0000-\u001f\u007f]/.test(value), path, 'must be nonempty trimmed plain text within its length limit');
}
function id(value, path) {
  check(typeof value === 'string' && /^[A-Za-z][A-Za-z0-9._-]{0,79}$/.test(value), path, 'must be a stable content identifier');
}
function integer(value, path, minimum, maximum) {
  check(Number.isSafeInteger(value) && value >= minimum && value <= maximum, path, 'must be an integer within its supported range');
}
function date(value, path) {
  check(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value), path, 'must be an ISO calendar date');
  const parsed = new Date(value + 'T00:00:00.000Z');
  check(Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value, path, 'must be a valid calendar date');
  return value;
}
function https(value, path) {
  text(value, path, 2048);
  let url;
  try { url = new URL(value); } catch { check(false, path, 'must be an absolute HTTPS URL'); }
  check(url.protocol === 'https:' && !url.username && !url.password && !url.port && !url.hash &&
    /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i.test(url.hostname) &&
    !/(?:^|\.)(?:localhost|local|internal|test|invalid|example)$/i.test(url.hostname), path,
  'must be a public HTTPS URL without credentials, a custom port or a fragment');
}
function list(value, path, minimum = 0, maximum = 100) {
  check(Array.isArray(value) && value.length >= minimum && value.length <= maximum, path, 'has an unsupported item count');
  return value;
}
function unique(items, path, key = (item) => item?.id) {
  check(new Set(items.map(key)).size === items.length, path, 'contains duplicate identifiers');
}
function source(value, path, latestReview) {
  object(value, path, ['label', 'url', 'reviewedOn']);
  text(value.label, `${path}.label`, 200);
  https(value.url, `${path}.url`);
  check(date(value.reviewedOn, `${path}.reviewedOn`) <= latestReview, path, 'source review is later than the catalog review');
}
function territory(value, path) {
  check(value.country === 'US' && value.currency === 'USD', path, 'schema 1 guides are national US dollar examples only');
}

/** Fail atomically before serving a malformed or ambiguous content update. */
export function validateCatalog(value) {
  object(value, 'catalog', ['schemaVersion', 'version', 'publishedAt', 'reviewedOn', 'recommendations', 'costGuides',
    'providerDirectories', 'resaleAssumptions', 'referralPartners']);
  check(value.schemaVersion === CATALOG_SCHEMA_VERSION, 'catalog.schemaVersion', 'unsupported schema version');
  check(typeof value.version === 'string' && /^\d{4}-\d{2}-\d{2}\.[1-9]\d{0,5}$/.test(value.version), 'catalog.version', 'must be YYYY-MM-DD.revision');
  date(value.version.slice(0, 10), 'catalog.version');
  check(typeof value.publishedAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value.publishedAt) &&
    Number.isFinite(Date.parse(value.publishedAt)) && new Date(value.publishedAt).toISOString() === value.publishedAt,
  'catalog.publishedAt', 'must be an ISO UTC timestamp');
  const reviewedOn = date(value.reviewedOn, 'catalog.reviewedOn');
  check(reviewedOn <= value.publishedAt.slice(0, 10) && value.version.slice(0, 10) === value.publishedAt.slice(0, 10),
    'catalog', 'review must precede publication and version date must match publication');

  list(value.costGuides, 'costGuides', 12, 100);
  unique(value.costGuides, 'costGuides');
  for (const item of value.costGuides) {
    const path = `costGuides.${item?.id ?? '?'}`;
    object(item, path, ['id', 'lowMinor', 'highMinor', 'country', 'currency', 'unit', 'basis', 'scope', 'sources']);
    id(item.id, `${path}.id`);
    integer(item.lowMinor, `${path}.lowMinor`, 0, MAX_MONEY_MINOR);
    integer(item.highMinor, `${path}.highMinor`, item.lowMinor, MAX_MONEY_MINOR);
    territory(item, path);
    check(UNITS.has(item.unit) && BASES.has(item.basis), path, 'has unsupported price units or cost basis');
    text(item.scope, `${path}.scope`);
    list(item.sources, `${path}.sources`, 1, 8);
    unique(item.sources, `${path}.sources`, (item) => item?.url);
    item.sources.forEach((item, index) => source(item, `${path}.sources[${index}]`, reviewedOn));
  }
  const guides = new Map(value.costGuides.map((item) => [item.id, item]));

  list(value.providerDirectories, 'providerDirectories', 1, 20);
  unique(value.providerDirectories, 'providerDirectories');
  for (const item of value.providerDirectories) {
    const path = `providerDirectories.${item?.id ?? '?'}`;
    object(item, path, ['id', 'name', 'url', 'disclosure']);
    id(item.id, `${path}.id`); text(item.name, `${path}.name`, 120);
    https(item.url, `${path}.url`); text(item.disclosure, `${path}.disclosure`, 1000);
  }
  const directories = new Set(value.providerDirectories.map((item) => item.id));

  list(value.resaleAssumptions, 'resaleAssumptions', 0, 1);
  unique(value.resaleAssumptions, 'resaleAssumptions');
  for (const item of value.resaleAssumptions) {
    const path = `resaleAssumptions.${item?.id ?? '?'}`;
    object(item, path, ['id', 'ratioBasisPoints', 'country', 'currency', 'mode', 'costGuideID', 'scope', 'source']);
    id(item.id, `${path}.id`); territory(item, path);
    integer(item.ratioBasisPoints, `${path}.ratioBasisPoints`, 0, 30_000);
    check(item.mode === 'hirePro' && item.costGuideID === 'closet-professional' &&
      guides.get(item.costGuideID)?.basis === 'installed' && guides.get(item.costGuideID)?.unit === 'job',
    path, 'schema 1 recovery assumptions apply only to the installed closet project');
    text(item.scope, `${path}.scope`); source(item.source, `${path}.source`, reviewedOn);
  }
  const resale = new Map(value.resaleAssumptions.map((item) => [item.id, item]));

  list(value.recommendations, 'recommendations', RECOMMENDATION_IDS.length, RECOMMENDATION_IDS.length);
  unique(value.recommendations, 'recommendations');
  for (const item of value.recommendations) {
    const path = `recommendations.${item?.id ?? '?'}`;
    object(item, path, ['id', 'title', 'detail', 'symbol', 'diyTitle', 'supplies', 'professionalGuideID', 'diyGuideID',
      'providerDirectoryID', 'resaleAssumptionID']);
    check(RECOMMENDATION_IDS.includes(item.id), `${path}.id`, 'unknown maintenance idea');
    text(item.title, `${path}.title`, 120); text(item.detail, `${path}.detail`);
    text(item.diyTitle, `${path}.diyTitle`, 120);
    check(typeof item.symbol === 'string' && /^[a-z][a-z0-9.]{0,79}$/.test(item.symbol), `${path}.symbol`, 'invalid symbol');
    list(item.supplies, `${path}.supplies`, 1, 75);
    for (const [index, supply] of item.supplies.entries()) {
      const field = `${path}.supplies[${index}]`;
      object(supply, field, ['name', 'quantity', 'unit', 'isEquipment']);
      text(supply.name, `${field}.name`, 120); integer(supply.quantity, `${field}.quantity`, 1, 9999);
      check(supply.unit === 'ea' && typeof supply.isEquipment === 'boolean', field, 'schema 1 supplies use individually counted items');
    }
    unique(item.supplies, `${path}.supplies`, (supply) => `${supply.name.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/\s+/g, ' ')}\x1f${supply.unit}`);
    check(item.professionalGuideID === item.id + '-professional' && item.diyGuideID === item.id + '-diy', path, 'guide IDs must match the task');
    const pro = guides.get(item.professionalGuideID), diy = guides.get(item.diyGuideID);
    check(pro && diy && pro.basis === (item.id === 'filter' ? 'labor' : 'installed') &&
      pro.unit === (item.id === 'filter' ? 'hour' : 'job') && diy.unit === 'item' &&
      ['materials', 'retailExample'].includes(diy.basis), path, 'missing or incompatible professional/DIY guides');
    check(directories.has(item.providerDirectoryID), path, 'unknown contractor directory');
    check(item.resaleAssumptionID === null || (item.id === 'closet' &&
      resale.get(item.resaleAssumptionID)?.costGuideID === item.professionalGuideID), path, 'unsupported resale assumption');
  }
  // Paid referrals require an approved, disclosed integration. No paid partner is configured
  // in the current app. A catalog change alone must not silently turn one on.
  list(value.referralPartners, 'referralPartners', 0, 0);
  check(Buffer.byteLength(JSON.stringify(value)) <= MAX_CATALOG_BYTES, 'catalog', 'exceeds the response size limit');
  return value;
}

export function loadCatalog(path = new URL('../data/home-catalog.json', import.meta.url)) {
  const bytes = readFileSync(path);
  check(bytes.length <= MAX_CATALOG_BYTES, 'catalog', 'exceeds the response size limit');
  return validateCatalog(JSON.parse(bytes.toString('utf8')));
}

/** Isolate the served snapshot from later caller mutations; deployments change it atomically. */
export function createCatalogResource(catalog = loadCatalog()) {
  const snapshot = structuredClone(validateCatalog(catalog));
  const body = JSON.stringify(snapshot);
  return Object.freeze({
    body,
    etag: `"${createHash('sha256').update(body).digest('hex')}"`,
    lastModified: new Date(snapshot.publishedAt).toUTCString(),
  });
}

function header(headers, name) {
  if (typeof headers.get === 'function') return headers.get(name);
  const key = Object.keys(headers).find((key) => key.toLowerCase() === name);
  const value = key === undefined ? undefined : headers[key];
  return Array.isArray(value) ? value.join(', ') : value;
}

/** Route after the existing app-key gate. No request body, account or household data is needed. */
export function catalogResponse(resource, { method = 'GET', headers = {} } = {}) {
  const common = {
    'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'private, max-age=3600',
    Vary: 'X-Home-Key',
    ETag: resource.etag,
    'Last-Modified': resource.lastModified,
  };
  if (!['GET', 'HEAD'].includes(method)) {
    return { status: 405, body: JSON.stringify({ error: 'method_not_allowed' }),
      headers: { 'Content-Type': common['Content-Type'], 'Cache-Control': 'no-store', Allow: 'GET, HEAD' } };
  }
  const ifNoneMatch = header(headers, 'if-none-match');
  const ifModifiedSince = header(headers, 'if-modified-since');
  // If-None-Match has precedence even when no supplied tag matches. GET and HEAD
  // use weak comparison; multiple entity tags and the wildcard are supported.
  const unmodified = typeof ifNoneMatch === 'string'
    ? ifNoneMatch.split(',').some((tag) => tag.trim() === '*' || tag.trim().replace(/^W\//, '') === resource.etag)
    : typeof ifModifiedSince === 'string' && Number.isFinite(Date.parse(ifModifiedSince)) &&
      Date.parse(resource.lastModified) <= Date.parse(ifModifiedSince);
  if (unmodified) return { status: 304, body: null, headers: common };
  return { status: 200, body: method === 'HEAD' ? null : resource.body,
    headers: { ...common, 'Content-Length': String(Buffer.byteLength(resource.body)) } };
}
