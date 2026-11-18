import SwiftUI

/// 阅读排版：清理来源噪音、中英文 / 数字间距、关键数字着色、字体与字号
@MainActor
enum Typeset {
    // MARK: 清理 + 盘古之白

    /// 拆行、去掉行首 *、空行，补中英文间距
    static func lines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("*") || t.hasPrefix("＊") { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        return pangu(t)
    }

    /// 中文与拉丁字母 / 数字之间加空格（「价值26亿美元」→「价值 26 亿美元」）
    static func pangu(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"(\p{Han})([A-Za-z0-9$@#])"#, with: "$1 $2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([A-Za-z0-9%$)])(\p{Han})"#, with: "$1 $2", options: .regularExpression)
        return t
    }

    // MARK: 高亮

    private static let pct = try! NSRegularExpression(pattern: #"[+\-−]?\d+(?:[.,]\d+)?%"#)

    /// 涨跌幅着色（看符号或前面几个字里的「涨 / 跌」），币种代码加粗
    static func attributed(_ line: String, coins: [String], base: Font, bold: Font) -> AttributedString {
        var a = AttributedString(line)
        a.font = base
        let ns = line as NSString
        for m in pct.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 6), length: min(6, m.range.location)))
            let down = token.hasPrefix("-") || token.hasPrefix("−") || before.contains("跌") || before.lowercased().contains("down")
            let up = token.hasPrefix("+") || before.contains("涨") || before.lowercased().contains("up")
            guard let r = Range(m.range, in: line), let ar = Range(r, in: a) else { continue }
            a[ar].font = bold
            a[ar].foregroundColor = down ? Color.eqDown : up ? Color.eqUp : Color.eqText
        }
        for c in coins where c.count >= 2 {
            var search = a.startIndex..<a.endIndex
            while let r = a[search].range(of: c) {
                // 只匹配完整代码，避免把 BTC 里的 TC 也加粗
                let prev = r.lowerBound > a.startIndex ? a.characters[a.characters.index(before: r.lowerBound)] : " "
                let next = r.upperBound < a.endIndex ? a.characters[r.upperBound] : " "
                if !(prev.isLetter && prev.isASCII) && !(next.isLetter && next.isASCII) {
                    a[r].font = bold
                    a[r].foregroundColor = Color.eqText
                }
                search = r.upperBound..<a.endIndex
            }
        }
        return a
    }
}

// MARK: - 阅读设置

enum ReadingFont: String, CaseIterable, Identifiable {
    case sans, serifTitle, serif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sans: "无衬线（推荐）"
        case .serifTitle: "标题衬线，正文无衬线"
        case .serif: "全部衬线（同网页）"
        }
    }
}

@MainActor
struct ReadingStyle {
    var font: ReadingFont
    var scale: Double            // 用户 A− / A+
    var dynamicType: DynamicTypeSize

    /// 跟随系统字号
    private var systemScale: Double {
        switch dynamicType {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1.0
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        default: 1.45 // 辅助功能字号
        }
    }

    func size(_ base: CGFloat) -> CGFloat { (base * scale * systemScale).rounded() }

    func title(_ base: CGFloat, bold: Bool) -> Font {
        let s = size(base)
        return font == .sans ? .system(size: s, weight: bold ? .semibold : .regular) : SerifFont.font(s, bold: bold)
    }

    func body(_ base: CGFloat, bold: Bool = false) -> Font {
        let s = size(base)
        return font == .serif ? SerifFont.font(s, bold: bold) : .system(size: s, weight: bold ? .semibold : .regular)
    }

    /// 中文行高约 1.65 倍字号
    func lineSpacing(_ base: CGFloat) -> CGFloat { size(base) * 0.5 }

    func mono(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size(base), weight: weight, design: .monospaced)
    }
}
