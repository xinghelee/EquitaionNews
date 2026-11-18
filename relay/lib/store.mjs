// 设备存储：内存 Map + JSON 文件（原子写：写临时文件后 rename）
import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { KINDS, LEVELS } from './match.mjs';

export class DeviceStore {
  constructor(path) {
    this.path = path;
    this.devices = new Map(); // token -> {token, env, rules, updatedAt}
    this._chain = Promise.resolve();
  }

  async load() {
    try {
      const j = JSON.parse(await readFile(this.path, 'utf8'));
      for (const d of j.devices ?? []) this.devices.set(d.token, d);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
    return this;
  }

  get size() { return this.devices.size; }
  all() { return [...this.devices.values()]; }

  upsert(dev) {
    this.devices.set(dev.token, { ...dev, updatedAt: new Date().toISOString() });
    return this.save();
  }

  remove(token) {
    const had = this.devices.delete(token);
    return had ? this.save().then(() => true) : Promise.resolve(false);
  }

  // 串行化写入，避免并发 rename 交错
  save() {
    this._chain = this._chain.then(() => this._write()).catch((e) => {
      console.error(`[store] write failed: ${e.message}`);
    });
    return this._chain;
  }

  async _write() {
    await mkdir(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.${process.pid}.tmp`;
    await writeFile(tmp, JSON.stringify({ devices: this.all() }, null, 2));
    await rename(tmp, this.path);
  }
}

/** 校验注册请求；返回 {ok, value} 或 {ok:false, error} */
export function validateRegistration(body) {
  if (!body || typeof body !== 'object') return { ok: false, error: 'body must be an object' };
  const token = typeof body.token === 'string' ? body.token.trim().toLowerCase() : '';
  if (!/^[0-9a-f]{32,200}$/.test(token)) return { ok: false, error: 'token must be hex' };
  const env = body.env ?? 'production';
  if (env !== 'sandbox' && env !== 'production') return { ok: false, error: 'env must be sandbox|production' };
  const rawRules = body.rules ?? [];
  if (!Array.isArray(rawRules) || rawRules.length > 500) return { ok: false, error: 'rules must be an array (≤500)' };
  const rules = [];
  for (const r of rawRules) {
    if (!r || typeof r !== 'object') return { ok: false, error: 'invalid rule' };
    if (!KINDS.includes(r.kind)) return { ok: false, error: `invalid rule kind: ${r.kind}` };
    if (!LEVELS.includes(r.level)) return { ok: false, error: `invalid rule level: ${r.level}` };
    if (typeof r.value !== 'string' || !r.value.trim() || r.value.length > 100) {
      return { ok: false, error: 'rule value must be a non-empty string (≤100)' };
    }
    rules.push({ kind: r.kind, value: r.value.trim(), level: r.level });
  }
  return { ok: true, value: { token, env, rules } };
}

export function validateToken(body) {
  const token = typeof body?.token === 'string' ? body.token.trim().toLowerCase() : '';
  if (!/^[0-9a-f]{32,200}$/.test(token)) return { ok: false, error: 'token must be hex' };
  return { ok: true, value: token };
}
