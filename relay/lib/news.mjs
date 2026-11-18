// 新闻源：WebSocket（main 实时）+ MCP list_news 轮询（全频道），两路去重后统一发出。
// 逻辑沿用 ../eqn-client.mjs。
import { EventEmitter } from 'node:events';
import { createHash } from 'node:crypto';

export const WS_URL = 'wss://api.eqn.news/public/ws';
export const MCP_URL = 'https://api.eqn.news/public/mcp';
export const STALE_MS = 180_000;

const norm = (s) => (s ?? '').replace(/\s+/g, '').slice(0, 60);
const titleKey = (s) => (norm(s) ? `t:${norm(s)}` : null);

/** WS 帧 -> 统一结构 */
export function fromWs(m) {
  const keys = [titleKey(m.news_title), m.url && `u:${m.url}`].filter(Boolean);
  return {
    via: 'ws',
    no: null,
    zh: m.news_title ?? null,
    en: null,
    source: m.source_name ?? '',
    coins: m.coins_included ?? [],
    url: null, // WS 的 url 是原文链接，不是 eqn 链接
    sourceUrl: m.url ?? null,
    channels: ['main'],
    publishedAt: m.timestamp ? m.timestamp * 1000 : null,
    keys,
  };
}

/** MCP item -> 统一结构 */
export function fromMcp(it, via = 'mcp') {
  const keys = [
    it.url && `e:${it.url}`, titleKey(it.zh), titleKey(it.en), it.source_url && `u:${it.source_url}`,
  ].filter(Boolean);
  return {
    via,
    no: it.no ?? null,
    zh: it.zh ?? null,
    en: it.en ?? null,
    source: it.source ?? '',
    coins: it.coins ?? [],
    url: it.url ?? null,
    sourceUrl: it.source_url ?? null,
    channels: it.channels?.length ? it.channels : ['main'],
    publishedAt: it.time ? Date.parse(it.time) : null,
    keys,
  };
}

/** 推送用的稳定 id（apns-collapse-id，≤64 字节） */
export function itemKey(item) {
  if (item.no != null) return `eqn-${item.no}`;
  return 'eqn-' + createHash('sha1').update(item.keys[0] ?? JSON.stringify(item)).digest('hex').slice(0, 32);
}

export function isStale(item, now = Date.now(), maxAge = STALE_MS) {
  return item.publishedAt != null && Number.isFinite(item.publishedAt) && now - item.publishedAt > maxAge;
}

/** 基于 Map 插入顺序的 LRU 去重 */
export class Dedupe {
  constructor(size = 5000) { this.size = size; this.map = new Map(); }
  /** 记录 keys；任何一个 key 已见过则返回 false */
  add(keys) {
    const known = keys.some((k) => this.map.has(k));
    for (const k of keys) { this.map.delete(k); this.map.set(k, true); }
    while (this.map.size > this.size) this.map.delete(this.map.keys().next().value);
    return !known;
  }
}

/**
 * events: 'news' (item), 'status' ({type,...})
 */
export class NewsSource extends EventEmitter {
  constructor(opts = {}) {
    super();
    this.pollMs = opts.pollMs ?? 1000;
    this.limit = opts.limit ?? 50;
    this.useWs = opts.ws ?? true;
    this.useMcp = opts.mcp ?? true;
    this.dedupe = new Dedupe(opts.dedupeSize ?? 5000);
    this.staleMs = opts.staleMs ?? STALE_MS;
    this.wsState = 'idle';
    this.mcpState = 'idle';
    this.lastItemAt = null;
    this._timers = new Set();
    this._backoff = 1000;
    this._rpcId = 0;
    this._warm = false;
    this._wsDownSince = null;
  }

  start() {
    if (this._running) return this;
    this._running = true;
    if (this.useWs) this._connectWs();
    if (this.useMcp) this._poll();
    return this;
  }

  stop() {
    this._running = false;
    for (const t of this._timers) clearTimeout(t);
    this._timers.clear();
    clearInterval(this._hb);
    try { this._ws?.close(1000); } catch {}
  }

