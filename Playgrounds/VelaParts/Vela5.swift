// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 5 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - FilterCatalog.swift
// ======================================================================

// MARK: - 広告ブロックのリストの一覧（組み込みのもの）と、保存する形
// UI・WebKit に頼らない（テストできるように FilterLists.swift から分けた）

struct FilterListInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var builtIn: Bool
    var lastUpdated: Date?
    var networkRules = 0
    var cosmeticRules = 0
    var unsupported = 0
    var lastError: String?
    /// スクリプトレットの行の数・リストの「! Expires:」（時間）。古い adblock.json には無いので Optional
    var scriptletRules: Int?
    var expiresHours: Int?
    /// コンパイル済みの WebKit のルールの名前
    var netID: String?
    var cosID: String?
}

struct AdBlockState: Codable {
    var lists: [FilterListInfo]
    var lastAutoUpdate: Date?
    /// スクリプトレットの道具を最後に確かめた時
    var scriptletsChecked: Date?
}

/// タブに入れるスクリプトレット（ScriptletAssembler の結果と、入れ替えの判定に使う印）
struct ScriptletInjection: Equatable {
    var key: String
    var main: String
    var isolated: String
    var filters: [String]
}

enum FilterCatalog {
    static let lists: [FilterListInfo] = [
        FilterListInfo(id: "easylist", name: "EasyList（広告）", url: "https://easylist.to/easylist/easylist.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy（トラッカー）", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "adguard-ja", name: "AdGuard Japanese（日本の広告）", url: "https://filters.adtidy.org/extension/ublock/filters/7.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-filters", name: "uBlock filters（YouTube など）", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes（すぐの直し）", url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt", enabled: true, builtIn: true),
    ]
    /// trusted の道具（trusted-*・rpnt など）を使ってよいリスト。uBO も自分のリスト（ublock-）だけを信頼する
    static let trustedIDs: Set<String> = ["ublock-filters", "ublock-quick-fixes"]

    /// そのリストの行が trusted の道具を使ってよいか（組み込みの一覧にあって、URL も一覧と同じもの。保存ファイルの id だけでは信じない）
    static func isTrusted(_ l: FilterListInfo) -> Bool {
        trustedIDs.contains(l.id) && lists.contains { $0.id == l.id && $0.url == l.url }
    }

    /// 保存してあった一覧と組み込みの一覧を合わせる。組み込みのものは名前と URL を一覧のもので上書きする（保存ファイルで偽れないように）。
    /// 一覧に無いのに「組み込み」になっているものは、自分で足したものとして扱う
    static func merge(saved: [FilterListInfo]) -> [FilterListInfo] {
        var merged = saved.map { l -> FilterListInfo in
            var l = l
            if let c = lists.first(where: { $0.id == l.id }) {
                l.name = c.name; l.url = c.url; l.builtIn = true
            } else {
                l.builtIn = false
            }
            return l
        }
        for c in lists where !merged.contains(where: { $0.id == c.id }) { merged.append(c) }
        return merged
    }
}

