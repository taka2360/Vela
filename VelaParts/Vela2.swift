// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 2 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

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
// MARK: - DownloadFiles.swift
// ======================================================================

// MARK: - ダウンロードのファイル（UI・WebKit に頼らない部分。Linux でテストする）
//
// ・VNet のタブのダウンロードは、WebKit の WKDownload を使わずに VNet が自分でファイルに書く
//   （VNetScheme が引き受けた読み込みを WebKit がダウンロードに変えると、iPad でアプリが落ちたため）
// ・ここには、ダウンロードにするかの判定・ファイル名の決め方・ファイルに書く部品（VNetDownload）を置く

enum DownloadFiles {
    /// 保存先（Documents/Downloads）
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 同じ名前があれば「名前 (2).拡張子」にする
    static func uniqueURL(for name: String, in dir: URL = folder) -> URL {
        let safe = sanitize(name)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var url = dir.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// ファイル名に使えない文字を外す（パスの区切り・制御文字・先頭の「.」）
    static func sanitize(_ raw: String) -> String {
        var s = String(raw.unicodeScalars.map { c -> Character in
            if c.value < 0x20 || c.value == 0x7F || "/\\:".unicodeScalars.contains(c) { return "_" }
            return Character(c)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            s = String(s.prefix(200 - ext.count - 1)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s.isEmpty ? "download" : s
    }

    /// ページとして表示できる種類か（できないものはダウンロードにする）
    static func isDisplayable(mime raw: String) -> Bool {
        let m = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if m.isEmpty { return true }                         // 種類が無い: WebKit に任せる（中身から判断する）
        for p in ["text/", "image/", "video/", "audio/", "multipart/"] where m.hasPrefix(p) { return true }
        let shown: Set<String> = ["application/xhtml+xml", "application/xml", "application/json", "application/javascript",
                                  "application/x-javascript", "application/ecmascript", "application/pdf", "application/rss+xml",
                                  "application/atom+xml", "application/ld+json", "application/manifest+json",
                                  "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/dash+xml"]
        return shown.contains(m)
    }

    /// この返事をダウンロードにするか（ページ本体の返事のときに使う）
    static func isDownload(status: Int, headers: [(String, String)]) -> Bool {
        guard (200...299).contains(status), status != 204 else { return false }
        if let cd = headers.value(for: "Content-Disposition"), cd.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            return true
        }
        guard let ct = headers.value(for: "Content-Type") else { return false }
        return !isDisplayable(mime: ct)
    }

    /// ファイル名を決める（Content-Disposition の filename* → filename → URL の最後 → "download"。拡張子が無ければ種類から足す）
    static func filename(contentDisposition: String?, url: URL?, mime: String?) -> String {
        var name: String?
        if let cd = contentDisposition {
            let params = parseParams(cd)
            if let star = params["filename*"], let v = decodeRFC5987(star), !v.isEmpty { name = v }
            else if let plain = params["filename"], !plain.isEmpty { name = plain }
        }
        if name == nil, let u = url {
            let last = u.lastPathComponent
            if !last.isEmpty && last != "/" { name = last.removingPercentEncoding ?? last }
        }
        var n = sanitize(name.map { ($0 as NSString).lastPathComponent } ?? "download")
        if (n as NSString).pathExtension.isEmpty, let ext = mime.flatMap(extensionFor) { n += "." + ext }
        return n
    }

    static func extensionFor(mime raw: String) -> String? {
        let m = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let map = ["application/pdf": "pdf", "application/zip": "zip", "application/json": "json", "text/plain": "txt",
                   "text/csv": "csv", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "video/mp4": "mp4",
                   "audio/mpeg": "mp3", "application/gzip": "gz", "application/x-tar": "tar", "application/epub+zip": "epub"]
        return map[m]
    }

    /// 「attachment; filename="a.zip"; filename*=UTF-8''a.zip」を名前 → 値にする（名前は小文字）
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        // 最初の「;」まで（attachment など）は飛ばす
        guard let semi = s.firstIndex(of: ";") else { return out }
        i = s.index(after: semi)
        while i < s.endIndex {
            while i < s.endIndex && (s[i] == " " || s[i] == ";") { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: eq)
            var value = ""
            if i < s.endIndex && s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex && s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i])
                    i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let end = s[i...].firstIndex(of: ";") ?? s.endIndex
                value = s[i..<end].trimmingCharacters(in: .whitespaces)
                i = end
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// RFC 5987: 「UTF-8''%E3%81%82.zip」を戻す（UTF-8 と ISO-8859-1 だけ）
    static func decodeRFC5987(_ v: String) -> String? {
        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        let encoded = String(parts[2])
        if charset == "utf-8" { return encoded.removingPercentEncoding }
        if charset == "iso-8859-1" {
            var bytes: [UInt8] = []
            var it = encoded.utf8.makeIterator()
            while let c = it.next() {
                if c == UInt8(ascii: "%"), let h = it.next(), let l = it.next(), let v = UInt8(String(bytes: [h, l], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(v)
                } else {
                    bytes.append(c)
                }
            }
            return String(bytes: bytes, encoding: .isoLatin1)
        }
        return nil
    }
}

/// VNet が自分でファイルに書くダウンロード 1 つ（どのスレッドからでも使える）
final class VNetDownload: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case running, finished, cancelled
        case failed(String)
    }

    let source: URL
    let fileURL: URL
    let expected: Int64
    /// 取り消すとき（VNet の要求を止める）。始めた側が入れる
    var cancelAction: (@Sendable () -> Void)?
    /// 進み具合・状態が変わったとき（間引いて呼ぶ。どのスレッドから呼ばれるかは決まっていない）
    var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "vela-download")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _received: Int64 = 0
    private var _state = State.running
    private var lastNotify = Date.distantPast

