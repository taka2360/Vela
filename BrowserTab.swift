import SwiftUI
import WebKit

// MARK: - タブ 1 枚
//
// ・WKWebView は必要なときだけ作る（ensureWebView）。見ていない間に捨てられたら（suspend）、スナップショットと
//   戻る/進むの履歴（interactionState）だけを持っておき、次に見るときに作り直して戻す
// ・WebView の状態（URL・タイトル・読み込みの進み具合・戻れるか）は KVO で受け取る
// ・通信の作り（VNet / 標準）は WebView を作るときにしか決められないので、切り替えは作り直しで行う
// ・捨てるときは、デリゲート・スクリプトの受け口・KVO を外して、読み込み中の要求を止める（循環参照と漏れを防ぐ）

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    enum LifeState: String {
        case live = "動いている"
        case suspended = "休止中"
        case crashed = "落ちた"
    }

    let id: Int
    private weak var store: BrowserStore?
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isSecure = false
    @Published private(set) var mode: NetMode
    @Published private(set) var state = LifeState.suspended
    @Published private(set) var snapshot: UIImage?
    /// このページが使った、VNet を通らない通信（"WebSocket" など）
    @Published private(set) var nonVNetUsage: Set<String> = []
    /// 最後に見た時刻（WebView を捨てる順番を決める）
    var lastSelected = Date()

    private(set) var webView: WKWebView?
    /// VNet のタブの、要求を引き受ける部品（タブごとに 1 つ。通信の machine は共有）
    private(set) var scheme: VNetScheme?
    private var delegate: TabWebDelegate?
    private var observations: [NSKeyValueObservation] = []
    private let cookies = CookieBridge()
    private let actions = PageActionBridge()
    private var refresh: UIRefreshControl?
    /// 休止中のときの、戻る/進むの履歴（WKWebView.interactionState）と開く URL
    private var savedState: Data?
    private var pendingURL: URL?

    init(id: Int, store: BrowserStore, mode: NetMode) {
        self.id = id
        self.store = store
        self.mode = mode
    }

    private func log(_ s: String, level: LogLevel = .info, category: LogCategory = .nav) {
        store?.logs.add(s, level: level, category: category, tab: id)
    }

    // MARK: WebView を作る・捨てる

    /// 見るときに呼ぶ。WebView が無ければ作って、休止中の履歴を戻す
    func ensureWebView() {
        if let wv = webView {
            // 見ていない間にページのプロセスが落ちていた: 見るときに読み直す
            if state == .crashed {
                log("落ちていたページを読み直します")
                wv.reload()
                state = .live
            }
            return
        }
        let wv = makeWebView(configuration: nil, scheme: nil)
        if let s = savedState {
            wv.interactionState = s as NSData
            savedState = nil
            log("休止中の履歴から戻しました")
        } else if let u = pendingURL ?? url {
            pendingURL = nil
            load(u, userInitiated: true)
        }
        state = .live
    }

    /// ページが開いた新しい窓。WebKit が渡した設定で作る（設定を変えると WebKit が止まるので、そのまま使う）
    func adopt(configuration: WKWebViewConfiguration, scheme opener: VNetScheme?) -> WKWebView {
        let wv = makeWebView(configuration: configuration, scheme: opener)
        state = .live
        return wv
    }

    private func makeWebView(configuration given: WKWebViewConfiguration?, scheme opener: VNetScheme?) -> WKWebView {
        let config: WKWebViewConfiguration
        if let given {
            config = given
            scheme = opener
        } else {
            config = makeConfiguration()
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        // User-Agent を iPad の Safari と同じにする。WKWebView の初期値には「Version/… Safari/…」が無く、
        // アプリの中のブラウザやロボットだと思われて、エラーや「不審なトラフィック」の画面になりやすい
        wv.customUserAgent = BrowserIdentity.userAgent
        wv.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { wv.isInspectable = VelaSettings.webInspector }
        let d = TabWebDelegate(tab: self)
        wv.navigationDelegate = d
        wv.uiDelegate = d
        delegate = d
        // 引っ張って再読み込み
        let rc = UIRefreshControl()
        rc.addAction(UIAction { [weak self, weak rc] _ in
            self?.webView?.reload()
            rc?.endRefreshing()
        }, for: .valueChanged)
        wv.scrollView.refreshControl = rc
        refresh = rc
        observe(wv)
        webView = wv
        log("WebView を作りました（\(mode.rawValue)）")
        return wv
    }

    /// 通信の作りに合わせた設定（スキームの引き受け・スクリプト・ルール）
    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        if mode.usesVNet, let store {
            let s = VNetScheme()
            s.machine = store.machine
            s.hsts = store.hsts
            let tabID = id
            let lb = store.logs
            s.log = { m in lb.add(m, tab: tabID) }
            s.pushCookies = { [weak store] changes, done in
                let st = store
                Task { @MainActor in
                    await st?.pushCookies(changes)
                    done()
                }
            }
            scheme = s
            if mode == .vnetDirect {
                config.setURLSchemeHandler(s, forURLScheme: "https")
                config.setURLSchemeHandler(s, forURLScheme: "http")
            } else {
                config.setURLSchemeHandler(s, forURLScheme: "vnet")
                config.setURLSchemeHandler(s, forURLScheme: "vnets")
                content.addUserScript(WKUserScript(source: PageScripts.rewriteURLs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            // Cookie: ページの JavaScript が変えたら「合図」だけもらって、WebKit の置き場（正本）を読み直す
            content.addUserScript(WKUserScript(source: PageScripts.watchCookies, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            cookies.log = { m in lb.add(m, tab: tabID) }
            cookies.onSignal = { [weak store] in
                let st = store
                Task { @MainActor in st?.cookiesChangedByPage() }
            }
            content.add(cookies, name: PageScripts.cookieHandlerName)
        } else {
            scheme = nil
        }
        // LAN の保護: WebSocket は VNet を通らないので、ページの中でも止める
        if VelaSettings.localNetworkProtection {
            content.addUserScript(WKUserScript(source: PageScripts.webSocketGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // VNet を通らない通信（WebSocket）を使ったら知らせてもらう
        content.addUserScript(WKUserScript(source: PageScripts.trackNonVNet, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        actions.onAction = { [weak self] body, isMain, origin in
            let tab = self
            Task { @MainActor in tab?.handleAction(body, isMainFrame: isMain, origin: origin) }
        }
        content.add(actions, name: PageScripts.actionHandlerName)
        for r in store?.ruleLists(for: mode) ?? [] { content.add(r) }
        // 動画: 全画面にせずページの中で再生する・自動再生を許す
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // iPad の Safari と同じ「デスクトップ用の表示」にする（User-Agent と、ページから見える端末の情報を揃えるため）
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        return config
    }

    /// WebKit のルールを後から足す（コンパイルが終わったとき）
    func addRuleList(_ list: WKContentRuleList, onlyVNetsLegacy: Bool) {
        if onlyVNetsLegacy && mode != .vnetsLegacy { return }
        webView?.configuration.userContentController.add(list)
    }

    private func observe(_ wv: WKWebView) {
        // KVO の知らせは画面のスレッドで来るが、閉包は MainActor の外なので、Task で戻ってから触る
        let sync: (WKWebView) -> Void = { [weak self] _ in
            let tab = self
            Task { @MainActor in tab?.syncFromWebView() }
        }
        observations = [
            wv.observe(\.url, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.title, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.estimatedProgress, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.isLoading, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.canGoBack, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.canGoForward, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.hasOnlySecureContent, options: [.new]) { w, _ in sync(w) },
        ]
    }

    func syncFromWebView() {
        guard let wv = webView else { return }
        let real = wv.url.flatMap { VNetURL.toReal($0) } ?? wv.url
        if real != url, real != nil {
            url = real
            nonVNetUsage = []
        }
        title = wv.title ?? ""
        progress = wv.estimatedProgress
        isLoading = wv.isLoading
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        isSecure = wv.hasOnlySecureContent && (real?.scheme?.lowercased() == "https")
    }

    /// WebView を捨てて休止する（スナップショット・履歴・URL は残す）
    func suspend(reason: String) {
        guard let wv = webView else { return }
        if let st = wv.interactionState as? Data { savedState = st } else if let st = wv.interactionState as? NSData { savedState = st as Data }
        pendingURL = url
        log("休止します（\(reason)）")
        tearDownWebView()
        state = .suspended
    }

    /// タブを閉じるとき
    func tearDown() {
        store?.cancelDialogs(for: self)
        tearDownWebView()
    }

    private func tearDownWebView() {
        guard let wv = webView else { return }
        observations = []
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        let content = wv.configuration.userContentController
        content.removeScriptMessageHandler(forName: PageScripts.cookieHandlerName)
        content.removeScriptMessageHandler(forName: PageScripts.actionHandlerName)
        wv.scrollView.refreshControl = nil
        wv.removeFromSuperview()
        webView = nil
        delegate = nil
        refresh = nil
        scheme = nil
        isLoading = false
        progress = 0
    }

    func takeSnapshot() {
        guard let wv = webView, wv.bounds.width > 0 else { return }
        wv.takeSnapshot(with: nil) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    // MARK: 読み込み

    /// 開く。userInitiated: ユーザーの操作（アドレス欄・ブックマークなど）か（LAN の保護・SameSite の判定に使う）
    func load(_ u: URL, userInitiated: Bool) {
        guard let wv = webView else {
            pendingURL = u
            url = u
            savedState = nil
            return
        }
        var target = u
        if mode == .vnetsLegacy {
            guard let v = VNetURL.toVNet(u) else { log("vnets:// にできないアドレスです: \(u.absoluteString)", level: .warning); return }
            target = v
        }
        if userInitiated { scheme?.noteUserNavigation(target) }
        url = u
        nonVNetUsage = []
        wv.load(URLRequest(url: target))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { if webView == nil { ensureWebView() } else { webView?.reload() } }
    func stop() { webView?.stopLoading() }

    /// 戻る/進むの履歴の項目へ
    func go(to item: WKBackForwardListItem) { webView?.go(to: item) }

    /// 通信の作りを変える（同じ URL で WebView を作り直す）
    func switchMode(to m: NetMode) {
        guard m != mode else { return }
        let u = url
        log("通信を \(mode.rawValue) → \(m.rawValue) に切り替えます")
        tearDownWebView()
        savedState = nil
        mode = m
        pendingURL = u
        ensureWebView()
        store?.saveSession()
    }

    // MARK: 保存

    func saved() -> SavedTab {
        var st = savedState
        if let wv = webView {
            if let d = wv.interactionState as? Data { st = d } else if let d = wv.interactionState as? NSData { st = d as Data }
        }
        return SavedTab(id: id, url: url?.absoluteString, title: title, mode: mode, state: st)
    }

    func restore(from s: SavedTab) {
        url = s.url.flatMap { URL(string: $0) }
        title = s.title
        savedState = s.state
        pendingURL = url
        state = .suspended
    }

    // MARK: WebKit からの知らせ（TabWebDelegate から）

    func navigationEvent(_ s: String, level: LogLevel = .info) {
        log(s, level: level)
    }

    func didFinish() {
        syncFromWebView()
        store?.saveSession()
    }

    func processTerminated() {
        log("⚠️ ページのプロセスが落ちました", level: .warning)
        if store?.selectedTab === self {
            webView?.reload()
        } else {
            state = .crashed
        }
    }

    func openInNewTab(_ u: URL, select: Bool) {
        store?.newTab(url: u, select: select, mode: mode, after: self)
    }

    func popup(configuration: WKWebViewConfiguration) -> WKWebView? {
        store?.adoptPopup(configuration: configuration, opener: self)
    }

    func closeByPage() {
        log("ページがタブを閉じました（window.close）")
        store?.close(self)
    }

    func presentDialog(_ kind: JSDialog.Kind, message: String, frame: WKFrameInfo, respond: @escaping (Bool, String?) -> Void) {
        let o = frame.securityOrigin
        let origin = "#\(id) \(o.host.isEmpty ? (url?.host ?? "") : o.host)"
        store?.presentDialog(JSDialog(kind: kind, message: message, origin: origin, respond: respond))
    }

    /// エラーページのボタン・守りのスクリプトからの知らせ
    private func handleAction(_ body: [String: Any], isMainFrame: Bool, origin: String) {
        switch body["action"] as? String {
        case "allowLocalNetwork":
            // 確認のページ（メインフレーム）からの、合言葉の合っている知らせだけを受け付ける
            guard isMainFrame, let nonce = body["nonce"] as? String, let u = scheme?.consumeConsent(nonce) else {
                log("🛡 LAN の確認: 受け付けない知らせです（\(origin)）", category: .security)
                return
            }
            log("🛡 LAN の確認: ユーザーが許可しました → \(u.absoluteString)", category: .security)
            load(u, userInitiated: true)
        case "blockedWebSocket":
            log("🛡 LAN の保護: WebSocket を止めました（\(origin) → \(body["url"] as? String ?? "?")）", category: .security)
        case "usedWebSocket":
            if !nonVNetUsage.contains("WebSocket") {
                nonVNetUsage.insert("WebSocket")
                log("このページは WebSocket を使っています（VNet を通りません）", category: .net)
            }
        default:
            break
        }
    }
}

// MARK: - WebKit のデリゲート（タブ 1 枚に 1 つ）

@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
        super.init()
    }

    // リンクを押したとき: vnets:// の作りなら、自作の通信のアドレスに直して開き直す
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let tab, tab.mode == .vnetsLegacy else { return .allow }
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https",
           navigationAction.targetFrame?.isMainFrame ?? true, let v = VNetURL.toVNet(u) {
            webView.load(URLRequest(url: v))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.navigationEvent("読み込み開始: \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.syncFromWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.navigationEvent("読み込み完了: \(webView.title ?? "")")
        tab?.didFinish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.navigationEvent("✕ 読み込みに失敗: \(error.localizedDescription)", level: .error)
        tab?.syncFromWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.navigationEvent("✕ 読み込みに失敗: \(error.localizedDescription)", level: .error)
        tab?.syncFromWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.processTerminated()
    }

    // MARK: WKUIDelegate

    /// target=_blank・window.open: 新しいタブにする
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        tab?.popup(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        tab?.closeByPage()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let tab else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            tab.presentDialog(.alert, message: message, frame: frame) { _, _ in c.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let tab else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            tab.presentDialog(.confirm, message: message, frame: frame) { ok, _ in c.resume(returning: ok) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let tab else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            tab.presentDialog(.prompt(defaultText ?? ""), message: prompt, frame: frame) { ok, text in c.resume(returning: ok ? (text ?? "") : nil) }
        }
    }

    /// リンクの長押しメニュー: 「新しいタブで開く」などを足す（WebKit の元のメニューも残す）
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL else { completionHandler(nil); return }
        let real = VNetURL.toReal(link) ?? link
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let open = UIAction(title: "新しいタブで開く", image: UIImage(systemName: "plus.square.on.square")) { _ in
                let d = self
                Task { @MainActor in d?.tab?.openInNewTab(real, select: true) }
            }
            let back = UIAction(title: "裏のタブで開く", image: UIImage(systemName: "square.on.square")) { _ in
                let d = self
                Task { @MainActor in d?.tab?.openInNewTab(real, select: false) }
            }
            let copy = UIAction(title: "リンクをコピー", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = real
            }
            return UIMenu(title: real.absoluteString, children: [open, back, copy] + suggested)
        }
        completionHandler(config)
    }
}
