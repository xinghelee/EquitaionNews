import SwiftUI

@main
struct EQNewsWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchRoot() }
    }
}

private extension Color {
    static let up = Color(red: 0.2, green: 0.83, blue: 0.6)
    static let down = Color(red: 0.97, green: 0.44, blue: 0.44)
}

struct WatchRoot: View {
    var body: some View {
        TabView {
            NavigationStack { WatchNewsList() }
            NavigationStack { WatchPrices() }
        }
        .tabViewStyle(.verticalPage)
    }
}

struct WatchNewsList: View {
    @AppStorage("watch.channel") private var channel = "main"
    @State private var items: [LiteNews] = []
    @State private var failed = false

    var body: some View {
        List {
            Picker("频道", selection: $channel) {
                ForEach(["main", "all", "binance", "korea", "tier2", "cz"], id: \.self) {
                    Text(LiteAPI.channelNames[$0] ?? $0).tag($0)
                }
            }
            if items.isEmpty {
                Text(failed ? "加载失败" : "加载中…").foregroundStyle(.secondary)
            }
            ForEach(items) { n in
                NavigationLink { WatchDetail(item: n) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(n.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())) · \(LiteAPI.channelNames[n.channel] ?? "")")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Text(n.headline).font(.system(size: 15, weight: .medium)).lineLimit(4)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("方程式新闻")
        .task(id: channel) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do { items = try await LiteAPI.news(channel: channel, limit: 20); failed = false } catch { failed = items.isEmpty }
    }
}

struct WatchDetail: View {
    let item: LiteNews
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(item.time.formatted(.dateTime.month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute())) · \(item.source)")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(item.lines.enumerated()), id: \.offset) { i, l in
                    Text(l).font(.system(size: i == 0 ? 16 : 14, weight: i == 0 ? .semibold : .regular))
                }
                if !item.coins.isEmpty {
                    Text(item.coins.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WatchPrices: View {
    @AppStorage("watch.symbols") private var symbols = "BTC,ETH,SOL,BNB,XRP"
    @State private var quotes: [LiteQuote] = []

    var body: some View {
        List {
            ForEach(quotes) { q in
                HStack {
                    Text(q.symbol).font(.system(size: 15, weight: .bold, design: .monospaced))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(LiteAPI.price(q.price)).font(.system(size: 14, design: .monospaced))
                        Text(LiteAPI.change(q.change24h)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(q.change24h >= 0 ? Color.up : Color.down)
                    }
                }
            }
        }
        .navigationTitle("币价")
        .task {
            while !Task.isCancelled {
                let syms = symbols.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                if let q = try? await LiteAPI.quotes(syms), !q.isEmpty { quotes = q }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
