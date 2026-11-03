import Foundation

// 通信の決まりの部品（NetPolicy.swift の続き）。Cookie 1 つの形・Set-Cookie の読み取り・送るかどうかの判定

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
            let (k, v) = HeaderParams.splitAttribute(a)
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
    /// Cookie を送らない理由（確かめる順番もこの並び。先に当てはまったものが理由になる）
    enum SendSkip: CaseIterable {
        case notAllowed, expired, domain, path, insecure, thirdParty, strict, lax, unspecified

        var text: String {
            switch self {
            case .notAllowed: return "Cookie を扱わない要求"
            case .expired: return "期限切れ"
            case .domain: return "ドメインが合わない"
            case .path: return "パスが合わない"
            case .insecure: return "Secure なのに https でない"
            case .thirdParty: return "サードパーティ Cookie をブロック"
            case .strict: return "SameSite=Strict でクロスサイト"
            case .lax: return "SameSite=Lax でクロスサイト"
            case .unspecified: return "SameSite なし（Lax 扱い）でクロスサイト"
            }
        }

        /// 開発者向けのログに出すか（期限切れ・ドメイン・パスは関係ない Cookie なので出さない）
        var isLogged: Bool {
            switch self {
            case .expired, .domain, .path: return false
            default: return true
            }
        }
    }

    /// 送らない理由（送ってよければ nil）
    static func sendSkip(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext,
                         settings: Settings, now: Date = Date()) -> SendSkip? {
        if !ctx.cookiesAllowed { return .notAllowed }
        if c.isExpired(now) { return .expired }
        guard let host = SiteUtil.host(of: url), c.domainMatches(host) else { return .domain }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if !c.pathMatches(path) { return .path }
        if c.secure && !SiteUtil.isSecureScheme(url) { return .insecure }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return .thirdParty }
        guard isCrossSite(url, method: method, ctx: ctx) else { return nil }
        let topLevelSafe = ctx.isTopLevel && safeMethods.contains(method.uppercased())
        switch c.sameSite {
        case .strict:
            return .strict
        case .lax:
            return topLevelSafe ? nil : .lax
        case .none:
            return nil
        case .unspecified:
            if !settings.laxByDefault { return nil }
            if topLevelSafe { return nil }
            if ctx.isTopLevel && method.uppercased() == "POST" && settings.laxPostGrace > 0
                && now.timeIntervalSince(c.created) <= settings.laxPostGrace { return nil }
            return .unspecified
        }
    }

    /// 送らない理由の文言（送ってよければ nil）
    static func sendDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext,
                             settings: Settings, now: Date = Date()) -> String? {
        sendSkip(c, url: url, method: method, ctx: ctx, settings: settings, now: now)?.text
    }

    /// 送る Cookie を順番に並べる（パスが長い順 → 作られた順）
    static func cookiesToSend(_ jar: [CookieRecord], url: URL, method: String, ctx: RequestContext,
                              settings: Settings, now: Date = Date()) -> (send: [CookieRecord], skipped: [(String, String)]) {
        var send: [CookieRecord] = []
        var skipped: [(String, String)] = []
        for c in jar {
            if let why = sendSkip(c, url: url, method: method, ctx: ctx, settings: settings, now: now) {
                if why.isLogged { skipped.append((c.name, why.text)) }
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
