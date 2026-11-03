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
// ほかに: クッキーを送る（CookieJar と CookiePolicy で判定）・リダイレクトを追いかける（RedirectPolicy）・POST も送れる
// 守り: 名前を引いた後、LAN への接続を LocalNetworkPolicy で判定する（DNS リバインディングも、ここで止める）
// 「ロボットだ」と思われないよう、ヘッダは Safari と同じものを、毎回同じ順番で送る
// 返事が来ないまま止まった接続は、時間切れで切る（でないと、その相手への読み込みがずっと止まる）

struct HTTPRequest: Sendable {
    var method = "GET"
    var url: URL
    var headers: [(String, String)] = []
    var body: Data?
    /// どんな場面の要求か（Cookie・リダイレクト・LAN の判定に使う）
    var context = RequestContext()
    /// 取り消しの印（WebKit が読み込みをやめたら cancel される）
    var token: RequestToken?
    /// 流す形で受け取る相手（nil なら全部貯めてから返す）
    var sink: StreamSink?
}

/// 流す形にした返事のヘッダ
struct HTTPHead: Sendable {
    var status: Int
    /// 中身を戻すときは Content-Encoding・Content-Length を外してある
    var headers: [(String, String)]
    var url: URL
    /// この返事で CookieJar に入れた Cookie の変更（WebKit の置き場にも入れてから、ページに返事を渡すこと）
    var cookieChanges: [CookieChange]
    func header(_ name: String) -> String? { headers.value(for: name) }
}

/// 流す形で受け取る相手（VNetScheme）。どれも stack.queue の上で呼ばれる
final class StreamSink: @unchecked Sendable {
    /// ヘッダを見て、流す形にするか（3xx などは貯めて、追いかけたり WebKit に移動として渡したりする）
    let shouldStream: (_ status: Int, _ headers: [(String, String)]) -> Bool
    /// 流す形にした返事のヘッダ（中身より先に 1 回だけ）
    let onHead: (HTTPHead) -> Void
    /// 中身（戻したもの。届いた分ずつ）
    let onData: (Data) -> Void

    init(shouldStream: @escaping (_ status: Int, _ headers: [(String, String)]) -> Bool,
         onHead: @escaping (HTTPHead) -> Void, onData: @escaping (Data) -> Void) {
        self.shouldStream = shouldStream
        self.onHead = onHead
        self.onData = onData
    }
}

struct HTTPResult: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var url: URL
    /// CookieJar に入れた Cookie の変更（リダイレクトの途中の分も）。ブラウザ（WebKit）の Cookie の置き場にも同じことをする
    var cookieChanges: [CookieChange] = []
    /// 中身は流す形で StreamSink に渡した（body は空）
    var streamed = false
    func header(_ name: String) -> String? { headers.value(for: name) }
}

struct FetchError: Error, Sendable, CustomStringConvertible {
    /// 失敗の種類（エラーページの説明・標準の通信へ切り替える案内に使う）
    enum Kind: String, Sendable {
        case other, dns, timeout, tls, connect, reset, malformed, tooLarge, redirect, notReady, cancelled
        /// TLS の版が合わない（相手が TLS 1.3 だけなど。VNet の TLS は 1.2 まで）
        case tlsVersion
        /// 決まり（LAN の保護など）で止めた
        case blocked
        /// ページが LAN へ移動しようとした。ユーザーが許可すれば開ける
        case localNetworkConsent
        /// 要求が多すぎて受け付けられない（待ち行列がいっぱい）
        case busy
    }
    let description: String
    var kind: Kind
    init(_ description: String, kind: Kind = .other) { self.description = description; self.kind = kind }

    /// 返事を読めなかった: 大きすぎるなら tooLarge、それ以外は malformed
    init(_ f: ResponseParser.Failure) {
        if case .tooLarge = f { self.init(f.description, kind: .tooLarge) } else { self.init(f.description, kind: .malformed) }
    }

    /// 縮めた中身を戻せなかった: 大きすぎるなら tooLarge、それ以外（壊れている・戻せない縮め方）は malformed
    init(_ f: ContentDecoding.Failure) {
        if case .tooLarge = f { self.init(f.description, kind: .tooLarge) } else { self.init(f.description, kind: .malformed) }
    }
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
    /// TCP がつながったか（失敗の種類を「つながらない」と「途中で切れた」に分ける）
    private var tcpConnected = false
    private var queued: Data?
    private var parser: ResponseParser?
    private var onDone: Completion?

