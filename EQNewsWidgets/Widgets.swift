import AppIntents
import SwiftUI
import WidgetKit

@main
struct EQNewsWidgets: WidgetBundle {
    var body: some Widget {
        LatestNewsWidget()
        PriceWidget()
    }
}

private extension Color {
    static let up = Color(red: 0.08, green: 0.64, blue: 0.29)
    static let down = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let navy = Color(red: 0.25, green: 0.38, blue: 0.51)
}

// MARK: - 最新快讯

enum WidgetChannel: String, AppEnum {
    case all, main, binance, korea, tier2, tier3, alpha, cz, tradfi, pricechange

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "频道"
    static let caseDisplayRepresentations: [WidgetChannel: DisplayRepresentation] = [
        .all: "全部快讯", .main: "方程式新闻", .binance: "币安公告", .korea: "韩所监控", .tier2: "二线上新",
        .tier3: "三线上新", .alpha: "币安Alpha", .cz: "CZ&何一", .tradfi: "方程式财经", .pricechange: "价格异动",
    ]
}

struct NewsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "最新快讯"
    static let description = IntentDescription("显示所选频道的最新快讯")
    @Parameter(title: "频道", default: .main) var channel: WidgetChannel
}

struct NewsEntry: TimelineEntry {
    let date: Date
    let channel: WidgetChannel
    let items: [LiteNews]
    let failed: Bool
}

struct NewsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NewsEntry {
        NewsEntry(date: .now, channel: .main, items: [
            LiteNews(no: 1, time: .now, channel: "main", source: "EQN", title: "币安将上线 ABC（ABC）", url: nil, coins: ["ABC"]),
            LiteNews(no: 2, time: .now, channel: "korea", source: "Upbit", title: "Upbit 新增 KRW 市场", url: nil, coins: []),
        ], failed: false)
    }

    func snapshot(for config: NewsIntent, in context: Context) async -> NewsEntry {
        context.isPreview ? placeholder(in: context) : await load(config)
    }

    func timeline(for config: NewsIntent, in context: Context) async -> Timeline<NewsEntry> {
        let e = await load(config)
        return Timeline(entries: [e], policy: .after(.now.addingTimeInterval(10 * 60)))
    }

    private func load(_ config: NewsIntent) async -> NewsEntry {
        let items = (try? await LiteAPI.news(channel: config.channel.rawValue, limit: 6)) ?? []
        return NewsEntry(date: .now, channel: config.channel, items: items, failed: items.isEmpty)
    }
}

struct LatestNewsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LatestNews", intent: NewsIntent.self, provider: NewsProvider()) { e in
            NewsWidgetView(entry: e).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("最新快讯")
        .description("方程式新闻最新快讯，约每 10 分钟刷新。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct NewsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NewsEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.items.first.map { "\(hm($0.time)) \($0.headline)" } ?? "方程式新闻")
        case .accessoryRectangular:
            if let n = entry.items.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(hm(n.time)) · \(LiteAPI.channelNames[n.channel] ?? "")").font(.caption2).widgetAccentable()
                    Text(n.headline).font(.caption).lineLimit(3)
                }
                .widgetURL(LiteAPI.deepLink(n))
            } else {
                Text("暂无快讯").font(.caption)
            }
        default:
            let count = family == .systemSmall ? 2 : family == .systemMedium ? 3 : 6
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
                HStack(spacing: 5) {
                    Image("BrandMark").resizable().renderingMode(.template).scaledToFit().frame(width: 12, height: 12)
                    Text(WidgetChannel.caseDisplayRepresentations[entry.channel]?.title ?? "快讯")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(hm(entry.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.navy)
                if entry.items.isEmpty {
                    Spacer()
                    Text(entry.failed ? "加载失败，稍后重试" : "暂无快讯").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(entry.items.prefix(count)) { n in
                        Link(destination: LiteAPI.deepLink(n) ?? URL(string: "eqnews://")!) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if family != .systemSmall {
                                    Text(hm(n.time)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Text(n.headline)
                                    .font(.system(size: family == .systemSmall ? 12.5 : 13.5, weight: .medium))
                                    .lineLimit(family == .systemLarge ? 2 : family == .systemSmall ? 3 : 2)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func hm(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) }
}

// MARK: - 自选币价

struct PriceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "币价"
    static let description = IntentDescription("显示自选币种的价格和 24 小时涨跌")
    @Parameter(title: "币种（逗号分隔）", default: "BTC,ETH,SOL,BNB") var symbols: String
}

struct PriceEntry: TimelineEntry {
    let date: Date
    let quotes: [LiteQuote]
}

struct PriceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PriceEntry {
        PriceEntry(date: .now, quotes: [
            LiteQuote(symbol: "BTC", price: 64000, change24h: -1.2), LiteQuote(symbol: "ETH", price: 1795, change24h: 0.8),
            LiteQuote(symbol: "SOL", price: 74.3, change24h: 2.1), LiteQuote(symbol: "BNB", price: 589, change24h: -0.4),
        ])
    }

    func snapshot(for config: PriceIntent, in context: Context) async -> PriceEntry {
        context.isPreview ? placeholder(in: context) : await load(config)
    }

    func timeline(for config: PriceIntent, in context: Context) async -> Timeline<PriceEntry> {
        Timeline(entries: [await load(config)], policy: .after(.now.addingTimeInterval(10 * 60)))
    }

    private func load(_ c: PriceIntent) async -> PriceEntry {
        let syms = c.symbols.uppercased().split(whereSeparator: { ",， ".contains($0) }).map(String.init).prefix(8)
        return PriceEntry(date: .now, quotes: (try? await LiteAPI.quotes(Array(syms))) ?? [])
    }
}

struct PriceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Prices", intent: PriceIntent.self, provider: PriceProvider()) { e in
            PriceWidgetView(entry: e).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("币价")
        .description("自选币种价格，约每 10 分钟刷新。长按小组件可编辑币种。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct PriceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PriceEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.quotes.prefix(2).map { "\($0.symbol) \(LiteAPI.price($0.price))" }.joined(separator: " · "))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entry.quotes.prefix(3)) { q in
                    HStack {
                        Text(q.symbol).font(.caption2.weight(.bold)).widgetAccentable()
                        Spacer()
                        Text(LiteAPI.price(q.price)).font(.caption2.monospacedDigit())
                        Text(LiteAPI.change(q.change24h)).font(.caption2.monospacedDigit())
                    }
                }
            }
        default:
            let n = family == .systemSmall ? 4 : 8
            let cols = family == .systemSmall ? 1 : 2
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image("BrandMark").resizable().renderingMode(.template).scaledToFit().frame(width: 12, height: 12)
                    Text("币价 · 24h").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.navy)
                if entry.quotes.isEmpty {
                    Spacer(); Text("加载失败，稍后重试").font(.caption).foregroundStyle(.secondary); Spacer()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), alignment: .leading, spacing: 6) {
                        ForEach(entry.quotes.prefix(n)) { q in
                            HStack {
                                Text(q.symbol).font(.system(size: 13, weight: .bold, design: .monospaced))
                                Spacer(minLength: 2)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(LiteAPI.price(q.price)).font(.system(size: 12.5, design: .monospaced))
                                    Text(LiteAPI.change(q.change24h)).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(q.change24h >= 0 ? Color.up : Color.down)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