// ======================================================================
// MARK: - FilterPreparser.swift
// ======================================================================

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
//   スクリプトレット: ##+js(…)・#@#+js(…)（uBO の書き方。Scriptlets.swift）
// 対応しないもの（数えて読み飛ばす）: /正規表現/、$redirect・$csp・$removeparam など、#?#・#$#・#%#（AdGuard などのスクリプト・拡張の書き方）、
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
    /// ##+js(…) / #@#+js(…)（Scriptlets.swift）
    var scriptlets: [ScriptletFilter] = []
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
                case .scriptlet(let s): out.scriptlets.append(s)
                }
            } else {
                out.unsupported += 1
            }
        }
        return out
    }

    enum Rule { case network(NetworkRule), cosmetic(CosmeticRule), scriptlet(ScriptletFilter) }

    /// 1 行を読む。対応しない書き方なら nil
    static func parseLine(_ line: String) -> Rule? {
        // スクリプトレット（uBO の ##+js(…)）
        if let s = ScriptletParser.parse(line) { return .scriptlet(s) }
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
// MARK: - Scriptlets.swift
// ======================================================================

// MARK: - スクリプトレット（##+js(...)）。uBlock Origin（uBO）1.75.2 の仕組みを写したもの
//
// ・行を読む:      static-filtering-parser.js の parseExtPatternScriptlet・ArglistParser（引数の分け方・引用符・\, の扱い）
// ・入れる:        scriptlet-filtering-core.js の compile（normalizeRawFilter・trusted の検査・ドメイン無しは例外だけ）
// ・選ぶ:          static-ext-filtering-db.js（ホストと親ドメイン・entity・パス・正規表現）と retrieve（祖先 >>・例外・#@#+js()）
// ・組み立てる:    lookupScriptlet・patchScriptlet・sortedCalls（依存の関数は 1 回だけ。try { 呼び出し } catch {}）
//   uBO の外側の包み（main は即時実行・isolated は関数の定義だけで呼ぶ側が実行）は写さず、Vela が両方とも (function(){ … })(); で包む
// 道具の中身（関数）は uBO のソースから作った resources/ubo-scriptlets.json（ScriptletLibrary）を使う。Vela は道具を書かない

/// 1 行のスクリプトレットのルール（まだ道具の名前は正規化していない）
struct ScriptletFilter: Equatable {
    struct Target: Equatable {
        /// 小文字のホスト・entity（youtube.*）・*・a.com/path・a.com>>・/正規表現/
        var value: String
        var not: Bool
    }
    /// args[0] は道具の名前（書かれたまま。末尾の .js は外す）。空なら #@#+js()
    var args: [String]
    var targets: [Target]
    var isException: Bool
    /// 読めなかったドメインの数
    var badTargets = 0
    var text: String
}

// MARK: 行を読む

enum ScriptletParser {
    /// 「ドメイン##+js(…)」「ドメイン#@#+js(…)」なら読む。スクリプトレットの行でなければ nil
    static func parse(_ line: String) -> ScriptletFilter? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[hash...]
        let isException: Bool
        let pattern: Substring
        if rest.hasPrefix("##+js(") { isException = false; pattern = rest.dropFirst(2) }
        else if rest.hasPrefix("#@#+js(") { isException = true; pattern = rest.dropFirst(3) }
        else { return nil }
        guard pattern.hasSuffix(")") else { return nil }
        let inner = String(pattern.dropFirst(4).dropLast())
        var f = ScriptletFilter(args: arguments(inner), targets: [], isException: isException, text: line)
        let domains = line[..<hash]
        if !domains.isEmpty {
            for (t, bad) in parseTargets(String(domains)) {
                if bad { f.badTargets += 1 } else if let t { f.targets.append(t) }
            }
        }
        return f
    }

    /// +js( と ) の間を、uBO と同じく引数に分ける（[道具の名前, 引数…]）
    static func arguments(_ s: String) -> [String] {
        let u = Array(s.utf16)
        if u.isEmpty { return [] }
        var p = ArglistParser()
        let t = p.nextArg(u, 0)
        var token = jsSlice(u, t.argBeg, t.argEnd)
        if token.hasSuffix(".js") { token.removeLast(3) }
        var out = [token]
        // 残り（uBO: parseExtPatternScriptletArglist。新しい文字列として最初から数える）
        let a = Array(u[t.separatorEnd...])
        let end = a.count
        if end == 0 { return out }
        var i = 0
        while true {
            let d = p.nextArg(a, i)
            if i == end { break }
            let raw = d.argEnd > d.argBeg ? Array(a[d.argBeg..<d.argEnd]) : []
            out.append(d.transform ? p.normalizeArg(raw) : String(utf16CodeUnits: raw, count: raw.count))
            i = d.separatorEnd
        }
        return out
    }

    /// JS の slice(b, e)（e が b より前なら空）
    static func jsSlice(_ u: [UInt16], _ b: Int, _ e: Int) -> String {
        let b = min(max(b, 0), u.count), e = min(max(e, 0), u.count)
        guard e > b else { return "" }
        return String(utf16CodeUnits: Array(u[b..<e]), count: e - b)
    }

    /// ドメインの並び（, 区切り。/正規表現/ の中の , は区切りにしない）。(ターゲット, 読めない)
    static func parseTargets(_ s: String) -> [(ScriptletFilter.Target?, Bool)] {
        var out: [(ScriptletFilter.Target?, Bool)] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            var j = i
            let not = chars[j] == "~"
            if not { j += 1 }
            var end: Int
            if j < chars.count && chars[j] == "/" {
                // 正規表現: 次の「/,」か終わりまで
                end = j + 1
                var found = false
                while end < chars.count {
                    if chars[end] == "/" && (end + 1 == chars.count || chars[end + 1] == ",") { end += 1; found = true; break }
                    end += 1
                }
                if !found { end = chars.count }
            } else {
                end = j
                while end < chars.count && chars[end] != "," { end += 1 }
            }
            let item = String(chars[j..<end])
            if !item.isEmpty { out.append(normalizeTarget(item, not: not)) }
            i = end + 1
        }
        return out
    }

    private static let reHostnameAscii = try! NSRegularExpression(pattern: #"^(?:[\da-z][\da-z_-]*\.)*[\da-z][\da-z-]*[\da-z]$"#)
    private static let rePlainEntity = try! NSRegularExpression(pattern: #"^(?:[\da-z][\da-z_-]*\.)+\*$"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 1 つのターゲットを確かめる（uBO: reAdvancedDomainSyntax /^([^>]+?)(>>)?(\/.*)?$/ と normalizeHostnameValue の ASCII の所）
    static func normalizeTarget(_ raw: String, not: Bool) -> (ScriptletFilter.Target?, Bool) {
        if raw.hasPrefix("/") {
            guard raw.count > 2, raw.hasSuffix("/"),
                  (try? NSRegularExpression(pattern: String(raw.dropFirst().dropLast()))) != nil else { return (nil, true) }
            return (ScriptletFilter.Target(value: raw, not: not), false)
        }
        // ホスト・>>・/パス に分ける
        var host = Substring(raw), path: Substring = "", ancestor = false
        if let slash = host.firstIndex(of: "/") { path = host[slash...]; host = host[..<slash] }
        if host.hasSuffix(">>") { ancestor = true; host = host.dropLast(2) }
        if host.contains(">") { return (nil, true) }
        let h = host.lowercased()
        let ok = h == "*" || matches(reHostnameAscii, h) || matches(rePlainEntity, h)
        guard ok else { return (nil, true) }
        return (ScriptletFilter.Target(value: h + (ancestor ? ">>" : "") + path, not: not), false)
    }
}

/// uBO の ArglistParser（区切りは「,」。位置は UTF-16 で数える。JS の文字列と同じ）
struct ArglistParser {
    let separatorCode: UInt16 = 0x2C
    var actualSeparatorCode: UInt16 = 0x2C
    var quoteBeg = 0, quoteEnd = 0, argBeg = 0, argEnd = 0, separatorBeg = 0, separatorEnd = 0
    var transform = false

    static func isWS(_ c: UInt16) -> Bool {
        // JS の \s（よく出るもの）
        switch c {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        case 0x2000...0x200A: return true
        default: return false
        }
    }

    static func leftWS(_ p: [UInt16], from: Int) -> Int {
        var n = 0
        while from + n < p.count && isWS(p[from + n]) { n += 1 }
        return n
    }

    /// p[0..<end] の末尾の空白の数（uBO: /(?:^|\S)(\s+)$/）
    static func rightWS(_ p: [UInt16], end: Int) -> Int {
        var n = 0
        while end - n - 1 >= 0 && isWS(p[end - n - 1]) { n += 1 }
        return n
    }

    mutating func nextArg(_ pattern: [UInt16], _ beg: Int) -> ArglistParser {
        let len = pattern.count
        quoteBeg = beg + ArglistParser.leftWS(pattern, from: beg)
        let qc: UInt16 = quoteBeg < len ? pattern[quoteBeg] : 0
        if qc == 0x22 || qc == 0x27 || qc == 0x60 {
            indexOfNextArgSeparator(pattern, qc)
            if argEnd != len {
                quoteEnd = argEnd + 1
                separatorBeg = quoteEnd
                separatorEnd = quoteEnd
                separatorEnd += ArglistParser.leftWS(pattern, from: quoteEnd)
                if separatorEnd == len { return self }
                if pattern[separatorEnd] == separatorCode {
                    separatorEnd += 1
                    return self
                }
            }
        }
        indexOfNextArgSeparator(pattern, separatorCode)
        separatorBeg = argEnd
        separatorEnd = argEnd
        if separatorBeg < len { separatorEnd += 1 }
        argEnd -= ArglistParser.rightWS(pattern, end: separatorBeg)
        quoteEnd = argEnd
        return self
    }

    /// 「\区切り」の \ を外す（区切りは今の actualSeparator。uBO と同じく、引用符で囲んだ引数ならその引用符）
    func normalizeArg(_ arg: [UInt16]) -> String {
        let ch = actualSeparatorCode
        var s = arg
        var out: [UInt16] = []
        while let pos = s.lastIndex(of: ch) {
            out = Array(s[pos...]) + out
            s = Array(s[..<pos])
            var n = 0
            while n < s.count && s[s.count - 1 - n] == 0x5C { n += 1 }
            if n == 0 { continue }
            let tail = Array(repeating: UInt16(0x5C), count: (n & 1) != 0 ? n - 1 : n)
            out = tail + out
            s.removeLast(n)
        }
        let all = s + out
        return String(utf16CodeUnits: all, count: all.count)
    }

    private mutating func indexOfNextArgSeparator(_ pattern: [UInt16], _ code: UInt16) {
        argBeg = code != separatorCode ? quoteBeg + 1 : quoteBeg
        argEnd = argBeg
        transform = false
        actualSeparatorCode = code
        while argEnd < pattern.count {
            guard let pos = pattern[argEnd...].firstIndex(of: code) else { argEnd = pattern.count; return }
            // 前に奇数個の \ があれば、エスケープされた区切り
            var n = 0
            while pos - n - 1 >= 0 && pattern[pos - n - 1] == 0x5C { n += 1 }
            if n % 2 == 0 { argEnd = pos; return }
            transform = true
            argEnd = pos + 1
        }
    }
}

// MARK: 道具（uBO から作った JSON）

struct ScriptletLibrary {
    struct Item: Codable, Equatable {
        var name: String
        var aliases: [String]
        var requiresTrust: Bool
        var world: String
        var dependencies: [String]
        var priority: Int?
        var js: String
    }
    struct File: Codable {
        var format: Int
        var ubo: String
        var commit: String?
        var generated: String?
        var license: String?
        var notice: String?
        var source: String?
        var scriptlets: [Item]
    }

    let ubo: String
    let generated: String?
    private(set) var items: [String: Item] = [:]
    private(set) var aliases: [String: String] = [:]

    static let empty = ScriptletLibrary(ubo: "", generated: nil, items: [])

    init(ubo: String, generated: String?, items: [Item]) {
        self.ubo = ubo
        self.generated = generated
        for i in items {
            self.items[i.name] = i
            for a in i.aliases { aliases[a] = i.name }
        }
    }

    init(json: Data) throws {
        let f = try JSONDecoder().decode(File.self, from: json)
        guard f.format == 1 else { throw NSError(domain: "Vela", code: 1, userInfo: [NSLocalizedDescriptionKey: "知らない形式（format \(f.format)）"]) }
        self.init(ubo: f.ubo, generated: f.generated, items: f.scriptlets)
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// 落とした道具の大きさの上限
    static let maxBytes = 4 << 20

    enum UpdateError: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int)
        case badSignature
        case unreadable(String)
        case older(new: String, current: String)
        case empty
        var description: String {
            switch self {
            case .tooLarge(let n): return "大きすぎます（\(n / 1024)KB）"
            case .badSignature: return "署名が合いません"
            case .unreadable(let m): return "読めません（\(m)）"
            case .older(let a, let b): return "今のもの（\(b)）より古いものです（\(a)）"
            case .empty: return "道具が空です"
            }
        }
    }

    /// 署名を確かめた後の検査: 形式・中身があるか・前より古くないか（generated は ISO 8601 なので文字の順で比べられる）
    static func acceptUpdate(_ data: Data, current: ScriptletLibrary?) -> Result<ScriptletLibrary, UpdateError> {
        if data.count > maxBytes { return .failure(.tooLarge(data.count)) }
        let lib: ScriptletLibrary
        do { lib = try ScriptletLibrary(json: data) } catch { return .failure(.unreadable("\(error)")) }
        if lib.isEmpty { return .failure(.empty) }
        if let cur = current?.generated, let new = lib.generated, new < cur { return .failure(.older(new: new, current: cur)) }
        if current?.generated != nil && lib.generated == nil { return .failure(.older(new: "?", current: current!.generated!)) }
        return .success(lib)
    }

    /// redirect-engine の contentFromName（別名 → 本名。mime は名前の拡張子）
    func content(_ name: String, ext: String) -> Item? {
        let n = aliases[name] ?? name
        guard n.hasSuffix(ext), let i = items[n] else { return nil }
        return i
    }

    /// normalizeRawFilter の名前の所: "set" → "set-constant"（.js は付けない）。知らない名前はそのまま
    func canonicalToken(_ token: String) -> String {
        var t = token + ".js"
        if let a = aliases[t] { t = a }
        return String(t.dropLast(3))
    }

    /// その名前の道具（.js）が trusted のリストだけのものか
    func requiresTrust(_ token: String) -> Bool {
        content(token + ".js", ext: ".js")?.requiresTrust ?? false
    }

    func knows(_ token: String) -> Bool { content(token + ".js", ext: ".js") != nil }
}

