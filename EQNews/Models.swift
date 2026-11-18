import Foundation
import SwiftUI
import UIKit

enum Via: String, Sendable {
    case ws, mcp, gapfill, backlog

    var label: String {
        switch self {
        case .ws: "WS"
        case .mcp: "MCP"
        case .gapfill: "补拉"
        case .backlog: "历史"
        }
    }

    var isLive: Bool { self != .backlog }
}

struct NewsItem: Identifiable, Hashable, Sendable {
    let id: String
    let via: Via
    var no: Int?
    var kind: String?
    var title: String
    var titleEn: String?
    var source: String
    var sourceSlug: String?
    var coins: [String]
    var url: URL?          // eqn.news 详情页
    var sourceURL: URL?    // 原文
    var images: [URL]
    var channels: [String]
    var publishedAt: Date?
    let receivedAt: Date
    /// 网页接口给的发布时市值（按币种），用于算「消息后涨跌」
    var mcAtPublish: [String: Double] = [:]

    var latency: TimeInterval? { publishedAt.map { receivedAt.timeIntervalSince($0) } }
    var sortDate: Date { publishedAt ?? receivedAt }

    var headline: String {
        String(title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(title))
    }

    /// 标题之后的正文（去掉空行）
    var detail: String? {
        let parts = title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        let s = parts[1].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return s.isEmpty ? nil : s
    }

    var headlineEn: String? {
        guard let en = titleEn?.split(separator: "\n").first.map(String.init), en != headline else { return nil }
        return en
    }

    var sourceIcon: URL? { Brand.sourceIcon(slug: sourceSlug, name: source) }
}

// MARK: - 频道（与 eqn.news 侧栏一致）

enum Channels {
    struct Group: Identifiable {
        let title: String
        let color: Color
        let keys: [String]
        let tagFG: Color
        let tagBG: Color
        var id: String { title }
    }

    static let names: [String: String] = [
        "main": "方程式新闻", "tradfi": "方程式财经", "binance": "币安公告", "tier2": "二线上新",
        "tier3": "三线上新", "korea": "韩所监控", "alpha": "币安Alpha", "hl": "Hyperliquid",
        "pricechange": "价格异动", "major": "大幅波动", "tfmoves": "美股重大行情", "oi": "OI价格异动",
        "cz": "CZ&何一", "earn": "理财提醒",
    ]

    static let groups: [Group] = [
        Group(title: "主频道", color: Color(hex: 0x406282), keys: ["main", "tradfi"],
              tagFG: Color(hex: 0x406282), tagBG: Color(hex: 0x406282, alpha: 0.10)),
        Group(title: "监控 · 上新与公告", color: Color(hex: 0x7C3AED), keys: ["binance", "tier2", "tier3", "korea", "alpha", "hl"],
              tagFG: Color(hex: 0x6D28D9), tagBG: Color(hex: 0x7C3AED, alpha: 0.10)),
        Group(title: "监控 · 行情异动", color: Color(hex: 0x0E7490), keys: ["pricechange", "major", "tfmoves", "oi"],
              tagFG: Color(hex: 0x0E7490), tagBG: Color(hex: 0x0E7490, alpha: 0.10)),
        Group(title: "监控 · 推文与理财", color: Color(hex: 0xEA580C), keys: ["cz", "earn"],
              tagFG: Color(hex: 0xC2410C), tagBG: Color(hex: 0xEA580C, alpha: 0.10)),
    ]

    static func group(of key: String) -> Group { groups.first { $0.keys.contains(key) } ?? groups[0] }

    static let all: [(key: String, name: String)] = groups.flatMap(\.keys).map { ($0, names[$0] ?? $0) }

    static func name(_ key: String) -> String { key == "all" ? "全部快讯" : names[key] ?? key }
    /// 与网页侧栏一致：主频道用频道图，交易所类用交易所图标，行情类用符号
    enum Icon { case image(URL), symbol(String, Color) }