    init(key: String) { self.key = key }

    func open(stack: GuestStack, ip: [UInt8], port: UInt16, host: String, https: Bool) {
        queue = stack.queue
        guard https else {
            tcp = stack.connect(ip, port, handler: .init(
                connected: { [weak self] in self?.tcpConnected = true; self?.becameReady() },
                data: { [weak self] d in self?.got(d) },
                closed: { [weak self] err in self?.ended(err) }))
            return
        }
        guard let t = TLSStream(host: host, port: port) else { fail("TLS を用意できません", kind: .tls); return }
        tls = t
        t.onReady = { [weak self, weak t] in
            stack.trace?("TLS つながった（\(host)・\(t?.version ?? "")）")
            self?.becameReady()
        }
        t.onData = { [weak self] d in self?.got(d) }
        t.onClosed = { [weak self] err in self?.ended(err) }
        tcp = stack.connect(ip, port, handler: .init(
            connected: { [weak self] in guard let self, let tc = self.tcp else { return }; self.tcpConnected = true; self.tls?.attach(tc) },
            data: { [weak self] d in self?.lastActivity = Date(); self?.tls?.tcpData(d) },
            closed: { [weak self] err in self?.tls?.tcpClosed(err) }))
    }

    /// 要求を 1 つ送る（返事を読み終わったら done）。何回目の要求か（取り消しに使う番号）を返す
    /// onGrow: 返事の中身が増えたとき（増えたバイト数）
    @discardableResult
    /// decide: ヘッダを読んだところで呼ぶ。中身を受け取る関数を返したら、流す形にする
    func send(_ bytes: Data, isHead: Bool, limits: ResponseParser.Limits = ResponseParser.Limits(),
              onGrow: ((Int) -> Void)? = nil, decide: ((ResponseParser) -> ((Data) -> Void)?)? = nil,
              done: @escaping Completion) -> Int {
        uses += 1
        serial += 1
        if !alive { done(.failure(FetchError("接続が閉じています", kind: .reset)), false, true); return serial }
        let p = ResponseParser(isHead: isHead, limits: limits)
        p.onBodyGrow = onGrow
        if let decide {
            p.decideStreaming = { [unowned p] in
                guard let h = decide(p) else { return false }
                p.onChunk = h
                return true
            }
        }
        parser = p
        onDone = done
        lastActivity = Date()
        watch(serial)
        if ready { write(bytes) } else { queued = bytes }
        return serial
    }

    /// 読んでいる途中の要求を取り消す（その要求の番号のときだけ）。接続は切って、使い回さない
    func cancel(serial s: Int) {
        guard s == serial, onDone != nil else { return }
        alive = false
        finishCurrent(.failure(HTTPPool.cancelled), reusable: false)
        tcp?.abort()
    }

    /// 時間切れの見張り（5 秒ごと）。返事を待っている間に長く何も届かなければ切る
    private func watch(_ s: Int) {
        queue?.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.serial == s, self.onDone != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) < HTTPConn.timeout { self.watch(s); return }
            self.alive = false
            self.finishCurrent(.failure(FetchError("時間切れ（\(Int(HTTPConn.timeout)) 秒なにも届きません）", kind: .timeout)), reusable: false)
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
        if let f = p.failure {
            // おかしな返事: その要求は失敗にして、接続は切る（続きのバイトの区切りが信用できないため）
            alive = false
            finishCurrent(.failure(FetchError(f)), reusable: false)
            tcp?.abort()
            return
        }
        if p.complete { finishCurrent(.success(p), reusable: p.keepAlive && alive) }
    }

    private func ended(_ err: String?) {
        alive = false
        guard let p = parser else { return }
        if p.closed() { finishCurrent(.success(p), reusable: false) }
        else if let t = tls, t.handshakeError != 0 {
            finishCurrent(.failure(FetchError(err ?? "TLS の握手に失敗", kind: t.versionMismatch ? .tlsVersion : .tls)), reusable: false)
        }
        else { finishCurrent(.failure(FetchError(err ?? "途中で切れました", kind: tcpConnected ? .reset : .connect)), reusable: false, gotNothing: p.received == 0) }
    }

    private func fail(_ s: String, kind: FetchError.Kind = .other) {
        alive = false
        finishCurrent(.failure(FetchError(s, kind: kind)), reusable: false, gotNothing: true)
    }

    private func finishCurrent(_ r: Result<ResponseParser, FetchError>, reusable: Bool, gotNothing: Bool = false) {
        let cb = onDone
        onDone = nil
        parser = nil
        cb?(r, reusable, gotNothing)
    }
}

