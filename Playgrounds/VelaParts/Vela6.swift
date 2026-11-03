// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 6 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import PhotosUI
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

// ======================================================================
// MARK: - ScriptletVerify.swift
// ======================================================================

// MARK: - 落とした道具（resources/ubo-scriptlets.json）が本物かを確かめる
//
// GitHub Actions が uBO のソースから作って Ed25519 で署名したものだけを受け取る（tools/ubo/build_scriptlets.mjs）。
// 秘密鍵は Actions の Secrets にだけある。公開鍵はここに埋め込む（tools/ubo/keygen.mjs が出したもの）。
// 署名の後に、形式・大きさ・前より古くないか（ScriptletLibrary.acceptUpdate）も確かめる

enum ScriptletVerify {
    /// Ed25519 の公開鍵（32 バイトの base64）。tools/ubo/verify.mjs もここを読む
    static let publicKeyBase64 = "4z7T7t38qr+xB8738lQD+r2cStOVyyumyj8Txk0MPwk="

    /// 署名が合えば true。sig は base64（前後の空白・改行は無視）
    static func isValidSignature(_ data: Data, signature sig: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: sig.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sigData, for: data)
    }

    /// 署名と中身を確かめて、使える道具を返す。だめなら理由
    static func verify(_ data: Data, signature sig: String, current: ScriptletLibrary?) -> Result<ScriptletLibrary, ScriptletLibrary.UpdateError> {
        if data.count > ScriptletLibrary.maxBytes { return .failure(.tooLarge(data.count)) }
        guard isValidSignature(data, signature: sig) else { return .failure(.badSignature) }
        return ScriptletLibrary.acceptUpdate(data, current: current)
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
