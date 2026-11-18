import Foundation
import Observation
import SwiftUI

// MARK: - 30 天搜索（MCP list_news 的 query / coin 参数，服务端检索）

extension EqnAPI {
    struct ListItem: Decodable, Sendable {
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
    struct ListResult: Decodable, Sendable { let items: [ListItem]; let next_cursor: String? }

    /// 关键词搜索覆盖近 30 天；看起来像币种代码时同时按币种查
    static func search(_ q: String, channel: String) async throws -> [NewsItem] {
        let query = q.trimmingCharacters(in: .whitespaces)
        var args: [String: Any] = ["channel": channel, "limit": 50]
        if query.range(of: #"^[A-Za-z0-9]{2,10}$"#, options: .regularExpression) != nil {
            args["coin"] = query.uppercased()
        } else {
            args["query"] = query
        }
        var r = try await call("list_news", args, as: ListResult.self)
        // 币种查不到时退回关键词
        if r.items.isEmpty, args["coin"] != nil {
            args.removeValue(forKey: "coin"); args["query"] = query
            r = try await call("list_news", args, as: ListResult.self)
        }
        return r.items.map { it in
            NewsItem(id: it.url, via: .backlog, no: it.no, kind: nil, title: it.zh ?? it.en ?? "", titleEn: it.en,
                     source: it.source, sourceSlug: nil, coins: it.coins ?? [], url: URL(string: it.url),
                     sourceURL: it.source_url.flatMap(URL.init(string:)), images: [], channels: it.channels,
                     publishedAt: EqnClient.parseDate(it.time), receivedAt: Date())
        }
    }
}

// MARK: - 每小时要点（xAI Grok 总结）

@MainActor @Observable
final class Briefing {
    struct Brief: Sendable {
        let text: String
        let at: Date
        let since: Date
        let count: Int
    }

    private(set) var latest: Brief?
    private(set) var working = false
    private(set) var error: String?
    var auto: Bool = UserDefaults.standard.bool(forKey: "brief.auto") {
        didSet { UserDefaults.standard.set(auto, forKey: "brief.auto") }
    }
    var autoSpeak: Bool = UserDefaults.standard.object(forKey: "brief.autoSpeak") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "brief.autoSpeak") }
    }

    static let model = "grok-4.20-0309-non-reasoning"
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// 自动模式：每到整点生成上一小时要点
    func start(items: @escaping @MainActor () -> [NewsItem], speak: @escaping @MainActor (String) -> Void) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let next = Calendar.current.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
                try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 5))
                guard let self, self.auto else { continue }
                await self.generate(items: items(), hours: 1)
                if self.autoSpeak, let t = self.latest?.text { speak("整点要点。" + t) }
            }
        }
    }

    func generate(items all: [NewsItem], hours: Double) async {
        guard !working else { return }
        guard let key = Keychain.read() else { error = "需要先在设置里填写 xAI API Key"; return }
        let since = Date().addingTimeInterval(-hours * 3600)
        let items = all.filter { $0.sortDate >= since }.sorted { $0.sortDate < $1.sortDate }
        guard !items.isEmpty else { error = "过去 \(Int(hours)) 小时没有快讯"; return }
        working = true; error = nil
        defer { working = false }

        let lines = items.suffix(150).map { n in
            "[\(n.sortDate.formatted(Fmt.hms))][\(Channels.name(n.channels.first ?? ""))] \(Typeset.lines(n.title).first ?? n.headline)"
        }.joined(separator: "\n")
        let system = """
        你是加密货币快讯编辑。根据给出的快讯列表，用简体中文写 3 到 5 条最重要的要点。
        要求：每条一行，以「• 」开头，40 字以内；优先上币 / 下架公告、监管与宏观、大额异动；
        保留币种代码和关键数字；同类价格异动合并成一条。
        严格只用列表里的信息：不要补充背景、不要评价意义、不要推测不同快讯之间的关联；不要投资建议；不要标题、开场白和结尾。
        """
        do {
            let text = try await XAI.chat(model: Self.model, system: system,
                                          user: "过去 \(Int(hours)) 小时共 \(items.count) 条快讯：\n\(lines)", key: key)
            // 只保留要点行，去掉模型可能加的标题 / Markdown
            let bullets = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
                .filter { $0.hasPrefix("•") || $0.hasPrefix("-") || $0.hasPrefix("·") }
                .map { "• " + $0.drop(while: { "•-· ".contains($0) }) }
            let out = bullets.isEmpty ? text : bullets.prefix(5).joined(separator: "\n")
            latest = Brief(text: out.trimmingCharacters(in: .whitespacesAndNewlines), at: Date(), since: since, count: items.count)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension XAI {
    /// OpenAI 兼容的 chat completions
    static func chat(model: String, system: String, user: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.3,
            "max_tokens": 600,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let msg = (j?["error"] as? [String: Any])?["message"] as? String ?? j?["error"] as? String ?? ""
            throw XAIError(status: status, message: msg)
        }
        let choices = j?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        guard let content = msg?["content"] as? String, !content.isEmpty else { throw XAIError(status: status, message: "空回复") }
        return content
    }
}

struct BriefingView: View {
    @Environment(Briefing.self) private var brief
    @Environment(EqnClient.self) private var client
    @Environment(Speaker.self) private var speaker
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 1.0

    var body: some View {
        @Bindable var b = brief
        NavigationStack {
            Form {
                Section {
                    Picker("时间范围", selection: $hours) {
                        Text("1 小时").tag(1.0); Text("4 小时").tag(4.0); Text("12 小时").tag(12.0)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        Task { await brief.generate(items: client.items, hours: hours) }
                    } label: {
                        HStack {
                            Label("生成要点", systemImage: "sparkles")
                            if brief.working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(brief.working)
                } footer: { Text("用 xAI \(Briefing.model) 总结已加载的快讯（最多 150 条），费用计入你的 xAI 账户。") }

                if let e = brief.error {
                    Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Color.eqDown) }
                }

                if let l = brief.latest {
                    Section {
                        Text(l.text).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled)
                        Button { speaker.speakText(l.text, id: "brief-\(l.at.timeIntervalSince1970)") } label: {
                            Label("朗读要点", systemImage: "speaker.wave.2")
                        }
                    } header: {
                        Text("\(l.since.formatted(Fmt.hms)) 以来 · \(l.count) 条")
                    } footer: { Text("AI 生成，仅供参考，可能有误。") }
                }

                Section {
                    Toggle("整点自动生成", isOn: $b.auto)
                    Toggle("自动生成后朗读", isOn: $b.autoSpeak).disabled(!brief.auto)
                } footer: { Text("App 在前台或开启「后台保持运行」时生效。") }
            }
            .navigationTitle("要点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
