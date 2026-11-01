import WebKit

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
        pending[ObjectIdentifier(task)] = nil
    }

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
