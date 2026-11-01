import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
