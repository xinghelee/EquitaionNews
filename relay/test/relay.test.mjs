import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { matchLevel } from '../lib/match.mjs';
import { NewsSource, fromWs, fromMcp, isStale, Dedupe } from '../lib/news.mjs';
import { makeJwt, JwtCache, buildPayload, collapseId } from '../lib/apns.mjs';
import { DeviceStore, validateRegistration } from '../lib/store.mjs';
import { createServer } from '../lib/http.mjs';

const NOW = Date.parse('2026-11-18T12:00:00Z');

const mcpItem = (o = {}) => ({
  no: 15774,
  time: new Date(NOW - 5000).toISOString(),
  channels: ['main'],
  source: 'AggrNews',
  zh: '*德国法官提议撤销 Movie2K 案\n\n*此前提议移交 56,000 BTC',
  en: '*GERMAN JUDGE PROPOSES DROPPING MOVIE2K CASE\n\n*PREVIOUS PROPOSAL',
  coins: ['BTC'],
  url: 'https://eqn.news/main/15774',
  source_url: 'https://x.com/AggrNews/status/1',
  ...o,
});

const wsFrame = (o = {}) => ({
  source_name: 'AggrNews',
  news_title: '*德国法官提议撤销 Movie2K 案\n\n*此前提议移交 56,000 BTC',
  coins_included: ['BTC'],
  url: 'https://x.com/AggrNews/status/1',
  timestamp: Math.floor((NOW - 3000) / 1000),
  ...o,
});

// ---------------- matching ----------------
test('matchLevel: no rules / no match -> null', () => {
  const item = fromMcp(mcpItem());
  assert.equal(matchLevel([], item), null);
  assert.equal(matchLevel([{ kind: 'coin', value: 'ETH', level: 'loud' }], item), null);
});

test('matchLevel: coin is case-insensitive', () => {
  const item = fromMcp(mcpItem());
  assert.equal(matchLevel([{ kind: 'coin', value: 'btc', level: 'notify' }], item), 'notify');
});

test('matchLevel: keyword searches zh and en, case-insensitive', () => {
  const item = fromMcp(mcpItem());
  assert.equal(matchLevel([{ kind: 'keyword', value: 'movie2k', level: 'loud' }], item), 'loud');
  assert.equal(matchLevel([{ kind: 'keyword', value: '法官', level: 'notify' }], item), 'notify');
  assert.equal(matchLevel([{ kind: 'keyword', value: 'judge', level: 'notify' }], item), 'notify');
  assert.equal(matchLevel([{ kind: 'keyword', value: 'nothing', level: 'notify' }], item), null);
});

test('matchLevel: channel', () => {
  const item = fromMcp(mcpItem({ channels: ['pricechange'] }));
  assert.equal(matchLevel([{ kind: 'channel', value: 'pricechange', level: 'notify' }], item), 'notify');
  assert.equal(matchLevel([{ kind: 'channel', value: 'main', level: 'notify' }], item), null);
});

test('matchLevel: highest level wins; none mutes only when nothing higher', () => {
  const item = fromMcp(mcpItem());
  const rules = [
    { kind: 'channel', value: 'main', level: 'notify' },
    { kind: 'coin', value: 'BTC', level: 'loud' },
    { kind: 'keyword', value: 'judge', level: 'none' },
  ];
  assert.equal(matchLevel(rules, item), 'loud');
  assert.equal(matchLevel([
    { kind: 'channel', value: 'main', level: 'notify' },
    { kind: 'keyword', value: 'judge', level: 'none' },
  ], item), 'notify');
  assert.equal(matchLevel([{ kind: 'keyword', value: 'judge', level: 'none' }], item), null);
});

// ---------------- dedupe / stale ----------------
test('dedupe: same news via WS then MCP is emitted once', () => {
  const src = new NewsSource({ ws: false, mcp: false });
  const out = [];
  src.on('news', (n) => out.push(n));
  assert.equal(src.ingest(fromWs(wsFrame()), NOW), true);
  assert.equal(src.ingest(fromMcp(mcpItem()), NOW), false);
  assert.equal(out.length, 1);
  assert.equal(out[0].via, 'ws');
});

