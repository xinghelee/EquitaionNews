# EquationNews 推送中继（relay）

零依赖的 Node.js（>= 22）小服务：实时监听 EquationNews 加密新闻，按每台 iPhone 注册的关注规则，通过 Apple Push Notification service（APNs）发推送。

## 工作原理

- **新闻源**（公开接口，无需鉴权，思路与 `../eqn-client.mjs` 相同）
  - WebSocket `wss://api.eqn.news/public/ws`：main 频道实时推送；每 30s 发一次 `ping` 心跳；断线按 1,2,4…30s 加抖动退避重连，关闭码 1012（服务重启）则 1–5s 后重连；重连后用 MCP 补拉断线期间的 main 新闻。
  - MCP `https://api.eqn.news/public/mcp`：每秒轮询一次 `list_news`（channel=all，limit=50）；遇到 HTTP 429 按 `Retry-After` 等待。首轮轮询只作为基线，不推送旧新闻。
  - 两路按「标题（去空白后前 60 字，zh/en/news_title）、eqn 链接、原文链接」去重，LRU 缓存约 5000 个 key。
  - 发布时间超过 180 秒的新闻视为过期，跳过。
- **规则匹配**：每条新闻对每台设备取命中规则中的最高级别（loud > notify > none）。
  - `coin`：新闻 coins 包含该值（不区分大小写）
  - `keyword`：中文或英文正文包含该值（不区分大小写）
  - `channel`：新闻所属频道包含该值
  - `none` 只在没有更高级别命中时起静音作用；没有任何命中则不推送。
  - `loud` → `interruption-level: time-sensitive`（需要 App 开启 Time Sensitive 能力）；`notify` → `active`。
- **APNs**：HTTP/2（`node:http2`）+ token 认证（ES256 JWT，约 50 分钟刷新），每个 host 复用一个会话。返回 410 或 400 `BadDeviceToken`/`Unregistered` 时自动删除该设备。
- **Dry-run 模式**：未配置 `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` 时，只在日志中打印将要发送的推送，不真正发送。

## 运行

```sh
cd relay
npm test          # 单元测试（node:test）
npm start         # 未配置 APNS_* 时为 dry-run
```

正式发送：

```sh
APNS_KEY_PATH=./AuthKey_XXXXXXXXXX.p8 \
APNS_KEY_ID=XXXXXXXXXX \
APNS_TEAM_ID=YYYYYYYYYY \
RELAY_SECRET=一串随机字符串 \
npm start
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8787` | HTTP 端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `DATA_PATH` | `./data/devices.json` | 设备列表持久化文件（原子写入） |
| `APNS_KEY_PATH` | — | `.p8` 私钥文件路径 |
| `APNS_KEY_ID` | — | Key ID（10 位） |
| `APNS_TEAM_ID` | — | Team ID（10 位） |
| `APNS_TOPIC` | `com.xinghelee.eqnews` | App 的 Bundle ID |
| `RELAY_SECRET` | — | 设置后，注册/注销必须带请求头 `x-relay-secret`，否则返回 401 |

三个 `APNS_*` 变量缺任何一个都会进入 dry-run 模式。

## 创建 APNs 密钥（.p8）

需要在 Apple Developer 后台自己操作（本项目不会替你创建任何账号或密钥）：

1. 登录 <https://developer.apple.com/account>，进入 **Certificates, Identifiers & Profiles → Keys**。
2. 点 **+** 新建 Key，填写名称，勾选 **Apple Push Notifications service (APNs)**，继续并注册。
3. 下载 `AuthKey_<KeyID>.p8`（**只能下载一次**，妥善保存，不要提交到 git——`.gitignore` 已忽略 `*.p8`）。
4. 记下页面上的 **Key ID**；**Team ID** 在账号页右上角或 Membership 页面。
5. 确认 App ID（`com.xinghelee.eqnews`）已启用 **Push Notifications** 能力；如需 loud 级别穿透专注模式，App 还需启用 **Time Sensitive Notifications**。

同一个 .p8 可同时用于 sandbox 和 production；设备注册时用 `env` 指明：Xcode 直接安装的调试包用 `sandbox`，TestFlight / App Store 包用 `production`。

## 注册 API

