// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 4 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - LibraryModel.swift
// ======================================================================

// MARK: - ブックマーク・履歴・アドレス欄の候補・文字の大きさ（UI と WebKit に頼らない部分。Linux でテストする）
//
// ・同じページかどうかは LibraryKey.normalize で比べる（#… を外す・スキームとホストを小文字に・末尾の「/」だけの違いを無視）
// ・履歴は URL ごとに 1 つ（最後に見た時刻・見た回数・タイトル）。新しい順。最大 HistoryLog.maxEntries 件
// ・候補は「入れた文字で始まるサイト」を一番上に。ブックマーク・よく見る・最近見たものを上げる

enum LibraryKey {
    /// 比べるための形（保存はしない）
    static func normalize(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.path == "/" && c.query == nil { c.path = "" }
        return c.string ?? s
    }

    /// 履歴・ブックマークに入れてよい URL か（http・https だけ）
    static func isRecordable(_ u: URL) -> Bool {
        let s = u.scheme?.lowercased()
        return (s == "http" || s == "https") && u.host?.isEmpty == false
    }

    /// 候補の照らし合わせ用（スキームと「www.」を外して小文字に）
    static func bare(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        return SiteUtil.stripWWW(t)
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var url: String
    var added: Date
}

struct BookmarkList: Codable, Equatable {
    var items: [Bookmark] = []

    func find(_ url: String) -> Bookmark? {
        let k = LibraryKey.normalize(url)
        return items.first { LibraryKey.normalize($0.url) == k }
    }

    func contains(_ url: String) -> Bool { find(url) != nil }

    /// 足す（同じページが既にあれば足さずに false）
    @discardableResult
    mutating func add(title: String, url: String, now: Date = Date()) -> Bool {
        if contains(url) { return false }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(Bookmark(id: UUID(), title: t.isEmpty ? url : t, url: url, added: now))
        return true
    }

    mutating func remove(id: UUID) { items.removeAll { $0.id == id } }

    mutating func remove(url: String) {
        let k = LibraryKey.normalize(url)
        items.removeAll { LibraryKey.normalize($0.url) == k }
    }

    mutating func rename(id: UUID, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = t
    }

    /// 並べ替え（delta: -1 で 1 つ上、+1 で 1 つ下）
    mutating func move(id: UUID, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + delta))
        if i == j { return }
        let b = items.remove(at: i)
        items.insert(b, at: j)
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
    var id: String { url }
}

struct HistoryLog: Codable, Equatable {
    static let maxEntries = 5000
    /// 新しい順
    var entries: [HistoryEntry] = []

    /// 見たページを記録する（http・https だけ）。記録したら true
    @discardableResult
    mutating func record(url: URL, title: String, at now: Date = Date()) -> Bool {
        guard LibraryKey.isRecordable(url) else { return false }
        let s = url.absoluteString
        let k = LibraryKey.normalize(s)
        var e = HistoryEntry(url: s, title: title, lastVisit: now, visits: 1)
        if let i = entries.firstIndex(where: { LibraryKey.normalize($0.url) == k }) {
            let old = entries.remove(at: i)
            e.visits = old.visits + 1
            if title.isEmpty { e.title = old.title }
        }
        entries.insert(e, at: 0)
        if entries.count > HistoryLog.maxEntries { entries.removeLast(entries.count - HistoryLog.maxEntries) }
        return true
    }

    /// ページのタイトルが後から変わった（読み込みの後に JavaScript が変えるなど）
    mutating func updateTitle(url: URL, title: String) {
        guard !title.isEmpty else { return }
        let k = LibraryKey.normalize(url.absoluteString)
        if let i = entries.firstIndex(where: { LibraryKey.normalize($0.url) == k }), entries[i].title != title {
            entries[i].title = title
        }
    }

    mutating func remove(url: String) {
        let k = LibraryKey.normalize(url)
        entries.removeAll { LibraryKey.normalize($0.url) == k }
    }

    /// since より後に見たものを消す（nil なら全部）
    mutating func clear(since: Date?) {
        guard let since else { entries = []; return }
        entries.removeAll { $0.lastVisit >= since }
    }

