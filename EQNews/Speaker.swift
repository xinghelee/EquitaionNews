import AVFoundation
import Foundation
import Observation
import UserNotifications

/// xAI 语音播报队列：一次播一条，预取下一条，超出上限丢最旧的
@MainActor @Observable
final class Speaker {
    // MARK: 设置（持久化到 UserDefaults）
    var enabled: Bool { didSet { save("enabled", enabled); onEnabledChanged() } }
    var voice: String { didSet { save("voice", voice) } }
    var language: String { didSet { save("language", language) } }
    var speed: Double { didSet { save("speed", speed) } }
    var prefixChannel: Bool { didSet { save("prefix", prefixChannel) } }
    var maxQueue: Int { didSet { save("maxQueue", maxQueue) } }
    var channels: Set<String> { didSet { save("channels", Array(channels)) } }
    /// 后台保持运行：循环播放静音音频，让 App 在锁屏 / 切后台时继续接收和播报
    var keepAlive: Bool { didSet { save("keepAlive", keepAlive); updateKeepAlive() } }
    var notify: Bool { didSet { save("notify", notify); if notify { requestNotify() } } }

    // MARK: 状态
    private(set) var nowPlaying: String?
    private(set) var nowPlayingID: String?
    private(set) var queueCount = 0
    private(set) var lastError: String?
    private(set) var hasKey = Keychain.read() != nil
    private(set) var voices: [XAIVoice] = []

    /// 超过这个延迟的消息不播（例如 App 从挂起恢复后补到的旧消息）
    private let staleAfter: TimeInterval = 180

    private final class Job {
        let item: NewsItem
        let text: String
        var audio: Task<Data, Error>?
        init(item: NewsItem, text: String) { self.item = item; self.text = text }
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var playing: Job?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playDone: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let delegate = PlayerDelegate()
    @ObservationIgnored private var silent: AVAudioPlayer?
    @ObservationIgnored private var appActive = true

    private static let d = UserDefaults.standard
    private func save(_ k: String, _ v: Any) { Self.d.set(v, forKey: "tts." + k) }

    init() {
        let d = Self.d
        enabled = d.bool(forKey: "tts.enabled")
        voice = d.string(forKey: "tts.voice") ?? "eve"
        language = d.string(forKey: "tts.language") ?? "zh"
        speed = d.object(forKey: "tts.speed") as? Double ?? 1.1
        prefixChannel = d.object(forKey: "tts.prefix") as? Bool ?? true
        maxQueue = d.object(forKey: "tts.maxQueue") as? Int ?? 5
        channels = Set(d.stringArray(forKey: "tts.channels") ?? Channels.all.map(\.key))
        keepAlive = d.bool(forKey: "tts.keepAlive")
        notify = d.bool(forKey: "tts.notify")
        delegate.onDone = { [weak self] in Task { @MainActor in self?.finishPlayback() } }
        configureSession(duck: false)
        updateKeepAlive()
    }

    // MARK: - Key

