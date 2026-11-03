import Foundation

// MARK: - 送る要求のバイトを作る（HTTPPool から分けたもの。状態を持たない）
//
// ヘッダは自分で決めるもの（Host・Connection・Accept-Encoding など）を決め直し、Safari と同じ順番に並べる。
// Cookie ヘッダの値は HTTPPool が CookieJar から作って渡す（送らなかった Cookie のログも HTTPPool が書く）

enum HTTPRequestBytes {
    /// こちらで決め直すので、ブラウザから来ても送らないヘッダ
    static let ownHeaders: Set<String> = ["host", "connection", "accept-encoding", "content-length", "user-agent",
                                                  "cookie", "keep-alive", "proxy-connection", "te", "upgrade"]

    /// ヘッダを送る順番（Safari に合わせる）。ここに無い名前は "content-type" の所に、来た順で入れる
    /// （ブラウザから来るヘッダは辞書なので順番がばらばら。毎回順番が変わると、ロボットだと思われやすい）
    static let headerOrder: [String] = ["host", "origin", "content-type", "accept", "sec-fetch-site", "sec-fetch-dest",
                                                "accept-language", "sec-fetch-mode", "user-agent", "upgrade-insecure-requests",
                                                "referer", "range", "if-none-match", "if-modified-since", "content-length",
                                                "accept-encoding", "cookie", "priority", "connection"]

    /// 1 つの要求のバイト（要求の行・ヘッダ・中身）。cookie は送る Cookie ヘッダの値（無ければ nil）。副作用は無い
    static func build(_ req: HTTPRequest, host: String, userAgent: String, cookie: String?) -> Data {
        let comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? "/"
        if path.isEmpty { path = "/" }
        if let q = comps?.percentEncodedQuery { path += "?" + q }
        var h: [(String, String)] = [("Host", req.url.port.map { "\(host):\($0)" } ?? host)]
        h += req.headers.filter { !ownHeaders.contains($0.0.lowercased()) }
        if h.value(for: "Accept") == nil { h.append(("Accept", "*/*")) }
        if h.value(for: "Accept-Language") == nil { h.append(("Accept-Language", BrowserIdentity.acceptLanguage)) }
        // User-Agent はブラウザ（WebKit）が付けてきたものを使う（ページの JavaScript から見える navigator.userAgent と同じにする）
        h.append(("User-Agent", req.headers.value(for: "User-Agent") ?? userAgent))
        // 途中から読む（Range。動画など）ときは縮めてもらわない。縮めると「何バイト目」がずれる
        h.append(("Accept-Encoding", req.headers.value(for: "Range") == nil ? ContentDecoding.acceptEncoding : "identity"))
        if let cookie { h.append(("Cookie", cookie)) }
        if let b = req.body { h.append(("Content-Length", String(b.count))) }
        else if req.method == "POST" || req.method == "PUT" || req.method == "PATCH" { h.append(("Content-Length", "0")) }
        h.append(("Connection", "keep-alive"))
        let order = headerOrder
        let other = order.firstIndex(of: "content-type") ?? 0
        let rank = { (name: String) -> Int in order.firstIndex(of: name.lowercased()) ?? other }
        let sorted = h.enumerated().sorted { a, b in
            let ra = rank(a.element.0), rb = rank(b.element.0)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        var s = "\(req.method) \(path) HTTP/1.1\r\n"
        for (_, kv) in sorted { s += "\(kv.0): \(kv.1)\r\n" }
        s += "\r\n"
        var d = Data(s.utf8)
        if let b = req.body { d.append(b) }
        return d
    }
}
