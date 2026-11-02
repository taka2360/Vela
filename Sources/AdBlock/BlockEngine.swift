import Foundation

// MARK: - 広告ブロックの判定（VNet のタブの通信を 1 つずつ調べる）
//
// ルールが何万もあるので、全部を毎回調べない。ルールごとに「必ず URL に入っている言葉」（英数字の並び）を 1 つ選んで索引にし、
// URL に入っている言葉の索引だけを調べる（言葉を選べないルールは毎回調べる）。
// 当てはめは正規表現を使わず、* と ^ だけの簡単な照らし合わせ（速い）。
// 作った後は変えないので、どのスレッドから使ってもよい

final class BlockEngine: @unchecked Sendable {
    struct Decision: Equatable {
        /// 当たったブロックのルール（元の行）
        let rule: String
    }

    private struct Compiled {
        let rule: NetworkRule
        let body: [UInt8]
    }

    private var blocks: [Compiled] = []
    private var exceptions: [Compiled] = []
    private var important: [Compiled] = []
    /// 言葉 → ルールの番号（種類ごと）
    private var blockIndex: [String: [Int]] = [:]
    private var exceptionIndex: [String: [Int]] = [:]
    private var importantIndex: [String: [Int]] = [:]
    private var blockGeneric: [Int] = []
    private var exceptionGeneric: [Int] = []
    private var importantGeneric: [Int] = []

    private(set) var ruleCount = 0

    init(rules: [NetworkRule] = []) {
        // 言葉は「ルールの中で一番珍しいもの」を選ぶ（"ads" などに何千ものルールが集まると、毎回たくさん調べることになる）
        let candidates = rules.map { BlockEngine.candidateTokens($0) }
        var freq: [String: Int] = [:]
        for c in candidates { for t in c { freq[t, default: 0] += 1 } }
        for (r, c) in zip(rules, candidates) {
            let token = c.min { a, b in
                let fa = freq[a] ?? 0, fb = freq[b] ?? 0
                return fa != fb ? fa < fb : a.count > b.count
            }
            add(r, token: token)
        }
    }

    /// 調べたときの数（開発者向け）: (言葉の種類, 言葉を選べなかったルール)
    var indexStats: (tokens: Int, generic: Int) {
        (blockIndex.count + exceptionIndex.count + importantIndex.count, blockGeneric.count + exceptionGeneric.count + importantGeneric.count)
    }

    static let empty = BlockEngine()

    private func add(_ r: NetworkRule, token: String?) {
        // document だけのルール（ページそのものを止める）は VNet では使わない（ページ本体は止めない）
        if let t = r.types, t == [.document] { return }
        let c = Compiled(rule: r, body: Array(r.body.utf8))
        if r.isException {
            exceptions.append(c)
            BlockEngine.insert(token, exceptions.count - 1, &exceptionIndex, &exceptionGeneric)
        } else if r.important {
            important.append(c)
            BlockEngine.insert(token, important.count - 1, &importantIndex, &importantGeneric)
        } else {
            blocks.append(c)
            BlockEngine.insert(token, blocks.count - 1, &blockIndex, &blockGeneric)
        }
        ruleCount += 1
    }

    private static func insert(_ token: String?, _ i: Int, _ index: inout [String: [Int]], _ generic: inout [Int]) {
        if let token { index[token, default: []].append(i) } else { generic.append(i) }
    }

    /// 言葉として使わないもの（ほとんどの URL に入っている）
    private static let commonTokens: Set<String> = ["http", "https", "www", "com", "net", "org", "html", "js", "jpg", "png", "gif"]

    /// 必ず URL に丸ごと入っている英数字の並びのうち、一番長いもの
    static func bestToken(_ r: NetworkRule) -> String? {
        candidateTokens(r).max { $0.count < $1.count }
    }