// MARK: 入れて選ぶ（StaticExtFilteringHostnameDB と retrieve）

struct ScriptletIndex {
    /// ターゲット（/ を含まないもの）→ "+[…]" / "-[…]"
    private var byHostname: [String: [String]] = [:]
    private struct Matcher { let isRegex: Bool; let hn: String; let pn: String?; var list: [String] }
    private var matchers: [Matcher] = []
    private var matcherIndex: [String: Int] = [:]
    /// ホスト（正規表現なら ""）→ matcher の番号
    private var hostnameToMatchers: [String: [Int]] = [:]
    private var seen = Set<String>()

    private(set) var size = 0
    /// 道具に無い名前 → 数
    private(set) var unknown: [String: Int] = [:]
    /// trusted でないリストの requiresTrust の行・ドメイン無しの行（例外でない）・読めないドメイン
    private(set) var rejectedTrust = 0
    private(set) var rejectedGeneric = 0
    private(set) var badTargets = 0

    init() {}

    /// uBO の compile。trusted: 組み込みの信頼するリストから来た行か
    mutating func add(_ f: ScriptletFilter, trusted: Bool, library: ScriptletLibrary) {
        var args = f.args
        if !args.isEmpty { args[0] = library.canonicalToken(args[0]) }
        badTargets += f.badTargets
        if !args.isEmpty && !f.isException {
            if !trusted && library.requiresTrust(args[0]) { rejectedTrust += 1; return }
            if !library.knows(args[0]) { unknown[args[0], default: 0] += 1 }
        }
        let normalized = ScriptletIndex.json(args)
        if normalized == "[]" && !f.isException { return }
        if f.targets.isEmpty {
            if f.isException { store("", "-" + normalized) } else { rejectedGeneric += 1 }
            return
        }
        for t in f.targets {
            if f.isException && t.not { continue }
            store(t.value, (f.isException || t.not ? "-" : "+") + normalized)
        }
    }