    /// ファイルを作る。作れなければ nil
    init?(source: URL, suggestedName: String, expected: Int64, in dir: URL = DownloadFiles.folder) {
        self.source = source
        self.expected = expected
        fileURL = DownloadFiles.uniqueURL(for: suggestedName, in: dir)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle = h
    }

    var received: Int64 { lock.lock(); defer { lock.unlock() }; return _received }
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    func write(_ d: Data) {
        queue.async {
            guard let h = self.handle, self.state == .running else { return }
            h.write(d)
            self.lock.lock()
            self._received += Int64(d.count)
            let now = Date()
            let notify = now.timeIntervalSince(self.lastNotify) > 0.3
            if notify { self.lastNotify = now }
            self.lock.unlock()
            if notify { self.onChange?() }
        }
    }

    /// 最後まで届いた
    func finish() { end(.finished, removeFile: false) }

    /// 失敗した（途中までのファイルは消す）
    func fail(_ why: String) { end(.failed(why), removeFile: true) }

    /// ユーザーが取り消した
    func cancel() {
        cancelAction?()
        end(.cancelled, removeFile: true)
    }

    /// 書き終わるまで待つ（テスト用）
    func waitUntilIdle() { queue.sync {} }

    private func end(_ s: State, removeFile: Bool) {
        queue.async {
            self.lock.lock()
            if self._state != .running { self.lock.unlock(); return }
            self._state = s
            self.lock.unlock()
            try? self.handle?.close()
            self.handle = nil
            if removeFile { try? FileManager.default.removeItem(at: self.fileURL) }
            self.onChange?()
        }
    }
}

// ======================================================================
// MARK: - BrowserStore.swift
// ======================================================================

// MARK: - アプリ全体（タブ・共有の部品・保存）
//
// ・タブ 1 枚 = BrowserTab（WKWebView は必要なときだけ作る。動いている WebView は maxLiveWebViews 枚まで）
// ・通信（VNetMachine）・Cookie の写し・HSTS・ログ・LAN の保護のルールは、全部のタブで 1 つを共有する
// ・タブの並び（と各タブの戻る/進むの履歴）を session.json に保存して、次に起動したときに戻す
// ・メモリが足りなくなったら（メモリ警告）、見ていないタブの WebView を捨てる（スナップショットと履歴は残す）

