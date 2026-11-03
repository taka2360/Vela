import Foundation

// MARK: - ホームの設定・サイトのアイコンの選び方のテスト

func homeTests() {
    print("Home")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    test("背景の書き方: 読み書き・知らないものは「なし」") {
        expectEqual(HomeBackground(code: "photo"), .photo)
        expectEqual(HomeBackground(code: "preset:sky"), .preset("sky"))
        expectEqual(HomeBackground(code: "preset:nope"), HomeBackground.none)
        expectEqual(HomeBackground(code: ""), HomeBackground.none)
        expectEqual(HomeBackground.preset("night").code, "preset:night")
        var l = HomeLayout()
        l.background = .preset("forest")
        expectEqual(l.backgroundCode, "preset:forest")
    }
    test("home.json: 無い項目は初期値で読む") {
        let d = "{\"backgroundCode\":\"photo\"}".data(using: .utf8)!
        let l = try JSONDecoder().decode(HomeLayout.self, from: d)
        expectEqual(l.background, .photo)
        expect(l.showBookmarks && l.showTopSites)
        expectEqual(l.hiddenTopSites, [])
        let back = try JSONDecoder().decode(HomeLayout.self, from: JSONEncoder().encode(l))
        expectEqual(back, l)
    }
    test("よく見るサイトから外す") {
        var h = HistoryLog()
        for i in 0..<5 { h.record(url: URL(string: "https://a.com/")!, title: "A", at: t0 + Double(i)) }
        for i in 0..<3 { h.record(url: URL(string: "https://www.b.com/")!, title: "B", at: t0 + Double(i)) }
        h.record(url: URL(string: "https://c.com/")!, title: "C", at: t0)
        var l = HomeLayout()
        expectEqual(l.visibleTopSites(h).map { $0.title }, ["A", "B", "C"])
        l.hideTopSite("https://b.com/x")
        l.hideTopSite("https://WWW.b.com/")
        expectEqual(l.hiddenTopSites, ["b.com"])
        expectEqual(l.visibleTopSites(h).map { $0.title }, ["A", "C"])
        expectEqual(l.visibleTopSites(h, limit: 1).map { $0.title }, ["A"])
    }
    test("アイコンのキー・大きさ") {
        expectEqual(SiteIconPick.key(for: "https://WWW.Example.com/a?b"), "example.com")
        expectEqual(SiteIconPick.key(for: "about:blank"), nil)
        expectEqual(SiteIconPick.largestSize("16x16 32x32"), 32)
        expectEqual(SiteIconPick.largestSize("any"), nil)
        expectEqual(SiteIconPick.largestSize("192X192"), 192)
    }
    test("アイコンの候補: 大きいもの・apple-touch-icon を先に、SVG と LAN は外す、最後は favicon.ico") {
        let page = URL(string: "https://example.com/news/1?x=1#top")!
        let links = [
            IconLink(rel: "icon", href: "https://example.com/f16.png", sizes: "16x16", type: "image/png"),
            IconLink(rel: "icon", href: "https://example.com/logo.svg", sizes: "any", type: "image/svg+xml"),
            IconLink(rel: "icon", href: "https://cdn.example.net/f192.png", sizes: "192x192"),
            IconLink(rel: "apple-touch-icon", href: "https://example.com/touch.png"),
            IconLink(rel: "icon", href: "http://192.168.1.1/evil.png", sizes: "512x512"),
            IconLink(rel: "icon", href: "javascript:alert(1)"),
        ]
        let c = SiteIconPick.candidates(links: links, page: page).map { $0.absoluteString }
        expectEqual(c, ["https://example.com/touch.png", "https://cdn.example.net/f192.png", "https://example.com/f16.png", "https://example.com/apple-touch-icon.png"])
        expectEqual(SiteIconPick.candidates(links: [], page: page).map { $0.absoluteString },
                    ["https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico"])
        // LAN のページなら LAN のアイコンも取ってよい
        expect(SiteIconPick.isAllowed(URL(string: "http://192.168.1.1/a.png")!, page: URL(string: "http://192.168.1.1/")!))
    }
    test("<link> の JSON を読む") {
        let v = SiteIconPick.parseLinks("[{\"rel\":\"icon\",\"href\":\"https://a.com/i.png\",\"sizes\":\"\",\"type\":\"\"}]")
        expectEqual(v, [IconLink(rel: "icon", href: "https://a.com/i.png")])
        expectEqual(SiteIconPick.parseLinks("null"), [])
    }
    test("取り直すか") {
        expect(SiteIconPick.needsFetch(nil, havePageLinks: false, now: t0))
        let ok = IconRecord(fetched: t0, ok: true, fromPage: true)
        expect(!SiteIconPick.needsFetch(ok, havePageLinks: true, now: t0 + 86_400))
        expect(SiteIconPick.needsFetch(ok, havePageLinks: true, now: t0 + 15 * 86_400))
        let guessed = IconRecord(fetched: t0, ok: true, fromPage: false)
        expect(SiteIconPick.needsFetch(guessed, havePageLinks: true, now: t0 + 1))
        expect(!SiteIconPick.needsFetch(guessed, havePageLinks: false, now: t0 + 1))
        let failed = IconRecord(fetched: t0, ok: false, fromPage: true)
        expect(!SiteIconPick.needsFetch(failed, havePageLinks: true, now: t0 + 3600))
        expect(SiteIconPick.needsFetch(failed, havePageLinks: true, now: t0 + 2 * 86_400))
    }
}
