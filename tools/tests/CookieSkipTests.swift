import Foundation

// MARK: - Cookie を送らない理由のテスト（今の動きを書き留めたもの）
// 確かめる順番: 扱わない要求 → 期限切れ → ドメイン → パス → Secure → サードパーティ → SameSite（Strict・Lax・なし）

func cookieSkipTests() {
    print("Cookie を送らない理由")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let noBlock: CookiePolicy.Settings = { var s = CookiePolicy.Settings(); s.blockThirdParty = false; return s }()
    let block = CookiePolicy.Settings()

    func rec(path: String = "/", secure: Bool = false, sameSite: CookieRecord.SameSite = .unspecified, expired: Bool = false) -> CookieRecord {
        var c = CookieRecord(name: "c", value: "v", domain: "example.com", hostOnly: false, path: path, secure: secure,
                             sameSite: sameSite, created: now.addingTimeInterval(-3600))
        if expired { c.expires = now.addingTimeInterval(-1) }
        return c
    }
    let sameTop = RequestContext(topURL: url("https://example.com/"), isTopLevel: true, initiator: url("https://example.com/"))
    let crossSub = RequestContext(topURL: url("https://evil.test/"))           // 別のサイトのページの中の部品（サードパーティ・クロスサイト）
    let notAllowed: RequestContext = { var c = RequestContext(topURL: url("https://example.com/")); c.cookiesAllowed = false; return c }()
    let crossNav = RequestContext(topURL: url("https://example.com/"), isTopLevel: true, initiator: url("https://evil.test/"))

    func why(_ c: CookieRecord, _ u: String, _ ctx: RequestContext, _ st: CookiePolicy.Settings = CookiePolicy.Settings(), method: String = "GET") -> String? {
        CookiePolicy.sendDecision(c, url: url(u), method: method, ctx: ctx, settings: st, now: now)
    }
    func logged(_ c: CookieRecord, _ u: String, _ ctx: RequestContext, _ st: CookiePolicy.Settings = CookiePolicy.Settings()) -> [String] {
        CookiePolicy.cookiesToSend([c], url: url(u), method: "GET", ctx: ctx, settings: st, now: now).skipped.map { $0.1 }
    }

    test("理由ごとの文言とログに出るか（9 種類）") {
        let cases: [(String, CookieRecord, String, RequestContext, CookiePolicy.Settings, Bool)] = [
            ("Cookie を扱わない要求", rec(), "https://example.com/", notAllowed, block, true),
            ("期限切れ", rec(expired: true), "https://example.com/", sameTop, block, false),
            ("ドメインが合わない", rec(), "https://other.test/", sameTop, block, false),
            ("パスが合わない", rec(path: "/app"), "https://example.com/x", sameTop, block, false),
            ("Secure なのに https でない", rec(secure: true), "http://example.com/", sameTop, block, true),
            ("サードパーティ Cookie をブロック", rec(), "https://example.com/", crossSub, block, true),
            ("SameSite=Strict でクロスサイト", rec(sameSite: .strict), "https://example.com/", crossSub, noBlock, true),
            ("SameSite=Lax でクロスサイト", rec(sameSite: .lax), "https://example.com/", crossSub, noBlock, true),
            ("SameSite なし（Lax 扱い）でクロスサイト", rec(), "https://example.com/", crossSub, noBlock, true),
        ]
        for (text, c, u, ctx, st, isLogged) in cases {
            expectEqual(why(c, u, ctx, st), text)
            expectEqual(logged(c, u, ctx, st), isLogged ? [text] : [], "ログ: \(text)")
        }
    }
    test("SendSkip: 9 種類・文言・isLogged") {
        expectEqual(CookiePolicy.SendSkip.allCases.count, 9)
        expectEqual(CookiePolicy.SendSkip.allCases.filter { !$0.isLogged }, [.expired, .domain, .path])
        expectEqual(Set(CookiePolicy.SendSkip.allCases.map { $0.text }).count, 9, "文言は全部違う")
    }
    test("理由が重なったら先の方（順番で隣り合う 8 組）") {
        expectEqual(why(rec(expired: true), "https://example.com/", notAllowed), "Cookie を扱わない要求")
        expectEqual(why(rec(expired: true), "https://other.test/", sameTop), "期限切れ")
        expectEqual(why(rec(path: "/app"), "https://other.test/x", sameTop), "ドメインが合わない")
        expectEqual(why(rec(path: "/app", secure: true), "http://example.com/x", sameTop), "パスが合わない")
        expectEqual(why(rec(secure: true), "http://example.com/", crossSub, block), "Secure なのに https でない")
        expectEqual(why(rec(sameSite: .strict), "https://example.com/", crossSub, block), "サードパーティ Cookie をブロック")
        expectEqual(why(rec(sameSite: .lax), "https://example.com/", crossSub, block), "サードパーティ Cookie をブロック")
        expectEqual(why(rec(), "https://example.com/", crossSub, block), "サードパーティ Cookie をブロック")
    }
    test("そのほかの組・送るもの") {
        for c in [rec(secure: true), rec(sameSite: .strict)] {
            expectEqual(why(c, "http://example.com/", notAllowed), "Cookie を扱わない要求")
        }
        var thirdNoCookies = crossSub
        thirdNoCookies.cookiesAllowed = false
        expectEqual(why(rec(), "https://example.com/", thirdNoCookies, block), "Cookie を扱わない要求", "サードパーティより先")
        expectEqual(why(rec(secure: true, expired: true), "http://example.com/", sameTop), "期限切れ")
        expectEqual(logged(rec(secure: true, expired: true), "http://example.com/", sameTop), [], "期限切れはログに出ない")
        expect(why(rec(sameSite: .none), "https://example.com/", crossSub, noBlock) == nil, "None はクロスサイトでも送る")
        expect(why(rec(sameSite: .lax), "https://example.com/", crossNav) == nil, "Lax はトップレベルの GET なら送る")
        expectEqual(why(rec(sameSite: .lax), "https://example.com/", crossNav, method: "POST"), "SameSite=Lax でクロスサイト")
        expect(why(rec(), "https://example.com/", sameTop) == nil, "同じサイトのトップレベルは送る")
    }
}
