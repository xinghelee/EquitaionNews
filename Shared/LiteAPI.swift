import Foundation

/// 小组件和手表共用的轻量数据层（不依赖主 App 的类型）
struct LiteNews: Identifiable, Hashable, Sendable, Codable {
    let no: Int
    let time: Date
    let channel: String
    let source: String
    let title: String
    let url: URL?
    let coins: [String]
    var id: Int { no }

    var lines: [String] {
        title.split(whereSeparator: \.isNewline)
            .map { var t = $0.trimmingCharacters(in: .whitespaces); while t.hasPrefix("*") { t.removeFirst() }; return t }
            .filter { !$0.isEmpty }
    }
    var headline: String { lines.first ?? title }
}

struct LiteQuote: Identifiable, Hashable, Sendable, Codable {
    let symbol: String
    let price: Double
    let change24h: Double
    var id: String { symbol }
}

enum LiteAPI {
    static let channelNames: [String: String] = [
        "all": "全部快讯", "main": "方程式新闻", "tradfi": "方程式财经", "binance": "币安公告", "tier2": "二线上新",
        "tier3": "三线上新", "korea": "韩所监控", "alpha": "币安Alpha", "hl": "Hyperliquid",
        "pricechange": "价格异动", "major": "大幅波动", "tfmoves": "美股重大行情", "oi": "OI价格异动",
        "cz": "CZ&何一", "earn": "理财提醒",
    ]

    private struct Item: Decodable {
        let no: Int; let time: String; let channels: [String]; let source: String
        let zh: String?; let en: String?; let coins: [String]?; let url: String
    }
    private struct Resp: Decodable {
        struct R: Decodable { struct C: Decodable { let items: [Item] }; let structuredContent: C? }
        let result: R?
    }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func news(channel: String = "all", limit: Int = 10) async throws -> [LiteNews] {
        var req = URLRequest(url: URL(string: "https://api.eqn.news/public/mcp")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "list_news", "arguments": ["channel": channel, "limit": limit]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let items = try JSONDecoder().decode(Resp.self, from: data).result?.structuredContent?.items ?? []
        return items.map {
            LiteNews(no: $0.no, time: (try? iso.parse($0.time)) ?? Date(), channel: $0.channels.first ?? "",
                     source: $0.source, title: $0.zh ?? $0.en ?? "", url: URL(string: $0.url), coins: $0.coins ?? [])
        }
    }

    /// eqn.news 网页行情接口（未公开）；只解析需要的币种
    static func quotes(_ symbols: [String]) async throws -> [LiteQuote] {
        let want = Set(symbols.map { $0.uppercased() })
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://eqn.news/api/v1/market")!)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = j["k"] as? [String], let rows = j["rows"] as? [[Any]] else { return [] }
        let ix = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        func num(_ r: [Any], _ k: String) -> Double { ix[k].flatMap { $0 < r.count ? (r[$0] as? NSNumber)?.doubleValue : nil } ?? 0 }
        var found: [String: LiteQuote] = [:]
        for r in rows {
            guard let si = ix["s"], si < r.count, let s = r[si] as? String, want.contains(s), found[s] == nil else { continue }
            found[s] = LiteQuote(symbol: s, price: num(r, "p"), change24h: num(r, "c24"))
        }
        for (s, arr) in j["x"] as? [String: [Any]] ?? [:] where want.contains(s) && found[s] == nil {
            found[s] = LiteQuote(symbol: s, price: (arr.first as? NSNumber)?.doubleValue ?? 0,
                                 change24h: (arr.count > 1 ? arr[1] as? NSNumber : nil)?.doubleValue ?? 0)
        }
        return symbols.compactMap { found[$0.uppercased()] }
    }

    static func price(_ p: Double) -> String {
        if p >= 1000 { return p.formatted(.number.precision(.fractionLength(0))) }
        if p >= 1 { return p.formatted(.number.precision(.fractionLength(2)).grouping(.never)) }
        return p.formatted(.number.precision(.significantDigits(4)).grouping(.never))
    }

    static func change(_ c: Double) -> String { (c >= 0 ? "+" : "") + String(format: "%.2f%%", c) }

    /// 小组件 / 手表点开后跳回 App 打开对应快讯
    static func deepLink(_ n: LiteNews) -> URL? {
        guard let u = n.url?.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "eqnews://open?url=\(u)")
    }
}
