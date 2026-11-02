// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 2 / 4。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

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
// MARK: - NetPolicy.swift
// ======================================================================

// MARK: - 通信の決まり（セキュリティの判定）
//
// 画面や WebKit に頼らない「判定だけ」の部品。Linux のテスト（tools/tests）でも動かす。
//  SiteUtil           … ホスト名の正規化・「サイト」「オリジン」の判定
//  RequestContext     … 要求の文脈（トップのページ・トップレベルの移動か・リダイレクトの経路 など）
//  CookiePolicy       … Cookie を送るか・保存するか（SameSite・サードパーティ・送る順番）
//  SetCookieParser    … Set-Cookie の 1 行を CookieRecord にする（属性の検査も）
//  RedirectPolicy     … 3xx から次の要求を作る（ここ以外では作らない）
//  CORSPassthrough    … サーバーの CORS ヘッダをそのまま通す（Vela が許可を作らない）
//  LocalNetworkPolicy … Vela 独自のローカルネットワーク（LAN）への接続の制御（Chrome の PNA / LNA とは別物）

// MARK: - サイト・オリジン

enum SiteUtil {
    /// ホスト名をそろえる（小文字・末尾の「.」を外す・IPv6 の [ ] を外す）。
    /// IDN（日本語ドメインなど）は、WebKit から届く URL の時点で punycode（xn--…）になっているので、ここでは変換しない
    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func host(of url: URL) -> String? {
        guard let h = url.host, !h.isEmpty else { return nil }
        return normalizeHost(h)
    }

    /// IPv4 か IPv6 の数字のアドレスか
    static func isIPLiteral(_ host: String) -> Bool {
        let h = normalizeHost(host)
        return IPAddressText.v4(h) != nil || h.contains(":")
    }

    /// 2 段以上の「公開の末尾」（Public Suffix List の、よく使う所だけ）。ここに無いものは最後の 1 段を末尾とみなす
    static let multiLevelSuffixes: Set<String> = [
        // 日本
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "lg.jp", "gr.jp", "ad.jp",
        "tokyo.jp", "osaka.jp", "kyoto.jp", "aichi.jp", "kanagawa.jp", "hokkaido.jp", "fukuoka.jp", "saitama.jp", "chiba.jp", "hyogo.jp",
        // ほかの国
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.sg", "edu.sg", "gov.sg", "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "co.id", "or.id", "ac.id", "go.id", "co.th", "or.th", "ac.th", "go.th", "in.th",
        "com.my", "com.mx", "com.ar", "co.za", "com.tr", "com.vn", "com.ph", "com.ua", "co.il",
        // 誰でも下にサイトを作れる所（別のサイトとして扱う）
        "github.io", "githubusercontent.com", "blogspot.com", "herokuapp.com", "netlify.app", "vercel.app",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net",
        "appspot.com", "glitch.me", "gitlab.io", "s3.amazonaws.com", "fly.dev", "onrender.com", "repl.co",
    ]

    /// 公開の末尾そのものか（例: "jp"・"co.jp"・"github.io"）。Cookie の Domain に使えない
    static func isPublicSuffix(_ domain: String) -> Bool {
        let d = normalizeHost(domain)
        if d.isEmpty { return true }
        if !d.contains(".") { return !isIPLiteral(d) && d != "localhost" }
        return multiLevelSuffixes.contains(d)
    }