    func setKey(_ key: String) async throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            Keychain.delete(); hasKey = false; voices = []
            return
        }
        let list = try await XAI.voices(key: k) // 先验证再保存
        Keychain.save(k)
        hasKey = true
        voices = list
        if !list.isEmpty, !list.contains(where: { $0.id == voice }) { voice = list[0].id }
    }

    func loadVoices() async {
        guard let k = Keychain.read() else { return }
        if let list = try? await XAI.voices(key: k), !list.isEmpty { voices = list }
    }

    // MARK: - 队列

    func setAppActive(_ active: Bool) { appActive = active }

    /// level：自选规则命中的等级；rulesActive=false 时（没有任何自选规则）沿用频道设置
    func handleNew(_ item: NewsItem, level: Watchlist.Level?, rulesActive: Bool) {
        if let lat = item.latency, lat > staleAfter { return }
        let speak: Bool, alert: Bool
        if rulesActive {
            speak = level == .loud
            alert = level == .loud || level == .notify
        } else {
            let match = item.channels.contains { channels.contains($0) }
            speak = match
            alert = match
        }
        if notify, !appActive, alert { postNotification(item, loud: level == .loud) }
        if enabled, speak { enqueue(item) }
    }

    /// 朗读任意文本（要点等），插到队首
    func speakText(_ raw: String, id: String) {
        let text = raw.replacingOccurrences(of: #"[•·\-]\s*"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "。")
        let item = NewsItem(id: id, via: .mcp, no: nil, kind: nil, title: text, titleEn: nil, source: "", sourceSlug: nil,
                            coins: [], url: nil, sourceURL: nil, images: [], channels: [], publishedAt: Date(), receivedAt: Date())
        enqueue(item, manual: true, text: String(text.prefix(1500)))
    }

    func enqueue(_ item: NewsItem, manual: Bool = false, text override: String? = nil) {
        let text = override ?? speechText(item)
        guard !text.isEmpty else { return }
        let job = Job(item: item, text: text)
        if manual { queue.insert(job, at: 0) } else { queue.append(job) }
        while queue.count > maxQueue {
            if manual { queue.removeLast() } else { queue.removeFirst() }
        }
        prefetch()
        if manual, playing != nil { skip() } else { next() }
        queueCount = queue.count
    }

    func skip() {
        player?.stop()
        finishPlayback()
    }

    func clear() {
        queue.forEach { $0.audio?.cancel() }
        queue.removeAll()
        queueCount = 0
        lastError = nil
        skip()
    }

    func test() {
        let sample = NewsItem(
            id: "test-\(Date().timeIntervalSince1970)", via: .mcp, no: nil, kind: nil,
            title: "这是一条测试播报。比特币价格突破十万美元。", titleEn: "This is a test broadcast.",
            source: "EQN", sourceSlug: nil, coins: [], url: nil, sourceURL: nil, images: [],
            channels: ["main"], publishedAt: Date(), receivedAt: Date())
        enqueue(sample, manual: true)
    }

    private func prefetch() {
        guard let key = Keychain.read() else { return }
        for job in queue.prefix(2) where job.audio == nil {
            let (text, voice, lang, speed) = (job.text, voice, language, speed)
            job.audio = Task { try await XAI.tts(text: text, voice: voice, language: lang, speed: speed, key: key) }
        }
    }

    private func next() {
        guard playing == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        playing = job
        queueCount = queue.count
        nowPlaying = job.text
        nowPlayingID = job.item.id
        prefetch()
        Task { await play(job) }
    }

    private func play(_ job: Job) async {
        do {
            guard Keychain.read() != nil else { throw XAIError(status: 0, message: "未设置 xAI API Key") }
            if job.audio == nil { prefetch() }
            let data = try await job.audio!.value
            guard playing === job else { return }
            configureSession(duck: true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = delegate
            player = p
            lastError = nil
            await withCheckedContinuation { cont in
                playDone = cont
                if !p.play() { finishPlayback() }
            }
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
            if (error as? XAIError).map({ $0.status == 0 || $0.status == 400 || $0.status == 401 || $0.status == 403 }) == true {
                queue.removeAll(); queueCount = 0
            }
            if playing === job { finishPlayback() }
        }
    }

    private func finishPlayback() {
        playDone?.resume()
        playDone = nil
        player = nil
        playing = nil
        nowPlaying = nil
        nowPlayingID = nil
        if queue.isEmpty { configureSession(duck: false) }
        next()
    }

    // MARK: - 文本

    func speechText(_ n: NewsItem) -> String {
        let raw = language == "en" ? (n.titleEn ?? n.title) : n.title
        var t = String(raw.split(separator: "\n").first ?? "")
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\p{Extended_Pictographic}|\x{FE0F}|\x{200D}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\[\]【】*#_`<>]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.count > 300 { t = String(t.prefix(300)) + "…" }
        if prefixChannel, language != "en", !t.isEmpty {
            t = "\(Channels.name(n.channels.first ?? n.source))。\(t)"
        }
        return t
    }

    // MARK: - 音频会话 / 后台保活

    private func configureSession(duck: Bool) {
        let s = AVAudioSession.sharedInstance()
        // 播报时压低其他 App 音量；空闲时（保活静音）与其他音频混音，不打断音乐
        try? s.setCategory(.playback, mode: .spokenAudio, options: duck ? [.duckOthers] : [.mixWithOthers])
        try? s.setActive(true)
    }

    private func onEnabledChanged() {
        if !enabled { clear() }
        updateKeepAlive()
    }

    private func updateKeepAlive() {
        if keepAlive && enabled {
            guard silent == nil, let p = try? AVAudioPlayer(data: Self.silentWAV) else { return }
            p.numberOfLoops = -1
            p.volume = 0
            configureSession(duck: false)
            p.play()
            silent = p
        } else {
            silent?.stop()
            silent = nil
        }
    }

    /// 1 秒 8kHz 单声道静音 WAV
    private static let silentWAV: Data = {
        let samples = 8000, bytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        d.append(Data(count: bytes))
        return d
    }()

    // MARK: - 通知

    private func requestNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(_ n: NewsItem, loud: Bool) {
        let c = UNMutableNotificationContent()
        c.title = "\(Channels.name(n.channels.first ?? "")) · \(n.source)"
        c.body = Typeset.lines(n.title).first ?? n.headline
        c.threadIdentifier = n.channels.first ?? "eqn"
        c.relevanceScore = loud ? 1 : 0.5
        if loud || !enabled { c.sound = .default }
        if let u = n.url { c.userInfo = ["url": u.absoluteString] }
        let req = UNNotificationRequest(identifier: n.id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onDone: (@Sendable () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onDone?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onDone?() }
}
