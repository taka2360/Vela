// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// 元ファイル: MyApp.swift, BrowserView.swift, BrowserModel.swift, VNetScheme.swift, HTTPSTakeover.swift, PageScripts.swift, HTTPClient.swift, HTTPResponseParser.swift, HTTPSupport.swift, TLSClient.swift, GuestStack.swift, GuestTCP.swift, DNSMessage.swift, Packet.swift, VNetMachine.swift, VNetCore.swift, VNetDriver.swift, UserNet.swift, UserNetApple.swift

import SwiftUI
import WebKit
import ObjectiveC
import Foundation
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
struct VNetBrowserApp: App {
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

// ======================================================================
// MARK: - VNetScheme.swift
// ======================================================================

// MARK: - WKWebView の読み込みを引き受けて、自作の通信（VNetMachine）で取ってくる
//
// https:// と http://（予備の作りでは vnets:// と vnet://）の読み込みが全部ここに来る。
// WebKit は画面のスレッドから呼ぶ。こちらも pending は画面のスレッドの上でだけ触る

final class VNetScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var machine: VNetMachine?
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 届いたクッキーをブラウザの置き場に入れる。入れ終わったら done を呼ぶこと
    var pushCookies: (([CookieLine], _ done: @escaping @Sendable () -> Void) -> Void)?

    /// 読み込み中の要求
    private struct Pending {
        let task: WKURLSchemeTask
        /// WebKit が頼んできたアドレス（vnets://… か https://…）。移動（リダイレクト）すると変わる
        var shownURL: URL
        /// 本当に読みに行くアドレス（https://…）
        var realURL: URL
        let origin: String?
        let started: Date
        /// WebKit からの要求（移動のときに、次の要求を作るのに使う）
        var request: URLRequest
        var body: Data?
        var redirects = 0
        /// 移動（3xx）を WebKit に伝えられるか。できないときは、自分で追いかけて最後の返事だけ渡す
        var webKitRedirects: Bool
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    static let maxRedirects = 20

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        start(task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        pending[ObjectIdentifier(task)] = nil
    }

    private func start(_ task: WKURLSchemeTask) {
        guard let shown = task.request.url, let real = VNetURL.toReal(shown), let machine else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let origin = task.request.value(forHTTPHeaderField: "Origin")
        // 下調べ（CORS の OPTIONS）は、ここで「何でも良い」と答える
        if task.request.httpMethod == "OPTIONS" {
            respond(task, url: shown, status: 204, type: "text/plain", body: Data(), origin: origin)
            return
        }
        let body = VNetScheme.body(of: task.request)
        let req = VNetScheme.makeRequest(task.request, url: real, body: body)
        let id = ObjectIdentifier(task)
        let webKitRedirects = SchemeTaskRedirect.isAvailable(task)
        pending[id] = Pending(task: task, shownURL: shown, realURL: real, origin: origin, started: Date(),
                              request: task.request, body: body, webKitRedirects: webKitRedirects)
        fetch(id, req, followRedirects: !webKitRedirects, machine: machine)
    }

    private func fetch(_ id: ObjectIdentifier, _ req: HTTPRequest, followRedirects: Bool, machine: VNetMachine) {
        machine.send(req, followRedirects: followRedirects) { [weak self] result in
            let me = self   // weak の self は var なので、並行で動く閉包からは直接さわれない。let に受け直す
            DispatchQueue.main.async { me?.finish(id, result) }
        }
    }

