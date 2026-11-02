import Foundation

// 通信の決まりの部品（NetPolicy.swift の続き）。ホスト名の正規化・サイト・オリジン・IP アドレスの文字の読み取り

// MARK: - サイト・オリジン

enum SiteUtil {
    /// ホスト名をそろえる（小文字・末尾の「.」を外す・IPv6 の [ ] を外す）。
    /// IDN（日本語ドメインなど）は、WebKit から届く URL の時点で punycode（xn--…）になっているので、ここでは変換しない
    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func host(of url: URL) -> String? {
        guard let h = url.host, !h.isEmpty else { return nil }
        return normalizeHost(h)
    }

    /// host が domain そのもの、またはその下（a.domain）か。小文字にはしない（呼ぶ側でそろえる）
    static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// 先頭の「www.」を 1 回だけ外す。小文字にはしない（呼ぶ側でそろえる）
    static func stripWWW(_ s: String) -> String {
        s.hasPrefix("www.") ? String(s.dropFirst(4)) : s
    }

    /// IPv4 か IPv6 の数字のアドレスか
    static func isIPLiteral(_ host: String) -> Bool {
        let h = normalizeHost(host)
        return IPAddressText.v4(h) != nil || h.contains(":")
    }

    /// 2 段以上の「公開の末尾」（Public Suffix List の、よく使う所だけ）。ここに無いものは最後の 1 段を末尾とみなす
    static let multiLevelSuffixes: Set<String> = [
        // 日本
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "lg.jp", "gr.jp", "ad.jp",
        "tokyo.jp", "osaka.jp", "kyoto.jp", "aichi.jp", "kanagawa.jp", "hokkaido.jp", "fukuoka.jp", "saitama.jp", "chiba.jp", "hyogo.jp",
        // ほかの国
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.sg", "edu.sg", "gov.sg", "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "co.id", "or.id", "ac.id", "go.id", "co.th", "or.th", "ac.th", "go.th", "in.th",
        "com.my", "com.mx", "com.ar", "co.za", "com.tr", "com.vn", "com.ph", "com.ua", "co.il",
        // 誰でも下にサイトを作れる所（別のサイトとして扱う）
        "github.io", "githubusercontent.com", "blogspot.com", "herokuapp.com", "netlify.app", "vercel.app",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net",
        "appspot.com", "glitch.me", "gitlab.io", "s3.amazonaws.com", "fly.dev", "onrender.com", "repl.co",
    ]

    /// 公開の末尾そのものか（例: "jp"・"co.jp"・"github.io"）。Cookie の Domain に使えない
    static func isPublicSuffix(_ domain: String) -> Bool {
        let d = normalizeHost(domain)
        if d.isEmpty { return true }
        if !d.contains(".") { return !isIPLiteral(d) && d != "localhost" }
        return multiLevelSuffixes.contains(d)
    }

    /// 「登録できるドメイン」（サイトの単位）。www.example.co.jp → example.co.jp、a.b.example.com → example.com
    static func registrableDomain(_ host: String) -> String {
        let h = normalizeHost(host)
        if isIPLiteral(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count <= 2 {
            // "co.jp" のように末尾そのもの・"example.com"・"localhost"
            return h
        }
        // 長い末尾から順に見る（"s3.amazonaws.com" のような 3 段もある）
        for n in stride(from: min(3, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if multiLevelSuffixes.contains(suffix) { return labels.suffix(n + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// 同じサイトか（スキームは見ない。WebKit の「サードパーティ」の考え方と同じ）
    static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let ha = host(of: a), let hb = host(of: b) else { return false }
        return registrableDomain(ha) == registrableDomain(hb)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https", "wss", "vnets": return 443
        case "http", "ws", "vnet": return 80
        default: return nil
        }
    }

    /// オリジン（"https://example.com" ・ 既定でないポートなら ":8443" も付ける）
    static func origin(of url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), let h = host(of: url) else { return nil }
        let hostText = h.contains(":") ? "[\(h)]" : h
        if let p = url.port, p != defaultPort(s) { return "\(s)://\(hostText):\(p)" }
        return "\(s)://\(hostText)"
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        return oa == ob
    }

    static func isSecureScheme(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        return s == "https" || s == "wss" || s == "vnets"
    }
}

/// 数字のアドレスを読む
enum IPAddressText {
    /// "192.168.0.1" → [192, 168, 0, 1]
    static func v4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// IPv6 を 8 個の 16 ビットにする（"::" の省略・末尾の IPv4 表記・"%zone" に対応）
    static func v6(_ text: String) -> [UInt16]? {
        var s = SiteUtil.normalizeHost(text)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard s.contains(":") else { return nil }
        var tail4: [UInt16] = []
        if let lastColon = s.lastIndex(of: ":"), let v4 = v4(String(s[s.index(after: lastColon)...])) {
            tail4 = [UInt16(v4[0]) << 8 | UInt16(v4[1]), UInt16(v4[2]) << 8 | UInt16(v4[3])]
            s = String(s[...lastColon]) + "0:0"   // IPv4 の分（16 ビット 2 個）を形だけ置いておき、あとで差し替える
        }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ t: String) -> [UInt16]? {
            if t.isEmpty { return [] }
            var g: [UInt16] = []
            for p in t.split(separator: ":", omittingEmptySubsequences: false) {
                guard !p.isEmpty, p.count <= 4, let v = UInt16(p, radix: 16) else { return nil }
                g.append(v)
            }
            return g
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let back = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - back.count
            guard fill >= 1 else { return nil }
            all = head + Array(repeating: 0, count: fill) + back
        } else {
            all = head
        }
        guard all.count == 8 else { return nil }
        if !tail4.isEmpty { all.removeLast(); all.removeLast(); all += tail4 }
        return all
    }
}