  /** 处理一条已规范化的新闻；返回是否发出 */
  ingest(item, now = Date.now()) {
    if (!item.keys.length) return false;
    if (!this.dedupe.add(item.keys)) return false;
    if (isStale(item, now, this.staleMs)) {
      this.emit('status', { type: 'stale_skip', via: item.via, key: itemKey(item) });
      return false;
    }
    item.key = itemKey(item);
    item.receivedAt = now;
    this.lastItemAt = now;
    this.emit('news', item);
    return true;
  }

  _later(fn, ms) {
    const t = setTimeout(() => { this._timers.delete(t); fn(); }, ms);
    this._timers.add(t);
  }

  // ---------- WebSocket ----------
  _connectWs() {
    if (!this._running) return;
    this.wsState = 'connecting';
    const ws = new WebSocket(WS_URL);
    this._ws = ws;
    ws.onopen = () => {
      this.wsState = 'open';
      this._backoff = 1000;
      this.emit('status', { type: 'ws_open' });
      clearInterval(this._hb);
      this._hb = setInterval(() => ws.readyState === WebSocket.OPEN && ws.send('ping'), 30_000);
      if (this._wsDownSince) {
        const since = this._wsDownSince;
        this._wsDownSince = null;
        this._gapFill(since).catch((e) => this.emit('status', { type: 'gap_fill_error', message: e.message }));
      }
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data !== 'string' || ev.data === 'pong') return;
      let m;
      try { m = JSON.parse(ev.data); } catch { return; }
      if (!m || typeof m !== 'object') return;
      this.ingest(fromWs(m));
    };
    ws.onclose = (ev) => {
      clearInterval(this._hb);
      this.wsState = 'closed';
      if (!this._running) return;
      this._wsDownSince ??= Date.now();
      const delay = ev.code === 1012 ? 1000 + Math.random() * 4000
        : this._backoff + Math.random() * this._backoff * 0.3;
      this.emit('status', { type: 'ws_close', code: ev.code, retryInMs: Math.round(delay) });
      this._backoff = Math.min(this._backoff * 2, 30_000);
      this._later(() => this._connectWs(), delay);
    };
    ws.onerror = () => {};
  }

  async _gapFill(since) {
    if (!this.useMcp) return;
    const items = await this._listNews('main', 50);
    const cutoff = since - 60_000;
    for (const it of items.slice().reverse()) {
      if (Date.parse(it.time) >= cutoff) this.ingest(fromMcp(it, 'gapfill'));
    }
  }

  // ---------- MCP ----------
  async _listNews(channel, limit) {
    const res = await fetch(MCP_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({
        jsonrpc: '2.0', id: ++this._rpcId, method: 'tools/call',
        params: { name: 'list_news', arguments: { channel, limit } },
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 429) {
      const err = new Error('MCP 429 rate limited');
      err.retryAfterMs = (Number(res.headers.get('retry-after')) || 10) * 1000;
      throw err;
    }
    if (!res.ok) throw new Error(`MCP HTTP ${res.status}`);
    const j = await res.json();
    if (j.error) throw new Error(`MCP error: ${j.error.message}`);
    if (j.result?.isError) throw new Error(`MCP tool error: ${j.result.content?.[0]?.text}`);
    return j.result?.structuredContent?.items ?? [];
  }

  async _poll() {
    if (!this._running) return;
    let next = this.pollMs;
    try {
      const items = await this._listNews('all', this.limit);
      const ordered = items.slice().reverse(); // 旧 -> 新
      if (!this._warm) {
        this._warm = true;
        for (const it of ordered) this.dedupe.add(fromMcp(it).keys);
        this.emit('status', { type: 'mcp_ready', baseline: items.length });
      } else {
        for (const it of ordered) this.ingest(fromMcp(it));
      }
      if (this.mcpState !== 'ok') {
        if (this.mcpState === 'error') this.emit('status', { type: 'mcp_recovered' });
        this.mcpState = 'ok';
      }
    } catch (e) {
      this.mcpState = 'error';
      next = e.retryAfterMs ?? Math.max(this.pollMs, 3000);
      this.emit('status', { type: 'mcp_error', message: e.message, retryInMs: next });
    }
    this._later(() => this._poll(), next);
  }
}