    private mutating func store(_ target: String, _ s: String) {
        guard seen.insert(target + "\u{0}" + s).inserted else { return }      // 同じもの（uBO: duplicates）
        size += 1
        if target.contains("/") {
            if let i = matcherIndex[target] { matchers[i].list.append(s); return }
            let isRegex = target.hasPrefix("/")
            var hn = "", pn: String?
            if !isRegex {
                let slash = target.firstIndex(of: "/")!
                hn = String(target[..<slash]); pn = String(target[slash...])
            } else if let r = target.range(of: "\\/") {
                hn = String(target[target.index(after: target.startIndex)..<r.lowerBound]) + "$"
                pn = "^" + String(target[r.lowerBound..<target.index(before: target.endIndex)])
            } else {
                hn = String(target.dropFirst().dropLast())
            }
            matchers.append(Matcher(isRegex: isRegex, hn: hn, pn: pn, list: [s]))
            matcherIndex[target] = matchers.count - 1
            hostnameToMatchers[isRegex ? "" : hn, default: []].append(matchers.count - 1)
            return
        }
        byHostname[target, default: []].append(s)
    }

    struct Selection: Equatable {
        /// 呼び出し（正規化した JSON の引数の並び。例 ["json-prune","a b"]）
        var calls: [String] = []
        var exceptions: [String] = []
        /// #@#+js() でそのサイトの注入を全部止めた
        var disabled = false
        var isEmpty: Bool { calls.isEmpty }
    }

