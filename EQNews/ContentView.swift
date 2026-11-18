import Charts
import SwiftUI

// 布局对照 eqn.news 手机版：顶栏（Logo · 搜索 · 设置）+ 底部 快讯 / 频道 / 行情

enum AppTab: Hashable { case feed, channels, watch, market }

struct ContentView: View {
    @State private var tab: AppTab = ProcessInfo.processInfo.arguments.contains("-openMarket") ? .market
        : ProcessInfo.processInfo.arguments.contains("-openChannelsTab") ? .channels
        : ProcessInfo.processInfo.arguments.contains("-openWatchTab") ? .watch : .feed
    @AppStorage("filter.channel") private var channel = "all"
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")

    var body: some View {
        TabView(selection: $tab) {
            Tab("快讯", systemImage: "list.bullet", value: AppTab.feed) {
                FeedView(channel: $channel, showSettings: $showSettings)
            }
            Tab("频道", systemImage: "square.grid.2x2", value: AppTab.channels) {
                ChannelsView(channel: $channel) { tab = .feed }
            }
            Tab("自选", systemImage: "star", value: AppTab.watch) {
                MyWatchView(showSettings: $showSettings)
            }
            Tab("行情", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.market) {
                MarketView(showSettings: $showSettings)
            }
        }
        .tint(Color.eqAccent)
        .sheet(isPresented: $showSettings) { SettingsView() }
        // 小组件 / 手表：eqnews://open?url=<快讯链接>
        .onOpenURL { u in
            guard u.scheme == "eqnews",
                  let s = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: s) else { return }
            tab = .feed
            PushManager.shared.pendingOpen = target
        }
    }
}

// MARK: - 顶栏

struct AppHeader: View {
    @Binding var searching: Bool
    var onSettings: () -> Void

    var body: some View {
        HStack {
            BrandLogo()
            Spacer()
            Button { withAnimation(.snappy) { searching.toggle() } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("搜索")
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .regular))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("设置")
        }
        .foregroundStyle(Color.eqText)
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 4)
        .background(Color.eqCard)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.eqLine).frame(height: 0.5) }
    }
}

struct BrandLogo: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark").resizable().renderingMode(.template).scaledToFit().frame(height: 26)
            VStack(alignment: .leading, spacing: -2) {
                Text("方程式新闻").font(.system(size: 17, weight: .bold))
                Text("EquationNews").font(.system(size: 11.5, weight: .semibold))
            }
        }
        .foregroundStyle(Color.eqText)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("方程式新闻 EquationNews")
    }
}

struct RemoteIcon: View {
    let url: URL?
    var size: CGFloat = 20
    var fallback: String = ""

    var body: some View {
        AsyncImage(url: url) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.eqChip)
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Color.eqMuted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.eqLine, lineWidth: 0.5))
    }

    private var initials: String {
        String(fallback.filter { $0.isASCII && $0.isLetter }.prefix(2)).uppercased()
    }
}

struct ChannelIcon: View {
    let key: String
    var size: CGFloat = 22

    var body: some View {
        switch Channels.icon(key) {
        case .image(let u):
            RemoteIcon(url: u, size: size, fallback: Channels.name(key))
        case .symbol(let name, let color) where name == "alpha":
            Text("α").font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.75))
                .frame(width: size, height: size)
                .background(color, in: Circle())
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(key == "alpha" ? Color.black.opacity(0.75) : color)
                .frame(width: size, height: size)
                .background(key == "alpha" ? color : color.opacity(0.12), in: Circle())
        }
    }
}

struct LivePill: View {
    let ok: Bool
    var text: String = "实时"
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.eqAccentDeep : Color.orange).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.eqChip, in: Capsule())
        .overlay(Capsule().stroke(Color.eqLine, lineWidth: 1))
        .foregroundStyle(Color.eqAccentDeep)
    }
}

// MARK: - 快讯

struct FeedView: View {
    @Environment(EqnClient.self) private var client
    @Environment(Speaker.self) private var speaker
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dts
    @Binding var channel: String
    @Binding var showSettings: Bool
    @AppStorage("show.en") private var showEn = false
    @AppStorage("read.font") private var fontRaw = ReadingFont.sans.rawValue
    @AppStorage("read.scale") private var scale = 1.0
    @AppStorage("read.compactData") private var compactData = true
    @AppStorage("read.lastSeen") private var lastSeenStored = 0.0
    @Environment(Watchlist.self) private var watchlist
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var selected: NewsItem?
    @State private var showBriefing = false
    @State private var remote: [NewsItem] = []
    @State private var remoteQuery = ""
    @State private var remoteLoading = false
    @State private var remoteError: String?
    /// 滚离顶部时冻结列表：之后到的新快讯先攒着，点按钮再插入
    @State private var holdAfter: Date?
    /// 本次启动时的「上次看到」时间点（之前的条目淡化）
    @State private var readBefore: Date? = {
        let v = UserDefaults.standard.double(forKey: "read.lastSeen")
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }()

