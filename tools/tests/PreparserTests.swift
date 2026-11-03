import Foundation

// MARK: - リストの前処理（!#if・!#include・Expires）のテスト。uBO 1.75.2 の preparser と同じ動きか

func preparserTests() {
    print("Preparser")
    let env = ["ublock"]

    test("!#if の名前: 知っている・知らない・cap_・打ち消し") {
        expectEqual(FilterPreparser.evaluateToken("ext_ublock", env), true)
        expectEqual(FilterPreparser.evaluateToken("!ext_ublock", env), false)
        expectEqual(FilterPreparser.evaluateToken("ext_ubol", env), false)
        expectEqual(FilterPreparser.evaluateToken("!ext_ubol", env), true)
        expectEqual(FilterPreparser.evaluateToken("env_safari", env), false)
        expectEqual(FilterPreparser.evaluateToken("env_mobile", env), false)
        expectEqual(FilterPreparser.evaluateToken("env_mobile", ["ublock", "mobile"]), true)
        // 'false' の値: 打ち消すと真
        expectEqual(FilterPreparser.evaluateToken("false", env), false)
        expectEqual(FilterPreparser.evaluateToken("!false", env), true)
        expectEqual(FilterPreparser.evaluateToken("ext_abp", env), false)
        expectEqual(FilterPreparser.evaluateToken("!adguard_app_ios", env), true)
        // 知らない名前は判定しない。cap_ で始まるものだけ偽
        expectEqual(FilterPreparser.evaluateToken("env_unknown", env), nil)
        expectEqual(FilterPreparser.evaluateToken("cap_user_stylesheet", env), false)
        expectEqual(FilterPreparser.evaluateToken("!cap_user_stylesheet", env), true)
        expectEqual(FilterPreparser.evaluateToken("cap_html_filtering", env), false)
    }

    test("!#if の式: && と || は左から、括弧は全体だけ") {
        expectEqual(FilterPreparser.evaluateExpr("ext_ublock && !env_mobile", env), true)
        expectEqual(FilterPreparser.evaluateExpr("env_firefox || env_chromium", env), false)
        expectEqual(FilterPreparser.evaluateExpr("(env_firefox || ext_ublock)", env), true)
        expectEqual(FilterPreparser.evaluateExpr("env_firefox || ext_ublock && false", env), false)
        // 知らない名前が続く所は判定しない
        expectEqual(FilterPreparser.evaluateExpr("ext_ublock && env_zzz", env), nil)
        // 最初が知らない名前: undefined || 真 → 真、undefined && x → undefined
        expectEqual(FilterPreparser.evaluateExpr("env_zzz || ext_ublock", env), true)
        expectEqual(FilterPreparser.evaluateExpr("env_zzz && ext_ublock", env), nil)
        expectEqual(FilterPreparser.evaluateExpr("ext_ublock env_mobile", env), nil)
        expectEqual(FilterPreparser.evaluateExpr("&& ext_ublock", env), nil)
        expectEqual(FilterPreparser.evaluateExpr("", env), nil)
    }

    test("!#if の枝: 捨てる・残す・else・入れ子・知らない名前は両方残す") {
        let text = """
        a
        !#if env_mobile
        mobile
        !#else
        desktop
        !#endif
        !#if ext_ublock
        ublock
        !#if env_firefox
        firefox
        !#endif
        after-nested
        !#endif
        !#if env_unknown
        unknown-if
        !#else
        unknown-else
        !#endif
        !#if cap_html_filtering
        html
        !#endif
        !#ifdef x
        z
        """
        let kept = FilterPreparser.prune(text, env: env).split(separator: "\n").map(String.init)
        expectEqual(kept, ["a", "desktop", "ublock", "after-nested", "unknown-if", "unknown-else", "!#ifdef x", "z"])
        let mobile = FilterPreparser.prune(text, env: ["ublock", "mobile"]).split(separator: "\n").map(String.init)
        expect(mobile.contains("mobile") && !mobile.contains("desktop"))
    }

    test("!#if は ABPParser.parse でも効く") {
        let p = ABPParser.parse("""
        ||a.com^
        !#if env_firefox
        ||firefox-only.com^
        !#endif
        !#if !ext_ubol
        ||b.com^
        !#endif
        """)
        expectEqual(p.network.map { $0.body }, ["a.com^", "b.com^"])
    }

    test("env: UA に Mobile があれば env_mobile") {
        expectEqual(FilterPreparser.env(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"), ["ublock"])
        expectEqual(FilterPreparser.env(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148"), ["ublock", "mobile"])
        expectEqual(FilterPreparser.env(userAgent: "xMobiley"), ["ublock"])
    }

    test("!#include: 名前の検査（URL・.. を断る・サブフォルダは可）") {
        let base = url("https://ublockorigin.github.io/uAssets/filters/filters.txt")
        expectEqual(FilterPreparser.includeURL("filters-2024.txt", base: base)?.absoluteString, "https://ublockorigin.github.io/uAssets/filters/filters-2024.txt")
        expectEqual(FilterPreparser.includeURL("ublock/filters.txt", base: base)?.absoluteString, "https://ublockorigin.github.io/uAssets/filters/ublock/filters.txt")
        expect(FilterPreparser.includeURL("../thirdparties/x.txt", base: base) == nil)
        expect(FilterPreparser.includeURL("https://evil.example/x.txt", base: base) == nil)
        expect(FilterPreparser.includeURL("data:text/plain,x", base: base) == nil)
        expectEqual(FilterPreparser.includeName("!#include filters-general.txt"), "filters-general.txt")
        expectEqual(FilterPreparser.includeName("!#include   a.txt  trailing"), "a.txt")
        expect(FilterPreparser.includeName("!#includex a.txt") == nil)
    }

    test("!#include: 埋め込み・捨てる枝の include は読まない・同じものは 1 回・入れ子") {
        let base = url("https://lists.example/f/main.txt")
        let files: [String: String] = [
            "https://lists.example/f/a.txt": "||a.com^\n!#include sub/b.txt\n!#include main.txt",
            "https://lists.example/f/sub/b.txt": "||b.com^",
            "https://lists.example/f/mobile.txt": "||mobile.com^",
        ]
        var asked: [String] = []
        let main = """
        ||top.com^
        !#include a.txt
        !#include a.txt
        !#if env_mobile
        !#include mobile.txt
        !#endif
        !#include ../x.txt
        """
        let r = runAsync {
            await FilterPreparser.expandIncludes(main, base: base, env: ["ublock"]) { u in
                asked.append(u.absoluteString)
                return files[u.absoluteString]
            }
        }
        expectEqual(asked, ["https://lists.example/f/a.txt", "https://lists.example/f/sub/b.txt"])
        expectEqual(r.included.map { $0.lastPathComponent }, ["a.txt", "b.txt"])
        expectEqual(r.failed, ["../x.txt（読めない名前）"])
        let p = ABPParser.parse(r.text)
        expectEqual(p.network.map { $0.body }, ["top.com^", "a.com^", "b.com^"])
    }

    test("!#include: 深さの上限") {
        let base = url("https://l.example/0.txt")
        let r = runAsync {
            await FilterPreparser.expandIncludes("!#include 1.txt", base: base, env: env) { u in
                let n = Int(u.deletingPathExtension().lastPathComponent)!
                return "||d\(n).com^\n!#include \(n + 1).txt"
            }
        }
        expectEqual(r.included.count, FilterPreparser.maxIncludeDepth)
        expectEqual(r.failed, ["\(FilterPreparser.maxIncludeDepth + 1).txt（深すぎる）"])
    }

    test("Expires を読む") {
        expectEqual(FilterPreparser.expiresHours("! Title: x\n! Expires: 8 hours\n||a^"), 8)
        expectEqual(FilterPreparser.expiresHours("! Expires: 4 days (update frequency)"), 96)
        expectEqual(FilterPreparser.expiresHours("! Expires: 1 day"), 24)
        expectEqual(FilterPreparser.expiresHours("! Expires: 30 days"), 168)
        expectEqual(FilterPreparser.expiresHours("! Title: x\n||a^"), nil)
    }
}

/// async の関数を、テストの中で待って結果を返す
final class AsyncResultBox<T>: @unchecked Sendable {
    var value: T?
    let body: () async -> T
    init(_ b: @escaping () async -> T) { body = b }
}

func runAsync<T>(_ body: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = AsyncResultBox(body)
    Task.detached {
        box.value = await box.body()
        sem.signal()
    }
    sem.wait()
    return box.value!
}
