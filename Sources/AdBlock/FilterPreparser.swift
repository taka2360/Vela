import Foundation

// MARK: - リストの前処理（!#if / !#else / !#endif と !#include）
//
// uBlock Origin（uBO）1.75.2 の static-filtering-parser.js の preparser（preparserTokens・evaluateExpr・splitter・expandIncludes）を写したもの。
// ・知らない名前の !#if は「判定しない」（中も外も残す）。cap_ で始まる知らない名前だけは偽
// ・env は uBO が持つ値の名前（"ublock"・"mobile" など）。Vela は ext_ublock を真にし、UA に Mobile があれば env_mobile も真（uBO の vapi-common.js と同じ判定）
// ・!#include は、URL の形と「..」を含むものを断り、元のリストと同じ場所（サブフォルダは可）から読む。捨てる枝の中の include は読まない

enum FilterPreparser {
    /// uBO の preparserTokens（!#if の名前 → env の値の名前）
    static let tokens: [String: String] = [
        "ext_ublock": "ublock",
        "ext_ubol": "ubol",
        "ext_devbuild": "devbuild",
        "env_brave": "brave",
        "env_chromium": "chromium",
        "env_edge": "edge",
        "env_firefox": "firefox",
        "env_legacy": "legacy",
        "env_mobile": "mobile",
        "env_mv3": "mv3",
        "env_safari": "safari",
        "cap_html_filtering": "html_filtering",
        "cap_ipaddress": "ipaddress",
        "false": "false",
        "ext_abp": "false",
        "adguard": "adguard",
        "adguard_app_android": "false",
        "adguard_app_cli": "false",
        "adguard_app_ios": "false",
        "adguard_app_mac": "false",
        "adguard_app_windows": "false",
        "adguard_ext_android_cb": "false",
        "adguard_ext_chromium": "chromium",
        "adguard_ext_chromium_mv3": "mv3",
        "adguard_ext_edge": "edge",
        "adguard_ext_firefox": "firefox",
        "adguard_ext_opera": "chromium",
        "adguard_ext_safari": "false",
    ]

    /// Vela の env（uBO の vAPI.webextFlavor.soup のうち、!#if が見るもの）
    static func env(userAgent: String) -> [String] {
        var e = ["ublock"]
        if userAgent.range(of: #"\bMobile\b"#, options: .regularExpression) != nil { e.append("mobile") }
        return e
    }

    /// 1 つの名前（先頭の ! は打ち消し）。知らない名前なら nil
    static func evaluateToken(_ raw: String, _ env: [String]) -> Bool? {
        var token = Substring(raw)
        let not = token.hasPrefix("!")
        if not { token = token.dropFirst() }
        var state = tokens[String(token)]
        if state == nil {
            if !token.hasPrefix("cap_") { return nil }
            state = "false"
        }
        // JS: state === 'false' && not || env.includes(state) !== not
        return (state == "false" && not) || (env.contains(state!) != not)
    }

    /// 式（&& と || は左から順に。括弧は全体を囲むものだけ）。判定できなければ nil
    static func evaluateExpr(_ raw: String, _ env: [String]) -> Bool? {
        var expr = Substring(raw)
        if expr.hasPrefix("(") && expr.hasSuffix(")") && expr.count >= 2 { expr = expr.dropFirst().dropLast() }
        // uBO: /(?:(?:&&|\|\|)\s+)?\S+/g
        let words = expr.split(whereSeparator: { $0.isWhitespace })
        var matches: [(op: Substring?, word: Substring)] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            if (w == "&&" || w == "||") && i + 1 < words.count {
                matches.append((w, words[i + 1])); i += 2
            } else {
                matches.append((nil, w)); i += 1
            }
        }
        guard let first = matches.first else { return nil }
        if first.op != nil || first.word.hasPrefix("|") || first.word.hasPrefix("&") { return nil }
        var result = evaluateToken(String(first.word), env)
        for m in matches.dropFirst() {
            guard let op = m.op else { return nil }       // 「a b」のような並び
            guard let state = evaluateToken(String(m.word), env) else { return nil }
            if op == "||" {
                result = (result == true) ? true : state  // undefined || x → x
            } else {
                result = (result == nil) ? nil : (result! && state)
            }
        }
        return result
    }

    enum Directive { case ifExpr(String), elseBranch, endif }

