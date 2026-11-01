import SwiftUI
import WebKit

// MARK: - ブラウザの中身: WKWebView と自作の通信（VNetMachine）をつなぐ
//
// ふつうは https・http の読み込みを全部 VNetScheme が引き受ける（HTTPSTakeover）。
// それができないときは予備の作り: WKWebView には「vnets://…」（https）・「vnet://…」（http）という自分用のアドレスで読ませ、
// ・ページの中の「https://…」の部品（画像・CSS など）も、HTML と CSS を書き換えて自作の通信で読む
// ・JavaScript が作るアドレス（fetch・XMLHttpRequest・img.src など）も、ページに入れた小さなスクリプトで書き換える
// ・それでも直接読もうとするものは止める（実験なので、混ざらないように）

/// ログをためておく（どのスレッドからでも足せる。画面には 0.3 秒ごとにまとめて出す。毎回出すと重い）
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var dirty = false
    let maxLines = 200

    func add(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        dirty = true
        lock.unlock()
    }

    /// 変わっていれば全部を 1 つの文字列にして返す
    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        if !dirty { return nil }
        dirty = false
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = "https://example.com/"
    @Published var logText = ""
    @Published var status = "準備中…"
    @Published var pageTitle = ""
    let webView: WKWebView
    let machine = VNetMachine(factory: NWUserNetFactory())
    /// true: https://… をそのまま自作の通信で読む。false: 予備の vnets://… の作り
    let direct: Bool
    private let scheme = VNetScheme()
    private let cookies = CookieBridge()
    private let logs = LogBuffer()
    private var timer: Timer?
    private var logTimer: Timer?

    override init() {
        let config = WKWebViewConfiguration()
        direct = HTTPSTakeover.install()
        let content = config.userContentController
        if direct {
            config.setURLSchemeHandler(scheme, forURLScheme: "https")
            config.setURLSchemeHandler(scheme, forURLScheme: "http")
        } else {
            config.setURLSchemeHandler(scheme, forURLScheme: "vnet")
            config.setURLSchemeHandler(scheme, forURLScheme: "vnets")
            content.addUserScript(WKUserScript(source: PageScripts.rewriteURLs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // クッキー: ページの JavaScript が作ったものをアプリにも知らせる
        content.addUserScript(WKUserScript(source: PageScripts.watchCookies, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.add(cookies, name: PageScripts.cookieHandlerName)
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
        scheme.machine = machine
        scheme.pushCookies = { [weak self] lines, done in
            let model = self
            Task { @MainActor in
                await model?.pushCookies(lines)
                done()
            }
        }
        webView.navigationDelegate = self
        if direct {
            logs.add("https・http をそのまま自作の通信で読みます（アドレスは本物の https://…）")
        } else {
            logs.add("https を引き受けられませんでした。vnets://… の作りで読みます")
            blockDirectLoads()
        }
        let m = machine
        let lb = logs
        machine.log = { s in lb.add(s) }
        scheme.log = { s in lb.add(s) }
        cookies.log = { s in lb.add(s) }
        // 自作の通信で送る User-Agent も同じもの（ページの JavaScript から見えるものと食い違うと、ロボットだと思われる）
        m.setUserAgent(BrowserIdentity.userAgent)
        m.boot()
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
        let ip = machine.stack.ready ? "IP \(machine.stack.ip.ipString)" : "IP をもらっています…"
        status = "\(ip)・\(machine.stats())"
    }

    /// サーバーから届いたクッキーを、ブラウザ（WebKit）の置き場にも入れる（ページの JavaScript から document.cookie で見えるように）
    func pushCookies(_ lines: [CookieLine]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for l in lines {
            guard let real = VNetURL.toReal(l.url) else { continue }
            for c in CookieSync.parse(l.header, url: real) {
                if let e = c.expiresDate, e <= Date() { await store.deleteCookie(c) } else { await store.setCookie(c) }
            }
        }
    }

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let u = URL(string: text), let v = direct ? Optional(u) : VNetURL.toVNet(u) else { addLog("アドレスが正しくありません"); return }
        addLog("―― \(text) を開きます ――")
        webView.load(URLRequest(url: v))
    }

    // MARK: WKNavigationDelegate

    // リンクを押したとき: https:// などのアドレスなら、自作の通信のアドレスに直して開き直す（vnets:// の作りのときだけ）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if direct { return .allow }
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
}
