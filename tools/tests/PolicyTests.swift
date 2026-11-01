import Foundation

// MARK: - NetPolicy・HSTSStore・CookieJar のテスト

func siteTests() {
    print("SiteUtil")
    test("ホスト名の正規化") {
        expectEqual(SiteUtil.normalizeHost("WWW.Example.COM."), "www.example.com")
        expectEqual(SiteUtil.normalizeHost("[::1]"), "::1")
    }
    test("登録できるドメイン") {
        expectEqual(SiteUtil.registrableDomain("www.example.co.jp"), "example.co.jp")
        expectEqual(SiteUtil.registrableDomain("a.b.example.com"), "example.com")
        expectEqual(SiteUtil.registrableDomain("example.com"), "example.com")
        expectEqual(SiteUtil.registrableDomain("user.github.io"), "user.github.io")
        expectEqual(SiteUtil.registrableDomain("x.user.github.io"), "user.github.io")
        expectEqual(SiteUtil.registrableDomain("bucket.s3.amazonaws.com"), "bucket.s3.amazonaws.com")
        expectEqual(SiteUtil.registrableDomain("192.168.0.1"), "192.168.0.1")
    }
    test("同じサイト・同じオリジン") {
        expect(SiteUtil.isSameSite(url("https://a.example.com/"), url("http://b.example.com/x")))
        expect(!SiteUtil.isSameSite(url("https://alice.github.io/"), url("https://bob.github.io/")))
        expect(!SiteUtil.isSameSite(url("https://example.co.jp/"), url("https://other.co.jp/")))
        expect(SiteUtil.isSameOrigin(url("https://example.com/a"), url("https://example.com:443/b")))
        expect(!SiteUtil.isSameOrigin(url("https://example.com/"), url("http://example.com/")))
        expect(!SiteUtil.isSameOrigin(url("https://example.com/"), url("https://example.com:8443/")))
        expectEqual(SiteUtil.origin(of: url("https://Example.com:8443/x")), "https://example.com:8443")
    }
    test("公開の末尾") {
        expect(SiteUtil.isPublicSuffix("jp"))
        expect(SiteUtil.isPublicSuffix("co.jp"))
        expect(SiteUtil.isPublicSuffix("github.io"))
        expect(!SiteUtil.isPublicSuffix("example.co.jp"))
        expect(!SiteUtil.isPublicSuffix("localhost"))
    }
    test("IPv6 の読み取り") {
        expectEqual(IPAddressText.v6("::1") ?? [], [0, 0, 0, 0, 0, 0, 0, 1])
        expectEqual(IPAddressText.v6("fe80::1%en0") ?? [], [0xfe80, 0, 0, 0, 0, 0, 0, 1])
        expectEqual(IPAddressText.v6("::ffff:192.168.1.2") ?? [], [0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0102])
        expect(IPAddressText.v6("1::2::3") == nil)
        expect(IPAddressText.v4("256.1.1.1") == nil)
        expect(IPAddressText.v4("1.2.3") == nil)
    }
}

