import Foundation

// MARK: - 通信の全部（GuestStack → virtio-net → UserNet → 偽のサーバー）を Linux で動かすテスト
//
// UserNetSocketFactory を偽物にして、外のサーバーの代わりに FakeNet が返事をする。
// フレームを捨てる・入れ替える、をはさんで TCP の送り直し・並べ直しも確かめる

/// 偽のサーバーに届いた要求
struct FakeRequest {
    var method: String
    var path: String
    var headers: [(String, String)]
    var body: Data
    var server: String
}

enum FakeReply {
    case raw(String)
    case data(Data)
    /// 返事をしない（取り消しのテスト用）
    case hang
}

/// 外の世界の代わり（サーバーは "IP:ポート" ごと）
final class FakeNet: UserNetSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: (FakeRequest) -> FakeReply] = [:]
    private var _received: [FakeRequest] = []
    private var _connections = 0

    func serve(_ key: String, _ h: @escaping (FakeRequest) -> FakeReply) { lock.lock(); servers[key] = h; lock.unlock() }
    var received: [FakeRequest] { lock.lock(); defer { lock.unlock() }; return _received }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }

    fileprivate func handle(_ r: FakeRequest) -> FakeReply? {
        lock.lock()
        _received.append(r)
        let h = servers[r.server]
        lock.unlock()
        return h?(r)
    }

    fileprivate func hasServer(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return servers[key] != nil }

    func tcp(host: String, port: UInt16, queue: DispatchQueue, onReady: @escaping @Sendable () -> Void,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) -> UserNetSocket {
        let key = "\(host):\(port)"
        lock.lock(); _connections += 1; lock.unlock()
        let s = FakeSocket(net: self, key: key, queue: queue, onData: onData, onClose: onClose)
        queue.async {
            if self.hasServer(key) { onReady() } else { onClose(true) }
        }
        return s
    }

    func udp(host: String, port: UInt16, queue: DispatchQueue, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable () -> Void) -> UserNetSocket {
        FakeUDP()
    }
}

final class FakeUDP: UserNetSocket, @unchecked Sendable {
    func send(_ data: Data) {}
    func finish() {}
    func close() {}
    func readMore() {}
}

/// 偽のサーバーへの 1 本の接続（すべて UserNet の queue の上で呼ばれる）
final class FakeSocket: UserNetSocket, @unchecked Sendable {
    let net: FakeNet
    let key: String
    let queue: DispatchQueue
    let onData: @Sendable (Data) -> Void
    let onClose: @Sendable (Bool) -> Void
    private var inbox = Data()
    private var outbox: [Data] = []
    private var wantRead = false
    private var closed = false

    init(net: FakeNet, key: String, queue: DispatchQueue, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        self.net = net; self.key = key; self.queue = queue; self.onData = onData; self.onClose = onClose
    }

    func send(_ data: Data) {
        inbox.append(data)
        while let r = takeRequest() {
            switch net.handle(r) {
            case .raw(let s)?: queueOut(Data(s.utf8))
            case .data(let d)?: queueOut(d)
            case .hang?, nil: break
            }
        }
    }

    private func queueOut(_ d: Data) {
        var i = 0
        while i < d.count { let n = min(16384, d.count - i); outbox.append(d.subdata(in: i..<(i + n))); i += n }
        flush()
    }

    /// 届いたバイトから、要求を 1 つ取り出す（ヘッダの終わり ＋ Content-Length）
    private func takeRequest() -> FakeRequest? {
        guard let end = inbox.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: inbox[inbox.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [(String, String)] = []
        for l in lines { if let c = l.firstIndex(of: ":") { headers.append((String(l[..<c]), String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces))) } }
        let len = Int(headers.value(for: "Content-Length") ?? "0") ?? 0
        guard inbox.count - (end.upperBound - inbox.startIndex) >= len else { return nil }
        let body = inbox.subdata(in: end.upperBound..<(end.upperBound + len))
        inbox = Data(inbox[(end.upperBound + len)...])
        return FakeRequest(method: first.count > 0 ? String(first[0]) : "", path: first.count > 1 ? String(first[1]) : "",
                           headers: headers, body: body, server: key)
    }

