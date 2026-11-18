import SwiftUI

/// MCP get_news：全文（多语言）+ AI 摘要 / AI 背景
struct NewsDetail: Decodable, Sendable {
    struct Point: Decodable, Sendable { let zh: String?; let en: String? }
    struct Summary: Decodable, Sendable { let type: String?; let points: [Point]? }
    struct Paragraph: Decodable, Sendable { let text: String; let sources: [String]? }
    struct OverviewText: Decodable, Sendable { let paragraphs: [Paragraph]? }
    struct Overview: Decodable, Sendable {
        let status: String
        let updated_at: String?
        let following: Bool?
        let zh: OverviewText?
        let en: OverviewText?
    }
    struct AI: Decodable, Sendable { let summary: Summary?; let overview: Overview?; let notice: String? }

    let no: Int
    let time: String
    let channels: [String]
    let source: String
    let zh: String?
    let en: String?
    let ko: String?
    let body: String?
    let coins: [String]?
    let url: String
    let source_url: String?
    let images: [String]?
    let telegram: [String]?
    let ai: AI?
}

enum EqnAPI {
    private struct Resp<T: Decodable>: Decodable {
        struct R: Decodable { let structuredContent: T?; let isError: Bool? }
        struct E: Decodable { let message: String }
        let result: R?
        let error: E?
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func call<T: Decodable>(_ tool: String, _ args: [String: Any], as: T.Type) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.eqn.news/public/mcp")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": Int.random(in: 1...999_999), "method": "tools/call",
            "params": ["name": tool, "arguments": args],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(message: code == 429 ? "请求太频繁，稍后再试" : "HTTP \(code)") }
        let r = try JSONDecoder().decode(Resp<T>.self, from: data)
        if let e = r.error { throw Failure(message: e.message) }
        guard let v = r.result?.structuredContent, r.result?.isError != true else { throw Failure(message: "没有数据") }
        return v
    }

    static func detail(_ no: Int) async throws -> NewsDetail {
        try await call("get_news", ["no": no], as: NewsDetail.self)
    }

    static func number(of item: NewsItem) -> Int? {
        item.no ?? item.url.flatMap { Int($0.lastPathComponent) }
    }
}

