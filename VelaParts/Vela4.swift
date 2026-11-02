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
        return sites.contains { h == $0 || h.hasSuffix("." + $0) }
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
        let h = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        if AdBlocker.isDisabled(host: h, in: disabledSites) {
            disabledSites = disabledSites.filter { !(h == $0 || h.hasSuffix("." + $0)) }
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
// MARK: - ABPFilter.swift
// ======================================================================

// MARK: - 広告ブロックのルール（Adblock Plus の書き方）を読む
//
// EasyList・EasyPrivacy・AdGuard Japanese などの 1 行ずつのルールを、通信のルールと、要素を隠すルールに分ける。
// 対応するもの:
//   通信: ||host^ ・ |先頭 ・ 末尾| ・ * ・ ^ ・ @@（例外）と、$ の後の指定
//         （third-party / first-party、script / image / stylesheet / xmlhttprequest / subdocument / font / media /
//          websocket / ping / other / document、domain=、match-case、important、~ の打ち消し）
//   隠す: ##セレクタ（全部のサイト）・a.com,b.com##セレクタ（そのサイト）・#@#（例外）
// 対応しないもの（数えて読み飛ばす）: /正規表現/、$redirect・$csp・$removeparam など、#?#・#$#・#%#（スクリプト・拡張の書き方）、
//   $popup・$elemhide など、:has-text() などの拡張セレクタ

/// 読み込みの種類（ルールの $script などと照らし合わせる）
enum ResourceType: String, CaseIterable, Hashable {
    case document, subdocument, script, image, stylesheet, font, media, xhr, websocket, ping, other
}

struct NetworkRule: Equatable {
    /// 本体（$ の前。|| や | の印は外してある。match-case でなければ小文字）
    var body: String
    var hostAnchor = false      // ||
    var startAnchor = false     // |…
    var endAnchor = false       // …|
    var isException = false     // @@
    var important = false
    var matchCase = false
    /// third-party: true / first-party: false / 指定なし: nil
    var thirdParty: Bool?
    /// 当てはまる種類（nil なら全部）
    var types: Set<ResourceType>?
    /// domain= の、当てはまるサイトと除くサイト
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    /// 元の行（ログ・開発者向け）
    var text: String
}

struct CosmeticRule: Equatable {
    var selector: String
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    var isException = false
}

struct ParsedFilterList {
    var network: [NetworkRule] = []
    var cosmetic: [CosmeticRule] = []
    var lines = 0
    var unsupported = 0
    /// リストの見出しの「! Title:」
    var title: String?
}

enum ABPParser {
    static func parse(_ text: String) -> ParsedFilterList {
        var out = ParsedFilterList()
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            out.lines += 1
            if line.hasPrefix("!") {
                if out.title == nil, line.hasPrefix("! Title:") { out.title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                return
            }
            if line.hasPrefix("[") { return }
            if let r = parseLine(line) {
                switch r {
                case .network(let n): out.network.append(n)
                case .cosmetic(let c): out.cosmetic.append(c)
                }
            } else {
                out.unsupported += 1
            }
        }
        return out
    }

    enum Rule { case network(NetworkRule), cosmetic(CosmeticRule) }

    /// 1 行を読む。対応しない書き方なら nil
    static func parseLine(_ line: String) -> Rule? {
        // 隠すルール（## / #@#）。スクリプトや拡張の書き方（#?# #$# #%# #@?# など）は読まない
        if let r = line.range(of: "#@#") ?? line.range(of: "##") {
            let isException = line[r] == "#@#"
            let domainsPart = String(line[..<r.lowerBound])
            let selector = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if domainsPart.contains("#") || domainsPart.contains("$") || domainsPart.contains("/") { return nil }
            guard isSafeSelector(selector) else { return nil }
            var c = CosmeticRule(selector: selector, isException: isException)
            for d in domainsPart.split(separator: ",") {
                let t = d.trimmingCharacters(in: .whitespaces).lowercased()
                if t.isEmpty { continue }
                if t.hasPrefix("~") { c.excludeDomains.append(String(t.dropFirst())) } else { c.includeDomains.append(t) }
            }
            if c.includeDomains.contains(where: { $0.contains("*") }) || c.excludeDomains.contains(where: { $0.contains("*") }) { return nil }
            return .cosmetic(c)
        }
        if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("$$") || line.contains("#@") { return nil }
        return parseNetwork(line).map { .network($0) }
    }

    /// WebKit の css-display-none に渡しても大丈夫そうなセレクタか（拡張の書き方・壊れたものを入れるとリスト全体がだめになる）
    static func isSafeSelector(_ s: String) -> Bool {
        if s.isEmpty || s.count > 500 { return false }
        if s.hasPrefix("+js") || s.hasPrefix("^") || s.contains("\\") || s.contains("{") || s.contains("}") { return false }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) else { return false }
        // 使ってよい疑似クラスだけ
        if s.contains(":") {
            let allowed = [":not(", ":nth-child(", ":nth-of-type(", ":first-child", ":last-child", ":first-of-type", ":last-of-type",
                           ":only-child", ":empty", ":has(", ":is(", ":where("]
            var rest = s
            for a in allowed { rest = rest.replacingOccurrences(of: a, with: "") }
            // 属性の中の「:」（[href^="http:"] など）は構わない
            var depth = 0
            for ch in rest {
                if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 } else if ch == ":" && depth == 0 { return false }
            }
        }
        // 括弧・角括弧・引用符の数が合っているか（壊れたセレクタを避ける）
        var paren = 0, bracket = 0, dq = 0, sq = 0
        for ch in s {
            switch ch {
            case "(": paren += 1
            case ")": paren -= 1; if paren < 0 { return false }
            case "[": bracket += 1
            case "]": bracket -= 1; if bracket < 0 { return false }
            case "\"": dq += 1
            case "'": sq += 1
            default: break
            }
        }
        return paren == 0 && bracket == 0 && dq % 2 == 0 && sq % 2 == 0
    }

    static func parseNetwork(_ line: String) -> NetworkRule? {
        var s = Substring(line)
        var r = NetworkRule(body: "", text: line)
        if s.hasPrefix("@@") { r.isException = true; s = s.dropFirst(2) }
        // 正規表現のルールは読まない
        if s.hasPrefix("/") && s.count > 2 && (s.hasSuffix("/") || s.contains("/$")) { return nil }
        // $ の後の指定（最後の $ から。本体に $ を含むことはまれ）
        if let dollar = s.lastIndex(of: "$") {
            let opts = s[s.index(after: dollar)...]
            let body = s[..<dollar]
            if !opts.isEmpty, !opts.contains("/") || opts.contains("domain=") {
                guard applyOptions(String(opts), to: &r) else { return nil }
                s = body
            }
        }
        if s.hasPrefix("||") { r.hostAnchor = true; s = s.dropFirst(2) }
        else if s.hasPrefix("|") { r.startAnchor = true; s = s.dropFirst() }
        if s.hasSuffix("|") { r.endAnchor = true; s = s.dropLast() }
        // 先頭・末尾の * は意味が無い
        while s.hasPrefix("*") { s = s.dropFirst(); r.hostAnchor = false; r.startAnchor = false }
        while s.hasSuffix("*") { s = s.dropLast(); r.endAnchor = false }
        if s.isEmpty && r.includeDomains.isEmpty { return nil }      // 全部に当たるルールは危ないので読まない
        if s.contains("|") { return nil }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) else { return nil }
        r.body = r.matchCase ? String(s) : s.lowercased()
        return r
    }

    /// $ の後の指定を読む。対応しない指定があれば false（ルールごと読まない）
    static func applyOptions(_ opts: String, to r: inout NetworkRule) -> Bool {
        var include = Set<ResourceType>(), exclude = Set<ResourceType>()
        for raw in opts.split(separator: ",") {
            var o = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = o.hasPrefix("~")
            if negated { o.removeFirst() }
            let type: ResourceType?
            switch o {
            case "script": type = .script
            case "image": type = .image
            case "stylesheet", "css": type = .stylesheet
            case "xmlhttprequest", "xhr": type = .xhr
            case "subdocument", "frame": type = .subdocument
            case "document", "doc": type = .document
            case "font": type = .font
            case "media": type = .media
            case "websocket": type = .websocket
            case "ping", "beacon": type = .ping
            case "other", "object", "object-subrequest": type = .other
            default: type = nil
            }
            if let type {
                if negated { exclude.insert(type) } else { include.insert(type) }
                continue
            }
            switch o {
            case "third-party", "3p": r.thirdParty = !negated
            case "first-party", "1p": r.thirdParty = negated
            case "match-case": r.matchCase = true
            case "important": r.important = true
            case "all": include.formUnion(ResourceType.allCases)
            case "cname": break
            default:
                if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                    let list = o.drop(while: { $0 != "=" }).dropFirst()
                    for d in list.split(separator: "|") {
                        let t = String(d)
                        if t.contains("*") || t.hasPrefix("/") { return false }
                        if t.hasPrefix("~") { r.excludeDomains.append(String(t.dropFirst())) } else { r.includeDomains.append(t) }
                    }
                } else {
                    // redirect・csp・removeparam・popup・elemhide・badfilter など
                    return false
                }
            }
        }
        if !include.isEmpty { r.types = include.subtracting(exclude) }
        else if !exclude.isEmpty { r.types = Set(ResourceType.allCases).subtracting(exclude).subtracting([.document]) }
        if r.types?.isEmpty == true { return false }
        return true
    }
}