    private var style: ReadingStyle {
        ReadingStyle(font: ReadingFont(rawValue: fontRaw) ?? .sans, scale: scale, dynamicType: dts)
    }

    private var filtered: [NewsItem] {
        client.items.filter { n in
            (channel == "all" || n.channels.contains(channel)) &&
            (query.isEmpty || ([n.title, n.titleEn ?? "", n.source] + n.coins).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var shown: [NewsItem] {
        guard let h = holdAfter else { return filtered }
        return filtered.filter { !$0.via.isLive || $0.receivedAt <= h }
    }

    private var pending: Int { holdAfter == nil ? 0 : filtered.count - shown.count }

    private var days: [(day: Date, items: [NewsItem])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: shown) { cal.startOfDay(for: $0.sortDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    /// 「上次看到这里」分隔线放在第一条已读条目之前
    private var firstReadID: String? {
        guard let rb = readBefore, let i = shown.firstIndex(where: { $0.sortDate <= rb }), i > 0 else { return nil }
        return shown[i].id
    }

    var body: some View {
        NavigationStack {
            feed
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selected) { DetailView(item: $0) }
        }
        .sheet(isPresented: $showBriefing) { BriefingView() }
        #if DEBUG
        .task {
            let a = ProcessInfo.processInfo.arguments
            if let i = a.firstIndex(of: "-openDetail"), i + 1 < a.count, let u = URL(string: a[i + 1]) {
                try? await Task.sleep(for: .seconds(2)); PushManager.shared.pendingOpen = u
            }
            if a.contains("-openBriefing") { showBriefing = true }
        }
        #endif
        .onChange(of: PushManager.shared.pendingOpen) { _, u in
            guard let u else { return }
            PushManager.shared.pendingOpen = nil
            // 非 eqn.news 链接（如 WS 推送带的原文链接）直接用浏览器打开
            // 深链来自外部，只接受 http(s)；eqn.news 需精确匹配域名
            guard let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = u.host?.lowercased() else { return }
            guard host == "eqn.news" || host.hasSuffix(".eqn.news") else {
                if let hit = client.items.first(where: { $0.sourceURL == u || $0.url == u }) { selected = hit } else { openURL(u) }
                return
            }
            // 已加载就用现成条目，否则用链接建一个占位，详情页按编号加载
            selected = client.items.first { $0.url == u } ?? NewsItem(
                id: u.absoluteString, via: .backlog, no: Int(u.lastPathComponent), kind: nil, title: "", titleEn: nil,
                source: "", sourceSlug: nil, coins: [], url: u, sourceURL: nil, images: [], channels: [], publishedAt: nil, receivedAt: Date())
        }
    }

    private var remoteExtra: [NewsItem] {
        let have = Set(shown.map(\.id))
        return remote.filter { !have.contains($0.id) }
    }

    private func runRemoteSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { remote = []; return }
        remoteQuery = q; remoteLoading = true; remoteError = nil
        Task {
            do { remote = try await EqnAPI.search(q, channel: channel) } catch { remoteError = error.localizedDescription; remote = [] }
            remoteLoading = false
        }
    }

    private var feed: some View {
        VStack(spacing: 0) {
            AppHeader(searching: $searching) { showSettings = true }
            if searching { searchBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Color.clear.frame(height: 0).id("top")
                        feedTitle
                        ChannelChips(channel: $channel)
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.items) { n in
                                    if n.id == firstReadID { readMarker }
                                    row(n)
                                    Rectangle().fill(Color.eqLine).frame(height: 0.5)
                                }
                            } header: {
                                DayHeader(day: group.day, count: group.items.count)
                            }
                        }
                        if !query.isEmpty && (remoteLoading || !remoteExtra.isEmpty || remoteError != nil || remoteQuery == query) {
                            Section {
                                if remoteLoading {
                                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                                } else if let e = remoteError {
                                    Text(e).font(.footnote).foregroundStyle(Color.eqDown).padding(.vertical, 12)
                                } else if remoteExtra.isEmpty {
                                    Text("近 30 天没有更多结果").font(.footnote).foregroundStyle(Color.eqMuted).padding(.vertical, 12)
                                }
                                ForEach(remoteExtra) { n in
                                    row(n)
                                    Rectangle().fill(Color.eqLine).frame(height: 0.5)
                                }
                            } header: {
                                HStack {
                                    Label("近 30 天", systemImage: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    if !remoteExtra.isEmpty { Text("\(remoteExtra.count) 条").font(.system(size: 13)).foregroundStyle(Color.eqMuted) }
                                }
                                .padding(.vertical, 10).background(Color.eqCard)
                            }
                        }
                        if shown.isEmpty && query.isEmpty {
                            Text(client.items.isEmpty ? "加载中…" : "没有匹配的快讯")
                                .font(.subheadline).foregroundStyle(Color.eqMuted)
                                .frame(maxWidth: .infinity).padding(.vertical, 60)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Color.eqCard)
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await client.refresh() }
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.contentInsets.top < 80
                } action: { _, atTop in
                    if atTop { holdAfter = nil } else if holdAfter == nil { holdAfter = Date() }
                }
                .overlay(alignment: .top) {
                    if pending > 0 {
                        Button {
                            holdAfter = nil
                            withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                        } label: {
                            Label("\(pending) 条新快讯", systemImage: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Color.eqAccentDeep, in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        }
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: pending > 0)
            }
            .safeAreaInset(edge: .bottom) { PlayerBar() }
        }
        .background(Color.eqCard)
        .onChange(of: phase) { _, p in
            // 切到后台时记住看到哪了，下次打开淡化已读
            if p == .background, let newest = client.items.first?.sortDate {
                lastSeenStored = newest.timeIntervalSince1970
            }
        }
    }

    @ViewBuilder private func row(_ n: NewsItem) -> some View {
        let isData = Channels.group(of: n.channels.first ?? "").title == "监控 · 行情异动"
        let read = readBefore.map { n.sortDate <= $0 } ?? false
        let level = watchlist.level(for: n)
        let alert = level == .loud || level == .notify ? level : nil
        Group {
            if compactData && isData && alert == nil {
                CompactRow(item: n, style: style, speaking: speaker.nowPlayingID == n.id) { selected = n }
            } else {
                NewsRow(item: n, style: style, showEn: showEn, isData: isData, speaking: speaker.nowPlayingID == n.id,
                        alert: alert,
                        onCoin: { c in query = c; searching = true },
                        onChannel: { c in channel = c },
                        onOpen: { selected = n })
            }
        }
        .opacity(read ? 0.55 : 1)
        .contextMenu { RowMenu(item: n) }
    }

    private var readMarker: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.eqAccentDeep.opacity(0.4)).frame(height: 1)
            Text("上次看到这里").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.eqAccentDeep)
            Rectangle().fill(Color.eqAccentDeep.opacity(0.4)).frame(height: 1)
        }
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.eqMuted)
            TextField("搜索快讯、币种或交易所", text: $query)
                .focused($searchFocused).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit(runRemoteSearch)
            if !query.isEmpty {
                Button { query = ""; remote = []; remoteQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.eqMuted) }
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Color.eqChip, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.eqCard)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, q in if q != remoteQuery { remote = []; remoteError = nil } }
    }

    private var feedTitle: some View {
        HStack(spacing: 10) {
            Text("7×24 快讯").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.eqText)
            Spacer()
            Button { showBriefing = true } label: {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color.eqChip, in: Circle())
                    .overlay(Circle().stroke(Color.eqLine, lineWidth: 1))
                    .foregroundStyle(Color.eqAccentDeep)
            }
            .accessibilityLabel("AI 要点")
            LivePill(ok: client.wsState == .ok, text: client.wsState == .ok ? "实时" : client.wsState.text)
            Button {
                if !speaker.enabled && !speaker.hasKey { showSettings = true } else { speaker.enabled.toggle() }
            } label: {
                Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(speaker.enabled ? Color.eqAccentDeep : Color.eqChip, in: Circle())
                    .overlay(Circle().stroke(Color.eqLine, lineWidth: speaker.enabled ? 0 : 1))
                    .foregroundStyle(speaker.enabled ? Color.white : Color.eqAccentDeep)
            }
            .accessibilityLabel(speaker.enabled ? "关闭语音播报" : "开启语音播报")
        }
        .padding(.top, 14).padding(.bottom, 10)
    }
}