struct DetailView: View {
    @Environment(Speaker.self) private var speaker
    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.openURL) private var openURL
    @AppStorage("read.font") private var fontRaw = ReadingFont.sans.rawValue
    @AppStorage("read.scale") private var scale = 1.0
    let item: NewsItem

    @State private var detail: NewsDetail?
    @State private var error: String?
    @State private var lang = "zh"

    private var style: ReadingStyle { ReadingStyle(font: ReadingFont(rawValue: fontRaw) ?? .sans, scale: scale, dynamicType: dts) }

    private var text: String {
        switch lang {
        case "en": detail?.en ?? item.titleEn ?? item.title
        case "ko": detail?.ko ?? item.title
        default: detail?.zh ?? item.title
        }
    }

    var body: some View {
        let _ = SerifFont.shared.ready
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                meta
                if langs.count > 1 {
                    Picker("语言", selection: $lang) {
                        ForEach(langs, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                }
                content
                if let s = detail?.ai?.summary, let pts = s.points, !pts.isEmpty { summaryCard(pts) }
                if let o = detail?.ai?.overview { overviewCard(o) }
                if !item.coins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("相关币种").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.eqMuted)
                        CoinChips(item: item, onTap: { _ in })
                    }
                }
                images
                links
                if let n = detail?.ai?.notice, detail?.ai?.summary != nil || detail?.ai?.overview != nil {
                    Text(n == "AI-generated, for reference only; may contain errors." ? "AI 生成，仅供参考，可能有误。" : n)
                        .font(.caption2).foregroundStyle(Color.eqMuted)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.eqDown)
                }
            }
            .padding(16)
        }
        .background(Color.eqCard)
        .navigationTitle(Channels.name(item.channels.first ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { speaker.enqueue(item, manual: true) } label: { Image(systemName: "speaker.wave.2") }
                    .accessibilityLabel("朗读")
                if let u = item.url { ShareLink(item: u) { Image(systemName: "square.and.arrow.up") } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var langs: [(String, String)] {
        var l = [("zh", "中文")]
        if (detail?.en ?? item.titleEn) != nil { l.append(("en", "English")) }
        if detail?.ko != nil { l.append(("ko", "한국어")) }
        return l
    }

    private func load() async {
        guard let no = EqnAPI.number(of: item) else { error = "这条快讯没有编号，无法加载详情"; return }
        do { detail = try await EqnAPI.detail(no); error = nil } catch { self.error = error.localizedDescription }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            if let ch = item.channels.first {
                let g = Channels.group(of: ch)
                Text(Channels.name(ch)).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(g.tagBG, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(g.tagFG)
            }
            RemoteIcon(url: item.sourceIcon, size: 20, fallback: item.sourceSlug ?? item.source)
            Text(Typeset.pangu(item.source)).font(.system(size: 13)).foregroundStyle(Color.eqMuted).lineLimit(1)
            Spacer()
            Text(item.sortDate.formatted(.dateTime.month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute().second().locale(Locale(identifier: "zh_CN"))))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.eqMuted)
        }
    }

    private var content: some View {
        let lines = Typeset.lines(text)
        return VStack(alignment: .leading, spacing: style.lineSpacing(16)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let size: CGFloat = i == 0 ? 20 : 16.5
                let f = i == 0 ? style.title(size, bold: true) : style.body(size)
                Text(Typeset.attributed(line, coins: item.coins, base: f, bold: i == 0 ? f : style.body(size, bold: true)))
                    .foregroundStyle(i == 0 ? Color.eqText : Color.eqBody)
                    .lineSpacing(style.lineSpacing(size))
                    .textSelection(.enabled)
            }
            if let b = detail?.body, !b.isEmpty, lang == "zh" || lang == "en" {
                Text(Typeset.clean(b)).font(style.body(15.5)).foregroundStyle(Color.eqBody)
                    .lineSpacing(style.lineSpacing(15.5)).textSelection(.enabled)
            }
        }
    }

    private func aiCard<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.eqAccentDeep)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.eqChipOn, in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryCard(_ pts: [NewsDetail.Point]) -> some View {
        aiCard("AI 摘要", icon: "sparkles") {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(Color.eqAccentDeep)
                    Text(Typeset.pangu((lang == "en" ? p.en : p.zh) ?? p.zh ?? p.en ?? ""))
                        .font(style.body(15)).foregroundStyle(Color.eqText)
                        .lineSpacing(style.lineSpacing(15) * 0.7)
                }
            }
        }
    }

    private func overviewCard(_ o: NewsDetail.Overview) -> some View {
        aiCard("AI 背景", icon: "text.magnifyingglass") {
            if o.status == "pending" {
                Text("AI 正在检索背景资料，几分钟后下拉刷新。").font(.footnote).foregroundStyle(Color.eqMuted)
            }
            let paras = (lang == "en" ? o.en : o.zh)?.paragraphs ?? o.zh?.paragraphs ?? []
            ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Typeset.pangu(p.text)).font(style.body(15)).foregroundStyle(Color.eqText)
                        .lineSpacing(style.lineSpacing(15) * 0.7)
                    if let s = p.sources, !s.isEmpty {
                        Text("来源：" + s.joined(separator: "、")).font(.caption2).foregroundStyle(Color.eqMuted)
                    }
                }
            }
            if o.following == true {
                Text("发布后 2 小时内会持续更新").font(.caption2).foregroundStyle(Color.eqMuted)
            }
        }
    }

    @ViewBuilder private var images: some View {
        let urls = (detail?.images ?? []).compactMap { s in s.hasPrefix("http") ? URL(string: s) : URL(string: "https://eqn.news" + (s.hasPrefix("/") ? s : "/" + s)) }
        let all = urls.isEmpty ? item.images : urls
        ForEach(all, id: \.self) { u in
            AsyncImage(url: u) { p in
                if let img = p.image { img.resizable().scaledToFit() } else { Color.eqChip.frame(height: 180) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { openURL(u) }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = detail?.source_url ?? item.sourceURL?.absoluteString, let u = URL(string: s) { linkRow("原文", u, "link") }
            if let u = item.url { linkRow("网页版", u, "safari") }
            ForEach(detail?.telegram ?? [], id: \.self) { s in
                if let u = URL(string: s) { linkRow("Telegram · \(u.pathComponents.dropFirst().first ?? "")", u, "paperplane") }
            }
        }
        .background(Color.eqBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private func linkRow(_ title: String, _ url: URL, _ icon: String) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 15))
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.eqMuted)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .foregroundStyle(Color.eqText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
