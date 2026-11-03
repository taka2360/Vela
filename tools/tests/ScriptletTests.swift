import Foundation

// MARK: - スクリプトレット（##+js）のテスト。uBO 1.75.2 と同じに読む・選ぶ・組み立てるか
// 道具は resources/ubo-scriptlets.json（uBO のソースから作ったもの）、行は tools/ubo/fixtures/youtube.txt（本物のリストから写したもの）

private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func realLibrary() -> ScriptletLibrary {
    let d = try! Data(contentsOf: projectRoot.appendingPathComponent("resources/ubo-scriptlets.json"))
    return try! ScriptletLibrary(json: d)
}

private func youtubeLines() -> String {
    try! String(contentsOf: projectRoot.appendingPathComponent("tools/ubo/fixtures/youtube.txt"), encoding: .utf8)
}

func scriptletTests() {
    print("Scriptlet")
    let lib = realLibrary()

    test("引数: 区切り・空白・空の引数・最後の , ") {
        expectEqual(ScriptletParser.arguments("json-prune, a b, , propsToMatch, /x/"), ["json-prune", "a b", "", "propsToMatch", "/x/"])
        expectEqual(ScriptletParser.arguments("set.js, a.b, undefined"), ["set", "a.b", "undefined"])
        expectEqual(ScriptletParser.arguments("nobab"), ["nobab"])
        expectEqual(ScriptletParser.arguments(""), [])
        expectEqual(ScriptletParser.arguments("x, a,"), ["x", "a"])
        expectEqual(ScriptletParser.arguments("x,  ,b"), ["x", "", "b"])
    }

    test("引数: \\, と引用符（uBO の ArglistParser と同じ）") {
        expectEqual(ScriptletParser.arguments(#"rmnt, script, window\,"fetch""#), ["rmnt", "script", #"window,"fetch""#])
        expectEqual(ScriptletParser.arguments(#"trusted-rpfr, '"adPlacements"', '"no_ads"', player?"#), ["trusted-rpfr", #""adPlacements""#, #""no_ads""#, "player?"])
        expectEqual(ScriptletParser.arguments(#"x, 'it\'s', "a,b""#), ["x", "it's", "a,b"])
        // 引用符の後に区切りが無ければ、引用符も含めた普通の引数
        expectEqual(ScriptletParser.arguments(#"x, 'a'b, c"#), ["x", "'a'b", "c"])
        // \\, は \ と区切り
        expectEqual(ScriptletParser.arguments(#"x, a\\, b"#), ["x", #"a\\"#, "b"])
        expectEqual(ScriptletParser.arguments(#"x, /"adPlacements.*?([A-Z]"\}|"\}{2\,4})\}\]\,/, , /p/"#),
                    ["x", #"/"adPlacements.*?([A-Z]"\}|"\}{2,4})\}\],/"#, "", "/p/"])
    }

    test("行: ドメイン・例外・読めないドメイン・スクリプトレットでない行") {
        let f = ScriptletParser.parse("m.youtube.com,~music.youtube.com,youtube.*,a.com/watch,b.com>>,/^x\\d+\\.com$/##+js(set, a, 1)")!
        expectEqual(f.args, ["set", "a", "1"])
        expectEqual(f.targets.map { $0.value }, ["m.youtube.com", "music.youtube.com", "youtube.*", "a.com/watch", "b.com>>", "/^x\\d+\\.com$/"])
        expectEqual(f.targets.map { $0.not }, [false, true, false, false, false, false])
        expect(!f.isException)
        let e = ScriptletParser.parse("example.org#@#+js()")!
        expect(e.isException && e.args.isEmpty)
        expectEqual(ScriptletParser.parse("日本.jp,a.com##+js(x)")!.badTargets, 1)
        expect(ScriptletParser.parse("example.com##.ad") == nil)
        expect(ScriptletParser.parse("example.com#$#abort-on-property-read x") == nil)
        expect(ScriptletParser.parse("example.com##+js(x") == nil)
        if case .scriptlet = ABPParser.parseLine("a.com##+js(nobab)") {} else { expect(false, "ABPParser が scriptlet にしない") }
    }

    test("本物の YouTube の行が全部読める・道具が全部ある") {
        let p = ABPParser.parse(youtubeLines())
        expectEqual(p.unsupported, 0)
        expect(p.scriptlets.count >= 30, "\(p.scriptlets.count)")
        var idx = ScriptletIndex()
        for s in p.scriptlets { idx.add(s, trusted: true, library: lib) }
        expectEqual(idx.unknown, [:])
        expectEqual(idx.rejectedTrust, 0)
        // 長い JS の入った rpnt も、引数が 3 つに分かれる
        let rpnt = p.scriptlets.first { $0.args.first == "rpnt" }!
        expect(rpnt.args[3].hasPrefix("(()=>{if(\"YOUTUBE_PREMIUM_LOGO\""))
        expectEqual(Array(rpnt.args[4...]), ["sedCount", "1", "excludes", "MutationObserver", "condition", "/serverContract|js_ld/"])
        let edit = p.scriptlets.first { $0.args.first == "trusted-edit-inbound-object" }!
        expectEqual(Array(edit.args.prefix(3)), ["trusted-edit-inbound-object", "JSON.stringify", "0"])
        expect(edit.args[3].hasPrefix("[?.attestationRequest]"))
    }

    test("名前の正規化（別名・.js）と trusted") {
        expectEqual(lib.canonicalToken("set"), "set-constant")
        expectEqual(lib.canonicalToken("rmnt"), "remove-node-text")
        expectEqual(lib.canonicalToken("rpnt"), "trusted-replace-node-text")
        expectEqual(lib.canonicalToken("trusted-rpfr"), "trusted-replace-fetch-response")
        expectEqual(lib.canonicalToken("nostif"), "prevent-setTimeout")
        expectEqual(lib.canonicalToken("json-prune"), "json-prune")
        expectEqual(lib.canonicalToken("zzz"), "zzz")
        expect(lib.requiresTrust("trusted-replace-fetch-response"))
        expect(lib.requiresTrust("trusted-replace-node-text"))
        expect(!lib.requiresTrust("json-prune"))
        // 信頼しないリストからの trusted の行は入れない（例外は入れる）
        var idx = ScriptletIndex()
        idx.add(ScriptletParser.parse("a.com##+js(trusted-rpfr, x, y)")!, trusted: false, library: lib)
        idx.add(ScriptletParser.parse("a.com##+js(rpnt, script, x, y)")!, trusted: false, library: lib)
        idx.add(ScriptletParser.parse("a.com##+js(json-prune, ads)")!, trusted: false, library: lib)
        expectEqual(idx.rejectedTrust, 2)
        expectEqual(idx.retrieve(url: url("https://a.com/")).calls, [#"["json-prune","ads"]"#])
        // 知らない名前は数える
        idx.add(ScriptletParser.parse("a.com##+js(brand-new-thing, 1)")!, trusted: true, library: lib)
        expectEqual(idx.unknown, ["brand-new-thing": 1])
    }

    test("選ぶ: 親ドメイン・entity・~・ドメイン無し・例外") {
        var idx = ScriptletIndex()
        for l in [
            "youtube.com##+js(json-prune, a)",
            "youtube.*##+js(json-prune, b)",
            "youtube.com,~music.youtube.com##+js(json-prune, c)",
            "##+js(json-prune, generic)",
            "*##+js(json-prune, star)",
            "#@#+js(json-prune, star)",
            "www.youtube.com#@#+js(json-prune, a)",
        ] { idx.add(ScriptletParser.parse(l)!, trusted: true, library: lib) }
        expectEqual(idx.rejectedGeneric, 1)
        let www = idx.retrieve(url: url("https://www.youtube.com/watch?v=1"))
        expectEqual(www.calls, [#"["json-prune","b"]"#, #"["json-prune","c"]"#])
        expectEqual(www.exceptions, [#"["json-prune","a"]"#, #"["json-prune","star"]"#])
        let music = idx.retrieve(url: url("https://music.youtube.com/"))
        expectEqual(music.calls, [#"["json-prune","a"]"#, #"["json-prune","b"]"#])
        // entity は登録できるドメインの名前.*（youtube.co.jp も youtube.*）
        expectEqual(ScriptletIndex.entity("www.youtube.co.jp"), "www.youtube.*")
        expectEqual(ScriptletIndex.entity("youtube.com"), "youtube.*")
        expectEqual(idx.retrieve(url: url("https://www.youtube.co.jp/")).calls, [#"["json-prune","b"]"#])
        expect(idx.retrieve(url: url("https://example.com/")).calls.isEmpty)
    }

    test("選ぶ: #@#+js() でそのサイトは全部止める") {
        var idx = ScriptletIndex()
        idx.add(ScriptletParser.parse("a.com##+js(json-prune, x)")!, trusted: true, library: lib)
        idx.add(ScriptletParser.parse("sub.a.com#@#+js()")!, trusted: true, library: lib)
        expect(!idx.retrieve(url: url("https://a.com/")).disabled)
        let s = idx.retrieve(url: url("https://sub.a.com/"))
        expect(s.disabled && s.calls.isEmpty)
    }

    test("選ぶ: パス・正規表現・祖先（>>）") {
        var idx = ScriptletIndex()
        for l in [
            "a.com/watch##+js(json-prune, path)",
            #"/^x\d+\.com$/##+js(json-prune, re)"#,
            #"/^y\.com\/v\d+/##+js(json-prune, repath)"#,
            "top.com>>##+js(json-prune, anc)",
        ] { idx.add(ScriptletParser.parse(l)!, trusted: true, library: lib) }
        expectEqual(idx.retrieve(url: url("https://a.com/watch?v=1")).calls, [#"["json-prune","path"]"#])
        expectEqual(idx.retrieve(url: url("https://sub.a.com/watch")).calls, [#"["json-prune","path"]"#])
        expect(idx.retrieve(url: url("https://a.com/other")).calls.isEmpty)
        expectEqual(idx.retrieve(url: url("https://x12.com/")).calls, [#"["json-prune","re"]"#])
        expect(idx.retrieve(url: url("https://x.com/")).calls.isEmpty)
        expectEqual(idx.retrieve(url: url("https://y.com/v12/z")).calls, [#"["json-prune","repath"]"#])
        expect(idx.retrieve(url: url("https://y.com/w/z")).calls.isEmpty)
        expectEqual(idx.retrieve(url: url("https://frame.net/"), ancestors: [url("https://www.top.com/")]).calls, [#"["json-prune","anc"]"#])
        expect(idx.retrieve(url: url("https://frame.net/")).calls.isEmpty)
    }

    test("組み立て: 依存は 1 回・main と isolated・ホストのガード・(function(){…})();") {
        var idx = ScriptletIndex()
        for l in [
            "a.com##+js(json-prune, x)",
            "a.com##+js(json-prune, y)",
            "a.com##+js(rmnt, script, ads)",
            "b.com##+js(json-prune, z)",
        ] { idx.add(ScriptletParser.parse(l)!, trusted: true, library: lib) }
        let out = ScriptletAssembler.assemble([
            ("a.com", idx.retrieve(url: url("https://a.com/"))),
            ("b.com", idx.retrieve(url: url("https://b.com/"))),
        ], library: lib)
        expect(out.main.hasPrefix("(function() {") && out.main.hasSuffix("})();"))
        expect(out.isolated.hasPrefix("(function() {") && out.isolated.hasSuffix("})();"))
        func count(_ s: String, _ sub: String) -> Int { s.components(separatedBy: sub).count - 1 }
        expectEqual(count(out.main, "function jsonPrune("), 1)
        expectEqual(count(out.main, "function safeSelf("), 1)
        expectEqual(count(out.main, "jsonPrune(\"x\");"), 1)
        expectEqual(count(out.main, "if (location.hostname === \"a.com\")"), 1)
        expectEqual(count(out.main, "if (location.hostname === \"b.com\")"), 1)
        // remove-node-text は isolated world の道具
        expect(out.isolated.contains("removeNodeText(\"script\",\"ads\");"))
        expect(!out.main.contains("removeNodeText(\"script\""))
        expectEqual(out.filters.count, 4)
        expect(out.filters.contains("a.com##+js(rmnt, script, ads)") || out.filters.contains("a.com##+js(remove-node-text, script, ads)"))
        // 何も無ければ空
        expect(ScriptletAssembler.assemble([("c.com", ScriptletIndex.Selection())], library: lib).isEmpty)
    }

    test("組み立て: patch（名前の無い道具の {{1}}）と関数の名前") {
        expectEqual(ScriptletAssembler.functionName("function jsonPrune(a) {}"), "jsonPrune")
        expectEqual(ScriptletAssembler.functionName("function  x  (a) {}"), "x")
        expectEqual(ScriptletAssembler.functionName("class A {}"), nil)
        expectEqual(ScriptletAssembler.functionName("(function() {})()"), nil)
        expectEqual(ScriptletAssembler.patch("f", "function f(){}", ["a", "b\"c"]), #"f("a","b\"c");"#)
        expectEqual(ScriptletAssembler.patch(nil, "x({{1}}, {{2}}); y({{args}})", ["p", "q"]), #"x(p, q); y("p","q")"#)
    }

    test("組み立て: www.youtube.com の本物の行で、node のテストに渡す JS を書く") {
        var idx = ScriptletIndex()
        for s in ABPParser.parse(youtubeLines()).scriptlets { idx.add(s, trusted: true, library: lib) }
        // テスト用のホストのルール（node のテストが中身の動きを確かめる）
        let selftest = try! String(contentsOf: projectRoot.appendingPathComponent("tools/ubo/fixtures/selftest.txt"), encoding: .utf8)
        for s in ABPParser.parse(selftest).scriptlets { idx.add(s, trusted: true, library: lib) }
        let yt = idx.retrieve(url: url("https://www.youtube.com/watch?v=x"))
        expect(yt.calls.count >= 20, "\(yt.calls.count)")
        let out = ScriptletAssembler.assemble([
            ("www.youtube.com", yt),
            ("vela-selftest.invalid", idx.retrieve(url: url("https://vela-selftest.invalid/"))),
        ], library: lib)
        expect(!out.main.isEmpty && !out.isolated.isEmpty)
        let dir = projectRoot.appendingPathComponent("tools/ubo/.out", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(out.main.utf8).write(to: dir.appendingPathComponent("main.js"))
        try? Data(out.isolated.utf8).write(to: dir.appendingPathComponent("isolated.js"))
        try? Data(out.filters.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("filters.txt"))
    }

    test("道具の更新を受け取るか: 形式・空・古い版") {
        func file(_ generated: String?, format: Int = 1, items: Int = 1) -> Data {
            let s = (0..<items).map { _ in #"{"name":"a.js","aliases":[],"requiresTrust":false,"world":"MAIN","dependencies":[],"priority":null,"js":"function a(){}"}"# }
            let g = generated.map { "\"\($0)\"" } ?? "null"
            return Data(#"{"format":\#(format),"ubo":"1.0","generated":\#(g),"scriptlets":[\#(s.joined(separator: ","))]}"#.utf8)
        }
        let cur = try! ScriptletLibrary(json: file("2026-11-02T00:00:00.000Z"))
        if case .success(let l) = ScriptletLibrary.acceptUpdate(file("2026-11-03T00:00:00.000Z"), current: cur) { expectEqual(l.count, 1) } else { expect(false) }
        if case .failure(let e) = ScriptletLibrary.acceptUpdate(file("2026-11-01T00:00:00.000Z"), current: cur) {
            expectEqual(e, .older(new: "2026-11-01T00:00:00.000Z", current: "2026-11-02T00:00:00.000Z"))
        } else { expect(false, "古い版を受け取った") }
        if case .failure(.unreadable) = ScriptletLibrary.acceptUpdate(file("x", format: 2), current: nil) {} else { expect(false, "format 2") }
        if case .failure(.empty) = ScriptletLibrary.acceptUpdate(file("x", items: 0), current: nil) {} else { expect(false, "空") }
        if case .failure(.unreadable) = ScriptletLibrary.acceptUpdate(Data("<html>".utf8), current: nil) {} else { expect(false, "html") }
        // 本物の JSON は読める
        if case .success(let l) = ScriptletLibrary.acceptUpdate(try! Data(contentsOf: projectRoot.appendingPathComponent("resources/ubo-scriptlets.json")), current: nil) {
            expect(l.count > 150)
        } else { expect(false, "本物") }
    }

    test("リストの一覧: 組み込みは一覧で上書き・trusted は一覧の id と URL が合うものだけ") {
        // 保存ファイルで URL を書き換えても、組み込みのものは一覧の URL に戻る
        var evil = FilterListInfo(id: "ublock-quick-fixes", name: "x", url: "https://evil.example/list.txt", enabled: true, builtIn: true)
        evil.lastUpdated = Date(timeIntervalSince1970: 1)
        let fake = FilterListInfo(id: "ublock-fake", name: "y", url: "https://evil.example/2.txt", enabled: true, builtIn: true)
        let m = FilterCatalog.merge(saved: [evil, fake])
        let qf = m.first { $0.id == "ublock-quick-fixes" }!
        expectEqual(qf.url, "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")
        expectEqual(qf.lastUpdated, Date(timeIntervalSince1970: 1))
        expect(FilterCatalog.isTrusted(qf))
        // 一覧に無い「組み込み」は自分で足したもの扱い・信頼しない
        let f = m.first { $0.id == "ublock-fake" }!
        expect(!f.builtIn && !FilterCatalog.isTrusted(f))
        expect(!FilterCatalog.isTrusted(evil))
        expect(!FilterCatalog.isTrusted(m.first { $0.id == "easylist" }!))
        // 足りない組み込みは足す
        expectEqual(Set(m.map { $0.id }), Set(FilterCatalog.lists.map { $0.id } + ["ublock-fake"]))
        // 古い adblock.json（scriptletRules などが無い）も読める
        let old = #"{"lists":[{"id":"easylist","name":"E","url":"u","enabled":true,"builtIn":true,"networkRules":1,"cosmeticRules":2,"unsupported":3}]}"#
        let st = try JSONDecoder().decode(AdBlockState.self, from: Data(old.utf8))
        expectEqual(st.lists.first?.scriptletRules, nil)
        expectEqual(st.scriptletsChecked, nil)
    }

    test("自己テストのページ: ルールが全部読めて、Chrome で開く形を書く") {
        let parsed = ABPParser.parse(ScriptletSelfTestPage.rules)
        expectEqual(parsed.unsupported, 0)
        let (out, unknown) = ScriptletSelfTestPage.assemble(library: lib)
        expectEqual(unknown, [:])
        expectEqual(out.filters.count, parsed.scriptlets.count)
        expect(!out.main.isEmpty && !out.isolated.isEmpty)
        let html = ScriptletSelfTestPage.chromeHarness(out)
        expect(html.contains("vela-result") && html.contains(out.main.prefix(40)))
        let dir = projectRoot.appendingPathComponent("tools/ubo/.out", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(html.utf8).write(to: dir.appendingPathComponent("selftest.html"))
    }

    test("decompile（ログの形）") {
        expectEqual(ScriptletIndex.decompile(#"["json-prune","a b",""]"#, isException: false), "##+js(json-prune, a b, '')")
        expectEqual(ScriptletIndex.decompile(#"["x","a,b"]"#, isException: true), "#@#+js(x, 'a,b')")
    }
}
