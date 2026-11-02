// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 5 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - ABPFilter.swift
// ======================================================================

// MARK: - 広告ブロックのルール（Adblock Plus の書き方）を読む
//
// EasyList・EasyPrivacy・AdGuard Japanese などの 1 行ずつのルールを、通信のルールと、要素を隠すルールに分ける。
// 対応するもの:
//   通信: ||host^ ・ |先頭 ・ 末尾| ・ * ・ ^ ・ @@（例外）と、$ の後の指定
//         （third-party / first-party、script / image / stylesheet / xmlhttprequest / subdocument / font / media /
//          websocket / ping / other / document、domain=、match-case、important、~ の打ち消し）
//   隠す: ##セレクタ（全部のサイト）・a.com,b.com##セレクタ（そのサイト）・#@#（例外）
// 対応しないもの（数えて読み飛ばす）: /正規表現/、$redirect・$csp・$removeparam など、#?#・#$#・#%#（スクリプト・拡張の書き方）、
//   $popup・$elemhide など、:has-text() などの拡張セレクタ

/// 読み込みの種類（ルールの $script などと照らし合わせる）
enum ResourceType: String, CaseIterable, Hashable {
    case document, subdocument, script, image, stylesheet, font, media, xhr, websocket, ping, other
}

struct NetworkRule: Equatable {
    /// 本体（$ の前。|| や | の印は外してある。match-case でなければ小文字）
    var body: String
    var hostAnchor = false      // ||
    var startAnchor = false     // |…
    var endAnchor = false       // …|
    var isException = false     // @@
    var important = false
    var matchCase = false
    /// third-party: true / first-party: false / 指定なし: nil
    var thirdParty: Bool?
    /// 当てはまる種類（nil なら全部）
    var types: Set<ResourceType>?
    /// domain= の、当てはまるサイトと除くサイト
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    /// 元の行（ログ・開発者向け）
    var text: String
}

struct CosmeticRule: Equatable {
    var selector: String
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    var isException = false
}

struct ParsedFilterList {
    var network: [NetworkRule] = []
    var cosmetic: [CosmeticRule] = []
    var lines = 0
    var unsupported = 0
    /// リストの見出しの「! Title:」
    var title: String?
}

enum ABPParser {
    static func parse(_ text: String) -> ParsedFilterList {
        var out = ParsedFilterList()
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            out.lines += 1
            if line.hasPrefix("!") {
                if out.title == nil, line.hasPrefix("! Title:") { out.title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                return
            }
            if line.hasPrefix("[") { return }
            if let r = parseLine(line) {
                switch r {
                case .network(let n): out.network.append(n)
                case .cosmetic(let c): out.cosmetic.append(c)
                }
            } else {
                out.unsupported += 1
            }
        }
        return out
    }

    enum Rule { case network(NetworkRule), cosmetic(CosmeticRule) }

    /// 1 行を読む。対応しない書き方なら nil
    static func parseLine(_ line: String) -> Rule? {
        // 隠すルール（## / #@#）。スクリプトや拡張の書き方（#?# #$# #%# #@?# など）は読まない
        if let r = line.range(of: "#@#") ?? line.range(of: "##") {
            let isException = line[r] == "#@#"
            let domainsPart = String(line[..<r.lowerBound])
            let selector = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if domainsPart.contains("#") || domainsPart.contains("$") || domainsPart.contains("/") { return nil }
            guard isSafeSelector(selector) else { return nil }
            var c = CosmeticRule(selector: selector, isException: isException)
            for d in domainsPart.split(separator: ",") {
                let t = d.trimmingCharacters(in: .whitespaces).lowercased()
                if t.isEmpty { continue }
                if t.hasPrefix("~") { c.excludeDomains.append(String(t.dropFirst())) } else { c.includeDomains.append(t) }
            }
            if c.includeDomains.contains(where: { $0.contains("*") }) || c.excludeDomains.contains(where: { $0.contains("*") }) { return nil }
            return .cosmetic(c)
        }
        if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("$$") || line.contains("#@") { return nil }
        return parseNetwork(line).map { .network($0) }
    }

