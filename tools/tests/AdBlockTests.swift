import Foundation

// MARK: - 広告ブロック（ルールの読み込み・判定・WebKit のルール）のテスト

func adBlockTests() {
    print("AdBlock")
    test("ルールを読む: 通信・隠す・読まないもの") {
        let text = """
        [Adblock Plus 2.0]
        ! Title: テスト
        ||ads.example.com^
        @@||ads.example.com/ok.js
        /banner/*$image,third-party,domain=news.com|~sub.news.com
        ||track.net^$script,important
        ##.ad-box
        example.org,~shop.example.org##div[id^="ad-"]
        example.org#@#.ad-box
        /^https?:\\/\\/re\\.gex/
        ||x.com^$redirect=noop.js
        ||y.com^$popup
        ##.foo:has-text(広告)
        example.com#?#div:-abp-has(.ad)
        example.com#$#abort-on-property-read x
        ##+js(nobab)
        """
        let p = ABPParser.parse(text)
        expectEqual(p.title, "テスト")
        expectEqual(p.network.count, 4)
        expectEqual(p.cosmetic.count, 3)
        expectEqual(p.unsupported, 6)
        // ##+js(nobab) はスクリプトレット（Scriptlets.swift）
        expectEqual(p.scriptlets.map { $0.args }, [["nobab"]])
        let r = p.network[2]
        expectEqual(r.body, "/banner/")
        expectEqual(r.types, [.image])
        expectEqual(r.thirdParty, true)
        expectEqual(r.includeDomains, ["news.com"])
        expectEqual(r.excludeDomains, ["sub.news.com"])
        expect(p.network[0].hostAnchor)
        expect(p.network[1].isException)
        expect(p.network[3].important)
        expectEqual(p.cosmetic[1].includeDomains, ["example.org"])
        expectEqual(p.cosmetic[1].excludeDomains, ["shop.example.org"])
        expect(p.cosmetic[2].isException)
    }
    test("セレクタの安全確認") {
        expect(ABPParser.isSafeSelector(".ad"))
        expect(ABPParser.isSafeSelector("a[href^=\"http://ads.\"]"))
        expect(ABPParser.isSafeSelector("div:not(.x) > .ad:nth-child(2)"))
        expect(!ABPParser.isSafeSelector(".ad:contains(x)"))
        expect(!ABPParser.isSafeSelector(".ad:-abp-has(.x)"))
        expect(!ABPParser.isSafeSelector("div[class=\"x\""))
        expect(!ABPParser.isSafeSelector(".広告"))
    }
    test("照らし合わせ: || ^ * | の印") {
        func m(_ rule: String, _ url: String) -> Bool {
            guard let r = ABPParser.parseNetwork(rule) else { return false }
            return BlockEngine(rules: [r]).match(url: URL(string: url)!, types: [.script], sourceHost: "page.com") != nil
        }
        expect(m("||ads.example.com^", "https://ads.example.com/x.js"))
        expect(m("||example.com^", "https://sub.example.com/"))
        expect(!m("||example.com^", "https://notexample.com/"))
        expect(!m("||example.com^", "https://example.com.evil.net/"))
        expect(m("||example.com^", "https://example.com"))
        expect(m("/ads/*.js", "https://x.com/ads/a/b.js?1"))
        expect(!m("/ads/*.js", "https://x.com/adsx/b.css"))
        expect(m("|https://x.com/a", "https://x.com/abc"))
        expect(!m("|https://x.com/a", "https://y.com/?u=https://x.com/a"))
        expect(m(".gif|", "https://x.com/p.gif"))
        expect(!m(".gif|", "https://x.com/p.gif?x"))
        expect(m("ad^banner", "https://x.com/ad/banner"))
        expect(m("&ad_type=", "https://x.com/?a=1&ad_type=2"))
        expect(m("-ad-$script", "https://x.com/foo-ad-bar.js"))
    }
    test("判定: 種類・third-party・domain・例外・important") {
        let rules = ABPParser.parse("""
        ||ads.com^
        @@||ads.com/allowed/
        ||img.com^$image
        ||tp.com^$third-party
        ||only.com^$domain=news.com
        ||cdn.com/x.js$important
        @@||cdn.com^
        """).network
        let e = BlockEngine(rules: rules)
        func blocked(_ u: String, _ t: Set<ResourceType> = [.script], _ src: String? = "page.com") -> Bool {
            e.match(url: URL(string: u)!, types: t, sourceHost: src) != nil
        }
        expect(blocked("https://ads.com/a.js"))
        expect(!blocked("https://ads.com/allowed/a.js"))
        expect(blocked("https://img.com/a.png", [.image]))
        expect(!blocked("https://img.com/a.js", [.script]))
        expect(blocked("https://tp.com/a.js", [.script], "page.com"))
        expect(!blocked("https://tp.com/a.js", [.script], "www.tp.com"))
        expect(blocked("https://only.com/a.js", [.script], "www.news.com"))
        expect(!blocked("https://only.com/a.js", [.script], "other.com"))
        expect(blocked("https://cdn.com/x.js"))
        expect(!blocked("https://cdn.com/y.js"))
        expectEqual(e.ruleCount, 7)
    }
    test("種類の当て推量") {
        expectEqual(BlockEngine.guessTypes(url: URL(string: "https://a.com/x.png")!, accept: "*/*", isTopLevel: false), [.image])
        expectEqual(BlockEngine.guessTypes(url: URL(string: "https://a.com/x")!, accept: "text/css,*/*;q=0.1", isTopLevel: false), [.stylesheet])
        expectEqual(BlockEngine.guessTypes(url: URL(string: "https://a.com/x")!, accept: "text/html,application/xhtml+xml", isTopLevel: false), [.subdocument])
        expectEqual(BlockEngine.guessTypes(url: URL(string: "https://a.com/")!, accept: nil, isTopLevel: true), [.document])
        expect(BlockEngine.guessTypes(url: URL(string: "https://a.com/api")!, accept: "*/*", isTopLevel: false).contains(.xhr))
    }
    test("WebKit のルール: 正しい JSON・正規表現・並び") {
        let p = ABPParser.parse("""
        ||ads.example.com^
        @@||ads.example.com/ok
        /a.b?c$image,domain=x.com|日本.jp
        ||imp.com^$important
        ##.ad
        ##.ad2
        x.com##.side-ad
        y.com#@#.ad2
        ##.gone
        #@#.gone
        """)
        let net = ContentBlockerCompiler.networkJSON(p.network)
        let arr = try? JSONSerialization.jsonObject(with: Data(net.json.utf8)) as? [[String: Any]]
        expectEqual(arr?.count, 4)
        let actions = arr?.compactMap { ($0["action"] as? [String: Any])?["type"] as? String } ?? []
        expectEqual(actions, ["block", "block", "ignore-previous-rules", "block"])
        let f0 = (arr?[0]["trigger"] as? [String: Any])?["url-filter"] as? String
        expectEqual(f0, "^[a-z][a-z0-9.+-]*://([^/?#]*\\.)?ads\\.example\\.com[^a-zA-Z0-9_.%-]")
        let t1 = arr?[1]["trigger"] as? [String: Any]
        expectEqual(t1?["url-filter"] as? String, "/a\\.b\\?c")
        expectEqual(t1?["if-domain"] as? [String], ["*x.com"])
        expectEqual(t1?["resource-type"] as? [String], ["image"])
        let rt0 = (arr?[0]["trigger"] as? [String: Any])?["resource-type"] as? [String] ?? []
        expect(!rt0.contains("document"))

        let cos = ContentBlockerCompiler.cosmeticJSON(p.cosmetic)
        let carr = try? JSONSerialization.jsonObject(with: Data(cos.json.utf8)) as? [[String: Any]]
        let sels = carr?.compactMap { ($0["action"] as? [String: Any])?["selector"] as? String } ?? []
        expect(sels.contains(".ad"))
        expect(sels.contains(".side-ad"))
        expect(!sels.joined().contains(".gone"))
        let ad2 = carr?.first { (($0["action"] as? [String: Any])?["selector"] as? String) == ".ad2" }
        expectEqual((ad2?["trigger"] as? [String: Any])?["unless-domain"] as? [String], ["*y.com"])
        expectEqual(ContentBlockerCompiler.hash("abc"), ContentBlockerCompiler.hash("abc"))
        expect(ContentBlockerCompiler.hash("abc") != ContentBlockerCompiler.hash("abd"))
    }
    test("たくさんのルールでも速い") {
        var lines: [String] = []
        for i in 0..<30_000 { lines.append("||ad\(i).example\(i % 50).com^") }
        for i in 0..<2_000 { lines.append("/banner\(i)/*") }
        let start = Date()
        let e = BlockEngine(rules: ABPParser.parse(lines.joined(separator: "\n")).network)
        let built = Date().timeIntervalSince(start)
        let t0 = Date()
        var n = 0
        for i in 0..<2_000 {
            if e.match(url: URL(string: "https://cdn\(i).site.com/static/app\(i).js?v=1")!, types: [.script], sourceHost: "site.com") != nil { n += 1 }
        }
        let per = Date().timeIntervalSince(t0) / 2_000
        expectEqual(n, 0)
        expect(e.match(url: URL(string: "https://ad77.example27.com/x")!, types: [.image], sourceHost: "site.com") != nil)
        print("    （作る \(Int(built * 1000))ms・1 件 \(String(format: "%.3f", per * 1000))ms）")
        expect(per < 0.002)
    }
}