    /// 文字で探す（タイトルと URL。新しい順）
    func search(_ q: String, limit: Int = 500) -> [HistoryEntry] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return Array(entries.prefix(limit)) }
        return Array(entries.lazy.filter { $0.title.lowercased().contains(t) || $0.url.lowercased().contains(t) }.prefix(limit))
    }

    /// よく見るサイト（ホストごとに 1 つ。回数の多い順）
    func topSites(limit: Int = 8) -> [HistoryEntry] {
        var best: [String: HistoryEntry] = [:]
        var total: [String: Int] = [:]
        for e in entries {
            guard let h = URL(string: e.url)?.host?.lowercased() else { continue }
            total[h, default: 0] += e.visits
            if let b = best[h], b.visits >= e.visits { continue }
            best[h] = e
        }
        return best.sorted { a, b in
            let ta = total[a.key] ?? 0, tb = total[b.key] ?? 0
            return ta != tb ? ta > tb : a.value.lastVisit > b.value.lastVisit
        }.prefix(limit).map { $0.value }
    }

    /// 日ごとに分ける（見出し・その日の分）。entries は新しい順のまま渡す
    static func groupByDay(_ list: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, entries: [HistoryEntry])] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        var out: [(title: String, entries: [HistoryEntry])] = []
        var lastDay: Date?
        for e in list {
            let day = calendar.startOfDay(for: e.lastVisit)
            if day != lastDay {
                let title: String
                if calendar.isDate(day, inSameDayAs: now) { title = "今日" }
                else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { title = "昨日" }
                else { title = f.string(from: day) }
                out.append((title, []))
                lastDay = day
            }
            out[out.count - 1].entries.append(e)
        }
        return out
    }
}

// MARK: アドレス欄の候補

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable { case bookmark, history }
    let kind: Kind
    let title: String
    let url: String
    var id: String { url }
}

enum Suggestions {
    static func rank(query: String, bookmarks: [Bookmark], history: [HistoryEntry], now: Date = Date(), limit: Int = 8) -> [Suggestion] {
        let q = LibraryKey.bare(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty { return [] }
        var scored: [String: (Int, Suggestion)] = [:]
        func consider(_ s: Suggestion, bonus: Int) {
            let u = LibraryKey.bare(s.url)
            let title = s.title.lowercased()
            var score: Int
            if u.hasPrefix(q) { score = 100 }
            else if title.hasPrefix(q) || title.contains(" " + q) { score = 60 }
            else if u.contains(q) || title.contains(q) { score = 30 }
            else { return }
            score += bonus
            let k = LibraryKey.normalize(s.url)
            if let old = scored[k], old.0 >= score { return }
            scored[k] = (score, s)
        }
        for b in bookmarks { consider(Suggestion(kind: .bookmark, title: b.title, url: b.url), bonus: 25) }
        // 履歴は全部を見ると重いので、新しい 2,000 件まで
        for h in history.prefix(2000) {
            var bonus = min(h.visits, 20) * 2
            let age = now.timeIntervalSince(h.lastVisit)
            if age < 86_400 { bonus += 10 } else if age < 7 * 86_400 { bonus += 5 }
            // 短い URL（サイトの入口）を少し上げる
            if (URL(string: h.url)?.path.count ?? 0) <= 1 { bonus += 8 }
            consider(Suggestion(kind: .history, title: h.title, url: h.url), bonus: bonus)
        }
        return scored.values.sorted { a, b in
            a.0 != b.0 ? a.0 > b.0 : a.1.url.count < b.1.url.count
        }.prefix(limit).map { $0.1 }
    }
}

// MARK: 文字の大きさ（ページの拡大率）

enum PageZoom {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// 今の値から段を delta だけ動かした値（delta が 0 なら 100%）
    static func step(from z: Double, by delta: Int) -> Double {
        if delta == 0 { return 1.0 }
        // 今の値に一番近い段から動かす
        let i = steps.indices.min { abs(steps[$0] - z) < abs(steps[$1] - z) } ?? 3
        return steps[max(0, min(steps.count - 1, i + delta))]
    }

    static func percent(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }
}

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
        guard let h = u.host, !h.isEmpty else { return u.absoluteString }
        return SiteUtil.stripWWW(h)
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