    /// WebKit の css-display-none に渡しても大丈夫そうなセレクタか（拡張の書き方・壊れたものを入れるとリスト全体がだめになる）
    static func isSafeSelector(_ s: String) -> Bool {
        if s.isEmpty || s.count > 500 { return false }
        if s.hasPrefix("+js") || s.hasPrefix("^") || s.contains("\\") || s.contains("{") || s.contains("}") { return false }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) else { return false }
        // 使ってよい疑似クラスだけ
        if s.contains(":") {
            let allowed = [":not(", ":nth-child(", ":nth-of-type(", ":first-child", ":last-child", ":first-of-type", ":last-of-type",
                           ":only-child", ":empty", ":has(", ":is(", ":where("]
            var rest = s
            for a in allowed { rest = rest.replacingOccurrences(of: a, with: "") }
            // 属性の中の「:」（[href^="http:"] など）は構わない
            var depth = 0
            for ch in rest {
                if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 } else if ch == ":" && depth == 0 { return false }
            }
        }
        // 括弧・角括弧・引用符の数が合っているか（壊れたセレクタを避ける）
        var paren = 0, bracket = 0, dq = 0, sq = 0
        for ch in s {
            switch ch {
            case "(": paren += 1
            case ")": paren -= 1; if paren < 0 { return false }
            case "[": bracket += 1
            case "]": bracket -= 1; if bracket < 0 { return false }
            case "\"": dq += 1
            case "'": sq += 1
            default: break
            }
        }
        return paren == 0 && bracket == 0 && dq % 2 == 0 && sq % 2 == 0
    }

    static func parseNetwork(_ line: String) -> NetworkRule? {
        var s = Substring(line)
        var r = NetworkRule(body: "", text: line)
        if s.hasPrefix("@@") { r.isException = true; s = s.dropFirst(2) }
        // 正規表現のルールは読まない
        if s.hasPrefix("/") && s.count > 2 && (s.hasSuffix("/") || s.contains("/$")) { return nil }
        // $ の後の指定（最後の $ から。本体に $ を含むことはまれ）
        if let dollar = s.lastIndex(of: "$") {
            let opts = s[s.index(after: dollar)...]
            let body = s[..<dollar]
            if !opts.isEmpty, !opts.contains("/") || opts.contains("domain=") {
                guard applyOptions(String(opts), to: &r) else { return nil }
                s = body
            }
        }
        if s.hasPrefix("||") { r.hostAnchor = true; s = s.dropFirst(2) }
        else if s.hasPrefix("|") { r.startAnchor = true; s = s.dropFirst() }
        if s.hasSuffix("|") { r.endAnchor = true; s = s.dropLast() }
        // 先頭・末尾の * は意味が無い
        while s.hasPrefix("*") { s = s.dropFirst(); r.hostAnchor = false; r.startAnchor = false }
        while s.hasSuffix("*") { s = s.dropLast(); r.endAnchor = false }
        if s.isEmpty && r.includeDomains.isEmpty { return nil }      // 全部に当たるルールは危ないので読まない
        if s.contains("|") { return nil }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) else { return nil }
        r.body = r.matchCase ? String(s) : s.lowercased()
        return r
    }

    /// $ の後の指定を読む。対応しない指定があれば false（ルールごと読まない）
    static func applyOptions(_ opts: String, to r: inout NetworkRule) -> Bool {
        var include = Set<ResourceType>(), exclude = Set<ResourceType>()
        for raw in opts.split(separator: ",") {
            var o = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = o.hasPrefix("~")
            if negated { o.removeFirst() }
            let type: ResourceType?
            switch o {
            case "script": type = .script
            case "image": type = .image
            case "stylesheet", "css": type = .stylesheet
            case "xmlhttprequest", "xhr": type = .xhr
            case "subdocument", "frame": type = .subdocument
            case "document", "doc": type = .document
            case "font": type = .font
            case "media": type = .media
            case "websocket": type = .websocket
            case "ping", "beacon": type = .ping
            case "other", "object", "object-subrequest": type = .other
            default: type = nil
            }
            if let type {
                if negated { exclude.insert(type) } else { include.insert(type) }
                continue
            }
            switch o {
            case "third-party", "3p": r.thirdParty = !negated
            case "first-party", "1p": r.thirdParty = negated
            case "match-case": r.matchCase = true
            case "important": r.important = true
            case "all": include.formUnion(ResourceType.allCases)
            case "cname": break
            default:
                if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                    let list = o.drop(while: { $0 != "=" }).dropFirst()
                    for d in list.split(separator: "|") {
                        let t = String(d)
                        if t.contains("*") || t.hasPrefix("/") { return false }
                        if t.hasPrefix("~") { r.excludeDomains.append(String(t.dropFirst())) } else { r.includeDomains.append(t) }
                    }
                } else {
                    // redirect・csp・removeparam・popup・elemhide・badfilter など
                    return false
                }
            }
        }
        if !include.isEmpty { r.types = include.subtracting(exclude) }
        else if !exclude.isEmpty { r.types = Set(ResourceType.allCases).subtracting(exclude).subtracting([.document]) }
        if r.types?.isEmpty == true { return false }
        return true
    }
}