    private func finish(_ id: ObjectIdentifier, _ result: Result<HTTPResult, FetchError>) {
        guard pending[id] != nil else { return }
        // クッキーが届いていたら、先にブラウザの置き場に入れてから返事を渡す（ページがすぐ document.cookie を読んでも間に合うように）
        if case .success(let r) = result, !r.cookieLines.isEmpty, let pushCookies {
            pushCookies(r.cookieLines) { [weak self] in
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
        // 移動（3xx）: WebKit に「移動した」と伝える（アドレス・相対リンク・オリジン・クッキーが移動先のものになる）
        if case .success(let r) = result, p.webKitRedirects, HTTPPool.redirectStatuses.contains(r.status),
           p.redirects < VNetScheme.maxRedirects, let loc = r.header("Location"),
           let next = URL(string: loc, relativeTo: p.realURL)?.absoluteURL,
           let s = next.scheme?.lowercased(), s == "http" || s == "https" {
            redirect(id, p, r, to: next)
            return
        }
        pending[id] = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        let real = p.realURL
        switch result {
        case .failure(let e):
            log?("✕ \(real.absoluteString)：\(e.description)")
            let html = "<html><body style='font:16px -apple-system;padding:20px'><h3>読めませんでした</h3><p>\(real.absoluteString)</p><p>\(e.description)</p></body></html>"
            respond(p.task, url: p.shownURL, status: 502, type: "text/html; charset=utf-8", body: Data(html.utf8), origin: p.origin)
        case .success(let r):
            let range = r.header("Content-Range").map { "・\($0)" } ?? ""
            log?("✓ \(r.status) \(real.absoluteString)（\(r.body.count / 1024)KB・\(ms)ms\(range)）")
            var type = VNetScheme.contentType(r, real: real)
            var body = r.body
            // vnets:// の作りのときだけ: HTML と CSS の中の https:// を vnets:// に書き換える（部品も自作の通信で読むため）
            // （https をそのまま引き受けているときは、書き換えなくても全部ここに来る）
            let viaVNet = VNetURL.isVNet(p.shownURL)
            let lower = type.lowercased()
            if viaVNet && (lower.contains("text/html") || lower.contains("text/css")) {
                body = VNetScheme.rewriteLinks(body)
                if !lower.contains("charset") { type += "; charset=utf-8" }
            }
            // 移動した先のアドレスで表示する（相対アドレスがずれないように）
            let shown = r.url == real ? p.shownURL : (viaVNet ? (VNetURL.toVNet(r.url) ?? p.shownURL) : r.url)
            respond(p.task, url: shown, status: r.status, type: type, body: body, origin: p.origin, extra: r.headers)
        }
    }

    // MARK: 移動（リダイレクト）

    /// 3xx を WebKit に伝える。WebKit が次の要求を返してきたら、それを読みに行く
    private func redirect(_ id: ObjectIdentifier, _ p: Pending, _ r: HTTPResult, to next: URL) {
        let nextShown = VNetURL.isVNet(p.shownURL) ? (VNetURL.toVNet(next) ?? next) : next
        log?("↪ \(r.status) \(p.realURL.absoluteString) → \(next.absoluteString)")
        var h = VNetScheme.responseHeaders(type: VNetScheme.contentType(r, real: p.realURL), length: 0, origin: p.origin, extra: r.headers)
        h["Location"] = nextShown.absoluteString
        // 次の要求: 303（と POST の 301・302）は GET に変える。前の相手のクッキーは付けない（WebKit が付け直す）
        var method = p.request.httpMethod ?? "GET"
        var body = p.body
        var drop: Set<String> = ["cookie"]
        if r.status == 303 || ((r.status == 301 || r.status == 302) && method == "POST") {
            if method != "HEAD" { method = "GET" }
            body = nil
            drop.formUnion(["content-type", "content-length", "origin"])
        }
        let nr = NSMutableURLRequest(url: nextShown)
        nr.httpMethod = method
        nr.allHTTPHeaderFields = (p.request.allHTTPHeaderFields ?? [:]).filter { !drop.contains($0.key.lowercased()) }
        nr.httpBody = body
        nr.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? nextShown : p.request.mainDocumentURL
        guard let resp = HTTPURLResponse(url: p.shownURL, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: h),
              SchemeTaskRedirect.perform(p.task, response: resp, request: nr, done: { [weak self] newReq in
                  let me = self
                  DispatchQueue.main.async { me?.afterRedirect(id, newReq, body: body) }
              }) else {
            // 伝えられなかった: 前のやり方（自分で追いかけて、最後の返事だけ渡す）
            pending[id]?.webKitRedirects = false
            if let machine { fetch(id, VNetScheme.makeRequest(p.request, url: p.realURL, body: p.body), followRedirects: true, machine: machine) }
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
        let b = newReq.httpBody ?? body
        p.shownURL = u
        p.realURL = real
        p.request = r
        p.body = b
        p.redirects += 1
        pending[id] = p
        fetch(id, VNetScheme.makeRequest(r, url: real, body: b), followRedirects: false, machine: machine)
    }

    // MARK: 要求を作る

    /// WebKit の要求を、自作の通信の要求にする
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

    /// だいたいの「サイト」（example.co.jp → example.co.jp、www.example.com → example.com）
    static func siteOf(_ host: String) -> String {
        let l = host.split(separator: ".")
        if l.count <= 2 { return host }
        let n = l[l.count - 1].count == 2 && l[l.count - 2].count <= 3 ? 3 : 2
        return l.suffix(n).joined(separator: ".")
    }

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

    /// 相手の返事のヘッダのうち、WebKit にそのまま渡さないもの（長さ・縮め方は自分で決め直す。安全の決まりは vnets:// と合わない）
    static let dropHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "content-type", "connection",
                                           "keep-alive", "set-cookie", "set-cookie2", "content-security-policy",
                                           "content-security-policy-report-only", "strict-transport-security",
                                           "x-frame-options", "alt-svc", "location"]

    /// 返事のヘッダ: 相手のヘッダ（動画に要る Content-Range・Accept-Ranges など）＋ 長さ・種類 ＋ CORS は何でも良い
    static func responseHeaders(type: String, length: Int, origin: String?, extra: [(String, String)]) -> [String: String] {
        var h: [String: String] = [:]
        var names: [String: String] = [:]      // 小文字の名前 → h での名前（同じ名前が何行もあれば「, 」でつなぐ）
        for (k, v) in extra {
            let lk = k.lowercased()
            if dropHeaders.contains(lk) || lk.hasPrefix("access-control-") { continue }
            if let ek = names[lk], let old = h[ek] { h[ek] = old + ", " + v } else { names[lk] = k; h[k] = v }
        }
        h["Content-Type"] = type
        h["Content-Length"] = String(length)
        h["Access-Control-Allow-Origin"] = origin ?? "*"
        h["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS, HEAD"
        h["Access-Control-Allow-Headers"] = "*"
        h["Access-Control-Expose-Headers"] = "*"
        if origin != nil { h["Access-Control-Allow-Credentials"] = "true" }
        return h
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data, origin: String?, extra: [(String, String)] = []) {
        let h = VNetScheme.responseHeaders(type: type, length: body.count, origin: origin, extra: extra)
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
enum HTTPSTakeover {
    // install() からしか触らないので、画面のスレッド（MainActor）に置く
    @MainActor private static var tried = false
    @MainActor private static var ok = false

    /// 1 回だけ行う。うまくいったら true（だめなら vnets:// の作りに戻す）
    @MainActor static func install() -> Bool {
        if tried { return ok }
        tried = true
        guard swap() else { return false }
        ok = !WKWebView.handlesURLScheme("https") && !WKWebView.handlesURLScheme("http")
        return ok
    }

    private static func swap() -> Bool {
        let sel = NSSelectorFromString("handlesURLScheme:")
        guard let m = class_getClassMethod(WKWebView.self, sel) else { return false }
        typealias Orig = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let orig = unsafeBitCast(method_getImplementation(m), to: Orig.self)
        let block: @convention(block) (AnyObject, NSString) -> Bool = { cls, scheme in
            let s = (scheme as String).lowercased()
            if s == "http" || s == "https" { return false }
            return orig(cls, sel, scheme)
        }
        method_setImplementation(m, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
        return true
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

    /// JavaScript が作ったクッキー（document.cookie・cookieStore）をアプリにも知らせる。
    /// アプリは自分の置き場（HTTPCookieStorage）に入れて、自作の通信で送る
    static let watchCookies = #"""
    (function () {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vnetCookie;
        if (!h) return;
        const tell = (c) => { try { h.postMessage({ c: String(c), u: location.href }); } catch (e) {} };
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (d && d.set) {
          Object.defineProperty(Document.prototype, 'cookie', {
            get: d.get,
            set(v) { d.set.call(this, v); tell(v); },
            configurable: true, enumerable: d.enumerable
          });
        }
        const cs = window.cookieStore;
        if (cs && cs.set) {
          const os = cs.set.bind(cs), od = cs.delete ? cs.delete.bind(cs) : null;
          cs.set = function (a, b) {
            const o = typeof a === 'string' ? { name: a, value: b } : (a || {});
            let s = o.name + '=' + (o.value == null ? '' : o.value) + '; path=' + (o.path || '/');
            if (o.domain) s += '; domain=' + o.domain;
            if (o.expires) s += '; expires=' + new Date(o.expires).toUTCString();
            tell(s);
            return os(a, b);
          };
          if (od) cs.delete = function (a) {
            const o = typeof a === 'string' ? { name: a } : (a || {});
            let s = o.name + '=; path=' + (o.path || '/') + '; expires=Thu, 01 Jan 1970 00:00:00 GMT';
            if (o.domain) s += '; domain=' + o.domain;
            tell(s);
            return od(a);
          };
        }
      } catch (e) {}
    })();
    """#
}

/// ページのスクリプト（PageScripts.watchCookies）から届いたクッキーを、自分の置き場に入れる
final class CookieBridge: NSObject, WKScriptMessageHandler {
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let c = d["c"] as? String,
              let us = d["u"] as? String, let u = URL(string: us), let real = VNetURL.toReal(u) else { return }
        CookieSync.store(c, url: real)
        let name = c.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "?"
        log?("🍪 ページ → \(name)（\(real.host ?? "")）")
    }
}

// ======================================================================
// MARK: - HTTPClient.swift
// ======================================================================

// MARK: - 自作の TCP/IP（GuestStack）の上の http / https
//
// 速くするための工夫:
// ・接続を使い回す（HTTP/1.1 の keep-alive）。https は暗号の握手（TLS）に時間がかかるので、とても効く
// ・同じ相手には同時に 6 本まで（ブラウザと同じ）。それ以上は空くまで待つ
// ・名前（DNS）の答えを覚えておく
// ・gzip・br で縮めて送ってもらう（HTML・JavaScript・CSS が数分の 1 になる）
// ほかに: クッキーを覚えて送る・リダイレクトを追いかける・POST も送れる
// 「ロボットだ」と思われないよう、ヘッダは Safari と同じものを、毎回同じ順番で送る
// 返事が来ないまま止まった接続は、時間切れで切る（でないと、その相手への読み込みがずっと止まる）

struct HTTPRequest: Sendable {
    var method = "GET"
    var url: URL
    var headers: [(String, String)] = []
    var body: Data?
}

struct HTTPResult: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var url: URL
    /// 届いた Set-Cookie（リダイレクトの途中の分も）。ブラウザ（WebKit）のクッキーの置き場にも入れるため
    var cookieLines: [CookieLine] = []
    func header(_ name: String) -> String? { headers.value(for: name) }
}

struct FetchError: Error, Sendable, CustomStringConvertible {
    let description: String
    /// TLS 1.3 での握手に失敗した（1.2 に下げてやり直せる）
    var tlsRetryable = false
    init(_ description: String, tlsRetryable: Bool = false) { self.description = description; self.tlsRetryable = tlsRetryable }
}

// MARK: - 1 本の接続

/// 1 本の接続（TCP、https ならその上に TLS）。使い終わったら、次の要求に使い回す
final class HTTPConn: @unchecked Sendable {
    /// 返事を読み終わった（または失敗した）。reusable: 次の要求に使える。gotNothing: 何も届かずに切れた
    typealias Completion = (Result<ResponseParser, FetchError>, _ reusable: Bool, _ gotNothing: Bool) -> Void

    let key: String
    private(set) var alive = true
    private(set) var uses = 0
    /// 最後に何か届いた（または送り始めた）時刻。時間切れを見る
    private var lastActivity = Date()
    /// 使い終わって置き場に戻った時刻
    var idleSince = Date()
    /// 何回目の要求か（時間切れの見張りが、前の要求の分を見ないように）
    private var serial = 0
    private var queue: DispatchQueue?
    /// 返事を待っている間に、これだけ何も届かなければ切る（秒）
    static let timeout: TimeInterval = 30
    private var tcp: GuestTCP?
    private var tls: TLSStream?
    private var ready = false
    private var queued: Data?
    private var parser: ResponseParser?
    private var onDone: Completion?

    init(key: String) { self.key = key }

    func open(stack: GuestStack, ip: [UInt8], port: UInt16, host: String, https: Bool, allowTLS13: Bool = true) {
        queue = stack.queue
        guard https else {
            tcp = stack.connect(ip, port, handler: .init(
                connected: { [weak self] in self?.becameReady() },
                data: { [weak self] d in self?.got(d) },
                closed: { [weak self] err in self?.ended(err) }))
            return
        }
        guard let t = TLSStream(host: host, port: port, allowTLS13: allowTLS13) else { fail("TLS を用意できません"); return }
        tls = t
        t.onReady = { [weak self, weak t] in
            stack.trace?("TLS つながった（\(host)・\(t?.version ?? "")）")
            self?.becameReady()
        }
        t.onData = { [weak self] d in self?.got(d) }
        t.onClosed = { [weak self] err in self?.ended(err) }
        tcp = stack.connect(ip, port, handler: .init(
            connected: { [weak self] in guard let self, let tc = self.tcp else { return }; self.tls?.attach(tc) },
            data: { [weak self] d in self?.lastActivity = Date(); self?.tls?.tcpData(d) },
            closed: { [weak self] err in self?.tls?.tcpClosed(err) }))
    }

    /// 要求を 1 つ送る（返事を読み終わったら done）
    func send(_ bytes: Data, isHead: Bool, done: @escaping Completion) {
        uses += 1
        if !alive { done(.failure(FetchError("接続が閉じています")), false, true); return }
        parser = ResponseParser(isHead: isHead)
        onDone = done
        lastActivity = Date()
        serial += 1
        watch(serial)
        if ready { write(bytes) } else { queued = bytes }
    }

    /// 時間切れの見張り（5 秒ごと）。返事を待っている間に長く何も届かなければ切る
    private func watch(_ s: Int) {
        queue?.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.serial == s, self.onDone != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) < HTTPConn.timeout { self.watch(s); return }
            self.alive = false
            self.finishCurrent(.failure(FetchError("時間切れ（\(Int(HTTPConn.timeout)) 秒なにも届きません）")), reusable: false)
            self.tcp?.abort()
        }
    }

    func close() {
        alive = false
        tcp?.close()
    }

    private func write(_ d: Data) {
        if let tls { tls.write(d) } else { tcp?.write(d) }
    }

    private func becameReady() {
        ready = true
        if let q = queued { queued = nil; write(q) }
    }

    private func got(_ d: Data) {
        lastActivity = Date()
        guard let p = parser else { return }
        p.feed(d)
        if p.complete { finishCurrent(.success(p), reusable: p.keepAlive && alive) }
    }

    private func ended(_ err: String?) {
        alive = false
        guard let p = parser else { return }
        if p.closed() { finishCurrent(.success(p), reusable: false) }
        else if let t = tls, t.handshakeError != 0 {
            let retry = t.triedTLS13 && !t.failedOnCertificate
            finishCurrent(.failure(FetchError(err ?? "TLS の握手に失敗", tlsRetryable: retry)), reusable: false)
        }
        else { finishCurrent(.failure(FetchError(err ?? "途中で切れました")), reusable: false, gotNothing: p.received == 0) }
    }

    private func fail(_ s: String) {
        alive = false
        finishCurrent(.failure(FetchError(s)), reusable: false, gotNothing: true)
    }

    private func finishCurrent(_ r: Result<ResponseParser, FetchError>, reusable: Bool, gotNothing: Bool = false) {
        let cb = onDone
        onDone = nil
        parser = nil
        cb?(r, reusable, gotNothing)
    }
}

// MARK: - 接続の置き場と、要求の受付

/// 接続の置き場（相手ごと）と、要求の受付。すべて stack.queue の上で呼ぶ
final class HTTPPool: @unchecked Sendable {
    let stack: GuestStack
    /// ブラウザ（WebKit）が User-Agent を付けてこなかったときに使う
    var userAgent = BrowserIdentity.userAgent
    let maxPerHost = 6
    let maxRedirects = 8
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    private var idle: [String: [HTTPConn]] = [:]
    private var busy: [String: Int] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    private var dnsCache: [String: (ip: [UInt8], at: Date)] = [:]
    /// TLS 1.3 で握手できなかった相手（次から 1.2 で）
    private var tls12Only = Set<String>()
    /// 使っていない接続を、これより長く置いておかない（相手はたいてい黙って閉じている）
    let idleLimit: TimeInterval = 50
    private(set) var reused = 0, opened = 0

    init(stack: GuestStack) {
        self.stack = stack
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
    }

    /// 送って返事を受け取る（リダイレクトは追いかける）
    /// followRedirects が false なら 3xx もそのまま返す（移動はブラウザ（WebKit）に任せるとき）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, redirects: Int = 0, carried: [CookieLine] = [], done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        sendOnce(req, retry: true) { [weak self] r in
            guard let self else { return }
            guard case .success(var res) = r else { done(r); return }
            if followRedirects, HTTPPool.redirectStatuses.contains(res.status), redirects < self.maxRedirects,
               let loc = res.header("Location"), let next = URL(string: loc, relativeTo: req.url)?.absoluteURL {
                var n = req
                n.url = next
                if res.status == 303 || ((res.status == 301 || res.status == 302) && req.method == "POST") {
                    n.method = "GET"
                    n.body = nil
                    n.headers.removeAll(named: ["content-type", "content-length", "origin"])
                }
                // ブラウザが付けてきたクッキーは前の相手のもの。移動先には自分の置き場から付け直す
                n.headers.removeAll(named: ["cookie"])
                self.stack.trace?("↪ \(res.status) → \(next.absoluteString)")
                self.send(n, redirects: redirects + 1, carried: carried + res.cookieLines, done: done)
                return
            }
            res.cookieLines = carried + res.cookieLines
            done(.success(res))
        }
    }

    private func sendOnce(_ req: HTTPRequest, retry: Bool, done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        guard let host = req.url.host, let scheme = req.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            done(.failure(FetchError("http か https のアドレスではありません"))); return
        }
        let https = scheme == "https"
        if https && !TLSStream.isSupported { done(.failure(FetchError("この環境では https を使えません"))); return }
        let port = UInt16(req.url.port ?? (https ? 443 : 80))
        let key = "\(scheme)://\(host):\(port)"
        let bytes = requestBytes(req, host: host)
        let run: (HTTPConn) -> Void = { [weak self] c in
            c.send(bytes, isHead: req.method == "HEAD") { r, reusable, gotNothing in
                guard let self else { return }
                self.release(c, reusable: reusable)
                switch r {
                case .success(let p):
                    done(.success(self.result(p, url: req.url)))
                case .failure(let e):
                    // TLS 1.3 で握手できなかった: 1.2 でもう一度（この相手は次から 1.2）
                    if e.tlsRetryable && !self.tls12Only.contains(key) {
                        self.tls12Only.insert(key)
                        self.stack.trace?("TLS 1.3 で握手できなかったので 1.2 でやり直します（\(host)）")
                        self.sendOnce(req, retry: retry, done: done)
                    }
                    // 使い回した接続が、相手に閉じられていた: 新しい接続でもう一度
                    else if retry && gotNothing && c.uses > 1 { self.sendOnce(req, retry: false, done: done) }
                    else { done(.failure(e)) }
                }
            }
        }
        acquire(key: key, host: host, port: port, https: https, run: run, fail: { done(.failure($0)) })
    }

    /// 空いている接続を使う。無ければ作る（6 本までなら）。いっぱいなら空くまで待つ
    private func acquire(key: String, host: String, port: UInt16, https: Bool, run: @escaping (HTTPConn) -> Void, fail: @escaping (FetchError) -> Void) {
        while var list = idle[key], let c = list.popLast() {
            idle[key] = list
            if c.alive && Date().timeIntervalSince(c.idleSince) > idleLimit { c.close(); continue }
            if c.alive {
                busy[key, default: 0] += 1
                reused += 1
                run(c)
                return
            }
        }
        if busy[key, default: 0] >= maxPerHost {
            waiting[key, default: []].append { [weak self] in
                self?.acquire(key: key, host: host, port: port, https: https, run: run, fail: fail)
            }
            return
        }
        busy[key, default: 0] += 1
        resolve(host) { [weak self] ip in
            guard let self else { return }
            guard let ip else {
                self.release(key: key)
                fail(FetchError("名前が見つかりません: \(host)"))
                return
            }
            let c = HTTPConn(key: key)
            self.opened += 1
            c.open(stack: self.stack, ip: ip, port: port, host: host, https: https, allowTLS13: !self.tls12Only.contains(key))
            run(c)
        }
    }

    /// 使い終わった接続を戻す（使い回せなければ閉じる）。待っている要求があれば 1 つ進める
    private func release(_ c: HTTPConn, reusable: Bool) {
        if reusable && c.alive { c.idleSince = Date(); idle[c.key, default: []].append(c) } else { c.close() }
        release(key: c.key)
    }

    private func release(key: String) {
        busy[key, default: 1] -= 1
        if var w = waiting[key], !w.isEmpty {
            let next = w.removeFirst()
            waiting[key] = w
            next()
        }
    }

    private func resolve(_ host: String, _ done: @escaping ([UInt8]?) -> Void) {
        if let c = dnsCache[host], Date().timeIntervalSince(c.at) < 300 { done(c.ip); return }
        stack.resolve(host) { [weak self] ip in
            if let ip { self?.dnsCache[host] = (ip, Date()) }
            done(ip)
        }
    }

    /// こちらで決め直すので、ブラウザから来ても送らないヘッダ
    private static let ownHeaders: Set<String> = ["host", "connection", "accept-encoding", "content-length", "user-agent",
                                                  "cookie", "keep-alive", "proxy-connection", "te", "upgrade"]

    /// ヘッダを送る順番（Safari に合わせる）。ここに無い名前は "content-type" の所に、来た順で入れる
    /// （ブラウザから来るヘッダは辞書なので順番がばらばら。毎回順番が変わると、ロボットだと思われやすい）
    private static let headerOrder: [String] = ["host", "origin", "content-type", "accept", "sec-fetch-site", "sec-fetch-dest",
                                                "accept-language", "sec-fetch-mode", "user-agent", "upgrade-insecure-requests",
                                                "referer", "range", "if-none-match", "if-modified-since", "content-length",
                                                "accept-encoding", "cookie", "priority", "connection"]

    private func requestBytes(_ req: HTTPRequest, host: String) -> Data {
        let comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? "/"
        if path.isEmpty { path = "/" }
        if let q = comps?.percentEncodedQuery { path += "?" + q }
        var h: [(String, String)] = [("Host", req.url.port.map { "\(host):\($0)" } ?? host)]
        h += req.headers.filter { !HTTPPool.ownHeaders.contains($0.0.lowercased()) }
        if h.value(for: "Accept") == nil { h.append(("Accept", "*/*")) }
        if h.value(for: "Accept-Language") == nil { h.append(("Accept-Language", BrowserIdentity.acceptLanguage)) }
        // User-Agent はブラウザ（WebKit）が付けてきたものを使う（ページの JavaScript から見える navigator.userAgent と同じにする）
        h.append(("User-Agent", req.headers.value(for: "User-Agent") ?? userAgent))
        // 途中から読む（Range。動画など）ときは縮めてもらわない。縮めると「何バイト目」がずれる
        h.append(("Accept-Encoding", req.headers.value(for: "Range") == nil ? ContentDecoding.acceptEncoding : "identity"))
        if let cookie = CookieSync.header(for: req.url, browserCookies: req.headers.values(for: "Cookie")) {
            h.append(("Cookie", cookie))
        }
        if let b = req.body { h.append(("Content-Length", String(b.count))) }
        else if req.method == "POST" || req.method == "PUT" || req.method == "PATCH" { h.append(("Content-Length", "0")) }
        h.append(("Connection", "keep-alive"))
        let order = HTTPPool.headerOrder
        let other = order.firstIndex(of: "content-type") ?? 0
        let rank = { (name: String) -> Int in order.firstIndex(of: name.lowercased()) ?? other }
        let sorted = h.enumerated().sorted { a, b in
            let ra = rank(a.element.0), rb = rank(b.element.0)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        var s = "\(req.method) \(path) HTTP/1.1\r\n"
        for (_, kv) in sorted { s += "\(kv.0): \(kv.1)\r\n" }
        s += "\r\n"
        var d = Data(s.utf8)
        if let b = req.body { d.append(b) }
        return d
    }

    /// 返事をまとめる（クッキーを覚える・縮めた中身を戻す）
    private func result(_ p: ResponseParser, url: URL) -> HTTPResult {
        var headers = p.headers
        let lines = headers.values(for: "Set-Cookie").map { CookieLine(header: $0, url: url) }
        for l in lines { CookieSync.store(l.header, url: url) }
        var body = Data(p.body)
        if let enc = headers.value(for: "Content-Encoding"), !body.isEmpty {
            if let g = ContentDecoding.decode(body, encoding: enc) {
                body = g
                headers.removeAll(named: ["content-encoding", "content-length"])
            } else {
                stack.trace?("縮めた中身（\(enc)）を戻せませんでした: \(url.absoluteString)")
            }
        }
        headers.removeAll(named: ["transfer-encoding"])
        return HTTPResult(status: p.status, headers: headers, body: body, url: url, cookieLines: lines)
    }
}

// ======================================================================
// MARK: - HTTPResponseParser.swift
// ======================================================================

// MARK: - http の返事を少しずつ読む
//
// ヘッダ → 中身。中身の終わりは「長さ指定（Content-Length）」「chunked」「閉じるまで」のどれか。
// 100 Continue などの途中の返事は読み飛ばす

final class ResponseParser {
    let isHead: Bool
    private(set) var status = 0
    private(set) var headers: [(String, String)] = []
    private(set) var body = [UInt8]()
    private(set) var complete = false
    private(set) var keepAlive = true
    /// 届いたバイト数（何も届かずに切れたかを見るため）
    private(set) var received = 0

    private var head = [UInt8]()
    private var headDone = false
    private enum Mode { case length(Int), chunked, untilClose }
    private var mode = Mode.untilClose
    private enum Chunk { case size, data(Int), dataEnd(Int), trailer }
    private var chunk = Chunk.size
    private var line = [UInt8]()

    init(isHead: Bool) { self.isHead = isHead }

    func feed(_ d: Data) {
        received += d.count
        var bytes = [UInt8](d)
        while !complete && !bytes.isEmpty {
            if headDone {
                bytes = consumeBody(bytes)
                continue
            }
            head.append(contentsOf: bytes)
            guard let end = findHeadEnd() else { return }
            bytes = Array(head[(end + 4)...])
            parseHead(Array(head[0..<end]))
            head = []
            if status >= 100 && status < 200 { headDone = false }     // 100 Continue など: 次のヘッダを読む
        }
    }

    /// 相手が閉じた: 「閉じるまで」の形なら、ここで終わり
    func closed() -> Bool {
        if complete { return true }
        if headDone, case .untilClose = mode { complete = true; keepAlive = false; return true }
        return false
    }

    private func findHeadEnd() -> Int? {
        if head.count < 4 { return nil }
        for i in 0...(head.count - 4) where head[i] == 13 && head[i + 1] == 10 && head[i + 2] == 13 && head[i + 3] == 10 { return i }
        return nil
    }

    private func parseHead(_ headBytes: [UInt8]) {
        headDone = true
        var lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        let parts = first.split(separator: " ")
        status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        headers = lines.compactMap { l -> (String, String)? in
            guard let c = l.firstIndex(of: ":") else { return nil }
            return (String(l[..<c]).trimmingCharacters(in: .whitespaces), String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces))
        }
        let conn = headers.value(for: "Connection")?.lowercased() ?? ""
        keepAlive = first.hasPrefix("HTTP/1.0") ? conn.contains("keep-alive") : !conn.contains("close")
        if status >= 100 && status < 200 { return }
        if isHead || status == 204 || status == 304 { complete = true; return }
        if headers.value(for: "Transfer-Encoding")?.lowercased().contains("chunked") == true { mode = .chunked }
        else if let l = headers.value(for: "Content-Length"), let n = Int(l) { mode = .length(n); if n == 0 { complete = true } }
        else { mode = .untilClose; keepAlive = false }
    }

    /// 中身を読む。余り（次の返事の分。普通は無い）を返す
    private func consumeBody(_ b: [UInt8]) -> [UInt8] {
        switch mode {
        case .untilClose:
            body.append(contentsOf: b)
            return []
        case .length(let n):
            let take = min(n - body.count, b.count)
            body.append(contentsOf: b[0..<take])
            if body.count >= n { complete = true }
            return Array(b[take...])
        case .chunked:
            var i = 0
            while i < b.count && !complete {
                switch chunk {
                case .size, .trailer:
                    let c = b[i]; i += 1
                    guard c == 10 else { line.append(c); continue }
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    line = []
                    if case .trailer = chunk {
                        if text.isEmpty { complete = true }
                    } else {
                        let sizeText = text.split(separator: ";").first.map(String.init) ?? ""
                        let n = Int(sizeText, radix: 16) ?? 0
                        chunk = n == 0 ? .trailer : .data(n)
                    }
                case .data(let remain):
                    let take = min(remain, b.count - i)
                    body.append(contentsOf: b[i..<(i + take)])
                    i += take
                    chunk = remain - take == 0 ? .dataEnd(2) : .data(remain - take)
                case .dataEnd(let k):                          // 中身のあとの \r\n
                    i += 1
                    chunk = k - 1 == 0 ? .size : .dataEnd(k - 1)
                }
            }
            return Array(b[i...])
        }
    }
}

// ======================================================================
// MARK: - HTTPSupport.swift
// ======================================================================

// MARK: - http の小さな道具（ヘッダ・gzip・クッキー）

/// ヘッダ（名前, 値）の並び。名前の大文字小文字は区別しない
extension Array where Element == (String, String) {
    func value(for name: String) -> String? {
        let n = name.lowercased()
        return first { $0.0.lowercased() == n }?.1
    }

    func values(for name: String) -> [String] {
        let n = name.lowercased()
        return filter { $0.0.lowercased() == n }.map { $0.1 }
    }

    /// names は小文字で渡す
    mutating func removeAll(named names: Set<String>) {
        removeAll { names.contains($0.0.lowercased()) }
    }
}

// MARK: 縮めた中身を戻す（gzip・deflate・br）

enum ContentDecoding {
    /// 送る Accept-Encoding（Safari と同じ。br は iOS 15 から）
    static var acceptEncoding: String {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return "gzip, deflate, br" }
        return "gzip, deflate"
        #else
        return "identity"
        #endif
    }

    /// Content-Encoding に従って戻す。知らない形・戻せないときは nil
    static func decode(_ d: Data, encoding: String) -> Data? {
        // "gzip, br" のように重ねてあるときは、後ろから戻す
        var out = d
        for e in encoding.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).reversed() {
            switch e {
            case "", "identity": continue
            case "gzip", "x-gzip": guard let g = gunzip(out) else { return nil }; out = g
            case "deflate": guard let g = inflateZlib(out) else { return nil }; out = g
            case "br": guard let g = brotli(out) else { return nil }; out = g
            default: return nil
            }
        }
        return out
    }

    /// gzip: 前（10 バイト〜）と後ろ（8 バイト）を外して、生の deflate として戻す
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { return nil }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }   // FEXTRA
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                      // FNAME
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                     // FCOMMENT
        if flags & 2 != 0 { p += 2 }                                                                                  // FHCRC
        guard p < b.count else { return nil }
        return inflateRaw(b[p...])
    }

    /// deflate: 本当は zlib の包み（2 バイト＋後ろ 4 バイト）付き。包みの無い生の deflate を送るサーバーもあるので両方受ける
    static func inflateZlib(_ d: Data) -> Data? {
        let b = [UInt8](d)
        if b.count >= 2 && b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return inflateRaw(b[2...]) }
        return inflateRaw(b[...])
    }

    static func inflateRaw(_ b: ArraySlice<UInt8>) -> Data? {
        #if canImport(Compression)
        return stream(b, COMPRESSION_ZLIB)      // Apple の ZLIB は「生の deflate」
        #else
        return nil
        #endif
    }

    static func brotli(_ d: Data) -> Data? {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return stream([UInt8](d)[...], COMPRESSION_BROTLI) }
        #endif
        return nil
    }

    #if canImport(Compression)
    /// 元の大きさが分からなくても戻せるよう、少しずつ戻す
    private static func stream(_ src: ArraySlice<UInt8>, _ algorithm: compression_algorithm) -> Data? {
        if src.isEmpty { return Data() }
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var s = compression_stream(dst_ptr: out, dst_size: 0, src_ptr: UnsafePointer(out), src_size: 0, state: nil)
        guard compression_stream_init(&s, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&s) }
        var result = Data()
        return src.withUnsafeBufferPointer { sb -> Data? in
            guard let base = sb.baseAddress else { return nil }
            s.src_ptr = base
            s.src_size = sb.count
            while true {
                s.dst_ptr = out
                s.dst_size = chunk
                let st = compression_stream_process(&s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - s.dst_size
                if produced > 0 { result.append(out, count: produced) }
                if st == COMPRESSION_STATUS_END { return result }
                // 壊れている・途中で切れている: 戻せた所までを使う（何も戻せなければ失敗）
                if st != COMPRESSION_STATUS_OK || (produced == 0 && s.src_size == 0) { return result.isEmpty ? nil : result }
                if result.count > 256 << 20 { return nil }
            }
        }
    }
    #endif
}

// MARK: ブラウザらしさ（User-Agent・言語）

enum BrowserIdentity {
    /// iPad の Safari（デスクトップ用の表示。iPad の Safari の初期設定と同じ）の User-Agent。
    /// WKWebView の初期値は「Version/… Safari/…」が無く、アプリの中のブラウザやロボットだと思われやすい
    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion).\(v.minorVersion) Safari/605.1.15"
    }()

    /// Accept-Language（端末の言語の順。例: "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"）
    static let acceptLanguage: String = {
        var langs: [String] = []
        for l in Locale.preferredLanguages.prefix(3) {
            let tag = l.replacingOccurrences(of: "_", with: "-")
            if !langs.contains(tag) { langs.append(tag) }
            if let base = tag.split(separator: "-").first.map(String.init), base != tag, !langs.contains(base) { langs.append(base) }
        }
        if langs.isEmpty { langs = ["ja-JP", "ja"] }
        return langs.prefix(6).enumerated().map { i, l in
            i == 0 ? l : "\(l);q=\(String(format: "%.1f", max(0.1, 1.0 - Double(i) * 0.1)))"
        }.joined(separator: ",")
    }()
}

// MARK: クッキー

/// Set-Cookie の 1 行と、それが来たアドレス
struct CookieLine: Sendable {
    let header: String
    let url: URL
}

/// クッキーを自分の置き場（HTTPCookieStorage）に入れる・送る。
/// 期限切れのものは消す（サーバーも JavaScript も「消す」を期限切れで伝える）
enum CookieSync {
    static func parse(_ line: String, url: URL) -> [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
    }

    static func store(_ line: String, url: URL) {
        let st = HTTPCookieStorage.shared
        for c in parse(line, url: url) {
            if let e = c.expiresDate, e <= Date() {
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                for old in st.cookies ?? [] where old.name == c.name && old.path == c.path
                    && (old.domain == d || old.domain == "." + d) {
                    st.deleteCookie(old)
                }
            } else {
                st.setCookie(c)
            }
        }
    }

    /// 送る Cookie ヘッダの中身。ブラウザ（WebKit）が付けてきたものを先に、
    /// 足りない名前を自分の置き場から足す（同じ名前は 1 つだけ）。無ければ nil
    static func header(for url: URL, browserCookies: [String]) -> String? {
        var jar: [String] = []
        var seen = Set<String>()
        for line in browserCookies {
            for part in line.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces)
                guard !kv.isEmpty else { continue }
                let name = kv.split(separator: "=", maxSplits: 1).first.map(String.init) ?? kv
                if seen.insert(name).inserted { jar.append(kv) }
            }
        }
        for c in HTTPCookieStorage.shared.cookies(for: url) ?? [] where seen.insert(c.name).inserted {
            jar.append("\(c.name)=\(c.value)")
        }
        return jar.isEmpty ? nil : jar.joined(separator: "; ")
    }
}

// ======================================================================
// MARK: - TLSClient.swift
// ======================================================================

// MARK: - https の暗号（TLS）を、自作の TCP の上で動かす
//
// iPad の普通の通信の部品（Network.framework）は、自分で作った TCP の上では TLS を使えない。
// そこで、古いけれど今も使える Apple の「SecureTransport」（SSLCreateContext など）を使う。
// これは「読む・書く」を自分で用意できるので、GuestTCP の上で TLS 1.2 を話せる。
// 証明書は iPad と同じ仕組みで確かめる（相手の名前も確かめる）。
// ブラウザらしく見えるよう: ALPN（http/1.1）を名乗る・TLS 1.3 を試す（だめなら呼ぶ側が 1.2 でやり直す）・
// 前の暗号の約束を使い回す（セッション再開。握手が速くなる）
//
// 使い方: TLSStream(host:) を作る → TCP がつながったら attach → onReady で write → onData で中身が届く → onClosed
// SecureTransport が無い環境では TLSStream(host:) が nil を返す（https は使えない）

#if canImport(Security) && os(iOS)
final class TLSStream: @unchecked Sendable {
    static let isSupported = true
    let host: String
    private let ctx: SSLContext
    private var tcp: GuestTCP?
    /// TCP から届いて、まだ TLS に渡していないもの（inbox[inboxPos...]）。先頭を消すと遅いので、位置で覚える
    private var inbox = [UInt8]()
    private var inboxPos = 0
    private var tcpEnded = false
    private var handshaking = true
    private var pendingWrite = Data()
    private var done = false
    /// 握手に失敗したときの番号（0 なら握手の失敗ではない）
    private(set) var handshakeError: OSStatus = 0
    /// TLS 1.3 まで試したか
    private(set) var triedTLS13 = false
    /// 決まった版（"TLS 1.2" など）
    private(set) var version = ""
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    init?(host: String, port: UInt16 = 443, allowTLS13: Bool = true) {
        self.host = host
        guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
        ctx = c
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        if allowTLS13 && SSLSetProtocolVersionMax(ctx, .tlsProtocol13) == errSecSuccess { triedTLS13 = true }
        else { SSLSetProtocolVersionMax(ctx, .tlsProtocol12) }
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
        SSLSetALPNProtocols(ctx, ["http/1.1"] as CFArray)
        let peer = Array("\(host):\(port):\(triedTLS13 ? 13 : 12)".utf8)
        _ = peer.withUnsafeBytes { SSLSetPeerID(ctx, $0.baseAddress, $0.count) }
    }

    /// 証明書の問題での失敗か（版を下げてやり直しても無駄）
    var failedOnCertificate: Bool { handshakeError <= -9807 && handshakeError >= -9815 }

    /// TCP がつながったら呼ぶ
    func attach(_ t: GuestTCP) {
        tcp = t
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        drive()
    }

    /// TCP から届いたもの
    func tcpData(_ d: Data) {
        if inboxPos > 65536 && inboxPos * 2 > inbox.count { inbox.removeFirst(inboxPos); inboxPos = 0 }
        inbox.append(contentsOf: d)
        drive()
    }

    func tcpClosed(_ error: String?) {
        tcpEnded = true
        drive()
        if !done { finish(error ?? (handshaking ? "TLS の途中で切れました" : nil)) }
    }

    /// 暗号にして送る（つながる前なら、つながってから送る）
    func write(_ d: Data) {
        if handshaking { pendingWrite.append(d); return }
        var processed = 0
        _ = d.withUnsafeBytes { SSLWrite(ctx, $0.baseAddress, d.count, &processed) }
    }

    private func finish(_ error: String?) {
        if done { return }
        done = true
        tcp?.abort()
        onClosed?(error)
    }

    /// 進められるところまで進める（握手 → 読む）
    private func drive() {
        if done { return }
        if handshaking {
            let st = SSLHandshake(ctx)
            if st == errSSLWouldBlock { return }
            if st != errSecSuccess {
                handshakeError = st
                finish("TLS の握手に失敗（\(st)）" + (st == errSSLXCertChainInvalid || st == -9807 ? "：証明書を確かめられません" : ""))
                return
            }
            handshaking = false
            var p = SSLProtocol.sslProtocolUnknown
            SSLGetNegotiatedProtocolVersion(ctx, &p)
            version = p == .tlsProtocol13 ? "TLS 1.3" : p == .tlsProtocol12 ? "TLS 1.2" : "TLS（\(p.rawValue)）"
            onReady?()
            if !pendingWrite.isEmpty { let w = pendingWrite; pendingWrite = Data(); write(w) }
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var n = 0
            let st = buf.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress!, $0.count, &n) }
            if n > 0 { onData?(Data(buf[0..<n])) }
            if st == errSSLWouldBlock { if tcpEnded && inboxPos >= inbox.count { finish(nil) }; return }
            if st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == errSSLClosedAbort { finish(nil); return }
            if st != errSecSuccess { finish("TLS の読み込みに失敗（\(st)）"); return }
        }
    }

    // SecureTransport から呼ばれる「読む・書く」
    fileprivate func readInto(_ p: UnsafeMutableRawPointer, _ want: Int) -> (Int, OSStatus) {
        let avail = inbox.count - inboxPos
        if avail <= 0 { return (0, tcpEnded ? errSSLClosedNoNotify : errSSLWouldBlock) }
        let n = min(want, avail)
        inbox.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + inboxPos, byteCount: n) }
        inboxPos += n
        return (n, n < want ? errSSLWouldBlock : errSecSuccess)
    }

    fileprivate func writeFrom(_ p: UnsafeRawPointer, _ n: Int) -> OSStatus {
        guard let t = tcp else { return errSSLClosedAbort }
        t.write(Data(bytes: p, count: n))
        return errSecSuccess
    }
}

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    let (n, st) = s.readInto(data, length.pointee)
    length.pointee = n
    return st
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    return s.writeFrom(data, length.pointee)
}
#else
/// SecureTransport が無い環境用の代わり（作れない）
final class TLSStream: @unchecked Sendable {
    static let isSupported = false
    let handshakeError: Int32 = 0
    let triedTLS13 = false
    let version = ""
    var failedOnCertificate: Bool { false }
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?
    init?(host: String, port: UInt16 = 443, allowTLS13: Bool = true) { return nil }
    func attach(_ t: GuestTCP) {}
    func tcpData(_ d: Data) {}
    func tcpClosed(_ error: String?) {}
    func write(_ d: Data) {}
}
#endif

// ======================================================================
// MARK: - GuestStack.swift
// ======================================================================

// MARK: - ゲスト側の小さな TCP/IP（Linux の代わり）
//
// ・DHCP で IP アドレスをもらう（ルーター UserNet が 10.0.2.15 をくれる）
// ・ARP でルーター（10.0.2.2）の MAC アドレスを調べる
// ・DNS（10.0.2.3）で名前を IP アドレスにする
// ・TCP でつなぐ（GuestTCP。送り直し・順番の確認など最低限）
// すべて queue（VNetMachine.queue）の上で動く

final class GuestStack: @unchecked Sendable {
    let queue: DispatchQueue
    /// フレームを送る（ドライバへ）
    var output: (([UInt8]) -> Void)?
    /// 何が起きたかを知らせる（画面のログ用）
    var trace: ((String) -> Void)?

    var mac = Net.guestMAC
    private(set) var ip = Net.zeroIP
    private(set) var router = Net.gateway
    private(set) var dns = Net.dns
    private(set) var ready = false
    private var routerMAC: [UInt8]?
    /// ルーターの MAC が分かるまで待たせる IP パケット
    private var waitingForARP: [[UInt8]] = []
    private var ipID: UInt16 = 1
    private var nextPort: UInt16 = 40000
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: 受け取り

    func input(_ f: [UInt8]) {
        guard f.count >= Ethernet.headerSize else { return }
        let body = Array(f[Ethernet.headerSize...])
        switch f.be16(at: 12) {
        case EtherType.arp: handleARP(body)
        case EtherType.ipv4: handleIPv4(body)
        default: break
        }
    }

    // MARK: イーサネット・ARP

    private func sendEthernet(_ type: UInt16, to dst: [UInt8], _ payload: [UInt8]) {
        output?(Ethernet.frame(dst: dst, src: mac, type: type, payload))
    }

    private func askRouterMAC() {
        let a = ARP.packet(op: ARP.request, senderMAC: mac, senderIP: ip, targetMAC: Net.zeroMAC, targetIP: router)
        sendEthernet(EtherType.arp, to: Net.broadcastMAC, a)
        trace?("→ ARP \(router.ipString) はどこ？")
    }

    private func handleARP(_ p: [UInt8]) {
        guard p.count >= 28 else { return }
        let op = p.be16(at: 6)
        let senderMAC = Array(p[8..<14]), senderIP = Array(p[14..<18]), target = Array(p[24..<28])
        if op == ARP.reply && senderIP == router {
            if routerMAC == nil { trace?("← ARP \(router.ipString) は \(senderMAC.macString)") }
            routerMAC = senderMAC
            let w = waitingForARP
            waitingForARP = []
            for pkt in w { sendEthernet(EtherType.ipv4, to: senderMAC, pkt) }
        } else if op == ARP.request && target == ip && ip != Net.zeroIP {
            let r = ARP.packet(op: ARP.reply, senderMAC: mac, senderIP: ip, targetMAC: senderMAC, targetIP: senderIP)
            sendEthernet(EtherType.arp, to: senderMAC, r)
        }
    }

    // MARK: IPv4

    private func sendIPv4(proto: UInt8, dst: [UInt8], _ body: [UInt8], broadcast: Bool = false) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: ip, dst: dst, body)
        ipID &+= 1
        if broadcast { sendEthernet(EtherType.ipv4, to: Net.broadcastMAC, pkt); return }
        // 外へは全部ルーター経由（10.0.2.x もルーターが答える）
        if let m = routerMAC { sendEthernet(EtherType.ipv4, to: m, pkt) } else {
            waitingForARP.append(pkt)
            askRouterMAC()
        }
    }

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p) else { return }
        switch pkt.proto {
        case IPProto.tcp: handleTCP(src: pkt.src, pkt.body)
        case IPProto.udp: handleUDP(pkt.body)
        default: break
        }
    }

    // MARK: UDP（DHCP と DNS）

    private func sendUDP(sport: UInt16, dst: [UInt8], dport: UInt16, _ payload: [UInt8], broadcast: Bool = false) {
        let u = UDPDatagram.build(src: ip, dst: dst, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, dst: dst, u, broadcast: broadcast)
    }

    private func handleUDP(_ b: [UInt8]) {
        guard let u = UDPDatagram(b) else { return }
        if u.sport == 67 && u.dport == 68 { handleDHCP(u.payload) }
        else if u.sport == 53, let q = dnsQueries.removeValue(forKey: u.dport) { q.finish(u.payload) }
    }

    private func allocPort() -> UInt16 {
        nextPort = nextPort >= 60000 ? 40000 : nextPort + 1
        return nextPort
    }

    // MARK: DHCP

    private let dhcpXID = UInt32.random(in: 1...UInt32.max)
    private var dhcpSentAt = Date.distantPast
    private var onReady: [() -> Void] = []

    /// IP アドレスをもらう（もらえたら done が呼ばれる）
    func start(_ done: @escaping () -> Void) {
        onReady.append(done)
        sendDHCP(type: DHCP.discover, requested: nil)
    }

    private func sendDHCP(type: UInt8, requested: [UInt8]?) {
        var m = [UInt8](repeating: 0, count: 236)
        m[0] = 1; m[1] = 1; m[2] = 6                       // 問い合わせ・イーサネット・MAC は 6 バイト
        m.setBE32(dhcpXID, at: 4)
        m[10] = 0x80                                       // ブロードキャストで返してほしい
        m.replaceSubrange(28..<34, with: mac)
        m += DHCP.magicCookie
        m += [53, 1, type]
        if let r = requested { m += [50, 4] + r + [54, 4] + router }
        m += [55, 3, 1, 3, 6, 255]                         // ほしいもの: サブネット・ルーター・DNS
        sendUDP(sport: 68, dst: Net.broadcastIP, dport: 67, m, broadcast: true)
        dhcpSentAt = Date()
        trace?(type == DHCP.discover ? "→ DHCP DISCOVER（IP アドレスをください）" : "→ DHCP REQUEST")
    }

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 2, p.be32(at: 4) == dhcpXID else { return }
        let yiaddr = Array(p[16..<20])
        let opts = DHCP.options(p)
        if let r = opts[3], r.count >= 4 { router = Array(r[0..<4]) }
        if let d = opts[6], d.count >= 4 { dns = Array(d[0..<4]) }
        let type = opts[53]?.first ?? 0
        if type == DHCP.offer {
            trace?("← DHCP OFFER \(yiaddr.ipString)")
            sendDHCP(type: DHCP.request, requested: yiaddr)
        } else if type == DHCP.ack && !ready {
            ip = yiaddr
            ready = true
            trace?("← DHCP ACK: IP \(ip.ipString)・ルーター \(router.ipString)・DNS \(dns.ipString)")
            let w = onReady
            onReady = []
            for f in w { f() }
        }
    }

    // MARK: DNS

    private final class DNSQuery {
        let packet: [UInt8]
        let done: ([UInt8]?) -> Void
        var sentAt = Date()
        var tries = 0
        private var finished = false
        init(packet: [UInt8], done: @escaping ([UInt8]?) -> Void) { self.packet = packet; self.done = done }
        func finish(_ reply: [UInt8]?) {
            if finished { return }
            finished = true
            done(reply.flatMap(DNSMessage.firstA))
        }
    }
    private var dnsQueries: [UInt16: DNSQuery] = [:]

    /// 名前を IPv4 アドレスにする（IP アドレスの形ならそのまま）
    func resolve(_ name: String, _ done: @escaping ([UInt8]?) -> Void) {
        let labels = name.split(separator: ".")
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4 && octets.count == 4 { done(octets); return }
        let packet = DNSMessage.query(name: name, id: .random(in: 0...UInt16.max))
        let port = allocPort()
        dnsQueries[port] = DNSQuery(packet: packet) { [weak self] ip in
            self?.trace?("← DNS \(name) = " + (ip?.ipString ?? "見つからない"))
            done(ip)
        }
        trace?("→ DNS \(name) は？")
        sendUDP(sport: port, dst: dns, dport: 53, packet)
    }

    // MARK: TCP

    private struct TCPKey: Hashable { let lport: UInt16; let rip: [UInt8]; let rport: UInt16 }
    private var tcps: [TCPKey: GuestTCP] = [:]

    private static func key(_ c: GuestTCP) -> TCPKey { TCPKey(lport: c.lport, rip: c.rip, rport: c.rport) }

    /// TCP でつなぐ
    func connect(_ rip: [UInt8], _ rport: UInt16, handler: GuestTCP.Handler) -> GuestTCP {
        let c = GuestTCP(stack: self, lport: allocPort(), rip: rip, rport: rport, handler: handler)
        tcps[GuestStack.key(c)] = c
        c.sendSYN()
        trace?("→ TCP SYN \(rip.ipString):\(rport)")
        return c
    }

    /// 終わった接続を忘れる（GuestTCP から呼ぶ）
    func forget(_ c: GuestTCP) {
        tcps[GuestStack.key(c)] = nil
    }

    /// 組み立てた TCP セグメントを送る（GuestTCP から呼ぶ）
    func sendTCP(to dst: [UInt8], _ segment: [UInt8]) {
        sendIPv4(proto: IPProto.tcp, dst: dst, segment)
    }

    private func handleTCP(src: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b), let c = tcps[TCPKey(lport: h.dport, rip: src, rport: h.sport)] else { return }
        c.input(h, payload: b[h.headerLength...])
    }

    // MARK: 時間で見るもの（DHCP・DNS・TCP の送り直し）

    private func tick() {
        let now = Date()
        if !ready && now.timeIntervalSince(dhcpSentAt) > 2 && !onReady.isEmpty { sendDHCP(type: DHCP.discover, requested: nil) }
        for (port, q) in dnsQueries where now.timeIntervalSince(q.sentAt) > 2 {
            q.tries += 1
            if q.tries > 3 { dnsQueries[port] = nil; q.finish(nil); continue }
            q.sentAt = now
            sendUDP(sport: port, dst: dns, dport: 53, q.packet)
        }
        for c in Array(tcps.values) { c.tick(now) }
    }
}

// ======================================================================
// MARK: - GuestTCP.swift
// ======================================================================

// MARK: - ゲスト側の TCP の接続 1 本
//
// 作るのは GuestStack.connect。届いたセグメント（input）と時間（tick）も GuestStack から渡される。
// すべて GuestStack と同じ queue の上で動く

final class GuestTCP: @unchecked Sendable {
    struct Handler {
        var connected: () -> Void
        var data: (Data) -> Void
        var closed: (_ error: String?) -> Void
    }

    unowned let stack: GuestStack
    let lport: UInt16, rip: [UInt8], rport: UInt16
    private let handler: Handler
    private enum State { case synSent, established, closed }
    private var state = State.synSent
    private let iss = UInt32.random(in: 0...UInt32.max)
    private var sndUna: UInt32, sndNxt: UInt32
    private var rcvNxt: UInt32 = 0
    /// sndUna から先の、まだ受け取ってもらっていないデータ
    private var sendBuf = Data()
    private var wantFIN = false, finSent = false, gotFIN = false
    private var peerWindow = 65535
    private let mss = 1460
    private var lastProgress = Date()
    private var retries = 0

    init(stack: GuestStack, lport: UInt16, rip: [UInt8], rport: UInt16, handler: Handler) {
        self.stack = stack; self.lport = lport; self.rip = rip; self.rport = rport; self.handler = handler
        sndUna = iss
        sndNxt = iss &+ 1
    }

    // MARK: 使う側から

    /// データを送る
    func write(_ d: Data) {
        guard state != .closed else { return }
        sendBuf.append(d)
        pump()
    }

    /// 送り終わったら閉じる
    func close() {
        wantFIN = true
        pump()
    }

    /// すぐに切る（RST）
    func abort() {
        if state != .closed { send([.rst, .ack]) }
        finish(nil)
    }

    // MARK: 送る

    private func send(_ flags: TCPFlags, mss withMSS: Bool = false, payload: ArraySlice<UInt8> = []) {
        let seq = flags.contains(.syn) ? iss : sndNxt
        let seg = TCPSegment.build(src: stack.ip, dst: rip, sport: lport, dport: rport, seq: seq,
                                   ack: flags.contains(.ack) ? rcvNxt : 0, flags: flags, mss: withMSS, payload: payload)
        stack.sendTCP(to: rip, seg)
    }

    /// 最初の SYN（GuestStack.connect から呼ぶ）
    func sendSYN() { send(.syn, mss: true) }

    private func finish(_ error: String?) {
        if state == .closed { return }
        state = .closed
        stack.forget(self)
        handler.closed(error)
    }

    /// 相手の窓の分だけ送る。全部送って閉じたいなら FIN
    private func pump() {
        guard state == .established else { return }
        while true {
            let inFlight = Int(sndNxt &- sndUna)
            let unsent = sendBuf.count - inFlight
            if unsent <= 0 {
                if wantFIN && !finSent {
                    send([.fin, .ack])
                    sndNxt &+= 1
                    finSent = true
                    lastProgress = Date()
                }
                return
            }
            let room = peerWindow - inFlight
            if room <= 0 { return }
            let n = min(unsent, mss, room)
            let start = sendBuf.startIndex + inFlight
            send([.ack, .psh], payload: ArraySlice(sendBuf[start..<(start + n)]))
            sndNxt &+= UInt32(n)
            lastProgress = Date()
        }
    }

    // MARK: GuestStack から

    /// 届いたセグメント
    func input(_ h: TCPHeader, payload: ArraySlice<UInt8>) {
        peerWindow = Int(h.window)
        if h.flags.contains(.rst) {
            stack.trace?("← TCP RST \(rip.ipString):\(rport)")
            finish(state == .synSent ? "つながりませんでした" : "相手に切られました")
            return
        }
        if state == .synSent {
            guard h.flags.contains([.syn, .ack]), h.ack == iss &+ 1 else { return }
            rcvNxt = h.seq &+ 1
            sndUna = h.ack
            state = .established
            retries = 0
            send(.ack)
            stack.trace?("← TCP SYN+ACK \(rip.ipString):\(rport)（つながった）")
            handler.connected()
            pump()
            return
        }
        guard state == .established else { return }
        if h.flags.contains(.ack) {
            let acked = h.ack &- sndUna
            let inFlight = sndNxt &- sndUna
            if acked > 0 && acked <= inFlight {
                var n = Int(acked)
                if finSent && h.ack == sndNxt { n -= 1 }        // FIN の分
                if n > 0 { sendBuf.removeFirst(min(n, sendBuf.count)) }
                sndUna = h.ack
                lastProgress = Date()
                retries = 0
            }
        }
        var needAck = false
        if !payload.isEmpty {
            if h.seq == rcvNxt {
                rcvNxt &+= UInt32(payload.count)
                handler.data(Data(payload))
            }
            needAck = true
        }
        if h.flags.contains(.fin) && h.seq &+ UInt32(payload.count) == rcvNxt && !gotFIN {
            gotFIN = true
            rcvNxt &+= 1
            needAck = true
        }
        if needAck { send(.ack) }
        pump()
        if gotFIN {
            // 相手が閉じた: こちらも閉じて終わり（ブラウザ用なので、半分だけ閉じた状態は使わない）
            if !finSent { wantFIN = true; pump() }
            finish(nil)
        }
    }

    /// 時間で見る（送り直し）
    func tick(_ now: Date) {
        if now.timeIntervalSince(lastProgress) < 1 { return }
        if state == .synSent {
            retries += 1
            if retries > 8 { finish("つながりませんでした（時間切れ）"); return }
            sendSYN()
            lastProgress = now
        } else if state == .established && sndNxt != sndUna {
            retries += 1
            if retries > 12 { abort(); return }
            // 受け取りの返事が来ない: 先頭から送り直す
            sndNxt = sndUna
            finSent = false
            lastProgress = now
            pump()
        }
    }
}

// ======================================================================
// MARK: - DNSMessage.swift
// ======================================================================

// MARK: - DNS のメッセージ（A レコードだけ）
//
// ゲスト側: query で問い合わせを作り、firstA で返事から IPv4 アドレスを取り出す
// ルーター側: question で問い合わせを読み、reply で返事を作る

enum DNSMessage {
    /// A レコードの問い合わせ（再帰あり）
    static func query(name: String, id: UInt16) -> [UInt8] {
        var q: [UInt8] = []
        q.appendBE16(id)
        q += [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]      // RD=1・質問 1 つ
        for label in name.split(separator: ".") {
            let b = Array(label.utf8.prefix(63))
            q.append(UInt8(b.count))
            q += b
        }
        q += [0, 0, 1, 0, 1]                           // 名前の終わり・A・IN
        return q
    }

    /// 返事から最初の A レコード（IPv4 アドレス）を取り出す
    static func firstA(_ r: [UInt8]) -> [UInt8]? {
        guard r.count >= 12, r[3] & 0x0F == 0 else { return nil }
        let qd = Int(r.be16(at: 4)), an = Int(r.be16(at: 6))
        var i = 12
        func skipName() {
            while i < r.count {
                let l = Int(r[i])
                if l == 0 { i += 1; return }
                if l & 0xC0 == 0xC0 { i += 2; return }
                i += 1 + l
            }
        }
        for _ in 0..<qd { skipName(); i += 4 }
        for _ in 0..<an {
            skipName()
            guard i + 10 <= r.count else { return nil }
            let type = r.be16(at: i)
            let rdlen = Int(r.be16(at: i + 8))
            i += 10
            if type == 1 && rdlen == 4 && i + 4 <= r.count { return Array(r[i..<(i + 4)]) }
            i += rdlen
        }
        return nil
    }

    struct Question {
        let name: String
        let type: UInt16
        /// 質問の終わり（返事はここまでを写して作る）
        let end: Int
    }

    /// 問い合わせの最初の質問を読む（形が変なら nil）
    static func question(_ q: [UInt8]) -> Question? {
        var i = 12
        var labels: [String] = []
        while i < q.count {
            let l = Int(q[i])
            if l == 0 { i += 1; break }
            guard l < 64, i + 1 + l <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + l)], as: UTF8.self))
            i += 1 + l
        }
        guard i + 4 <= q.count else { return nil }
        return Question(name: labels.joined(separator: "."), type: q.be16(at: i), end: i + 4)
    }

    /// 返事を作る（問い合わせの先頭 questionEnd バイトを写し、A レコードを並べる）
    static func reply(to q: [UInt8], questionEnd: Int, rcode: UInt8, answers: [[UInt8]]) -> [UInt8] {
        var r = Array(q[0..<min(questionEnd, q.count)])
        r[2] = 0x81                                    // QR=1・RD=1
        r[3] = 0x80 | rcode                            // RA=1
        r.setBE16(UInt16(answers.count), at: 6)
        for k in 8..<12 { r[k] = 0 }
        for a in answers {
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + a   // 名前は質問を指す・A・IN・60 秒・4 バイト
        }
        return r
    }
}

// ======================================================================
// MARK: - Packet.swift
// ======================================================================

// MARK: - パケットを組み立てる・読むための共通の部品
//
// ゲスト側（GuestStack・GuestTCP）とルーター側（UserNet）の両方が使う。
// 数はすべてネットワークの順（ビッグエンディアン）。IP アドレスは 4 バイト、MAC アドレスは 6 バイトの [UInt8]

/// この小さなネットワークの決まった値（QEMU の SLIRP と同じ）
enum Net {
    static let guestIP: [UInt8] = [10, 0, 2, 15]
    static let gateway: [UInt8] = [10, 0, 2, 2]
    static let dns: [UInt8] = [10, 0, 2, 3]
    static let zeroIP: [UInt8] = [0, 0, 0, 0]
    static let broadcastIP: [UInt8] = [255, 255, 255, 255]
    /// ゲスト（仮想 LAN カード）の MAC アドレス（QEMU と同じ）
    static let guestMAC: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
    /// ルーターの MAC アドレス
    static let routerMAC: [UInt8] = [0x52, 0x55, 0x0A, 0x00, 0x02, 0x02]
    static let zeroMAC: [UInt8] = [0, 0, 0, 0, 0, 0]
    static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    /// 10.0.2.x（ルーターが自分で答える範囲）
    static func isLocal(_ ip: [UInt8]) -> Bool { ip.count == 4 && ip[0] == 10 && ip[1] == 0 && ip[2] == 2 }
}

enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
}

enum IPProto {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

// MARK: バイト列の読み書き

extension Array where Element == UInt8 {
    func be16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(at i: Int) -> UInt32 { UInt32(be16(at: i)) << 16 | UInt32(be16(at: i + 2)) }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) { appendBE16(UInt16(v >> 16)); appendBE16(UInt16(v & 0xFFFF)) }
    mutating func setBE16(_ v: UInt16, at i: Int) { self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF) }
    mutating func setBE32(_ v: UInt32, at i: Int) { setBE16(UInt16(v >> 16), at: i); setBE16(UInt16(v & 0xFFFF), at: i + 2) }

    /// 10.0.2.15 の形
    var ipString: String { map { String($0) }.joined(separator: ".") }
    /// 52:54:00:12:34:56 の形
    var macString: String { map { String(format: "%02x", $0) }.joined(separator: ":") }
}

// MARK: 確認用の値（チェックサム）

enum Checksum {
    /// IP などで使う 16 ビットの 1 の補数の和
    static func internet(_ b: [UInt8], initial: UInt32 = 0) -> UInt16 {
        var s = initial
        var i = 0
        while i + 1 < b.count { s &+= UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { s &+= UInt32(b[i]) << 8 }
        while s >> 16 != 0 { s = (s & 0xFFFF) &+ (s >> 16) }
        return ~UInt16(s)
    }

    /// TCP / UDP 用（疑似ヘッダ込み）
    static func l4(proto: UInt8, src: [UInt8], dst: [UInt8], _ seg: [UInt8]) -> UInt16 {
        var s = UInt32(src.be16(at: 0)) &+ UInt32(src.be16(at: 2))
        s &+= UInt32(dst.be16(at: 0)) &+ UInt32(dst.be16(at: 2))
        s &+= UInt32(proto) &+ UInt32(seg.count)
        return internet(seg, initial: s)
    }
}

// MARK: イーサネット・ARP

enum Ethernet {
    static let headerSize = 14
    static func frame(dst: [UInt8], src: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var f = dst + src
        f.appendBE16(type)
        return f + payload
    }
}

enum ARP {
    static let request: UInt16 = 1
    static let reply: UInt16 = 2
    /// ARP の中身（イーサネット・IPv4 用）
    static func packet(op: UInt16, senderMAC: [UInt8], senderIP: [UInt8], targetMAC: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        var a: [UInt8] = [0, 1, 8, 0, 6, 4]
        a.appendBE16(op)
        return a + senderMAC + senderIP + targetMAC + targetIP
    }
}

// MARK: IPv4

struct IPv4Packet {
    let proto: UInt8
    let src: [UInt8]
    let dst: [UInt8]
    let body: [UInt8]
    /// 分割されたもの（フラグメント）か
    let isFragment: Bool

    /// 読む（形が変なら nil）
    init?(_ p: [UInt8]) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 15) * 4
        let total = min(Int(p.be16(at: 2)), p.count)
        guard ihl >= 20, total >= ihl else { return nil }
        proto = p[9]
        src = Array(p[12..<16])
        dst = Array(p[16..<20])
        body = Array(p[ihl..<total])
        isFragment = p.be16(at: 6) & 0x3FFF != 0
    }

    /// 組み立てる（オプション無し・TTL 64）
    static func build(proto: UInt8, id: UInt16, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8]) -> [UInt8] {
        var h: [UInt8] = [0x45, 0]
        h.appendBE16(UInt16(20 + body.count))
        h.appendBE16(id)
        h += [dontFragment ? 0x40 : 0, 0, 64, proto, 0, 0]
        h += src + dst
        h.setBE16(Checksum.internet(h), at: 10)
        return h + body
    }
}

// MARK: UDP

struct UDPDatagram {
    let sport: UInt16
    let dport: UInt16
    let payload: [UInt8]

    init?(_ b: [UInt8]) {
        guard b.count >= 8 else { return nil }
        let len = min(Int(b.be16(at: 4)), b.count)
        guard len >= 8 else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        payload = Array(b[8..<len])
    }

    /// 組み立てる（チェックサム込み。0 になったら 0xFFFF にする決まり）
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var u: [UInt8] = []
        u.appendBE16(sport)
        u.appendBE16(dport)
        u.appendBE16(UInt16(8 + payload.count))
        u += [0, 0]
        u += payload
        let c = Checksum.l4(proto: IPProto.udp, src: src, dst: dst, u)
        u.setBE16(c == 0 ? 0xFFFF : c, at: 6)
        return u
    }
}

// MARK: TCP

struct TCPFlags: OptionSet {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 1)
    static let syn = TCPFlags(rawValue: 2)
    static let rst = TCPFlags(rawValue: 4)
    static let psh = TCPFlags(rawValue: 8)
    static let ack = TCPFlags(rawValue: 16)
}

struct TCPHeader {
    let sport: UInt16
    let dport: UInt16
    let seq: UInt32
    let ack: UInt32
    /// ヘッダの長さ（オプション込み）。中身はここから
    let headerLength: Int
    let flags: TCPFlags
    let window: UInt16

    init?(_ b: [UInt8]) {
        guard b.count >= 20 else { return nil }
        let off = Int(b[12] >> 4) * 4
        guard off >= 20, off <= b.count else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        seq = b.be32(at: 4)
        ack = b.be32(at: 8)
        headerLength = off
        flags = TCPFlags(rawValue: b[13])
        window = b.be16(at: 14)
    }

    /// オプションの MSS（無ければ nil）
    static func mss(_ b: [UInt8], headerLength off: Int) -> Int? {
        var i = 20
        while i < off {
            let kind = b[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < off else { break }
            let l = Int(b[i + 1])
            if kind == 2, l == 4, i + 3 < off { return Int(b.be16(at: i + 2)) }
            i += max(2, l)
        }
        return nil
    }
}

enum TCPSegment {
    /// TCP のセグメントを組み立てる（チェックサム込み）。mss = true なら MSS 1460 のオプションを付ける
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, seq: UInt32, ack: UInt32,
                      flags: TCPFlags, window: UInt16 = 0xFFFF, mss: Bool = false,
                      payload: ArraySlice<UInt8> = []) -> [UInt8] {
        let hlen = mss ? 24 : 20
        var t: [UInt8] = []
        t.appendBE16(sport)
        t.appendBE16(dport)
        t.appendBE32(seq)
        t.appendBE32(ack)
        t += [UInt8(hlen / 4) << 4, flags.rawValue]
        t.appendBE16(window)
        t += [0, 0, 0, 0]                              // チェックサム・緊急ポインタ
        if mss { t += [2, 4, 0x05, 0xB4] }
        t += payload
        t.setBE16(Checksum.l4(proto: IPProto.tcp, src: src, dst: dst, t), at: 16)
        return t
    }
}

// MARK: DHCP

enum DHCP {
    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let ack: UInt8 = 5

    /// オプション（番号 → 中身）。240 バイト目から読む
    static func options(_ p: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 240
        while i + 1 < p.count {
            let code = p[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            let l = Int(p[i + 1])
            guard i + 2 + l <= p.count else { break }
            out[code] = Array(p[(i + 2)..<(i + 2 + l)])
            i += 2 + l
        }
        return out
    }
}

// ======================================================================
// MARK: - VNetMachine.swift
// ======================================================================

// MARK: - 全部をつなぐ
//
//  [ゲスト側]  HTTPPool（http・https）→ GuestStack → VirtioNetDriver
//                                         ↓ ↑（RAM の中のキューと、レジスタ）
//  [カード]                             VirtioNet
//                                         ↓ onTransmit      ↑ receive
//  [ルーター]                           UserNet（小さなルーター）→ iPad の通信 → インターネット
//
// ゲスト側とカードは queue の上で動く。ルーターは自分のキューで動き、フレームを渡すときだけ行き来する

final class VNetMachine: @unchecked Sendable {
    let queue = DispatchQueue(label: "vnet-guest")
    let ram = GuestRAM(megabytes: 4)
    let card: VirtioNet
    let driver: VirtioNetDriver
    let stack: GuestStack
    let router: UserNet
    let pool: HTTPPool
    /// ログ（どのスレッドからも呼ばれる）
    var log: (@Sendable (String) -> Void)?
    private var ready = false
    private var waiting: [() -> Void] = []
    /// 統計: カードを通ったフレームの数とバイト数
    private var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0

    init(factory: UserNetSocketFactory) {
        card = VirtioNet(memory: ram)
        driver = VirtioNetDriver(dev: card, ram: ram)
        stack = GuestStack(queue: queue)
        router = UserNet(factory: factory)
        pool = HTTPPool(stack: stack)
        // ゲスト → カード → ルーター
        stack.output = { [unowned self] f in self.driver.send(f) }
        card.onTransmit = { [unowned self] f in
            self.framesOut += 1; self.bytesOut += f.count
            self.router.input(f)
        }
        // ルーター → カード → ゲスト（カードとゲストは queue の上で触る）
        router.onFrame = { [weak self] f in
            guard let self else { return }
            self.queue.async {
                self.framesIn += 1; self.bytesIn += f.count
                self.card.receive(f)
                self.driver.poll()          // 割り込みを見て、届いたフレームを取り出す
            }
        }
        driver.onReceive = { [unowned self] f in self.stack.input(f) }
        stack.trace = { [weak self] s in self?.log?(s) }
        router.log = { [weak self] s in self?.log?(s) }
    }

    /// カードを準備して DHCP で IP アドレスをもらう
    func boot() {
        queue.async {
            do {
                try self.driver.start()
                self.stack.mac = self.driver.mac
                self.log?("カードの準備ができました（MAC \(self.driver.mac.macString)）")
            } catch {
                self.log?("カードを準備できません: \(error)")
                return
            }
            self.stack.start {
                self.ready = true
                let w = self.waiting
                self.waiting = []
                for f in w { f() }
            }
        }
    }

    /// 送って返事を受け取る（結果は done に、queue の上で返る）
    /// followRedirects: false なら 3xx もそのまま返す（移動はブラウザに任せる）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, _ done: @escaping @Sendable (Result<HTTPResult, FetchError>) -> Void) {
        queue.async {
            let go = { self.pool.send(req, followRedirects: followRedirects) { r in done(r) } }
            if self.ready { go() } else { self.waiting.append(go) }
        }
    }

    /// ブラウザの User-Agent を使う
    func setUserAgent(_ ua: String) { queue.async { self.pool.userAgent = ua } }

    func stats() -> String {
        "フレーム 送 \(framesOut)（\(bytesOut / 1024)KB）・受 \(framesIn)（\(bytesIn / 1024)KB）・接続 新 \(pool.opened) 使い回し \(pool.reused)"
    }
}

// ======================================================================
// MARK: - VNetCore.swift
// ======================================================================

// MARK: - 実験用の「機械」の部品
//
// Android エミュレータと同じ virtio-net（仮想 LAN カード）を使う。
// 本物のエミュレータでは Linux（ゲスト）がこのカードを動かすが、この実験アプリでは
// ゲストの代わりに、Swift で書いた小さな「ドライバ」と「TCP/IP」（GuestStack）が動かす。
//
//   ブラウザ（WKWebView）→ HTTPPool → GuestStack（TCP/IP）→ VirtioNetDriver
//     → VirtioNet（仮想 LAN カード）→ UserNet（小さなルーター）→ iPad の通信

/// ゲストの RAM（virtio のキューと、フレームの入れ物を置く）。アドレスは 0x4000_0000 から
final class GuestRAM: @unchecked Sendable {
    let base: UInt64 = 0x4000_0000
    let size: UInt64
    private let words: UnsafeMutablePointer<UInt64>
    private var next: UInt64 = 0

    init(megabytes: Int) {
        size = UInt64(megabytes) << 20
        words = .allocate(capacity: Int(size / 8))
        words.initialize(repeating: 0, count: Int(size / 8))
    }
    deinit { words.deallocate() }

    /// 置き場所をもらう（align の倍数に揃える）。戻り値はゲストの物理アドレス
    func alloc(_ count: Int, align: UInt64 = 16) -> UInt64 {
        next = (next + align - 1) / align * align
        let a = base + next
        next += UInt64(count)
        precondition(next <= size, "GuestRAM が足りません")
        return a
    }

    /// ドライバ用（自分で置いた場所なので確かめない）
    func pointer(_ pa: UInt64) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(words) + Int(pa - base) }
    /// カード用（ゲストが書いたアドレスなので、RAM の中に収まるか確かめる）
    func pointer(_ pa: UInt64, count: Int) -> UnsafeMutableRawPointer? {
        let off = pa &- base
        guard pa >= base, off <= size, UInt64(count) <= size - off else { return nil }
        return UnsafeMutableRawPointer(words) + Int(off)
    }

    func load16(_ pa: UInt64) -> UInt16 { pointer(pa).loadUnaligned(as: UInt16.self) }
    func load32(_ pa: UInt64) -> UInt32 { pointer(pa).loadUnaligned(as: UInt32.self) }
    func store16(_ pa: UInt64, _ v: UInt16) { pointer(pa).storeBytes(of: v, as: UInt16.self) }
    func store32(_ pa: UInt64, _ v: UInt32) { pointer(pa).storeBytes(of: v, as: UInt32.self) }
    func store64(_ pa: UInt64, _ v: UInt64) { pointer(pa).storeBytes(of: v, as: UInt64.self) }
}

// MARK: - virtio-mmio の決まり（カードとドライバの両方が使う）

enum VirtioMMIO {
    /// レジスタの位置
    enum Reg {
        static let magic: UInt64 = 0x000
        static let version: UInt64 = 0x004
        static let deviceID: UInt64 = 0x008
        static let vendorID: UInt64 = 0x00C
        static let deviceFeatures: UInt64 = 0x010
        static let deviceFeaturesSel: UInt64 = 0x014
        static let driverFeatures: UInt64 = 0x020
        static let driverFeaturesSel: UInt64 = 0x024
        static let guestPageSize: UInt64 = 0x028          // legacy
        static let queueSel: UInt64 = 0x030
        static let queueNumMax: UInt64 = 0x034
        static let queueNum: UInt64 = 0x038
        static let queueAlign: UInt64 = 0x03C             // legacy
        static let queuePFN: UInt64 = 0x040               // legacy
        static let queueReady: UInt64 = 0x044
        static let queueNotify: UInt64 = 0x050
        static let interruptStatus: UInt64 = 0x060
        static let interruptACK: UInt64 = 0x064
        static let status: UInt64 = 0x070
        static let queueDescLow: UInt64 = 0x080
        static let queueDescHigh: UInt64 = 0x084
        static let queueAvailLow: UInt64 = 0x090
        static let queueAvailHigh: UInt64 = 0x094
        static let queueUsedLow: UInt64 = 0x0A0
        static let queueUsedHigh: UInt64 = 0x0A4
        static let config: UInt64 = 0x100                 // ここから先がカードごとの設定（ネットワークなら MAC アドレス）
    }
    static let magicValue: UInt32 = 0x7472_6976           // "virt"
    static let vendorQEMU: UInt32 = 0x554D_4551           // "QEMU"
    static let deviceNet: UInt32 = 1

    /// 状態（status）のビット
    static let statusAcknowledge: UInt32 = 1
    static let statusDriver: UInt32 = 2
    static let statusDriverOK: UInt32 = 4

    /// 機能のビット
    static let featureNetMAC: UInt64 = 1 << 5
    static let featureVersion1: UInt64 = 1 << 32

    /// 記述子の flags
    static let descNext: UInt16 = 1
    static let descWrite: UInt16 = 2

    /// キューの番号（ネットワーク）
    static let rxQueue = 0
    static let txQueue = 1

    /// virtio_net_hdr の大きさ（古い形 = legacy、MRG_RXBUF なし）
    static let netHeaderSize = 10
}

// MARK: - virtio-mmio のネットワーク（Linux では eth0 になる）
//
// キューは 2 つ: 0 = 受け取り用（OS が空の入れ物を並べておく）、1 = 送り出し用。
// 1 つの入れ物 = [virtio_net_hdr 10 バイト] [イーサネットのフレーム]
// 送り出されたフレームは onTransmit に渡す。外から届いたフレームは receive(_:) で受け取り、
// OS が並べた入れ物に書き込む（入れ物が無ければ、来るまで取っておく）。
// receive はほかのスレッドから呼んでもよい（鍵で守る）。入れ物に書くのは CPU の側（interruptLine を見るとき）
final class VirtioNet: @unchecked Sendable {
    let legacy: Bool
    let mac = Net.guestMAC
    /// OS が送り出したフレーム（ヘッダを除いたイーサネットのフレーム）
    var onTransmit: (([UInt8]) -> Void)?

    static let queueMax: UInt32 = 256
    static let maxPending = 512

    private let ram: GuestRAM

    private struct Queue {
        var num: UInt32 = 0
        var ready: UInt32 = 0
        var desc: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var lastAvail: UInt16 = 0
        var align: UInt32 = 4096
        var pfn: UInt32 = 0
        /// 入れ物の数（ドライバが決めていなければ最大）
        var size: UInt16 { UInt16(num == 0 ? VirtioNet.queueMax : num) }
    }
    private var queues = [Queue(), Queue()]
    private var status: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var queueSel: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var guestPageSize: UInt32 = 4096

    /// まだ OS に渡していない受け取ったフレーム
    private var pending: [[UInt8]] = []
    private let lock = NSLock()
    private var hasPending = false

    init(memory: GuestRAM, legacy: Bool = true) {
        ram = memory
        self.legacy = legacy
    }

    var interruptLine: Bool {
        if hasPending { deliverPending() }
        return interruptStatus != 0
    }

    /// 外から届いたフレームを受け取る（どのスレッドからでもよい）
    func receive(_ frame: [UInt8]) {
        lock.lock()
        if pending.count >= VirtioNet.maxPending { pending.removeFirst() }
        pending.append(frame)
        hasPending = true
        lock.unlock()
    }

    /// 持っている機能: MAC。バージョン 2 なら VERSION_1 も
    private var deviceFeatures: UInt64 { (legacy ? 0 : VirtioMMIO.featureVersion1) | VirtioMMIO.featureNetMAC }

    private func reset() {
        status = 0
        deviceFeaturesSel = 0
        driverFeaturesSel = 0
        driverFeatures = 0
        queueSel = 0
        interruptStatus = 0
        guestPageSize = 4096
        queues = [Queue(), Queue()]
    }

    // MARK: レジスタ

    func read(_ offset: UInt64, size width: Int) -> UInt64 {
        typealias R = VirtioMMIO.Reg
        if offset >= R.config {
            // 設定領域: 先頭 6 バイトが MAC アドレス
            var r: UInt64 = 0
            for k in 0..<width {
                let i = Int(offset - R.config) + k
                if i < mac.count { r |= UInt64(mac[i]) << UInt64(8 * k) }
            }
            return r
        }
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.magic: return UInt64(VirtioMMIO.magicValue)
        case R.version: return legacy ? 1 : 2
        case R.deviceID: return UInt64(VirtioMMIO.deviceNet)
        case R.vendorID: return UInt64(VirtioMMIO.vendorQEMU)
        case R.deviceFeatures: return deviceFeaturesSel < 2 ? (deviceFeatures >> UInt64(32 * deviceFeaturesSel)) & 0xFFFF_FFFF : 0
        case R.queueNumMax: return ok ? UInt64(VirtioNet.queueMax) : 0
        case R.queuePFN: return legacy && ok ? UInt64(queues[qs].pfn) : 0
        case R.queueReady: return ok ? UInt64(queues[qs].ready) : 0
        case R.interruptStatus: return UInt64(interruptStatus)
        case R.status: return UInt64(status)
        default: return 0
        }
    }

    func write(_ offset: UInt64, size width: Int, value: UInt64) {
        typealias R = VirtioMMIO.Reg
        let v = UInt32(truncatingIfNeeded: value)
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.deviceFeaturesSel: deviceFeaturesSel = v
        case R.driverFeatures:
            if driverFeaturesSel < 2 {
                let shift = UInt64(32 * driverFeaturesSel)
                driverFeatures = (driverFeatures & ~(0xFFFF_FFFF << shift)) | (UInt64(v) << shift)
            }
        case R.driverFeaturesSel: driverFeaturesSel = v
        case R.guestPageSize: if legacy { guestPageSize = v == 0 ? 4096 : v }
        case R.queueSel: queueSel = v
        case R.queueNum: if ok { queues[qs].num = min(v, VirtioNet.queueMax) }
        case R.queueAlign: if legacy && ok { queues[qs].align = v == 0 ? 4096 : v }
        case R.queuePFN: if legacy && ok { setLegacyQueue(qs, pfn: v) }
        case R.queueReady: if ok { queues[qs].ready = v & 1 }
        case R.queueNotify:
            if v == UInt32(VirtioMMIO.txQueue) { transmit() } else if v == UInt32(VirtioMMIO.rxQueue) { deliverPending() }
        case R.interruptACK: interruptStatus &= ~v
        case R.status: if v == 0 { reset() } else { status = v }
        case R.queueDescLow: if ok { queues[qs].desc = setLow(queues[qs].desc, v) }
        case R.queueDescHigh: if ok { queues[qs].desc = setHigh(queues[qs].desc, v) }
        case R.queueAvailLow: if ok { queues[qs].avail = setLow(queues[qs].avail, v) }
        case R.queueAvailHigh: if ok { queues[qs].avail = setHigh(queues[qs].avail, v) }
        case R.queueUsedLow: if ok { queues[qs].used = setLow(queues[qs].used, v) }
        case R.queueUsedHigh: if ok { queues[qs].used = setHigh(queues[qs].used, v) }
        default: break
        }
    }

    /// 古い形: ページ番号（PFN）から、記述子表・avail・used の場所を決める
    private func setLegacyQueue(_ i: Int, pfn: UInt32) {
        queues[i].pfn = pfn
        if pfn == 0 { queues[i].ready = 0; queues[i].lastAvail = 0; return }
        let num = UInt64(queues[i].size)
        let desc = UInt64(pfn) * UInt64(guestPageSize)
        let avail = desc + 16 * num
        let align = UInt64(queues[i].align)
        let availEnd = avail + 4 + 2 * num + 2
        queues[i].desc = desc
        queues[i].avail = avail
        queues[i].used = (availEnd + align - 1) / align * align
        queues[i].lastAvail = 0
        queues[i].ready = 1
    }

    private func setLow(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF_0000_0000) | UInt64(v) }
    private func setHigh(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF) | (UInt64(v) << 32) }

    // MARK: キュー（RAM はゲストが書いた場所なので、確かめながら読み書きする）

    private func load16(_ pa: UInt64) -> UInt16 { ram.pointer(pa, count: 2)?.loadUnaligned(as: UInt16.self) ?? 0 }
    private func load32(_ pa: UInt64) -> UInt32 { ram.pointer(pa, count: 4)?.loadUnaligned(as: UInt32.self) ?? 0 }
    private func load64(_ pa: UInt64) -> UInt64 { ram.pointer(pa, count: 8)?.loadUnaligned(as: UInt64.self) ?? 0 }
    private func store16(_ pa: UInt64, _ v: UInt16) { ram.pointer(pa, count: 2)?.storeBytes(of: v, as: UInt16.self) }
    private func store32(_ pa: UInt64, _ v: UInt32) { ram.pointer(pa, count: 4)?.storeBytes(of: v, as: UInt32.self) }

    /// ドライバが並べた番号（avail.idx）
    private func availIdx(_ q: Queue) -> UInt16 { load16(q.avail + 2) }
    /// 次に取り出す入れ物の先頭の記述子
    private func nextAvailHead(_ q: Queue) -> UInt16 { load16(q.avail + 4 + 2 * UInt64(q.lastAvail % q.size)) }

    /// 記述子のつながり: (アドレス, 長さ, 書き込み用か)
    private func chain(_ q: Queue, head: UInt16) -> [(addr: UInt64, len: Int, writable: Bool)] {
        var out: [(addr: UInt64, len: Int, writable: Bool)] = []
        var i = head
        let num = q.size
        for _ in 0..<Int(num) {
            let d = q.desc + 16 * UInt64(i % num)
            let flags = load16(d + 12)
            out.append((load64(d), Int(load32(d + 8)), flags & VirtioMMIO.descWrite != 0))
            if flags & VirtioMMIO.descNext == 0 { break }
            i = load16(d + 14)
        }
        return out
    }

    /// 使い終わった入れ物を used リングに返す
    private func pushUsed(_ q: Queue, head: UInt16, len: Int) {
        let usedIdx = load16(q.used + 2)
        let slot = q.used + 4 + 8 * UInt64(usedIdx % q.size)
        store32(slot, UInt32(head))
        store32(slot + 4, UInt32(len))
        store16(q.used + 2, usedIdx &+ 1)
    }

    /// 送り出し用のキューに並んだフレームを取り出して onTransmit に渡す
    private func transmit() {
        let qi = VirtioMMIO.txQueue
        guard queues[qi].ready != 0 else { return }
        let end = availIdx(queues[qi])
        var did = false
        var guardCount = 0
        while queues[qi].lastAvail != end && guardCount < Int(queues[qi].size) * 2 {
            guardCount += 1
            let head = nextAvailHead(queues[qi])
            var bytes: [UInt8] = []
            for d in chain(queues[qi], head: head) where !d.writable {
                guard d.len > 0, d.len <= 65536, let p = ram.pointer(d.addr, count: d.len) else { continue }
                bytes.append(contentsOf: UnsafeRawBufferPointer(start: p, count: d.len))
            }
            if bytes.count > VirtioMMIO.netHeaderSize {
                onTransmit?(Array(bytes[VirtioMMIO.netHeaderSize...]))
            }
            pushUsed(queues[qi], head: head, len: 0)
            queues[qi].lastAvail &+= 1
            did = true
        }
        if did { interruptStatus |= 1 }
    }

    /// 取っておいたフレームを、OS が並べた受け取り用の入れ物に書く
    private func deliverPending() {
        let qi = VirtioMMIO.rxQueue
        guard queues[qi].ready != 0 else { return }
        var did = false
        lock.lock()
        while !pending.isEmpty {
            if queues[qi].lastAvail == availIdx(queues[qi]) { break }       // 入れ物が無い: あとで
            let head = nextAvailHead(queues[qi])
            // ヘッダ（10 バイトの 0）+ フレームを、入れ物の記述子に順に詰める
            let full = [UInt8](repeating: 0, count: VirtioMMIO.netHeaderSize) + pending.removeFirst()
            var written = 0
            for d in chain(queues[qi], head: head) where d.writable {
                if written >= full.count { break }
                let n = min(d.len, full.count - written)
                guard n > 0, let p = ram.pointer(d.addr, count: n) else { continue }
                full.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress! + written, byteCount: n) }
                written += n
            }
            pushUsed(queues[qi], head: head, len: written)
            queues[qi].lastAvail &+= 1
            did = true
        }
        hasPending = !pending.isEmpty
        lock.unlock()
        if did { interruptStatus |= 1 }
    }
}

// ======================================================================
// MARK: - VNetDriver.swift
// ======================================================================

// MARK: - ゲスト側の virtio-net ドライバ（Linux の virtio_net ドライバの代わり）
//
// 仮想 LAN カード（VirtioNet）のレジスタを、Linux と同じ順番で読み書きして使えるようにする。
// ・キューは 2 つ: 0 = 受け取り用、1 = 送り出し用（古い形 = legacy の virtio-mmio）
// ・受け取り用には、あらかじめ空の入れ物（2KB）を並べておく。カードが届いたフレームを書いてくれる
// ・送るときは、入れ物に [ヘッダ 10 バイト][フレーム] を書いて、avail リングに並べて「通知」する
// すべて 1 本のキュー（VNetMachine.queue）の上で呼ぶこと
final class VirtioNetDriver: @unchecked Sendable {
    let dev: VirtioNet
    let ram: GuestRAM
    let qsize = 256
    let bufSize = 2048
    private(set) var mac: [UInt8] = []

    /// 1 本のキュー（記述子表・avail・used と、入れ物）
    private struct Ring {
        let ram: GuestRAM
        let size: Int
        var desc: UInt64 = 0, avail: UInt64 = 0, used: UInt64 = 0
        var bufs: [UInt64] = []
        var lastUsed: UInt16 = 0
        var availIdx: UInt16 = 0

        func writeDesc(_ i: Int, len: Int, writable: Bool) {
            let d = desc + 16 * UInt64(i)
            ram.store64(d, bufs[i])
            ram.store32(d + 8, UInt32(len))
            ram.store16(d + 12, writable ? VirtioMMIO.descWrite : 0)
            ram.store16(d + 14, 0)
        }

        /// 入れ物 i を avail リングに積む（カードに見せるのは publish で）
        mutating func offer(_ i: Int) {
            ram.store16(avail + 4 + 2 * UInt64(Int(availIdx) % size), UInt16(i))
            availIdx &+= 1
        }

        /// 積んだ分をカードに見せる
        func publish() { ram.store16(avail + 2, availIdx) }

        /// カードが使い終わった入れ物を 1 つ取る（無ければ nil）
        mutating func takeUsed() -> (id: Int, len: Int)? {
            guard lastUsed != ram.load16(used + 2) else { return nil }
            let slot = used + 4 + 8 * UInt64(Int(lastUsed) % size)
            lastUsed &+= 1
            return (Int(ram.load32(slot)), Int(ram.load32(slot + 4)))
        }
    }
    private var rx: Ring
    private var tx: Ring
    private var txFree: [Int] = []
    /// まだ入れ物が空かず送れていないフレーム
    private var txWaiting: [[UInt8]] = []

    /// 届いたフレーム（ヘッダを除いたイーサネットのフレーム）
    var onReceive: (([UInt8]) -> Void)?

    init(dev: VirtioNet, ram: GuestRAM) {
        self.dev = dev
        self.ram = ram
        rx = Ring(ram: ram, size: qsize)
        tx = Ring(ram: ram, size: qsize)
    }

    struct DriverError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    private func r32(_ off: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: dev.read(off, size: 4)) }
    private func w32(_ off: UInt64, _ v: UInt32) { dev.write(off, size: 4, value: UInt64(v)) }

    /// Linux の virtio_mmio + virtio_net と同じ手順でカードを準備する
    func start() throws {
        typealias R = VirtioMMIO.Reg
        guard r32(R.magic) == VirtioMMIO.magicValue else { throw DriverError("virtio の目印がありません") }
        guard r32(R.deviceID) == VirtioMMIO.deviceNet else { throw DriverError("ネットワークのカードではありません") }
        let ackDriver = VirtioMMIO.statusAcknowledge | VirtioMMIO.statusDriver
        w32(R.status, 0)                                   // リセット
        w32(R.status, VirtioMMIO.statusAcknowledge)        // 見つけた
        w32(R.status, ackDriver)                           // 使い方が分かる
        w32(R.deviceFeaturesSel, 0)
        let features = r32(R.deviceFeatures)
        w32(R.driverFeaturesSel, 0)
        w32(R.driverFeatures, features & UInt32(VirtioMMIO.featureNetMAC))   // MAC アドレスだけ使う
        w32(R.guestPageSize, 4096)
        mac = (0..<6).map { UInt8(truncatingIfNeeded: dev.read(R.config + UInt64($0), size: 1)) }
        rx = setupQueue(VirtioMMIO.rxQueue)
        tx = setupQueue(VirtioMMIO.txQueue)
        // 受け取り用: 空の入れ物を全部並べる
        for i in 0..<qsize {
            rx.writeDesc(i, len: bufSize, writable: true)
            rx.offer(i)
        }
        rx.publish()
        txFree = Array(0..<qsize)
        w32(R.status, ackDriver | VirtioMMIO.statusDriverOK)   // 使い始める
        w32(R.queueNotify, UInt32(VirtioMMIO.rxQueue))
    }

    /// キューを 1 つ用意する（古い形: ページ番号 = PFN で場所を伝える）
    private func setupQueue(_ q: Int) -> Ring {
        typealias R = VirtioMMIO.Reg
        w32(R.queueSel, UInt32(q))
        precondition(Int(r32(R.queueNumMax)) >= qsize)
        w32(R.queueNum, UInt32(qsize))
        w32(R.queueAlign, 4096)
        // 記述子表 (16 × n) + avail (4 + 2n + 2)、used は 4096 の倍数から (4 + 8n + 2)
        let n = UInt64(qsize)
        let availEnd = 16 * n + 4 + 2 * n + 2
        let usedOff = (availEnd + 4095) / 4096 * 4096
        let total = Int(usedOff + 4 + 8 * n + 2)
        let area = ram.alloc(total, align: 4096)
        var r = Ring(ram: ram, size: qsize)
        r.desc = area
        r.avail = area + 16 * n
        r.used = area + usedOff
        r.bufs = (0..<qsize).map { _ in ram.alloc(bufSize, align: 64) }
        w32(R.queuePFN, UInt32(area / 4096))
        return r
    }

    /// フレームを送る（入れ物が無ければ、空くまで待たせる）
    func send(_ frame: [UInt8]) {
        txWaiting.append(frame)
        reclaimTX()
        flushTX()
    }

    private func flushTX() {
        let hdr = VirtioMMIO.netHeaderSize
        var did = false
        while !txWaiting.isEmpty, let i = txFree.popLast() {
            let frame = txWaiting.removeFirst()
            let p = ram.pointer(tx.bufs[i])
            p.initializeMemory(as: UInt8.self, repeating: 0, count: hdr)
            let n = min(frame.count, bufSize - hdr)
            frame.withUnsafeBytes { (p + hdr).copyMemory(from: $0.baseAddress!, byteCount: n) }
            tx.writeDesc(i, len: hdr + n, writable: false)
            tx.offer(i)
            did = true
        }
        if did {
            tx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.txQueue))   // → カードが onTransmit に渡す
        }
    }

    /// 送り終わった入れ物を回収する
    private func reclaimTX() {
        while let u = tx.takeUsed() {
            if u.id < qsize { txFree.append(u.id) }
        }
    }

    /// 割り込みが来ていれば、届いたフレームを取り出す（カードから知らせがあったときに呼ぶ）
    func poll() {
        guard dev.interruptLine else { return }
        w32(VirtioMMIO.Reg.interruptACK, r32(VirtioMMIO.Reg.interruptStatus))   // 割り込みを受け取った
        reclaimTX()
        flushTX()
        let hdr = VirtioMMIO.netHeaderSize
        var reposted = false
        while let u = rx.takeUsed() {
            guard u.id < qsize else { continue }
            if u.len > hdr {
                let p = ram.pointer(rx.bufs[u.id]) + hdr
                onReceive?([UInt8](UnsafeRawBufferPointer(start: p, count: min(u.len, bufSize) - hdr)))
            }
            rx.offer(u.id)                                 // 入れ物を戻す
            reposted = true
        }
        if reposted {
            rx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.rxQueue))
        }
    }
}

// ======================================================================
// MARK: - UserNet.swift
// ======================================================================

// MARK: - アプリの中の小さなルーター（ユーザーモードの NAT。QEMU の「SLIRP」と同じ考え方）
//
// ゲストの eth0 から出たイーサネットのフレームを受け取り、中身の TCP / UDP を
// iPad の普通の通信（Network.framework）に置き換えて外に出す。返事はフレームに組み立て直してゲストに返す。
//
//   ゲスト 10.0.2.15 ── ルーター 10.0.2.2（＝このクラス）── iPad の通信 ── インターネット
//                        DNS は 10.0.2.3（iPad の名前解決を使う）
//
// ・ARP: 10.0.2.x を聞かれたら、自分の MAC で答える
// ・DHCP: 10.0.2.15 を配る（ルーター 10.0.2.2、DNS 10.0.2.3）
// ・DNS: A レコードは iPad で名前解決して答える。AAAA などは「無し」と答える（IPv4 だけ使う）
// ・TCP: ゲストとの TCP はここで終わらせ、外へは iPad の TCP 接続でつなぐ（中身だけ中継する）
// ・UDP: 宛先ごとに iPad の UDP 接続を作って中継する
// ・ping（ICMP）: 10.0.2.x にだけ答える（iPad のアプリは外へ ping を打てない）
// すべて queue（1 本の直列キュー）の上で動く。

/// 外への接続（TCP か UDP）。受け取りは readMore() を呼ぶたびに 1 回分ずつ届く
protocol UserNetSocket: AnyObject, Sendable {
    func send(_ data: Data)
    /// 送り終わったら閉じる（TCP の FIN）
    func finish()
    func close()
    func readMore()
}

/// 外への接続を作るもの（iPad では Network.framework）。
/// 呼び出し（onReady など）は必ず queue の上で行うこと
protocol UserNetSocketFactory {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (_ error: Bool) -> Void) -> UserNetSocket
    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket
}

final class UserNet: @unchecked Sendable {
    let queue = DispatchQueue(label: "usernet")
    let factory: UserNetSocketFactory
    /// ゲストへ送るフレーム（queue の上で呼ばれる）
    var onFrame: (([UInt8]) -> Void)?
    /// ログ
    var log: ((String) -> Void)?
    /// ゲストの MAC アドレス（届いたフレームから覚える）
    private var guestMAC = Net.guestMAC

    private var ipID: UInt16 = 1
    private var tcps: [TCPKey: TCPConn] = [:]
    private var udps: [UDPKey: UDPFlow] = [:]
    private var timer: DispatchSourceTimer?

    init(factory: UserNetSocketFactory) {
        self.factory = factory
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// ゲストから出たフレーム（どのスレッドからでもよい）
    func input(_ frame: [UInt8]) {
        queue.async { self.handleFrame(frame) }
    }

    // MARK: イーサネット

    private func handleFrame(_ f: [UInt8]) {
        guard f.count >= Ethernet.headerSize else { return }
        if f[6] & 1 == 0 { guestMAC = Array(f[6..<12]) }
        let body = Array(f[Ethernet.headerSize...])
        switch f.be16(at: 12) {
        case EtherType.arp: handleARP(body)
        case EtherType.ipv4: handleIPv4(body)
        default: break        // IPv6 などは使わない
        }
    }

    private func sendEthernet(_ type: UInt16, _ payload: [UInt8], to dst: [UInt8]? = nil) {
        onFrame?(Ethernet.frame(dst: dst ?? guestMAC, src: Net.routerMAC, type: type, payload))
    }

    // MARK: ARP

    private func handleARP(_ p: [UInt8]) {
        guard p.count >= 28, p.be16(at: 6) == ARP.request else { return }     // 問い合わせだけ
        let target = Array(p[24..<28])
        guard Net.isLocal(target), target != Net.guestIP else { return }
        let senderMAC = Array(p[8..<14]), senderIP = Array(p[14..<18])
        let r = ARP.packet(op: ARP.reply, senderMAC: Net.routerMAC, senderIP: target, targetMAC: senderMAC, targetIP: senderIP)
        sendEthernet(EtherType.arp, r, to: senderMAC)
    }

    // MARK: IPv4

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p), !pkt.isFragment else { return }   // 分割されたものは扱わない（MTU 1500 なので普通は来ない）
        switch pkt.proto {
        case IPProto.icmp: handleICMP(src: pkt.src, dst: pkt.dst, pkt.body)
        case IPProto.tcp: handleTCP(dst: pkt.dst, pkt.body)
        case IPProto.udp: handleUDP(dst: pkt.dst, pkt.body)
        default: break
        }
    }

    private func sendIPv4(proto: UInt8, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8], to mac: [UInt8]? = nil) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: src, dst: dst, dontFragment: dontFragment, body)
        ipID &+= 1
        sendEthernet(EtherType.ipv4, pkt, to: mac)
    }

    /// ゲストが指定した宛先 IP を、iPad 側でつなぐ相手の名前にする（10.0.2.x・ループバック・マルチキャストはつながない）
    private func hostFor(_ ip: [UInt8]) -> String? {
        if Net.isLocal(ip) || ip[0] == 127 || ip[0] == 0 || ip[0] >= 224 { return nil }
        return ip.ipString
    }

    // MARK: ICMP（ping）

    private func handleICMP(src: [UInt8], dst: [UInt8], _ b: [UInt8]) {
        guard b.count >= 8, b[0] == 8, Net.isLocal(dst) else { return }    // echo request だけ
        var r = b
        r[0] = 0; r[2] = 0; r[3] = 0                                        // echo reply
        r.setBE16(Checksum.internet(r), at: 2)
        sendIPv4(proto: IPProto.icmp, src: dst, dst: src, r)
    }

    // MARK: UDP

    private struct UDPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }
    private final class UDPFlow: @unchecked Sendable {
        var sock: UserNetSocket?
        var last = Date()
    }

    private func sendUDP(src: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) {
        let u = UDPDatagram.build(src: src, dst: Net.guestIP, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, src: src, dst: Net.guestIP, u)
    }

    private func handleUDP(dst: [UInt8], _ b: [UInt8]) {
        guard let d = UDPDatagram(b) else { return }
        if d.dport == 67 { handleDHCP(d.payload); return }
        if dst == Net.dns && d.dport == 53 { handleDNS(d.payload, sport: d.sport); return }
        guard let host = hostFor(dst) else { return }
        let sport = d.sport, dport = d.dport
        let key = UDPKey(sport: sport, dst: dst, dport: dport)
        let flow: UDPFlow
        if let f = udps[key] { flow = f } else {
            let f = UDPFlow()
            let sock = factory.udp(host: host, port: dport, queue: queue, onData: { [weak self, weak f] data in
                guard let self else { return }
                f?.last = Date()
                self.sendUDP(src: dst, sport: dport, dport: sport, Array(data))
            }, onClose: { [weak self] in self?.udps[key] = nil })
            f.sock = sock
            flow = f
            udps[key] = f
            sock.readMore()
        }
        flow.last = Date()
        flow.sock?.send(Data(d.payload))
    }

    // MARK: DHCP

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 1, Array(p[236..<240]) == DHCP.magicCookie else { return }
        let reply: UInt8
        switch DHCP.options(p)[53]?.first ?? 0 {
        case DHCP.discover: reply = DHCP.offer
        case DHCP.request: reply = DHCP.ack
        default: return
        }
        var r = [UInt8](repeating: 0, count: 236)
        r[0] = 2; r[1] = 1; r[2] = 6
        r.replaceSubrange(4..<8, with: p[4..<8])           // xid
        r[10] = p[10]; r[11] = p[11]                       // flags
        r.replaceSubrange(16..<20, with: Net.guestIP)      // yiaddr
        r.replaceSubrange(20..<24, with: Net.gateway)      // siaddr
        r.replaceSubrange(28..<44, with: p[28..<44])       // chaddr
        r += DHCP.magicCookie
        r += [53, 1, reply]
        r += [54, 4] + Net.gateway
        r += [51, 4, 0, 1, 0x51, 0x80]                     // 86400 秒
        r += [1, 4, 255, 255, 255, 0]
        r += [3, 4] + Net.gateway
        r += [6, 4] + Net.dns
        r += [26, 2, 0x05, 0xDC]                           // MTU 1500
        r += [255]
        // ブロードキャストで返す（ゲストはまだ IP を持っていないので）
        let u = UDPDatagram.build(src: Net.gateway, dst: Net.broadcastIP, sport: 67, dport: 68, r)
        sendIPv4(proto: IPProto.udp, src: Net.gateway, dst: Net.broadcastIP, dontFragment: false, u, to: Net.broadcastMAC)
        log?("[ネット] DHCP \(reply == DHCP.offer ? "OFFER" : "ACK") \(Net.guestIP.ipString)")
    }

    // MARK: DNS

    private func handleDNS(_ q: [UInt8], sport: UInt16) {
        guard q.count >= 12 else { return }
        guard q.be16(at: 4) == 1 else {                    // 質問が 1 つでなければ「できません」
            sendDNS(DNSMessage.reply(to: q, questionEnd: 12, rcode: 4, answers: []), sport: sport)
            return
        }
        guard let question = DNSMessage.question(q) else { return }
        if question.type != 1 || question.name.isEmpty {   // A 以外は「無し」
            sendDNS(DNSMessage.reply(to: q, questionEnd: question.end, rcode: 0, answers: []), sport: sport)
            return
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let addrs = UserNet.resolveIPv4(question.name)
            let r = DNSMessage.reply(to: q, questionEnd: question.end, rcode: addrs == nil ? 3 : 0, answers: addrs ?? [])
            queue.async { [weak self] in self?.sendDNS(r, sport: sport) }
        }
    }

    private func sendDNS(_ r: [UInt8], sport: UInt16) {
        sendUDP(src: Net.dns, sport: 53, dport: sport, r)
    }

    /// 名前を IPv4 アドレスにする（nil = 見つからない）
    static func resolveIPv4(_ name: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if a.pointee.ai_family == AF_INET, let sa = a.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    let v = sin.pointee.sin_addr.s_addr       // ネットワークの順（ビッグエンディアン）のまま
                    let b = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
                    if !out.contains(b) { out.append(b) }
                }
            }
            p = a.pointee.ai_next
        }
        return out.isEmpty ? nil : Array(out.prefix(8))
    }

    // MARK: TCP

    private struct TCPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }

    private final class TCPConn: @unchecked Sendable {
        let key: TCPKey
        var sock: UserNetSocket?
        var state = State.connecting
        enum State { case connecting, synSent, established, closed }
        var rcvNxt: UInt32 = 0            // ゲストから次に来るはずの番号
        let iss: UInt32                   // こちらの最初の番号
        var sndUna: UInt32                // ゲストがまだ受け取ったと言っていない最初の番号
        var sndNxt: UInt32                // 次に送る番号
        /// 外から来た（まだ受け取りの返事が無い）データ。buf[bufPos...] が sndUna から先。
        /// 先頭を消すとそのたびに全部ずらすことになって遅いので、位置で覚えてときどき詰める
        var buf = [UInt8]()
        var bufPos = 0
        var pending: Int { buf.count - bufPos }
        var window: UInt32 = 65535
        var mss = 536
        var remoteEOF = false             // 外の相手が閉じた
        var finSent = false
        var guestFIN = false
        var lastProgress = Date()
        var retries = 0
        var reading = false
        var lastActivity = Date()
        init(key: TCPKey) {
            self.key = key
            iss = UInt32.random(in: 0...UInt32.max)
            sndUna = iss
            sndNxt = iss
        }

        /// ゲストが受け取ったと言った分を buf から外す
        func dropAcked(_ n: Int) {
            guard n > 0 else { return }
            bufPos += n
            if bufPos == buf.count { buf.removeAll(keepingCapacity: true); bufPos = 0 }
            else if bufPos > 131072 && bufPos * 2 > buf.count { buf.removeFirst(bufPos); bufPos = 0 }
        }
    }

    static let maxBuffered = 512 * 1024

    /// 外の相手のふりをして、ゲストへセグメントを送る
    private func sendTCP(_ c: TCPConn, _ flags: TCPFlags, seq: UInt32, payload: ArraySlice<UInt8> = [], mss: Bool = false) {
        // こちらの受け取り窓は 65535 のまま: 外へ送り切れていない分は気にしない（iPad の接続が受け取る）
        let seg = TCPSegment.build(src: c.key.dst, dst: Net.guestIP, sport: c.key.dport, dport: c.key.sport,
                                   seq: seq, ack: c.rcvNxt, flags: flags, mss: mss, payload: payload)
        sendIPv4(proto: IPProto.tcp, src: c.key.dst, dst: Net.guestIP, seg)
    }

    private func sendSYNACK(_ c: TCPConn) { sendTCP(c, [.syn, .ack], seq: c.iss, mss: true) }

    /// 外の相手のふりをして、ゲストへ RST を送る
    private func sendRST(remote: [UInt8], remotePort: UInt16, guestPort: UInt16, seq: UInt32, ack: UInt32) {
        let seg = TCPSegment.build(src: remote, dst: Net.guestIP, sport: remotePort, dport: guestPort,
                                   seq: seq, ack: ack, flags: [.rst, .ack], window: 0)
        sendIPv4(proto: IPProto.tcp, src: remote, dst: Net.guestIP, seg)
    }

    private func sendRST(_ c: TCPConn, seq: UInt32) {
        sendRST(remote: c.key.dst, remotePort: c.key.dport, guestPort: c.key.sport, seq: seq, ack: c.rcvNxt)
    }

    private func handleTCP(dst: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b) else { return }
        let payload = b[h.headerLength...]
        let key = TCPKey(sport: h.sport, dst: dst, dport: h.dport)
        guard let c = tcps[key] else {
            open(key, h, b)
            return
        }

        c.lastActivity = Date()
        if h.flags.contains(.rst) { remove(c); return }
        if h.flags.contains(.syn) {
            // SYN の送り直し: SYN+ACK を送り直す
            if c.state == .synSent { sendSYNACK(c) }
            return
        }
        if h.flags.contains(.ack) {
            let acked = h.ack &- c.sndUna
            let inFlight = c.sndNxt &- c.sndUna
            if acked > 0 && acked <= inFlight {
                var n = Int(acked)
                if c.state == .synSent { c.state = .established; n -= 1 }     // SYN の分
                c.dropAcked(min(n, c.pending))
                c.sndUna = h.ack
                c.lastProgress = Date()
                c.retries = 0
                readIfRoom(c)
            }
            c.window = UInt32(h.window)
        }
        if c.state == .synSent || c.state == .connecting { return }
        // データ
        var needAck = false
        if !payload.isEmpty {
            if h.seq == c.rcvNxt {
                c.sock?.send(Data(payload))
                c.rcvNxt &+= UInt32(payload.count)
            }
            needAck = true
        }
        if h.flags.contains(.fin) && h.seq &+ UInt32(payload.count) == c.rcvNxt && !c.guestFIN {
            c.guestFIN = true
            c.rcvNxt &+= 1
            c.sock?.finish()
            needAck = true
        }
        let before = c.sndNxt
        pump(c)
        if needAck && c.sndNxt == before { sendTCP(c, .ack, seq: c.sndNxt) }
        checkDone(c)
    }

    /// 知らない接続のセグメント: SYN なら外へつなぎに行く（つながったら SYN+ACK を返す）。ほかは RST で終わらせてもらう
    private func open(_ key: TCPKey, _ h: TCPHeader, _ b: [UInt8]) {
        if h.flags.contains(.rst) { return }
        guard h.flags.contains(.syn), !h.flags.contains(.ack), let host = hostFor(key.dst) else {
            let payloadCount = UInt32(b.count - h.headerLength)
            let extra: UInt32 = h.flags.isDisjoint(with: [.syn, .fin]) ? 0 : 1
            sendRST(remote: key.dst, remotePort: key.dport, guestPort: key.sport,
                    seq: h.flags.contains(.ack) ? h.ack : 0, ack: h.seq &+ payloadCount &+ extra)
            return
        }
        let c = TCPConn(key: key)
        c.rcvNxt = h.seq &+ 1
        c.window = UInt32(h.window)
        if let m = TCPHeader.mss(b, headerLength: h.headerLength) { c.mss = min(1460, m) }
        tcps[key] = c
        c.sock = factory.tcp(host: host, port: key.dport, queue: queue, onReady: { [weak self, weak c] in
            guard let self, let c, c.state == .connecting else { return }
            c.state = .synSent
            self.sendSYNACK(c)
            c.sndNxt = c.iss &+ 1
            c.lastProgress = Date()
            self.readIfRoom(c)
        }, onData: { [weak self, weak c] d in
            guard let self, let c else { return }
            c.reading = false
            c.buf.append(contentsOf: d)
            c.lastActivity = Date()
            self.pump(c)
            self.readIfRoom(c)
        }, onClose: { [weak self, weak c] error in
            guard let self, let c else { return }
            c.reading = false
            if c.state == .connecting || (error && c.state != .established) {
                // つながらなかった
                self.sendRST(c, seq: c.iss &+ 1)
                self.remove(c)
                return
            }
            c.remoteEOF = true
            self.pump(c)
        })
    }

    /// 外から来たデータを、ゲストの窓の分だけ送る。外が閉じていて全部送ったら FIN
    private func pump(_ c: TCPConn) {
        guard c.state == .established else { return }
        while !c.finSent {
            let sent = Int(c.sndNxt &- c.sndUna)
            let unsent = c.pending - sent
            if unsent <= 0 {
                if c.remoteEOF {
                    sendTCP(c, [.fin, .ack], seq: c.sndNxt)
                    c.sndNxt &+= 1
                    c.finSent = true
                    c.lastProgress = Date()
                }
                break
            }
            let room = Int(c.window) - sent
            if room <= 0 { break }
            let n = min(unsent, c.mss, room)
            let start = c.bufPos + sent
            sendTCP(c, [.ack, .psh], seq: c.sndNxt, payload: c.buf[start..<(start + n)])
            c.sndNxt &+= UInt32(n)
        }
        checkDone(c)
    }

    private func readIfRoom(_ c: TCPConn) {
        guard !c.reading, !c.remoteEOF, c.state == .established || c.state == .synSent,
              c.pending < UserNet.maxBuffered, let s = c.sock else { return }
        c.reading = true
        s.readMore()
    }

    private func checkDone(_ c: TCPConn) {
        // 両方が閉じて、こちらの FIN も受け取ってもらえたら終わり
        if c.guestFIN && c.finSent && c.sndUna == c.sndNxt { remove(c) }
    }

    private func remove(_ c: TCPConn) {
        if c.state == .closed { return }
        c.state = .closed
        c.sock?.close()
        c.sock = nil
        if tcps[c.key] === c { tcps[c.key] = nil }
    }

    // MARK: 時間で見るもの（送り直しと、古い接続の片付け）

    private func tick() {
        let now = Date()
        for c in Array(tcps.values) {
            if c.state == .synSent && now.timeIntervalSince(c.lastProgress) > 1 {
                c.retries += 1
                if c.retries > 6 { remove(c); continue }
                sendSYNACK(c)
                c.lastProgress = now
            } else if c.state == .established && c.sndNxt != c.sndUna && now.timeIntervalSince(c.lastProgress) > 1 {
                // 受け取りの返事が来ない: 先頭から送り直す
                c.retries += 1
                if c.retries > 10 {
                    sendRST(c, seq: c.sndNxt)
                    remove(c); continue
                }
                c.sndNxt = c.sndUna
                c.finSent = false
                c.lastProgress = now
                if c.window == 0 { c.window = 1 }       // 窓が 0 のままなら 1 バイトだけ送って様子を見る
                pump(c)
            } else if now.timeIntervalSince(c.lastActivity) > 600 {
                remove(c)
            }
        }
        for (k, u) in udps where now.timeIntervalSince(u.last) > 60 {
            u.sock?.close()
            udps[k] = nil
        }
    }
}

// ======================================================================
// MARK: - UserNetApple.swift
// ======================================================================

#if canImport(Network)
import Foundation
import Network

// MARK: - UserNet の外への接続を、iPad の Network.framework で作る

final class NWUserNetFactory: UserNetSocketFactory, @unchecked Sendable {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (Bool) -> Void) -> UserNetSocket {
        let opts = NWProtocolTCP.Options()
        opts.noDelay = true
        opts.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: opts)
        // iPad の「プロキシ」（iCloud プライベートリレーなど）を通さず、相手に直接つなぐ。
        // プロキシを通ると、暗号化していない http の要求がプロキシに読まれて「400 Bad Request」で断られることがある
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: params)
        let s = NWUserNetSocket(c, datagram: false, onData: onData, onClose: onClose)
        c.stateUpdateHandler = { [weak s] st in
            guard let s else { return }
            switch st {
            case .ready:
                if !s.readyCalled { s.readyCalled = true; onReady() }
            case .failed, .cancelled:
                s.closed(error: true)
            default:
                // .waiting（つながらない・ネットが無いなど）は、iPad が自分でやり直すので切らない
                // （connectionTimeout を過ぎると failed になる）
                break
            }
        }
        c.start(queue: queue)
        return s
    }

    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket {
        let params = NWParameters.udp
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 53, using: params)
        let s = NWUserNetSocket(c, datagram: true, onData: onData, onClose: { _ in onClose() })
        c.stateUpdateHandler = { [weak s] st in
            switch st {
            case .failed, .cancelled: s?.closed(error: true)
            default: break
            }
        }
        c.start(queue: queue)
        return s
    }
}

final class NWUserNetSocket: UserNetSocket, @unchecked Sendable {
    let conn: NWConnection
    let datagram: Bool
    let onData: @Sendable (Data) -> Void
    let onClose: @Sendable (Bool) -> Void
    var readyCalled = false
    private var done = false

    init(_ c: NWConnection, datagram: Bool, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        conn = c; self.datagram = datagram; self.onData = onData; self.onClose = onClose
    }

    func closed(error: Bool) {
        if done { return }
        done = true
        conn.cancel()
        onClose(error)
    }

    func send(_ data: Data) {
        if done { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func finish() {
        if done || datagram { return }
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        if done { return }
        done = true
        conn.cancel()
    }

    func readMore() {
        if done { return }
        if datagram {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.done else { return }
                if let d = data, !d.isEmpty { self.onData(d) }
                if error != nil { self.closed(error: true); return }
                self.readMore()          // UDP は続けて受け取る
            }
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let d = data, !d.isEmpty {
                self.onData(d)
                if isComplete { self.closed(error: false) }
                return
            }
            if isComplete || error != nil { self.closed(error: error != nil) }
            else { self.readMore() }
        }
    }
}
#endif