    /// 「登録できるドメイン」（サイトの単位）。www.example.co.jp → example.co.jp、a.b.example.com → example.com
    static func registrableDomain(_ host: String) -> String {
        let h = normalizeHost(host)
        if isIPLiteral(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count <= 2 {
            // "co.jp" のように末尾そのもの・"example.com"・"localhost"
            return h
        }
        // 長い末尾から順に見る（"s3.amazonaws.com" のような 3 段もある）
        for n in stride(from: min(3, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if multiLevelSuffixes.contains(suffix) { return labels.suffix(n + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// 同じサイトか（スキームは見ない。WebKit の「サードパーティ」の考え方と同じ）
    static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let ha = host(of: a), let hb = host(of: b) else { return false }
        return registrableDomain(ha) == registrableDomain(hb)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https", "wss", "vnets": return 443
        case "http", "ws", "vnet": return 80
        default: return nil
        }
    }

    /// オリジン（"https://example.com" ・ 既定でないポートなら ":8443" も付ける）
    static func origin(of url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), let h = host(of: url) else { return nil }
        let hostText = h.contains(":") ? "[\(h)]" : h
        if let p = url.port, p != defaultPort(s) { return "\(s)://\(hostText):\(p)" }
        return "\(s)://\(hostText)"
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        return oa == ob
    }

    static func isSecureScheme(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        return s == "https" || s == "wss" || s == "vnets"
    }
}

/// 数字のアドレスを読む
enum IPAddressText {
    /// "192.168.0.1" → [192, 168, 0, 1]
    static func v4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// IPv6 を 8 個の 16 ビットにする（"::" の省略・末尾の IPv4 表記・"%zone" に対応）
    static func v6(_ text: String) -> [UInt16]? {
        var s = SiteUtil.normalizeHost(text)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard s.contains(":") else { return nil }
        var tail4: [UInt16] = []
        if let lastColon = s.lastIndex(of: ":"), let v4 = v4(String(s[s.index(after: lastColon)...])) {
            tail4 = [UInt16(v4[0]) << 8 | UInt16(v4[1]), UInt16(v4[2]) << 8 | UInt16(v4[3])]
            s = String(s[...lastColon]) + "0:0"   // IPv4 の分（16 ビット 2 個）を形だけ置いておき、あとで差し替える
        }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ t: String) -> [UInt16]? {
            if t.isEmpty { return [] }
            var g: [UInt16] = []
            for p in t.split(separator: ":", omittingEmptySubsequences: false) {
                guard !p.isEmpty, p.count <= 4, let v = UInt16(p, radix: 16) else { return nil }
                g.append(v)
            }
            return g
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let back = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - back.count
            guard fill >= 1 else { return nil }
            all = head + Array(repeating: 0, count: fill) + back
        } else {
            all = head
        }
        guard all.count == 8 else { return nil }
        if !tail4.isEmpty { all.removeLast(); all.removeLast(); all += tail4 }
        return all
    }
}

// MARK: - 要求の文脈

/// 要求がどんな場面で出たか。Cookie・リダイレクト・LAN の判定に使う
struct RequestContext: Sendable {
    /// トップのページの URL（WebKit の mainDocumentURL）
    var topURL: URL?
    /// トップレベルの移動（ページそのものを開く要求）か
    var isTopLevel = false
    /// 要求を出したページ（Referer）。トップレベルの移動で、どこから来たかを見るのに使う
    var initiator: URL?
    /// リダイレクトの経路で、一度でもクロスサイトになったか（なったら、そのあとはずっとクロスサイト扱い）
    var crossSiteChain = false
    /// Cookie を送受信してよいか（URLRequest.httpShouldHandleCookies。Fetch の credentials: omit と同じものではない）
    var cookiesAllowed = true
    /// ユーザーがアドレス欄・ブックマークなどから開いた移動か（ページのリンクや JavaScript ではない）
    var userInitiated = false
    /// リダイレクトのとき、1 つ前の URL
    var previousURL: URL?
    /// どのタブの要求か（ログ用）
    var tabID = 0

    init(topURL: URL? = nil, isTopLevel: Bool = false, initiator: URL? = nil) {
        self.topURL = topURL
        self.isTopLevel = isTopLevel
        self.initiator = initiator
    }

    /// リダイレクトで次の URL に進んだときの文脈
    func redirected(from: URL, to next: URL) -> RequestContext {
        var c = self
        if !SiteUtil.isSameSite(from, next) { c.crossSiteChain = true }
        c.previousURL = from
        // トップレベルの移動なら、トップのページは移動先になる
        if isTopLevel { c.topURL = next }
        return c
    }
}

// MARK: - Cookie

/// Cookie 1 つ（WebKit の置き場の写し・Set-Cookie から作ったもの）
struct CookieRecord: Sendable, Equatable {
    enum SameSite: String, Sendable { case unspecified, none, lax, strict }

    var name: String
    var value: String
    /// 先頭の「.」は外した形（小文字）
    var domain: String
    /// Domain 属性が無かった（このホストだけに送る）
    var hostOnly: Bool
    var path: String
    var secure = false
    var httpOnly = false
    var sameSite = SameSite.unspecified
    /// nil ならセッションの間だけ
    var expires: Date?
    /// 作られた時刻（送る順番に使う。WebKit の置き場には無いので、写しで覚える）
    var created: Date

    var key: String { "\(name)\u{1}\(domain)\u{1}\(path)" }

    func isExpired(_ now: Date) -> Bool {
        if let e = expires { return e <= now }
        return false
    }

    /// このホストに送ってよいドメインか
    func domainMatches(_ host: String) -> Bool {
        let h = SiteUtil.normalizeHost(host)
        if hostOnly { return h == domain }
        if h == domain { return true }
        return !SiteUtil.isIPLiteral(h) && h.hasSuffix("." + domain)
    }

    /// このパスに送ってよいか（RFC 6265 5.1.4）
    func pathMatches(_ requestPath: String) -> Bool {
        let p = requestPath.isEmpty ? "/" : requestPath
        if p == path { return true }
        guard p.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        return p.dropFirst(path.count).first == "/"
    }
}

/// Set-Cookie の 1 行を読む（RFC 6265 / 6265bis）。だめな Cookie は nil と理由
enum SetCookieParser {
    static let maxNameValueBytes = 4096

    enum Outcome {
        case cookie(CookieRecord)
        case rejected(String)
    }

    static func parse(_ line: String, url: URL, now: Date = Date()) -> Outcome {
        guard let host = SiteUtil.host(of: url) else { return .rejected("ホスト名がありません") }
        var parts = line.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        let pair = parts.removeFirst()
        var name = "", value = ""
        if let eq = pair.firstIndex(of: "=") {
            name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else {
            value = pair.trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty && value.isEmpty { return .rejected("名前も値もありません") }
        if name.utf8.count + value.utf8.count > maxNameValueBytes { return .rejected("大きすぎます") }
        if (name + value).unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) {
            return .rejected("制御文字が入っています")
        }

        var rec = CookieRecord(name: name, value: value, domain: host, hostOnly: true, path: defaultPath(url), created: now)
        var maxAge: Int?
        var expires: Date?
        for raw in parts {
            let a = raw.trimmingCharacters(in: .whitespaces)
            if a.isEmpty { continue }
            let k: String, v: String
            if let eq = a.firstIndex(of: "=") {
                k = String(a[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                v = String(a[a.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                k = a.lowercased(); v = ""
            }
            switch k {
            case "expires": if let d = HTTPDate.parse(v) { expires = d }
            case "max-age":
                if let n = Int(v) { maxAge = n }
            case "domain":
                var d = v.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                d = SiteUtil.normalizeHost(d)
                if d.isEmpty { continue }
                if SiteUtil.isPublicSuffix(d) {
                    if d == host { continue }          // ホストそのものなら、このホストだけの Cookie として受ける
                    return .rejected("公開の末尾（\(d)）には付けられません")
                }
                let probe = CookieRecord(name: "", value: "", domain: d, hostOnly: false, path: "/", created: now)
                guard probe.domainMatches(host) else { return .rejected("Domain=\(d) はこのホスト（\(host)）に合いません") }
                rec.domain = d
                rec.hostOnly = SiteUtil.isIPLiteral(host)   // IP のときは Domain があってもそのアドレスだけ
            case "path":
                if v.hasPrefix("/") { rec.path = v }
            case "secure": rec.secure = true
            case "httponly": rec.httpOnly = true
            case "samesite":
                switch v.lowercased() {
                case "strict": rec.sameSite = .strict
                case "lax": rec.sameSite = .lax
                case "none": rec.sameSite = .none
                default: rec.sameSite = .unspecified
                }
            default: break
            }
        }
        if let m = maxAge { rec.expires = m <= 0 ? Date(timeIntervalSince1970: 0) : now.addingTimeInterval(TimeInterval(m)) }
        else if let e = expires { rec.expires = e }

        let secureURL = SiteUtil.isSecureScheme(url)
        if rec.secure && !secureURL { return .rejected("Secure の Cookie は https からしか作れません") }
        if rec.sameSite == .none && !rec.secure { return .rejected("SameSite=None には Secure が必要です") }
        if name.hasPrefix("__Secure-") && !(rec.secure && secureURL) { return .rejected("__Secure- には Secure が必要です") }
        if name.hasPrefix("__Host-") && !(rec.secure && secureURL && rec.hostOnly && rec.path == "/") {
            return .rejected("__Host- には Secure・Domain なし・Path=/ が必要です")
        }
        return .cookie(rec)
    }

    /// 既定の Path（RFC 6265 5.1.4: 最後の「/」の手前まで）
    static func defaultPath(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard p.hasPrefix("/"), let last = p.lastIndex(of: "/"), last != p.startIndex else { return "/" }
        return String(p[..<last])
    }
}

/// http の日付（Expires）を読む
enum HTTPDate {
    private static let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                  "EEE MMM d HH:mm:ss yyyy", "EEE, dd MMM yy HH:mm:ss zzz", "EEE, dd-MMM-yy HH:mm:ss zzz",
                                  "dd MMM yyyy HH:mm:ss zzz"]
    private static let formatters: [DateFormatter] = formats.map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "GMT")
        d.dateFormat = f
        return d
    }
    private static let lock = NSLock()

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        for f in formatters { if let d = f.date(from: t) { return d } }
        return nil
    }
}

enum CookiePolicy {
    struct Settings: Sendable, Equatable {
        /// サードパーティ Cookie を保存も送信もしない（Safari の ITP や Storage Access API の例外までは再現しない）
        var blockThirdParty = true
        /// SameSite が無い Cookie を Lax として扱う
        var laxByDefault = true
        /// Lax-by-default の例外: 作られてからこの秒数の間は、クロスサイトのトップレベルの POST にも付ける（0 で例外なし）
        var laxPostGrace: TimeInterval = 120
        init() {}
    }

    static let safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "TRACE"]

    /// この要求はクロスサイトか（SameSite の判定用）
    static func isCrossSite(_ url: URL, method: String, ctx: RequestContext) -> Bool {
        if ctx.crossSiteChain { return true }
        if ctx.isTopLevel {
            // どこから来たかで決める。分からないとき: 安全なメソッドならユーザーの操作とみなす、それ以外はクロスサイト扱い
            if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
            if ctx.userInitiated { return false }
            return !safeMethods.contains(method.uppercased())
        }
        if let t = ctx.topURL { return !SiteUtil.isSameSite(t, url) }
        if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
        return false
    }

    /// サードパーティの要求か（ページの中の部品・iframe が、トップと別のサイトのもの）
    static func isThirdParty(_ url: URL, ctx: RequestContext) -> Bool {
        if ctx.isTopLevel { return false }
        if ctx.crossSiteChain { return true }
        guard let t = ctx.topURL else { return false }
        return !SiteUtil.isSameSite(t, url)
    }

    /// 1 つの Cookie を送るか。送らないなら理由
    static func sendDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext,
                             settings: Settings, now: Date = Date()) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if c.isExpired(now) { return "期限切れ" }
        guard let host = SiteUtil.host(of: url), c.domainMatches(host) else { return "ドメインが合わない" }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if !c.pathMatches(path) { return "パスが合わない" }
        if c.secure && !SiteUtil.isSecureScheme(url) { return "Secure なのに https でない" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        guard isCrossSite(url, method: method, ctx: ctx) else { return nil }
        let topLevelSafe = ctx.isTopLevel && safeMethods.contains(method.uppercased())
        switch c.sameSite {
        case .strict:
            return "SameSite=Strict でクロスサイト"
        case .lax:
            return topLevelSafe ? nil : "SameSite=Lax でクロスサイト"
        case .none:
            return nil
        case .unspecified:
            if !settings.laxByDefault { return nil }
            if topLevelSafe { return nil }
            if ctx.isTopLevel && method.uppercased() == "POST" && settings.laxPostGrace > 0
                && now.timeIntervalSince(c.created) <= settings.laxPostGrace { return nil }
            return "SameSite なし（Lax 扱い）でクロスサイト"
        }
    }

    /// 送る Cookie を順番に並べる（パスが長い順 → 作られた順）
    static func cookiesToSend(_ jar: [CookieRecord], url: URL, method: String, ctx: RequestContext,
                              settings: Settings, now: Date = Date()) -> (send: [CookieRecord], skipped: [(String, String)]) {
        var send: [CookieRecord] = []
        var skipped: [(String, String)] = []
        for c in jar {
            if let why = sendDecision(c, url: url, method: method, ctx: ctx, settings: settings, now: now) {
                // ドメイン・パスが合わないものはログに出さない（関係ない Cookie なので）
                if why != "ドメインが合わない" && why != "パスが合わない" && why != "期限切れ" { skipped.append((c.name, why)) }
            } else {
                send.append(c)
            }
        }
        send.sort { a, b in a.path.count != b.path.count ? a.path.count > b.path.count : a.created < b.created }
        return (send, skipped)
    }

    static func header(_ cookies: [CookieRecord]) -> String? {
        if cookies.isEmpty { return nil }
        return cookies.map { $0.name.isEmpty ? $0.value : "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 届いた Cookie を保存してよいか。だめなら理由
    static func storeDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext, settings: Settings) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        // クロスサイトの部品の応答からは、SameSite=Lax / Strict の Cookie を作らせない（6265bis）
        if !ctx.isTopLevel && isCrossSite(url, method: method, ctx: ctx) && (c.sameSite == .lax || c.sameSite == .strict) {
            return "クロスサイトの部品からの SameSite=\(c.sameSite.rawValue)"
        }
        return nil
    }
}

// MARK: - リダイレクト

enum RedirectPolicy {
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    static let maxRedirects = 20
    /// 本体に関するヘッダ（メソッドが GET に変わったら外す）
    static let bodyHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "content-language", "content-location"]
    /// オリジンが変わったら外す
    static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]

    struct Next: Sendable {
        var url: URL
        var method: String
        var headers: [(String, String)]
        var body: Data?
        var crossOrigin: Bool
        var upgradedByHSTS: Bool
        /// 外したヘッダの名前（ログ用）
        var dropped: [String]
    }

    enum Failure: Error, Equatable, Sendable {
        case noLocation, badLocation(String), unsupportedScheme(String), tooMany
    }

    /// 3xx の応答から、次の要求を作る
    /// - hsts: そのホストを https に上げるべきか
    static func next(from url: URL, method: String, headers: [(String, String)], body: Data?, status: Int,
                     location: String?, redirectCount: Int, hsts: (String) -> Bool = { _ in false }) -> Result<Next, Failure> {
        if redirectCount >= maxRedirects { return .failure(.tooMany) }
        guard let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else { return .failure(.noLocation) }
        guard var nextURL = URL(string: loc, relativeTo: url)?.absoluteURL else { return .failure(.badLocation(loc)) }
        let scheme = nextURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        var upgraded = false
        if scheme == "http", let h = SiteUtil.host(of: nextURL), hsts(h), var c = URLComponents(url: nextURL, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            if let u = c.url { nextURL = u; upgraded = true }
        }

        var m = method.uppercased()
        var b = body
        var drop = Set<String>()
        if status == 303 && m != "HEAD" || (status == 301 || status == 302) && m == "POST" {
            m = "GET"
            b = nil
            drop.formUnion(bodyHeaders)
        }
        let crossOrigin = !SiteUtil.isSameOrigin(url, nextURL)
        // Cookie は移動先で CookiePolicy がもう一度決める（前の相手のものを持ち越さない）
        drop.insert("cookie")
        if crossOrigin { drop.formUnion(credentialHeaders) }

        var out: [(String, String)] = []
        var dropped: [String] = []
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "host" { continue }
            if drop.contains(lk) { dropped.append(k); continue }
            switch lk {
            case "origin":
                // クロスオリジンに移ったら、元のオリジンは「null」にする（Fetch の仕様）
                if crossOrigin, let target = SiteUtil.origin(of: nextURL), v != target { out.append((k, "null")) } else { out.append((k, v)) }
            case "referer":
                guard let ref = URL(string: v) else { dropped.append(k); continue }
                if SiteUtil.isSecureScheme(ref) && !SiteUtil.isSecureScheme(nextURL) { dropped.append(k); continue }  // https → http では送らない
                if !SiteUtil.isSameOrigin(ref, nextURL), let o = SiteUtil.origin(of: ref) { out.append((k, o + "/")) }  // 別オリジンにはオリジンだけ
                else { out.append((k, v)) }
            default:
                out.append((k, v))
            }
        }
        return .success(Next(url: nextURL, method: m, headers: out, body: b, crossOrigin: crossOrigin, upgradedByHSTS: upgraded, dropped: dropped))
    }
}

