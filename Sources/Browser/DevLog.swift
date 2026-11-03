import Foundation

// MARK: - 開発者向けのログ（どのスレッドからでも書ける）
//
// 1 行ずつ「時刻・重さ・種類・タブ・本文」を持って、最新 maxEntries 件まで覚える（古いものから消す）。
// 今までの log?("…") の文字列も、そのまま add で入れられる（先頭の記号から種類と重さを決める）。
// 画面へは、必要なときに entries(after:) で差分だけ取り出す（毎回全部を作り直すと重い）

enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug, info, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var mark: String {
        switch self { case .debug: return "·"; case .info: return " "; case .warning: return "⚠"; case .error: return "✕" }
    }
}

enum LogCategory: String, Sendable, CaseIterable {
    case app = "アプリ"
    case vnet = "VNet"
    case net = "通信"
    case nav = "移動"
    case cookie = "Cookie"
    case security = "守り"
    case block = "ブロック"
    case download = "ダウンロード"
    case js = "JS"
}

struct LogEntry: Sendable, Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let category: LogCategory
    /// どのタブのものか（タブに関係ないものは nil）
    let tab: Int?
    let message: String

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var line: String {
        "\(LogEntry.timeFormat.string(from: time)) \(level.mark) [\(category.rawValue)\(tab.map { "#\($0)" } ?? "")] \(message)"
    }
}

/// 開発者パネルの日時（端末の時刻で「2026-11-03 14:05」）。Cookie や HSTS の期限など、日付も要るもの用
enum DevDate {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func dateTime(_ d: Date, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        formatter.timeZone = timeZone
        return formatter.string(from: d)
    }
}

final class DevLog: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var start = 0           // ring の中で一番古いものの位置（いっぱいになってから使う）
    private var nextID = 1
    private var dirty = false
    /// ログを書いた回数（重さごと。開発者パネル用。clear で 0 に戻す）
    private var counts: [LogLevel: Int] = [:]

    init() {}

    /// 今までの文字列のログ。先頭の記号などから種類と重さを決める
    func add(_ message: String, tab: Int? = nil) {
        let (level, category) = DevLog.classify(message)
        add(message, level: level, category: category, tab: tab)
    }

    func add(_ message: String, level: LogLevel, category: LogCategory, tab: Int? = nil) {
        lock.lock()
        let e = LogEntry(id: nextID, time: Date(), level: level, category: category, tab: tab, message: message)
        nextID += 1
        if ring.count < DevLog.maxEntries {
            ring.append(e)
        } else {
            ring[start] = e
            start = (start + 1) % DevLog.maxEntries
        }
        counts[level, default: 0] += 1
        dirty = true
        lock.unlock()
        // 落ちたときのために、すぐファイルにも書く（CrashLog.start の前は何もしない）
        CrashLog.writeLine(e.line)
    }

    /// 古い順に全部
    func all() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[start...] + ring[..<start])
    }

    /// id より新しいもの（古い順）。画面は最後に見た id を覚えておいて、差分だけもらう
    func entries(after id: Int) -> [LogEntry] {
        all().filter { $0.id > id }
    }

    func count(_ level: LogLevel) -> Int { lock.lock(); defer { lock.unlock() }; return counts[level] ?? 0 }

    /// 変わっていれば、最新 lines 行を 1 つの文字列にして返す（今の簡易のログ表示用）
    func take(lines: Int = 200) -> String? {
        lock.lock()
        if !dirty { lock.unlock(); return nil }
        dirty = false
        lock.unlock()
        return all().suffix(lines).map { $0.message }.joined(separator: "\n")
    }

    /// 書き出し用（共有・コピー）
    func export(minLevel: LogLevel = .debug) -> String {
        all().filter { $0.level >= minLevel }.map { $0.line }.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); ring = []; start = 0; counts = [:]; dirty = true; lock.unlock()
    }

    /// 文字列から種類と重さを決める（今までのログの書き方に合わせる）
    static func classify(_ m: String) -> (LogLevel, LogCategory) {
        let level: LogLevel = m.hasPrefix("✕") || m.contains("失敗") ? .error
            : m.hasPrefix("⚠") ? .warning : .info
        let category: LogCategory
        if m.hasPrefix("🍪") { category = .cookie }
        else if m.hasPrefix("🚫") { category = .block }
        else if m.hasPrefix("🛡") || m.hasPrefix("🔒") || m.contains("HSTS") || m.contains("横取り") { category = .security }
        else if m.hasPrefix("✓") || m.hasPrefix("✕") || m.hasPrefix("↪") || m.hasPrefix("――") { category = .net }
        else if m.hasPrefix("→") || m.hasPrefix("←") || m.contains("TLS") || m.contains("DHCP") || m.contains("カード")
                    || m.contains("[ネット]") || m.contains("TCP") { category = .vnet }
        else { category = .app }
        return (level, category)
    }
}

/// 開発者パネルのログ・通信のページの絞り込み（「このタブだけ」と「探す」）。Cookie のページは決まりが違うので使わない
struct DevQuery {
    let onlyThisTab: Bool
    /// 小文字にした「探す」の文字
    private let q: String

    init(onlyThisTab: Bool, query: String) {
        self.onlyThisTab = onlyThisTab
        q = query.lowercased()
    }

    /// 調べるときに選ばれているタブ（「このタブだけ」でなければ nil = 全部のタブ）
    func tab(selected: Int?) -> Int? { onlyThisTab ? selected : nil }

    /// 「探す」が空か、text（小文字にして）に含まれるか
    func matches(_ text: String) -> Bool { q.isEmpty || text.lowercased().contains(q) }
}
