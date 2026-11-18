import SwiftUI

/// 「自选」tab：自选币价 + 命中规则的快讯 + 规则管理
struct MyWatchView: View {
    @Environment(EqnClient.self) private var client
    @Environment(MarketStore.self) private var market
    @Environment(Watchlist.self) private var watchlist
    @Environment(Speaker.self) private var speaker
    @Environment(\.dynamicTypeSize) private var dts
    @Binding var showSettings: Bool
    @AppStorage("read.font") private var fontRaw = ReadingFont.sans.rawValue
    @AppStorage("read.scale") private var scale = 1.0
    @AppStorage("show.en") private var showEn = false
    @State private var selected: NewsItem?
    @State private var levelFilter: Watchlist.Level? = nil

    private var style: ReadingStyle { ReadingStyle(font: ReadingFont(rawValue: fontRaw) ?? .sans, scale: scale, dynamicType: dts) }
    private var coinRules: [Watchlist.Rule] { watchlist.rules.filter { $0.kind == .coin } }

    private var matched: [(item: NewsItem, level: Watchlist.Level)] {
        client.items.compactMap { n in
            guard let lv = watchlist.level(for: n), lv != .none else { return nil }
            if let f = levelFilter, lv != f { return nil }
            return (n, lv)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(searching: .constant(false)) { showSettings = true }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("自选").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.eqText)
                            Spacer()
                            NavigationLink { WatchlistView() } label: {
                                Label("管理规则", systemImage: "slider.horizontal.3")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(Color.eqChip, in: Capsule())
                                    .overlay(Capsule().stroke(Color.eqLine, lineWidth: 1))
                                    .foregroundStyle(Color.eqAccentDeep)
                            }
                        }
                        .padding(.top, 14)

                        if watchlist.rules.isEmpty {
                            emptyState
                        } else {
                            if !coinRules.isEmpty { pricesCard }
                            newsSection
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 20)
                }
                .refreshable { await client.refresh(); await market.refresh() }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
            }
            .background(Color.eqBg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selected) { DetailView(item: $0) }
        }
    }

    // MARK: 空状态：一键添加常用规则

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没有自选规则").font(.system(size: 17, weight: .semibold))
            Text("添加关注的币种、关键词或频道，命中的快讯会集中显示在这里，并按等级播报或通知。")
                .font(.system(size: 14)).foregroundStyle(Color.eqMuted).lineSpacing(4)
            Text("快速添加").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.eqMuted).padding(.top, 4)
            let presets: [Watchlist.Rule] = [
                .init(kind: .coin, value: "BTC", level: .notify),
                .init(kind: .coin, value: "ETH", level: .notify),
                .init(kind: .keyword, value: "上线", level: .loud),
                .init(kind: .channel, value: "korea", level: .loud),
                .init(kind: .channel, value: "binance", level: .notify),
            ]
            FlowChips(rules: presets) { watchlist.upsert($0) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.eqCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.eqLine, lineWidth: 1))
    }

    // MARK: 自选币价

    private var pricesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("自选币种").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let t = market.updatedAt {
                    Text("更新于 \(t.formatted(Fmt.hms))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.eqMuted)
                }
            }
            .padding(.bottom, 6)
            ForEach(coinRules) { r in
                let q = market.quote(r.value)
                let news = client.items.filter { $0.coins.contains { $0.caseInsensitiveCompare(r.value) == .orderedSame } }.count
                HStack(spacing: 10) {
                    RemoteIcon(url: q?.icon, size: 26, fallback: r.value)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.value).font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text(news > 0 ? "\(news) 条相关快讯" : r.level.label)
                            .font(.system(size: 11)).foregroundStyle(Color.eqMuted)
                    }
                    Spacer()
                    if let q {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.price(q.price)).font(.system(size: 15, design: .monospaced))
                            Text(Fmt.change(q.change24h)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(q.change24h >= 0 ? Color.eqUp : Color.eqDown)
                        }
                    } else {
                        Text("—").foregroundStyle(Color.eqMuted)
                    }
                }
                .padding(.vertical, 8)
                if r.id != coinRules.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(Color.eqCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.eqLine, lineWidth: 1))
    }

    // MARK: 命中快讯

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("命中快讯").font(.system(size: 15, weight: .semibold))
                Text("\(matched.count)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.eqMuted)
                Spacer()
                Picker("等级", selection: $levelFilter) {
                    Text("全部").tag(Watchlist.Level?.none)
                    Text("播报").tag(Watchlist.Level?.some(.loud))
                    Text("通知").tag(Watchlist.Level?.some(.notify))
                }
                .pickerStyle(.segmented).frame(width: 170)
            }
            .padding(16)
            if matched.isEmpty {
                Text("已加载的快讯里暂时没有命中的").font(.system(size: 14)).foregroundStyle(Color.eqMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matched, id: \.item.id) { m in
                    NewsRow(item: m.item, style: style, showEn: showEn,
                            isData: Channels.group(of: m.item.channels.first ?? "").title == "监控 · 行情异动",
                            speaking: speaker.nowPlayingID == m.item.id, alert: m.level,
                            onCoin: { _ in }, onChannel: { _ in }, onOpen: { selected = m.item })
                        .contextMenu {
                            Button { speaker.enqueue(m.item, manual: true) } label: { Label("朗读", systemImage: "speaker.wave.2") }
                        }
                    Rectangle().fill(Color.eqLine).frame(height: 0.5)
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Color.eqCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.eqLine, lineWidth: 1))
    }
}

/// 预设规则按钮（自动换行）
private struct FlowChips: View {
    let rules: [Watchlist.Rule]
    let onAdd: (Watchlist.Rule) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ForEach(rules.prefix(3)) { chip($0) } }
                HStack(spacing: 8) { ForEach(rules.dropFirst(3)) { chip($0) } }
            }
        }
    }

    private var chips: some View { ForEach(rules) { chip($0) } }

    private func chip(_ r: Watchlist.Rule) -> some View {
        Button { onAdd(r) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text(r.kind == .channel ? Channels.name(r.value) : r.value).font(.system(size: 14, weight: .medium))
                Text(r.level.short).font(.system(size: 11, weight: .semibold)).foregroundStyle(r.level.color)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color.eqChip, in: Capsule())
            .foregroundStyle(Color.eqText)
        }
        .buttonStyle(.plain)
    }
}
