// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 4 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - AddressInput.swift
// ======================================================================

// MARK: - アドレス欄に入れた文字を、開く URL にする（URL か検索語かを決める）
//
// ・「://」がある・about: で始まる → そのまま URL
// ・空白がある → 検索
// ・ホスト名らしい（example.com・192.168.0.1・localhost・[::1]・ポートやパス付きも） → URL
//   LAN のアドレス（数字の LAN・localhost・.local）は http://、それ以外は https://
// ・それ以外 → 検索

enum SearchEngine: String, CaseIterable, Codable, Sendable {
    case google, duckDuckGo, bing, yahooJapan

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yahooJapan: return "Yahoo! JAPAN"
        }
    }

    func searchURL(_ query: String) -> URL? {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .duckDuckGo: c = URLComponents(string: "https://duckduckgo.com/")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yahooJapan: c = URLComponents(string: "https://search.yahoo.co.jp/search")!; c.queryItems = [URLQueryItem(name: "p", value: query)]
        }
        // URLComponents は「+」をそのまま残すので、検索語の「+」を %2B にする（空白と区別するため）
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }
}

enum AddressInput {
    enum Resolved: Equatable {
        case url(URL)
        case search(String, URL)
    }

    /// 入れた文字を開く URL にする。空なら nil
    static func resolve(_ raw: String, engine: SearchEngine) -> Resolved? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") { return URL(string: lower).map { .url($0) } }
        if text.contains("://"), let u = URL(string: text), u.scheme != nil, u.host != nil || lower.hasPrefix("file:") {
            return .url(u)
        }
        if text.rangeOfCharacter(from: .whitespaces) == nil, let u = hostLikeURL(text) { return .url(u) }
        return engine.searchURL(text).map { .search(text, $0) }
    }

    /// ホスト名らしいものなら URL にする
    static func hostLikeURL(_ text: String) -> URL? {
        // ホストの部分（最初の / ? # まで）
        let hostEnd = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        var hostPort = String(text[..<hostEnd])
        let rest = String(text[hostEnd...])
        if hostPort.isEmpty { return nil }
        var host = hostPort
        // ポート（[v6]:8080 と host:8080）
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if !after.isEmpty && !(after.hasPrefix(":") && after.dropFirst().allSatisfy({ $0.isNumber }) && after.count > 1) { return nil }
            guard IPAddressText.v6(host) != nil else { return nil }
        } else if let colon = hostPort.lastIndex(of: ":") {
            let port = hostPort[hostPort.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(port), p > 0, p < 65536 else { return nil }
            host = String(hostPort[..<colon])
        }
        host = host.lowercased()
        hostPort = hostPort.lowercased()
        let local: Bool
        if hostPort.hasPrefix("[") {
            local = LocalNetworkPolicy.classify(host: host)?.isLocal ?? false
        } else if IPAddressText.v4(host) != nil {
            local = LocalNetworkPolicy.classify(host: host)?.isLocal ?? false
        } else if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            local = true
        } else {
            guard looksLikeDomain(host) else { return nil }
            local = false
        }
        return URL(string: (local ? "http://" : "https://") + hostPort + rest)
    }

    /// ドメイン名らしいか（点で区切った各部分が英数字とハイフン、最後は英字 2 文字以上か xn--）
    static func looksLikeDomain(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard !l.isEmpty, l.count <= 63, !l.hasPrefix("-"), !l.hasSuffix("-"),
                  l.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        let tld = labels.last!
        return tld.hasPrefix("xn--") || (tld.count >= 2 && tld.allSatisfy { $0.isLetter })
    }

    /// アドレス欄を触っていないときに見せる短い形（ホスト名。www. は外す）
    static func shortDisplay(_ url: URL?) -> String {
        guard let u = url else { return "" }
        if u.scheme == "about" { return "" }
        guard var h = u.host, !h.isEmpty else { return u.absoluteString }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// 検索の結果のページなら、その検索語（アドレス欄に戻すため）
    static func searchTerms(in url: URL?) -> String? {
        guard let u = url, let c = URLComponents(url: u, resolvingAgainstBaseURL: false), let host = u.host?.lowercased() else { return nil }
        let key: String
        if host.hasSuffix("google.com") && u.path == "/search" { key = "q" }
        else if host == "duckduckgo.com" { key = "q" }
        else if host.hasSuffix("bing.com") && u.path == "/search" { key = "q" }
        else if host == "search.yahoo.co.jp" { key = "p" }
        else { return nil }
        return c.queryItems?.first(where: { $0.name == key })?.value
    }
}