func setCookieTests() {
    print("SetCookieParser")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func parse(_ s: String, _ u: String) -> CookieRecord? {
        if case .cookie(let c) = SetCookieParser.parse(s, url: url(u), now: now) { return c }
        return nil
    }
    test("基本の属性") {
        let c = parse("sid=abc; Path=/app; Secure; HttpOnly; SameSite=Strict; Max-Age=60", "https://www.example.com/app/page")
        expect(c != nil)
        expectEqual(c?.name, "sid"); expectEqual(c?.value, "abc"); expectEqual(c?.path, "/app")
        expectEqual(c?.secure, true); expectEqual(c?.httpOnly, true); expectEqual(c?.sameSite, .strict)
        expectEqual(c?.hostOnly, true); expectEqual(c?.domain, "www.example.com")
        expectEqual(c?.expires, now.addingTimeInterval(60))
    }
    test("既定の Path") {
        expectEqual(parse("a=1", "https://example.com/a/b/c")?.path, "/a/b")
        expectEqual(parse("a=1", "https://example.com/a")?.path, "/")
        expectEqual(parse("a=1", "https://example.com/")?.path, "/")
    }
    test("Domain 属性") {
        let c = parse("a=1; Domain=.Example.com", "https://www.example.com/")
        expectEqual(c?.domain, "example.com"); expectEqual(c?.hostOnly, false)
        expect(parse("a=1; Domain=other.com", "https://www.example.com/") == nil, "合わないドメイン")
        expect(parse("a=1; Domain=co.jp", "https://example.co.jp/") == nil, "公開の末尾")
        expect(parse("a=1; Domain=com", "https://example.com/") == nil, "TLD")
    }
    test("Secure・SameSite=None・接頭辞の検査") {
        expect(parse("a=1; Secure", "http://example.com/") == nil)
        expect(parse("a=1; SameSite=None", "https://example.com/") == nil)
        expect(parse("a=1; SameSite=None; Secure", "https://example.com/") != nil)
        expect(parse("__Secure-a=1", "https://example.com/") == nil)
        expect(parse("__Secure-a=1; Secure", "https://example.com/") != nil)
        expect(parse("__Host-a=1; Secure; Path=/; Domain=example.com", "https://example.com/") == nil)
        expect(parse("__Host-a=1; Secure; Path=/", "https://example.com/x") != nil)
    }
    test("Expires と Max-Age=0") {
        let c = parse("a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT", "https://example.com/")
        expect(c?.isExpired(now) == true)
        let d = parse("a=1; Max-Age=0", "https://example.com/")
        expect(d?.isExpired(now) == true)
        let e = parse("a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=100", "https://example.com/")
        expect(e?.isExpired(now) == false, "Max-Age が優先")
    }
    test("制御文字は拒否") {
        expect(parse("a=1\u{0}x", "https://example.com/") == nil)
    }
}

