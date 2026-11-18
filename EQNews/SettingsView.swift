import SwiftUI

struct SettingsView: View {
    @Environment(Speaker.self) private var speaker
    @Environment(EqnClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var keyMsg: String?
    @State private var keyOK = false
    @State private var saving = false
    @Environment(\.dynamicTypeSize) private var dts
    @AppStorage("read.font") private var fontRaw = ReadingFont.sans.rawValue
    @AppStorage("read.scale") private var scale = 1.0
    @AppStorage("read.compactData") private var compactData = true
    @AppStorage("show.en") private var showEn = false
    @AppStorage("read.lastSeen") private var lastSeen = 0.0

    var body: some View {
        @Bindable var s = speaker
        NavigationStack {
            Form {
                Section {
                    NavigationLink { WatchlistView() } label: {
                        Label("自选与提醒", systemImage: "star")
                    }
                    NavigationLink { PushSettingsView() } label: {
                        Label("远程推送", systemImage: "bell.badge")
                    }
                }

                readingSection

                Section {
                    SecureField(speaker.hasKey ? "已保存，输入新 Key 可替换" : "xai-…", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await saveKey() }
                    } label: {
                        HStack { Text(keyInput.isEmpty && speaker.hasKey ? "删除 Key" : "保存并验证"); if saving { Spacer(); ProgressView() } }
                    }
                    .disabled(saving || (keyInput.isEmpty && !speaker.hasKey))
                } header: { Text("xAI API Key") } footer: {
                    if let keyMsg { Text(keyMsg).foregroundStyle(keyOK ? .green : .red) }
                    else { Text(speaker.hasKey ? "已保存在本机钥匙串（仅此设备）。" : "到 console.x.ai 创建 API Key。") }
                }

                Section("播报") {
                    Toggle("自动播报新消息", isOn: $s.enabled)
                    Picker("音色", selection: $s.voice) {
                        if speaker.voices.isEmpty { Text(speaker.voice).tag(speaker.voice) }
                        ForEach(speaker.voices) { v in Text(v.name).tag(v.id) }
                    }
                    Picker("语言", selection: $s.language) {
                        Text("中文").tag("zh")
                        Text("英文（读英文标题）").tag("en")
                        Text("自动").tag("auto")
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("语速"); Spacer(); Text(String(format: "%.2f×", speaker.speed)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $s.speed, in: 0.7...1.5, step: 0.05)
                    }
                    Toggle("先读频道名", isOn: $s.prefixChannel)
                    Picker("队列上限", selection: $s.maxQueue) {
                        ForEach([3, 5, 10, 20], id: \.self) { Text("\($0) 条").tag($0) }
                    }
                    Button("试听") { speaker.test() }.disabled(!speaker.hasKey)
                }

                Section {
                    Toggle("后台保持运行", isOn: $s.keepAlive)
                    Toggle("后台时发通知", isOn: $s.notify)
                } header: { Text("后台") } footer: {
                    Text("iOS 会在切到后台几秒后挂起 App。开启「后台保持运行」后，播报开启时会循环播放静音音频让 App 保持运行，锁屏也能继续接收和播报，但会增加耗电。只适合自己安装使用，上架 App Store 会被拒。")
                }

                Section {
                    LabeledContent("WebSocket（main 实时推送）") { status(client.wsState) }
                    LabeledContent("MCP（每秒轮询全部频道）") { status(client.mcpState) }
                    LabeledContent("网页数据（头像 / 币价 / 配图）") {
                        Text(client.richAvailable ? "可用" : "不可用").foregroundStyle(client.richAvailable ? Color.eqUp : Color.eqMuted)
                    }
                    LabeledContent("WS 发布→收到", value: latency(client.latWS))
                    LabeledContent("MCP 发布→收到", value: latency(client.latMCP))
                    LabeledContent("本次实时收到", value: "\(client.liveCount) 条")
                } header: { Text("连接") } footer: { Text("延迟为本次启动以来的中位数。") }

                ForEach(Channels.groups) { g in
                    Section(g.title) {
                        ForEach(g.keys, id: \.self) { key in
                            Toggle(isOn: Binding(
                                get: { speaker.channels.contains(key) },
                                set: { on in if on { speaker.channels.insert(key) } else { speaker.channels.remove(key) } })) {
                                HStack(spacing: 10) {
                                    ChannelIcon(key: key, size: 22)
                                    Text(Channels.name(key))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if speaker.hasKey && speaker.voices.isEmpty { await speaker.loadVoices() } }
        }
    }

    @ViewBuilder private var readingSection: some View {
        let style = ReadingStyle(font: ReadingFont(rawValue: fontRaw) ?? .sans, scale: scale, dynamicType: dts)
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Typeset.attributed(Typeset.clean("*币安将上线ABC（ABC），开放ABC/USDT交易对，24小时上涨12.5%"),
                                        coins: ["ABC"], base: style.title(16.5, bold: true), bold: style.title(16.5, bold: true)))
                    .foregroundStyle(Color.eqText).lineSpacing(style.lineSpacing(16.5))
                Text(Typeset.attributed(Typeset.clean("充值将于2026年11月19日08:00开放，提现于次日开放。"),
                                        coins: [], base: style.body(15.5), bold: style.body(15.5, bold: true)))
                    .foregroundStyle(Color.eqBody).lineSpacing(style.lineSpacing(15.5))
            }
            .padding(.vertical, 4)
            Picker("字体", selection: $fontRaw) {
                ForEach(ReadingFont.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                Text("字号")
                Spacer()
                Button { scale = max(0.8, (scale - 0.1) * 10 .rounded() / 10) } label: { Text("A−").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(.bordered).disabled(scale <= 0.8)
                Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(width: 52)
                Button { scale = min(1.5, (scale + 0.1) * 10 .rounded() / 10) } label: { Text("A+").font(.system(size: 18, weight: .semibold)) }
                    .buttonStyle(.bordered).disabled(scale >= 1.5)
            }
            Toggle("行情异动类紧凑显示", isOn: $compactData)
            Toggle("显示英文标题", isOn: $showEn)
            Button("清除已读标记") { lastSeen = 0 }.disabled(lastSeen == 0)
        } header: { Text("阅读") } footer: {
            Text("字号同时跟随系统「文字大小」。已读：切到后台时记录位置，下次打开淡化之前看过的快讯。")
        }
    }

    private func status(_ s: ConnState) -> some View {
        HStack(spacing: 5) {
            Circle().fill(s.color).frame(width: 7, height: 7)
            Text(s.text).foregroundStyle(Color.eqMuted)
        }
    }

    private func latency(_ arr: [Double]) -> String {
        guard !arr.isEmpty else { return "—" }
        let med = arr.sorted()[arr.count / 2]
        return String(format: "%.1fs（%d 条）", med, arr.count)
    }

    private func saveKey() async {
        saving = true; defer { saving = false }
        do {
            try await speaker.setKey(keyInput)
            keyOK = true
            keyMsg = keyInput.isEmpty ? "已删除" : "验证通过，已保存"
            keyInput = ""
        } catch {
            keyOK = false
            keyMsg = error.localizedDescription
        }
    }
}