// ======================================================================
// MARK: - BlockEngine.swift
// ======================================================================

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
        SiteUtil.hostMatches(host, domain: d)
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

// ======================================================================
// MARK: - ContentBlocker.swift
// ======================================================================

// MARK: - 広告ブロックのルールを WebKit のルール（WKContentRuleList の JSON）にする
//
// ・通信のルール（標準の通信のタブで使う。VNet のタブは BlockEngine が自分で調べて数える）と、
//   隠すルール（どちらのタブでも使う）を、別々の JSON にする
// ・WebKit の例外（ignore-previous-rules）は、同じリストの前にあるルールだけを打ち消す。なので
//   並びは「ブロック → 例外 → important のブロック」
// ・WebKit の url-filter は正規表現の一部（| や {n} が使えない・ASCII だけ）。^ は「区切りの文字」に置き換える
// ・1 つのリストは maxRules まで（WebKit の上限は 15 万）

enum ContentBlockerCompiler {
    static let maxRules = 140_000
    /// 1 つの css-display-none にまとめるセレクタの数
    static let selectorsPerRule = 200

    struct Output {
        var json: String
        var count: Int
        var skipped: Int
    }

    // MARK: 通信のルール

    static func networkJSON(_ rules: [NetworkRule]) -> Output {
        var blocks: [String] = [], exceptions: [String] = [], important: [String] = []
        var skipped = 0
        for r in rules {
            guard let obj = networkRule(r) else { skipped += 1; continue }
            if r.isException { exceptions.append(obj) } else if r.important { important.append(obj) } else { blocks.append(obj) }
        }
        var all = blocks + exceptions + important
        if all.count > maxRules {
            skipped += all.count - maxRules
            // 例外と important は残して、普通のブロックを減らす
            all = Array(blocks.prefix(max(0, maxRules - exceptions.count - important.count))) + exceptions + important
        }
        return Output(json: "[" + all.joined(separator: ",") + "]", count: all.count, skipped: skipped)
    }

    static func networkRule(_ r: NetworkRule) -> String? {
        guard let filter = urlFilter(r) else { return nil }
        var trigger = "\"url-filter\":\(quote(filter))"
        if r.matchCase { trigger += ",\"url-filter-is-case-sensitive\":true" }
        // WebKit のサイトの指定は ASCII だけ（日本語のドメインはリスト全体のエラーになる）
        let inc = r.includeDomains.filter(isASCIIDomain), exc = r.excludeDomains.filter(isASCIIDomain)
        if !r.includeDomains.isEmpty && inc.isEmpty { return nil }
        if !inc.isEmpty {
            trigger += ",\"if-domain\":" + list(inc.map { "*" + $0 })
        } else if !exc.isEmpty {
            trigger += ",\"unless-domain\":" + list(exc.map { "*" + $0 })
        }
        if let tp = r.thirdParty { trigger += ",\"load-type\":[\"\(tp ? "third-party" : "first-party")\"]" }
        // 種類の指定が無いルールも、ページそのもの（document）は止めない（記事の URL に「/ads/」が入っていても開けるように）
        let types = r.types ?? Set(ResourceType.allCases).subtracting([.document, .subdocument])
        let wk = Set(types.map(webKitType)).sorted()
        trigger += ",\"resource-type\":" + list(wk)
        let action = r.isException ? "ignore-previous-rules" : "block"
        return "{\"trigger\":{\(trigger)},\"action\":{\"type\":\"\(action)\"}}"
    }