/// 通信の作り（タブごと）
enum NetMode: String, Codable {
    /// https・http をそのまま VNetScheme が引き受ける（アドレスは本物の https://…）
    case vnetDirect = "VNet"
    /// 予備の vnets://… の作り（開発者向けの実験。CSP などを外すので安全ではない）
    case vnetsLegacy = "VNet（vnets://・実験）"
    /// 標準の通信（WebKit 内蔵）
    case native = "標準"

    var usesVNet: Bool { self != .native }
    var short: String {
        switch self { case .vnetDirect: return "VNet"; case .vnetsLegacy: return "vnets"; case .native: return "標準" }
    }
}

/// ページの JavaScript からのダイアログ（alert・confirm・prompt）
struct JSDialog: Identifiable {
    enum Kind { case alert, confirm, prompt(String) }
    let id = UUID()
    let kind: Kind
    let message: String
    let origin: String
    /// (OK か, prompt の入力)
    let respond: (Bool, String?) -> Void
}

/// 保存するタブ
struct SavedTab: Codable {
    var id: Int
    var url: String?
    var title: String
    var mode: NetMode
    /// WebKit の戻る/進むの履歴（WKWebView.interactionState）
    var state: Data?
}

struct SessionData: Codable {
    var tabs: [SavedTab]
    var selected: Int?
}

