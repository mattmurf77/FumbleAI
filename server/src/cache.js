// Small in-memory LRU cache with per-entry TTL.
// Uses Map insertion order: the first key is the least recently used.

export class LruCache {
  /**
   * @param {{ max?: number, ttlMs?: number, now?: () => number }} [opts]
   */
  constructor({ max = 500, ttlMs = 24 * 60 * 60 * 1000, now = Date.now } = {}) {
    this.max = max;
    this.ttlMs = ttlMs;
    this.now = now;
    this.map = new Map();
  }

  get(key) {
    const entry = this.map.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.now()) {
      this.map.delete(key);
      return undefined;
    }
    // Refresh recency.
    this.map.delete(key);
    this.map.set(key, entry);
    return entry.value;
  }

  set(key, value, ttlMs = this.ttlMs) {
    if (this.map.has(key)) this.map.delete(key);
    this.map.set(key, { value, expiresAt: this.now() + ttlMs });
    while (this.map.size > this.max) {
      const oldest = this.map.keys().next().value;
      this.map.delete(oldest);
    }
  }

  get size() {
    return this.map.size;
  }

  clear() {
    this.map.clear();
  }
}