    static func isASCIIDomain(_ d: String) -> Bool {
        !d.isEmpty && d.unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "." || $0 == "-" }
    }

    static func webKitType(_ t: ResourceType) -> String {
        switch t {
        case .document, .subdocument: return "document"
        case .script: return "script"
        case .image: return "image"
        case .stylesheet: return "style-sheet"
        case .font: return "font"
        case .media: return "media"
        case .xhr, .websocket, .ping, .other: return "raw"
        }
    }

    /// ABP の本体を、WebKit の url-filter（正規表現の一部）にする
    static func urlFilter(_ r: NetworkRule) -> String? {
        var out = ""
        if r.hostAnchor { out = "^[a-z][a-z0-9.+-]*://([^/?#]*\\.)?" }
        else if r.startAnchor { out = "^" }
        for ch in r.body.unicodeScalars {
            guard ch.isASCII else { return nil }
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-zA-Z0-9_.%-]"
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(ch)
            default: out.unicodeScalars.append(ch)
            }
        }
        if r.endAnchor { out += "$" }
        if out.isEmpty { out = ".*" }
        return out
    }

    // MARK: 隠すルール

    static func cosmeticJSON(_ rules: [CosmeticRule]) -> Output {
        // 全部のサイトに効く例外（#@#.ad）はセレクタごと外す。サイトを指定した例外は、そのサイトを unless-domain にする
        var removed = Set<String>()
        var exceptDomains: [String: [String]] = [:]
        let rules = rules.compactMap { r -> CosmeticRule? in
            var c = r
            c.includeDomains = r.includeDomains.filter(isASCIIDomain)
            c.excludeDomains = r.excludeDomains.filter(isASCIIDomain)
            return (!r.includeDomains.isEmpty && c.includeDomains.isEmpty) ? nil : c
        }
        for r in rules where r.isException {
            if r.includeDomains.isEmpty { removed.insert(r.selector) }
            else { exceptDomains[r.selector, default: []] += r.includeDomains }
        }
        var generic: [String] = []
        var genericWithExceptions: [String: [String]] = [:]
        var specific: [String: [String]] = [:]      // サイトの組 → セレクタ
        var seen = Set<String>()
        for r in rules where !r.isException && !removed.contains(r.selector) {
            if r.includeDomains.isEmpty {
                guard seen.insert(r.selector).inserted else { continue }
                let unless = r.excludeDomains + (exceptDomains[r.selector] ?? [])
                if unless.isEmpty { generic.append(r.selector) } else { genericWithExceptions[r.selector] = unless }
            } else {
                let key = r.includeDomains.sorted().joined(separator: ",")
                specific[key, default: []].append(r.selector)
            }
        }
        var out: [String] = []
        var i = 0
        while i < generic.count {
            let chunk = generic[i..<min(i + selectorsPerRule, generic.count)]
            out.append(hideRule(Array(chunk), ifDomains: nil, unlessDomains: nil))
            i += selectorsPerRule
        }
        for (sel, unless) in genericWithExceptions.sorted(by: { $0.key < $1.key }) {
            out.append(hideRule([sel], ifDomains: nil, unlessDomains: unless))
        }
        for (key, sels) in specific.sorted(by: { $0.key < $1.key }) {
            let domains = key.split(separator: ",").map(String.init)
            var j = 0
            while j < sels.count {
                out.append(hideRule(Array(sels[j..<min(j + selectorsPerRule, sels.count)]), ifDomains: domains, unlessDomains: nil))
                j += selectorsPerRule
            }
        }
        var skipped = 0
        if out.count > maxRules { skipped = out.count - maxRules; out = Array(out.prefix(maxRules)) }
        return Output(json: "[" + out.joined(separator: ",") + "]", count: out.count, skipped: skipped)
    }

    static func hideRule(_ selectors: [String], ifDomains: [String]?, unlessDomains: [String]?) -> String {
        var trigger = "\"url-filter\":\".*\""
        if let d = ifDomains { trigger += ",\"if-domain\":" + list(d.map { "*" + $0 }) }
        else if let d = unlessDomains { trigger += ",\"unless-domain\":" + list(d.map { "*" + $0 }) }
        return "{\"trigger\":{\(trigger)},\"action\":{\"type\":\"css-display-none\",\"selector\":\(quote(selectors.joined(separator: ", ")))}}"
    }

    // MARK: JSON の文字

    static func quote(_ s: String) -> String {
        var o = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) } else { o.unicodeScalars.append(ch) }
            }
        }
        return o + "\""
    }

    static func list(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ",") + "]" }

    /// ルールの中身から作る、変わったかどうかの印（FNV-1a 64 bit。コンパイル済みのリストの名前に使う）
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// ======================================================================
// MARK: - Persistence.swift
// ======================================================================