func cookiePolicyTests() {
    print("CookiePolicy")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let s = CookiePolicy.Settings()
    func rec(_ name: String, domain: String = "example.com", hostOnly: Bool = false, path: String = "/",
             secure: Bool = true, sameSite: CookieRecord.SameSite = .unspecified, created: Date? = nil) -> CookieRecord {
        CookieRecord(name: name, value: "v", domain: domain, hostOnly: hostOnly, path: path, secure: secure,
                     sameSite: sameSite, created: created ?? now.addingTimeInterval(-3600))
    }
    func sends(_ c: CookieRecord, _ u: String, method: String = "GET", _ ctx: RequestContext, _ st: CookiePolicy.Settings = CookiePolicy.Settings()) -> Bool {
        CookiePolicy.sendDecision(c, url: url(u), method: method, ctx: ctx, settings: st, now: now) == nil
    }
    let sameSiteSub = RequestContext(topURL: url("https://www.example.com/"))
    let crossSub = RequestContext(topURL: url("https://evil.test/"))
    var crossNav = RequestContext(topURL: url("https://example.com/"), isTopLevel: true, initiator: url("https://evil.test/page"))
    test("同じサイトの部品には全部送る") {
        expect(sends(rec("a", sameSite: .strict), "https://api.example.com/x", sameSiteSub))
        expect(sends(rec("a", sameSite: .lax), "https://api.example.com/x", sameSiteSub))
        expect(sends(rec("a"), "https://api.example.com/x", sameSiteSub))
    }
    test("サードパーティは既定でブロック") {
        expect(!sends(rec("a", sameSite: .none), "https://example.com/x", crossSub))
        var off = s; off.blockThirdParty = false
        expect(sends(rec("a", sameSite: .none), "https://example.com/x", crossSub, off))
        expect(!sends(rec("a", sameSite: .lax), "https://example.com/x", crossSub, off), "Lax はクロスサイトの部品に送らない")
        expect(!sends(rec("a"), "https://example.com/x", crossSub, off), "SameSite なしは Lax 扱い")
        var noLax = off; noLax.laxByDefault = false
        expect(sends(rec("a"), "https://example.com/x", crossSub, noLax))
    }
    test("クロスサイトのトップレベルの移動") {
        expect(!sends(rec("a", sameSite: .strict), "https://example.com/", crossNav))
        expect(sends(rec("a", sameSite: .lax), "https://example.com/", crossNav))
        expect(sends(rec("a"), "https://example.com/", crossNav))
        expect(!sends(rec("a", sameSite: .lax), "https://example.com/", method: "POST", crossNav))
        expect(!sends(rec("a"), "https://example.com/", method: "POST", crossNav), "2 分を過ぎた Lax 扱い")
        expect(sends(rec("a", created: now.addingTimeInterval(-60)), "https://example.com/", method: "POST", crossNav), "2 分以内の例外")
        expect(sends(rec("a", sameSite: .none), "https://example.com/", method: "POST", crossNav))
    }
    test("ユーザーの操作・どこから来たか分からない移動") {
        var typed = RequestContext(topURL: url("https://example.com/"), isTopLevel: true)
        typed.userInitiated = true
        expect(sends(rec("a", sameSite: .strict), "https://example.com/", typed))
        let unknown = RequestContext(topURL: url("https://example.com/"), isTopLevel: true)
        expect(sends(rec("a", sameSite: .strict), "https://example.com/", unknown), "GET なら送る")
        expect(!sends(rec("a", sameSite: .strict), "https://example.com/", method: "POST", unknown), "POST はクロスサイト扱い")
    }
    test("リダイレクトの経路で一度クロスサイトになったら戻らない") {
        let start = RequestContext(topURL: url("https://example.com/"), isTopLevel: true, initiator: url("https://example.com/"))
        let hop1 = start.redirected(from: url("https://example.com/a"), to: url("https://evil.test/b"))
        let hop2 = hop1.redirected(from: url("https://evil.test/b"), to: url("https://example.com/c"))
        expect(hop2.crossSiteChain)
        expect(!sends(rec("a", sameSite: .strict), "https://example.com/c", hop2))
        expect(sends(rec("a", sameSite: .lax), "https://example.com/c", hop2), "トップレベルの GET なので Lax は送る")
        var subStart = RequestContext(topURL: url("https://example.com/"))
        subStart = subStart.redirected(from: url("https://example.com/x"), to: url("https://evil.test/y"))
        subStart = subStart.redirected(from: url("https://evil.test/y"), to: url("https://example.com/z"))
        expect(!sends(rec("a", sameSite: .none), "https://example.com/z", subStart), "部品の経路がクロスサイト → サードパーティ扱い")
    }
    test("Secure・ドメイン・パス・omit") {
        expect(!sends(rec("a"), "http://example.com/", sameSiteSub), "Secure は http に送らない")
        expect(!sends(rec("a", domain: "www.example.com", hostOnly: true), "https://api.example.com/", sameSiteSub))
        expect(!sends(rec("a", path: "/app"), "https://example.com/application", sameSiteSub))
        expect(sends(rec("a", path: "/app"), "https://example.com/app/x", sameSiteSub))
        var omit = sameSiteSub; omit.cookiesAllowed = false
        expect(!sends(rec("a"), "https://example.com/", omit))
    }
    test("送る順番（パスが長い順 → 作られた順）と、同じ名前の別パス") {
        let a = rec("x", path: "/", created: now.addingTimeInterval(-10))
        let b = rec("x", path: "/app", created: now.addingTimeInterval(-5))
        let c = rec("y", path: "/", created: now.addingTimeInterval(-20))
        let (send, _) = CookiePolicy.cookiesToSend([a, c, b], url: url("https://example.com/app/z"), method: "GET", ctx: sameSiteSub, settings: s, now: now)
        expectEqual(send.map { "\($0.name)\($0.path)" }, ["x/app", "y/", "x/"])
    }
    test("保存の判定") {
        let none = rec("a", sameSite: .none)
        expect(CookiePolicy.storeDecision(none, url: url("https://example.com/"), method: "GET", ctx: crossSub, settings: s) != nil)
        var off = s; off.blockThirdParty = false
        expect(CookiePolicy.storeDecision(none, url: url("https://example.com/"), method: "GET", ctx: crossSub, settings: off) == nil)
        expect(CookiePolicy.storeDecision(rec("a", sameSite: .lax), url: url("https://example.com/"), method: "GET", ctx: crossSub, settings: off) != nil)
        crossNav.isTopLevel = true
        expect(CookiePolicy.storeDecision(rec("a", sameSite: .strict), url: url("https://example.com/"), method: "GET", ctx: crossNav, settings: s) == nil)
    }
}