// MARK: - CORS

/// サーバーの Access-Control-* をそのまま通す。Vela が自分で許可を作ることはしない
enum CORSPassthrough {
    /// vnetsMode: 予備の vnets:// 方式（開発者向け）。そのときだけ、許可されたオリジンの https:// を vnets:// に読み替える
    static func headers(_ server: [(String, String)], vnetsMode: Bool) -> [(String, String)] {
        server.compactMap { k, v in
            let lk = k.lowercased()
            guard lk.hasPrefix("access-control-") else { return nil }
            if vnetsMode && lk == "access-control-allow-origin" {
                if v.lowercased().hasPrefix("https://") { return (k, "vnets://" + v.dropFirst(8)) }
                if v.lowercased().hasPrefix("http://") { return (k, "vnet://" + v.dropFirst(7)) }
            }
            return (k, v)
        }
    }
}

// MARK: - ローカルネットワーク（LAN）

/// アドレスの種類
enum IPClass: String, Sendable {
    case publicAddress = "公開"
    case privateAddress = "LAN"
    case loopback = "ループバック"
    case linkLocal = "リンクローカル"
    /// VNet の中（10.0.2.x。ルーター・DNS など）
    case vnetInternal = "VNet 内部"
    case unspecified = "未指定"

    /// LAN 側（公開でない）か
    var isLocal: Bool { self != .publicAddress }
}

