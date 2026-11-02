import SwiftUI
import WebKit

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