func cookieJarTests() {
    print("CookieJar")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    test("受け取り・置き換えで作られた時刻を保つ・消す") {
        let jar = CookieJar()
        let ctx = RequestContext(topURL: url("https://example.com/"), isTopLevel: true)
        var ch = jar.receive(["a=1; Path=/", "b=2; Secure"], url: url("https://example.com/"), method: "GET", ctx: ctx, now: now)
        expectEqual(ch.count, 2)
        ch = jar.receive(["a=9; Path=/"], url: url("https://example.com/"), method: "GET", ctx: ctx, now: now.addingTimeInterval(50))
        expectEqual(jar.snapshot().first { $0.name == "a" }?.created, now)
        expectEqual(jar.snapshot().first { $0.name == "a" }?.value, "9")
        ch = jar.receive(["a=; Max-Age=0"], url: url("https://example.com/"), method: "GET", ctx: ctx, now: now)
        expectEqual(ch.first?.delete, true)
        expectEqual(jar.count, 1)
        let (h, _) = jar.header(for: url("https://example.com/x"), method: "GET", ctx: ctx, now: now)
        expectEqual(h, "b=2")
    }
    test("サードパーティの応答からは保存しない") {
        let jar = CookieJar()
        let ctx = RequestContext(topURL: url("https://news.test/"))
        let ch = jar.receive(["track=1; SameSite=None; Secure"], url: url("https://ads.example/"), method: "GET", ctx: ctx, now: now)
        expect(ch.isEmpty)
        expectEqual(jar.count, 0)
    }
    test("WebKit の置き場からの作り直しで、時刻と SameSite を引き継ぐ") {
        let jar = CookieJar()
        let ctx = RequestContext(topURL: url("https://example.com/"), isTopLevel: true)
        _ = jar.receive(["a=1; SameSite=Strict"], url: url("https://example.com/"), method: "GET", ctx: ctx, now: now)
        var fromWebKit = jar.snapshot()[0]
        fromWebKit.sameSite = .unspecified
        fromWebKit.created = now.addingTimeInterval(1000)
        jar.replaceAll([fromWebKit], now: now)
        expectEqual(jar.snapshot()[0].sameSite, .strict)
        expectEqual(jar.snapshot()[0].created, now)
    }
    test("HTTPCookie との往復") {
        let r = CookieRecord(name: "a", value: "1", domain: "example.com", hostOnly: false, path: "/p", secure: true,
                             httpOnly: true, sameSite: .lax, expires: now.addingTimeInterval(100), created: now)
        guard let hc = r.httpCookie() else { expect(false, "HTTPCookie を作れない"); return }
        let back = CookieRecord(httpCookie: hc, now: now)
        expectEqual(back?.domain, "example.com"); expectEqual(back?.hostOnly, false)
        expectEqual(back?.path, "/p"); expectEqual(back?.secure, true); expectEqual(back?.httpOnly, true)
    }
}

