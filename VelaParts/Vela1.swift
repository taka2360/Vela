// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 1 / 4。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import ObjectiveC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - MyApp.swift
// ======================================================================

@main
struct VelaApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}

// ======================================================================
// MARK: - BrowserView.swift
// ======================================================================

// MARK: - 画面: 自作の通信（virtio-net → 小さなルーター）で読んだページを表示するブラウザ
//
// 中身は BrowserModel。ここは見た目だけ

struct WebBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @StateObject private var model = BrowserModel()
    @State private var showLog = true

    var body: some View {
        VStack(spacing: 8) {
            addressBar
            Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            WebBox(webView: model.webView)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            Toggle("通信のログ（virtio-net → ルーター）", isOn: $showLog).font(.caption)
            if showLog { logView }
        }
        .padding()
    }

    private var addressBar: some View {
        HStack {
            Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
            Button { model.webView.goForward() } label: { Image(systemName: "chevron.forward") }
            TextField("アドレス", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit { model.go() }
            Button("開く") { model.go() }.buttonStyle(.borderedProminent)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 180)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.logText) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// ======================================================================
// MARK: - BrowserModel.swift
// ======================================================================

// MARK: - ブラウザの中身: WKWebView と自作の通信（VNetMachine）をつなぐ
//
// ふつうは https・http の読み込みを全部 VNetScheme が引き受ける（HTTPSTakeover）。
// それができないときは予備の作り: WKWebView には「vnets://…」（https）・「vnet://…」（http）という自分用のアドレスで読ませ、
// ・ページの中の「https://…」の部品（画像・CSS など）も、HTML と CSS を書き換えて自作の通信で読む
// ・JavaScript が作るアドレス（fetch・XMLHttpRequest・img.src など）も、ページに入れた小さなスクリプトで書き換える
// ・それでも直接読もうとするものは止める（実験なので、混ざらないように）

/// 通信の作り
enum NetMode: String {
    /// https・http をそのまま VNetScheme が引き受ける（アドレスは本物の https://…）
    case vnetDirect = "VNet"
    /// 予備の vnets://… の作り（開発者向けの実験。CSP などを外すので安全ではない）
    case vnetsLegacy = "VNet（vnets://・実験）"
    /// 標準の通信（WebKit 内蔵）
    case native = "標準"

    var usesVNet: Bool { self != .native }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = "https://example.com/"
    @Published var logText = ""
    @Published var status = "準備中…"
    @Published var pageTitle = ""
    let webView: WKWebView
    let machine = VNetMachine(factory: NWUserNetFactory())
    /// 通信の作り（起動のときに決める）
    let mode: NetMode
    /// https の横取りの結果
    let takeover: HTTPSTakeover.Outcome
    /// Cookie の写し（正本は WebKit の置き場）
    let cookieJar = CookieJar()
    /// HSTS の記録
    let hsts = HSTSStore(fileURL: HSTSStore.defaultFileURL())
    private let scheme = VNetScheme()
    private let cookies = CookieBridge()
    private let actions = PageActionBridge()
    private var cookieSync: WebCookieSync?
    /// 開発者向けのログ（どのスレッドからでも書ける。画面には 0.3 秒ごとにまとめて出す）
    let logs = DevLog()
    private var timer: Timer?
    private var logTimer: Timer?

    override init() {
        let config = WKWebViewConfiguration()
        let outcome = HTTPSTakeover.install()
        takeover = outcome
        if outcome == .installed { mode = .vnetDirect }
        else if VelaSettings.legacyVNetsFallback && !VelaSettings.vnetDisabled { mode = .vnetsLegacy }
        else { mode = .native }
        let content = config.userContentController
        switch mode {
        case .vnetDirect:
            config.setURLSchemeHandler(scheme, forURLScheme: "https")
            config.setURLSchemeHandler(scheme, forURLScheme: "http")
        case .vnetsLegacy:
            config.setURLSchemeHandler(scheme, forURLScheme: "vnet")
            config.setURLSchemeHandler(scheme, forURLScheme: "vnets")
            content.addUserScript(WKUserScript(source: PageScripts.rewriteURLs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        case .native:
            break
        }
        if mode.usesVNet {
            // Cookie: ページの JavaScript が変えたら「合図」だけもらって、WebKit の置き場（正本）を読み直す
            content.addUserScript(WKUserScript(source: PageScripts.watchCookies, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            content.add(cookies, name: PageScripts.cookieHandlerName)
        }
        // LAN の保護: WebSocket は VNet を通らないので、ページの中でも止める
        if VelaSettings.localNetworkProtection {
            content.addUserScript(WKUserScript(source: PageScripts.webSocketGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        content.add(actions, name: PageScripts.actionHandlerName)
        // 動画: 全画面にせずページの中で再生する・自動再生を許す
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // iPad の Safari と同じ「デスクトップ用の表示」にする（User-Agent と、ページから見える端末の情報を揃えるため）
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: .zero, configuration: config)
        // User-Agent を iPad の Safari と同じにする。WKWebView の初期値には「Version/… Safari/…」が無く、
        // アプリの中のブラウザやロボットだと思われて、エラーや「不審なトラフィック」の画面になりやすい
        webView.customUserAgent = BrowserIdentity.userAgent
        super.init()
        webView.navigationDelegate = self
        // 残りの準備は、画面のスレッドで改めて行う。
        // NSObject の override init は、iPad の Swift だと MainActor の中と見なされないことがあり、
        // 自分の @MainActor のメソッド（startTimers など）をここから呼ぶとエラーになるため
        Task { @MainActor in self.setUp() }
    }

    /// init の続き（画面のスレッドで 1 回だけ）
    private func setUp() {
        let lb = logs
        logs.add(takeover.description)
        switch mode {
        case .vnetDirect: logs.add("https・http をそのまま自作の通信で読みます（アドレスは本物の https://…）")
        case .vnetsLegacy:
            logs.add("⚠️ 予備の vnets://… の作りで読みます（開発者向けの実験。CSP などを外すので安全ではありません）")
            blockDirectLoads()
        case .native: logs.add("標準の通信（WebKit）で読みます。VNet は使いません")
        }
        if VelaSettings.localNetworkProtection { installLocalNetworkRules() } else { logs.add("⚠️ LAN の保護は切ってあります") }
        actions.onAction = { [weak self] body, isMain, origin in
            let model = self
            Task { @MainActor in model?.handleAction(body, isMainFrame: isMain, origin: origin) }
        }

        guard mode.usesVNet else { startTimers(); return }
        // VNet: Cookie の正本は WebKit の置き場。CookieJar はその写し
        cookieJar.settings = VelaSettings.cookiePolicy
        cookieJar.log = { s in lb.add(s) }
        hsts.log = { s in lb.add(s) }
        let sync = WebCookieSync(store: webView.configuration.websiteDataStore.httpCookieStore, jar: cookieJar)
        sync.log = { s in lb.add(s) }
        cookieSync = sync
        cookies.onSignal = { [weak sync] in
            let target = sync   // weak の変数は並行の閉包から直接さわれないので、let に受け直す
            Task { @MainActor in target?.scheduleRefresh() }
        }
        scheme.machine = machine
        scheme.hsts = hsts
        scheme.pushCookies = { [weak sync] changes, done in
            let target = sync
            Task { @MainActor in
                await target?.apply(changes)
                done()
            }
        }
        machine.log = { s in lb.add(s) }
        scheme.log = { s in lb.add(s) }
        cookies.log = { s in lb.add(s) }
        machine.configurePolicies(cookieJar: cookieJar, hsts: hsts, localNetworkProtection: VelaSettings.localNetworkProtection)
        // 自作の通信で送る User-Agent も同じもの（ページの JavaScript から見えるものと食い違うと、ロボットだと思われる）
        machine.setUserAgent(BrowserIdentity.userAgent)
        machine.boot()
        startTimers()
    }

    /// ブラウザが自分で外へ読みに行くのを止める（予備の作りのとき。自作の通信だけで読む実験のため）
    private func blockDirectLoads() {
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vnet-only", encodedContentRuleList: rules) { [weak self] list, _ in
            let model = self
            if let list { Task { @MainActor in model?.webView.configuration.userContentController.add(list) } }
        }
    }

    /// LAN の保護のルール（標準の通信のタブ・WebSocket・VNet の手前）を WebKit に入れる
    private func installLocalNetworkRules() {
        let lb = logs
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vela-lan-protection", encodedContentRuleList: PageScripts.localNetworkRules) { [weak self] list, error in
            let model = self
            if let list {
                Task { @MainActor in model?.webView.configuration.userContentController.add(list) }
            } else {
                lb.add("⚠️ LAN の保護のルールを WebKit に入れられません: \(error.map { "\($0)" } ?? "不明")")
            }
        }
    }

    private func startTimers() {
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in model?.flushLog() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in model?.refreshStatus() }
        }
    }

    func addLog(_ s: String) { logs.add(s) }

    private func flushLog() {
        if let t = logs.take() { logText = t }
    }

    private func refreshStatus() {
        guard mode.usesVNet else { status = "通信: \(mode.rawValue)"; return }
        let name = mode.rawValue
        machine.stats { [weak self] s in
            let model = self
            let ip = s.ready ? "IP \(s.ip)" : "IP をもらっています…"
            let text = "\(name)・\(ip)・\(s.summary)"
            Task { @MainActor in model?.status = text }
        }
    }

    /// エラーページのボタン・守りのスクリプトからの知らせ
    private func handleAction(_ body: [String: Any], isMainFrame: Bool, origin: String) {
        switch body["action"] as? String {
        case "allowLocalNetwork":
            // 確認のページ（メインフレーム）からの、合言葉の合っている知らせだけを受け付ける
            guard isMainFrame, let nonce = body["nonce"] as? String, let u = scheme.consumeConsent(nonce) else {
                addLog("🛡 LAN の確認: 受け付けない知らせです（\(origin)）")
                return
            }
            addLog("🛡 LAN の確認: ユーザーが許可しました → \(u.absoluteString)")
            open(u)
        case "blockedWebSocket":
            addLog("🛡 LAN の保護: WebSocket を止めました（\(origin) → \(body["url"] as? String ?? "?")）")
        default:
            break
        }
    }

    /// ユーザーの操作として開く（LAN の保護・SameSite の判定で「ユーザーの操作」になる）
    private func open(_ u: URL) {
        let target: URL
        switch mode {
        case .vnetsLegacy: guard let v = VNetURL.toVNet(u) else { addLog("アドレスが正しくありません"); return }; target = v
        case .vnetDirect, .native: target = u
        }
        if mode.usesVNet { scheme.noteUserNavigation(target) }
        webView.load(URLRequest(url: target))
    }

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let u = URL(string: text) else { addLog("アドレスが正しくありません"); return }
        addLog("―― \(text) を開きます ――")
        open(u)
    }

    // MARK: WKNavigationDelegate

    // リンクを押したとき: https:// などのアドレスなら、自作の通信のアドレスに直して開き直す（vnets:// の作りのときだけ）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if mode != .vnetsLegacy { return .allow }
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https",
           navigationAction.targetFrame?.isMainFrame ?? true, let v = VNetURL.toVNet(u) {
            webView.load(URLRequest(url: v))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url, let r = VNetURL.toReal(u) { address = r.absoluteString }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageTitle = webView.title ?? ""
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        addLog("✕ 読み込みに失敗: \(error.localizedDescription)")
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
// MARK: - VNetScheme.swift
// ======================================================================

// MARK: - WKWebView の読み込みを引き受けて、自作の通信（VNetMachine）で取ってくる
//
// https:// と http://（予備の作りでは vnets:// と vnet://）の読み込みが全部ここに来る。
// WebKit は画面のスレッドから呼ぶ。こちらも pending は画面のスレッドの上でだけ触る
//
// 守っていること（NetPolicy.swift の決まりを使う）:
// ・CORS はサーバーの答えをそのまま渡す（OPTIONS もサーバーに送る）。Vela が許可を作ることはしない
// ・CSP・X-Frame-Options などの守りのヘッダは消さない（予備の vnets:// の作りだけは、書き換えと合わないので外す）
// ・リダイレクトの次の要求は RedirectPolicy だけで作る（Authorization を別のオリジンへ持ち越さない・POST を二重に送らない）
// ・Cookie は CookieJar（WebKit の置き場の写し）と CookiePolicy。届いた Cookie は WebKit の置き場に入れてから、ページに返事を渡す
// ・HSTS: 記録があれば http を https に上げる。https の応答から記録する（HSTSPolicy の条件のときだけ）
// ・LAN の保護で「確認が必要」になった移動は、確認のページを出す（ユーザーが押したら、ユーザーの操作として開き直す）

final class VNetScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var machine: VNetMachine?
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 届いた Cookie の変更をブラウザ（WebKit）の置き場に入れる。入れ終わったら done を呼ぶこと
    var pushCookies: (([CookieChange], _ done: @escaping @Sendable () -> Void) -> Void)?
    /// HSTS の記録（nil なら使わない）
    var hsts: HSTSStore?
    /// LAN への移動の確認のページで使う合言葉（nonce）→ 開く URL。ページのボタンはこの合言葉を付けて知らせる。
    /// 合言葉は確認のページの中にしか無い（確認のページは LAN 側のオリジンで出すので、元の公開のページからは読めない）
    private var consents: [String: (url: URL, at: Date)] = [:]

    /// 確認のページのボタンから届いた合言葉を確かめて、開く URL を返す（1 回だけ・10 分まで）
    func consumeConsent(_ nonce: String) -> URL? {
        guard let c = consents.removeValue(forKey: nonce), Date().timeIntervalSince(c.at) < 600 else { return nil }
        return c.url
    }

    private func makeConsentNonce(_ url: URL) -> String {
        let now = Date()
        consents = consents.filter { now.timeIntervalSince($0.value.at) < 600 }
        let n = UUID().uuidString + UUID().uuidString
        consents[n] = (url, now)
        return n
    }

    /// 読み込み中の要求
    private struct Pending {
        let task: WKURLSchemeTask
        /// WebKit が頼んできたアドレス（vnets://… か https://…）。移動（リダイレクト）すると変わる
        var shownURL: URL
        /// 本当に読みに行くアドレス（https://…）
        var realURL: URL
        let started: Date
        /// WebKit からの要求（移動のときに、次の要求を作るのに使う）
        var request: URLRequest
        var body: Data?
        var redirects = 0
        /// 移動（3xx）を WebKit に伝えられるか。できないときは、自分で追いかけて最後の返事だけ渡す
        var webKitRedirects: Bool
        /// 要求の文脈（Cookie・LAN・HSTS の判定）
        var context: RequestContext
        /// 取り消しの印（WebKit がやめたら、裏の通信も止める）
        let token = RequestToken()
        /// 予備の vnets:// の作りの要求か
        var vnetsMode: Bool { VNetURL.isVNet(shownURL) }
    }
    private var pending: [ObjectIdentifier: Pending] = [:]

    /// ユーザーがアドレス欄などから開いた URL（1 回だけ使える印。ページのリンクや JavaScript の移動と見分ける）
    private var userNavigation: (url: URL, at: Date)?

    /// アプリが load() する直前に呼ぶ（画面のスレッドから）
    func noteUserNavigation(_ url: URL) {
        userNavigation = (VNetURL.toReal(url) ?? url, Date())
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        start(task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 裏の通信も止める（待ち行列から外す・読んでいる途中の接続は切る）
        pending.removeValue(forKey: ObjectIdentifier(task))?.token.cancel()
    }

    /// 読み込み中の要求の数（開発者向け）
    var pendingCount: Int { pending.count }

    private func start(_ task: WKURLSchemeTask) {
        guard let shown = task.request.url, let real = VNetURL.toReal(shown), let machine else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let body = VNetScheme.body(of: task.request)
        let ctx = context(for: task.request, real: real)
        let id = ObjectIdentifier(task)
        let webKitRedirects = SchemeTaskRedirect.isAvailable(task)
        var p = Pending(task: task, shownURL: shown, realURL: real, started: Date(), request: task.request, body: body,
                        webKitRedirects: webKitRedirects, context: ctx)
        pending[id] = p
        // HSTS: 記録のあるホストの http は、https に上げてから読む（WebKit にも移動として伝える）
        if real.scheme?.lowercased() == "http", let h = SiteUtil.host(of: real), hsts?.shouldUpgrade(h) == true,
           var c = URLComponents(url: real, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            if let up = c.url {
                log?("🔒 HSTS: \(real.absoluteString) → https")
                if webKitRedirects {
                    let next = RedirectPolicy.Next(url: up, method: task.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(task.request),
                                                   body: body, crossOrigin: true, upgradedByHSTS: true, dropped: [])
                    redirect(id, p, status: 307, serverHeaders: [("Non-Authoritative-Reason", "HSTS")], type: "text/plain", next: next)
                    return
                }
                p.realURL = up
                p.context = ctx.redirected(from: real, to: up)
                pending[id] = p
                fetch(id, makeRequest(task.request, url: up, body: body, ctx: p.context), followRedirects: true, machine: machine)
                return
            }
        }
        fetch(id, makeRequest(task.request, url: real, body: body, ctx: ctx), followRedirects: !webKitRedirects, machine: machine)
    }

    private func fetch(_ id: ObjectIdentifier, _ req: HTTPRequest, followRedirects: Bool, machine: VNetMachine) {
        var req = req
        req.token = pending[id]?.token
        machine.send(req, followRedirects: followRedirects) { [weak self] result in
            let me = self   // weak の self は var なので、並行で動く閉包からは直接さわれない。let に受け直す
            DispatchQueue.main.async { me?.finish(id, result) }
        }
    }

    private func finish(_ id: ObjectIdentifier, _ result: Result<HTTPResult, FetchError>) {
        guard pending[id] != nil else { return }
        // Cookie が届いていたら、先にブラウザの置き場に入れてから返事を渡す（ページがすぐ document.cookie を読んでも間に合うように）
        if case .success(let r) = result, !r.cookieChanges.isEmpty, let pushCookies {
            pushCookies(r.cookieChanges) { [weak self] in
                let me = self
                DispatchQueue.main.async { me?.complete(id, result) }
            }
            return
        }
        complete(id, result)
    }

    /// 返事を WebKit に渡す（途中で止められていたら何もしない）
    private func complete(_ id: ObjectIdentifier, _ result: Result<HTTPResult, FetchError>) {
        guard let p = pending[id] else { return }
        if case .success(let r) = result, let sts = r.header("Strict-Transport-Security") {
            hsts?.record(header: sts, url: r.url, ctx: p.context)
        }
        // 移動（3xx）: WebKit に「移動した」と伝える（アドレス・相対リンク・オリジン・クッキーが移動先のものになる）
        if case .success(let r) = result, p.webKitRedirects, RedirectPolicy.statuses.contains(r.status) {
            let hsts = self.hsts
            switch RedirectPolicy.next(from: p.realURL, method: p.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(p.request),
                                       body: p.body, status: r.status, location: r.header("Location"), redirectCount: p.redirects,
                                       hsts: { hsts?.shouldUpgrade($0) ?? false }) {
            case .success(let next):
                redirect(id, p, status: r.status, serverHeaders: r.headers, type: VNetScheme.contentType(r, real: p.realURL), next: next)
                return
            case .failure(.tooMany):
                pending[id] = nil
                fail(p, FetchError("リダイレクトが多すぎます", kind: .redirect))
                return
            case .failure(let f):
                log?("↪ \(r.status) を追いかけません（\(f)）。そのまま渡します")
            }
        }
        pending[id] = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        let real = p.realURL
        switch result {
        case .failure(let e):
            fail(p, e)
        case .success(let r):
            let range = r.header("Content-Range").map { "・\($0)" } ?? ""
            log?("✓ \(r.status) \(r.url.absoluteString)（\(r.body.count / 1024)KB・\(ms)ms\(range)）")
            var type = VNetScheme.contentType(r, real: real)
            var body = r.body
            // vnets:// の作りのときだけ: HTML と CSS の中の https:// を vnets:// に書き換える（部品も自作の通信で読むため）
            // （https をそのまま引き受けているときは、書き換えなくても全部ここに来る）
            let lower = type.lowercased()
            if p.vnetsMode && (lower.contains("text/html") || lower.contains("text/css")) {
                body = VNetScheme.rewriteLinks(body)
                if !lower.contains("charset") { type += "; charset=utf-8" }
            }
            // 自分で追いかけた移動の先のアドレスで表示する（相対アドレスがずれないように）
            let shownReal = VNetURL.toReal(p.shownURL) ?? p.shownURL
            let shown = r.url == shownReal ? p.shownURL : (p.vnetsMode ? (VNetURL.toVNet(r.url) ?? p.shownURL) : r.url)
            respond(p.task, url: shown, status: r.status, type: type, body: body, vnetsMode: p.vnetsMode, extra: r.headers)
        }
    }

    /// 失敗をページにする（LAN への移動の確認なら、確認のページ）
    private func fail(_ p: Pending, _ e: FetchError) {
        let real = p.realURL
        log?("✕ \(real.absoluteString)：\(e.description)")
        var html: String
        if e.kind == .localNetworkConsent && p.context.isTopLevel {
            let nonce = makeConsentNonce(real)
            html = VNetScheme.page(title: "LAN の機器を開きますか？", lines: [
                "ページが、LAN（家や会社の中のネットワーク）にある次のアドレスへ移動しようとしています。",
                real.absoluteString, e.description,
                "心当たりがなければ開かないでください。"],
                button: ("開く", "window.webkit.messageHandlers.velaAction.postMessage({action:'allowLocalNetwork',nonce:'\(nonce)'})"))
        } else {
            html = VNetScheme.page(title: "読めませんでした", lines: [real.absoluteString, e.description], button: nil)
        }
        html += "<!-- vela-error:\(e.kind.rawValue) -->"
        respond(p.task, url: p.shownURL, status: 502, type: "text/html; charset=utf-8", body: Data(html.utf8), vnetsMode: p.vnetsMode)
    }

    /// エラー・確認のページ（文字は全部エスケープする）
    static func page(title: String, lines: [String], button: (String, String)?) -> String {
        var s = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
        s += "<title>\(htmlEscape(title))</title></head><body style='font:16px -apple-system;padding:24px;max-width:640px'>"
        s += "<h3>\(htmlEscape(title))</h3>"
        for l in lines { s += "<p style='word-break:break-all'>\(htmlEscape(l))</p>" }
        if let (label, js) = button {
            s += "<button style='font-size:16px;padding:8px 20px' onclick=\"\(htmlEscape(js))\">\(htmlEscape(label))</button>"
        }
        return s + "</body></html>"
    }

    static func htmlEscape(_ s: String) -> String {
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

    // MARK: 移動（リダイレクト）

    /// 3xx を WebKit に伝える。WebKit が次の要求を返してきたら、それを読みに行く
    private func redirect(_ id: ObjectIdentifier, _ p: Pending, status: Int, serverHeaders: [(String, String)], type: String, next: RedirectPolicy.Next) {
        let nextShown = p.vnetsMode ? (VNetURL.toVNet(next.url) ?? next.url) : next.url
        let dropped = next.dropped.isEmpty ? "" : "（外したヘッダ: \(next.dropped.joined(separator: ", "))）"
        log?("↪ \(status) \(p.realURL.absoluteString) → \(next.url.absoluteString)\(dropped)")
        var h = VNetScheme.responseHeaders(type: type, length: 0, vnetsMode: p.vnetsMode, extra: serverHeaders)
        h["Location"] = nextShown.absoluteString
        let nr = NSMutableURLRequest(url: nextShown)
        nr.httpMethod = next.method
        var fields: [String: String] = [:]
        for (k, v) in next.headers { fields[k] = v }
        nr.allHTTPHeaderFields = fields
        nr.httpBody = next.body
        nr.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? nextShown : p.request.mainDocumentURL
        let body = next.body
        guard let resp = HTTPURLResponse(url: p.shownURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h),
              SchemeTaskRedirect.perform(p.task, response: resp, request: nr, done: { [weak self] newReq in
                  let me = self
                  DispatchQueue.main.async { me?.afterRedirect(id, newReq, body: body) }
              }) else {
            // 伝えられなかった: 受け取った 3xx から作った次の要求を、自分で追いかける（元の要求は送り直さない。POST を二重に送らないため）
            guard var q = pending[id], let machine else { return }
            q.webKitRedirects = false
            q.context = q.context.redirected(from: q.realURL, to: next.url)
            q.realURL = next.url
            q.redirects += 1
            pending[id] = q
            var r = URLRequest(url: next.url)
            r.httpMethod = next.method
            r.allHTTPHeaderFields = fields
            r.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? next.url : p.request.mainDocumentURL.flatMap { VNetURL.toReal($0) }
            r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
            fetch(id, makeRequest(r, url: next.url, body: next.body, ctx: q.context), followRedirects: true, machine: machine)
            return
        }
    }

    /// WebKit が移動を受け入れた（newReq が次の要求）。nil なら WebKit がやめた（このあと stop が来る）
    private func afterRedirect(_ id: ObjectIdentifier, _ newReq: NSURLRequest?, body: Data?) {
        guard var p = pending[id] else { return }
        guard let newReq, let u = newReq.url, let real = VNetURL.toReal(u), let machine else {
            pending[id] = nil
            return
        }
        var r = URLRequest(url: u)
        r.httpMethod = newReq.httpMethod
        r.allHTTPHeaderFields = newReq.allHTTPHeaderFields
        r.mainDocumentURL = newReq.mainDocumentURL
        r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
        let b = newReq.httpBody ?? body
        p.context = p.context.redirected(from: p.realURL, to: real)
        p.shownURL = u
        p.realURL = real
        p.request = r
        p.body = b
        p.redirects += 1
        pending[id] = p
        fetch(id, makeRequest(r, url: real, body: b, ctx: p.context), followRedirects: false, machine: machine)
    }

    // MARK: 要求を作る

    /// WebKit の要求から、文脈（トップのページ・トップレベルの移動か・どこから来たか・ユーザーの操作か）を作る
    private func context(for r: URLRequest, real: URL) -> RequestContext {
        let top = r.mainDocumentURL.flatMap { VNetURL.toReal($0) }
        let isTop = r.mainDocumentURL != nil && r.mainDocumentURL == r.url
        // どこから来たか: Referer。無ければ Origin（Referrer-Policy: no-referrer でも、POST には Origin が付く。"null" は分からない扱い）
        let referer = r.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) }
        let originHeader = r.value(forHTTPHeaderField: "Origin").flatMap { $0 == "null" ? nil : URL(string: $0) }
        let initiator = (referer ?? originHeader).flatMap { VNetURL.toReal($0) }
        var ctx = RequestContext(topURL: top, isTopLevel: isTop, initiator: initiator)
        ctx.cookiesAllowed = r.httpShouldHandleCookies
        // 実機で確かめること: WebKit がスキームハンダの要求に httpShouldHandleCookies を正しく入れてくるか（ページ本体で false なら怪しい）
        if isTop && !r.httpShouldHandleCookies { log?("🍪 ページ本体の要求が httpShouldHandleCookies=false です（\(real.absoluteString)）") }
        if isTop, let u = userNavigation, Date().timeIntervalSince(u.at) < 15, VNetScheme.sameIgnoringFragment(u.url, real) {
            ctx.userInitiated = true
            userNavigation = nil
        }
        return ctx
    }

    static func sameIgnoringFragment(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false), cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil; cb?.fragment = nil
        return ca?.url?.absoluteString == cb?.url?.absoluteString
    }

    /// URLRequest のヘッダを（名前, 値）の並びにする
    static func headerPairs(_ r: URLRequest) -> [(String, String)] {
        (r.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
    }

    /// WebKit の要求を、自作の通信の要求にする
    func makeRequest(_ r: URLRequest, url: URL, body: Data?, ctx: RequestContext) -> HTTPRequest {
        var req = VNetScheme.makeRequest(r, url: url, body: body)
        req.context = ctx
        return req
    }

    /// WebKit の要求を、自作の通信の要求にする（ヘッダの変換だけ。文脈は makeRequest(_:url:body:ctx:) で付ける）
    static func makeRequest(_ r: URLRequest, url: URL, body: Data?) -> HTTPRequest {
        var req = HTTPRequest(url: url)
        req.method = r.httpMethod ?? "GET"
        for (k, v) in r.allHTTPHeaderFields ?? [:] {
            switch k.lowercased() {
            case "origin", "referer":
                // vnets://… なら https://… に戻して送る（https://… ならそのまま）
                if v.lowercased().hasPrefix("vnet"), let u = URL(string: v), let real = VNetURL.toReal(u) {
                    let s = real.absoluteString
                    req.headers.append((k, k.lowercased() == "origin" ? s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : s))
                } else if v.lowercased().hasPrefix("http") {
                    req.headers.append((k, v))
                }
            case "range":
                // 「最後まで全部」は、少しずつ（2MB ずつ）にする。動画を丸ごと読み終わるまで待たないように
                req.headers.append((k, clampRange(v) ?? v))
            default:
                req.headers.append((k, v))
            }
        }
        req.body = body
        // ページを開く要求（ページ本体）に Sec-Fetch-* が無ければ付ける（Safari は必ず付ける。無いとロボットだと思われやすい）
        if req.headers.value(for: "Sec-Fetch-Dest") == nil, let main = r.mainDocumentURL, main == r.url {
            var site = "none"
            if let ref = req.headers.value(for: "Referer").flatMap({ URL(string: $0) }), let rh = ref.host?.lowercased(),
               let h = url.host?.lowercased() {
                if ref.scheme?.lowercased() == url.scheme?.lowercased() && rh == h && ref.port == url.port { site = "same-origin" }
                else { site = siteOf(rh) == siteOf(h) ? "same-site" : "cross-site" }
            }
            req.headers += [("Sec-Fetch-Site", site), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")]
            if req.headers.value(for: "Upgrade-Insecure-Requests") == nil { req.headers.append(("Upgrade-Insecure-Requests", "1")) }
        }
        return req
    }

    /// 「サイト」（example.co.jp → example.co.jp、www.example.com → example.com）
    static func siteOf(_ host: String) -> String { SiteUtil.registrableDomain(host) }

    static func body(of r: URLRequest) -> Data? {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return nil }
        var d = Data()
        s.open()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        s.close()
        return d
    }

    /// 1 回に読む大きさ（動画の Range）
    static let rangeChunk = 2 << 20

    /// "bytes=a-"（最後まで）や、大きすぎる "bytes=a-b" を "bytes=a-(a+2MB-1)" に直す。直さなくて良いときは nil
    static func clampRange(_ v: String) -> String? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("bytes="), !s.contains(",") else { return nil }
        let parts = s.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let maxEnd = a + rangeChunk - 1
        if let b = Int(parts[1].trimmingCharacters(in: .whitespaces)), b <= maxEnd { return nil }
        return "bytes=\(a)-\(maxEnd)"
    }

    // MARK: 返事を作る

    /// 拡張子から動画・音声の種類を決める
    static let mediaTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
                                               "webm": "video/webm", "mp3": "audio/mpeg", "m4a": "audio/mp4",
                                               "aac": "audio/aac", "wav": "audio/wav", "m3u8": "application/vnd.apple.mpegurl",
                                               "ts": "video/mp2t"]

    /// Content-Type。種類が書いていない動画・音声は、拡張子から決める（でないと再生できない）
    static func contentType(_ r: HTTPResult, real: URL) -> String {
        let type = r.header("Content-Type") ?? "application/octet-stream"
        let lower = type.lowercased()
        if lower.hasPrefix("application/octet-stream") || lower.hasPrefix("binary/"),
           let guess = mediaTypes[real.pathExtension.lowercased()] {
            return guess
        }
        return type
    }

    /// HTML・CSS の中の https:// を vnets://（http:// を vnet://）に書き換える
    static func rewriteLinks(_ body: Data) -> Data {
        var s = String(decoding: body, as: UTF8.self)
        for (from, to) in [("https://", "vnets://"), ("http://", "vnet://"), ("https:\\/\\/", "vnets:\\/\\/")] {
            for q in ["\"", "'", "(", "=", " "] { s = s.replacingOccurrences(of: q + from, with: q + to) }
        }
        return Data(s.utf8)
    }

    /// 相手の返事のヘッダのうち、WebKit にそのまま渡さないもの（長さ・縮め方は自分で決め直す。Cookie は CookieJar 経由で WebKit の置き場に入れる）
    static let dropHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "content-type", "connection",
                                           "keep-alive", "set-cookie", "set-cookie2", "alt-svc", "location"]
    /// 予備の vnets:// の作りのときだけ外すもの（アドレスを書き換えるので、ページの守りの決まりと合わない。この作りは開発者向けの実験で、安全ではない）
    static let vnetsOnlyDropHeaders: Set<String> = ["content-security-policy", "content-security-policy-report-only", "x-frame-options"]

    /// 返事のヘッダ: 相手のヘッダ（CSP・X-Frame-Options・動画に要る Content-Range など）＋ 長さ・種類。
    /// CORS（Access-Control-*）はサーバーの答えをそのまま渡す（CORSPassthrough）。Vela が許可を足すことはしない
    static func responseHeaders(type: String, length: Int, vnetsMode: Bool, extra: [(String, String)]) -> [String: String] {
        var h: [String: String] = [:]
        var names: [String: String] = [:]      // 小文字の名前 → h での名前（同じ名前が何行もあれば「, 」でつなぐ）
        func add(_ k: String, _ v: String) {
            let lk = k.lowercased()
            if let ek = names[lk], let old = h[ek] { h[ek] = old + ", " + v } else { names[lk] = k; h[k] = v }
        }
        for (k, v) in extra {
            let lk = k.lowercased()
            if dropHeaders.contains(lk) || lk.hasPrefix("access-control-") { continue }
            if vnetsMode && vnetsOnlyDropHeaders.contains(lk) { continue }
            add(k, v)
        }
        for (k, v) in CORSPassthrough.headers(extra, vnetsMode: vnetsMode) { add(k, v) }
        h["Content-Type"] = type
        h["Content-Length"] = String(length)
        return h
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data, vnetsMode: Bool, extra: [(String, String)] = []) {
        let h = VNetScheme.responseHeaders(type: type, length: body.count, vnetsMode: vnetsMode, extra: extra)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

// ======================================================================
// MARK: - HTTPSTakeover.swift
// ======================================================================

// MARK: - WKWebView の https・http の読み込みを、アプリが引き受けるための仕掛け

/// WKWebView に「https・http も自分で引き受けます」と言えるようにする
///
/// 普通は https を setURLSchemeHandler に渡すと「それは WebKit が自分でやる」と止められる（アプリが落ちる）。
/// WebKit はそれを WKWebView.handlesURLScheme で確かめているので、そこだけ「http・https は扱わない」と答えさせる。
/// こうすると、ページのアドレスは本物の https://… のまま、読み込みは全部 VNetScheme（自作の通信）に来る。
/// YouTube やログインのように「アドレスが https か」を確かめるページも、そのまま動く。
///
/// 受け入れたリスク（README と開発者パネルにも書く）:
/// ・WebKit の中の作り（handlesURLScheme の差し替え・_willPerformRedirection:）に頼っている。実行時に確かめても、
///   WebKit が変われば動かなくなる・落ちる可能性は消せない。App Store に出すアプリには使えない
/// ・守り: 確かめた iOS の版（testedMajorVersions）だけで使う。差し替えた後の確認に失敗したら、元の実装に戻して標準の通信にする。
///   設定の「VNet を使わない」で、差し替え自体をしないようにできる
enum HTTPSTakeover {
    enum Outcome: Equatable {
        /// https・http を VNetScheme が引き受けられる
        case installed
        /// 設定で VNet を使わない
        case disabledBySetting
        /// 確かめていない iOS の版（設定で許せば試す）
        case untestedOS(Int)
        /// 差し替えられなかった・確認に失敗した（元に戻した）
        case failed(String)

        var description: String {
            switch self {
            case .installed: return "https の横取り: 成功"
            case .disabledBySetting: return "https の横取り: 設定で使わない"
            case .untestedOS(let v): return "https の横取り: 確かめていない iOS \(v) なので使わない（設定で試せます）"
            case .failed(let why): return "https の横取り: 失敗（\(why)）。元に戻しました"
            }
        }
    }

    /// 動くことを確かめた iOS の版（大きい番号）
    static let testedMajorVersions = 16...26

    // 1 回目の結果。@MainActor にはしない（NSObject の override init など、隔離の扱いが iPad の Swift で揺れる所から呼ぶため）。
    // 代わりにロックで守る。WKWebView.handlesURLScheme は Objective-C の API なので、どのスレッドから呼んでもコンパイルは通る
    private static let lock = NSLock()
    private static var result: Outcome?

    /// 1 回だけ行う（2 回目からは 1 回目の結果）。画面のスレッドから呼ぶこと
    static func install() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        let r = tryInstall()
        result = r
        return r
    }

    private static func tryInstall() -> Outcome {
        if VelaSettings.vnetDisabled { return .disabledBySetting }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if !testedMajorVersions.contains(major) && !VelaSettings.allowUntestedOS { return .untestedOS(major) }
        let sel = NSSelectorFromString("handlesURLScheme:")
        guard let m = class_getClassMethod(WKWebView.self, sel) else { return .failed("handlesURLScheme: が見つかりません") }
        let original = method_getImplementation(m)
        let others = ["data", "blob", "about", "vnets"]
        let before = others.map { WKWebView.handlesURLScheme($0) }
        swap(m, sel: sel, original: original)
        // 差し替えが効いているか・ほかのスキームの答えが変わっていないかを確かめる。だめなら元に戻す
        let ok = !WKWebView.handlesURLScheme("https") && !WKWebView.handlesURLScheme("http")
            && others.map({ WKWebView.handlesURLScheme($0) }) == before
        if !ok {
            _ = method_setImplementation(m, original)
            return .failed("差し替えた後の確認に失敗")
        }
        return .installed
    }

    private static func swap(_ m: Method, sel: Selector, original: IMP) {
        typealias Orig = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let orig = unsafeBitCast(original, to: Orig.self)
        let block: @convention(block) (AnyObject, NSString) -> Bool = { cls, scheme in
            let s = (scheme as String).lowercased()
            if s == "http" || s == "https" { return false }
            return orig(cls, sel, scheme)
        }
        _ = method_setImplementation(m, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
    }
}

/// 読み込みの途中の「移動（リダイレクト）」を WebKit に伝える
///
/// WKURLSchemeTask の公開の作りには移動を伝える方法が無い。そのままだと、移動先の中身を元のアドレスのまま見せることになり、
/// 相対リンク・オリジン・クッキーがずれて、ページが壊れたりログインできなかったりする。
/// WebKit の中にある _willPerformRedirection:newRequest:completionHandler:（iOS 13 から）を使って、本当の移動として伝える。
/// 無ければ false（そのときは前のやり方: 自分で追いかけて、最後の返事だけ渡す）
enum SchemeTaskRedirect {
    private static let selector = NSSelectorFromString("_willPerformRedirection:newRequest:completionHandler:")

    static func isAvailable(_ task: WKURLSchemeTask) -> Bool {
        class_getInstanceMethod(object_getClass(task), selector) != nil
    }

    /// 移動を伝える。WebKit が受け入れたら done(次の要求)、やめたら done(nil)
    static func perform(_ task: WKURLSchemeTask, response: URLResponse, request: NSURLRequest,
                        done: @escaping (NSURLRequest?) -> Void) -> Bool {
        guard let m = class_getInstanceMethod(object_getClass(task), selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, URLResponse, NSURLRequest, @escaping @convention(block) (NSURLRequest?) -> Void) -> Void
        let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (NSURLRequest?) -> Void = { done($0) }
        f(task as AnyObject, selector, response, request, block)
        return true
    }
}

/// 予備の作りで使う自分用のアドレス: https://… ⇄ vnets://…、http://… ⇄ vnet://…
enum VNetURL {
    /// https://… → vnets://…、http://… → vnet://…（vnets・vnet はそのまま）
    static func toVNet(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "vnets"
        case "http": c.scheme = "vnet"
        case "vnet", "vnets": break
        default: return nil
        }
        return c.url
    }

    /// vnets://… → https://…、vnet://… → http://…（https・http はそのまま）
    static func toReal(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "vnets": c.scheme = "https"
        case "vnet": c.scheme = "http"
        case "https", "http": return u
        default: return nil
        }
        return c.url
    }

    /// 自分用のアドレス（vnet://・vnets://）か
    static func isVNet(_ u: URL) -> Bool { u.scheme?.lowercased().hasPrefix("vnet") ?? false }
}