test('dedupe: MCP first then WS (title differs only by whitespace)', () => {
  const src = new NewsSource({ ws: false, mcp: false });
  let n = 0;
  src.on('news', () => n++);
  assert.equal(src.ingest(fromMcp(mcpItem()), NOW), true);
  const frame = wsFrame({ news_title: '*德国法官提议撤销Movie2K案 *此前提议移交56,000BTC', url: null });
  assert.equal(src.ingest(fromWs(frame), NOW), false);
  assert.equal(n, 1);
});

test('dedupe: matches on source_url alone, and on eqn url', () => {
  const src = new NewsSource({ ws: false, mcp: false });
  src.ingest(fromMcp(mcpItem()), NOW);
  assert.equal(src.ingest(fromWs(wsFrame({ news_title: 'totally different' })), NOW), false);
  assert.equal(src.ingest(fromMcp(mcpItem({ zh: 'x', en: 'y', source_url: null })), NOW), false);
  assert.equal(src.ingest(fromMcp(mcpItem({ no: 2, zh: 'new', en: 'new', url: 'https://eqn.news/main/2', source_url: null })), NOW), true);
});

test('dedupe: LRU evicts oldest keys', () => {
  const d = new Dedupe(3);
  d.add(['a']); d.add(['b']); d.add(['c']); d.add(['d']);
  assert.equal(d.map.has('a'), false);
  assert.equal(d.add(['a']), true);
  assert.equal(d.add(['d']), false);
});

test('stale: items older than 180s are skipped', () => {
  const src = new NewsSource({ ws: false, mcp: false });
  let n = 0;
  src.on('news', () => n++);
  const old = fromMcp(mcpItem({ time: new Date(NOW - 181_000).toISOString() }));
  assert.equal(isStale(old, NOW), true);
  assert.equal(src.ingest(old, NOW), false);
  const oldWs = fromWs(wsFrame({ news_title: 'other', url: null, timestamp: Math.floor((NOW - 200_000) / 1000) }));
  assert.equal(src.ingest(oldWs, NOW), false);
  const fresh = fromMcp(mcpItem({ no: 9, zh: 'fresh', en: 'fresh', url: 'https://eqn.news/main/9', source_url: null, time: new Date(NOW - 179_000).toISOString() }));
  assert.equal(src.ingest(fresh, NOW), true);
  assert.equal(n, 1);
});

// ---------------- JWT ----------------
test('JWT: ES256 header/claims and verifiable P-256 signature', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwt = makeJwt({ key: pem, keyId: 'ABC123DEFG', teamId: 'TEAM123456', iat: 1700000000 });
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url')), { iss: 'TEAM123456', iat: 1700000000 });
  const sig = Buffer.from(s, 'base64url');
  assert.equal(sig.length, 64); // raw r||s, not DER
  assert.ok(verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, sig));
  assert.doesNotMatch(jwt, /[=+/]/);
});

test('JwtCache: reuses token and refreshes after ttl', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  let t = NOW;
  const cache = new JwtCache({ key: privateKey, keyId: 'K', teamId: 'T', now: () => t });
  const a = cache.get();
  t += 49 * 60_000;
  assert.equal(cache.get(), a);
  t += 2 * 60_000;
  assert.notEqual(cache.get(), a);
});

// ---------------- payload ----------------
test('buildPayload: loud main item', () => {
  const item = fromMcp(mcpItem());
  const p = buildPayload(item, 'loud');
  assert.deepEqual(p, {
    aps: {
      alert: { title: '方程式新闻 · AggrNews', body: '德国法官提议撤销 Movie2K 案' },
      sound: 'default',
      'thread-id': 'main',
      'interruption-level': 'time-sensitive',
      'relevance-score': 1,
    },
    url: 'https://eqn.news/main/15774',
    no: 15774,
  });
});