// ======================================================================
// MARK: - BlockEngine.swift
// ======================================================================

// MARK: - 広告ブロックの判定（VNet のタブの通信を 1 つずつ調べる）
//
// ルールが何万もあるので、全部を毎回調べない。ルールごとに「必ず URL に入っている言葉」（英数字の並び）を 1 つ選んで索引にし、
// URL に入っている言葉の索引だけを調べる（言葉を選べないルールは毎回調べる）。
// 当てはめは正規表現を使わず、* と ^ だけの簡単な照らし合わせ（速い）。
// 作った後は変えないので、どのスレッドから使ってもよい

final class BlockEngine: @unchecked Sendable {
    struct Decision: Equatable {
        /// 当たったブロックのルール（元の行）
        let rule: String
    }

    private struct Compiled {
        let rule: NetworkRule
        let body: [UInt8]
    }

    private var blocks: [Compiled] = []
    private var exceptions: [Compiled] = []
    private var important: [Compiled] = []
    /// 言葉 → ルールの番号（種類ごと）
    private var blockIndex: [String: [Int]] = [:]
    private var exceptionIndex: [String: [Int]] = [:]
    private var importantIndex: [String: [Int]] = [:]
    private var blockGeneric: [Int] = []
    private var exceptionGeneric: [Int] = []
    private var importantGeneric: [Int] = []

