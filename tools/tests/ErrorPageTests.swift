import Foundation

// MARK: - エラーページ・ボタンの合言葉のテスト

func errorPageTests() {
    print("ErrorPage・PageActions")
    test("合言葉は 1 回だけ・期限あり・知らないものは受け付けない") {
        let a = PageActions()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let n = a.make("retry", url: url("https://example.com/"), now: now)
        expect(n.count >= 64, "推測できない長さ")
        expect(a.consume("bogus", now: now) == nil)
        expectEqual(a.consume(n, now: now)?.action, "retry")
        expect(a.consume(n, now: now) == nil, "2 回目は使えない")
        let old = a.make("openNative", url: url("https://example.com/"), now: now)
        expect(a.consume(old, now: now.addingTimeInterval(PageActions.lifetime + 1)) == nil, "期限切れ")
    }
    test("HTML の文字はエスケープする（URL やエラーの文に記号が入っても壊れない）") {
        let h = ErrorPage.html(title: "<b>x</b>", lines: ["a\"b'c&d", "https://e.test/?q=<script>"], detail: "</p><img src=x>",
                               buttons: [ErrorPage.Button(label: "再試行", nonce: "abc", primary: true)], kind: "dns")
        expect(!h.contains("<script>"), h)
        expect(!h.contains("<b>x"), h)
        expect(!h.contains("<img"), h)
        expect(h.contains("&lt;script&gt;"))
        expect(h.contains("nonce:&#39;abc&#39;"), "ボタンの合言葉")
        expect(h.contains("vela-error:dns"))
    }
    test("失敗の種類ごとの説明") {
        expect(ErrorPage.describe(FetchError("x", kind: .tlsVersion)).offerNative)
        expect(!ErrorPage.describe(FetchError("x", kind: .blocked)).offerNative, "守りで止めたものは標準の通信を勧めない")
        expect(!ErrorPage.describe(FetchError("x", kind: .localNetworkConsent)).offerNative)
        let off = ErrorPage.describe(nsErrorCode: NSURLErrorNotConnectedToInternet, domain: NSURLErrorDomain, message: "m")
        expectEqual(off.title, "インターネットにつながっていません")
    }
}