    /// HTTPS-First で https に上げたが開けなかったときのページ（標準の通信・VNet で同じ）。
    /// ボタンは「http のまま開く」（http の URL）→「再試行」（開けなかった URL）の順に、actions で合言葉を作る
    static func httpsFirst(http: URL, failing: URL, message: String, actions: PageActions) -> String {
        html(title: "https では開けませんでした", lines: [
            "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
            "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
            detail: "\(failing.absoluteString)\n\(message)",
            buttons: [Button(label: "http のまま開く", nonce: actions.make("openHTTP", url: http), primary: false),
                      Button(label: "再試行", nonce: actions.make("retry", url: failing), primary: true)],
            kind: "httpsFirst")
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
// MARK: - NetLog.swift
// ======================================================================

// MARK: - 通信の記録（開発者パネルの「通信」。VNet が引き受けた要求 1 つずつ）
//
// 要求ごとに、メソッド・URL・種類・結果（返事の番号・大きさ・かかった時間）と、途中で決めたこと
// （HSTS で https に上げた・リダイレクト・Cookie を保存した・広告ブロックで止めた など）をメモとして持つ。
// 最新 maxRecords 件まで。どのスレッドから書いてもよい

struct NetRecord: Identifiable, Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case pending
        case ok
        case failed(String)
        case blocked(String)
        case cancelled
        case download

        var label: String {
            switch self {
            case .pending: return "…"
            case .ok: return "完了"
            case .failed: return "失敗"
            case .blocked: return "ブロック"
            case .cancelled: return "取り消し"
            case .download: return "ダウンロード"
            }
        }
    }

    let id: Int
    let tab: Int?
    let started: Date
    var method: String
    var url: String
    /// 種類（ページ・画像・スクリプト など。当て推量）
    var kind: String
    var topLevel: Bool
    var status: Int?
    var bytes = 0
    var finished: Date?
    var outcome = Outcome.pending
    var notes: [String] = []

    var durationMs: Int? { finished.map { Int($0.timeIntervalSince(started) * 1000) } }
    var isProblem: Bool {
        switch outcome {
        case .failed, .blocked: return true
        default: return (status ?? 0) >= 400
        }
    }

    /// 1 行の説明
    var line: String {
        let st = status.map(String.init) ?? outcome.label
        let ms = durationMs.map { "\($0)ms" } ?? "…"
        let kb = bytes > 0 ? "・\(bytes / 1024)KB" : ""
        var s = "\(st) \(method) \(kind)\(topLevel ? "（ページ）" : "") \(ms)\(kb) \(url)"
        switch outcome {
        case .failed(let m): s += "  ✕ \(m)"
        case .blocked(let r): s += "  🚫 \(r)"
        default: break
        }
        return s
    }
}

final class NetLog: @unchecked Sendable {
    static let maxRecords = 1000
    private let lock = NSLock()
    private var records: [NetRecord] = []
    private var positions: [Int: Int] = [:]     // id → records の中の位置
    private var nextID = 1

    init() {}

    /// 始まった要求を記録して、番号を返す
    func begin(tab: Int?, method: String, url: String, kind: String, topLevel: Bool, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        records.append(NetRecord(id: id, tab: tab, started: now, method: method, url: url, kind: kind, topLevel: topLevel))
        positions[id] = records.count - 1
        if records.count > NetLog.maxRecords + 100 {
            // まとめて古いものを捨てる（1 件ずつだと位置の付け直しが重い）
            records.removeFirst(records.count - NetLog.maxRecords)
            positions = [:]
            for (i, r) in records.enumerated() { positions[r.id] = i }
        }
        return id
    }