    static func icon(_ key: String) -> Icon {
        let img: [String: String] = [
            "main": "ch/main", "tradfi": "ch/tradfi", "binance": "src/binance", "tier2": "src/bybit",
            "tier3": "src/mexc", "korea": "src/upbit", "hl": "src/hyperliquid", "cz": "src/cz",
        ]
        if let p = img[key], let u = URL(string: "https://eqn.news/_shared/img/\(p).webp") { return .image(u) }
        switch key {
        case "alpha": return .symbol("alpha", Color(hex: 0xF0B90B))
        case "pricechange": return .symbol("waveform.path.ecg", Color(hex: 0x0E7490))
        case "major": return .symbol("arrow.up.arrow.down", Color(hex: 0x0E7490))
        case "tfmoves": return .symbol("building.columns", Color(hex: 0x0E7490))
        case "oi": return .symbol("chart.bar.fill", Color(hex: 0x0E7490))
        case "earn": return .symbol("percent", Color(hex: 0xEA580C))
        default: return .symbol("newspaper", Color(hex: 0x406282))
        }
    }
}

enum Brand {
    private static let sources: [(match: String, file: String)] = [
        ("heyi", "yihe"), ("cz_", "cz"), ("cz ", "cz"), ("binance", "binance"), ("okx", "okx"), ("bybit", "bybit"),
        ("gate", "gate"), ("mexc", "mexc"), ("upbit", "upbit"), ("bithumb", "bithumb"), ("bitget", "bitget"),
        ("hyperliquid", "hyperliquid"), ("coinbase", "coinbase"), ("htx", "htx"),
    ]

    static func sourceIcon(slug: String?, name: String) -> URL? {
        let s = (slug ?? name).lowercased()
        if s.contains("tradfi") { return URL(string: "https://eqn.news/_shared/img/ch/tradfi.webp") }
        guard let hit = sources.first(where: { s.contains($0.match) }) else { return nil }
        return URL(string: "https://eqn.news/_shared/img/src/\(hit.file).webp")
    }

    static func coinIcon(_ file: String?) -> URL? {
        file.flatMap { URL(string: "https://eqn.news/api/v1/icons/\($0)") }
    }
}

enum ConnState: Equatable {
    case connecting, ok, retrying(Int), error(String)

    var text: String {
        switch self {
        case .connecting: "连接中"
        case .ok: "正常"
        case .retrying(let s): "重连中 \(s)s"
        case .error(let m): m
        }
    }

    var color: Color {
        switch self {
        case .ok: .eqUp
        case .connecting, .retrying: .orange
        case .error: .eqDown
        }
    }
}

// MARK: - 主题（取自 eqn.news）

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { t in
            let h = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }

    static let eqBg = dyn(0xF4F6FA, 0x0B0D11)
    static let eqCard = dyn(0xFFFFFF, 0x15181D)
    static let eqLine = dyn(0xE4E8EF, 0x262A31)
    static let eqText = dyn(0x111723, 0xE8EAEE)
    static let eqMuted = dyn(0x6B7385, 0x8B929E)
    static let eqAccent = dyn(0x3B6FB6, 0x6EA2EA)
    static let eqChip = dyn(0xF1F3F7, 0x1F232A)
    static let eqUp = dyn(0x15A34A, 0x34D399)
    static let eqDown = dyn(0xE5484D, 0xF87171)
    static let eqBody = dyn(0x353C4B, 0xC4C8D0)
    static let eqAccentDeep = dyn(0x406282, 0x8FB2D6)
    static let eqMainBar = dyn(0x406282, 0x6D8FB3)
    static let eqChipOn = dyn(0xE9EEF4, 0x232A33)
}

enum Fmt {
    static func price(_ p: Double) -> String {
        if p >= 1000 { return p.formatted(.number.precision(.fractionLength(1))) }
        if p >= 100 { return p.formatted(.number.precision(.fractionLength(2)).grouping(.never)) }
        if p >= 1 { return p.formatted(.number.precision(.fractionLength(4)).grouping(.never)) }
        if p == 0 { return "0" }
        return p.formatted(.number.precision(.significantDigits(4)).grouping(.never))
    }

    static func change(_ c: Double) -> String {
        (c >= 0 ? "▲" : "▼") + String(format: "%.2f%%", abs(c))
    }

    static func bigUSD(_ v: Double) -> String {
        switch v {
        case 1e12...: String(format: "$%.2fT", v / 1e12)
        case 1e9...: String(format: "$%.2fB", v / 1e9)
        case 1e6...: String(format: "$%.1fM", v / 1e6)
        default: String(format: "$%.0f", v)
        }
    }

    static let hms = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        timeZone: .current, calendar: .current)
}