@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: Int?
    @Published var showTabOverview = false
    @Published var showDevPanel = false
    /// いま出しているダイアログ（順番待ちは dialogQueue）
    @Published private(set) var dialog: JSDialog?
    @Published var dialogInput = ""
    /// VNet の様子（ツールバー・開発者パネル用）
    @Published private(set) var vnetReady = false
    @Published private(set) var vnetStatus = "準備中…"
    /// 開発者パネルのログ（パネルを開いている間だけ更新する）
    @Published private(set) var logText = ""
    @Published var showDownloads = false
    /// 前回は落ちて終わった（開発者パネルで前回の記録を見られる）
    @Published private(set) var hadCrash = false
    /// ネットワークにつながっているか（NWPathMonitor）
    @Published private(set) var isOnline = true
    /// ダウンロード
    let downloads = DownloadManager()
    private let pathMonitor = NWPathMonitor()

    let machine = VNetMachine(factory: NWUserNetFactory())
    /// Cookie の写し（正本は WebKit の置き場）
    let cookieJar = CookieJar()
    /// HSTS の記録
    let hsts = HSTSStore(fileURL: HSTSStore.defaultFileURL())
    /// 開発者向けのログ（どのスレッドからでも書ける）
    let logs = DevLog()
    /// https の横取りの結果・新しいタブの通信の作り（setUp で決める）
    private(set) var takeover: HTTPSTakeover.Outcome = .disabledBySetting
    private(set) var defaultMode: NetMode = .native
    /// 全部のタブに入れる WebKit のルール（LAN の保護など）
    private(set) var contentRuleLists: [WKContentRuleList] = []
    private var cookieSync: WebCookieSync?
    private var nextTabID = 1
    /// 閉じたタブ（⌘⇧T で戻す。新しいものが後ろ）
    private var closedTabs: [SavedTab] = []
    private var dialogQueue: [JSDialog] = []
    private let session = JSONFile<SessionData>(name: "session.json")
    private var timers: [Timer] = []
    private var memoryObserver: NSObjectProtocol?
    private var didSetUp = false

    /// 動いている WebView の上限（これを超えたら、長く見ていないタブから WebView を捨てる）
    static let maxLiveWebViews = 6
    static let maxClosedTabs = 20

    /// @StateObject から作られる。iPad の Swift ではここが MainActor の中と見なされないことがあるので、
    /// 自分の @MainActor のものは触らず、準備は setUp に回す
    nonisolated init() {
        Task { @MainActor in self.setUp() }
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var searchEngine: SearchEngine { VelaSettings.searchEngine }
    var liveWebViewCount: Int { tabs.filter { $0.webView != nil }.count }

    private func setUp() {
        if didSetUp { return }
        didSetUp = true
        CrashLog.start()
        let lb = logs
        if let crash = CrashLog.previousCrashSummary() {
            logs.add("⚠️ 前回は落ちて終わりました: \(crash)（開発者パネルの「前回の記録」で、落ちる前のログが見られます）", level: .error, category: .app)
            hadCrash = true
        }
        takeover = HTTPSTakeover.install()
        if takeover == .installed { defaultMode = .vnetDirect }
        else if VelaSettings.legacyVNetsFallback && !VelaSettings.vnetDisabled { defaultMode = .vnetsLegacy }
        else { defaultMode = .native }
        logs.add(takeover.description)
        logs.add("新しいタブの通信: \(defaultMode.rawValue)")
        if defaultMode == .vnetsLegacy { logs.add("⚠️ 予備の vnets://… の作りで読みます（開発者向けの実験。CSP などを外すので安全ではありません）") }
        session.log = { s in lb.add(s) }

        // VNet: Cookie の正本は WebKit の置き場。CookieJar はその写し
        cookieJar.settings = VelaSettings.cookiePolicy
        cookieJar.log = { s in lb.add(s) }
        hsts.log = { s in lb.add(s) }
        machine.log = { s in lb.add(s) }
        if takeover == .installed || defaultMode == .vnetsLegacy {
            let sync = WebCookieSync(store: WKWebsiteDataStore.default().httpCookieStore, jar: cookieJar)
            sync.log = { s in lb.add(s) }
            cookieSync = sync
            machine.configurePolicies(cookieJar: cookieJar, hsts: hsts, localNetworkProtection: VelaSettings.localNetworkProtection)
            // 自作の通信で送る User-Agent も同じもの（ページの JavaScript から見えるものと食い違うと、ロボットだと思われる）
            machine.setUserAgent(BrowserIdentity.userAgent)
            machine.boot()
        }
        if VelaSettings.localNetworkProtection { compileLocalNetworkRules() } else { logs.add("⚠️ LAN の保護は切ってあります") }
        if defaultMode == .vnetsLegacy { compileVNetOnlyRules() }

        downloads.log = { s in lb.add(s, level: .info, category: .download) }
        downloads.webViewForResume = { [weak self] in self?.selectedTab?.webView }
        downloads.loadExisting()

        // ネットワークの様子（つながっていないときは帯を出す）
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let store = self
            Task { @MainActor in store?.setOnline(online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vela-path"))

        restoreSession()
        if tabs.isEmpty { newTab(url: nil) }

        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.handleMemoryWarning() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.refreshStatus() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.flushLogIfVisible() }
        })
    }

    // MARK: タブ

    /// 新しいタブ（url が nil なら空のタブ）。select: すぐ見るか
    @discardableResult
    func newTab(url: URL?, select: Bool = true, mode: NetMode? = nil, after: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(id: nextTabID, store: self, mode: mode ?? defaultMode)
        nextTabID += 1
        if let after, let i = tabs.firstIndex(where: { $0 === after }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if let url { tab.load(url, userInitiated: true) }
        if select { self.select(tab) }
        saveSession()
        return tab
    }

    /// ページが開いた新しい窓（target=_blank・window.open）。WebKit が渡した設定で WebView を作ってタブにする
    func adoptPopup(configuration: WKWebViewConfiguration, opener: BrowserTab) -> WKWebView {
        let tab = BrowserTab(id: nextTabID, store: self, mode: opener.mode)
        nextTabID += 1
        if let i = tabs.firstIndex(where: { $0 === opener }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        let wv = tab.adopt(configuration: configuration, scheme: opener.scheme)
        select(tab)
        logs.add("新しい窓をタブにしました（#\(opener.id) から）", level: .info, category: .nav, tab: tab.id)
        return wv
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        tab.lastSelected = Date()
        tab.ensureWebView()
        trimLiveWebViews()
        saveSession()
    }

    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        closedTabs.append(tab.saved())
        if closedTabs.count > BrowserStore.maxClosedTabs { closedTabs.removeFirst(closedTabs.count - BrowserStore.maxClosedTabs) }
        tab.tearDown()
        tabs.remove(at: i)
        logs.add("タブを閉じました", level: .info, category: .nav, tab: tab.id)
        if tabs.isEmpty { newTab(url: nil); return }
        if selectedID == tab.id { select(tabs[min(i, tabs.count - 1)]) }
        saveSession()
    }

    func closeOthers(_ keep: BrowserTab) {
        for t in tabs where t !== keep { close(t) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let s = closedTabs.popLast() else { return }
        let tab = BrowserTab(id: nextTabID, store: self, mode: s.mode)
        nextTabID += 1
        tab.restore(from: s)
        tabs.append(tab)
        select(tab)
    }

    func selectNextTab(_ step: Int) {
        guard let cur = selectedTab, let i = tabs.firstIndex(where: { $0 === cur }), !tabs.isEmpty else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    /// アドレス欄から開く（URL か検索語か）
    func open(_ text: String, in tab: BrowserTab? = nil) {
        guard let r = AddressInput.resolve(text, engine: searchEngine) else { return }
        let target = tab ?? selectedTab ?? newTab(url: nil)
        switch r {
        case .url(let u):
            logs.add("―― \(u.absoluteString) を開きます ――", level: .info, category: .nav, tab: target.id)
            target.load(u, userInitiated: true)
        case .search(let q, let u):
            logs.add("―― 「\(q)」を検索します（\(searchEngine.name)）――", level: .info, category: .nav, tab: target.id)
            target.load(u, userInitiated: true)
        }
    }

    /// 動いている WebView が多すぎたら、長く見ていないタブ（見ているタブ以外）から WebView を捨てる
    private func trimLiveWebViews() {
        let live = tabs.filter { $0.webView != nil && $0.id != selectedID }.sorted { $0.lastSelected < $1.lastSelected }
        let over = live.count + (selectedTab?.webView != nil ? 1 : 0) - BrowserStore.maxLiveWebViews
        if over <= 0 { return }
        for t in live.prefix(over) { t.suspend(reason: "動いている WebView が \(BrowserStore.maxLiveWebViews) 枚を超えた") }
    }

    private func handleMemoryWarning() {
        let others = tabs.filter { $0.webView != nil && $0.id != selectedID }
        logs.add("⚠️ メモリ警告: 見ていないタブ \(others.count) 枚の WebView を捨てます", level: .warning, category: .app)
        for t in others { t.suspend(reason: "メモリ警告") }
    }

    /// タブ一覧を開く前に、動いているタブのスナップショットを撮る
    func openTabOverview() {
        for t in tabs where t.webView != nil { t.takeSnapshot() }
        showTabOverview = true
    }

    // MARK: 保存

    func saveSession() {
        session.save(SessionData(tabs: tabs.map { $0.saved() }, selected: selectedID))
    }

    /// アプリが裏に回るとき: すぐ書く
    func saveSessionNow() {
        session.saveNow(SessionData(tabs: tabs.map { $0.saved() }, selected: selectedID))
        hsts.saveNow()
    }

    private func restoreSession() {
        guard let s = session.load(), !s.tabs.isEmpty else { return }
        for st in s.tabs {
            var mode = st.mode
            if mode.usesVNet && defaultMode == .native { mode = .native }      // VNet が使えないときは標準の通信で
            if mode == .vnetDirect && defaultMode == .vnetsLegacy { mode = .vnetsLegacy }
            let tab = BrowserTab(id: st.id, store: self, mode: mode)
            tab.restore(from: st)
            tabs.append(tab)
            nextTabID = max(nextTabID, st.id + 1)
        }
        logs.add("前のタブを \(s.tabs.count) 枚戻しました", level: .info, category: .app)
        select(tabs.first { $0.id == s.selected } ?? tabs[0])
    }

    // MARK: ダイアログ（JavaScript の alert・confirm・prompt）

    func presentDialog(_ d: JSDialog) {
        if dialog == nil { show(d) } else { dialogQueue.append(d) }
    }

    private func show(_ d: JSDialog) {
        if case .prompt(let def) = d.kind { dialogInput = def } else { dialogInput = "" }
        dialog = d
    }

    /// ダイアログを閉じる（ok: OK を押したか）
    func answerDialog(ok: Bool) {
        guard let d = dialog else { return }
        dialog = nil
        d.respond(ok, ok ? dialogInput : nil)
        if !dialogQueue.isEmpty { show(dialogQueue.removeFirst()) }
    }

    /// そのタブのダイアログを全部取り消す（タブを閉じたとき）
    func cancelDialogs(for tab: BrowserTab) {
        let mine = dialogQueue.filter { $0.origin.hasPrefix("#\(tab.id) ") }
        dialogQueue.removeAll { $0.origin.hasPrefix("#\(tab.id) ") }
        for d in mine { d.respond(false, nil) }
        if let d = dialog, d.origin.hasPrefix("#\(tab.id) ") { answerDialog(ok: false) }
    }

    // MARK: WebKit のルール

    /// LAN の保護のルール（標準の通信のタブ・WebSocket・VNet の手前）
    private func compileLocalNetworkRules() {
        let lb = logs
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vela-lan-protection", encodedContentRuleList: PageScripts.localNetworkRules) { [weak self] list, error in
            let store = self
            if let list {
                Task { @MainActor in store?.addRuleList(list) }
            } else {
                lb.add("⚠️ LAN の保護のルールを WebKit に入れられません: \(error.map { "\($0)" } ?? "不明")")
            }
        }
    }

    /// 予備の vnets:// の作りで、ブラウザが自分で外へ読みに行くのを止める（自作の通信だけで読む実験のため）
    private func compileVNetOnlyRules() {
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vnet-only", encodedContentRuleList: rules) { [weak self] list, _ in
            let store = self
            if let list { Task { @MainActor in store?.addRuleList(list, onlyVNetsLegacy: true) } }
        }
    }

    private var vnetsOnlyRuleLists: [WKContentRuleList] = []

    private func addRuleList(_ list: WKContentRuleList, onlyVNetsLegacy: Bool = false) {
        if onlyVNetsLegacy { vnetsOnlyRuleLists.append(list) } else { contentRuleLists.append(list) }
        for t in tabs { t.addRuleList(list, onlyVNetsLegacy: onlyVNetsLegacy) }
    }

    /// そのタブに入れるルール
    func ruleLists(for mode: NetMode) -> [WKContentRuleList] {
        contentRuleLists + (mode == .vnetsLegacy ? vnetsOnlyRuleLists : [])
    }

    /// VNet のタブの Cookie を WebKit の置き場に入れる（VNetScheme から）
    func pushCookies(_ changes: [CookieChange]) async {
        await cookieSync?.apply(changes)
    }

    func cookiesChangedByPage() {
        cookieSync?.scheduleRefresh()
    }

    // MARK: 様子

    private func setOnline(_ online: Bool) {
        if online == isOnline { return }
        isOnline = online
        logs.add(online ? "ネットワークにつながりました" : "⚠️ ネットワークにつながっていません", level: online ? .info : .warning, category: .app)
    }

    private func refreshStatus() {
        guard defaultMode.usesVNet || tabs.contains(where: { $0.mode.usesVNet }) else {
            vnetStatus = "VNet: 使っていません（\(takeover.description)）"
            return
        }
        machine.stats { [weak self] s in
            let store = self
            let text = (s.ready ? "IP \(s.ip)" : "IP をもらっています…") + "・" + s.summary
            Task { @MainActor in
                store?.vnetReady = s.ready
                store?.vnetStatus = text
            }
        }
    }

    private func flushLogIfVisible() {
        guard showDevPanel, let t = logs.take(lines: 400) else { return }
        logText = t
    }
}
