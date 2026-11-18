import Foundation
import Observation

/// EquationNews 低延迟接入：
/// - WebSocket 实时推送 main 频道
/// - MCP list_news 每秒轮询全部频道
/// - 两路按 标题 / 链接 去重
/// - WS 断线重连后用 MCP 补拉 main（WS 不重发）
/// - 网页内部接口（未公开）补充来源头像、币种、配图与今日条数；失败时退回公开数据
@MainActor @Observable
final class EqnClient {
    private(set) var items: [NewsItem] = []
    private(set) var wsState: ConnState = .connecting
    private(set) var mcpState: ConnState = .connecting
    private(set) var latWS: [Double] = []
    private(set) var latMCP: [Double] = []
    private(set) var liveCount = 0
    private(set) var todayCounts: [String: Int] = [:]
    private(set) var todayTotal: Int?
    private(set) var richAvailable = false
    let startedAt = Date()

    /// 每条实时新消息（ws / mcp / gapfill）回调一次
    @ObservationIgnored var onNew: ((NewsItem) -> Void)?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var wsTask: URLSessionWebSocketTask?
    @ObservationIgnored private var wsLoop: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private var wsDownSince: Date?
    @ObservationIgnored private var backoff: Double = 1
    @ObservationIgnored private var warm = false
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var seenOrder: [String] = []
    @ObservationIgnored private var keyToID: [String: String] = [:]
    @ObservationIgnored private var rpcId = 0

    private let wsURL = URL(string: "wss://api.eqn.news/public/ws")!
    private let mcpURL = URL(string: "https://api.eqn.news/public/mcp")!
    private let siteAPI = URL(string: "https://eqn.news/api/v1/")!
    private let pollInterval: Double = 1
    private let maxItems = 500

    // MARK: - 生命周期

    func start() {
        guard !running else { return }
        running = true
        connectWS()
        pollTask = Task { [weak self] in
            await self?.initialLoad()
            await self?.pollLoop()
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadStats()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        running = false
        [pollTask, statsTask, enrichTask, heartbeat, wsLoop].forEach { $0?.cancel() }
        wsTask?.cancel(with: .normalClosure, reason: nil); wsTask = nil
    }

    /// App 回到前台：立即拉一次；WS 若已断开立即重连（不等退避）
    func resume() {
        guard running else { return start() }
        Task { await pollOnce(); await loadStats() }
        if wsTask?.state != .running {
            wsDownSince = wsDownSince ?? Date()
            backoff = 1
            connectWS()
        }
    }

    func refresh() async {
        await pollOnce()
        await enrich(limit: 50)
        await loadStats()
    }

    // MARK: - WebSocket

    private func connectWS() {
        wsLoop?.cancel()
        heartbeat?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: wsURL)
        wsTask = task
        wsState = .connecting
        task.resume()
        wsLoop = Task { [weak self] in await self?.receiveLoop(task) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            try await task.send(.string("ping")) // send 成功即表示握手完成
            onWSOpen()
            heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    try? await task.send(.string("ping"))
                }
            }
            while !Task.isCancelled {
                switch try await task.receive() {
                case .string(let s): handleWS(s)
                case .data(let d): handleWS(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
            }
        } catch {
            heartbeat?.cancel()
            guard running, wsTask === task, !Task.isCancelled else { return }
            wsDownSince = wsDownSince ?? Date()
            let delay = backoff * Double.random(in: 1...1.3)
            backoff = min(backoff * 2, 30)
            wsState = .retrying(Int(delay.rounded(.up)))
            try? await Task.sleep(for: .seconds(delay))
            if running, wsTask === task { connectWS() }
        }
    }

    private func onWSOpen() {
        backoff = 1
        wsState = .ok
        if let since = wsDownSince {
            wsDownSince = nil
            Task { await gapFill(since: since) }
        }
    }

    private struct WSMessage: Decodable {
        let source_name: String?
        let news_title: String?
        let coins_included: [String]?
        let url: String?
        let timestamp: Double?
    }

    private func handleWS(_ s: String) {
        guard s != "pong", let data = s.data(using: .utf8),
              let m = try? JSONDecoder().decode(WSMessage.self, from: data),
              let title = m.news_title, !title.isEmpty else { return }
        var keys = [Self.titleKey(title)].compactMap { $0 }
        if let u = m.url { keys += ["u:\(u)", "e:\(u)"] }
        let link = m.url.flatMap(URL.init(string:))
        let isEQN = link?.host?.hasSuffix("eqn.news") == true
        let item = NewsItem(
            id: m.url ?? title, via: .ws, no: nil, kind: nil, title: title, titleEn: nil,
            source: m.source_name ?? "", sourceSlug: nil, coins: m.coins_included ?? [],
            url: isEQN ? link : nil, sourceURL: isEQN ? nil : link, images: [], channels: ["main"],
            publishedAt: m.timestamp.map { Date(timeIntervalSince1970: $0) }, receivedAt: Date())
        emit(item, keys: keys)
    }

    // MARK: - MCP（公开）

