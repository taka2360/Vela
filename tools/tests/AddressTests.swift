import Foundation

// MARK: - アドレス欄の判定のテスト

func addressTests() {
    print("AddressInput")
    func r(_ s: String) -> String? {
        switch AddressInput.resolve(s, engine: .google) {
        case .url(let u)?: return u.absoluteString
        case .search(let q, _)?: return "検索:" + q
        case nil: return nil
        }
    }
    test("URL として開くもの") {
        expectEqual(r("https://example.com/a?b=1"), "https://example.com/a?b=1")
        expectEqual(r("example.com"), "https://example.com")
        expectEqual(r("www.example.co.jp/path?q=1#x"), "https://www.example.co.jp/path?q=1#x")
        expectEqual(r("  Example.COM  "), "https://example.com")
        expectEqual(r("example.com:8443/x"), "https://example.com:8443/x")
        expectEqual(r("about:blank"), "about:blank")
        expectEqual(r("xn--eckwd4c7c.xn--zckzah"), "https://xn--eckwd4c7c.xn--zckzah")
    }
    test("LAN は http で開く") {
        expectEqual(r("192.168.1.1"), "http://192.168.1.1")
        expectEqual(r("192.168.1.1:8080/admin"), "http://192.168.1.1:8080/admin")
        expectEqual(r("localhost:3000"), "http://localhost:3000")
        expectEqual(r("printer.local"), "http://printer.local")
        expectEqual(r("[::1]:8080"), "http://[::1]:8080")
        expectEqual(r("8.8.8.8"), "https://8.8.8.8")
    }
    test("検索にするもの") {
        expectEqual(r("swift playgrounds"), "検索:swift playgrounds")
        expectEqual(r("天気"), "検索:天気")
        expectEqual(r("hello"), "検索:hello")
        expectEqual(r("1.5"), "検索:1.5")
        expectEqual(r("example.c"), "検索:example.c")
        expectEqual(r("foo:bar"), "検索:foo:bar")
        expect(r("   ") == nil)
    }
    test("検索の URL（+ や & を壊さない）") {
        let u = SearchEngine.google.searchURL("c++ & swift")!.absoluteString
        expect(u.hasPrefix("https://www.google.com/search?q="))
        expect(u.contains("c%2B%2B"), u)
        expect(!u.contains("& "), u)
        expectEqual(AddressInput.searchTerms(in: SearchEngine.google.searchURL("c++ & swift")), "c++ & swift")
        expectEqual(AddressInput.searchTerms(in: SearchEngine.yahooJapan.searchURL("天気")), "天気")
        expect(AddressInput.searchTerms(in: url("https://example.com/search?q=x")) == nil)
    }
    test("短い表示") {
        expectEqual(AddressInput.shortDisplay(url("https://www.example.com/a/b")), "example.com")
        expectEqual(AddressInput.shortDisplay(url("about:blank")), "")
        expectEqual(AddressInput.shortDisplay(nil), "")
    }
}
