// In-app feedback: validation, Postgres storage, a small rate limiter and the read-only admin page.
// The database client is injected (anything with `query(text, params) -> { rows }`), so tests use a fake
// and never need a real Postgres. Production uses a `pg.Pool` built from DATABASE_URL.

export const CATEGORIES = ['bug', 'polish', 'idea'];
export const STATUSES = ['new', 'triaged', 'done'];
export const MAX_MESSAGE = 5000;
const MAX_CONTEXT_BYTES = 4096;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS feedback (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  category       text NOT NULL CHECK (category IN ('bug', 'polish', 'idea')),
  message        text NOT NULL CHECK (char_length(message) BETWEEN 1 AND ${MAX_MESSAGE}),
  page           text,
  screen_context jsonb,
  app_version    text,
  build_number   text,
  os_version     text,
  device_model   text,
  install_id     text,
  status         text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'triaged', 'done'))
);
CREATE INDEX IF NOT EXISTS feedback_created_at_idx ON feedback (created_at DESC);
`;

export class ValidationError extends Error {}

export function isUuid(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

function optionalString(body, key, max) {
  const v = body[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== 'string') throw new ValidationError(`${key} must be a string.`);
  const t = v.trim();
  if (t.length > max) throw new ValidationError(`${key} must be at most ${max} characters.`);
  return t === '' ? null : t;
}

/**
 * Checks a POST /v1/feedback body and returns the row to insert. Unknown fields are ignored.
 * @param {unknown} body
 */
export function validateFeedback(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new ValidationError('Body must be a JSON object.');
  if (!CATEGORIES.includes(body.category)) throw new ValidationError(`category must be one of ${CATEGORIES.join(', ')}.`);
  if (typeof body.message !== 'string') throw new ValidationError('message is required.');
  const message = body.message.trim();
  // Count characters (code points), matching Postgres char_length.
  const length = [...message].length;
  if (length < 1) throw new ValidationError('message must not be empty.');
  if (length > MAX_MESSAGE) throw new ValidationError(`message must be at most ${MAX_MESSAGE} characters.`);

  let screenContext = null;
  if (body.screenContext !== undefined && body.screenContext !== null) {
    const ctx = body.screenContext;
    if (typeof ctx !== 'object' || Array.isArray(ctx)) throw new ValidationError('screenContext must be a JSON object.');
    if (Buffer.byteLength(JSON.stringify(ctx)) > MAX_CONTEXT_BYTES) {
      throw new ValidationError(`screenContext must be at most ${MAX_CONTEXT_BYTES} bytes.`);
    }
    screenContext = ctx;
  }

  return {
    category: body.category,
    message,
    page: optionalString(body, 'page', 200),
    screenContext,
    appVersion: optionalString(body, 'appVersion', 50),
    buildNumber: optionalString(body, 'buildNumber', 50),
    osVersion: optionalString(body, 'osVersion', 50),
    deviceModel: optionalString(body, 'deviceModel', 100),
    installId: optionalString(body, 'installId', 100),
  };
}

function toApi(row) {
  return {
    id: row.id,
    createdAt: row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at,
    category: row.category,
    message: row.message,
    page: row.page ?? null,
    screenContext: row.screen_context ?? null,
    appVersion: row.app_version ?? null,
    buildNumber: row.build_number ?? null,
    osVersion: row.os_version ?? null,
    deviceModel: row.device_model ?? null,
    installId: row.install_id ?? null,
    status: row.status,
  };
}

const COLUMNS = 'id, created_at, category, message, page, screen_context, app_version, build_number, os_version, device_model, install_id, status';

/** Feedback table access over an injected client (`query(text, params) -> { rows }`). */
export class FeedbackStore {
  /** @param {{ query: (text: string, params?: unknown[]) => Promise<{ rows: any[] }> }} db */
  constructor(db) {
    this.db = db;
    this.schemaPromise = null;
  }

  /** Creates the table if missing. Memoized; retried after a failure. */
  ensureSchema() {
    if (!this.schemaPromise) {
      this.schemaPromise = this.db.query(SCHEMA_SQL).then(
        () => undefined,
        (err) => {
          this.schemaPromise = null;
          throw err;
        },
      );
    }
    return this.schemaPromise;
  }

  async insert(f) {
    await this.ensureSchema();
    const { rows } = await this.db.query(
      `INSERT INTO feedback (category, message, page, screen_context, app_version, build_number, os_version, device_model, install_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING id, created_at`,
      [f.category, f.message, f.page, f.screenContext === null ? null : JSON.stringify(f.screenContext),
        f.appVersion, f.buildNumber, f.osVersion, f.deviceModel, f.installId],
    );
    return { id: rows[0].id, createdAt: rows[0].created_at instanceof Date ? rows[0].created_at.toISOString() : rows[0].created_at };
  }

  /** Newest first. */
  async list({ status = null, category = null, limit = 100 } = {}) {
    await this.ensureSchema();
    const where = [];
    const params = [];
    if (status) {
      params.push(status);
      where.push(`status = $${params.length}`);
    }
    if (category) {
      params.push(category);
      where.push(`category = $${params.length}`);
    }
    params.push(limit);
    const { rows } = await this.db.query(
      `SELECT ${COLUMNS} FROM feedback ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY created_at DESC, id LIMIT $${params.length}`,
      params,
    );
    return rows.map(toApi);
  }

  /** Returns the updated row, or null when the id doesn't exist. */
  async setStatus(id, status) {
    await this.ensureSchema();
    const { rows } = await this.db.query(`UPDATE feedback SET status = $2 WHERE id = $1 RETURNING ${COLUMNS}`, [id, status]);
    return rows[0] ? toApi(rows[0]) : null;
  }
}

/**
 * Builds a `pg.Pool` for DATABASE_URL. Render's internal URL (host `dpg-…`, private network) needs no TLS; the
 * external one (`….render.com`) requires it. DATABASE_SSL=true/false overrides the guess, and an explicit
 * `?sslmode=` in the URL is left to pg.
 */
export async function createPgPool(databaseUrl, env = process.env, log = console.log) {
  const { default: pg } = await import('pg');
  let host = '';
  let hasSslMode = false;
  try {
    const u = new URL(databaseUrl);
    host = u.hostname;
    hasSslMode = u.searchParams.has('sslmode');
  } catch {
    // pg reports a malformed URL itself.
  }
  const override = env.DATABASE_SSL?.trim().toLowerCase();
  const useSsl = override ? ['1', 'true', 'yes', 'require'].includes(override) : !hasSslMode && host.endsWith('.render.com');
  const pool = new pg.Pool({
    connectionString: databaseUrl,
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    ssl: useSsl ? { rejectUnauthorized: false } : undefined,
  });
  pool.on('error', (err) => log(`postgres pool error: ${err.message}`));
  return pool;
}

/** Fixed-window counter per key (in memory; resets on restart, which is fine for 2–5 testers). */
export class RateLimiter {
  constructor({ limit = 30, windowMs = 60 * 60 * 1000, now = Date.now } = {}) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.windows = new Map();
  }

  /** Counts one hit. Returns { ok: true } or { ok: false, retryAfterS }. */
  hit(key) {
    const t = this.now();
    if (this.windows.size > 10_000) {
      for (const [k, w] of this.windows) if (w.resetAt <= t) this.windows.delete(k);
    }
    let w = this.windows.get(key);
    if (!w || w.resetAt <= t) {
      w = { count: 0, resetAt: t + this.windowMs };
      this.windows.set(key, w);
    }
    if (w.count >= this.limit) return { ok: false, retryAfterS: Math.max(1, Math.ceil((w.resetAt - t) / 1000)) };
    w.count += 1;
    return { ok: true };
  }
}

// ---------- admin page ----------

const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const CATEGORY_LABEL = { bug: 'Bug', polish: 'Polish', idea: 'Idea' };

/**
 * Read-only HTML list of feedback, newest first, with filter links.
 * @param {{ items: ReturnType<typeof toApi>[], status: string|null, category: string|null, limit: number, key: string|null }} opts
 */
export function renderAdminPage({ items, status, category, limit, key }) {
  const link = (next) => {
    const p = new URLSearchParams();
    if (key) p.set('key', key);
    const s = 'status' in next ? next.status : status;
    const c = 'category' in next ? next.category : category;
    if (s) p.set('status', s);
    if (c) p.set('category', c);
    if (limit !== 200) p.set('limit', String(limit));
    const q = p.toString();
    return `/admin/feedback${q ? `?${q}` : ''}`;
  };
  const pill = (label, active, href) =>
    `<a class="pill${active ? ' on' : ''}" href="${escapeHtml(href)}">${escapeHtml(label)}</a>`;

  const statusPills = [pill('All statuses', !status, link({ status: null }))]
    .concat(STATUSES.map((s) => pill(s, status === s, link({ status: s }))))
    .join('');
  const categoryPills = [pill('All categories', !category, link({ category: null }))]
    .concat(CATEGORIES.map((c) => pill(CATEGORY_LABEL[c], category === c, link({ category: c }))))
    .join('');

  const rows = items
    .map((f) => {
      const device = [f.deviceModel, f.osVersion && `iOS ${f.osVersion}`, f.appVersion && `v${f.appVersion} (${f.buildNumber ?? '?'})`]
        .filter(Boolean)
        .join(' · ');
      const ctx = f.screenContext ? `<details><summary>Screen context</summary><pre>${escapeHtml(JSON.stringify(f.screenContext, null, 2))}</pre></details>` : '';
      return `<article class="item">
  <header><span class="cat cat-${escapeHtml(f.category)}">${escapeHtml(CATEGORY_LABEL[f.category] ?? f.category)}</span>
  <span class="page">${escapeHtml(f.page ?? '—')}</span><span class="status status-${escapeHtml(f.status)}">${escapeHtml(f.status)}</span></header>
  <p class="msg">${escapeHtml(f.message)}</p>
  ${ctx}
  <footer><time datetime="${escapeHtml(f.createdAt)}">${escapeHtml(f.createdAt)}</time> · ${escapeHtml(device || 'unknown device')} · install ${escapeHtml((f.installId ?? '—').slice(0, 8))} · <code>${escapeHtml(f.id)}</code></footer>
</article>`;
    })
    .join('\n');

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Home Blueprint feedback</title>
<style>
:root{color-scheme:light dark;--bg:#f6f6f4;--card:#fff;--ink:#1c1c1e;--muted:#6b6b70;--line:#e2e2e0;--accent:#2f6fde}
@media (prefers-color-scheme:dark){:root{--bg:#141415;--card:#1f1f21;--ink:#f2f2f2;--muted:#9a9aa0;--line:#333336;--accent:#6ea0ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin:0 0 16px}
.filters{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px}.pill{padding:4px 10px;border:1px solid var(--line);border-radius:999px;color:var(--ink);text-decoration:none;font-size:13px;background:var(--card)}
.pill.on{background:var(--accent);border-color:var(--accent);color:#fff}
.item{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:12px 0}
.item header{display:flex;gap:10px;align-items:center;flex-wrap:wrap;font-size:13px}.page{font-weight:600}
.status{margin-left:auto;color:var(--muted);text-transform:uppercase;font-size:11px;letter-spacing:.05em}
.status-new{color:var(--accent)}.cat{font-weight:600;padding:1px 8px;border-radius:6px;background:var(--line)}.msg{white-space:pre-wrap;word-wrap:break-word;margin:8px 0}
.item footer{color:var(--muted);font-size:12px;word-break:break-all}pre{font-size:12px;overflow:auto}
.empty{color:var(--muted);padding:40px 0;text-align:center}
</style></head><body><main>
<h1>Feedback</h1><p class="sub">${items.length} shown, newest first (limit ${limit}). Read-only; change status with <code>PATCH /v1/feedback/:id</code>.</p>
<nav class="filters">${statusPills}</nav><nav class="filters">${categoryPills}</nav>
${rows || '<p class="empty">No feedback yet.</p>'}
</main></body></html>`;
}