    /// uBO の retrieve。ancestors: 祖先のフレームの URL（近い順。Vela はトップだけ渡す）
    func retrieve(url: URL, ancestors: [URL] = []) -> Selection {
        guard size > 0, let hostname = url.host?.lowercased(), !hostname.isEmpty else { return Selection() }
        var all = Set<String>()
        retrieveSpecifics(&all, hostname)
        let entity = ScriptletIndex.entity(hostname)
        retrieveSpecifics(&all, entity)
        retrieveSpecificsByRegex(&all, hostname, url.absoluteString)
        for k in ["", "*"] { all.formUnion(byHostname[k] ?? []) }
        var visited: [String] = []
        for a in ancestors {
            guard let h = a.host?.lowercased(), !visited.contains(h) else { continue }
            visited.append(h)
            retrieveSpecifics(&all, h + ">>")
            let e = ScriptletIndex.entity(h)
            if !e.isEmpty { retrieveSpecifics(&all, e + ">>") }
        }
        if all.isEmpty { return Selection() }
        if all.contains("-[]") { return Selection(disabled: true) }
        var sel = Selection()
        for s in all where s.hasPrefix("+") {
            let body = String(s.dropFirst())
            if all.contains("-" + body) { sel.exceptions.append(body) } else { sel.calls.append(body) }
        }
        sel.calls.sort()
        sel.exceptions.sort()
        return sel
    }

    private func retrieveSpecifics(_ out: inout Set<String>, _ hostname: String) {
        var hn = Substring(hostname)
        if hn.isEmpty { return }
        while true {
            if let l = byHostname[String(hn)] { out.formUnion(l) }
            guard let dot = hn.firstIndex(of: ".") else { break }
            hn = hn[hn.index(after: dot)...]
            if hn == "*" { break }
        }
    }

    private func retrieveSpecificsByRegex(_ out: inout Set<String>, _ hostname: String, _ url: String) {
        if matchers.isEmpty { return }
        let pathname = ScriptletIndex.naivePathname(url) ?? ""
        var hn = Substring(hostname)
        while true {
            test(String(hn), &out, hostname, pathname)
            guard let dot = hn.firstIndex(of: ".") else { break }
            hn = hn[hn.index(after: dot)...]
        }
        test("", &out, hostname, pathname)
    }

    private func test(_ key: String, _ out: inout Set<String>, _ hostname: String, _ pathname: String) {
        for i in hostnameToMatchers[key] ?? [] {
            let m = matchers[i]
            let ok: Bool
            if !m.isRegex {
                ok = pathname.hasPrefix(m.pn ?? "")
            } else if !ScriptletIndex.regexTest(m.hn, hostname) {
                ok = false
            } else if let pn = m.pn {
                ok = ScriptletIndex.regexTest(pn, pathname)
            } else {
                ok = true
            }
            if ok { out.formUnion(m.list) }
        }
    }

