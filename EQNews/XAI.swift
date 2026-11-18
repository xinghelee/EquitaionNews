import Foundation
import Security

/// xAI API Key 存在 iOS 钥匙串（仅本设备、解锁后可读）
enum Keychain {
    private static let service = "com.xinghelee.eqnews.xai"
    private static let account = "api-key"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

struct XAIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "xAI \(status) \(message)".trimmingCharacters(in: .whitespaces) }
}

struct XAIVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let desc: String
}

enum XAI {
    private static let base = URL(string: "https://api.x.ai/v1")!

    private static func request(_ path: String, key: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: 30)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var msg = ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                msg = (j["error"] as? [String: Any])?["message"] as? String ?? j["error"] as? String ?? j["message"] as? String ?? ""
            }
            throw XAIError(status: status, message: msg)
        }
        return data
    }

    static func voices(key: String) async throws -> [XAIVoice] {
        let data = try await request("tts/voices", key: key)
        let json = try JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]] =
            (json as? [String: Any]).flatMap { ($0["voices"] ?? $0["data"]) as? [[String: Any]] }
            ?? (json as? [[String: Any]]) ?? []
        return list.compactMap { v in
            guard let id = (v["voice_id"] ?? v["id"]) as? String else { return nil }
            return XAIVoice(id: id, name: v["name"] as? String ?? id, desc: v["description"] as? String ?? "")
        }
    }

    /// 合成语音，返回 mp3；429 / 5xx 退避重试两次
    static func tts(text: String, voice: String, language: String, speed: Double, key: String) async throws -> Data {
        let body: [String: Any] = [
            "text": text,
            "voice_id": voice,
            "language": language,
            "speed": min(1.5, max(0.7, speed)),
            "optimize_streaming_latency": 1,
            "output_format": ["codec": "mp3", "sample_rate": 24000, "bit_rate": 64000],
        ]
        var attempt = 0
        while true {
            do {
                return try await request("tts", key: key, body: body)
            } catch let e as XAIError where (e.status == 429 || e.status >= 500) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(800 * (1 << attempt)))
            }
        }
    }
}
