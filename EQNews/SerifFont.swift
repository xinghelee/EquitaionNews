import CoreText
import Observation
import SwiftUI
import UIKit

/// eqn.news 正文用衬线字体。iOS 自带宋体（STSongti）但默认不装，首次启动向系统按需下载，之后系统缓存。
@MainActor @Observable
final class SerifFont {
    static let shared = SerifFont()
    static let regular = "STSongti-SC-Regular"
    static let bold = "STSongti-SC-Bold"

    private(set) var ready = UIFont(name: SerifFont.bold, size: 12) != nil

    func load() {
        guard !ready else { return }
        Self.download([Self.regular, Self.bold])
    }

    /// CoreText 在后台线程回调，所以这里必须 nonisolated，回到主线程再改状态
    private nonisolated static func download(_ names: [String]) {
        let descs = names.map { CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary) }
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descs as CFArray, nil) { @Sendable state, _ in
            if state == .didFinish {
                Task { @MainActor in SerifFont.shared.ready = UIFont(name: SerifFont.bold, size: 12) != nil }
            }
            return true
        }
    }

    /// 字体未就绪时退回系统字体（PingFang）
    static func font(_ size: CGFloat, bold: Bool) -> Font {
        shared.ready ? .custom(bold ? Self.bold : Self.regular, size: size) : .system(size: size, weight: bold ? .semibold : .regular)
    }
}