    func update(_ id: Int, _ change: (inout NetRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard id > 0, let i = positions[id], i < records.count, records[i].id == id else { return }
        change(&records[i])
    }

    func note(_ id: Int, _ s: String) {
        update(id) { $0.notes.append(s) }
    }

    /// 終わった（status が分かっていれば入れる）
    func finish(_ id: Int, outcome: NetRecord.Outcome, status: Int? = nil, bytes: Int? = nil, now: Date = Date()) {
        update(id) { r in
            if r.finished != nil && r.outcome != .pending { return }      // 先に終わっていたら変えない
            r.outcome = outcome
            if let status { r.status = status }
            if let bytes { r.bytes = bytes }
            r.finished = now
        }
    }

    /// 新しい順
    func recent(limit: Int = 300, filter: (NetRecord) -> Bool = { _ in true }) -> [NetRecord] {
        lock.lock(); defer { lock.unlock() }
        var out: [NetRecord] = []
        for r in records.reversed() where filter(r) {
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    func clear() {
        lock.lock(); records = []; positions = [:]; lock.unlock()
    }

    func export() -> String {
        recent(limit: NetLog.maxRecords).reversed().map { r in
            ([r.line] + r.notes.map { "    " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

// ======================================================================
// MARK: - FilterLists.swift
// ======================================================================

// MARK: - 広告ブロックのリストの管理（ダウンロード・更新・WebKit のルールへのコンパイル・サイトごとの OFF）
//
// ・リストは Application Support/Vela/filters/<id>.txt に置く。状態（いつ更新したか・ルールの数・コンパイル済みの名前）は adblock.json
// ・ダウンロードは標準の通信（URLSession）で行う（VNet が動いていなくても更新できるように）
// ・起動するたびに、置いてあるリストを裏で読んで、BlockEngine（VNet のタブ用）と WebKit のルール（JSON）を作る。
//   WebKit のルールは中身の印（ハッシュ）を名前に入れてあるので、変わっていなければコンパイルし直さずに取り出せる
// ・自動更新は 4 日ごと（起動したとき）。手で「今すぐ更新」もできる

struct FilterListInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var builtIn: Bool
    var lastUpdated: Date?
    var networkRules = 0
    var cosmeticRules = 0
    var unsupported = 0
    var lastError: String?
    /// コンパイル済みの WebKit のルールの名前
    var netID: String?
    var cosID: String?
}

struct AdBlockState: Codable {
    var lists: [FilterListInfo]
    var lastAutoUpdate: Date?
}

/// VNet の通信から（裏のスレッドで）使う、判定の入れ物
final class BlockEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine = BlockEngine.empty
    private var enabled = true
    private var disabledSites = Set<String>()

    func set(engine e: BlockEngine) { lock.lock(); engine = e; lock.unlock() }
    func set(enabled on: Bool, disabledSites sites: Set<String>) { lock.lock(); enabled = on; disabledSites = sites; lock.unlock() }
    var ruleCount: Int { lock.lock(); defer { lock.unlock() }; return engine.ruleCount }

    /// 止めるなら当たったルール。topHost: タブで開いているページのホスト（サイトごとの OFF の判定）
    func match(url: URL, types: Set<ResourceType>, sourceHost: String?, topHost: String?) -> BlockEngine.Decision? {
        lock.lock()
        let e = engine, on = enabled
        let off = topHost.map { AdBlocker.isDisabled(host: $0, in: disabledSites) } ?? false
        lock.unlock()
        guard on, !off else { return nil }
        return e.match(url: url, types: types, sourceHost: sourceHost)
    }
}

@MainActor
final class AdBlocker: ObservableObject {
    static let catalog: [FilterListInfo] = [
        FilterListInfo(id: "easylist", name: "EasyList（広告）", url: "https://easylist.to/easylist/easylist.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy（トラッカー）", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "adguard-ja", name: "AdGuard Japanese（日本の広告）", url: "https://filters.adtidy.org/extension/ublock/filters/7.txt", enabled: true, builtIn: true),
    ]
    static let updateInterval: TimeInterval = 4 * 86_400
    nonisolated static let idPrefix = "vela-ab-"

    @Published private(set) var lists: [FilterListInfo] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "準備中…"
    @Published private(set) var enabled = true
    @Published private(set) var disabledSites = Set<String>()
    /// 起動してから止めた数（VNet のタブ）
    @Published private(set) var totalBlocked = 0
    let box = BlockEngineBox()
    /// リスト id → WebKit のルール
    private var netLists: [String: WKContentRuleList] = [:]
    private var cosLists: [String: WKContentRuleList] = [:]
    /// ルールが変わったとき（タブに入れ直す）
    var onRuleListsChanged: (@MainActor () -> Void)?
    private let stateFile = JSONFile<AdBlockState>(name: "adblock.json", delay: 0.5)
    private var lastAutoUpdate: Date?
    private var logs: DevLog?
    private var started = false

    nonisolated init() {}

    private func log(_ s: String, level: LogLevel = .info) { logs?.add(s, level: level, category: .block) }

    nonisolated static var folder: URL {
        let dir = JSONFile<AdBlockState>.defaultDirectory().appendingPathComponent("filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static func textURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).txt") }

    nonisolated static func isDisabled(host: String, in sites: Set<String>) -> Bool {
        let h = host.lowercased()
        return sites.contains { SiteUtil.hostMatches(h, domain: $0) }
    }

    // MARK: 始める

    func start(logs: DevLog) {
        if started { return }
        started = true
        self.logs = logs
        stateFile.log = { s in logs.add(s) }
        let d = UserDefaults.standard
        enabled = d.object(forKey: "adblock.enabled") == nil ? true : d.bool(forKey: "adblock.enabled")
        disabledSites = Set(d.stringArray(forKey: "adblock.disabledSites") ?? [])
        box.set(enabled: enabled, disabledSites: disabledSites)
        let saved = stateFile.load()
        lastAutoUpdate = saved?.lastAutoUpdate
        var merged = saved?.lists ?? []
        for c in AdBlocker.catalog where !merged.contains(where: { $0.id == c.id }) { merged.append(c) }
        lists = merged
        let missing = lists.contains { $0.enabled && !FileManager.default.fileExists(atPath: AdBlocker.textURL($0.id).path) }
        let due = lastAutoUpdate.map { Date().timeIntervalSince($0) > AdBlocker.updateInterval } ?? true
        if missing || due {
            Task { await self.update(manual: false) }
        } else {
            Task { await self.rebuild() }
        }
    }

    // MARK: 設定

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "adblock.enabled")
        box.set(enabled: on, disabledSites: disabledSites)
        log(on ? "広告ブロックを使います" : "広告ブロックを止めました")
        onRuleListsChanged?()
    }

    func isActive(for host: String?) -> Bool {
        guard enabled else { return false }
        guard let host else { return true }
        return !AdBlocker.isDisabled(host: host, in: disabledSites)
    }

    /// そのサイトで止める・使う
    func toggleSite(_ host: String) {
        let h = SiteUtil.stripWWW(host.lowercased())
        if AdBlocker.isDisabled(host: h, in: disabledSites) {
            disabledSites = disabledSites.filter { !SiteUtil.hostMatches(h, domain: $0) }
            log("\(h) で広告ブロックを使います")
        } else {
            disabledSites.insert(h)
            log("\(h) では広告ブロックを止めます")
        }
        saveSites()
    }

    func removeDisabledSite(_ h: String) {
        disabledSites.remove(h)
        saveSites()
    }

    private func saveSites() {
        UserDefaults.standard.set(Array(disabledSites).sorted(), forKey: "adblock.disabledSites")
        box.set(enabled: enabled, disabledSites: disabledSites)
        onRuleListsChanged?()
    }

    func setListEnabled(_ id: String, _ on: Bool) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].enabled = on
        saveState()
        if on && !FileManager.default.fileExists(atPath: AdBlocker.textURL(id).path) {
            Task { await self.update(manual: true, only: [id]) }
        } else {
            Task { await self.rebuild() }
        }
    }

    /// 自分で URL を足す
    func addCustom(_ text: String) {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), let s = u.scheme?.lowercased(), s == "https" || s == "http",
              !lists.contains(where: { $0.url == u.absoluteString }) else { return }
        let id = "custom-" + ContentBlockerCompiler.hash(u.absoluteString)
        lists.append(FilterListInfo(id: id, name: u.host ?? u.absoluteString, url: u.absoluteString, enabled: true, builtIn: false))
        saveState()
        Task { await self.update(manual: true, only: [id]) }
    }

    func removeList(_ id: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }), !lists[i].builtIn else { return }
        let l = lists.remove(at: i)
        try? FileManager.default.removeItem(at: AdBlocker.textURL(id))
        for rid in [l.netID, l.cosID].compactMap({ $0 }) { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: rid) { _ in } }
        saveState()
        Task { await self.rebuild() }
    }

    func noteBlocked() { totalBlocked += 1 }

    /// そのタブに入れる WebKit のルール（VNet のタブは隠すルールだけ。通信は BlockEngine が調べる）
    func ruleLists(for mode: NetMode, host: String?) -> [WKContentRuleList] {
        guard isActive(for: host) else { return [] }
        let ids = lists.filter { $0.enabled }.map { $0.id }
        var out = ids.compactMap { cosLists[$0] }
        if !mode.usesVNet { out += ids.compactMap { netLists[$0] } }
        return out
    }

    var ruleCount: Int { box.ruleCount }

    // MARK: 更新

    /// ダウンロードしてから作り直す。only: そのリストだけ
    func update(manual: Bool, only: [String]? = nil) async {
        if busy { return }
        busy = true
        let targets = lists.filter { $0.enabled && (only == nil || only!.contains($0.id)) }
        log("広告ブロックのリストを更新します（\(targets.count) 個\(manual ? "・手で" : "・自動")）")
        for (n, l) in targets.enumerated() {
            status = "ダウンロード中 \(n + 1)/\(targets.count): \(l.name)"
            let result = await AdBlocker.download(l.url)
            guard let i = lists.firstIndex(where: { $0.id == l.id }) else { continue }
            if let text = result.text {
                do {
                    try Data(text.utf8).write(to: AdBlocker.textURL(l.id), options: .atomic)
                    lists[i].lastUpdated = Date()
                    lists[i].lastError = nil
                    log("✓ \(l.name): \(text.utf8.count / 1024)KB")
                } catch {
                    lists[i].lastError = "保存できません: \(error.localizedDescription)"
                }
            } else {
                let message = result.error ?? "不明"
                lists[i].lastError = message
                log("⚠️ \(l.name) をダウンロードできません: \(message)", level: .warning)
            }
        }
        if only == nil { lastAutoUpdate = Date() }
        saveState()
        busy = false
        await rebuild()
    }

    /// ダウンロードの結果（text か error のどちらか）
    struct Downloaded: Sendable { var text: String?; var error: String? }

    nonisolated static func download(_ urlString: String) async -> Downloaded {
        guard let u = URL(string: urlString) else { return Downloaded(error: "URL が正しくありません") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<Downloaded, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error { c.resume(returning: Downloaded(error: error.localizedDescription)); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data, let text = String(data: data, encoding: .utf8) else {
                    c.resume(returning: Downloaded(error: "サーバーの返事が \(status) です")); return
                }
                // HTML（ログインやエラーのページ）などをリストだと思わないように
                let head = text.prefix(2000)
                guard head.contains("!") || head.contains("[Adblock") || head.contains("##") || head.contains("||") else {
                    c.resume(returning: Downloaded(error: "広告ブロックのリストではないようです")); return
                }
                c.resume(returning: Downloaded(text: text))
            }.resume()
        }
    }

    // MARK: 作り直す（BlockEngine と WebKit のルール）

    private struct Built {
        let id: String
        let network: [NetworkRule]
        let netJSON: String
        let cosJSON: String
        let networkCount: Int
        let cosmeticCount: Int
        let unsupported: Int
        let skipped: Int
    }

    /// 置いてあるリストを裏で読んで、BlockEngine を作り、WebKit のルールを（変わったものだけ）コンパイルする
    func rebuild() async {
        busy = true
        status = "リストを読んでいます…"
        let ids = lists.filter { $0.enabled }.map { $0.id }
        let start = Date()
        let built: [Built] = await Task.detached(priority: .utility) {
            ids.compactMap { id -> Built? in
                guard let d = try? Data(contentsOf: AdBlocker.textURL(id)) else { return nil }
                let p = ABPParser.parse(String(decoding: d, as: UTF8.self))
                let net = ContentBlockerCompiler.networkJSON(p.network)
                let cos = ContentBlockerCompiler.cosmeticJSON(p.cosmetic)
                return Built(id: id, network: p.network, netJSON: net.json, cosJSON: cos.json, networkCount: p.network.count,
                             cosmeticCount: p.cosmetic.count, unsupported: p.unsupported, skipped: net.skipped + cos.skipped)
            }
        }.value
        let engine: BlockEngine = await Task.detached(priority: .utility) {
            BlockEngine(rules: built.flatMap { $0.network })
        }.value
        box.set(engine: engine)
        log("広告ブロック: VNet 用のルール \(engine.ruleCount) 個を作りました（\(Int(Date().timeIntervalSince(start) * 1000))ms）")

        var newNet: [String: WKContentRuleList] = [:], newCos: [String: WKContentRuleList] = [:]
        for (n, b) in built.enumerated() {
            status = "WebKit のルールを用意しています \(n + 1)/\(built.count)…"
            guard let i = lists.firstIndex(where: { $0.id == b.id }) else { continue }
            lists[i].networkRules = b.networkCount
            lists[i].cosmeticRules = b.cosmeticCount
            lists[i].unsupported = b.unsupported + b.skipped
            let netID = "\(AdBlocker.idPrefix)\(b.id)-net-\(ContentBlockerCompiler.hash(b.netJSON))"
            let cosID = "\(AdBlocker.idPrefix)\(b.id)-cos-\(ContentBlockerCompiler.hash(b.cosJSON))"
            if let l = await compile(netID, b.netJSON, name: "\(lists[i].name) の通信") { newNet[b.id] = l; lists[i].netID = netID }
            if let l = await compile(cosID, b.cosJSON, name: "\(lists[i].name) の隠すルール") { newCos[b.id] = l; lists[i].cosID = cosID }
        }
        netLists = newNet
        cosLists = newCos
        saveState()
        removeUnusedCompiled()
        busy = false
        status = "ルール \(engine.ruleCount) 個（VNet）・リスト \(built.count) 個"
        onRuleListsChanged?()
    }

    /// 同じ名前のものがあれば取り出し、無ければコンパイルする
    private func compile(_ id: String, _ json: String, name: String) async -> WKContentRuleList? {
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        if let found = await withCheckedContinuation({ (c: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: id) { l, _ in c.resume(returning: l) }
        }) { return found }
        let t0 = Date()
        let (list, error) = await withCheckedContinuation { (c: CheckedContinuation<(WKContentRuleList?, String?), Never>) in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { l, e in
                c.resume(returning: (l, e.map { "\($0)" }))
            }
        }
        if let list {
            log("WebKit のルールをコンパイルしました: \(name)（\(Int(Date().timeIntervalSince(t0) * 1000))ms）")
            return list
        }
        log("⚠️ WebKit のルールをコンパイルできません: \(name)（\(error ?? "不明")）", level: .warning)
        return nil
    }

    /// 使っていない古いコンパイル済みのルールを消す
    private func removeUnusedCompiled() {
        let keep = Set(lists.flatMap { [$0.netID, $0.cosID] }.compactMap { $0 })
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        let lg = logs
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix(AdBlocker.idPrefix) && !keep.contains(id) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
                lg?.add("古い WebKit のルールを消しました: \(id)", level: .debug, category: .block)
            }
        }
    }

    private func saveState() {
        stateFile.save(AdBlockState(lists: lists, lastAutoUpdate: lastAutoUpdate))
    }
}

