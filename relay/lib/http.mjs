// 设备注册 HTTP API
import http from 'node:http';
import { timingSafeEqual, createHash } from 'node:crypto';
import { validateRegistration, validateToken } from './store.mjs';

const MAX_BODY = 64 * 1024;

function send(res, status, obj, extra = {}) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body), ...extra });
  res.end(body);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const tooLarge = () => Object.assign(new Error('body too large'), { status: 413 });
    if (Number(req.headers['content-length']) > MAX_BODY) return reject(tooLarge());
    let size = 0;
    let done = false;
    const chunks = [];
    req.on('data', (c) => {
      if (done) return;
      size += c.length;
      if (size > MAX_BODY) { done = true; chunks.length = 0; reject(tooLarge()); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (done) return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || 'null')); }
      catch { reject(Object.assign(new Error('invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

const digest = (s) => createHash('sha256').update(String(s)).digest();
function secretOk(req, secret) {
  if (!secret) return true;
  const got = req.headers['x-relay-secret'];
  if (typeof got !== 'string') return false;
  return timingSafeEqual(digest(got), digest(secret));
}

/**
 * @param {object} o
 * @param {import('./store.mjs').DeviceStore} o.store
 * @param {() => object} o.health  返回 {ws, lastItemAt}
 * @param {string} [o.secret]
 * @param {(m:string)=>void} [o.log]
 */
export function createServer({ store, health, secret, log = console.log }) {
  return http.createServer(async (req, res) => {
    const path = (req.url ?? '/').split('?')[0];
    try {
      if (path === '/health' && req.method === 'GET') {
        return send(res, 200, { ok: true, devices: store.size, ...health() });
      }
      if (path === '/register') {
        if (req.method !== 'POST' && req.method !== 'DELETE') return send(res, 405, { error: 'method not allowed' });
        if (!secretOk(req, secret)) return send(res, 401, { error: 'unauthorized' });
        const body = await readJson(req);
        if (req.method === 'POST') {
          const v = validateRegistration(body);
          if (!v.ok) return send(res, 400, { error: v.error });
          await store.upsert(v.value);
          log(`[http] register ${v.value.token.slice(0, 8)}… env=${v.value.env} rules=${v.value.rules.length}`);
          return send(res, 200, { ok: true });
        }
        const v = validateToken(body);
        if (!v.ok) return send(res, 400, { error: v.error });
        const removed = await store.remove(v.value);
        log(`[http] unregister ${v.value.slice(0, 8)}… removed=${removed}`);
        return send(res, 200, { ok: true, removed });
      }
      return send(res, 404, { error: 'not found' });
    } catch (e) {
      if (!res.headersSent) {
        if (e.status === 413) {
          // 回 413 后关闭连接，不再读取剩余请求体
          send(res, 413, { error: e.message }, { connection: 'close' });
          res.on('finish', () => req.socket?.destroy());
        } else {
          send(res, e.status ?? 500, { error: e.status ? e.message : 'internal error' });
        }
      }
      if (!e.status) log(`[http] error: ${e.stack ?? e.message}`);
    }
  });
}