// MARK: - データのファイル（Application Support/Vela/ の JSON）
//
// タブ・ブックマーク・履歴などを Codable の JSON で置く。書き込みはまとめて（delay 秒後に 1 回）、裏のキューで、
// いったん別の名前に書いてから置き換える（.atomic。書いている途中で落ちても前のものが残る）

enum AppPaths {
    /// Application Support/Vela（取れなければ一時フォルダの Vela）。フォルダは作らない（作るのは使う側）
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
    }
}

final class JSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    /// 読み書きの失敗（開発者向けのログに出す）
    var log: (@Sendable (String) -> Void)?

    /// name: ファイルの名前（例: "tabs.json"）。directory を省くと Application Support/Vela/
    init(name: String, directory: URL? = nil, delay: TimeInterval = 1.0) {
        let dir = directory ?? JSONFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.delay = delay
        queue = DispatchQueue(label: "vela-json-\(name)")
    }

    static func defaultDirectory() -> URL { AppPaths.support }

    /// 読む（無い・壊れているなら nil。壊れていたファイルは .broken に名前を変えて残す）
    func load() -> Value? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: d)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を読めません（\(error)）。.broken として残します")
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return nil
        }
    }

    /// 保存する（delay 秒の間に何度呼んでも、書くのは最後の 1 回）
    func save(_ v: Value) {
        lock.lock()
        pending = v
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// 待っている分をすぐ書く（アプリが裏に回るときなど）。書き終わるまで待つ
    func saveNow(_ v: Value? = nil) {
        if let v { lock.lock(); pending = v; lock.unlock() }
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let v = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let v else { return }
        do {
            let d = try JSONEncoder().encode(v)
            try d.write(to: url, options: .atomic)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を書けません（\(error)）")
        }
    }
}

// MARK: - 設定（UserDefaults に置く）
//
// 通信まわりの設定は、アプリを起動し直したときに効く（WebView や通信の作りを、起動のときに決めるため）

enum VelaSettings {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: 通信（VNet）

    /// VNet を使わず、標準の通信（WebKit 内蔵）だけで読む
    static var vnetDisabled: Bool {
        get { bool("vnet.disabled", false) } set { d.set(newValue, forKey: "vnet.disabled") }
    }
    /// 確かめていない iOS の版でも、https の横取り（非公開 API）を試す
    static var allowUntestedOS: Bool {
        get { bool("vnet.allowUntestedOS", false) } set { d.set(newValue, forKey: "vnet.allowUntestedOS") }
    }
    /// 開発者向け: 横取りできないとき、標準の通信ではなく予備の vnets:// の作りを使う（安全ではない。CSP などを外すため）
    static var legacyVNetsFallback: Bool {
        get { bool("vnet.legacyVNets", false) } set { d.set(newValue, forKey: "vnet.legacyVNets") }
    }

    // MARK: 使い勝手