// ======================================================================
// MARK: - FilterPreparser.swift
// ======================================================================

// MARK: - リストの前処理（!#if / !#else / !#endif と !#include）
//
// uBlock Origin（uBO）1.75.2 の static-filtering-parser.js の preparser（preparserTokens・evaluateExpr・splitter・expandIncludes）を写したもの。
// ・知らない名前の !#if は「判定しない」（中も外も残す）。cap_ で始まる知らない名前だけは偽
// ・env は uBO が持つ値の名前（"ublock"・"mobile" など）。Vela は ext_ublock を真にし、UA に Mobile があれば env_mobile も真（uBO の vapi-common.js と同じ判定）
// ・!#include は、URL の形と「..」を含むものを断り、元のリストと同じ場所（サブフォルダは可）から読む。捨てる枝の中の include は読まない

enum FilterPreparser {
    /// uBO の preparserTokens（!#if の名前 → env の値の名前）
    static let tokens: [String: String] = [
        "ext_ublock": "ublock",
        "ext_ubol": "ubol",
        "ext_devbuild": "devbuild",
        "env_brave": "brave",
        "env_chromium": "chromium",
        "env_edge": "edge",
        "env_firefox": "firefox",
        "env_legacy": "legacy",
        "env_mobile": "mobile",
        "env_mv3": "mv3",
        "env_safari": "safari",
        "cap_html_filtering": "html_filtering",
        "cap_ipaddress": "ipaddress",
        "false": "false",
        "ext_abp": "false",
        "adguard": "adguard",
        "adguard_app_android": "false",
        "adguard_app_cli": "false",
        "adguard_app_ios": "false",
        "adguard_app_mac": "false",
        "adguard_app_windows": "false",
        "adguard_ext_android_cb": "false",
        "adguard_ext_chromium": "chromium",
        "adguard_ext_chromium_mv3": "mv3",
        "adguard_ext_edge": "edge",
        "adguard_ext_firefox": "firefox",
        "adguard_ext_opera": "chromium",
        "adguard_ext_safari": "false",
    ]