/// Vela 独自のローカルネットワークへの接続の制御（Chrome の Private Network Access / Local Network Access とは別物）
enum LocalNetworkPolicy {
    static func classify(_ ip: [UInt8]) -> IPClass {
        guard ip.count == 4 else { return .publicAddress }
        switch (ip[0], ip[1]) {
        case (0, _): return .unspecified
        case (10, 0) where ip[2] == 2: return .vnetInternal
        case (10, _): return .privateAddress
        case (127, _): return .loopback
        case (169, 254): return .linkLocal
        case (172, 16...31): return .privateAddress
        case (192, 168): return .privateAddress
        case (100, 64...127): return .privateAddress          // CGNAT（100.64/10）
        default: return ip[0] >= 224 ? .unspecified : .publicAddress   // マルチキャストなど
        }
    }

    static func classify(v6 g: [UInt16]) -> IPClass {
        guard g.count == 8 else { return .publicAddress }
        if g.allSatisfy({ $0 == 0 }) { return .unspecified }
        if g[0..<7].allSatisfy({ $0 == 0 }) && g[7] == 1 { return .loopback }
        if g[0..<5].allSatisfy({ $0 == 0 }) && g[5] == 0xFFFF {        // ::ffff:a.b.c.d
            return classify([UInt8(g[6] >> 8), UInt8(g[6] & 0xFF), UInt8(g[7] >> 8), UInt8(g[7] & 0xFF)])
        }
        if g[0] & 0xFE00 == 0xFC00 { return .privateAddress }           // fc00::/7（ULA）
        if g[0] & 0xFFC0 == 0xFE80 { return .linkLocal }                // fe80::/10
        if g[0] & 0xFF00 == 0xFF00 { return .unspecified }              // マルチキャスト
        return .publicAddress
    }