    private(set) var ruleCount = 0

    init(rules: [NetworkRule] = []) {
        // 言葉は「ルールの中で一番珍しいもの」を選ぶ（"ads" などに何千ものルールが集まると、毎回たくさん調べることになる）
        let candidates = rules.map { BlockEngine.candidateTokens($0) }
        var freq: [String: Int] = [:]
        for c in candidates { for t in c { freq[t, default: 0] += 1 } }
        for (r, c) in zip(rules, candidates) {
            let token = c.min { a, b in
                let fa = freq[a] ?? 0, fb = freq[b] ?? 0
                return fa != fb ? fa < fb : a.count > b.count
            }
            add(r, token: token)
        }
    }

    /// 調べたときの数（開発者向け）: (言葉の種類, 言葉を選べなかったルール)
    var indexStats: (tokens: Int, generic: Int) {
        (blockIndex.count + exceptionIndex.count + importantIndex.count, blockGeneric.count + exceptionGeneric.count + importantGeneric.count)
    }

    static let empty = BlockEngine()

    private func add(_ r: NetworkRule, token: String?) {
        // document だけのルール（ページそのものを止める）は VNet では使わない（ページ本体は止めない）
        if let t = r.types, t == [.document] { return }
        let c = Compiled(rule: r, body: Array(r.body.utf8))
        if r.isException {
            exceptions.append(c)
            BlockEngine.insert(token, exceptions.count - 1, &exceptionIndex, &exceptionGeneric)
        } else if r.important {
            important.append(c)
            BlockEngine.insert(token, important.count - 1, &importantIndex, &importantGeneric)
        } else {
            blocks.append(c)
            BlockEngine.insert(token, blocks.count - 1, &blockIndex, &blockGeneric)
        }
        ruleCount += 1
    }

    private static func insert(_ token: String?, _ i: Int, _ index: inout [String: [Int]], _ generic: inout [Int]) {
        if let token { index[token, default: []].append(i) } else { generic.append(i) }
    }

    /// 言葉として使わないもの（ほとんどの URL に入っている）
    private static let commonTokens: Set<String> = ["http", "https", "www", "com", "net", "org", "html", "js", "jpg", "png", "gif"]