    /// 検索エンジン
    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "search.engine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "search.engine") }
    }
    /// HTTPS-First: ページを開く http:// を、まず https で試す（だめなら「http のまま開く」を出す）
    static var httpsFirst: Bool {
        get { bool("nav.httpsFirst", true) } set { d.set(newValue, forKey: "nav.httpsFirst") }
    }
    /// VNet でページを読めなかったら（TLS・つながらない など）、標準の通信に自動で切り替える
    static var autoFallbackToNative: Bool {
        get { bool("vnet.autoFallback", false) } set { d.set(newValue, forKey: "vnet.autoFallback") }
    }
    /// Mac の Safari の Web インスペクタからつなげるようにする（iOS 16.4 から）
    static var webInspector: Bool {
        get { bool("dev.webInspector", false) } set { d.set(newValue, forKey: "dev.webInspector") }
    }

    /// サイト（ホスト）ごとの文字の大きさ（100% のものは持たない）
    static func zoom(for host: String?) -> Double {
        guard let h = host?.lowercased(), let z = (d.dictionary(forKey: "zoom.sites") as? [String: Double])?[h] else { return 1.0 }
        return z
    }
    static func setZoom(_ z: Double, for host: String?) {
        guard let h = host?.lowercased(), !h.isEmpty else { return }
        var m = (d.dictionary(forKey: "zoom.sites") as? [String: Double]) ?? [:]
        m[h] = abs(z - 1.0) < 0.001 ? nil : z
        if m.count > 500 { m = [h: z] }      // 増えすぎたら覚え直す（めったに起きない）
        d.set(m, forKey: "zoom.sites")
    }

    // MARK: プライバシー・守り

    /// サードパーティ Cookie をブロックする
    static var blockThirdPartyCookies: Bool {
        get { bool("cookies.blockThirdParty", true) } set { d.set(newValue, forKey: "cookies.blockThirdParty") }
    }
    /// SameSite が無い Cookie を Lax として扱う
    static var cookiesLaxByDefault: Bool {
        get { bool("cookies.laxByDefault", true) } set { d.set(newValue, forKey: "cookies.laxByDefault") }
    }
    /// LAN の保護（公開のサイトから LAN の機器へ届かせない）
    static var localNetworkProtection: Bool {
        get { bool("lan.protection", true) } set { d.set(newValue, forKey: "lan.protection") }
    }

    /// 今の設定から作る Cookie の決まり
    static var cookiePolicy: CookiePolicy.Settings {
        var s = CookiePolicy.Settings()
        s.blockThirdParty = blockThirdPartyCookies
        s.laxByDefault = cookiesLaxByDefault
        return s
    }
}

// ======================================================================
// MARK: - DevLog.swift
// ======================================================================

// MARK: - 開発者向けのログ（どのスレッドからでも書ける）
//
// 1 行ずつ「時刻・重さ・種類・タブ・本文」を持って、最新 maxEntries 件まで覚える（古いものから消す）。
// 今までの log?("…") の文字列も、そのまま add で入れられる（先頭の記号から種類と重さを決める）。
// 画面へは、必要なときに entries(after:) で差分だけ取り出す（毎回全部を作り直すと重い）

enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug, info, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var mark: String {
        switch self { case .debug: return "·"; case .info: return " "; case .warning: return "⚠"; case .error: return "✕" }
    }
}

enum LogCategory: String, Sendable, CaseIterable {
    case app = "アプリ"
    case vnet = "VNet"
    case net = "通信"
    case nav = "移動"
    case cookie = "Cookie"
    case security = "守り"
    case block = "ブロック"
    case download = "ダウンロード"
    case js = "JS"
}

struct LogEntry: Sendable, Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let category: LogCategory
    /// どのタブのものか（タブに関係ないものは nil）
    let tab: Int?
    let message: String

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var line: String {
        "\(LogEntry.timeFormat.string(from: time)) \(level.mark) [\(category.rawValue)\(tab.map { "#\($0)" } ?? "")] \(message)"
    }
}