    /// ホスト名だけで分かるときの種類（数字のアドレス・localhost・.local）。名前を引かないと分からないなら nil
    static func classify(host: String) -> IPClass? {
        let h = SiteUtil.normalizeHost(host)
        if let v4 = IPAddressText.v4(h) { return classify(v4) }
        if let v6 = IPAddressText.v6(h) { return classify(v6: v6) }
        if h == "localhost" || h.hasSuffix(".localhost") { return .loopback }
        if h.hasSuffix(".local") || h.hasSuffix(".home.arpa") { return .privateAddress }
        return nil
    }

    enum Decision: Equatable, Sendable {
        case allow
        case block(String)
        /// トップレベルの移動: ユーザーに確かめてから
        case askUser(String)
    }

    /// target: 接続先のアドレスの種類。topClass: トップのページの種類。fromClass: 1 つ前（リダイレクト元・移動を起こしたページ）の種類
    static func decide(target: IPClass, ctx: RequestContext, topClass: IPClass?, fromClass: IPClass?) -> Decision {
        guard target.isLocal else { return .allow }
        if target == .vnetInternal || target == .unspecified { return .block("\(target.rawValue)のアドレスには接続しません") }
        if ctx.isTopLevel {
            if ctx.userInitiated && ctx.previousURL == nil { return .allow }     // アドレス欄から直接
            if let f = fromClass, f.isLocal { return .allow }                     // LAN のページから LAN へ
            if ctx.previousURL != nil && fromClass == .publicAddress {
                return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト")
            }
            return .askUser("ページが LAN（\(target.rawValue)）へ移動しようとしています")
        }
        if let t = topClass, t.isLocal { return .allow }                          // LAN のページの部品
        if ctx.previousURL != nil { return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト") }
        return .block("公開のサイトから LAN（\(target.rawValue)）の部品を読み込もうとしました")
    }
}

// ======================================================================
// MARK: - CookieJar.swift
// ======================================================================

// MARK: - Cookie の写し（正本は WebKit の WKHTTPCookieStore）
//
// ・正本は WebKit の置き場だけ。ここはその写しで、VNet が要求を送るとき（vnet-guest のキュー）に、待たずに読めるようにするためのもの
// ・WebKit の置き場が変わったら（WKHTTPCookieStoreObserver）、写しを作り直す（replaceAll）。この同期は WebCookieSync（PageScripts.swift）がやる
// ・VNet の応答の Set-Cookie は、CookiePolicy で許されたものだけを写しに入れて、変更（CookieChange）として返す。
//   呼んだ側が WebKit の置き場にも入れる（入れ終わってから、ページに返事を渡す）
// ・ページの JavaScript から届く「Cookie の文字列」は、一切ここに入れない（HttpOnly や Domain を偽れるため）

/// 写しの変更（WebKit の置き場にも同じことをする）
struct CookieChange: Sendable {
    var record: CookieRecord
    /// true なら消す
    var delete: Bool
}

final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: CookieRecord] = [:]
    private var _settings = CookiePolicy.Settings()
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?

    init() {}

    var settings: CookiePolicy.Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return cookies.count }

    func snapshot() -> [CookieRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(cookies.values)
    }

    /// 送る Cookie ヘッダ（送らないものがあれば理由も返す）
    func header(for url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> (header: String?, skipped: [(String, String)]) {
        lock.lock()
        let all = Array(cookies.values)
        let s = _settings
        lock.unlock()
        let (send, skipped) = CookiePolicy.cookiesToSend(all, url: url, method: method, ctx: ctx, settings: s, now: now)
        return (CookiePolicy.header(send), skipped)
    }

    /// 応答の Set-Cookie を受け取る。許されたものを写しに入れ、変更を返す
    func receive(_ lines: [String], url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> [CookieChange] {
        var changes: [CookieChange] = []
        let s = settings
        for line in lines {
            switch SetCookieParser.parse(line, url: url, now: now) {
            case .rejected(let why):
                log?("🍪✕ 受け取らない（\(SiteUtil.host(of: url) ?? "")）: \(why)")
            case .cookie(var rec):
                if let why = CookiePolicy.storeDecision(rec, url: url, method: method, ctx: ctx, settings: s) {
                    log?("🍪✕ 保存しない \(rec.name)（\(rec.domain)）: \(why)")
                    continue
                }
                lock.lock()
                if rec.isExpired(now) {
                    let old = cookies.removeValue(forKey: rec.key)
                    lock.unlock()
                    changes.append(CookieChange(record: old ?? rec, delete: true))
                    continue
                }
                // 置き換えるときは、最初に作られた時刻を引き継ぐ（RFC 6265 5.3 の 11.3）
                if let old = cookies[rec.key] { rec.created = old.created }
                cookies[rec.key] = rec
                lock.unlock()
                changes.append(CookieChange(record: rec, delete: false))
            }
        }
        return changes
    }

    /// WebKit の置き場の中身で写しを作り直す。作られた時刻と、WebKit が覚えていない SameSite は、前の写しから引き継ぐ
    func replaceAll(_ records: [CookieRecord], now: Date = Date()) {
        lock.lock()
        var next: [String: CookieRecord] = [:]
        for var r in records where !r.isExpired(now) {
            if let old = cookies[r.key] {
                r.created = old.created
                if r.sameSite == .unspecified { r.sameSite = old.sameSite }
            }
            next[r.key] = r
        }
        cookies = next
        lock.unlock()
    }

    func removeAll() {
        lock.lock(); cookies = [:]; lock.unlock()
    }
}

// MARK: - HTTPCookie との変換

extension CookieRecord {
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
    private static let sameSiteKey = HTTPCookiePropertyKey("SameSite")

    /// WebKit の置き場の HTTPCookie から作る（作られた時刻は分からないので now）
    init?(httpCookie c: HTTPCookie, now: Date = Date()) {
        var d = c.domain.lowercased()
        let hostOnly = !d.hasPrefix(".")
        while d.hasPrefix(".") { d.removeFirst() }
        if d.isEmpty { return nil }
        var ss = SameSite.unspecified
        #if canImport(Darwin)
        if let p = c.sameSitePolicy {
            if p == .sameSiteStrict { ss = .strict } else if p == .sameSiteLax { ss = .lax } else if p.rawValue.lowercased() == "none" { ss = .none }
        }
        #else
        if let p = c.properties?[CookieRecord.sameSiteKey] as? String {
            switch p.lowercased() { case "strict": ss = .strict; case "lax": ss = .lax; case "none": ss = .none; default: break }
        }
        #endif
        self.init(name: c.name, value: c.value, domain: SiteUtil.normalizeHost(d), hostOnly: hostOnly, path: c.path.isEmpty ? "/" : c.path,
                  secure: c.isSecure, httpOnly: c.isHTTPOnly, sameSite: ss, expires: c.expiresDate, created: now)
    }

    /// WebKit の置き場に入れる HTTPCookie にする
    func httpCookie() -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .path: path]
        if hostOnly {
            // Domain 属性なし（このホストだけ）: 先頭に「.」を付けない
            p[.domain] = domain
        } else {
            p[.domain] = "." + domain
        }
        if secure { p[.secure] = "TRUE" }
        if let e = expires { p[.expires] = e } else { p[.discard] = "TRUE" }
        if httpOnly { p[CookieRecord.httpOnlyKey] = "TRUE" }
        #if canImport(Darwin)
        switch sameSite {
        case .strict: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .lax: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .none, .unspecified: break
        }
        #else
        switch sameSite {
        case .strict: p[CookieRecord.sameSiteKey] = "strict"
        case .lax: p[CookieRecord.sameSiteKey] = "lax"
        case .none, .unspecified: break
        }
        #endif
        return HTTPCookie(properties: p)
    }
}