    static func regexTest(_ pattern: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// uBO の naivePathnameFromURL（ホストの後の / から。? や # も含む）
    static func naivePathname(_ url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        guard let slash = url[r.upperBound...].firstIndex(of: "/") else { return nil }
        return String(url[slash...])
    }

    /// uBO の entityFromHostname（www.youtube.co.jp → www.youtube.*）
    static func entity(_ hostname: String) -> String {
        let domain = SiteUtil.registrableDomain(hostname)
        guard let dot = domain.firstIndex(of: "."), hostname.hasSuffix(domain) else { return "" }
        return String(hostname.dropLast(domain.count)) + String(domain[..<dot]) + ".*"
    }

    /// JSON.stringify(args)
    static func json(_ args: [String]) -> String {
        "[" + args.map(jsString).joined(separator: ",") + "]"
    }

    /// JSON.stringify(文字列) と同じ（" \ と制御文字だけをエスケープ）
    static func jsString(_ s: String) -> String {
        var o = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0C}": o += "\\f"
            default:
                if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) } else { o.unicodeScalars.append(ch) }
            }
        }
        return o + "\""
    }

    static func parseJSONArgs(_ s: String) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String] ?? []
    }

    /// uBO の decompile（ログ用。##+js(…) の形に戻す）
    static func decompile(_ json: String, isException: Bool) -> String {
        let args = parseJSONArgs(json)
        func requote(_ s: String) -> String {
            let needs = s.isEmpty || s.contains(",") || (s.count >= 2 && ["\"", "'", "`"].contains(where: { s.hasPrefix($0) && s.hasSuffix($0) }))
            if !needs { return s }
            if !s.contains("'") { return "'\(s)'" }
            if !s.contains("\"") { return "\"\(s)\"" }
            if !s.contains("`") { return "`\(s)`" }
            return "'" + s.replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        return (isException ? "#@#" : "##") + "+js(" + args.map(requote).joined(separator: ", ") + ")"
    }
}

// MARK: 組み立てる

enum ScriptletAssembler {
    struct Output: Equatable {
        /// ページの JS と同じ所（WKContentWorld.page）で動かすもの
        var main: String
        /// ページから見えない所（WKContentWorld.defaultClient）で動かすもの
        var isolated: String
        /// 入れたルール（ログ用）
        var filters: [String]
        var isEmpty: Bool { main.isEmpty && isolated.isEmpty }
    }

    private struct Entry { let code: String; let priority: Int? }

    /// frames: (ホスト, そのフレームで選んだもの)。同じホストは最初のものだけ
    static func assemble(_ frames: [(host: String, selection: ScriptletIndex.Selection)], library: ScriptletLibrary) -> Output {
        var mainDefs: [String: String] = [:], isoDefs: [String: String] = [:]
        var mainBlocks: [String] = [], isoBlocks: [String] = []
        var filters: [String] = []
        var hosts = Set<String>()
        for (host, sel) in frames where !sel.disabled && hosts.insert(host).inserted {
            var mainCalls: [String: Entry] = [:], isoCalls: [String: Entry] = [:]
            for token in sel.calls {
                lookup(token, library: library, mainDefs: &mainDefs, isoDefs: &isoDefs, mainCalls: &mainCalls, isoCalls: &isoCalls)
            }
            if let b = block(host, mainCalls) { mainBlocks.append(b) }
            if let b = block(host, isoCalls) { isoBlocks.append(b) }
            filters += sel.calls.map { "\(host)" + ScriptletIndex.decompile($0, isException: false) }
            filters += sel.exceptions.map { "\(host)" + ScriptletIndex.decompile($0, isException: true) }
        }
        return Output(main: wrap(mainDefs, mainBlocks), isolated: wrap(isoDefs, isoBlocks), filters: filters)
    }

    /// uBO の lookupScriptlet
    private static func lookup(_ rawToken: String, library: ScriptletLibrary,
                               mainDefs: inout [String: String], isoDefs: inout [String: String],
                               mainCalls: inout [String: Entry], isoCalls: inout [String: Entry]) {
        if mainCalls[rawToken] != nil || isoCalls[rawToken] != nil { return }
        let args = ScriptletIndex.parseJSONArgs(rawToken)
        guard let first = args.first else { return }
        let token = first + ".js"
        guard let details = library.content(token, ext: ".js") else { return }
        let isolated = details.world == "ISOLATED"
        let fname = functionName(details.js)
        let content = patch(fname, details.js, Array(args.dropFirst()))
        var defs = isolated ? isoDefs : mainDefs
        if fname != nil { defs[token] = details.js }
        var deps = details.dependencies
        while !deps.isEmpty {
            let d = deps.removeFirst()
            if defs[d] != nil { continue }
            guard let dd = library.content(d, ext: ".fn") ?? library.content(d, ext: ".js") else { continue }
            defs[d] = dd.js
            deps += dd.dependencies
        }
        let entry = Entry(code: "try {\n\t\(content)\n} catch (e) {\n\n}", priority: details.priority ?? 0)
        if isolated { isoDefs = defs; isoCalls[rawToken] = entry } else { mainDefs = defs; mainCalls[rawToken] = entry }
    }