    private struct MCPItem: Decodable {
        let no: Int
        let time: String
        let channels: [String]
        let source: String
        let zh: String?
        let en: String?
        let coins: [String]?
        let url: String
        let source_url: String?
    }

    private struct RPCResponse: Decodable {
        struct Result: Decodable {
            struct Content: Decodable { let items: [MCPItem] }
            let structuredContent: Content?
            let isError: Bool?
        }
        struct RPCError: Decodable { let message: String }
        let result: Result?
        let error: RPCError?
    }

    struct RateLimited: Error { let retryAfter: Double }
    struct Failure: Error { let message: String }

    private func listNews(channel: String, limit: Int) async throws -> [MCPItem] {
        rpcId += 1
        var req = URLRequest(url: mcpURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": rpcId, "method": "tools/call",
            "params": ["name": "list_news", "arguments": ["channel": channel, "limit": limit]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 429 {
            throw RateLimited(retryAfter: Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10)
        }
        guard http?.statusCode == 200 else { throw Failure(message: "HTTP \(http?.statusCode ?? 0)") }
        let r = try JSONDecoder().decode(RPCResponse.self, from: data)
        if let e = r.error { throw Failure(message: e.message) }
        if r.result?.isError == true { throw Failure(message: "tool error") }
        return r.result?.structuredContent?.items ?? []
    }

    private func pollLoop() async {
        while running, !Task.isCancelled {
            let next = await pollOnce()
            try? await Task.sleep(for: .seconds(next))
        }
    }

    @discardableResult
    private func pollOnce() async -> Double {
        do {
            let list = try await listNews(channel: "all", limit: 50)
            let via: Via = warm ? .mcp : .backlog
            warm = true
            for it in list.reversed() { handleMCP(it, via: via) }
            mcpState = .ok
            return pollInterval
        } catch let e as RateLimited {
            mcpState = .error("限流")
            return e.retryAfter
        } catch {
            mcpState = .error("请求失败")
            return 3
        }
    }

    private func gapFill(since: Date) async {
        guard let list = try? await listNews(channel: "main", limit: 50) else { return }
        let cutoff = since.addingTimeInterval(-60)
        for it in list.reversed() where (Self.parseDate(it.time) ?? .distantPast) >= cutoff {
            handleMCP(it, via: .gapfill)
        }
    }

    private func handleMCP(_ it: MCPItem, via: Via) {
        var keys = ["e:\(it.url)", "n:\(it.no)"]
        keys += [Self.titleKey(it.zh), Self.titleKey(it.en)].compactMap { $0 }
        if let s = it.source_url { keys.append("u:\(s)") }
        let item = NewsItem(
            id: it.url, via: via, no: it.no, kind: nil, title: it.zh ?? it.en ?? "", titleEn: it.en,
            source: it.source, sourceSlug: nil, coins: it.coins ?? [], url: URL(string: it.url),
            sourceURL: it.source_url.flatMap(URL.init(string:)), images: [], channels: it.channels,
            publishedAt: Self.parseDate(it.time), receivedAt: Date())
        let isNew = emit(item, keys: keys)
        if isNew, via.isLive { scheduleEnrich() }
    }

    // MARK: - 网页内部接口（未公开，失败时静默退回）

    private struct RichItem: Decodable {
        struct Source: Decodable { let slug: String?; let display: String?; let display_zh: String? }
        struct I18n: Decodable { let zh: String?; let en: String? }
        struct Coin: Decodable { let symbol: String; let mc_at_publish: Double? }
        let no: Int
        let path: String
        let published_ts: Double
        let channels: [String]
        let kind: String?
        let source: Source
        let i18n: I18n
        let coins: [Coin]?
        let url: String?
        let images: [ImageRef]?
    }

    /// images 字段格式未公开：兼容字符串或 {url|src|path}
    private struct ImageRef: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s; return }
            let d = try? c.decode([String: String].self)
            value = d?["url"] ?? d?["src"] ?? d?["path"]
        }
    }

    private struct RichList: Decodable { let items: [RichItem] }

    private func fetchRich(limit: Int) async throws -> [RichItem] {
        var comps = URLComponents(url: siteAPI.appending(path: "news"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: comps.url!, timeoutInterval: 10))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "site api") }
        return try JSONDecoder().decode(RichList.self, from: data).items
    }

    private func absoluteURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: s.hasPrefix("/") ? "https://eqn.news\(s)" : "https://eqn.news/\(s)")
    }

    private func richKeys(_ r: RichItem) -> [String] {
        var keys = ["n:\(r.no)", "e:https://eqn.news\(r.path)"]
        keys += [Self.titleKey(r.i18n.zh), Self.titleKey(r.i18n.en)].compactMap { $0 }
        if let u = r.url { keys.append("u:\(u)") }
        return keys
    }

    private func richToItem(_ r: RichItem, via: Via) -> NewsItem {
        NewsItem(
            id: "https://eqn.news\(r.path)", via: via, no: r.no, kind: r.kind,
            title: r.i18n.zh ?? r.i18n.en ?? "", titleEn: r.i18n.en,
            source: r.source.display_zh ?? r.source.display ?? r.source.slug ?? "", sourceSlug: r.source.slug,
            coins: r.coins?.map(\.symbol) ?? [], url: URL(string: "https://eqn.news\(r.path)"),
            sourceURL: absoluteURL(r.url), images: (r.images ?? []).compactMap { absoluteURL($0.value) },
            channels: r.channels, publishedAt: Date(timeIntervalSince1970: r.published_ts / 1000), receivedAt: Date(),
            mcAtPublish: Self.mcMap(r))
    }

    private static func mcMap(_ r: RichItem) -> [String: Double] {
        var m: [String: Double] = [:]
        for c in r.coins ?? [] { if let v = c.mc_at_publish, v > 0 { m[c.symbol.uppercased()] = v } }
        return m
    }

    /// 首屏：优先用网页接口（带头像 / 币种 / 配图），失败则由 MCP 首轮当历史
    private func initialLoad() async {
        guard let list = try? await fetchRich(limit: 100) else { return }
        richAvailable = true
        for r in list.reversed() { emit(richToItem(r, via: .backlog), keys: richKeys(r)) }
        warm = true
    }

    private func scheduleEnrich() {
        guard enrichTask == nil else { return }
        enrichTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await self?.enrich(limit: 30)
            self?.enrichTask = nil
        }
    }

    /// 把网页接口的富字段合并进已有条目（实时条目来自 WS / MCP）
    private func enrich(limit: Int) async {
        guard let list = try? await fetchRich(limit: limit) else { return }
        richAvailable = true
        for r in list {
            let keys = richKeys(r)
            guard let id = keys.lazy.compactMap({ self.keyToID[$0] }).first,
                  let i = items.firstIndex(where: { $0.id == id }) else { continue }
            var it = items[i]
            it.no = it.no ?? r.no
            it.kind = r.kind
            it.sourceSlug = r.source.slug
            if let zh = r.source.display_zh ?? r.source.display { it.source = zh }
            if let c = r.coins, !c.isEmpty { it.coins = c.map(\.symbol) }
            let mc = Self.mcMap(r)
            if !mc.isEmpty { it.mcAtPublish = mc }
            let imgs = (r.images ?? []).compactMap { absoluteURL($0.value) }
            if !imgs.isEmpty { it.images = imgs }
            if it.url == nil { it.url = URL(string: "https://eqn.news\(r.path)") }
            if it.sourceURL == nil { it.sourceURL = absoluteURL(r.url) }
            if it.titleEn == nil { it.titleEn = r.i18n.en }
            if items[i] != it { items[i] = it }
            for k in keys { keyToID[k] = id }
        }
    }

    private struct Stats: Decodable {
        struct Ch: Decodable { let today: Int }
        let total_today: Int?
        let channels: [String: Ch]
    }

    private func loadStats() async {
        var comps = URLComponents(url: siteAPI.appending(path: "news/stats"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "tz", value: TimeZone.current.identifier)]
        guard let (data, resp) = try? await URLSession.shared.data(from: comps.url!),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(Stats.self, from: data) else { return }
        todayCounts = s.channels.mapValues(\.today)
        todayTotal = s.total_today
    }

    // MARK: - 去重 & 分发

    @discardableResult
    private func emit(_ item: NewsItem, keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        let known = keys.contains { seen.contains($0) }
        for k in keys where seen.insert(k).inserted { seenOrder.append(k) }
        if seenOrder.count > 5000 {
            let drop = seenOrder.prefix(seenOrder.count - 5000)
            drop.forEach { seen.remove($0); keyToID.removeValue(forKey: $0) }
            seenOrder.removeFirst(drop.count)
        }
        if known {
            // 已有条目：登记新的 key，方便后续富化
            if let id = keys.lazy.compactMap({ self.keyToID[$0] }).first { for k in keys { keyToID[k] = id } }
            return false
        }
        for k in keys { keyToID[k] = item.id }

        let idx = items.firstIndex { $0.sortDate < item.sortDate } ?? items.endIndex
        items.insert(item, at: idx)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }

        guard item.via.isLive else { return true }
        liveCount += 1
        if let lat = item.latency, lat >= 0, lat < 600 {
            if item.via == .ws { latWS.append(lat) } else if item.via == .mcp { latMCP.append(lat) }
        }
        onNew?(item)
        if item.via == .ws { scheduleEnrich() }
        return true
    }

    // MARK: - 工具

    private static func titleKey(_ s: String?) -> String? {
        guard let s else { return nil }
        let n = String(s.filter { !$0.isWhitespace }.prefix(60))
        return n.isEmpty ? nil : "t:\(n)"
    }

    private nonisolated static let isoFrac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private nonisolated static let iso = Date.ISO8601FormatStyle()

    nonisolated static func parseDate(_ s: String) -> Date? {
        (try? isoFrac.parse(s)) ?? (try? iso.parse(s))
    }
}