// ======================================================================
// MARK: - HSTSStore.swift
// ======================================================================

// MARK: - HSTS（「このサイトは https だけで開く」の記録）
//
// 決まり（README と開発者パネルにも書く）:
//  ・VNet が受け取った https の応答で、トップレベルかファーストパーティ（トップと同じサイト）のものからだけ登録する
//    （サードパーティの応答・http の応答・数字のアドレスのホストは無視する。サードパーティから登録させると、追跡に使えてしまう）
//  ・max-age で期限を決める。max-age=0 は消す。includeSubDomains に対応
//  ・ホスト名は SiteUtil.normalizeHost でそろえる
//  ・Application Support に保存する（期限切れは読み込むときに消す。最大 maxEntries 件。あふれたら期限の近いものから消す）
//  ・使い道: http:// への移動とリダイレクトを https に上げる

struct HSTSEntry: Codable, Equatable, Sendable {
    var host: String
    var expires: Date
    var includeSubDomains: Bool
}

enum HSTSPolicy {
    /// Strict-Transport-Security の値を読む。読めなければ nil
    static func parse(_ header: String) -> (maxAge: Int, includeSubDomains: Bool)? {
        var maxAge: Int?
        var sub = false
        var seen = Set<String>()
        for raw in header.split(separator: ";") {
            let d = raw.trimmingCharacters(in: .whitespaces)
            if d.isEmpty { continue }
            let k: String, v: String
            if let eq = d.firstIndex(of: "=") {
                k = d[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                v = d[d.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else {
                k = d.lowercased(); v = ""
            }
            if !seen.insert(k).inserted { return nil }     // 同じ指示が 2 回あるものは無効（RFC 6797）
            switch k {
            case "max-age":
                guard let n = Int(v), n >= 0 else { return nil }
                maxAge = n
            case "includesubdomains": sub = true
            default: break
            }
        }
        guard let m = maxAge else { return nil }
        return (m, sub)
    }

    /// この応答から登録してよいか
    static func mayRecord(url: URL, ctx: RequestContext) -> Bool {
        guard url.scheme?.lowercased() == "https", let h = SiteUtil.host(of: url), !SiteUtil.isIPLiteral(h) else { return false }
        if ctx.isTopLevel { return true }
        guard let top = ctx.topURL else { return false }
        return SiteUtil.isSameSite(top, url)
    }
}

/// HSTS の記録（どのスレッドからでも使える）
final class HSTSStore: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var entries: [String: HSTSEntry] = [:]
    private let fileURL: URL?
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "vela-hsts-save")
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?

    /// fileURL が nil なら保存しない（テスト用）
    init(fileURL: URL?, now: Date = Date()) {
        self.fileURL = fileURL
        if let f = fileURL, let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([HSTSEntry].self, from: d) {
            for e in list where e.expires > now { entries[e.host] = e }
        }
    }

    /// 既定の置き場（Application Support/Vela/hsts.json）
    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hsts.json")
    }