    /// 必ず URL に丸ごと入っている英数字の並び（索引に使えるもの）
    static func candidateTokens(_ r: NetworkRule) -> [String] {
        let b = Array(r.body.lowercased().utf8)
        var out: [String] = []
        var i = 0
        while i < b.count {
            guard isAlnum(b[i]) else { i += 1; continue }
            var j = i
            while j < b.count && isAlnum(b[j]) { j += 1 }
            // 前後が「*」や本体の端（印の無い端）だと、URL の中ではもっと長い並びの一部かもしれない
            let leftOK = i > 0 ? b[i - 1] != UInt8(ascii: "*") : (r.hostAnchor || r.startAnchor)
            let rightOK = j < b.count ? b[j] != UInt8(ascii: "*") : r.endAnchor
            if leftOK && rightOK && j - i >= 2 {
                let t = String(decoding: b[i..<j], as: UTF8.self)
                if !commonTokens.contains(t) { out.append(t) }
            }
            i = j
        }
        return out
    }

    @inline(__always) static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    /// 「^」に当たる文字（英数字と _ - . % 以外）
    @inline(__always) static func isSeparator(_ c: UInt8) -> Bool {
        !(isAlnum(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "%"))
    }

    /// 調べる。止めるなら、当たったルール
    /// - types: 読み込みの種類（はっきりしないときは、ありそうなもの全部）
    /// - sourceHost: その読み込みをしたページのホスト（domain= と third-party の判定）
    func match(url: URL, types: Set<ResourceType>, sourceHost: String?) -> Decision? {
        let s = url.absoluteString
        let lower = Array(s.lowercased().utf8)
        let original = Array(s.utf8)
        guard let hostRange = BlockEngine.hostRange(lower) else { return nil }
        let host = String(decoding: lower[hostRange], as: UTF8.self)
        let thirdParty: Bool? = sourceHost.map { SiteUtil.registrableDomain($0.lowercased()) != SiteUtil.registrableDomain(host) }
        let tokens = BlockEngine.tokens(lower)
        let req = Request(lower: lower, original: original, host: hostRange, types: types,
                          source: sourceHost?.lowercased(), thirdParty: thirdParty)
        if let i = find(important, importantIndex, importantGeneric, tokens, req) { return Decision(rule: important[i].rule.text) }
        guard let i = find(blocks, blockIndex, blockGeneric, tokens, req) else { return nil }
        if find(exceptions, exceptionIndex, exceptionGeneric, tokens, req) != nil { return nil }
        return Decision(rule: blocks[i].rule.text)
    }

    private struct Request {
        let lower: [UInt8]
        let original: [UInt8]
        let host: Range<Int>
        let types: Set<ResourceType>
        let source: String?
        let thirdParty: Bool?
    }

    private func find(_ list: [Compiled], _ index: [String: [Int]], _ generic: [Int], _ tokens: [String], _ req: Request) -> Int? {
        for t in tokens {
            if let ids = index[t] { for i in ids where BlockEngine.matches(list[i], req) { return i } }
        }
        for i in generic where BlockEngine.matches(list[i], req) { return i }
        return nil
    }

    private static func matches(_ c: Compiled, _ req: Request) -> Bool {
        let r = c.rule
        if let t = r.types, t.isDisjoint(with: req.types) { return false }
        if let tp = r.thirdParty {
            guard let actual = req.thirdParty, actual == tp else { return false }
        }
        if !r.includeDomains.isEmpty || !r.excludeDomains.isEmpty {
            guard let src = req.source else { return false }
            if r.excludeDomains.contains(where: { domainMatches(src, $0) }) { return false }
            if !r.includeDomains.isEmpty && !r.includeDomains.contains(where: { domainMatches(src, $0) }) { return false }
        }
        if c.body.isEmpty { return true }
        return patternMatches(c.body, in: r.matchCase ? req.original : req.lower, host: req.host,
                              hostAnchor: r.hostAnchor, startAnchor: r.startAnchor, endAnchor: r.endAnchor)
    }

    static func domainMatches(_ host: String, _ d: String) -> Bool {
        host == d || host.hasSuffix("." + d)
    }