// ======================================================================
// MARK: - ErrorPages.swift
// ======================================================================

// MARK: - エラーページ・確認のページ
//
// ・読めなかったときに、原因の説明と、できること（再試行・標準の通信で開く など）のボタンを出す
// ・ボタンは window.webkit.messageHandlers.velaAction に {action: "page", nonce} を送る。
//   合言葉（nonce）は 1 回だけ・10 分まで使える。ページは失敗した URL のオリジンで出すので、元のページからは合言葉を読めない
//   （LAN の確認のように、押されると困るボタンもあるため。合言葉の無い知らせは受け付けない）

/// ページのボタンの合言葉 → してほしいこと（画面のスレッドでだけ使う）
final class PageActions {
    struct Item {
        let action: String
        let url: URL
        let at: Date
    }
    private var items: [String: Item] = [:]
    static let lifetime: TimeInterval = 600

    init() {}

    /// 合言葉を作る
    func make(_ action: String, url: URL, now: Date = Date()) -> String {
        items = items.filter { now.timeIntervalSince($0.value.at) < PageActions.lifetime }
        let n = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        items[n] = Item(action: action, url: url, at: now)
        return n
    }

    /// 合言葉を確かめて、してほしいことを返す（1 回だけ）
    func consume(_ nonce: String, now: Date = Date()) -> Item? {
        guard let i = items.removeValue(forKey: nonce), now.timeIntervalSince(i.at) < PageActions.lifetime else { return nil }
        return i
    }
}

enum ErrorPage {
    /// ページの中のボタン（label・合言葉）
    struct Button {
        let label: String
        let nonce: String
        let primary: Bool
    }

    /// 説明（見出し・ひとこと・標準の通信で開く案内を出すか）
    struct Description {
        let title: String
        let hint: String
        let offerNative: Bool
    }

    static func describe(_ e: FetchError) -> Description {
        switch e.kind {
        case .dns: return Description(title: "サーバーが見つかりません", hint: "アドレスが正しいか、ネットワークにつながっているかを確かめてください。", offerNative: true)
        case .timeout: return Description(title: "時間切れです", hint: "サーバーから返事がありません。しばらくしてから試してください。", offerNative: true)
        case .tls: return Description(title: "安全な接続を作れませんでした", hint: "証明書に問題があるか、VNet の TLS では話せない相手です。", offerNative: true)
        case .tlsVersion: return Description(title: "このサイトは VNet の TLS では開けません", hint: "相手が TLS 1.3 だけを使っています（VNet の TLS は 1.2 まで）。標準の通信なら開けます。", offerNative: true)
        case .connect: return Description(title: "サーバーにつながりません", hint: "サーバーが止まっているか、ネットワークに問題があります。", offerNative: true)
        case .reset: return Description(title: "接続が途中で切れました", hint: "もう一度試してください。", offerNative: true)
        case .malformed, .tooLarge: return Description(title: "サーバーの返事を読めません", hint: e.description, offerNative: true)
        case .redirect: return Description(title: "リダイレクトが多すぎます", hint: "サーバーの設定に問題があるかもしれません。", offerNative: false)
        case .busy: return Description(title: "要求が多すぎます", hint: "少し待ってから試してください。", offerNative: false)
        case .blocked: return Description(title: "Vela の守りで止めました", hint: e.description, offerNative: false)
        case .localNetworkConsent: return Description(title: "LAN の機器を開きますか？", hint: e.description, offerNative: false)
        case .notReady: return Description(title: "VNet の準備ができていません", hint: "少し待ってから試してください。", offerNative: true)
        case .cancelled: return Description(title: "取り消しました", hint: "", offerNative: false)
        case .other: return Description(title: "読めませんでした", hint: e.description, offerNative: true)
        }
    }

