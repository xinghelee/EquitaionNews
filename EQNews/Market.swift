import Foundation
import Observation

/// 行情数据：eqn.news 内部接口 /api/v1/market（未公开，失败时整块隐藏）
@MainActor @Observable
final class MarketStore {
    struct Coin: Identifiable, Hashable, Sendable {
        let id: String
        let symbol: String
        let name: String
        let rank: Int
        let price: Double
        let marketCap: Double
        let volume: Double
        let change1h: Double
        let change24h: Double
        let change7d: Double
        /// 0 普通币；1/2 稳定币；3 黄金 / 包装 / 质押类
        let group: Int
        let icon: URL?

        func change(_ p: Period) -> Double {
            switch p { case .h1: change1h; case .h24: change24h; case .d7: change7d }
        }
    }

    enum Period: String, CaseIterable, Identifiable { case h1 = "1h", h24 = "24h", d7 = "7d"; var id: String { rawValue } }

    struct Quote: Sendable { let price: Double; let change24h: Double; let icon: URL?; var marketCap: Double = 0 }

    struct Global: Sendable {
        let marketCap: Double
        let marketCapChange: Double
        let volume: Double
        let btcDominance: Double
        let ethDominance: Double
        /// 近 7 天总市值（单位：十亿美元）
        let history: [Double]
        var change7d: Double? {
            guard let a = history.first, let b = history.last, a > 0 else { return nil }
            return (b / a - 1) * 100
        }
    }

    private(set) var coins: [Coin] = []
    private(set) var quotes: [String: Quote] = [:]
    private(set) var global: Global?
    private(set) var fearGreed: (value: Int, label: String)?
    private(set) var fearGreedHistory: [Int] = []
    private(set) var updatedAt: Date?
    private(set) var failed = false

    @ObservationIgnored private var task: Task<Void, Never>?
    private let url = URL(string: "https://eqn.news/api/v1/market")!

    func visible(excludeStable: Bool) -> [Coin] { excludeStable ? coins.filter { $0.group == 0 } : coins }

    /// 与网页涨跌榜口径一致：市值前 500、成交额 ≥ $1M
    func movers(_ p: Period, up: Bool, excludeStable: Bool) -> [Coin] {
        let liquid = visible(excludeStable: excludeStable).filter { $0.rank <= 500 && $0.volume >= 1_000_000 }
        return Array(liquid.sorted { up ? $0.change(p) > $1.change(p) : $0.change(p) < $1.change(p) }.prefix(30))
    }

    func breadth(_ p: Period, excludeStable: Bool) -> (up: Int, down: Int) {
        let list = visible(excludeStable: excludeStable)
        return (list.filter { $0.change(p) > 0 }.count, list.filter { $0.change(p) < 0 }.count)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func quote(_ symbol: String) -> Quote? { quotes[symbol.uppercased()] }

    // MARK: 消息后涨跌

    /// 实时收到快讯时记下当时价格
    @ObservationIgnored private var anchors: [String: Double] = [:]
    @ObservationIgnored private var anchorOrder: [String] = []

    func anchor(_ item: NewsItem) {
        for s in item.coins {
            guard let p = quote(s)?.price, p > 0 else { continue }
            let k = "\(item.id)|\(s.uppercased())"
            guard anchors[k] == nil else { continue }
            anchors[k] = p
            anchorOrder.append(k)
        }
        if anchorOrder.count > 2000 {
            anchorOrder.prefix(500).forEach { anchors.removeValue(forKey: $0) }
            anchorOrder.removeFirst(500)
        }
    }

    /// 自快讯发布以来的涨跌幅（%）；优先用实时锚定价，其次用发布时市值
    func sincePublish(_ item: NewsItem, _ symbol: String) -> Double? {
        guard let q = quote(symbol) else { return nil }
        if let a = anchors["\(item.id)|\(symbol.uppercased())"], a > 0 { return (q.price / a - 1) * 100 }
        if let mc0 = item.mcAtPublish[symbol.uppercased()], mc0 > 0, q.marketCap > 0 { return (q.marketCap / mc0 - 1) * 100 }
        return nil
    }

    func refresh() async {
        do {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
            parse(j)
            failed = false
            updatedAt = Date()
        } catch {
            if coins.isEmpty { failed = true }
        }
    }

    private func parse(_ j: [String: Any]) {
        if let keys = j["k"] as? [String], let rows = j["rows"] as? [[Any]] {
            let ix = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
            func v<T>(_ r: [Any], _ k: String) -> T? { ix[k].flatMap { $0 < r.count ? r[$0] as? T : nil } }
            func d(_ r: [Any], _ k: String) -> Double { (v(r, k) as NSNumber?)?.doubleValue ?? 0 }
            var list: [Coin] = []
            var q: [String: Quote] = [:]
            for r in rows {
                guard let id: String = v(r, "id"), let s: String = v(r, "s") else { continue }
                let icon = Brand.coinIcon(v(r, "ic"))
                let c = Coin(id: id, symbol: s, name: v(r, "n") ?? s, rank: Int(d(r, "r")), price: d(r, "p"),
                             marketCap: d(r, "mc"), volume: d(r, "v"), change1h: d(r, "c1"), change24h: d(r, "c24"),
                             change7d: d(r, "c7"), group: Int(d(r, "grp")), icon: icon)
                list.append(c)
                if q[s] == nil { q[s] = Quote(price: c.price, change24h: c.change24h, icon: icon, marketCap: c.marketCap) }
            }
            // 额外报价：x = { 符号: [价格, 24h涨跌] }，xi = { 符号: 图标 }
            let xi = j["xi"] as? [String: String] ?? [:]
            for (s, arr) in j["x"] as? [String: [Any]] ?? [:] where q[s] == nil {
                let p = (arr.first as? NSNumber)?.doubleValue ?? 0
                let c = (arr.count > 1 ? arr[1] as? NSNumber : nil)?.doubleValue ?? 0
                q[s] = Quote(price: p, change24h: c, icon: Brand.coinIcon(xi[s]))
            }
            coins = list.sorted { $0.rank < $1.rank }
            quotes = q
        }
        if let g = j["g"] as? [String: Any] {
            func n(_ k: String) -> Double { (g[k] as? NSNumber)?.doubleValue ?? 0 }
            let hist = (g["mc7"] as? [NSNumber])?.map(\.doubleValue) ?? []
            global = Global(marketCap: n("mc"), marketCapChange: n("mcChg"), volume: n("vol"),
                            btcDominance: n("btcD"), ethDominance: n("ethD"), history: hist)
        }
        if let all = j["fng"] as? [[Any]] {
            fearGreedHistory = all.compactMap { ($0.first as? NSNumber)?.intValue }
        }
        if let f = (j["fng"] as? [[Any]])?.last, let val = (f.first as? NSNumber)?.intValue {
            let zh = ["Extreme Fear": "极度恐惧", "Fear": "恐惧", "Neutral": "中性", "Greed": "贪婪", "Extreme Greed": "极度贪婪"]
            let label = f.count > 1 ? f[1] as? String ?? "" : ""
            fearGreed = (val, zh[label] ?? label)
        }
    }
}