final class DevLog: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var start = 0           // ring の中で一番古いものの位置（いっぱいになってから使う）
    private var nextID = 1
    private var dirty = false
    /// ログを書いた回数（重さごと。開発者パネル用）
    private var counts: [LogLevel: Int] = [:]

    init() {}

    /// 今までの文字列のログ。先頭の記号などから種類と重さを決める
    func add(_ message: String, tab: Int? = nil) {
        let (level, category) = DevLog.classify(message)
        add(message, level: level, category: category, tab: tab)
    }

    func add(_ message: String, level: LogLevel, category: LogCategory, tab: Int? = nil) {
        lock.lock()
        let e = LogEntry(id: nextID, time: Date(), level: level, category: category, tab: tab, message: message)
        nextID += 1
        if ring.count < DevLog.maxEntries {
            ring.append(e)
        } else {
            ring[start] = e
            start = (start + 1) % DevLog.maxEntries
        }
        counts[level, default: 0] += 1
        dirty = true
        lock.unlock()
        // 落ちたときのために、すぐファイルにも書く（CrashLog.start の前は何もしない）
        CrashLog.writeLine(e.line)
    }

    /// 古い順に全部
    func all() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[start...] + ring[..<start])
    }

    /// id より新しいもの（古い順）。画面は最後に見た id を覚えておいて、差分だけもらう
    func entries(after id: Int) -> [LogEntry] {
        all().filter { $0.id > id }
    }

    func count(_ level: LogLevel) -> Int { lock.lock(); defer { lock.unlock() }; return counts[level] ?? 0 }

    /// 変わっていれば、最新 lines 行を 1 つの文字列にして返す（今の簡易のログ表示用）
    func take(lines: Int = 200) -> String? {
        lock.lock()
        if !dirty { lock.unlock(); return nil }
        dirty = false
        lock.unlock()
        return all().suffix(lines).map { $0.message }.joined(separator: "\n")
    }

    /// 書き出し用（共有・コピー）
    func export(minLevel: LogLevel = .debug) -> String {
        all().filter { $0.level >= minLevel }.map { $0.line }.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); ring = []; start = 0; dirty = true; lock.unlock()
    }

    /// 文字列から種類と重さを決める（今までのログの書き方に合わせる）
    static func classify(_ m: String) -> (LogLevel, LogCategory) {
        let level: LogLevel = m.hasPrefix("✕") || m.contains("失敗") ? .error
            : m.hasPrefix("⚠") ? .warning : .info
        let category: LogCategory
        if m.hasPrefix("🍪") { category = .cookie }
        else if m.hasPrefix("🚫") { category = .block }
        else if m.hasPrefix("🛡") || m.hasPrefix("🔒") || m.contains("HSTS") || m.contains("横取り") { category = .security }
        else if m.hasPrefix("✓") || m.hasPrefix("✕") || m.hasPrefix("↪") || m.hasPrefix("――") { category = .net }
        else if m.hasPrefix("→") || m.hasPrefix("←") || m.contains("TLS") || m.contains("DHCP") || m.contains("カード")
                    || m.contains("[ネット]") || m.contains("TCP") { category = .vnet }
        else { category = .app }
        return (level, category)
    }
}

// ======================================================================
// MARK: - CrashLog.swift
// ======================================================================

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 落ちたときの記録（次に起動したときに、開発者パネルで見る）
//
// ・ログを 1 行ずつ、すぐファイルに書く（落ちる直前まで残るように。メモリのログは落ちると消える）
// ・Objective-C の例外（WebKit などが投げる）は、名前・理由・呼び出しの順をファイルに書く
// ・致命的なシグナル（Swift の強制終了・不正なメモリアクセスなど）は、番号・落ちたスレッド・呼び出しの順を書く
//   （シグナルの中ではほとんど何もできないので、用意しておいた文字と backtrace_symbols_fd で、ファイルに直接書くだけ）
// ・起動するたびに、前回の記録を crash-previous.txt に移す。前回が落ちて終わっていたら、ログに知らせる

/// シグナルの中から使うので、ファイルの番号は global に置く（Swift の static は初めて触るときに準備が走るので、シグナルの中では使わない）
private var crashFD: Int32 = -1
private let signalMessages: [Int32: [UInt8]] = {
    var m: [Int32: [UInt8]] = [:]
    for (s, name) in [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")] {
        m[s] = Array("\n【シグナル】\(name)（\(s)）でアプリが止まりました\n".utf8)
    }
    return m
}()
/// 呼び出しの順を入れる場所（シグナルの中では作れないので、先に用意する）
private let backtraceCapacity: Int32 = 64
private let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private let mainThreadText = Array("落ちたスレッド: 画面のスレッド（main）\n呼び出しの順:\n".utf8)
private let otherThreadText = Array("落ちたスレッド: 裏のスレッド（main 以外）\n呼び出しの順:\n".utf8)