    /// 必ず URL に丸ごと入っている英数字の並びのうち、一番長いもの
    static func bestToken(_ r: NetworkRule) -> String? {
        candidateTokens(r).max { $0.count < $1.count }
    }

    /// 必ず URL に丸ごと入っている英数字の並び（索引に使えるもの）
    static func candidateTokens(_ r: NetworkRule) -> [String] {
        let b = Array(r.body.lowercased().utf8)
        var out: [String] = []
        var i = 0
        while i < b.count {
            guard isAlnum(b[i]) else { i += 1; continue }
            var j = i
            while j < b.count && isAlnum(b[j]) { j += 1 }
            // 前後が「*」や本体の端（印の無い端）だと、URL の中ではもっと長い並びの一部かもしれない
            let leftOK = i > 0 ? b[i - 1] != UInt8(ascii: "*") : (r.hostAnchor || r.startAnchor)
            let rightOK = j < b.count ? b[j] != UInt8(ascii: "*") : r.endAnchor
            if leftOK && rightOK && j - i >= 2 {
                let t = String(decoding: b[i..<j], as: UTF8.self)
                if !commonTokens.contains(t) { out.append(t) }
            }
            i = j
        }
        return out
    }

    @inline(__always) static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    /// 「^」に当たる文字（英数字と _ - . % 以外）
    @inline(__always) static func isSeparator(_ c: UInt8) -> Bool {
        !(isAlnum(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "%"))
    }

    /// 調べる。止めるなら、当たったルール
    /// - types: 読み込みの種類（はっきりしないときは、ありそうなもの全部）
    /// - sourceHost: その読み込みをしたページのホスト（domain= と third-party の判定）
    func match(url: URL, types: Set<ResourceType>, sourceHost: String?) -> Decision? {
        let s = url.absoluteString
        let lower = Array(s.lowercased().utf8)
        let original = Array(s.utf8)
        guard let hostRange = BlockEngine.hostRange(lower) else { return nil }
        let host = String(decoding: lower[hostRange], as: UTF8.self)
        let thirdParty: Bool? = sourceHost.map { SiteUtil.registrableDomain($0.lowercased()) != SiteUtil.registrableDomain(host) }
        let tokens = BlockEngine.tokens(lower)
        let req = Request(lower: lower, original: original, host: hostRange, types: types,
                          source: sourceHost?.lowercased(), thirdParty: thirdParty)
        if let i = find(important, importantIndex, importantGeneric, tokens, req) { return Decision(rule: important[i].rule.text) }
        guard let i = find(blocks, blockIndex, blockGeneric, tokens, req) else { return nil }
        if find(exceptions, exceptionIndex, exceptionGeneric, tokens, req) != nil { return nil }
        return Decision(rule: blocks[i].rule.text)
    }

    private struct Request {
        let lower: [UInt8]
        let original: [UInt8]
        let host: Range<Int>
        let types: Set<ResourceType>
        let source: String?
        let thirdParty: Bool?
    }

    private func find(_ list: [Compiled], _ index: [String: [Int]], _ generic: [Int], _ tokens: [String], _ req: Request) -> Int? {
        for t in tokens {
            if let ids = index[t] { for i in ids where BlockEngine.matches(list[i], req) { return i } }
        }
        for i in generic where BlockEngine.matches(list[i], req) { return i }
        return nil
    }

    private static func matches(_ c: Compiled, _ req: Request) -> Bool {
        let r = c.rule
        if let t = r.types, t.isDisjoint(with: req.types) { return false }
        if let tp = r.thirdParty {
            guard let actual = req.thirdParty, actual == tp else { return false }
        }
        if !r.includeDomains.isEmpty || !r.excludeDomains.isEmpty {
            guard let src = req.source else { return false }
            if r.excludeDomains.contains(where: { domainMatches(src, $0) }) { return false }
            if !r.includeDomains.isEmpty && !r.includeDomains.contains(where: { domainMatches(src, $0) }) { return false }
        }
        if c.body.isEmpty { return true }
        return patternMatches(c.body, in: r.matchCase ? req.original : req.lower, host: req.host,
                              hostAnchor: r.hostAnchor, startAnchor: r.startAnchor, endAnchor: r.endAnchor)
    }

    static func domainMatches(_ host: String, _ d: String) -> Bool {
        host == d || host.hasSuffix("." + d)
    }