    /// 標準の通信（WebKit）の失敗の説明（NSURLErrorDomain の番号）
    static func describe(nsErrorCode code: Int, domain: String, message: String) -> Description {
        guard domain == NSURLErrorDomain else { return Description(title: "読めませんでした", hint: message, offerNative: false) }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return Description(title: "インターネットにつながっていません", hint: "Wi-Fi やモバイル通信を確かめてください。", offerNative: false)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return Description(title: "サーバーが見つかりません", hint: "アドレスが正しいかを確かめてください。", offerNative: false)
        case NSURLErrorTimedOut:
            return Description(title: "時間切れです", hint: "サーバーから返事がありません。", offerNative: false)
        case NSURLErrorCannotConnectToHost:
            return Description(title: "サーバーにつながりません", hint: message, offerNative: false)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return Description(title: "安全な接続を作れませんでした", hint: "証明書に問題があります。このサイトは開かないでください。", offerNative: false)
        default:
            return Description(title: "読めませんでした", hint: message, offerNative: false)
        }
    }

    /// エラーページの HTML（文字は全部エスケープする。暗い表示にも合わせる）
    static func html(title: String, lines: [String], detail: String? = nil, buttons: [Button], kind: String) -> String {
        var s = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(escape(title))</title><style>
        body{font:17px -apple-system,system-ui;margin:0;padding:48px 24px;color:#1c1c1e;background:#f2f2f7}
        @media (prefers-color-scheme:dark){body{color:#f2f2f7;background:#1c1c1e}.d{background:#2c2c2e}}
        main{max-width:620px;margin:0 auto}h1{font-size:24px;margin:0 0 16px}p{line-height:1.5;word-break:break-all}
        .u{color:#8e8e93;font-size:14px}.d{background:#e5e5ea;border-radius:8px;padding:8px 12px;font:12px ui-monospace,monospace;white-space:pre-wrap}
        button{font-size:16px;padding:10px 20px;margin:8px 8px 0 0;border-radius:10px;border:0;background:#d1d1d6;color:inherit}
        button.p{background:#0a84ff;color:#fff}
        </style></head><body><main>
        """
        s += "<h1>\(escape(title))</h1>"
        for l in lines where !l.isEmpty { s += "<p>\(escape(l))</p>" }
        if !buttons.isEmpty {
            s += "<div>"
            for b in buttons {
                let js = "window.webkit.messageHandlers.velaAction.postMessage({action:'page',nonce:'\(b.nonce)'})"
                s += "<button class=\"\(b.primary ? "p" : "")\" onclick=\"\(escape(js))\">\(escape(b.label))</button>"
            }
            s += "</div>"
        }
        if let d = detail, !d.isEmpty { s += "<details><summary class=\"u\">くわしく</summary><p class=\"d\">\(escape(d))</p></details>" }
        s += "</main></body></html><!-- vela-error:\(escape(kind)) -->"
        return s
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }
}

// ======================================================================
// MARK: - Persistence.swift
// ======================================================================

// MARK: - データのファイル（Application Support/Vela/ の JSON）
//
// タブ・ブックマーク・履歴などを Codable の JSON で置く。書き込みはまとめて（delay 秒後に 1 回）、裏のキューで、
// いったん別の名前に書いてから置き換える（.atomic。書いている途中で落ちても前のものが残る）

final class JSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    /// 読み書きの失敗（開発者向けのログに出す）
    var log: (@Sendable (String) -> Void)?

    /// name: ファイルの名前（例: "tabs.json"）。directory を省くと Application Support/Vela/
    init(name: String, directory: URL? = nil, delay: TimeInterval = 1.0) {
        let dir = directory ?? JSONFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.delay = delay
        queue = DispatchQueue(label: "vela-json-\(name)")
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
    }

    /// 読む（無い・壊れているなら nil。壊れていたファイルは .broken に名前を変えて残す）
    func load() -> Value? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: d)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を読めません（\(error)）。.broken として残します")
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return nil
        }
    }

    /// 保存する（delay 秒の間に何度呼んでも、書くのは最後の 1 回）
    func save(_ v: Value) {
        lock.lock()
        pending = v
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// 待っている分をすぐ書く（アプリが裏に回るときなど）。書き終わるまで待つ
    func saveNow(_ v: Value? = nil) {
        if let v { lock.lock(); pending = v; lock.unlock() }
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let v = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let v else { return }
        do {
            let d = try JSONEncoder().encode(v)
            try d.write(to: url, options: .atomic)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を書けません（\(error)）")
        }
    }
}

// MARK: - 設定（UserDefaults に置く）
//
// 通信まわりの設定は、アプリを起動し直したときに効く（WebView や通信の作りを、起動のときに決めるため）

enum VelaSettings {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: 通信（VNet）

    /// VNet を使わず、標準の通信（WebKit 内蔵）だけで読む
    static var vnetDisabled: Bool {
        get { bool("vnet.disabled", false) } set { d.set(newValue, forKey: "vnet.disabled") }
    }
    /// 確かめていない iOS の版でも、https の横取り（非公開 API）を試す
    static var allowUntestedOS: Bool {
        get { bool("vnet.allowUntestedOS", false) } set { d.set(newValue, forKey: "vnet.allowUntestedOS") }
    }
    /// 開発者向け: 横取りできないとき、標準の通信ではなく予備の vnets:// の作りを使う（安全ではない。CSP などを外すため）
    static var legacyVNetsFallback: Bool {
        get { bool("vnet.legacyVNets", false) } set { d.set(newValue, forKey: "vnet.legacyVNets") }
    }

    // MARK: 使い勝手

    /// 検索エンジン
    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "search.engine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "search.engine") }
    }
    /// HTTPS-First: ページを開く http:// を、まず https で試す（だめなら「http のまま開く」を出す）
    static var httpsFirst: Bool {
        get { bool("nav.httpsFirst", true) } set { d.set(newValue, forKey: "nav.httpsFirst") }
    }
    /// VNet でページを読めなかったら（TLS・つながらない など）、標準の通信に自動で切り替える
    static var autoFallbackToNative: Bool {
        get { bool("vnet.autoFallback", false) } set { d.set(newValue, forKey: "vnet.autoFallback") }
    }
    /// Mac の Safari の Web インスペクタからつなげるようにする（iOS 16.4 から）
    static var webInspector: Bool {
        get { bool("dev.webInspector", false) } set { d.set(newValue, forKey: "dev.webInspector") }
    }

    /// サイト（ホスト）ごとの文字の大きさ（100% のものは持たない）
    static func zoom(for host: String?) -> Double {
        guard let h = host?.lowercased(), let z = (d.dictionary(forKey: "zoom.sites") as? [String: Double])?[h] else { return 1.0 }
        return z
    }
    static func setZoom(_ z: Double, for host: String?) {
        guard let h = host?.lowercased(), !h.isEmpty else { return }
        var m = (d.dictionary(forKey: "zoom.sites") as? [String: Double]) ?? [:]
        m[h] = abs(z - 1.0) < 0.001 ? nil : z
        if m.count > 500 { m = [h: z] }      // 増えすぎたら覚え直す（めったに起きない）
        d.set(m, forKey: "zoom.sites")
    }

    // MARK: プライバシー・守り

    /// サードパーティ Cookie をブロックする
    static var blockThirdPartyCookies: Bool {
        get { bool("cookies.blockThirdParty", true) } set { d.set(newValue, forKey: "cookies.blockThirdParty") }
    }
    /// SameSite が無い Cookie を Lax として扱う
    static var cookiesLaxByDefault: Bool {
        get { bool("cookies.laxByDefault", true) } set { d.set(newValue, forKey: "cookies.laxByDefault") }
    }
    /// LAN の保護（公開のサイトから LAN の機器へ届かせない）
    static var localNetworkProtection: Bool {
        get { bool("lan.protection", true) } set { d.set(newValue, forKey: "lan.protection") }
    }

    /// 今の設定から作る Cookie の決まり
    static var cookiePolicy: CookiePolicy.Settings {
        var s = CookiePolicy.Settings()
        s.blockThirdParty = blockThirdPartyCookies
        s.laxByDefault = cookiesLaxByDefault
        return s
    }
}

// ======================================================================
// MARK: - DevLog.swift
// ======================================================================

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

final class DevLog: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var start = 0           // ring の中で一番古いものの位置（いっぱいになってから使う）
    private var nextID = 1
    private var dirty = false
    /// ログを書いた回数（重さごと。開発者パネル用）
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
        lock.lock(); ring = []; start = 0; dirty = true; lock.unlock()
    }

    /// 文字列から種類と重さを決める（今までのログの書き方に合わせる）
    static func classify(_ m: String) -> (LogLevel, LogCategory) {
        let level: LogLevel = m.hasPrefix("✕") || m.contains("失敗") ? .error
            : m.hasPrefix("⚠") ? .warning : .info
        let category: LogCategory
        if m.hasPrefix("🍪") { category = .cookie }
        else if m.hasPrefix("🛡") || m.hasPrefix("🔒") || m.contains("HSTS") || m.contains("横取り") { category = .security }
        else if m.hasPrefix("✓") || m.hasPrefix("✕") || m.hasPrefix("↪") || m.hasPrefix("――") { category = .net }
        else if m.hasPrefix("→") || m.hasPrefix("←") || m.contains("TLS") || m.contains("DHCP") || m.contains("カード")
                    || m.contains("[ネット]") || m.contains("TCP") { category = .vnet }
        else { category = .app }
        return (level, category)
    }
}

// ======================================================================
// MARK: - CrashLog.swift
// ======================================================================

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 落ちたときの記録（次に起動したときに、開発者パネルで見る）
//
// ・ログを 1 行ずつ、すぐファイルに書く（落ちる直前まで残るように。メモリのログは落ちると消える）
// ・Objective-C の例外（WebKit などが投げる）は、名前・理由・呼び出しの順をファイルに書く
// ・致命的なシグナル（Swift の強制終了・不正なメモリアクセスなど）は、番号・落ちたスレッド・呼び出しの順を書く
//   （シグナルの中ではほとんど何もできないので、用意しておいた文字と backtrace_symbols_fd で、ファイルに直接書くだけ）
// ・起動するたびに、前回の記録を crash-previous.txt に移す。前回が落ちて終わっていたら、ログに知らせる

/// シグナルの中から使うので、ファイルの番号は global に置く（Swift の static は初めて触るときに準備が走るので、シグナルの中では使わない）
private var crashFD: Int32 = -1
private let signalMessages: [Int32: [UInt8]] = {
    var m: [Int32: [UInt8]] = [:]
    for (s, name) in [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")] {
        m[s] = Array("\n【シグナル】\(name)（\(s)）でアプリが止まりました\n".utf8)
    }
    return m
}()
/// 呼び出しの順を入れる場所（シグナルの中では作れないので、先に用意する）
private let backtraceCapacity: Int32 = 64
private let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private let mainThreadText = Array("落ちたスレッド: 画面のスレッド（main）\n呼び出しの順:\n".utf8)
private let otherThreadText = Array("落ちたスレッド: 裏のスレッド（main 以外）\n呼び出しの順:\n".utf8)

// backtrace・backtrace_symbols_fd（C の execinfo.h）。iPad の Swift Playgrounds では Darwin から見えなかった
// （「cannot find 'backtrace' in scope」）ので、C の関数の名前で直接つなぐ。iOS・Linux の libc のどちらにもある
@_silgen_name("backtrace")
private func cBacktrace(_ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd")
private func cBacktraceSymbolsFD(_ buffer: UnsafePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)

/// 致命的なシグナルの受け口。シグナルの中なので、用意しておいたものを write で書くだけにする
private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        if let m = signalMessages[sig] { _ = m.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) } }
        #if canImport(Darwin)
        let isMain = pthread_main_np() != 0
        #else
        let isMain = false
        #endif
        let t = isMain ? mainThreadText : otherThreadText
        _ = t.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        let n = cBacktrace(backtraceBuffer, backtraceCapacity)
        cBacktraceSymbolsFD(backtraceBuffer, n, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashLog {
    private static let lock = NSLock()
    private static var written = 0
    static let maxBytes = 2 << 20
    static let exceptionMark = "【例外】"
    static let signalMark = "【シグナル】"

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var currentURL: URL { folder.appendingPathComponent("crash-current.txt") }
    static var previousURL: URL { folder.appendingPathComponent("crash-previous.txt") }

    /// 起動したときに 1 回。前回の記録を移して、新しいファイルを開き、例外とシグナルの受け口を入れる
    static func start() {
        lock.lock(); defer { lock.unlock() }
        if crashFD >= 0 { return }
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        if fm.fileExists(atPath: currentURL.path) { try? fm.moveItem(at: currentURL, to: previousURL) }
        crashFD = open(currentURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = (signalMessages, mainThreadText, otherThreadText, backtraceBuffer)     // シグナルの中で準備が走らないよう、先に作っておく
        #if canImport(Darwin)
        NSSetUncaughtExceptionHandler { e in CrashLog.recordException(e) }
        #endif
        _ = cBacktrace(backtraceBuffer, 1)     // 初めて呼ぶときの準備を、シグナルの中ではなくここで済ませておく
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(s, crashSignalHandler)
        }
        // ここはもう lock を持っているので、writeLine ではなく writeLineLocked（NSLock は 2 回取ると止まる）
        writeLineLocked("―― 起動 \(Date()) ――")
    }

    /// 1 行書く（DevLog から全部の行が来る）
    static func writeLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        writeLineLocked(s)
    }

    /// lock を持っているときに呼ぶ
    private static func writeLineLocked(_ s: String) {
        guard crashFD >= 0 else { return }
        let bytes = Array((s + "\n").utf8)
        if written + bytes.count > maxBytes {
            // 大きくなりすぎたら最初から（落ちる直前の分があればよい）
            _ = ftruncate(crashFD, 0)
            _ = lseek(crashFD, 0, SEEK_SET)
            written = 0
        }
        _ = bytes.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        written += bytes.count
    }

    #if canImport(Darwin)
    static func recordException(_ e: NSException) {
        var s = "\n\(exceptionMark)\(e.name.rawValue): \(e.reason ?? "（理由なし）")\n"
        s += e.callStackSymbols.prefix(40).joined(separator: "\n")
        writeLine(s)
    }
    #endif

    /// 前回の記録（最後の lines 行）。無ければ nil
    static func previous(lines: Int = 300) -> String? {
        guard let d = try? Data(contentsOf: previousURL), !d.isEmpty else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// 前回は落ちて終わったか（例外かシグナルの記録がある）。あれば、その行
    static func previousCrashSummary() -> String? {
        guard let p = previous(lines: 2000) else { return nil }
        let lines = p.split(separator: "\n")
        return lines.last { $0.contains(exceptionMark) || $0.contains(signalMark) }.map(String.init)
    }
}