// ======================================================================
// MARK: - PageScripts.swift
// ======================================================================

// MARK: - ページに入れる小さなスクリプトと、そこから届く知らせ

enum PageScripts {
    /// JavaScript が使う https:// のアドレスを vnets:// に直す（予備の vnets:// の作りのときだけ使う）
    static let rewriteURLs = #"""
    (function () {
      const map = (u) => {
        try {
          if (u == null) return u;
          const s = String(u);
          if (/^https:\/\//i.test(s)) return 'vnets://' + s.slice(8);
          if (/^http:\/\//i.test(s)) return 'vnet://' + s.slice(7);
          if (s.startsWith('//')) return location.protocol + s;
          return s;
        } catch (e) { return u; }
      };
      const of = window.fetch;
      if (of) window.fetch = function (input, init) {
        if (typeof input === 'string' || input instanceof URL) input = map(input);
        else if (input && input.url && /^(https?:)?\/\//i.test(input.url)) input = new Request(map(input.url), input);
        return of.call(this, input, init);
      };
      const oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u, ...rest) { return oo.call(this, m, map(u), ...rest); };
      const props = [[window.HTMLImageElement, 'src'], [window.HTMLScriptElement, 'src'], [window.HTMLLinkElement, 'href'],
                     [window.HTMLIFrameElement, 'src'], [window.HTMLSourceElement, 'src'], [window.HTMLMediaElement, 'src']];
      for (const [C, p] of props) {
        if (!C) continue;
        const d = Object.getOwnPropertyDescriptor(C.prototype, p);
        if (d && d.set) Object.defineProperty(C.prototype, p, { get: d.get, set(v) { d.set.call(this, map(v)); }, configurable: true, enumerable: d.enumerable });
      }
      const sa = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (n, v) {
        const ln = String(n).toLowerCase();
        if (ln === 'src' || ln === 'href' || ln === 'action' || ln === 'poster') v = map(v);
        else if (ln === 'srcset' && v) v = String(v).replace(/https:\/\//gi, 'vnets://').replace(/http:\/\//gi, 'vnet://');
        return sa.call(this, n, v);
      };
      const wo = window.open;
      window.open = function (u, ...rest) { return wo.call(this, map(u), ...rest); };
    })();
    """#

    /// 知らせの名前（window.webkit.messageHandlers.<この名前>）
    static let cookieHandlerName = "vnetCookie"
    /// エラーページのボタン・守りのスクリプトからの知らせ
    static let actionHandlerName = "velaAction"

    /// JavaScript が Cookie を変えたこと（document.cookie・cookieStore）を、アプリに「合図」だけ知らせる。
    /// Cookie の中身は送らない・信じない（HttpOnly や Domain を偽れるため）。アプリは合図を受けて、WebKit の置き場（正本）を読み直す
    static let watchCookies = #"""
    (function () {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vnetCookie;
        if (!h) return;
        let queued = false;
        const tell = () => {
          if (queued) return;
          queued = true;
          setTimeout(() => { queued = false; try { h.postMessage({}); } catch (e) {} }, 50);
        };
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (d && d.set) {
          Object.defineProperty(Document.prototype, 'cookie', {
            get: d.get,
            set(v) { d.set.call(this, v); tell(); },
            configurable: true, enumerable: d.enumerable
          });
        }
        const cs = window.cookieStore;
        if (cs && cs.set) {
          const os = cs.set.bind(cs), od = cs.delete ? cs.delete.bind(cs) : null;
          cs.set = function (a, b) { const r = os(a, b); Promise.resolve(r).then(tell, tell); return r; };
          if (od) cs.delete = function (a) { const r = od(a); Promise.resolve(r).then(tell, tell); return r; };
        }
      } catch (e) {}
    })();
    """#

    /// LAN の保護（WebSocket）: WebSocket は VNet を通らないので、ページの中で止める。
    /// 公開のサイトのページから、数字の LAN のアドレス・localhost・.local への WebSocket を拒否する。
    /// 限界: ホスト名で LAN に解決されるものは分からない。スクリプトの守りは、ページに回避される可能性がある
    static let webSocketGuard = #"""
    (function () {
      try {
        const W = window.WebSocket;
        if (!W) return;
        const isLocal = (h) => {
          h = String(h || '').toLowerCase().replace(/^\[|\]$/g, '');
          return /^(10|127)\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) ||
                 /^172\.(1[6-9]|2[0-9]|3[01])\./.test(h) || /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./.test(h) ||
                 h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') ||
                 h === '::1' || /^f[cd][0-9a-f]{2}:/.test(h) || /^fe[89ab][0-9a-f]:/.test(h);
        };
        let pageLocal = false;
        try { pageLocal = isLocal(window.top.location.hostname); } catch (e) { pageLocal = isLocal(location.hostname); }
        if (pageLocal) return;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.velaAction;
        const Guarded = function WebSocket(url, protocols) {
          let host = '';
          try { host = new URL(url, location.href).hostname; } catch (e) {}
          if (isLocal(host)) {
            try { h && h.postMessage({ action: 'blockedWebSocket', url: String(url) }); } catch (e) {}
            throw new DOMException('Vela: 公開のサイトから LAN への WebSocket は止めました', 'SecurityError');
          }
          return protocols === undefined ? new W(url) : new W(url, protocols);
        };
        Guarded.prototype = W.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Guarded[k] = W[k];
        window.WebSocket = Guarded;
      } catch (e) {}
    })();
    """#

    /// LAN の保護（標準の通信のタブと WebSocket 用）: WebKit のルールで、LAN でないページから数字の LAN のアドレスなどへの読み込みを止める。
    /// トップのページが LAN のもの（ユーザーがアドレス欄で開いた機器のページなど）なら止めない。
    /// WebKit の正規表現は「|」が使えないので、アドレスの範囲ごとに 1 行にする
    static let localNetworkPatterns: [String] = [
        #"^[a-z]+://10\."#, #"^[a-z]+://127\."#, #"^[a-z]+://192\.168\."#, #"^[a-z]+://169\.254\."#,
        #"^[a-z]+://172\.1[6-9]\."#, #"^[a-z]+://172\.2[0-9]\."#, #"^[a-z]+://172\.3[01]\."#,
        #"^[a-z]+://localhost[:/]"#, #"^[a-z]+://[a-z0-9.-]*\.local[:/]"#,
        #"^[a-z]+://\[::1\]"#, #"^[a-z]+://\[f[cd]"#, #"^[a-z]+://\[fe[89ab]"#,
    ]

    static var localNetworkRules: String {
        let quoted = localNetworkPatterns.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\") + "\"" }
        let unless = "[" + quoted.joined(separator: ",") + "]"
        let rules = quoted.map { #"{"trigger":{"url-filter":\#($0),"unless-top-url":\#(unless)},"action":{"type":"block"}}"# }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

/// ページのスクリプト（PageScripts.watchCookies）からの「Cookie が変わったかも」という合図を受ける。
/// 中身は受け取らない。合図を受けたら onSignal（WebKit の置き場を読み直す）
final class CookieBridge: NSObject, WKScriptMessageHandler {
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 合図を受けたとき（画面のスレッドで呼ばれる）
    var onSignal: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let o = message.frameInfo.securityOrigin
        log?("🍪 ページの JavaScript が Cookie を変えました（\(o.protocol)://\(o.host)\(o.port == 0 ? "" : ":\(o.port)")）")
        onSignal?()
    }
}

/// エラーページのボタン・守りのスクリプトからの知らせを受ける
final class PageActionBridge: NSObject, WKScriptMessageHandler {
    /// (中身, メインフレームか, 送ってきたページのオリジン)。画面のスレッドで呼ばれる
    var onAction: (([String: Any], Bool, String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        let o = message.frameInfo.securityOrigin
        onAction?(d, message.frameInfo.isMainFrame, "\(o.protocol)://\(o.host)")
    }
}

/// WebKit の Cookie の置き場（正本）と CookieJar（写し）をそろえる
@MainActor
final class WebCookieSync: NSObject, WKHTTPCookieStoreObserver {
    let store: WKHTTPCookieStore
    let jar: CookieJar
    var log: (@Sendable (String) -> Void)?
    private var refreshScheduled = false
    /// WebKit の置き場に入れている途中の数（その間は写しを作り直さない。入れる前の中身で上書きしないため）
    private var pushing = 0
    private var refreshAfterPush = false

    init(store: WKHTTPCookieStore, jar: CookieJar) {
        self.store = store
        self.jar = jar
        super.init()
        store.add(self)
        refresh()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.scheduleRefresh() }
    }

    /// 少し待ってから読み直す（続けて変わったときに、何度も読まないように）
    func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let me = self
            Task { @MainActor in
                me?.refreshScheduled = false
                me?.refresh()
            }
        }
    }

    func refresh() {
        if pushing > 0 { refreshAfterPush = true; return }
        let s = store, j = jar
        Task { @MainActor in
            let all = await s.allCookies()
            j.replaceAll(all.compactMap { CookieRecord(httpCookie: $0) })
        }
    }

    /// VNet が受け取った Cookie の変更を、WebKit の置き場にも入れる
    func apply(_ changes: [CookieChange]) async {
        pushing += 1
        for ch in changes {
            guard let c = ch.record.httpCookie() else { log?("🍪 WebKit に渡せない Cookie: \(ch.record.name)"); continue }
            if ch.delete { await store.deleteCookie(c) } else { await store.setCookie(c) }
        }
        pushing -= 1
        if pushing == 0 && refreshAfterPush { refreshAfterPush = false; refresh() }
    }
}
