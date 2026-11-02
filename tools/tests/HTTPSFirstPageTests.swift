import Foundation

// MARK: - HTTPS-First の失敗ページのテスト（今の動きを書き留めたもの）
// BrowserTab.showLoadError と VNetScheme.fail は WebKit に頼るので、ここでは動かせない。
// そこで、2 か所の ErrorPage.html(...) の呼び出しをそのまま写して、同じ HTML になることを確かめる。
// nonce は毎回ちがう（UUID）ので、NONCE に置き換えてから比べる

func normalizeNonces(_ s: String) -> String {
    s.replacingOccurrences(of: "[0-9A-Fa-f]{64}", with: "NONCE", options: .regularExpression)
}

/// BrowserTab.showLoadError の HTTPS-First の分かれ道の写し（f = 開けなかった URL、ns の説明 = message）
func browserTabHTTPSFirstCopy(http: URL, f: URL, message: String, pageActions: PageActions) -> String {
    ErrorPage.html(title: "https では開けませんでした", lines: [
        "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
        "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
        detail: "\(f.absoluteString)\n\(message)",
        buttons: [ErrorPage.Button(label: "http のまま開く", nonce: pageActions.make("openHTTP", url: http), primary: false),
                  ErrorPage.Button(label: "再試行", nonce: pageActions.make("retry", url: f), primary: true)],
        kind: "httpsFirst")
}

/// VNetScheme.fail の HTTPS-First の分かれ道の写し（real = 開けなかった URL、e.description = message）
func vnetSchemeHTTPSFirstCopy(http: URL, real: URL, message: String, actions: PageActions) -> String {
    ErrorPage.html(title: "https では開けませんでした", lines: [
        "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
        "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
        detail: "\(real.absoluteString)\n\(message)",
        buttons: [ErrorPage.Button(label: "http のまま開く", nonce: actions.make("openHTTP", url: http), primary: false),
                  ErrorPage.Button(label: "再試行", nonce: actions.make("retry", url: real), primary: true)],
        kind: "httpsFirst")
}

func httpsFirstPageTests() {
    print("HTTPS-First のページ")
    let http = url("http://example.com/a?b=1")
    let https = url("https://example.com/a?b=1")

    test("2 か所の HTTPS-First の失敗ページは同じ HTML（nonce を除いて）") {
        let a1 = PageActions(), a2 = PageActions()
        let t = browserTabHTTPSFirstCopy(http: http, f: https, message: "つながりません <x>", pageActions: a1)
        let v = vnetSchemeHTTPSFirstCopy(http: http, real: https, message: "つながりません <x>", actions: a2)
        expectEqual(normalizeNonces(t), normalizeNonces(v))
        expect(t.contains("example.com は、安全な接続（https）に対応していないようです。"))
        expect(t.contains("つながりません &lt;x&gt;"))
        expect(t.hasSuffix("<!-- vela-error:httpsFirst -->"))
        expectEqual(normalizeNonces(t).components(separatedBy: "NONCE").count - 1, 2)
    }

    test("ボタンの nonce: 1 つ目が openHTTP（http の URL）、2 つ目が retry（https の URL）") {
        let a = PageActions()
        let s = browserTabHTTPSFirstCopy(http: http, f: https, message: "m", pageActions: a)
        guard let re = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{64}") else { expect(false); return }
        let ns = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
        expectEqual(ns.count, 2)
        guard ns.count == 2 else { return }
        let first = a.consume(ns[0]), second = a.consume(ns[1])
        expectEqual(first?.action, "openHTTP")
        expectEqual(first?.url, http)
        expectEqual(second?.action, "retry")
        expectEqual(second?.url, https)
    }
}
