import Foundation

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