// MARK: - 取り消し

/// 要求の取り消しの印。WebKit が読み込みをやめたら（VNetScheme.stop）cancel() する。
/// HTTPPool は、待っている要求は列から外し、読んでいる途中の接続は切る（使い回さない）
final class RequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    init() {}

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 取り消す（何度呼んでもよい）。登録された処理は、呼んだスレッドで 1 回ずつ動く
    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let hs = handlers
        handlers = []
        lock.unlock()
        for h in hs { h() }
    }

    /// 取り消されたときの処理を登録する（もう取り消されていれば、すぐ動く）
    func onCancel(_ h: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); h(); return }
        handlers.append(h)
        lock.unlock()
    }
}

// MARK: - 接続の置き場と、要求の受付

/// 資源の上限（メモリ・接続の数・待ち行列）
struct PoolLimits: Sendable {
    /// 同じ相手への同時の接続（ブラウザと同じ）
    var maxPerHost = 6
    /// 全部の相手への接続の合計（使っていないものも含む）
    var maxTotalConnections = 32
    /// 待っている要求の合計（これを超えたら失敗にする）
    var maxWaiting = 256
    /// 1 つの返事の中身の上限（縮めたものを戻した後も同じ）
    var maxBodyPerRequest = 32 << 20
    /// 読んでいる途中の返事の中身の合計。超えている間は、新しい要求を待たせる
    var maxBufferedTotal = 128 << 20
    init() {}
}

/// 開発者向けの数字（queue の上で作ったスナップショット）
struct PoolStats: Sendable {
    var opened = 0, reused = 0
    var busy = 0, idle = 0, waiting = 0
    var bufferedBytes = 0
    var dnsCached = 0
}

/// 接続の置き場（相手ごと）と、要求の受付。すべて stack.queue の上で呼ぶ
final class HTTPPool: @unchecked Sendable {
    let stack: GuestStack
    /// ブラウザ（WebKit）が User-Agent を付けてこなかったときに使う
    var userAgent = BrowserIdentity.userAgent
    var limits = PoolLimits()

    /// 待っている要求（取り消されたら、順番が来たときに cancel を呼んで飛ばす）
    private struct Waiter {
        let token: RequestToken?
        let run: () -> Void
        let cancel: () -> Void
    }
    private var idle: [String: [HTTPConn]] = [:]
    private var busy: [String: Int] = [:]
    /// 相手ごとの待ち（同じ相手への接続が maxPerHost 本使われている）
    private var waiting: [String: [Waiter]] = [:]
    /// 全体の待ち（接続の合計が上限・貯めている中身が上限）
    private var admission: [Waiter] = []
    private var dnsCache: [String: (ip: [UInt8], at: Date)] = [:]
    /// 名前を引いて分かったアドレスの種類（トップのページが LAN のものかを見るのに使う）
    private var hostClass: [String: IPClass] = [:]
    /// 使っていない接続を、これより長く置いておかない（相手はたいてい黙って閉じている）
    let idleLimit: TimeInterval = 50
    private(set) var reused = 0, opened = 0
    /// 読んでいる途中の返事の中身の合計（バイト）
    private(set) var bufferedBytes = 0
    /// Cookie の写し（正本は WebKit）。nil なら Cookie を送らない・受け取らない
    var cookieJar: CookieJar?
    /// HSTS の記録（リダイレクトを https に上げる）
    var hsts: HSTSStore?
    /// LAN の保護（LocalNetworkPolicy）を使うか
    var localNetworkProtection = true
    /// 判定のログ（Cookie を送らなかった理由・LAN を止めた理由など）
    var policyLog: ((String) -> Void)?