    /// uBO: /^function\s+([^(\s]+)\s*\(/
    static func functionName(_ js: String) -> String? {
        guard js.hasPrefix("function") else { return nil }
        var rest = js.dropFirst("function".count)
        guard let f = rest.first, f.isWhitespace else { return nil }
        rest = rest.drop(while: { $0.isWhitespace })
        let name = rest.prefix(while: { $0 != "(" && !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        let after = rest.dropFirst(name.count).drop(while: { $0.isWhitespace })
        return after.first == "(" ? String(name) : nil
    }

    /// uBO の patchScriptlet（名前のある関数なら「名前(引数);」。名前の無いものは {{1}} などを埋める）
    static func patch(_ fname: String?, _ content: String, _ args: [String]) -> String {
        var c = content
        if let fname {
            c = "\(fname)({{args}});"
        } else {
            for (i, a) in args.enumerated() {
                if let r = c.range(of: "{{\(i + 1)}}") { c.replaceSubrange(r, with: a) }
            }
        }
        let json = ScriptletIndex.json(args)
        if let r = c.range(of: "{{args}}") { c.replaceSubrange(r, with: String(json.dropFirst().dropLast())) }
        return c
    }

    /// uBO の sortedCalls と同じ並べ方（priority の高いもの → 中身の順）
    private static func block(_ host: String, _ calls: [String: Entry]) -> String? {
        if calls.isEmpty { return nil }
        let sorted = calls.values.sorted { a, b in
            let ap = a.priority ?? 0, bp = b.priority ?? 0
            return ap == bp ? a.code < b.code : ap > bp
        }.map { $0.code }
        return "if (location.hostname === \(ScriptletIndex.jsString(host))) {\n" + sorted.joined(separator: "\n\n") + "\n}"
    }

    private static func wrap(_ defs: [String: String], _ blocks: [String]) -> String {
        if blocks.isEmpty { return "" }
        // 依存の関数（とクラス）を先に。クラスは巻き上げられないので、呼び出しより前に置く
        let d = defs.values.sorted()
        return [
            "(function() {",
            "// >>>> start of private namespace",
            "",
            ";",
            "",
            "const scriptletGlobals = {};",
            "",
            d.joined(separator: "\n\n"),
            "",
            blocks.joined(separator: "\n\n"),
            "",
            "// <<<< end of private namespace",
            "})();",
        ].joined(separator: "\n")
    }
}

// MARK: 自己テストのページ（開発者パネルの ScriptletSelfTest が WKWebView で、単体テストが Chrome で開く）

enum ScriptletSelfTestPage {
    static let host = "vela-selftest.invalid"

    /// テスト用のルール（このテストの中だけ信頼する）
    static let rules = """
    vela-selftest.invalid##+js(json-prune, adPlacements playerAds)
    vela-selftest.invalid##+js(set, ytInitialPlayerResponse.adSlots, undefined)
    vela-selftest.invalid##+js(trusted-edit-inbound-object, JSON.stringify, 0, [?.context].context.client+={"clientScreen":"CHANNEL"})
    vela-selftest.invalid##+js(trusted-rpfr, '"fetchAdSlots"', '"no_ads"', blob:)
    vela-selftest.invalid##+js(json-prune-fetch-response, fetchAdPlacements, , propsToMatch, blob:)
    vela-selftest.invalid##+js(trusted-replace-xhr-response, '"xhrAdSlots"', '"no_ads"', blob:)
    vela-selftest.invalid##+js(json-prune-xhr-response, xhrAdPlacements, , propsToMatch, blob:)
    vela-selftest.invalid##+js(rmnt, script, VELA_RMNT_MARK)
    vela-selftest.invalid##+js(rpnt, script, __velaRpnt = 1, __velaRpnt = 2)
    vela-selftest.invalid##+js(trusted-prevent-dom-bypass, Node.prototype.appendChild, fetch)
    """

    /// ページの中のテスト（結果は velaSelfTest に送る）
    static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <script>window.__velaRmnt = 1; /* VELA_RMNT_MARK */</script>
    <script>window.__velaRpnt = 1;</script>
    </head><body>
    <script>
    (async function () {
      const out = [];
      const t = (name, ok, detail) => out.push({ name, ok: !!ok, detail: String(detail ?? '') });
      const blobURL = (obj) => URL.createObjectURL(new Blob([JSON.stringify(obj)], { type: 'application/json' }));
      const xhr = (u, type) => new Promise((res) => {
        const x = new XMLHttpRequest();
        x.open('GET', u);
        if (type) x.responseType = type;
        x.onload = () => res(type === 'json' ? x.response : x.responseText);
        x.onerror = () => res(null);
        x.send();
      });
      try {
        const p = JSON.parse('{"adPlacements":[1],"playerAds":[2],"keep":1}');
        t('json-prune（JSON.parse）', p.adPlacements === undefined && p.playerAds === undefined && p.keep === 1, JSON.stringify(p));
      } catch (e) { t('json-prune（JSON.parse）', false, e); }
      try {
        window.ytInitialPlayerResponse = { adSlots: [1], keep: 1 };
        const y = window.ytInitialPlayerResponse;
        t('set-constant（後から入れたオブジェクトの中）', y && y.adSlots === undefined && y.keep === 1, JSON.stringify(y));
      } catch (e) { t('set-constant', false, e); }
      try {
        const s = JSON.stringify({ context: { client: { clientName: 'WEB' } } });
        t('trusted-edit-inbound-object（送る JSON を変える）', s.includes('"clientScreen":"CHANNEL"'), s);
      } catch (e) { t('trusted-edit-inbound-object', false, e); }
      try {
        const txt = await (await fetch(blobURL({ fetchAdSlots: [1], keep: 1 }))).text();
        t('trusted-replace-fetch-response（fetch の中身）', txt.includes('"no_ads"') && !txt.includes('"fetchAdSlots"'), txt);
      } catch (e) { t('trusted-replace-fetch-response', false, e); }
      try {
        const j = await (await fetch(blobURL({ fetchAdPlacements: [1], keep: 1 }))).json();
        t('json-prune-fetch-response（Response.json）', j.fetchAdPlacements === undefined && j.keep === 1, JSON.stringify(j));
      } catch (e) { t('json-prune-fetch-response', false, e); }
      try {
        const txt = await xhr(blobURL({ xhrAdSlots: [1], keep: 1 }), '');
        t('trusted-replace-xhr-response（XHR の文字）', txt && txt.includes('"no_ads"') && !txt.includes('"xhrAdSlots"'), txt);
      } catch (e) { t('trusted-replace-xhr-response', false, e); }
      try {
        const j = await xhr(blobURL({ xhrAdPlacements: [1], keep: 1 }), 'json');
        t('json-prune-xhr-response（XHR の json）', j && j.xhrAdPlacements === undefined && j.keep === 1, JSON.stringify(j));
      } catch (e) { t('json-prune-xhr-response', false, e); }
      t('remove-node-text（isolated world・script の中を消す）', window.__velaRmnt === undefined, window.__velaRmnt);
      t('trusted-replace-node-text（isolated world・script の中を書き換える）', window.__velaRpnt === 2, window.__velaRpnt);
      try {
        const f = document.createElement('iframe');
        document.body.appendChild(f);
        t('trusted-prevent-dom-bypass（iframe から元の fetch を取らせない）', f.contentWindow.fetch === window.fetch, '');
        f.remove();
      } catch (e) { t('trusted-prevent-dom-bypass', false, e); }
      t('道具の中の関数がページから見えない（private namespace）', typeof window.jsonPrune === 'undefined' && typeof window.safeSelf === 'undefined', '');
      window.webkit.messageHandlers.velaSelfTest.postMessage(out);
    })();
    </script></body></html>
    """#

    /// テスト用のルールを今の道具で組み立てる
    static func assemble(library: ScriptletLibrary) -> (output: ScriptletAssembler.Output, unknown: [String: Int]) {
        var idx = ScriptletIndex()
        for f in ABPParser.parse(rules).scriptlets { idx.add(f, trusted: true, library: library) }
        let sel = idx.retrieve(url: URL(string: "https://\(host)/")!)
        return (ScriptletAssembler.assemble([(host, sel)], library: library), idx.unknown)
    }

    /// Chrome で開く形（world が無いので、両方ともページの先頭に入れる。結果は #vela-result に書く）。tools/ubo/test_assembled.mjs が使う
    static func chromeHarness(_ out: ScriptletAssembler.Output) -> String {
        let harness = "<script>window.webkit={messageHandlers:{velaSelfTest:{postMessage:function(r){var p=document.createElement('pre');p.id='vela-result';p.textContent=JSON.stringify(r);document.documentElement.appendChild(p);}}}};</script>"
        func tag(_ js: String) -> String { js.isEmpty ? "" : "<script>" + js.replacingOccurrences(of: "</script", with: "<\\/script") + "</script>" }
        let head = "<head><meta charset=\"utf-8\">"
        return page.replacingOccurrences(of: head, with: head + harness + tag(out.main) + tag(out.isolated))
    }
}