    /// Vela の env（uBO の vAPI.webextFlavor.soup のうち、!#if が見るもの）
    static func env(userAgent: String) -> [String] {
        var e = ["ublock"]
        if userAgent.range(of: #"\bMobile\b"#, options: .regularExpression) != nil { e.append("mobile") }
        return e
    }

    /// 1 つの名前（先頭の ! は打ち消し）。知らない名前なら nil
    static func evaluateToken(_ raw: String, _ env: [String]) -> Bool? {
        var token = Substring(raw)
        let not = token.hasPrefix("!")
        if not { token = token.dropFirst() }
        var state = tokens[String(token)]
        if state == nil {
            if !token.hasPrefix("cap_") { return nil }
            state = "false"
        }
        // JS: state === 'false' && not || env.includes(state) !== not
        return (state == "false" && not) || (env.contains(state!) != not)
    }

    /// 式（&& と || は左から順に。括弧は全体を囲むものだけ）。判定できなければ nil
    static func evaluateExpr(_ raw: String, _ env: [String]) -> Bool? {
        var expr = Substring(raw)
        if expr.hasPrefix("(") && expr.hasSuffix(")") && expr.count >= 2 { expr = expr.dropFirst().dropLast() }
        // uBO: /(?:(?:&&|\|\|)\s+)?\S+/g
        let words = expr.split(whereSeparator: { $0.isWhitespace })
        var matches: [(op: Substring?, word: Substring)] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            if (w == "&&" || w == "||") && i + 1 < words.count {
                matches.append((w, words[i + 1])); i += 2
            } else {
                matches.append((nil, w)); i += 1
            }
        }
        guard let first = matches.first else { return nil }
        if first.op != nil || first.word.hasPrefix("|") || first.word.hasPrefix("&") { return nil }
        var result = evaluateToken(String(first.word), env)
        for m in matches.dropFirst() {
            guard let op = m.op else { return nil }       // 「a b」のような並び
            guard let state = evaluateToken(String(m.word), env) else { return nil }
            if op == "||" {
                result = (result == true) ? true : state  // undefined || x → x
            } else {
                result = (result == nil) ? nil : (result! && state)
            }
        }
        return result
    }