// backtrace・backtrace_symbols_fd（C の execinfo.h）。iPad の Swift Playgrounds では Darwin から見えなかった
// （「cannot find 'backtrace' in scope」）ので、C の関数の名前で直接つなぐ。iOS・Linux の libc のどちらにもある
@_silgen_name("backtrace")
private func cBacktrace(_ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd")
private func cBacktraceSymbolsFD(_ buffer: UnsafePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)

/// 致命的なシグナルの受け口。シグナルの中なので、用意しておいたものを write で書くだけにする
private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        if let m = signalMessages[sig] { _ = m.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) } }
        #if canImport(Darwin)
        let isMain = pthread_main_np() != 0
        #else
        let isMain = false
        #endif
        let t = isMain ? mainThreadText : otherThreadText
        _ = t.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        let n = cBacktrace(backtraceBuffer, backtraceCapacity)
        cBacktraceSymbolsFD(backtraceBuffer, n, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashLog {
    private static let lock = NSLock()
    private static var written = 0
    static let maxBytes = 2 << 20
    static let exceptionMark = "【例外】"
    static let signalMark = "【シグナル】"

    static var folder: URL {
        let dir = AppPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var currentURL: URL { folder.appendingPathComponent("crash-current.txt") }
    static var previousURL: URL { folder.appendingPathComponent("crash-previous.txt") }

    /// 起動したときに 1 回。前回の記録を移して、新しいファイルを開き、例外とシグナルの受け口を入れる
    static func start() {
        lock.lock(); defer { lock.unlock() }
        if crashFD >= 0 { return }
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        if fm.fileExists(atPath: currentURL.path) { try? fm.moveItem(at: currentURL, to: previousURL) }
        crashFD = open(currentURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = (signalMessages, mainThreadText, otherThreadText, backtraceBuffer)     // シグナルの中で準備が走らないよう、先に作っておく
        #if canImport(Darwin)
        NSSetUncaughtExceptionHandler { e in CrashLog.recordException(e) }
        #endif
        _ = cBacktrace(backtraceBuffer, 1)     // 初めて呼ぶときの準備を、シグナルの中ではなくここで済ませておく
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(s, crashSignalHandler)
        }
        // ここはもう lock を持っているので、writeLine ではなく writeLineLocked（NSLock は 2 回取ると止まる）
        writeLineLocked("―― 起動 \(Date()) ――")
    }

    /// 1 行書く（DevLog から全部の行が来る）
    static func writeLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        writeLineLocked(s)
    }

    /// lock を持っているときに呼ぶ
    private static func writeLineLocked(_ s: String) {
        guard crashFD >= 0 else { return }
        let bytes = Array((s + "\n").utf8)
        if written + bytes.count > maxBytes {
            // 大きくなりすぎたら最初から（落ちる直前の分があればよい）
            _ = ftruncate(crashFD, 0)
            _ = lseek(crashFD, 0, SEEK_SET)
            written = 0
        }
        _ = bytes.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        written += bytes.count
    }

    #if canImport(Darwin)
    static func recordException(_ e: NSException) {
        var s = "\n\(exceptionMark)\(e.name.rawValue): \(e.reason ?? "（理由なし）")\n"
        s += e.callStackSymbols.prefix(40).joined(separator: "\n")
        writeLine(s)
    }
    #endif

    /// 前回の記録（最後の lines 行）。無ければ nil
    static func previous(lines: Int = 300) -> String? {
        guard let d = try? Data(contentsOf: previousURL), !d.isEmpty else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// 前回は落ちて終わったか（例外かシグナルの記録がある）。あれば、その行
    static func previousCrashSummary() -> String? {
        guard let p = previous(lines: 2000) else { return nil }
        let lines = p.split(separator: "\n")
        return lines.last { $0.contains(exceptionMark) || $0.contains(signalMark) }.map(String.init)
    }
}