    /// URL のホストの位置（"scheme://" の後から、/ ? # : の前まで）
    static func hostRange(_ u: [UInt8]) -> Range<Int>? {
        var i = 0
        while i + 2 < u.count, !(u[i] == UInt8(ascii: ":") && u[i + 1] == UInt8(ascii: "/") && u[i + 2] == UInt8(ascii: "/")) { i += 1 }
        guard i + 2 < u.count else { return nil }
        let start = i + 3
        var end = start
        while end < u.count, ![UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: ":")].contains(u[end]) { end += 1 }
        return start < end ? start..<end : nil
    }

    static func tokens(_ u: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < u.count {
            guard isAlnum(u[i]) else { i += 1; continue }
            var j = i
            while j < u.count && isAlnum(u[j]) { j += 1 }
            if j - i >= 2 { out.append(String(decoding: u[i..<j], as: UTF8.self)) }
            i = j
        }
        return out
    }

    /// * と ^ の入った本体を、URL に当てはめる
    static func patternMatches(_ p: [UInt8], in u: [UInt8], host: Range<Int>, hostAnchor: Bool, startAnchor: Bool, endAnchor: Bool) -> Bool {
        // 「*」で区切る
        var segments: [ArraySlice<UInt8>] = []
        var s = 0
        for (i, c) in p.enumerated() where c == UInt8(ascii: "*") {
            if i > s { segments.append(p[s..<i]) }
            s = i + 1
        }
        if s < p.count { segments.append(p[s..<p.count]) }
        if segments.isEmpty { return true }

        func matchAt(_ seg: ArraySlice<UInt8>, _ pos: Int) -> Int? {
            var k = pos
            for c in seg {
                if c == UInt8(ascii: "^") {
                    if k == u.count { continue }       // 終わりにも当たる
                    if !isSeparator(u[k]) { return nil }
                } else {
                    if k >= u.count || u[k] != c { return nil }
                }
                k += 1
            }
            return min(k, u.count)
        }
        func search(_ seg: ArraySlice<UInt8>, from: Int) -> (Int, Int)? {
            var i = from
            while i <= u.count {
                if let e = matchAt(seg, i) { return (i, e) }
                i += 1
            }
            return nil
        }
        func rest(_ from: Int, _ idx: Int) -> Bool {
            var pos = from
            for k in idx..<segments.count {
                if k == segments.count - 1 && endAnchor {
                    // 最後の区切りは URL の終わりで終わらなければならない
                    var i = pos
                    while i <= u.count {
                        if let e = matchAt(segments[k], i), e == u.count { return true }
                        i += 1
                    }
                    return false
                }
                guard let (_, e) = search(segments[k], from: pos) else { return false }
                pos = e
            }
            return true
        }

        var starts: [Int] = []
        if hostAnchor {
            // ホストの始め、またはホストの中の「.」の後
            starts.append(host.lowerBound)
            for i in host where u[i] == UInt8(ascii: ".") { starts.append(i + 1) }
        } else if startAnchor {
            starts.append(0)
        } else {
            if segments.count == 1 && !endAnchor { return search(segments[0], from: 0) != nil }
            // 最初の区切りが当たる所を順に試す
            var i = 0
            while let (st, e) = search(segments[0], from: i) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
                i = st + 1
            }
            return false
        }
        for st in starts {
            if let e = matchAt(segments[0], st) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
            }
        }
        return false
    }

    /// VNet が受けた要求の種類を当てる（WebKit は種類を教えてくれないので、Accept と拡張子から）
    static func guessTypes(url: URL, accept: String?, isTopLevel: Bool) -> Set<ResourceType> {
        if isTopLevel { return [.document] }
        let a = (accept ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        if a.hasPrefix("text/html") || a.hasPrefix("application/xhtml") { return [.subdocument] }
        if a.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp"].contains(ext) { return [.image] }
        if a.hasPrefix("text/css") || ext == "css" { return [.stylesheet] }
        if ["woff", "woff2", "ttf", "otf", "eot"].contains(ext) || a.hasPrefix("font/") { return [.font] }
        if ["mp4", "webm", "m3u8", "ts", "mp3", "m4a", "aac", "ogg", "mov"].contains(ext) || a.hasPrefix("video/") || a.hasPrefix("audio/") { return [.media] }
        if ext == "js" || ext == "mjs" { return [.script] }
        // 分からない: スクリプトか、fetch / XHR か、その他
        return [.script, .xhr, .other, .ping]
    }
}