func redirectTests() {
    print("RedirectPolicy")
    let base: [(String, String)] = [("Authorization", "Bearer x"), ("Proxy-Authorization", "y"), ("Cookie", "a=1"),
                                    ("Content-Type", "application/json"), ("Origin", "https://example.com"),
                                    ("Referer", "https://example.com/page?q=1"), ("Accept", "*/*")]
    func names(_ h: [(String, String)]) -> Set<String> { Set(h.map { $0.0.lowercased() }) }
    func run(_ status: Int, _ method: String, from: String = "https://example.com/a", to: String,
             hsts: @escaping (String) -> Bool = { _ in false }) -> RedirectPolicy.Next? {
        if case .success(let n) = RedirectPolicy.next(from: url(from), method: method, headers: base, body: Data("b".utf8),
                                                      status: status, location: to, redirectCount: 0, hsts: hsts) { return n }
        return nil
    }
    test("同じオリジン: Authorization を保ち、Cookie は外す") {
        let n = run(302, "GET", to: "/b")!
        expectEqual(n.url.absoluteString, "https://example.com/b")
        expect(names(n.headers).contains("authorization"))
        expect(!names(n.headers).contains("cookie"))
        expect(!n.crossOrigin)
    }
    test("別オリジン: Authorization・Proxy-Authorization・Cookie を外す、Origin は null、Referer はオリジンだけ") {
        let n = run(302, "GET", to: "https://other.test/x")!
        let h = names(n.headers)
        expect(!h.contains("authorization") && !h.contains("proxy-authorization") && !h.contains("cookie"))
        expectEqual(n.headers.value(for: "Origin"), "null")
        expectEqual(n.headers.value(for: "Referer"), "https://example.com/")
        expect(n.crossOrigin)
    }
    test("https → http: Referer を送らない") {
        let n = run(302, "GET", to: "http://example.com/x")!
        expect(n.headers.value(for: "Referer") == nil)
        expect(n.crossOrigin, "スキームが違えば別オリジン")
    }
    test("POST → 301 / 302 / 303 は GET（本体と Content-Type を捨てる）") {
        for st in [301, 302, 303] {
            let n = run(st, "POST", to: "/done")!
            expectEqual(n.method, "GET", "\(st)")
            expect(n.body == nil, "\(st)")
            expect(n.headers.value(for: "Content-Type") == nil, "\(st)")
        }
        expectEqual(run(303, "PUT", to: "/x")!.method, "GET")
        expectEqual(run(303, "HEAD", to: "/x")!.method, "HEAD")
    }
    test("POST → 307 / 308 はそのまま") {
        for st in [307, 308] {
            let n = run(st, "POST", to: "/again")!
            expectEqual(n.method, "POST"); expectEqual(n.body, Data("b".utf8))
            expectEqual(n.headers.value(for: "Content-Type"), "application/json")
        }
    }
    test("HSTS で https に上げる・おかしな Location・回数の上限") {
        let n = run(302, "GET", to: "http://secure.test:80/x", hsts: { $0 == "secure.test" })!
        expectEqual(n.url.absoluteString, "https://secure.test/x"); expect(n.upgradedByHSTS)
        if case .failure(let f) = RedirectPolicy.next(from: url("https://a.test/"), method: "GET", headers: [], body: nil, status: 302,
                                                      location: "javascript:alert(1)", redirectCount: 0) {
            expectEqual(f, .unsupportedScheme("javascript"))
        } else { expect(false, "javascript: を通した") }
        if case .failure(let f) = RedirectPolicy.next(from: url("https://a.test/"), method: "GET", headers: [], body: nil, status: 302,
                                                      location: nil, redirectCount: 0) { expectEqual(f, .noLocation) } else { expect(false) }
        if case .failure(let f) = RedirectPolicy.next(from: url("https://a.test/"), method: "GET", headers: [], body: nil, status: 302,
                                                      location: "/x", redirectCount: 20) { expectEqual(f, .tooMany) } else { expect(false) }
    }
}