    /// このホストを https に上げるべきか
    func shouldUpgrade(_ host: String, now: Date = Date()) -> Bool {
        let h = SiteUtil.normalizeHost(host)
        if SiteUtil.isIPLiteral(h) { return false }
        lock.lock(); defer { lock.unlock() }
        if let e = entries[h], e.expires > now { return true }
        // 親のドメインが includeSubDomains で登録されているか
        var labels = h.split(separator: ".")
        while labels.count > 1 {
            labels.removeFirst()
            if let e = entries[labels.joined(separator: ".")], e.includeSubDomains, e.expires > now { return true }
        }
        return false
    }

    /// 応答の Strict-Transport-Security を記録する（mayRecord を満たすときだけ）
    func record(header: String, url: URL, ctx: RequestContext, now: Date = Date()) {
        guard HSTSPolicy.mayRecord(url: url, ctx: ctx), let h = SiteUtil.host(of: url) else { return }
        guard let (maxAge, sub) = HSTSPolicy.parse(header) else { log?("HSTS の値が読めません（\(h)）: \(header)"); return }
        lock.lock()
        var changed = false
        if maxAge == 0 {
            changed = entries.removeValue(forKey: h) != nil
        } else {
            let e = HSTSEntry(host: h, expires: now.addingTimeInterval(TimeInterval(maxAge)), includeSubDomains: sub)
            let old = entries[h]
            entries[h] = e
            // 期限が少し延びただけなら保存しない（毎回書くと重い）
            changed = old == nil || old!.includeSubDomains != sub || abs(old!.expires.timeIntervalSince(e.expires)) > 86400
            if entries.count > HSTSStore.maxEntries {
                let drop = entries.values.sorted { $0.expires < $1.expires }.prefix(entries.count - HSTSStore.maxEntries)
                for d in drop { entries[d.host] = nil }
            }
        }
        lock.unlock()
        if changed {
            log?(maxAge == 0 ? "HSTS を消しました: \(h)" : "HSTS を記録: \(h)（\(maxAge / 86400) 日\(sub ? "・サブドメインも" : "")）")
            scheduleSave()
        }
    }

