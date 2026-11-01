import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