func corsTests() {
    print("CORSPassthrough")
    test("サーバーのヘッダだけを通す") {
        let h = CORSPassthrough.headers([("Access-Control-Allow-Origin", "https://a.test"), ("Content-Type", "x"),
                                         ("Access-Control-Allow-Credentials", "true")], vnetsMode: false)
        expectEqual(h.count, 2)
        expectEqual(h.value(for: "Access-Control-Allow-Origin"), "https://a.test")
        expect(CORSPassthrough.headers([("Content-Type", "x")], vnetsMode: false).isEmpty, "許可が無ければ何も足さない")
    }
    test("vnets:// 方式ではオリジンだけ読み替える") {
        let h = CORSPassthrough.headers([("Access-Control-Allow-Origin", "https://a.test"), ("Access-Control-Allow-Origin", "*")], vnetsMode: true)
        expectEqual(h[0].1, "vnets://a.test"); expectEqual(h[1].1, "*")
    }
}

func localNetworkTests() {
    print("LocalNetworkPolicy")
    test("アドレスの種類") {
        expectEqual(LocalNetworkPolicy.classify([192, 168, 1, 1]), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify([172, 20, 0, 1]), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify([172, 32, 0, 1]), .publicAddress)
        expectEqual(LocalNetworkPolicy.classify([10, 0, 2, 3]), .vnetInternal)
        expectEqual(LocalNetworkPolicy.classify([10, 1, 2, 3]), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify([169, 254, 1, 1]), .linkLocal)
        expectEqual(LocalNetworkPolicy.classify([127, 0, 0, 1]), .loopback)
        expectEqual(LocalNetworkPolicy.classify([100, 100, 0, 1]), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify([8, 8, 8, 8]), .publicAddress)
        expectEqual(LocalNetworkPolicy.classify(host: "[fd00::1]"), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify(host: "fe80::1"), .linkLocal)
        expectEqual(LocalNetworkPolicy.classify(host: "::1"), .loopback)
        expectEqual(LocalNetworkPolicy.classify(host: "::ffff:192.168.0.1"), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify(host: "2001:db8::1"), .publicAddress)
        expectEqual(LocalNetworkPolicy.classify(host: "printer.local"), .privateAddress)
        expectEqual(LocalNetworkPolicy.classify(host: "localhost"), .loopback)
        expect(LocalNetworkPolicy.classify(host: "example.com") == nil)
    }
    func decide(_ target: IPClass, _ ctx: RequestContext, top: IPClass?, from: IPClass?) -> LocalNetworkPolicy.Decision {
        LocalNetworkPolicy.decide(target: target, ctx: ctx, topClass: top, fromClass: from)
    }
    test("公開サイト → LAN の部品はブロック・LAN のページの部品は許可") {
        let sub = RequestContext(topURL: url("https://evil.test/"))
        if case .block = decide(.privateAddress, sub, top: .publicAddress, from: nil) {} else { expect(false) }
        expectEqual(decide(.privateAddress, sub, top: .privateAddress, from: nil), .allow)
        expectEqual(decide(.publicAddress, sub, top: .publicAddress, from: nil), .allow)
    }
    test("公開サイト → LAN へのリダイレクトはブロック") {
        var ctx = RequestContext(topURL: url("https://evil.test/"), isTopLevel: true)
        ctx.previousURL = url("https://evil.test/r")
        if case .block = decide(.privateAddress, ctx, top: .publicAddress, from: .publicAddress) {} else { expect(false, "トップレベル") }
        var sub = RequestContext(topURL: url("https://evil.test/"))
        sub.previousURL = url("https://evil.test/img")
        if case .block = decide(.privateAddress, sub, top: .publicAddress, from: .publicAddress) {} else { expect(false, "部品") }
    }
    test("DNS が LAN を返した（リバインディング）: 部品ならブロック") {
        let sub = RequestContext(topURL: url("https://evil.test/"))
        if case .block = decide(.loopback, sub, top: .publicAddress, from: nil) {} else { expect(false) }
    }
    test("ユーザーの入力は許可・ページによる移動は確認") {
        var typed = RequestContext(topURL: url("http://192.168.0.1/"), isTopLevel: true)
        typed.userInitiated = true
        expectEqual(decide(.privateAddress, typed, top: nil, from: nil), .allow)
        let byPage = RequestContext(topURL: url("http://192.168.0.1/"), isTopLevel: true, initiator: url("https://evil.test/"))
        if case .askUser = decide(.privateAddress, byPage, top: nil, from: .publicAddress) {} else { expect(false) }
        var lanToLan = byPage
        lanToLan.previousURL = url("http://router.local/")
        expectEqual(decide(.privateAddress, lanToLan, top: nil, from: .privateAddress), .allow)
    }
    test("VNet 内部のアドレスには常に接続しない") {
        var typed = RequestContext(isTopLevel: true)
        typed.userInitiated = true
        if case .block = decide(.vnetInternal, typed, top: nil, from: nil) {} else { expect(false) }
    }
}