    func all() -> [HSTSEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.host < $1.host }
    }

    func remove(_ host: String) {
        lock.lock(); entries[SiteUtil.normalizeHost(host)] = nil; lock.unlock()
        scheduleSave()
    }

    func removeAll() {
        lock.lock(); entries = [:]; lock.unlock()
        scheduleSave()
    }

    /// まとめて 2 秒後に書く
    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        guard let f = fileURL else { return }
        lock.lock()
        saveScheduled = false
        let list = Array(entries.values)
        lock.unlock()
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: f, options: .atomic) }
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
}

struct HTTPResult: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var url: URL
    /// CookieJar に入れた Cookie の変更（リダイレクトの途中の分も）。ブラウザ（WebKit）の Cookie の置き場にも同じことをする
    var cookieChanges: [CookieChange] = []
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
    func send(_ bytes: Data, isHead: Bool, limits: ResponseParser.Limits = ResponseParser.Limits(),
              onGrow: ((Int) -> Void)? = nil, done: @escaping Completion) -> Int {
        uses += 1
        serial += 1
        if !alive { done(.failure(FetchError("接続が閉じています", kind: .reset)), false, true); return serial }
        let p = ResponseParser(isHead: isHead, limits: limits)
        p.onBodyGrow = onGrow
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
            let kind: FetchError.Kind
            if case .tooLarge = f { kind = .tooLarge } else { kind = .malformed }
            finishCurrent(.failure(FetchError(f.description, kind: kind)), reusable: false)
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
                let serial = c.send(bytes, isHead: req.method == "HEAD", limits: self.parserLimits(),
                                    onGrow: { [weak self] n in held += n; self?.bufferedBytes += n }) { [weak self] r, reusable, gotNothing in
                    guard let self else { return }
                    self.bufferedBytes -= held
                    held = 0
                    self.release(c, reusable: reusable)
                    switch r {
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
                if case .tooLarge = f { return .failure(FetchError(f.description, kind: .tooLarge)) }
                return .failure(FetchError(f.description, kind: .malformed))
            }
        }
        headers.removeAll(named: ["transfer-encoding"])
        return .success(HTTPResult(status: p.status, headers: headers, body: body, url: url, cookieChanges: changes))
    }
}