private struct RowMenu: View {
    @Environment(Speaker.self) private var speaker
    let item: NewsItem
    var body: some View {
        Button { speaker.enqueue(item, manual: true) } label: { Label("朗读", systemImage: "speaker.wave.2") }
        if let u = item.url { Link(destination: u) { Label("打开详情", systemImage: "safari") } }
        if let u = item.sourceURL { Link(destination: u) { Label("打开原文", systemImage: "link") } }
        if let u = item.url { ShareLink(item: u) { Label("分享", systemImage: "square.and.arrow.up") } }
        Button { UIPasteboard.general.string = item.title } label: { Label("复制", systemImage: "doc.on.doc") }
    }
}

private struct ChannelChips: View {
    @Environment(EqnClient.self) private var client
    @Binding var channel: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["all"] + Channels.all.map(\.key), id: \.self) { k in
                        let on = k == channel
                        Button { channel = k } label: {
                            HStack(spacing: 6) {
                                if k != "all" { ChannelIcon(key: k, size: 20) }
                                Text(Channels.name(k)).font(.system(size: 14, weight: on ? .semibold : .regular))
                                if let n = k == "all" ? client.todayTotal : client.todayCounts[k], n > 0 {
                                    Text("\(n)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.eqMuted)
                                }
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(on ? Color.eqChipOn : Color.eqCard, in: Capsule())
                            .overlay(Capsule().stroke(Color.eqLine, lineWidth: on ? 0 : 1))
                            .foregroundStyle(on ? Color.eqAccentDeep : Color.eqText)
                        }
                        .buttonStyle(.plain)
                        .id(k)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(channel, anchor: .center) }
            .onChange(of: channel) { _, c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
        }
        .padding(.bottom, 10)
    }
}

