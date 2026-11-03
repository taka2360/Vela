import Foundation

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
    var unsupported = 0
    /// リストの見出しの「! Title:」
    var title: String?
}

enum ABPParser {
    /// env: !#if の判定に使う値（FilterPreparser.env）。既定は uBO の拡張と同じ（ext_ublock だけ真）
    static func parse(_ text: String, env: [String] = ["ublock"]) -> ParsedFilterList {
        var out = ParsedFilterList()
        let splitter = FilterPreparser.Splitter(env: env)
        text.enumerateLines { raw, _ in
            // !#if で捨てる枝の行は読まない（uBO の preparser と同じ）
            guard splitter.keep(Substring(raw)) else { return }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
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