```sh
# 注册 / 更新（按 token upsert）
curl -X POST http://localhost:8787/register \
  -H 'content-type: application/json' \
  -H 'x-relay-secret: <RELAY_SECRET，未设置可省略>' \
  -d '{
    "token": "<十六进制 APNs device token>",
    "env": "sandbox",
    "rules": [
      {"kind": "coin",    "value": "BTC",         "level": "loud"},
      {"kind": "keyword", "value": "上线",         "level": "notify"},
      {"kind": "channel", "value": "pricechange", "level": "notify"},
      {"kind": "channel", "value": "earn",        "level": "none"}
    ]
  }'
# => {"ok":true}

# 注销
curl -X DELETE http://localhost:8787/register \
  -H 'x-relay-secret: ...' -d '{"token":"<token>"}'
# => {"ok":true,"removed":true}

# 健康检查
curl http://localhost:8787/health
# => {"ok":true,"devices":1,"ws":"open","mcp":"ok","lastItemAt":"2026-…","dryRun":false}
```

- 请求体上限 64KB；`kind` ∈ `coin|keyword|channel`，`level` ∈ `loud|notify|none`，`env` ∈ `sandbox|production`。
- 频道名：`main` 方程式新闻、`tradfi` 方程式财经、`binance` 币安公告、`tier2` 二线上新、`tier3` 三线上新、`korea` 韩所监控、`alpha` 币安Alpha、`hl` Hyperliquid、`pricechange` 价格异动、`major` 大幅波动、`tfmoves` 美股重大行情、`oi` OI价格异动、`cz` CZ&何一、`earn` 理财提醒。

推送 payload 示例：

```json
{
  "aps": {
    "alert": { "title": "方程式新闻 · AggrNews", "body": "德国法官提议……" },
    "sound": "default",
    "thread-id": "main",
    "interruption-level": "time-sensitive",
    "relevance-score": 1
  },
  "url": "https://eqn.news/main/15774",
  "no": 15774
}
```

## 部署

服务是单进程、内存去重、JSON 文件存储，**只跑一个实例**即可（多实例会重复推送）。注册接口建议放在 HTTPS 反代后面，并设置 `RELAY_SECRET`。

### 任意 VPS + Docker

```sh
cd relay
docker build -t eqn-relay .
docker run -d --name eqn-relay --restart unless-stopped \
  -p 8787:8787 \
  -v eqn-relay-data:/data \
  -v /path/to/AuthKey_XXXXXXXXXX.p8:/keys/apns.p8:ro \
  -e APNS_KEY_PATH=/keys/apns.p8 \
  -e APNS_KEY_ID=XXXXXXXXXX \
  -e APNS_TEAM_ID=YYYYYYYYYY \
  -e RELAY_SECRET=... \
  eqn-relay
```

前面再用 Caddy / Nginx 提供 HTTPS（例如 Caddy：`relay.example.com { reverse_proxy localhost:8787 }`）。

### Fly.io（带持久卷）

```sh
cd relay
fly launch --no-deploy            # 生成 fly.toml，内部端口填 8787
fly volumes create relay_data --size 1
fly secrets set APNS_KEY_ID=XXXXXXXXXX APNS_TEAM_ID=YYYYYYYYYY RELAY_SECRET=...
fly secrets set APNS_KEY_P8="$(cat AuthKey_XXXXXXXXXX.p8)"
```

在 `fly.toml` 中挂载卷，并让机器常驻（不要自动停机，否则收不到新闻）：

```toml
[mounts]
  source = "relay_data"
  destination = "/data"

[http_service]
  internal_port = 8787
  auto_stop_machines = "off"
  min_machines_running = 1
```

由于程序读取的是密钥文件路径，可把 Dockerfile 的 `CMD` 改为先把 secret 写到文件再启动，例如：

```dockerfile
CMD ["sh", "-c", "printf '%s' \"$APNS_KEY_P8\" > /tmp/apns.p8 && APNS_KEY_PATH=/tmp/apns.p8 exec node relay.mjs"]
```

然后 `fly deploy`，数量保持 1 台（`fly scale count 1`）。

## 文件

- `relay.mjs` — 入口：组装新闻源、规则匹配、APNs、HTTP 服务
- `lib/news.mjs` — WS + MCP 新闻源、去重、过期判断
- `lib/match.mjs` — 规则匹配
- `lib/apns.mjs` — JWT、payload、HTTP/2 客户端
- `lib/store.mjs` — 设备存储与参数校验
- `lib/http.mjs` — 注册 API
- `test/relay.test.mjs` — 单元测试
