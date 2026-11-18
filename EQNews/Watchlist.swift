import Foundation
import Observation
import SwiftUI

/// 自选与提醒等级。格式与推送中转服务 relay/ 共用：{kind, value, level}
@MainActor @Observable
final class Watchlist {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case coin, keyword, channel
        var id: String { rawValue }
        var label: String {
            switch self { case .coin: "币种"; case .keyword: "关键词"; case .channel: "频道" }
        }
    }

    enum Level: String, Codable, CaseIterable, Identifiable, Comparable {
        case none, notify, loud
        var id: String { rawValue }
        var label: String {
            switch self { case .loud: "播报 + 强提醒"; case .notify: "仅通知"; case .none: "静默" }
        }
        var short: String {
            switch self { case .loud: "播报"; case .notify: "通知"; case .none: "静默" }
        }
        var color: Color {
            switch self { case .loud: .eqDown; case .notify: .orange; case .none: .eqMuted }
        }
        private var rank: Int { switch self { case .none: 0; case .notify: 1; case .loud: 2 } }
        static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    struct Rule: Codable, Hashable, Identifiable {
        var kind: Kind
        var value: String
        var level: Level
        var id: String { "\(kind.rawValue):\(value.lowercased())" }
    }

    private(set) var rules: [Rule] = []
    /// 没有命中任何规则时，用原来的「播报哪些频道」设置
    var useChannelFallback: Bool { rules.isEmpty }

    private let key = "watchlist.rules"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let r = try? JSONDecoder().decode([Rule].self, from: d) {
            rules = r
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
        NotificationCenter.default.post(name: .watchlistChanged, object: nil)
    }

    func upsert(_ r: Rule) {
        let v = r.value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        let rule = Rule(kind: r.kind, value: r.kind == .coin ? v.uppercased() : v, level: r.level)
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        save()
    }

    func remove(_ r: Rule) { rules.removeAll { $0.id == r.id }; save() }

    func setLevel(_ r: Rule, _ level: Level) { upsert(Rule(kind: r.kind, value: r.value, level: level)) }

    func coinLevel(_ symbol: String) -> Level? {
        rules.first { $0.kind == .coin && $0.value.caseInsensitiveCompare(symbol) == .orderedSame }?.level
    }

    /// 命中规则里最高的等级；无命中返回 nil
    func level(for item: NewsItem) -> Level? {
        var best: Level?
        let text = (item.title + "\n" + (item.titleEn ?? "")).lowercased()
        for r in rules {
            let hit: Bool
            switch r.kind {
            case .coin: hit = item.coins.contains { $0.caseInsensitiveCompare(r.value) == .orderedSame }
            case .keyword: hit = text.contains(r.value.lowercased())
            case .channel: hit = item.channels.contains(r.value)
            }
            if hit, best == nil || r.level > best! { best = r.level }
        }
        return best
    }

    /// 给推送中转服务的 JSON
    var payloadRules: [[String: String]] {
        rules.map { ["kind": $0.kind.rawValue, "value": $0.value, "level": $0.level.rawValue] }
    }
}

extension Notification.Name {
    static let watchlistChanged = Notification.Name("watchlistChanged")
}

// MARK: - 编辑界面

struct WatchlistView: View {
    @Environment(Watchlist.self) private var watchlist
    @Environment(MarketStore.self) private var market
    @State private var kind: Watchlist.Kind = .coin
    @State private var value = ""
    @State private var level: Watchlist.Level = .loud

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $kind) {
                    ForEach(Watchlist.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if kind == .channel {
                    Picker("频道", selection: $value) {
                        Text("选择频道").tag("")
                        ForEach(Channels.all, id: \.key) { Text($0.name).tag($0.key) }
                    }
                } else {
                    TextField(kind == .coin ? "币种代码，如 BTC、SOL" : "关键词，如 上线、listing、Upbit", text: $value)
                        .textInputAutocapitalization(kind == .coin ? .characters : .never)
                        .autocorrectionDisabled()
                }
                Picker("等级", selection: $level) {
                    ForEach(Watchlist.Level.allCases.reversed()) { Text($0.label).tag($0) }
                }
                Button("添加") {
                    watchlist.upsert(.init(kind: kind, value: value, level: level))
                    value = ""
                }
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("添加规则") } footer: {
                Text("一条快讯命中多条规则时取最高等级。「播报」= 语音朗读 + 时效性通知；「通知」= 只在后台时发通知；「静默」= 只在列表里显示。没有任何规则时，沿用「播报哪些频道」设置。")
            }

            ForEach(Watchlist.Kind.allCases) { k in
                let list = watchlist.rules.filter { $0.kind == k }
                if !list.isEmpty {
                    Section(k.label) {
                        ForEach(list) { r in
                            HStack(spacing: 10) {
                                if k == .coin, let icon = market.quote(r.value)?.icon {
                                    RemoteIcon(url: icon, size: 22, fallback: r.value)
                                } else if k == .channel {
                                    ChannelIcon(key: r.value, size: 22)
                                }
                                Text(k == .channel ? Channels.name(r.value) : r.value)
                                    .font(k == .coin ? .body.monospaced().weight(.semibold) : .body)
                                if k == .coin, let q = market.quote(r.value) {
                                    Text(Fmt.price(q.price)).font(.caption.monospaced()).foregroundStyle(Color.eqMuted)
                                }
                                Spacer()
                                Menu {
                                    ForEach(Watchlist.Level.allCases.reversed()) { lv in
                                        Button(lv.label) { watchlist.setLevel(r, lv) }
                                    }
                                } label: {
                                    Text(r.level.short).font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(r.level.color.opacity(0.14), in: Capsule())
                                        .foregroundStyle(r.level.color)
                                }
                            }
                            .swipeActions { Button("删除", role: .destructive) { watchlist.remove(r) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("自选与提醒")
        .navigationBarTitleDisplayMode(.inline)
    }
}