    private func flush() {
        guard wantRead, !closed, !outbox.isEmpty else { return }
        wantRead = false
        let d = outbox.removeFirst()
        let cb = onData
        queue.async { cb(d) }
    }

    func readMore() { wantRead = true; flush() }
    func finish() {}
    func close() { closed = true }
}

// MARK: 道具

/// 返事を作る
func httpReply(_ status: Int = 200, _ body: String = "", headers: [(String, String)] = []) -> FakeReply {
    var s = "HTTP/1.1 \(status) X\r\n"
    for (k, v) in headers { s += "\(k): \(v)\r\n" }
    s += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    return .raw(s)
}

let ipSite: [UInt8] = [93, 184, 216, 34]
let ipOther: [UInt8] = [93, 184, 216, 35]
let ipLAN: [UInt8] = [192, 168, 1, 10]

/// 偽の世界につないだ VNet を作って、IP をもらうまで待つ
func makeMachine(_ net: FakeNet, names: [String: [UInt8]] = [:], limits: PoolLimits? = nil) -> (VNetMachine, CookieJar, HSTSStore)? {
    let m = VNetMachine(factory: net)
    let table = names
    m.router.resolver = { name in table[name].map { [$0] } }
    let jar = CookieJar()
    let hsts = HSTSStore(fileURL: nil)
    m.configurePolicies(cookieJar: jar, hsts: hsts, localNetworkProtection: true)
    if let limits { m.queue.async { m.pool.limits = limits } }
    m.boot()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if statsOf(m)?.ready == true { return (m, jar, hsts) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    expect(false, "IP をもらえませんでした")
    return nil
}

/// 送って、返事を待つ
func fetch(_ m: VNetMachine, _ req: HTTPRequest, follow: Bool = true, timeout: TimeInterval = 20) -> Result<HTTPResult, FetchError>? {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox()
    m.send(req, followRedirects: follow) { r in box.set(r); sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut { expect(false, "時間切れ: \(req.url)"); return nil }
    return box.get()
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var r: Result<HTTPResult, FetchError>?
    func set(_ v: Result<HTTPResult, FetchError>) { lock.lock(); r = v; lock.unlock() }
    func get() -> Result<HTTPResult, FetchError>? { lock.lock(); defer { lock.unlock() }; return r }
}

func ok(_ r: Result<HTTPResult, FetchError>?, file: StaticString = #file, line: UInt = #line) -> HTTPResult? {
    switch r {
    case .success(let v)?: return v
    case .failure(let e)?: expect(false, "失敗: \(e.description)（\(e.kind)）", file: file, line: line); return nil
    case nil: return nil
    }
}

func kind(_ r: Result<HTTPResult, FetchError>?) -> FetchError.Kind? {
    if case .failure(let e)? = r { return e.kind }
    return nil
}

/// ゲストへ向かうフレームに細工する（捨てる・入れ替える）。router の queue の上で呼ばれる
func tamper(_ m: VNetMachine, drop every: Int = 0, swap swapEvery: Int = 0) {
    guard let orig = m.router.onFrame else { return }
    var n = 0
    var held: [UInt8]?
    m.router.onFrame = { f in
        n += 1
        if every > 0 && n % every == 0 { return }
        if swapEvery > 0 && n % swapEvery == 0 && held == nil { held = f; return }
        orig(f)
        if let h = held { held = nil; orig(h) }
    }
}

// MARK: テスト

/// 中身の確かめ用の数（順番が入れ替わっても分かる）
func bodySum(_ d: Data) -> Int {
    var s = 0
    for b in d { s = (s &* 31 &+ Int(b)) & 0xFFFFFF }
    return s
}

func netTests() {
    print("VNet の全部（偽のサーバー）")
    let net = FakeNet()
    let names = ["site.test": ipSite, "other.test": ipOther, "rebind.test": ipLAN]
    guard let (m, jar, hsts) = makeMachine(net, names: names) else { return }

    net.serve("93.184.216.34:80") { r in
        switch r.path {
        case "/hello": return httpReply(200, "hello world")
        case "/chunked": return .raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n")
        case "/big": return httpReply(200, String(repeating: "0123456789abcdef", count: 16384))   // 256KB
        case "/to-other": return httpReply(302, headers: [("Location", "http://other.test/landing")])
        case "/post307": return httpReply(307, headers: [("Location", "/echo")])
        case "/post303": return httpReply(303, headers: [("Location", "/echo")])
        case "/echo": return httpReply(200, "\(r.method) \(r.body.count)")
        case "/sum": return httpReply(200, "\(r.body.count) \(bodySum(r.body))")
        case "/to-lan": return httpReply(302, headers: [("Location", "http://192.168.1.10/admin")])
        case "/to-secure": return httpReply(302, headers: [("Location", "http://secure.test/x")])
        case "/login": return httpReply(200, "ok", headers: [("Set-Cookie", "sid=abc; Path=/"), ("Set-Cookie", "pref=1; SameSite=Strict")])
        case "/cookies": return httpReply(200, r.headers.value(for: "Cookie") ?? "-")
        case "/neg": return .raw("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nabc")
        case "/tecl": return .raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        case "/hang": return .hang
        default: return httpReply(404, "nf")
        }
    }
    net.serve("93.184.216.35:80") { r in httpReply(200, "other:" + (r.headers.value(for: "Authorization") ?? "none")) }
    net.serve("192.168.1.10:80") { _ in httpReply(200, "router admin") }

    test("GET（長さ指定・chunked）") {
        let a = ok(fetch(m, HTTPRequest(url: url("http://site.test/hello"))))
        expectEqual(a.map { String(decoding: $0.body, as: UTF8.self) }, "hello world")
        let b = ok(fetch(m, HTTPRequest(url: url("http://site.test/chunked"))))
        expectEqual(b.map { String(decoding: $0.body, as: UTF8.self) }, "hello world")
    }
    test("別オリジンへのリダイレクトで Authorization を外す") {
        var req = HTTPRequest(url: url("http://site.test/to-other"))
        req.headers = [("Authorization", "Bearer secret")]
        let r = ok(fetch(m, req))
        expectEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "other:none")
        expectEqual(r?.url.absoluteString, "http://other.test/landing")
    }
    test("POST: 307 は保つ・303 は GET に") {
        var req = HTTPRequest(url: url("http://site.test/post307"))
        req.method = "POST"; req.body = Data("abcd".utf8); req.headers = [("Content-Type", "text/plain")]
        expectEqual(ok(fetch(m, req)).map { String(decoding: $0.body, as: UTF8.self) }, "POST 4")
        req.url = url("http://site.test/post303")
        expectEqual(ok(fetch(m, req)).map { String(decoding: $0.body, as: UTF8.self) }, "GET 0")
    }
    test("大きい POST（300KB）: ゲストの送り待ちが欠けずに・順番どおりに出る") {
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i * 7 + i / 251) }
        let body = Data(bytes)
        var req = HTTPRequest(url: url("http://site.test/sum"))
        req.method = "POST"; req.body = body; req.headers = [("Content-Type", "application/octet-stream")]
        let want = "\(body.count) \(bodySum(body))"
        expectEqual(ok(fetch(m, req, timeout: 60)).map { String(decoding: $0.body, as: UTF8.self) }, want)
    }
    test("LAN: 公開サイトから LAN へのリダイレクト・DNS リバインディングを止める（サーバーに届かない）") {
        let before = net.received.filter { $0.server.hasPrefix("192.168.") }.count
        var sub = HTTPRequest(url: url("http://site.test/to-lan"))
        sub.context = RequestContext(topURL: url("http://site.test/"))
        expectEqual(kind(fetch(m, sub)), .blocked)
        var rebind = HTTPRequest(url: url("http://rebind.test/"))
        rebind.context = RequestContext(topURL: url("http://site.test/"))
        expectEqual(kind(fetch(m, rebind)), .blocked)
        var byPage = HTTPRequest(url: url("http://192.168.1.10/"))
        byPage.context = RequestContext(topURL: url("http://192.168.1.10/"), isTopLevel: true, initiator: url("http://site.test/"))
        expectEqual(kind(fetch(m, byPage)), .localNetworkConsent)
        expectEqual(net.received.filter { $0.server.hasPrefix("192.168.") }.count, before)
        var typed = HTTPRequest(url: url("http://192.168.1.10/"))
        typed.context = RequestContext(topURL: url("http://192.168.1.10/"), isTopLevel: true)
        typed.context.userInitiated = true
        expectEqual(ok(fetch(m, typed)).map { String(decoding: $0.body, as: UTF8.self) }, "router admin")
    }
    test("Cookie: 受け取り → 同じサイトには送る・サードパーティには送らない") {
        var login = HTTPRequest(url: url("http://site.test/login"))
        login.context = RequestContext(topURL: url("http://site.test/"), isTopLevel: true)
        let r = ok(fetch(m, login))
        expectEqual(r?.cookieChanges.count, 2)
        expectEqual(jar.count, 2)
        var same = HTTPRequest(url: url("http://site.test/cookies"))
        same.context = RequestContext(topURL: url("http://site.test/"))
        expectEqual(ok(fetch(m, same)).map { String(decoding: $0.body, as: UTF8.self) }, "sid=abc; pref=1")
        var third = HTTPRequest(url: url("http://site.test/cookies"))
        third.context = RequestContext(topURL: url("http://news.test/"))
        expectEqual(ok(fetch(m, third)).map { String(decoding: $0.body, as: UTF8.self) }, "-")
        var omit = same
        omit.context.cookiesAllowed = false
        expectEqual(ok(fetch(m, omit)).map { String(decoding: $0.body, as: UTF8.self) }, "-")
    }
    test("HSTS: リダイレクト先の http を https に上げる") {
        hsts.record(header: "max-age=1000", url: url("https://secure.test/"), ctx: RequestContext(topURL: url("https://secure.test/"), isTopLevel: true))
        let r = fetch(m, HTTPRequest(url: url("http://site.test/to-secure")))
        // Linux では https を話せないので「TLS が使えない」で止まる = https に上げた
        expectEqual(kind(r), .tls)
    }
    test("壊れた返事は malformed（落ちない）") {
        expectEqual(kind(fetch(m, HTTPRequest(url: url("http://site.test/neg")))), .malformed)
        expectEqual(kind(fetch(m, HTTPRequest(url: url("http://site.test/tecl")))), .malformed)
        // 壊れた接続は使い回さない: 続けて普通に読める
        expect(ok(fetch(m, HTTPRequest(url: url("http://site.test/hello")))) != nil)
    }
    test("取り消し: 待っている・読んでいる途中の要求が止まり、残らない") {
        let token = RequestToken()
        var req = HTTPRequest(url: url("http://site.test/hang"))
        req.token = token
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        m.send(req) { r in box.set(r); sem.signal() }
        Thread.sleep(forTimeInterval: 0.3)
        token.cancel()
        expect(sem.wait(timeout: .now() + 3) == .success, "取り消しが届かない")
        expectEqual(kind(box.get()), .cancelled)
        Thread.sleep(forTimeInterval: 0.2)
        let s = statsOf(m)
        expectEqual(s?.pool.busy, 0); expectEqual(s?.pool.waiting, 0)
        let early = RequestToken(); early.cancel()
        var pre = HTTPRequest(url: url("http://site.test/hello")); pre.token = early
        expectEqual(kind(fetch(m, pre)), .cancelled)
    }
    test("大きい返事（256KB）が欠けずに届く") {
        let r = ok(fetch(m, HTTPRequest(url: url("http://site.test/big"))))
        expectEqual(r?.body.count, 262144)
    }
    test("流す形: ヘッダ → 中身の順に届き、結果の body は空・3xx は貯めて追いかける") {
        final class Got: @unchecked Sendable {
            let lock = NSLock()
            var heads: [Int] = []
            var data = Data()
            var dataBeforeHead = false
        }
        let got = Got()
        let sink = StreamSink(shouldStream: { status, _ in !(300...399).contains(status) },
                              onHead: { h in got.lock.lock(); got.heads.append(h.status); got.lock.unlock() },
                              onData: { d in got.lock.lock(); if got.heads.isEmpty { got.dataBeforeHead = true }; got.data.append(d); got.lock.unlock() })
        var req = HTTPRequest(url: url("http://site.test/big"))
        req.sink = sink
        let r = ok(fetch(m, req))
        expect(r?.streamed == true); expectEqual(r?.body.count, 0)
        expectEqual(got.heads, [200]); expect(!got.dataBeforeHead)
        expect(got.data == Data(String(repeating: "0123456789abcdef", count: 16384).utf8), "中身が違う（\(got.data.count)）")
        let s = statsOf(m)
        expectEqual(s?.pool.bufferedBytes, 0, "流す形は貯めている量に数えない")
        var red = HTTPRequest(url: url("http://site.test/to-other"))
        let got2 = Got()
        red.sink = StreamSink(shouldStream: { status, _ in !(300...399).contains(status) },
                              onHead: { h in got2.lock.lock(); got2.heads.append(h.status); got2.lock.unlock() },
                              onData: { d in got2.lock.lock(); got2.data.append(d); got2.lock.unlock() })
        let r2 = ok(fetch(m, red))
        expectEqual(r2?.url.absoluteString, "http://other.test/landing")
        expectEqual(got2.heads, [200])
        expectEqual(String(decoding: got2.data, as: UTF8.self), "other:none")
    }
    tamper(m, drop: 41)
    test("フレームを捨てても（41 個に 1 個）欠けずに届く（送り直し・並べ直し）") {
        let r = ok(fetch(m, HTTPRequest(url: url("http://site.test/big")), timeout: 60))
        expectEqual(r?.body.count, 262144)
        expect(r.map { $0.body == Data(String(repeating: "0123456789abcdef", count: 16384).utf8) } ?? false, "中身が違う")
        let routerRetransmits = m.router.queue.sync { m.router.retransmits }
        expect(routerRetransmits > 0, "ルーターが送り直していない（捨てたのに）")
        expect((statsOf(m)?.tcpReordered ?? 0) > 0, "先の分を取っておいていない")
    }
    guard let (m2, _, _) = makeMachine(net, names: names) else { return }
    tamper(m2, swap: 7)
    test("フレームの順番が入れ替わっても欠けずに届く") {
        let r = ok(fetch(m2, HTTPRequest(url: url("http://site.test/big")), timeout: 60))
        expect(r.map { $0.body == Data(String(repeating: "0123456789abcdef", count: 16384).utf8) } ?? false, "中身が違う")
        expect((statsOf(m2)?.tcpReordered ?? 0) > 0, "入れ替わったのに、先の分を取っておいていない")
    }

    print("資源の上限")
    var small = PoolLimits()
    small.maxPerHost = 1; small.maxWaiting = 2; small.maxBodyPerRequest = 1024
    guard let (m3, _, _) = makeMachine(net, names: names, limits: small) else { return }
    test("1 つの返事の上限を超えたら tooLarge") {
        expectEqual(kind(fetch(m3, HTTPRequest(url: url("http://site.test/big")))), .tooLarge)
    }
    test("待ち行列がいっぱいなら busy・取り消した待ちは数えない") {
        var tokens: [RequestToken] = []
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            let t = RequestToken(); tokens.append(t)
            var r = HTTPRequest(url: url("http://site.test/hang")); r.token = t
            m3.send(r) { _ in sem.signal() }
        }
        Thread.sleep(forTimeInterval: 0.3)
        m3.send(HTTPRequest(url: url("http://site.test/hello"))) { r in box.set(r); sem.signal() }
        expect(sem.wait(timeout: .now() + 3) == .success)
        expectEqual(kind(box.get()), .busy)
        for t in tokens { t.cancel() }
        for _ in 0..<3 { _ = sem.wait(timeout: .now() + 3) }
        Thread.sleep(forTimeInterval: 0.2)
        expect(ok(fetch(m3, HTTPRequest(url: url("http://site.test/hello")))) != nil, "取り消した後は普通に読める")
        expectEqual(statsOf(m3)?.pool.waiting, 0)
    }
}

func statsOf(_ m: VNetMachine) -> VNetMachine.Stats? {
    let sem = DispatchSemaphore(value: 0)
    let box = StatsBox()
    m.stats { s in box.v = s; sem.signal() }
    sem.wait()
    return box.v
}

final class StatsBox: @unchecked Sendable { var v: VNetMachine.Stats? }