test('buildPayload: notify, other channel, en fallback, WS item without no', () => {
  const p = buildPayload(fromMcp(mcpItem({ channels: ['pricechange'], zh: null, en: 'Price Monitor: X +9%' })), 'notify');
  assert.equal(p.aps.alert.title, '价格异动 · AggrNews');
  assert.equal(p.aps.alert.body, 'Price Monitor: X +9%');
  assert.equal(p.aps['interruption-level'], 'active');
  assert.equal(p.aps['relevance-score'], 0.5);
  assert.equal(p.aps['thread-id'], 'pricechange');

  const w = buildPayload(fromWs(wsFrame()), 'notify');
  assert.equal(w.no, undefined);
  assert.equal(w.url, 'https://x.com/AggrNews/status/1');
  assert.equal(w.aps.alert.body, '德国法官提议撤销 Movie2K 案');
});

test('collapseId: ≤64 bytes', () => {
  assert.equal(collapseId('eqn-1'), 'eqn-1');
  assert.ok(Buffer.byteLength(collapseId('中'.repeat(40))) <= 64);
});

// ---------------- store / validation / http ----------------
test('validateRegistration', () => {
  const tok = 'ab'.repeat(32);
  assert.equal(validateRegistration({ token: 'zz', env: 'sandbox', rules: [] }).ok, false);
  assert.equal(validateRegistration({ token: tok, env: 'dev', rules: [] }).ok, false);
  assert.equal(validateRegistration({ token: tok, env: 'sandbox', rules: [{ kind: 'x', value: 'a', level: 'loud' }] }).ok, false);
  assert.equal(validateRegistration({ token: tok, env: 'sandbox', rules: [{ kind: 'coin', value: 'a', level: 'max' }] }).ok, false);
  const v = validateRegistration({ token: tok.toUpperCase(), env: 'sandbox', rules: [{ kind: 'coin', value: ' BTC ', level: 'loud' }] });
  assert.deepEqual(v.value, { token: tok, env: 'sandbox', rules: [{ kind: 'coin', value: 'BTC', level: 'loud' }] });
});

test('http: register / health / delete / secret / persistence', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'relay-test-'));
  const path = join(dir, 'sub', 'devices.json');
  let server;
  try {
    const store = await new DeviceStore(path).load();
    server = createServer({ store, secret: 's3cret', log: () => {}, health: () => ({ ws: 'open', lastItemAt: null }) });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const base = `http://127.0.0.1:${server.address().port}`;
    const tok = 'cd'.repeat(32);
    const body = JSON.stringify({ token: tok, env: 'sandbox', rules: [{ kind: 'coin', value: 'BTC', level: 'loud' }] });

    let r = await fetch(`${base}/register`, { method: 'POST', body });
    assert.equal(r.status, 401);
    r = await fetch(`${base}/register`, { method: 'POST', body: 'x'.repeat(70_000), headers: { 'x-relay-secret': 's3cret' } });
    assert.equal(r.status, 413);
    r = await fetch(`${base}/register`, { method: 'POST', body: '{bad', headers: { 'x-relay-secret': 's3cret' } });
    assert.equal(r.status, 400);
    r = await fetch(`${base}/register`, { method: 'POST', body, headers: { 'x-relay-secret': 's3cret' } });
    assert.equal(r.status, 200);

    r = await fetch(`${base}/health`);
    assert.deepEqual(await r.json(), { ok: true, devices: 1, ws: 'open', lastItemAt: null });

    const reloaded = await new DeviceStore(path).load();
    assert.equal(reloaded.all()[0].token, tok);

    r = await fetch(`${base}/register`, { method: 'DELETE', body: JSON.stringify({ token: tok }), headers: { 'x-relay-secret': 's3cret' } });
    assert.deepEqual(await r.json(), { ok: true, removed: true });
    assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), { devices: [] });
  } finally {
    server?.closeAllConnections();
    server?.close();
    await rm(dir, { recursive: true, force: true });
  }
});