    /// URL のホストの位置（"scheme://" の後から、/ ? # : の前まで）
    static func hostRange(_ u: [UInt8]) -> Range<Int>? {
        var i = 0
        while i + 2 < u.count, !(u[i] == UInt8(ascii: ":") && u[i + 1] == UInt8(ascii: "/") && u[i + 2] == UInt8(ascii: "/")) { i += 1 }
        guard i + 2 < u.count else { return nil }
        let start = i + 3
        var end = start
        while end < u.count, ![UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: ":")].contains(u[end]) { end += 1 }
        return start < end ? start..<end : nil
    }

    static func tokens(_ u: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < u.count {
            guard isAlnum(u[i]) else { i += 1; continue }
            var j = i
            while j < u.count && isAlnum(u[j]) { j += 1 }
            if j - i >= 2 { out.append(String(decoding: u[i..<j], as: UTF8.self)) }
            i = j
        }
        return out
    }

    /// * と ^ の入った本体を、URL に当てはめる
    static func patternMatches(_ p: [UInt8], in u: [UInt8], host: Range<Int>, hostAnchor: Bool, startAnchor: Bool, endAnchor: Bool) -> Bool {
        // 「*」で区切る
        var segments: [ArraySlice<UInt8>] = []
        var s = 0
        for (i, c) in p.enumerated() where c == UInt8(ascii: "*") {
            if i > s { segments.append(p[s..<i]) }
            s = i + 1
        }
        if s < p.count { segments.append(p[s..<p.count]) }
        if segments.isEmpty { return true }

        func matchAt(_ seg: ArraySlice<UInt8>, _ pos: Int) -> Int? {
            var k = pos
            for c in seg {
                if c == UInt8(ascii: "^") {
                    if k == u.count { continue }       // 終わりにも当たる
                    if !isSeparator(u[k]) { return nil }
                } else {
                    if k >= u.count || u[k] != c { return nil }
                }
                k += 1
            }
            return min(k, u.count)
        }
        func search(_ seg: ArraySlice<UInt8>, from: Int) -> (Int, Int)? {
            var i = from
            while i <= u.count {
                if let e = matchAt(seg, i) { return (i, e) }
                i += 1
            }
            return nil
        }
        func rest(_ from: Int, _ idx: Int) -> Bool {
            var pos = from
            for k in idx..<segments.count {
                if k == segments.count - 1 && endAnchor {
                    // 最後の区切りは URL の終わりで終わらなければならない
                    var i = pos
                    while i <= u.count {
                        if let e = matchAt(segments[k], i), e == u.count { return true }
                        i += 1
                    }
                    return false
                }
                guard let (_, e) = search(segments[k], from: pos) else { return false }
                pos = e
            }
            return true
        }

        var starts: [Int] = []
        if hostAnchor {
            // ホストの始め、またはホストの中の「.」の後
            starts.append(host.lowerBound)
            for i in host where u[i] == UInt8(ascii: ".") { starts.append(i + 1) }
        } else if startAnchor {
            starts.append(0)
        } else {
            if segments.count == 1 && !endAnchor { return search(segments[0], from: 0) != nil }
            // 最初の区切りが当たる所を順に試す
            var i = 0
            while let (st, e) = search(segments[0], from: i) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
                i = st + 1
            }
            return false
        }
        for st in starts {
            if let e = matchAt(segments[0], st) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
            }
        }
        return false
    }

    /// VNet が受けた要求の種類を当てる（WebKit は種類を教えてくれないので、Accept と拡張子から）
    static func guessTypes(url: URL, accept: String?, isTopLevel: Bool) -> Set<ResourceType> {
        if isTopLevel { return [.document] }
        let a = (accept ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        if a.hasPrefix("text/html") || a.hasPrefix("application/xhtml") { return [.subdocument] }
        if a.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp"].contains(ext) { return [.image] }
        if a.hasPrefix("text/css") || ext == "css" { return [.stylesheet] }
        if ["woff", "woff2", "ttf", "otf", "eot"].contains(ext) || a.hasPrefix("font/") { return [.font] }
        if ["mp4", "webm", "m3u8", "ts", "mp3", "m4a", "aac", "ogg", "mov"].contains(ext) || a.hasPrefix("video/") || a.hasPrefix("audio/") { return [.media] }
        if ext == "js" || ext == "mjs" { return [.script] }
        // 分からない: スクリプトか、fetch / XHR か、その他
        return [.script, .xhr, .other, .ping]
    }
}