    init(stack: GuestStack) {
        self.stack = stack
    }

    func stats() -> PoolStats {
        pruneIdle()
        return PoolStats(opened: opened, reused: reused, busy: busy.values.reduce(0, +), idle: idle.values.reduce(0) { $0 + $1.count },
                         waiting: waitingCount(), bufferedBytes: bufferedBytes, dnsCached: dnsCache.count)
    }

    /// 送って返事を受け取る（リダイレクトは追いかける）
    /// followRedirects が false なら 3xx もそのまま返す（移動はブラウザ（WebKit）に任せるとき）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, redirects: Int = 0, carried: [CookieChange] = [], done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        if req.token?.isCancelled == true { done(.failure(HTTPPool.cancelled)); return }
        sendOnce(req, retry: true) { [weak self] r in
            guard let self else { return }
            guard case .success(var res) = r else { done(r); return }
            if followRedirects, RedirectPolicy.statuses.contains(res.status) {
                let hsts = self.hsts
                switch RedirectPolicy.next(from: req.url, method: req.method, headers: req.headers, body: req.body, status: res.status,
                                           location: res.header("Location"), redirectCount: redirects,
                                           hsts: { hsts?.shouldUpgrade($0) ?? false }) {
                case .success(let nx):
                    var n = req
                    n.url = nx.url
                    n.method = nx.method
                    n.headers = nx.headers
                    n.body = nx.body
                    n.context = req.context.redirected(from: req.url, to: nx.url)
                    let dropped = nx.dropped.isEmpty ? "" : "（外したヘッダ: \(nx.dropped.joined(separator: ", "))）"
                    self.stack.trace?("↪ \(res.status) → \(nx.url.absoluteString)\(nx.upgradedByHSTS ? "（HSTS で https に）" : "")\(dropped)")
                    self.send(n, followRedirects: true, redirects: redirects + 1, carried: carried + res.cookieChanges, done: done)
                    return
                case .failure(let f):
                    // 追いかけられない 3xx（Location が無い・javascript: など）は、そのまま返す。回数の上限は失敗にする
                    if f == .tooMany { done(.failure(FetchError("リダイレクトが多すぎます", kind: .redirect))); return }
                    self.stack.trace?("↪ \(res.status) を追いかけません: \(f)")
                }
            }
            res.cookieChanges = carried + res.cookieChanges
            done(.success(res))
        }
    }

    static let cancelled = FetchError("取り消しました", kind: .cancelled)

    private func sendOnce(_ req: HTTPRequest, retry: Bool, done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        guard let rawHost = req.url.host, let scheme = req.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            done(.failure(FetchError("http か https のアドレスではありません"))); return
        }
        let host = SiteUtil.normalizeHost(rawHost)
        let https = scheme == "https"
        if https && !TLSStream.isSupported { done(.failure(FetchError("この環境では https を使えません", kind: .tls))); return }
        let port = UInt16(req.url.port ?? (https ? 443 : 80))
        let key = "\(scheme)://\(host):\(port)"
        // 先に名前を引いて、LAN への接続かを判定する（接続を使い回すときも、要求ごとに判定する）
        resolve(host) { [weak self] ip in
            guard let self else { return }
            if req.token?.isCancelled == true { done(.failure(HTTPPool.cancelled)); return }
            guard let ip else { done(.failure(FetchError("名前が見つかりません: \(host)", kind: .dns))); return }
            if let e = self.checkLocalNetwork(req, host: host, ip: ip) { done(.failure(e)); return }
            let bytes = self.requestBytes(req, host: host)
            let run: (HTTPConn) -> Void = { [weak self] c in
                guard let self else { return }
                if req.token?.isCancelled == true {
                    self.release(c, reusable: c.alive)
                    done(.failure(HTTPPool.cancelled))
                    return
                }
                var held = 0
                let stream = StreamState()
                let decide: ((ResponseParser) -> ((Data) -> Void)?)? = req.sink.map { sink in
                    { [weak self] p in self?.startStream(p, req: req, sink: sink, state: stream) }
                }
                let serial = c.send(bytes, isHead: req.method == "HEAD", limits: self.parserLimits(),
                                    onGrow: { [weak self] n in held += n; self?.bufferedBytes += n },
                                    decide: decide) { [weak self] r, reusable, gotNothing in
                    guard let self else { return }
                    self.bufferedBytes -= held
                    held = 0
                    self.release(c, reusable: reusable)
                    switch r {
                    case .success(let p) where p.streaming:
                        done(self.finishStream(p, req: req, state: stream))
                    case .success(let p):
                        done(self.result(p, req: req))
                    case .failure(let e):
                        // 使い回した接続が、相手に閉じられていた: 新しい接続でもう一度（取り消したものは除く）
                        if e.kind != .cancelled && retry && gotNothing && c.uses > 1 { self.sendOnce(req, retry: false, done: done) }
                        else { done(.failure(e)) }
                    }
                }
                let q = self.stack.queue
                req.token?.onCancel { [weak c] in q.async { c?.cancel(serial: serial) } }
            }
            self.admit(req.token, cancel: { done(.failure(HTTPPool.cancelled)) }, fail: { done(.failure($0)) }) { [weak self] in
                self?.acquire(key: key, host: host, ip: ip, port: port, https: https, token: req.token,
                              cancel: { done(.failure(HTTPPool.cancelled)) }, fail: { done(.failure($0)) }, run: run)
            }
        }
    }

    /// 流す形の途中の様子（1 つの要求の間だけ）
    private final class StreamState {
        var sink: StreamSink?
        var decoder: StreamDecoder?
        var head: HTTPHead?
        var failure: FetchError?
        var bytes = 0
    }

    /// ヘッダを読んだところで、流す形にするかを決める。流すなら、Cookie を入れて onHead を呼び、中身を受け取る関数を返す
    private func startStream(_ p: ResponseParser, req: HTTPRequest, sink: StreamSink, state: StreamState) -> ((Data) -> Void)? {
        guard sink.shouldStream(p.status, p.headers) else { return nil }
        var headers = p.headers
        let enc = headers.value(for: "Content-Encoding") ?? ""
        let decoder: StreamDecoder?
        switch StreamDecoder.make(encoding: enc) {
        case .success(let d): decoder = d
        case .failure: return nil            // 流す形で戻せない縮め方（重ねてあるなど）: 貯める形で読む
        }
        if decoder != nil { headers.removeAll(named: ["content-encoding", "content-length"]) }
        headers.removeAll(named: ["transfer-encoding"])
        var changes: [CookieChange] = []
        let lines = headers.values(for: "Set-Cookie")
        if !lines.isEmpty, let jar = cookieJar { changes = jar.receive(lines, url: req.url, method: req.method, ctx: req.context) }
        let head = HTTPHead(status: p.status, headers: headers, url: req.url, cookieChanges: changes)
        state.sink = sink
        state.decoder = decoder
        state.head = head
        sink.onHead(head)
        return { [weak state] chunk in
            guard let state, state.failure == nil else { return }
            state.bytes += chunk.count
            guard let d = state.decoder else { sink.onData(chunk); return }
            switch d.feed(chunk) {
            case .success(let out): if !out.isEmpty { sink.onData(out) }
            // 流す形の StreamDecoder には上限が無い（maxOutput = Int.max）ので、今は tooLarge にならず必ず malformed。
            // 流す形に上限を付けたら、ここも tooLarge になる
            case .failure(let f): state.failure = FetchError(f)
            }
        }
    }

    /// 流す形の返事を読み終えた
    private func finishStream(_ p: ResponseParser, req: HTTPRequest, state: StreamState) -> Result<HTTPResult, FetchError> {
        if let d = state.decoder, state.failure == nil {
            switch d.finish() {
            case .success(let out): if !out.isEmpty { state.sink?.onData(out) }
            case .failure(let f): state.failure = FetchError(f)        // 上と同じく、今は必ず malformed
            }
        }
        if let f = state.failure {
            stack.trace?("流す形の中身を戻せませんでした: \(req.url.absoluteString)（\(f.description)）")
            return .failure(f)
        }
        let h = state.head
        return .success(HTTPResult(status: p.status, headers: h?.headers ?? p.headers, body: Data(), url: req.url,
                                   cookieChanges: h?.cookieChanges ?? [], streamed: true))
    }

    private func parserLimits() -> ResponseParser.Limits {
        var l = ResponseParser.Limits()
        l.maxBody = limits.maxBodyPerRequest
        return l
    }

    /// LAN への接続を判定する。止めるならエラーを返す
    private func checkLocalNetwork(_ req: HTTPRequest, host: String, ip: [UInt8]) -> FetchError? {
        let target = LocalNetworkPolicy.classify(ip)
        hostClass[host] = target
        // VNet の中のアドレス（ルーター・DNS）には、設定に関係なく接続しない
        if !localNetworkProtection && target != .vnetInternal { return nil }
        let ctx = req.context
        let topClass = ctx.topURL.flatMap { classOf($0) }
        let from = ctx.previousURL ?? ctx.initiator
        let fromClass = from.flatMap { classOf($0) }
        switch LocalNetworkPolicy.decide(target: target, ctx: ctx, topClass: topClass, fromClass: fromClass) {
        case .allow:
            return nil
        case .block(let why):
            policyLog?("🛡 LAN の保護: \(req.url.absoluteString)（\(ip.ipString)）を止めました: \(why)")
            return FetchError("\(why)（\(host) → \(ip.ipString)）", kind: .blocked)
        case .askUser(let why):
            policyLog?("🛡 LAN の保護: \(req.url.absoluteString)（\(ip.ipString)）は確認が必要です: \(why)")
            return FetchError("\(why)（\(host) → \(ip.ipString)）", kind: .localNetworkConsent)
        }
    }

    /// URL のホストのアドレスの種類（数字のアドレスならそのまま。名前なら、引いたことがあればその結果。分からなければ公開とみなす）
    private func classOf(_ u: URL) -> IPClass? {
        guard let h = SiteUtil.host(of: u) else { return nil }
        return LocalNetworkPolicy.classify(host: h) ?? hostClass[h] ?? .publicAddress
    }

    // MARK: 待ち行列と上限

    private func waitingCount() -> Int {
        admission.filter { $0.token?.isCancelled != true }.count
            + waiting.values.reduce(0) { $0 + $1.filter { $0.token?.isCancelled != true }.count }
    }

    /// 待ち行列に入れる（いっぱいなら失敗）
    private func enqueue(_ w: Waiter, key: String?, fail: (FetchError) -> Void) {
        if waitingCount() >= limits.maxWaiting {
            fail(FetchError("要求が多すぎます（\(limits.maxWaiting) 件待っています）", kind: .busy))
            return
        }
        if let key { waiting[key, default: []].append(w) } else { admission.append(w) }
    }

    /// 貯めている中身が上限なら待たせる。空いていればすぐ go
    private func admit(_ token: RequestToken?, cancel: @escaping () -> Void, fail: (FetchError) -> Void, _ go: @escaping () -> Void) {
        if bufferedBytes < limits.maxBufferedTotal { go(); return }
        stack.trace?("読んでいる途中の中身が \(bufferedBytes >> 20)MB あるので、新しい要求を待たせます")
        enqueue(Waiter(token: token, run: go, cancel: cancel), key: nil, fail: fail)
    }

    /// 死んだ・古い「使っていない接続」を片付ける
    private func pruneIdle() {
        let now = Date()
        for (k, list) in idle {
            let keep = list.filter { c in
                if c.alive && now.timeIntervalSince(c.idleSince) <= idleLimit { return true }
                c.close()
                return false
            }
            idle[k] = keep.isEmpty ? nil : keep
        }
    }

    private var totalConnections: Int { busy.values.reduce(0, +) + idle.values.reduce(0) { $0 + $1.count } }

    /// 空いている接続を使う。無ければ作る（上限まで）。いっぱいなら空くまで待つ
    private func acquire(key: String, host: String, ip: [UInt8], port: UInt16, https: Bool, token: RequestToken?,
                         cancel: @escaping () -> Void, fail: @escaping (FetchError) -> Void, run: @escaping (HTTPConn) -> Void) {
        pruneIdle()
        if var list = idle[key], let c = list.popLast() {
            idle[key] = list.isEmpty ? nil : list
            busy[key, default: 0] += 1
            reused += 1
            run(c)
            return
        }
        let again = { [weak self] () -> Void in
            self?.acquire(key: key, host: host, ip: ip, port: port, https: https, token: token, cancel: cancel, fail: fail, run: run)
        }
        if busy[key, default: 0] >= limits.maxPerHost {
            enqueue(Waiter(token: token, run: again, cancel: cancel), key: key, fail: fail)
            return
        }
        if totalConnections >= limits.maxTotalConnections {
            // ほかの相手の、使っていない接続を 1 本閉じて場所を空ける。それも無ければ待つ
            if let (k, list) = idle.first(where: { !$0.value.isEmpty }) {
                var l = list
                l.removeFirst().close()
                idle[k] = l.isEmpty ? nil : l
            } else {
                enqueue(Waiter(token: token, run: again, cancel: cancel), key: nil, fail: fail)
                return
            }
        }
        busy[key, default: 0] += 1
        let c = HTTPConn(key: key)
        opened += 1
        c.open(stack: stack, ip: ip, port: port, host: host, https: https)
        run(c)
    }

    /// 使い終わった接続を戻す（使い回せなければ閉じる）。待っている要求があれば進める
    private func release(_ c: HTTPConn, reusable: Bool) {
        if reusable && c.alive { c.idleSince = Date(); idle[c.key, default: []].append(c) } else { c.close() }
        busy[c.key, default: 1] -= 1
        if busy[c.key] == 0 { busy[c.key] = nil }
        drain(key: c.key)
    }

    /// 待っている要求を進める（相手ごとの待ち → 全体の待ち）。取り消されたものは飛ばす
    private func drain(key: String) {
        while var w = waiting[key], !w.isEmpty {
            let next = w.removeFirst()
            waiting[key] = w.isEmpty ? nil : w
            if next.token?.isCancelled == true { next.cancel(); continue }
            next.run()
            break
        }
        while !admission.isEmpty && bufferedBytes < limits.maxBufferedTotal && totalConnections < limits.maxTotalConnections {
            let next = admission.removeFirst()
            if next.token?.isCancelled == true { next.cancel(); continue }
            next.run()
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
        if let cookie = cookieHeader(req) { h.append(("Cookie", cookie)) }
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

    /// 送る Cookie。WebKit が付けてきたものがあれば、それをそのまま使う（WebKit が自分の決まりで選んだもの）。
    /// 無ければ CookieJar（WebKit の置き場の写し）から、CookiePolicy で許されたものだけ
    private func cookieHeader(_ req: HTTPRequest) -> String? {
        if !req.context.cookiesAllowed { return nil }
        let fromWebKit = req.headers.values(for: "Cookie").filter { !$0.isEmpty }
        if !fromWebKit.isEmpty { return fromWebKit.joined(separator: "; ") }
        guard let jar = cookieJar else { return nil }
        let (header, skipped) = jar.header(for: req.url, method: req.method, ctx: req.context)
        if !skipped.isEmpty, let log = policyLog {
            log("🍪 送らない（\(req.url.host ?? "")）: " + skipped.map { "\($0.0)＝\($0.1)" }.joined(separator: "、"))
        }
        return header
    }

    /// 返事をまとめる（Cookie を CookieJar に入れる・縮めた中身を戻す）
    private func result(_ p: ResponseParser, req: HTTPRequest) -> Result<HTTPResult, FetchError> {
        let url = req.url
        var headers = p.headers
        let lines = headers.values(for: "Set-Cookie")
        var changes: [CookieChange] = []
        if !lines.isEmpty, let jar = cookieJar {
            changes = jar.receive(lines, url: url, method: req.method, ctx: req.context)
        }
        var body = Data(p.body)
        if let enc = headers.value(for: "Content-Encoding"), !body.isEmpty {
            switch ContentDecoding.decode(body, encoding: enc, maxOutput: limits.maxBodyPerRequest) {
            case .success(let g):
                body = g
                headers.removeAll(named: ["content-encoding", "content-length"])
            case .failure(let f):
                // 戻せない中身をそのまま渡すと、ページには壊れたデータになる。失敗にする
                stack.trace?("縮めた中身（\(enc)）を戻せませんでした: \(url.absoluteString)（\(f.description)）")
                return .failure(FetchError(f))
            }
        }
        headers.removeAll(named: ["transfer-encoding"])
        return .success(HTTPResult(status: p.status, headers: headers, body: body, url: url, cookieChanges: changes))
    }
}