func hstsTests() {
    print("HSTS")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let top = RequestContext(topURL: url("https://example.com/"), isTopLevel: true)
    test("値の読み取り") {
        expect(HSTSPolicy.parse("max-age=31536000; includeSubDomains")! == (31536000, true))
        expect(HSTSPolicy.parse("max-age=\"100\"")! == (100, false))
        expect(HSTSPolicy.parse("includeSubDomains") == nil)
        expect(HSTSPolicy.parse("max-age=-1") == nil)
        expect(HSTSPolicy.parse("max-age=1; max-age=2") == nil)
    }
    test("記録・サブドメイン・max-age=0 で消す") {
        let st = HSTSStore(fileURL: nil, now: now)
        st.record(header: "max-age=1000; includeSubDomains", url: url("https://Example.com/"), ctx: top, now: now)
        expect(st.shouldUpgrade("example.com", now: now))
        expect(st.shouldUpgrade("a.b.example.com", now: now))
        expect(!st.shouldUpgrade("example.com", now: now.addingTimeInterval(2000)), "期限切れ")
        st.record(header: "max-age=0", url: url("https://example.com/"), ctx: top, now: now)
        expect(!st.shouldUpgrade("example.com", now: now))
    }
    test("登録しない場合: http・サードパーティ・IP") {
        let st = HSTSStore(fileURL: nil, now: now)
        st.record(header: "max-age=1000", url: url("http://plain.test/"), ctx: RequestContext(topURL: url("http://plain.test/"), isTopLevel: true), now: now)
        st.record(header: "max-age=1000", url: url("https://tracker.test/p"), ctx: RequestContext(topURL: url("https://news.test/")), now: now)
        st.record(header: "max-age=1000", url: url("https://1.2.3.4/"), ctx: RequestContext(topURL: url("https://1.2.3.4/"), isTopLevel: true), now: now)
        st.record(header: "max-age=1000", url: url("https://cdn.news.test/x"), ctx: RequestContext(topURL: url("https://news.test/")), now: now)
        expect(!st.shouldUpgrade("plain.test", now: now))
        expect(!st.shouldUpgrade("tracker.test", now: now))
        expect(!st.shouldUpgrade("1.2.3.4", now: now))
        expect(st.shouldUpgrade("cdn.news.test", now: now), "ファーストパーティの部品は登録する")
    }
    test("保存と読み込み") {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("vela-hsts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: f) }
        let st = HSTSStore(fileURL: f, now: now)
        st.record(header: "max-age=1000", url: url("https://example.com/"), ctx: top, now: now)
        st.saveNow()
        let again = HSTSStore(fileURL: f, now: now)
        expect(again.shouldUpgrade("example.com", now: now))
        let later = HSTSStore(fileURL: f, now: now.addingTimeInterval(5000))
        expectEqual(later.all().count, 0, "期限切れは読み込み時に消す")
    }
}