    /// 「!#if 式」「!#else」「!#endif」の行か（uBO: /^!#(if|else|endif)\b([^\n]*)/）
    static func directive(_ line: Substring) -> Directive? {
        guard line.hasPrefix("!#") else { return nil }
        let rest = line.dropFirst(2)
        func word(_ w: String) -> Substring? {
            guard rest.hasPrefix(w) else { return nil }
            let after = rest.dropFirst(w.count)
            if let c = after.first, c.isLetter || c.isNumber || c == "_" { return nil }
            return after
        }
        if let a = word("endif") { _ = a; return .endif }
        if let a = word("else") { _ = a; return .elseBranch }
        if let a = word("if") { return .ifExpr(a.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// uBO の splitter を行ごとに。残す行なら true を返す閉包を、行を順に渡して使う
    final class Splitter {
        private final class Details { var known: Bool; var discard: Bool; init(_ k: Bool, _ d: Bool) { known = k; discard = d } }
        private var stack: [Details] = []
        private(set) var discarding = false
        let env: [String]
        init(env: [String]) { self.env = env }

        private func shouldDiscard() -> Bool { stack.contains { $0.known && $0.discard } }
        private func begif(_ d: Details) {
            if !discarding && d.known && d.discard { discarding = true }
            stack.append(d)
        }
        private func endif() {
            if !stack.isEmpty { stack.removeLast() }
            if discarding && !shouldDiscard() { discarding = false }
        }

        /// その行を残すか（!#if などの行そのものは、どちらにしても注釈として読み飛ばされる）
        func keep(_ line: Substring) -> Bool {
            switch directive(line) {
            case .ifExpr(let e)?:
                let r = FilterPreparser.evaluateExpr(e, env)
                begif(Details(r != nil, r == false))
                return false
            case .elseBranch?:
                guard let d = stack.last else { return false }
                endif()
                d.discard = !d.discard
                begif(d)
                return false
            case .endif?:
                endif()
                return false
            case nil:
                return !discarding
            }
        }
    }

    /// !#if で捨てる行を除いたもの（行の区切りは \n）
    static func prune(_ text: String, env: [String]) -> String {
        let s = Splitter(env: env)
        var out: [Substring] = []
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).forEach { line in
            if s.keep(line) { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: !#include

    static let maxIncludeDepth = 3
    static let maxTotalBytes = 16 << 20

    /// include の名前から、読みに行く URL（だめなら nil）。uBO: URL の形と「..」は断る。元のリストの最後の / までに付ける
    static func includeURL(_ name: String, base: URL) -> URL? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.contains("..") { return nil }
        if let u = URL(string: n), u.scheme != nil { return nil }
        let b = base.absoluteString
        guard let slash = b.lastIndex(of: "/") else { return nil }
        return URL(string: String(b[...slash]) + n)
    }

    /// 残る枝の中の「!#include 名前」の名前（uBO: /^!#include +(\S+)/）
    static func includeName(_ line: Substring) -> String? {
        guard line.hasPrefix("!#include ") else { return nil }
        let rest = line.dropFirst("!#include".count).drop(while: { $0 == " " })
        let name = rest.prefix(while: { !$0.isWhitespace })
        return name.isEmpty ? nil : String(name)
    }

    struct Expanded {
        var text: String
        var included: [URL] = []
        var failed: [String] = []
    }

    /// include を読んで、その位置に埋め込む。fetch は読めなければ nil。同じ URL は 1 回だけ・深さと合計の大きさに上限
    static func expandIncludes(_ text: String, base: URL, env: [String],
                               fetch: (URL) async -> String?) async -> Expanded {
        var seen: Set<String> = [base.absoluteString]
        var total = text.utf8.count
        var included: [URL] = [], failed: [String] = []
        func expand(_ text: String, base: URL, depth: Int) async -> String {
            let s = Splitter(env: env)
            var out: [String] = []
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let kept = s.keep(line)
                out.append(String(line))
                guard kept, let name = includeName(line) else { continue }
                guard let u = includeURL(name, base: base) else { failed.append("\(name)（読めない名前）"); continue }
                if seen.contains(u.absoluteString) { continue }
                seen.insert(u.absoluteString)
                if depth >= maxIncludeDepth { failed.append("\(name)（深すぎる）"); continue }
                guard let sub = await fetch(u) else { failed.append("\(name)（読めない）"); continue }
                if total + sub.utf8.count > maxTotalBytes { failed.append("\(name)（大きすぎる）"); continue }
                total += sub.utf8.count
                included.append(u)
                let body = await expand(sub, base: u, depth: depth + 1)
                out.append("! >>>>>>>> \(u.absoluteString)")
                out.append(body)
                out.append("! <<<<<<<< \(u.absoluteString)")
            }
            return out.joined(separator: "\n")
        }
        let t = await expand(text, base: base, depth: 0)
        return Expanded(text: t, included: included, failed: failed)
    }

    /// 「! Expires: 8 hours」「! Expires: 4 days (update frequency)」→ 時間（1〜168 に丸める）。無ければ nil
    static func expiresHours(_ text: String) -> Int? {
        for line in text.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true).prefix(60) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.lowercased().hasPrefix("! expires:") else { continue }
            let rest = l.dropFirst("! expires:".count).trimmingCharacters(in: .whitespaces).lowercased()
            let num = rest.prefix(while: { $0.isNumber })
            guard let v = Int(num), v > 0 else { return nil }
            let unit = rest.dropFirst(num.count).trimmingCharacters(in: .whitespaces)
            let hours = unit.hasPrefix("h") ? v : v * 24
            return min(max(hours, 1), 168)
        }
        return nil
    }
}