private struct DayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        let cal = Calendar.current
        let md = "\(cal.component(.month, from: day))/\(cal.component(.day, from: day))"
        let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: day) - 1]
        let rel = cal.isDateInToday(day) ? "今天" : cal.isDateInYesterday(day) ? "昨天" : nil
        HStack(spacing: 12) {
            Text(md).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(Color.eqText)
            HStack(spacing: 3) {
                Text(week)
                if let rel { Text("·"); Text(rel).foregroundStyle(Color.eqAccentDeep) }
            }
            .font(.system(size: 14)).foregroundStyle(Color.eqMuted)
            Spacer()
            Text("\(count) 条").font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.eqMuted)
        }
        .padding(.vertical, 10)
        .background(Color.eqCard)
        .overlay(alignment: .top) { Rectangle().fill(Color.eqLine).frame(height: 0.5) }
    }
}

// MARK: - 行情类紧凑行（一行灰字，不抢正文）

private struct CompactRow: View {
    let item: NewsItem
    let style: ReadingStyle
    let speaking: Bool
    let onOpen: () -> Void

    var body: some View {
        let text = Typeset.lines(item.title).first ?? item.headline
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.sortDate.formatted(Fmt.hms))
                .font(style.mono(12))
                .foregroundStyle(Color.eqMuted)
            ChannelIcon(key: item.channels.first ?? "", size: style.size(14))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + style.size(4.5) }
            Text(Typeset.attributed(text, coins: item.coins, base: style.body(14), bold: style.body(14, bold: true)))
                .foregroundStyle(Color.eqBody)
                .lineLimit(2)
                .lineSpacing(style.lineSpacing(14) * 0.6)
            Spacer(minLength: 0)
            if speaking {
                Image(systemName: "waveform").font(.caption).foregroundStyle(Color.eqUp).symbolEffect(.variableColor.iterative)
            }
        }
        .padding(.leading, 12).padding(.vertical, 9)
        .background(alignment: .leading) { Rectangle().fill(Color.eqLine).frame(width: 3) }
        .background(speaking ? Color.eqUp.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - 快讯行（左侧色条 · 时间 · 频道标签 · 来源 · 正文 · 币种）

struct NewsRow: View {
    let item: NewsItem
    let style: ReadingStyle
    let showEn: Bool
    let isData: Bool
    let speaking: Bool
    let alert: Watchlist.Level?
    let onCoin: (String) -> Void
    let onChannel: (String) -> Void
    let onOpen: () -> Void
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    private var isMain: Bool { item.channels.contains("main") }
    private let collapsedLines = 3

    var body: some View {
        // 读取以便字体下载完成后刷新
        let _ = SerifFont.shared.ready
        let lines = Typeset.lines(item.title)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.sortDate.formatted(Fmt.hms))
                    .font(style.mono(13, weight: .semibold))
                    .foregroundStyle(Color.eqText)
                if isMain {
                    Image("BrandMark").resizable().renderingMode(.template).scaledToFit()
                        .frame(width: 13, height: 13).foregroundStyle(Color.eqText)
                        .accessibilityLabel("主频道已推送")
                }
                if speaking {
                    Image(systemName: "waveform").font(.caption).foregroundStyle(Color.eqUp)
                        .symbolEffect(.variableColor.iterative)
                }
                Spacer(minLength: 4)
                RemoteIcon(url: item.sourceIcon, size: 18, fallback: item.sourceSlug ?? item.source)
                Text(Typeset.pangu(item.source)).font(.system(size: 12)).foregroundStyle(Color.eqMuted).lineLimit(1)
                if let ch = item.channels.first {
                    let g = Channels.group(of: ch)
                    Button { onChannel(ch) } label: {
                        Text(Channels.name(ch))
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(g.tagBG, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(g.tagFG)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: style.lineSpacing(15.5) * 0.6) {
                ForEach(Array(lines.prefix(expanded ? .max : collapsedLines).enumerated()), id: \.offset) { i, line in
                    let first = i == 0
                    let bold = first && !isData
                    let size: CGFloat = first ? 16.5 : 15.5
                    let font = first ? style.title(size, bold: bold) : style.body(size)
                    let boldFont = first ? style.title(size, bold: true) : style.body(size, bold: true)
                    Text(Typeset.attributed(line, coins: item.coins, base: font, bold: boldFont))
                        .foregroundStyle(bold ? Color.eqText : Color.eqBody)
                        .lineSpacing(style.lineSpacing(size))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lines.count > collapsedLines && !expanded {
                    Button("展开全文（共 \(lines.count) 行）") { withAnimation(.snappy) { expanded = true } }
                        .font(.system(size: style.size(13), weight: .medium))
                        .foregroundStyle(Color.eqAccentDeep)
                        .buttonStyle(.plain)
                }
                if showEn, let en = item.headlineEn {
                    Text(Typeset.clean(en)).font(style.body(14)).foregroundStyle(Color.eqMuted)
                        .lineSpacing(style.lineSpacing(14) * 0.8)
                }
            }

            if !item.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(item.images, id: \.self) { u in
                            AsyncImage(url: u) { p in
                                if let img = p.image { img.resizable().scaledToFill() } else { Color.eqChip }
                            }
                            .frame(width: 240, height: 144)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.eqLine, lineWidth: 0.5))
                            .onTapGesture { openURL(u) }
                        }
                    }
                }
            }
            if !item.coins.isEmpty {
                CoinChips(item: item, onTap: onCoin)
            }
        }
        .padding(.leading, 12).padding(.top, 13).padding(.bottom, 14)
        .background(alignment: .leading) {
            Rectangle().fill(alert?.color ?? (isMain ? Color.eqMainBar : Color.eqLine)).frame(width: 3)
        }
        .background(speaking ? Color.eqUp.opacity(0.07) : alert.map { $0.color.opacity(0.05) } ?? Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

struct CoinChips: View {
    @Environment(MarketStore.self) private var market
    @Environment(Watchlist.self) private var watchlist
    let item: NewsItem
    let onTap: (String) -> Void
    private var symbols: [String] { item.coins }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(symbols, id: \.self) { s in
                    let q = market.quote(s)
                    Button { onTap(s) } label: {
                        HStack(spacing: 5) {
                            if let icon = q?.icon { RemoteIcon(url: icon, size: 16, fallback: s) }
                            Text(s).font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundStyle(Color.eqText)
                            if let q {
                                Text(Fmt.price(q.price)).font(.system(size: 12.5, design: .monospaced))
                                Text(Fmt.change(q.change24h))
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(q.change24h >= 0 ? Color.eqUp : Color.eqDown)
                            }
                            // 消息后涨跌：发布 1 分钟后才显示，避免噪音
                            if Date().timeIntervalSince(item.sortDate) > 60, let since = market.sincePublish(item, s), abs(since) >= 0.05 {
                                Text("消息后 " + (since >= 0 ? "+" : "") + String(format: "%.2f%%", since))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5).frame(height: 18)
                                    .background((since >= 0 ? Color.eqUp : Color.eqDown).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(since >= 0 ? Color.eqUp : Color.eqDown)
                            }
                            if let lv = watchlist.coinLevel(s), lv != .none {
                                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(lv.color)
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Color.eqCard, in: Capsule())
                        .overlay(Capsule().stroke(Color.eqLine, lineWidth: 1))
                        .foregroundStyle(Color.eqBody)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(1)
        }
    }
}

// MARK: - 频道（手机版「频道」页）

struct ChannelsView: View {
    @Environment(EqnClient.self) private var client
    @Binding var channel: String
    var onPick: () -> Void
    @State private var searching = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(searching: .constant(false)) { showSettings = true }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("频道").font(.system(size: 17, weight: .bold))
                        Spacer()
                        Text("今日条数").font(.system(size: 13)).foregroundStyle(Color.eqMuted)
                    }
                    .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
                    row("all")
                    ForEach(Channels.groups) { g in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1).fill(g.color).frame(width: 3, height: 13)
                            Text(g.title).font(.system(size: 13)).foregroundStyle(Color.eqMuted)
                        }
                        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
                        ForEach(g.keys, id: \.self) { row($0) }
                    }
                }
                .padding(.bottom, 12)
                .background(Color.eqCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.eqLine, lineWidth: 1))
                .padding(16)
            }
            .background(Color.eqBg)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func row(_ key: String) -> some View {
        let on = key == channel
        return Button {
            channel = key
            onPick()
        } label: {
            HStack(spacing: 10) {
                if key != "all" { ChannelIcon(key: key, size: 24) }
                Text(Channels.name(key)).font(.system(size: 16, weight: key == "all" || on ? .semibold : .regular))
                if key == "tradfi" { Text("TradFi").font(.system(size: 12)).foregroundStyle(Color.eqMuted) }
                Spacer()
                if let n = key == "all" ? client.todayTotal : client.todayCounts[key], n > 0 {
                    Text("\(n)").font(.system(size: 15, design: .monospaced)).foregroundStyle(Color.eqMuted)
                }
            }
            .foregroundStyle(on ? Color.eqAccentDeep : Color.eqText)
            .padding(.horizontal, 12).frame(height: 46)
            .background(on ? Color.eqChipOn : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 行情（手机版 /markets）

struct MarketView: View {
    @Environment(MarketStore.self) private var market
    @Binding var showSettings: Bool
    @AppStorage("market.period") private var periodRaw = MarketStore.Period.h24.rawValue
    @AppStorage("market.excludeStable") private var excludeStable = true
    @AppStorage("market.treemapTop") private var treemapTop = 100
    @State private var listTab = 0

    private var period: MarketStore.Period { MarketStore.Period(rawValue: periodRaw) ?? .h24 }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(searching: .constant(false)) { showSettings = true }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("行情").font(.system(size: 26, weight: .bold)).foregroundStyle(Color.eqText)
                        Text("全市场 · 按市值排序 · 市值前 \(market.coins.count)" + (market.updatedAt.map { " · 更新于 \($0.formatted(Fmt.hms))" } ?? ""))
                            .font(.system(size: 13)).foregroundStyle(Color.eqMuted)
                    }
                    controls
                    if let g = market.global { totalCard(g) }
                    sentimentCard
                    treemapCard
                    listCard
                    if market.failed {
                        Text("行情数据暂时不可用").foregroundStyle(Color.eqMuted).frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(16)
            }
            .refreshable { await market.refresh() }
            .background(Color.eqBg)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarketStore.Period.allCases) { p in
                    Button { periodRaw = p.rawValue } label: {
                        Text(p.rawValue).font(.system(size: 14, weight: p == period ? .semibold : .regular))
                            .frame(width: 44, height: 32)
                            .background(p == period ? Color.eqCard : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(p == period ? Color.eqText : Color.eqMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.eqChip, in: RoundedRectangle(cornerRadius: 10))
            Button { excludeStable.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: excludeStable ? "checkmark.square.fill" : "square")
                        .foregroundStyle(excludeStable ? Color.eqAccentDeep : Color.eqMuted)
                    Text("排除稳定币等").font(.system(size: 14)).foregroundStyle(Color.eqText)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            LivePill(ok: !market.failed)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.eqCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.eqLine, lineWidth: 1))
    }

    private func totalCard(_ g: MarketStore.Global) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("总市值").font(.system(size: 15, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.bigUSD(g.marketCap)).font(.system(size: 30, weight: .regular)).monospacedDigit()
                    Text(Fmt.change(g.marketCapChange)).font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(g.marketCapChange >= 0 ? Color.eqUp : Color.eqDown)
                    Text("24h").font(.system(size: 13)).foregroundStyle(Color.eqMuted)
                }
                if g.history.count > 2 {
                    let down = (g.change7d ?? 0) < 0
                    let lo = g.history.min()!, hi = g.history.max()!
                    Chart(Array(g.history.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("t", i), yStart: .value("lo", lo), yEnd: .value("v", v))
                            .foregroundStyle((down ? Color.eqDown : Color.eqUp).opacity(0.12))
                        LineMark(x: .value("t", i), y: .value("v", v))
                            .foregroundStyle(down ? Color.eqDown : Color.eqUp)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartYScale(domain: lo...hi)
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .frame(height: 110)
                    .overlay(alignment: .topTrailing) { Text(Fmt.bigUSD(hi * 1e9)).font(.caption2.monospaced()).foregroundStyle(Color.eqMuted) }
                    .overlay(alignment: .bottomTrailing) { Text(Fmt.bigUSD(lo * 1e9)).font(.caption2.monospaced()).foregroundStyle(Color.eqMuted) }
                    HStack { Text("7 天前"); Spacer(); Text("现在") }.font(.caption).foregroundStyle(Color.eqMuted)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        stat("24h 成交额") { Text(Fmt.bigUSD(g.volume)) }
                        stat("7 日变化") {
                            if let c = g.change7d { Text(Fmt.change(c)).foregroundStyle(c >= 0 ? Color.eqUp : Color.eqDown) } else { Text("—") }
                        }
                    }
                    GridRow {
                        stat("BTC 占比") { dominance(g.btcDominance) }
                        stat("ETH 占比") { dominance(g.ethDominance) }
                    }
                }
            }
        }
    }

    private func stat<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.eqMuted)
            value().font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(Color.eqText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dominance(_ v: Double) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%.1f%%", v))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.eqChip)
                    Capsule().fill(Color.eqMainBar).frame(width: geo.size.width * min(1, v / 100))
                }
            }
            .frame(height: 5)
        }
    }

    private var sentimentCard: some View {
        card {
            HStack(alignment: .top, spacing: 16) {
                if let f = market.fearGreed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("恐惧与贪婪").font(.system(size: 15, weight: .semibold))
                        Gauge(value: Double(f.value), in: 0...100) {} currentValueLabel: {
                            Text("\(f.value)").font(.system(size: 20, weight: .bold, design: .monospaced))
                        }
                        .gaugeStyle(.accessoryCircular)
                        .tint(Gradient(colors: [Color.eqDown, .orange, .yellow, Color.eqUp]))
                        .scaleEffect(1.3).frame(width: 80, height: 70)
                        Text(f.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(fgColor(f.value))
                        if market.fearGreedHistory.count > 1 {
                            let y = market.fearGreedHistory[market.fearGreedHistory.count - 2]
                            Text("昨天 \(y)").font(.caption).foregroundStyle(Color.eqMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let b = market.breadth(period, excludeStable: excludeStable)
                VStack(alignment: .leading, spacing: 8) {
                    Text("涨跌家数 · \(period.rawValue)").font(.system(size: 15, weight: .semibold))
                    GeometryReader { geo in
                        let total = max(1, b.up + b.down)
                        HStack(spacing: 2) {
                            Rectangle().fill(Color.eqUp).frame(width: geo.size.width * CGFloat(b.up) / CGFloat(total))
                            Rectangle().fill(Color.eqDown)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                    HStack {
                        Text("▲\(b.up)").foregroundStyle(Color.eqUp)
                        Spacer()
                        Text("▼\(b.down)").foregroundStyle(Color.eqDown)
                    }
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    if market.fearGreedHistory.count > 1 {
                        Chart(Array(market.fearGreedHistory.suffix(30).enumerated()), id: \.offset) { i, v in
                            BarMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(fgColor(v).opacity(0.6))
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100)
                        .frame(height: 40)
                        Text("近 30 天情绪").font(.caption2).foregroundStyle(Color.eqMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fgColor(_ v: Int) -> Color {
        switch v { case ..<25: .eqDown; case ..<45: .orange; case ..<56: .yellow; default: .eqUp }
    }

    private var treemapCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("市值矩阵").font(.system(size: 17, weight: .bold))
                    Text("面积 = 市值 · 颜色 = \(period.rawValue) 涨跌").font(.system(size: 12)).foregroundStyle(Color.eqMuted)
                }
                Picker("范围", selection: $treemapTop) {
                    Text("前 50").tag(50); Text("前 100").tag(100); Text("前 200").tag(200)
                }
                .pickerStyle(.segmented)
                let coins = Array(market.visible(excludeStable: excludeStable).prefix(treemapTop))
                Treemap(coins: coins, period: period).frame(height: 420)
            }
        }
    }

    private var listCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Picker("榜单", selection: $listTab) {
                    Text("市值").tag(0); Text("涨幅榜").tag(1); Text("跌幅榜").tag(2)
                }
                .pickerStyle(.segmented)
                let list = listTab == 0 ? Array(market.visible(excludeStable: excludeStable).prefix(100))
                    : market.movers(period, up: listTab == 1, excludeStable: excludeStable)
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        CoinRow(index: listTab == 0 ? c.rank : i + 1, coin: c, change: c.change(period))
                        Divider()
                    }
                }
                if listTab != 0 {
                    Text("市值前 500 · \(period.rawValue) · 成交额 ≥ $1M").font(.caption).foregroundStyle(Color.eqMuted)
                }
            }
        }
    }
}

/// Squarified treemap：面积 ∝ 市值，红绿深浅 ∝ 涨跌
private struct Treemap: View {
    let coins: [MarketStore.Coin]
    let period: MarketStore.Period

    var body: some View {
        GeometryReader { geo in
            let rects = Self.layout(coins.map { max($0.marketCap, 1) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(coins, rects)), id: \.0.id) { c, r in
                    let ch = c.change(period)
                    let big = r.width > 70 && r.height > 50
                    VStack(alignment: .leading, spacing: 2) {
                        if r.width > 34 && r.height > 18 {
                            HStack(spacing: 4) {
                                if big { RemoteIcon(url: c.icon, size: min(28, r.height / 4), fallback: c.symbol) }
                                Text(c.symbol)
                                    .font(.system(size: big ? min(28, max(12, r.width / 6)) : 10, weight: .bold, design: .monospaced))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                            }
                            if r.height > 34 {
                                Text(Fmt.change(ch)).font(.system(size: big ? min(20, max(10, r.width / 9)) : 9, design: .monospaced))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                            }
                            if big && r.height > 90 {
                                Text("$" + Fmt.price(c.price)).font(.system(size: min(16, r.width / 10), design: .monospaced))
                                    .foregroundStyle(Color.eqMuted).lineLimit(1)
                            }
                        }
                    }
                    .foregroundStyle(Color.eqText)
                    .padding(r.width > 60 ? 6 : 2)
                    .frame(width: max(0, r.width - 1.5), height: max(0, r.height - 1.5), alignment: .topLeading)
                    .background(Self.color(ch))
                    .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    static func color(_ ch: Double) -> Color {
        let a = min(1, abs(ch) / 8) * 0.55 + 0.12
        return (ch >= 0 ? Color.eqUp : Color.eqDown).opacity(a)
    }

    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let total = values.reduce(0, +)
        let scale = rect.width * rect.height / total
        var out = [CGRect](repeating: .zero, count: values.count)
        var rest = rect
        var i = 0
        while i < values.count {
            let side = min(rest.width, rest.height)
            var row: [Int] = [i]
            var worstPrev = worst(row.map { values[$0] * scale }, side)
            var j = i + 1
            while j < values.count {
                let w = worst((row + [j]).map { values[$0] * scale }, side)
                if w > worstPrev { break }
                row.append(j); worstPrev = w; j += 1
            }
            let area = row.reduce(0.0) { $0 + values[$1] * scale }
            let thick = area / side
            var pos: CGFloat = 0
            for k in row {
                let len = values[k] * scale / thick
                out[k] = rest.width >= rest.height
                    ? CGRect(x: rest.minX, y: rest.minY + pos, width: thick, height: len)
                    : CGRect(x: rest.minX + pos, y: rest.minY, width: len, height: thick)
                pos += len
            }
            rest = rest.width >= rest.height
                ? CGRect(x: rest.minX + thick, y: rest.minY, width: rest.width - thick, height: rest.height)
                : CGRect(x: rest.minX, y: rest.minY + thick, width: rest.width, height: rest.height - thick)
            i = j
        }
        return out
    }

    private static func worst(_ areas: [Double], _ side: Double) -> Double {
        let s = areas.reduce(0, +), mx = areas.max() ?? 0, mn = areas.min() ?? 0
        guard s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), s * s / (side * side * mn))
    }
}

private struct CoinRow: View {
    let index: Int
    let coin: MarketStore.Coin
    let change: Double

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.eqMuted)
                .frame(width: 28, alignment: .leading)
            RemoteIcon(url: coin.icon, size: 22, fallback: coin.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(coin.symbol).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(coin.name).font(.caption2).foregroundStyle(Color.eqMuted).lineLimit(1)
            }
            Spacer()
            Text(Fmt.price(coin.price)).font(.system(size: 14, design: .monospaced))
            Text((change >= 0 ? "+" : "") + String(format: "%.2f%%", change))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(change >= 0 ? Color.eqUp : Color.eqDown)
                .frame(width: 82, alignment: .trailing)
        }
        .foregroundStyle(Color.eqText)
        .padding(.vertical, 9)
    }
}

// MARK: - 播放条

private struct PlayerBar: View {
    @Environment(Speaker.self) private var speaker
    var body: some View {
        if speaker.nowPlaying != nil || speaker.queueCount > 0 || speaker.lastError != nil {
            HStack(spacing: 10) {
                if let now = speaker.nowPlaying {
                    Image(systemName: "waveform").foregroundStyle(Color.eqUp).symbolEffect(.variableColor.iterative)
                    Text(now).lineLimit(1).font(.footnote)
                } else if let e = speaker.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.eqDown)
                    Text("播报失败：\(e)").lineLimit(2).font(.footnote).foregroundStyle(Color.eqDown)
                } else {
                    Text("准备播报…").font(.footnote).foregroundStyle(Color.eqMuted)
                }
                Spacer(minLength: 0)
                if speaker.queueCount > 0 {
                    Text("待播 \(speaker.queueCount)").font(.caption).foregroundStyle(Color.eqMuted).monospacedDigit()
                }
                Button { speaker.skip() } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("跳过")
                Button { speaker.clear() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("清空")
            }
            .foregroundStyle(Color.eqText)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }
}
