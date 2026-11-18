import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// 远程推送：App 关闭 / 锁屏也能收到。需要
/// 1) 推送中转服务（relay/）已部署；2) App 签名带 aps-environment 能力（通配描述文件不支持，需要显式 App ID）。
@MainActor @Observable
final class PushManager {
    static let shared = PushManager()

    var relayURL: String = UserDefaults.standard.string(forKey: "push.relay") ?? "" {
        didSet { UserDefaults.standard.set(relayURL, forKey: "push.relay") }
    }
    var secret: String = UserDefaults.standard.string(forKey: "push.secret") ?? "" {
        didSet { UserDefaults.standard.set(secret, forKey: "push.secret") }
    }
    var enabled: Bool = UserDefaults.standard.bool(forKey: "push.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "push.enabled"); if enabled { start() } else { unregister() } }
    }

    private(set) var token: String?
    private(set) var status = "未开启"
    private(set) var lastSync: Date?

    /// 通知点开后要打开的快讯链接
    var pendingOpen: URL?

    @ObservationIgnored var rules: () -> [[String: String]] = { [] }

    #if DEBUG
    private let apnsEnv = "sandbox"
    #else
    private let apnsEnv = "production"
    #endif

    func start() {
        guard enabled else { return }
        status = "请求权限…"
        Task {
            let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard ok else { status = "通知权限被拒绝"; return }
            status = "注册中…"
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        Task { await sync() }
    }

    func didFail(_ error: Error) {
        let msg = error.localizedDescription
        status = msg.contains("aps-environment") ? "这个签名没有推送能力（需要显式 App ID，见 relay/README）" : "注册失败：\(msg)"
    }

    /// 把 token + 自选规则同步给中转服务
    func sync() async {
        guard enabled, let token, let base = URL(string: relayURL), !relayURL.isEmpty else {
            if enabled, token != nil { status = "已获取推送令牌，请填写中转服务地址" }
            return
        }
        var req = URLRequest(url: base.appending(path: "register"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty { req.setValue(secret, forHTTPHeaderField: "x-relay-secret") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "env": apnsEnv, "rules": rules()])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { status = "已连接中转服务"; lastSync = Date() } else { status = "中转服务返回 \(code)" }
        } catch {
            status = "连不上中转服务：\(error.localizedDescription)"
        }
    }

    private func unregister() {
        status = "未开启"
        guard let token, let base = URL(string: relayURL), !relayURL.isEmpty else { return }
        var req = URLRequest(url: base.appending(path: "register"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty { req.setValue(secret, forHTTPHeaderField: "x-relay-secret") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFail(error) }
    }

    /// 前台时也显示横幅（本地通知 / 远程推送）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// 点开通知 → 打开对应快讯详情
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let s = response.notification.request.content.userInfo["url"] as? String
        completionHandler()
        Task { @MainActor in
            if let s, let u = URL(string: s) { PushManager.shared.pendingOpen = u }
        }
    }
}

struct PushSettingsView: View {
    @Environment(Watchlist.self) private var watchlist
    @State private var push = PushManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("开启远程推送", isOn: $push.enabled)
                LabeledContent("状态", value: push.status)
                if let t = push.token {
                    LabeledContent("设备令牌", value: String(t.prefix(12)) + "…")
                }
                if let d = push.lastSync {
                    LabeledContent("上次同步", value: d.formatted(Fmt.hms))
                }
            } footer: {
                Text("按「自选与提醒」规则推送：「播报」等级为时效性通知，「通知」为普通通知。App 完全关闭也能收到。")
            }
            Section {
                TextField("https://relay.example.com", text: $push.relayURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("共享密钥（可选）", text: $push.secret)
                Button("立即同步规则") { Task { await push.sync() } }
                    .disabled(push.token == nil || push.relayURL.isEmpty)
            } header: { Text("中转服务") } footer: {
                Text("中转服务代码在项目的 relay/ 目录，部署方法见 relay/README.md。")
            }
        }
        .navigationTitle("远程推送")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { push.rules = { [watchlist] in watchlist.payloadRules } }
    }
}
