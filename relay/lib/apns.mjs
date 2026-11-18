// APNs：ES256 JWT（token-based auth）+ node:http2，按 host 复用会话
import http2 from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

export const HOSTS = {
  sandbox: 'api.sandbox.push.apple.com',
  production: 'api.push.apple.com',
};

export const CHANNEL_NAMES = {
  main: '方程式新闻',
  tradfi: '方程式财经',
  binance: '币安公告',
  tier2: '二线上新',
  tier3: '三线上新',
  korea: '韩所监控',
  alpha: '币安Alpha',
  hl: 'Hyperliquid',
  pricechange: '价格异动',
  major: '大幅波动',
  tfmoves: '美股重大行情',
  oi: 'OI价格异动',
  cz: 'CZ&何一',
  earn: '理财提醒',
};

const b64url = (buf) => Buffer.from(buf).toString('base64url');

/** 生成 APNs provider JWT。key 为 KeyObject 或 PEM 字符串 */
export function makeJwt({ key, keyId, teamId, iat = Math.floor(Date.now() / 1000) }) {
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat }));
  const input = `${header}.${claims}`;
  const k = typeof key === 'string' ? createPrivateKey(key) : key;
  const sig = sign('sha256', Buffer.from(input), { key: k, dsaEncoding: 'ieee-p1363' });
  return `${input}.${b64url(sig)}`;
}

/** 缓存 JWT，约 50 分钟刷新一次（Apple 要求 20–60 分钟之间） */
export class JwtCache {
  constructor({ key, keyId, teamId, ttlMs = 50 * 60_000, now = () => Date.now() }) {
    Object.assign(this, { key, keyId, teamId, ttlMs, now });
    this.token = null;
    this.at = 0;
  }
  get() {
    const t = this.now();
    if (!this.token || t - this.at >= this.ttlMs) {
      this.token = makeJwt({ key: this.key, keyId: this.keyId, teamId: this.teamId, iat: Math.floor(t / 1000) });
      this.at = t;
    }
    return this.token;
  }
}

const stripStar = (s) => s.replace(/^\s*\*+\s*/, '');

function firstLine(s) {
  return (s ?? '').split('\n').map((l) => l.trim()).find(Boolean) ?? '';
}

export function primaryChannel(item) {
  return (item.channels ?? []).find((c) => c !== 'all') ?? 'main';
}

/** 构造 APNs payload */
export function buildPayload(item, level) {
  const ch = primaryChannel(item);
  const chName = CHANNEL_NAMES[ch] ?? ch;
  const loud = level === 'loud';
  let body = stripStar(firstLine(item.zh) || firstLine(item.en));
  if (body.length > 200) body = body.slice(0, 199) + '…';
  const payload = {
    aps: {
      alert: {
        title: item.source ? `${chName} · ${item.source}` : chName,
        body,
      },
      sound: 'default',
      'thread-id': ch,
      'interruption-level': loud ? 'time-sensitive' : 'active',
      'relevance-score': loud ? 1 : 0.5,
    },
  };
  const url = item.url ?? item.sourceUrl;
  if (url) payload.url = url;
  if (item.no != null) payload.no = item.no;
  return payload;
}

/** 截断到 ≤64 字节（按 UTF-8） */
export function collapseId(key) {
  let s = String(key);
  while (Buffer.byteLength(s) > 64) s = s.slice(0, -1);
  return s;
}

export class ApnsClient {
  /**
   * @param {object} o
   * @param {JwtCache|null} o.jwt  null => dry-run
   * @param {string} o.topic
   * @param {(msg:string)=>void} [o.log]
   */
  constructor({ jwt, topic, log = console.log }) {
    this.jwt = jwt;
    this.topic = topic;
    this.log = log;
    this.sessions = new Map();
  }

  get dryRun() { return !this.jwt; }

  _session(host) {
    let s = this.sessions.get(host);
    if (s && !s.closed && !s.destroyed) return s;
    s = http2.connect(`https://${host}`);
    const drop = () => { if (this.sessions.get(host) === s) this.sessions.delete(host); };
    s.on('error', (e) => { this.log(`[apns] session ${host} error: ${e.message}`); drop(); });
    s.on('close', drop);
    s.on('goaway', drop);
    s.setTimeout(60 * 60_000, () => s.close()); // 空闲 1 小时关闭
    this.sessions.set(host, s);
    return s;
  }

  /**
   * 发送一条推送。返回 {ok, status, reason, unregister}
   */
  async send({ token, env }, payload, { key, priority = 10 } = {}) {
    const host = HOSTS[env] ?? HOSTS.production;
    if (this.dryRun) {
      this.log(`[dry-run] -> ${env} ${token.slice(0, 8)}… ${JSON.stringify(payload)}`);
      return { ok: true, status: 0, dryRun: true };
    }
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      'apns-topic': this.topic,
      'apns-push-type': 'alert',
      'apns-priority': String(priority),
      authorization: `bearer ${this.jwt.get()}`,
    };
    if (key) headers['apns-collapse-id'] = collapseId(key);
    const body = JSON.stringify(payload);
    const attempt = () => new Promise((resolve, reject) => {
      let req;
      try { req = this._session(host).request(headers); } catch (e) { return reject(e); }
      let status = 0;
      let data = '';
      req.setEncoding('utf8');
      req.setTimeout(10_000, () => req.close(http2.constants.NGHTTP2_CANCEL));
      req.on('response', (h) => { status = h[':status']; });
      req.on('data', (c) => { data += c; });
      req.on('end', () => resolve({ status, data }));
      req.on('error', reject);
      req.end(body);
    });
    let res;
    try {
      res = await attempt();
    } catch (e) {
      // 会话可能已失效：丢弃后重试一次
      this.sessions.get(host)?.destroy();
      this.sessions.delete(host);
      try { res = await attempt(); } catch (e2) {
        this.log(`[apns] ${token.slice(0, 8)}… network error: ${e2.message}`);
        return { ok: false, status: 0, reason: e2.message };
      }
    }
    if (res.status === 200) return { ok: true, status: 200 };
    let reason = '';
    try { reason = JSON.parse(res.data).reason ?? ''; } catch {}
    const unregister = res.status === 410
      || (res.status === 400 && (reason === 'BadDeviceToken' || reason === 'Unregistered'));
    this.log(`[apns] ${token.slice(0, 8)}… failed ${res.status} ${reason}`);
    return { ok: false, status: res.status, reason, unregister };
  }

  close() {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}
