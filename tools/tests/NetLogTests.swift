import Foundation

// MARK: - 通信の記録のテスト

func netLogTests() {
    print("NetLog")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    test("始まり・メモ・終わり") {
        let log = NetLog()
        let id = log.begin(tab: 1, method: "GET", url: "https://a.com/", kind: "ページ", topLevel: true, now: t0)
        log.note(id, "🔒 HSTS: https に上げた")
        log.update(id) { $0.status = 200 }
        log.finish(id, outcome: .ok, bytes: 2048, now: t0 + 0.25)
        let r = log.recent()[0]
        expectEqual(r.status, 200)
        expectEqual(r.durationMs, 250)
        expectEqual(r.notes.count, 1)
        expect(r.line.hasPrefix("200 GET ページ（ページ） 250ms・2KB https://a.com/"))
        // 終わった後は変えない
        log.finish(id, outcome: .cancelled, now: t0 + 1)
        expectEqual(log.recent()[0].outcome, .ok)
        expect(!r.isProblem)
    }
    test("ブロック・失敗・絞り込み・新しい順") {
        let log = NetLog()
        let a = log.begin(tab: 1, method: "GET", url: "https://ads.com/x.js", kind: "スクリプト", topLevel: false, now: t0)
        log.finish(a, outcome: .blocked("||ads.com^"), now: t0)
        let b = log.begin(tab: 2, method: "POST", url: "https://b.com/api", kind: "XHR", topLevel: false, now: t0)
        log.finish(b, outcome: .failed("タイムアウト"), now: t0 + 1)
        let c = log.begin(tab: 2, method: "GET", url: "https://c.com/", kind: "画像", topLevel: false, now: t0)
        log.finish(c, outcome: .ok, status: 404, now: t0 + 1)
        expectEqual(log.recent().map { $0.id }, [c, b, a])
        expectEqual(log.recent { $0.isProblem }.count, 3)
        expectEqual(log.recent { $0.tab == 2 }.count, 2)
        expect(log.recent()[2].line.contains("🚫 ||ads.com^"))
        expect(log.export().contains("✕ タイムアウト"))
    }
    test("上限を超えたら古いものを捨てる・番号で引ける") {
        let log = NetLog()
        var last = 0
        for i in 0..<(NetLog.maxRecords + 150) {
            last = log.begin(tab: nil, method: "GET", url: "https://s\(i).com/", kind: "?", topLevel: false, now: t0)
        }
        expect(log.count <= NetLog.maxRecords + 100)
        log.finish(last, outcome: .ok, status: 204, now: t0)
        expectEqual(log.recent(limit: 1)[0].status, 204)
        log.finish(1, outcome: .ok, now: t0)        // もう捨てたもの: 何も起きない
        log.clear()
        expectEqual(log.count, 0)
    }
}
