#!/usr/bin/env node
// EquationNews -> APNs 推送中继（零依赖，Node >= 22）
import { readFileSync } from 'node:fs';
import { createPrivateKey } from 'node:crypto';
import { NewsSource } from './lib/news.mjs';
import { matchLevel } from './lib/match.mjs';
import { ApnsClient, JwtCache, buildPayload } from './lib/apns.mjs';
import { DeviceStore } from './lib/store.mjs';
import { createServer } from './lib/http.mjs';

const env = process.env;
const ts = () => new Date().toISOString();
const log = (...a) => console.log(ts(), ...a);

const PORT = Number(env.PORT ?? 8787);
const HOST = env.HOST ?? '0.0.0.0';
const DATA_PATH = env.DATA_PATH ?? './data/devices.json';
const TOPIC = env.APNS_TOPIC ?? 'com.xinghelee.eqnews';

function loadJwt() {
  const { APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID } = env;
  if (!APNS_KEY_PATH || !APNS_KEY_ID || !APNS_TEAM_ID) return null;
  const key = createPrivateKey(readFileSync(APNS_KEY_PATH, 'utf8'));
  const jwt = new JwtCache({ key, keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID });
  jwt.get(); // 启动时就验证 key 能签名
  return jwt;
}

const store = await new DeviceStore(DATA_PATH).load();
const apns = new ApnsClient({ jwt: loadJwt(), topic: TOPIC, log });
const news = new NewsSource();

log(`[relay] devices=${store.size} data=${DATA_PATH} topic=${TOPIC} mode=${apns.dryRun ? 'DRY-RUN (APNS_* 未配置)' : 'live'}`);

news.on('status', (s) => {
  if (s.type === 'stale_skip') return log(`[news] stale skip ${s.via} ${s.key}`);
  log(`[news] ${JSON.stringify(s)}`);
});

news.on('news', async (item) => {
  const title = (item.zh ?? item.en ?? '').split('\n')[0].slice(0, 80);
  const lag = item.publishedAt ? `${((item.receivedAt - item.publishedAt) / 1000).toFixed(1)}s` : '?';
  log(`[news] ${item.via} [${item.channels.join(',')}] ${item.source}: ${title} (lag ${lag})`);
  const jobs = [];
  for (const dev of store.all()) {
    const level = matchLevel(dev.rules, item);
    if (!level) continue;
    const payload = buildPayload(item, level);
    jobs.push(apns.send(dev, payload, { key: item.key }).then(async (r) => {
      if (r.unregister) {
        log(`[relay] removing device ${dev.token.slice(0, 8)}… (${r.status} ${r.reason})`);
        await store.remove(dev.token);
      }
    }));
  }
  if (jobs.length) {
    await Promise.allSettled(jobs);
    log(`[relay] ${item.key} -> ${jobs.length} device(s)`);
  }
});

const server = createServer({
  store,
  secret: env.RELAY_SECRET || undefined,
  log,
  health: () => ({
    ws: news.wsState,
    mcp: news.mcpState,
    lastItemAt: news.lastItemAt ? new Date(news.lastItemAt).toISOString() : null,
    dryRun: apns.dryRun,
  }),
});
server.listen(PORT, HOST, () => log(`[http] listening on ${HOST}:${PORT}`));
news.start();

const shutdown = (sig) => {
  log(`[relay] ${sig}, shutting down`);
  news.stop();
  apns.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
