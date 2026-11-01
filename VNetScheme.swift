import WebKit

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
