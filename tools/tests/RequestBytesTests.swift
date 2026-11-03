import Foundation

// MARK: - 送る要求のバイト（ヘッダの順番・外すもの・既定の値）のテスト（今の動きを書き留めたもの）
// 偽のサーバー（FakeNet）に届いた要求を見る。Linux には Compression が無いので、Accept-Encoding はいつも identity

func requestBytesTests(_ m: VNetMachine, _ net: FakeNet) {
    print("送る要求のヘッダ")
    func last(_ path: String) -> FakeRequest? { net.received.last { $0.path == path } }
    func names(_ r: FakeRequest?) -> [String] { r?.headers.map { $0.0 } ?? [] }

    test("ヘッダの順番（知らない名前は content-type の所に来た順・外すものは外す・既定の値）") {
        var req = HTTPRequest(url: url("http://site.test/order"))
        req.headers = [("X-Custom", "1"), ("Referer", "http://site.test/"), ("accept", "text/html"), ("Host", "evil.test"),
                       ("Connection", "close"), ("Sec-Fetch-Site", "none"), ("X-Other", "2"), ("TE", "trailers"),
                       ("Upgrade", "h2c"), ("Keep-Alive", "1"), ("Content-Length", "99")]
        _ = fetch(m, req)
        let r = last("/order")
        expectEqual(names(r), ["Host", "X-Custom", "X-Other", "accept", "Sec-Fetch-Site", "Accept-Language", "User-Agent",
                               "Referer", "Accept-Encoding", "Cookie", "Connection"])   // Cookie は前のテストで入った CookieJar から
        expectEqual(r?.headers.value(for: "Host"), "site.test", "Host は自分で決める")
        expectEqual(r?.headers.value(for: "Connection"), "keep-alive")
        expectEqual(r?.headers.value(for: "accept"), "text/html", "来た Accept はそのまま")
        expectEqual(r?.headers.value(for: "Accept-Language"), BrowserIdentity.acceptLanguage)
        expectEqual(r?.headers.value(for: "Accept-Encoding"), ContentDecoding.acceptEncoding)
        expect(r?.headers.value(for: "Content-Length") == nil, "GET で中身が無いので付けない（来たものは外す）")
    }
    test("Accept の既定値・User-Agent は来たものを優先・Range のときは identity") {
        var req = HTTPRequest(url: url("http://site.test/ua"))
        req.headers = [("User-Agent", "Mine/1.0"), ("Range", "bytes=0-9")]
        _ = fetch(m, req)
        let r = last("/ua")
        expectEqual(r?.headers.value(for: "Accept"), "*/*")
        expectEqual(r?.headers.value(for: "User-Agent"), "Mine/1.0")
        expectEqual(r?.headers.value(for: "Accept-Encoding"), "identity")
        expectEqual(names(r), ["Host", "Accept", "Accept-Language", "User-Agent", "Range", "Accept-Encoding", "Cookie", "Connection"])
    }
    test("Content-Length: POST・PUT・PATCH で中身が無いときは 0、ほかは付けない（大文字だけ見る）") {
        for (method, want) in [("POST", "0"), ("PUT", "0"), ("PATCH", "0"), ("DELETE", nil), ("post", nil)] as [(String, String?)] {
            var req = HTTPRequest(url: url("http://site.test/cl-\(method)"))
            req.method = method
            _ = fetch(m, req)
            expectEqual(last("/cl-\(method)")?.headers.value(for: "Content-Length"), want, method)
            expectEqual(last("/cl-\(method)")?.method, method)
        }
        var withBody = HTTPRequest(url: url("http://site.test/cl-body"))
        withBody.method = "POST"; withBody.body = Data("abc".utf8)
        _ = fetch(m, withBody)
        expectEqual(last("/cl-body")?.headers.value(for: "Content-Length"), "3")
    }
    test("WebKit から来た Cookie は空のものを外して \"; \" でつなぐ") {
        var req = HTTPRequest(url: url("http://site.test/ck"))
        req.headers = [("Cookie", "a=1"), ("Cookie", ""), ("cookie", "b=2")]
        _ = fetch(m, req)
        expectEqual(last("/ck")?.headers.value(for: "Cookie"), "a=1; b=2")
        expectEqual(last("/ck")?.headers.filter { $0.0.lowercased() == "cookie" }.count, 1)
    }
    test("Host にポートを付けるのは、URL に書いたときだけ（:80・:443 も）") {
        _ = fetch(m, HTTPRequest(url: url("http://site.test:80/p80")))
        expectEqual(last("/p80")?.headers.value(for: "Host"), "site.test:80")
        _ = fetch(m, HTTPRequest(url: url("http://site.test:443/p443")))
        expectEqual(last("/p443")?.headers.value(for: "Host"), "site.test:443")
        _ = fetch(m, HTTPRequest(url: url("http://SITE.test/upper")))
        expectEqual(last("/upper")?.headers.value(for: "Host"), "site.test", "小文字にそろえる")
    }
    test("パスとクエリは % のまま（空のパスは /）") {
        _ = fetch(m, HTTPRequest(url: url("http://site.test/a%20b?x=1&y=%2F")))
        expect(net.received.contains { $0.path == "/a%20b?x=1&y=%2F" })
        _ = fetch(m, HTTPRequest(url: url("http://site.test")))
        expect(net.received.last?.path == "/", "空のパス")
    }
}