    enum Directive { case ifExpr(String), elseBranch, endif }

    /// 「!#if 式」「!#else」「!#endif」の行か（uBO: /^!#(if|else|endif)\b([^\n]*)/）
    static func directive(_ line: Substring) -> Directive? {
        guard line.hasPrefix("!#") else { return nil }
        let rest = line.dropFirst(2)
        func word(_ w: String) -> Substring? {
            guard rest.hasPrefix(w) else { return nil }
            let after = rest.dropFirst(w.count)
            if let c = after.first, c.isLetter || c.isNumber || c == "_" { return nil }
            return after
        }
        if let a = word("endif") { _ = a; return .endif }
        if let a = word("else") { _ = a; return .elseBranch }
        if let a = word("if") { return .ifExpr(a.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// uBO の splitter を行ごとに。残す行なら true を返す閉包を、行を順に渡して使う
    final class Splitter {
        private final class Details { var known: Bool; var discard: Bool; init(_ k: Bool, _ d: Bool) { known = k; discard = d } }
        private var stack: [Details] = []
        private(set) var discarding = false
        let env: [String]
        init(env: [String]) { self.env = env }

        private func shouldDiscard() -> Bool { stack.contains { $0.known && $0.discard } }
        private func begif(_ d: Details) {
            if !discarding && d.known && d.discard { discarding = true }
            stack.append(d)
        }
        private func endif() {
            if !stack.isEmpty { stack.removeLast() }
            if discarding && !shouldDiscard() { discarding = false }
        }

        /// その行を残すか（!#if などの行そのものは、どちらにしても注釈として読み飛ばされる）
        func keep(_ line: Substring) -> Bool {
            switch directive(line) {
            case .ifExpr(let e)?:
                let r = FilterPreparser.evaluateExpr(e, env)
                begif(Details(r != nil, r == false))
                return false
            case .elseBranch?:
                guard let d = stack.last else { return false }
                endif()
                d.discard = !d.discard
                begif(d)
                return false
            case .endif?:
                endif()
                return false
            case nil:
                return !discarding
            }
        }
    }

    /// !#if で捨てる行を除いたもの（行の区切りは \n）
    static func prune(_ text: String, env: [String]) -> String {
        let s = Splitter(env: env)
        var out: [Substring] = []
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).forEach { line in
            if s.keep(line) { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: !#include

    static let maxIncludeDepth = 3
    static let maxTotalBytes = 16 << 20

    /// include の名前から、読みに行く URL（だめなら nil）。uBO: URL の形と「..」は断る。元のリストの最後の / までに付ける
    static func includeURL(_ name: String, base: URL) -> URL? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.contains("..") { return nil }
        if let u = URL(string: n), u.scheme != nil { return nil }
        let b = base.absoluteString
        guard let slash = b.lastIndex(of: "/") else { return nil }
        return URL(string: String(b[...slash]) + n)
    }

    /// 残る枝の中の「!#include 名前」の名前（uBO: /^!#include +(\S+)/）
    static func includeName(_ line: Substring) -> String? {
        guard line.hasPrefix("!#include ") else { return nil }
        let rest = line.dropFirst("!#include".count).drop(while: { $0 == " " })
        let name = rest.prefix(while: { !$0.isWhitespace })
        return name.isEmpty ? nil : String(name)
    }

    struct Expanded {
        var text: String
        var included: [URL] = []
        var failed: [String] = []
    }

    /// include を読んで、その位置に埋め込む。fetch は読めなければ nil。同じ URL は 1 回だけ・深さと合計の大きさに上限
    static func expandIncludes(_ text: String, base: URL, env: [String],
                               fetch: (URL) async -> String?) async -> Expanded {
        var seen: Set<String> = [base.absoluteString]
        var total = text.utf8.count
        var included: [URL] = [], failed: [String] = []
        func expand(_ text: String, base: URL, depth: Int) async -> String {
            let s = Splitter(env: env)
            var out: [String] = []
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let kept = s.keep(line)
                out.append(String(line))
                guard kept, let name = includeName(line) else { continue }
                guard let u = includeURL(name, base: base) else { failed.append("\(name)（読めない名前）"); continue }
                if seen.contains(u.absoluteString) { continue }
                seen.insert(u.absoluteString)
                if depth >= maxIncludeDepth { failed.append("\(name)（深すぎる）"); continue }
                guard let sub = await fetch(u) else { failed.append("\(name)（読めない）"); continue }
                if total + sub.utf8.count > maxTotalBytes { failed.append("\(name)（大きすぎる）"); continue }
                total += sub.utf8.count
                included.append(u)
                let body = await expand(sub, base: u, depth: depth + 1)
                out.append("! >>>>>>>> \(u.absoluteString)")
                out.append(body)
                out.append("! <<<<<<<< \(u.absoluteString)")
            }
            return out.joined(separator: "\n")
        }
        let t = await expand(text, base: base, depth: 0)
        return Expanded(text: t, included: included, failed: failed)
    }

    /// 「! Expires: 8 hours」「! Expires: 4 days (update frequency)」→ 時間（1〜168 に丸める）。無ければ nil
    static func expiresHours(_ text: String) -> Int? {
        for line in text.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true).prefix(60) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.lowercased().hasPrefix("! expires:") else { continue }
            let rest = l.dropFirst("! expires:".count).trimmingCharacters(in: .whitespaces).lowercased()
            let num = rest.prefix(while: { $0.isNumber })
            guard let v = Int(num), v > 0 else { return nil }
            let unit = rest.dropFirst(num.count).trimmingCharacters(in: .whitespaces)
            let hours = unit.hasPrefix("h") ? v : v * 24
            return min(max(hours, 1), 168)
        }
        return nil
    }
}
