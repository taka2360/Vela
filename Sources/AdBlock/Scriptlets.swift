import Foundation

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
