import Foundation

// MARK: - 開発者パネルの絞り込み（DevQuery）のテスト

func devQueryTests() {
    print("DevQuery")
    test("tab: 「このタブだけ」なら選ばれているタブ、でなければ nil") {
        expectEqual(DevQuery(onlyThisTab: true, query: "").tab(selected: 3), 3)
        expectEqual(DevQuery(onlyThisTab: true, query: "").tab(selected: nil), nil)
        expectEqual(DevQuery(onlyThisTab: false, query: "x").tab(selected: 3), nil)
    }
    test("matches は前の式（q.isEmpty || text.lowercased().contains(q)）と同じ") {
        let queries = ["", "a", "ABC", "Https://", " ", "クッキー", "ß", "İ"]
        let texts = ["", "abc", "xABCx", "https://Example.com/", "a b", "クッキーを送る", "STRASSE", "straße", "i̇"]
        for query in queries {
            let q = query.lowercased()
            for t in texts {
                let old = q.isEmpty || t.lowercased().contains(q)
                expectEqual(DevQuery(onlyThisTab: false, query: query).matches(t), old, "\(query) / \(t)")
            }
        }
        expect(DevQuery(onlyThisTab: false, query: "EXAMPLE").matches("https://example.com"), "大文字・小文字を見ない")
        expect(!DevQuery(onlyThisTab: false, query: "zzz").matches("abc"))
        expect(DevQuery(onlyThisTab: true, query: "").matches(""), "空なら何でも通す")
    }
}
