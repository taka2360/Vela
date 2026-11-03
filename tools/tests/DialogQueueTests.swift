import Foundation

// MARK: - JavaScript のダイアログの順番待ち（DialogQueue）のテスト
// 前の BrowserStore の presentDialog・answerDialog・cancelDialogs と同じ決まりであることを確かめる

/// respond が呼ばれた記録（名前, ok, 入力）
final class DialogLog {
    var calls: [(String, Bool, String?)] = []
    func count(_ name: String) -> Int { calls.filter { $0.0 == name }.count }
}

func dlg(_ name: String, tab: Int, _ log: DialogLog) -> JSDialog { dlg(name, tab: tab, .alert, log) }

func dlg(_ name: String, tab: Int, _ kind: JSDialog.Kind, _ log: DialogLog) -> JSDialog {
    JSDialog(kind: kind, message: name, tabID: tab, host: "h") { ok, text in log.calls.append((name, ok, text)) }
}

func dialogQueueTests() {
    print("DialogQueue")
    test("来た順に 1 つずつ出す") {
        let q = DialogQueue(), log = DialogLog()
        expect(q.current == nil)
        q.present(dlg("a", tab: 1, log))
        q.present(dlg("b", tab: 1, log))
        q.present(dlg("c", tab: 2, log))
        expectEqual(q.current?.message, "a")
        expectEqual(q.waitingCount, 2)
        q.answer(ok: true)
        expectEqual(q.current?.message, "b")
        q.answer(ok: true)
        expectEqual(q.current?.message, "c")
        q.answer(ok: true)
        expect(q.current == nil)
        expectEqual(log.calls.map { $0.0 }, ["a", "b", "c"])
    }
    test("入力欄: prompt なら既定値、それ以外は空。prompt が 2 つ続くと 2 つ目の既定値") {
        let q = DialogQueue(), log = DialogLog()
        q.present(dlg("p1", tab: 1, .prompt("a"), log))
        q.present(dlg("al", tab: 1, .alert, log))
        q.present(dlg("p2", tab: 1, .prompt("x"), log))
        q.present(dlg("p3", tab: 1, .prompt("y"), log))
        expectEqual(q.input, "a")
        q.input = "typed"
        q.answer(ok: true)
        expectEqual(q.input, "", "alert の間は空")
        q.answer(ok: true)
        expectEqual(q.input, "x")
        q.answer(ok: false)
        expectEqual(q.input, "y")
        q.answer(ok: true)
        expectEqual(log.calls.count, 4)
        guard log.calls.count == 4 else { return }
        expectEqual(log.calls[0].1, true); expectEqual(log.calls[0].2, "typed")
        expectEqual(log.calls[1].1, true); expectEqual(log.calls[1].2, "", "OK なら alert でも入力（空）を渡す")
        expectEqual(log.calls[2].1, false); expectEqual(log.calls[2].2, nil, "キャンセルは nil")
        expectEqual(log.calls[3].1, true); expectEqual(log.calls[3].2, "y")
    }
    test("出しているタブを閉じる: そのタブのものを全部 false で答え、次はほかのタブのもの") {
        let q = DialogQueue(), log = DialogLog()
        q.present(dlg("a1", tab: 1, log))
        q.present(dlg("b1", tab: 2, log))
        q.present(dlg("a2", tab: 1, log))
        q.present(dlg("b2", tab: 2, log))
        q.cancel(tabID: 1)
        expectEqual(log.calls.map { $0.0 }, ["a2", "a1"], "列の中のものが先、出しているものが後")
        expect(log.calls.allSatisfy { !$0.1 && $0.2 == nil })
        expectEqual(q.current?.message, "b1")
        expectEqual(q.waitingCount, 1)
    }
    test("待っている方のタブを閉じる: 出ているものは変わらない") {
        let q = DialogQueue(), log = DialogLog()
        q.present(dlg("a1", tab: 1, .prompt("d"), log))
        q.present(dlg("b1", tab: 2, log))
        q.present(dlg("b2", tab: 2, log))
        q.input = "keep"
        q.cancel(tabID: 2)
        expectEqual(log.calls.map { $0.0 }, ["b1", "b2"])
        expectEqual(q.current?.message, "a1")
        expectEqual(q.input, "keep", "入力欄はそのまま")
        expectEqual(q.waitingCount, 0)
    }
    test("同じタブから続けて 3 つ。閉じた後・何も出ていないときに答えても何も起きない") {
        let q = DialogQueue(), log = DialogLog()
        q.answer(ok: true)
        q.cancel(tabID: 1)
        expectEqual(log.calls.count, 0)
        for n in ["x", "y", "z"] { q.present(dlg(n, tab: 3, log)) }
        q.cancel(tabID: 3)
        expectEqual(log.calls.map { $0.0 }, ["y", "z", "x"])
        expect(q.current == nil)
        q.answer(ok: true)
        q.answer(ok: false)
        q.cancel(tabID: 3)
        expectEqual(log.calls.count, 3)
    }
    test("どの組み合わせでも、各ダイアログの respond はちょうど 1 回") {
        // 操作: 0 = 1 のタブから出す, 1 = 2 のタブから出す, 2 = OK, 3 = キャンセル, 4 = 1 を閉じる, 5 = 2 を閉じる
        var seed: UInt32 = 12345
        func next(_ n: UInt32) -> Int { seed = seed &* 1103515245 &+ 12345; return Int((seed >> 16) % n) }
        for round in 0..<200 {
            let q = DialogQueue(), log = DialogLog()
            var made: [String] = []
            for step in 0..<12 {
                switch next(6) {
                case 0, 1:
                    let tab = made.count % 2 == 0 ? 1 : 2
                    let name = "r\(round)s\(step)"
                    made.append(name)
                    q.present(dlg(name, tab: tab, next(2) == 0 ? .alert : .prompt("p"), log))
                case 2: q.answer(ok: true)
                case 3: q.answer(ok: false)
                case 4: q.cancel(tabID: 1)
                default: q.cancel(tabID: 2)
                }
                for n in made where log.count(n) > 1 { expect(false, "\(n) が 2 回以上") }
            }
            q.cancel(tabID: 1)
            q.cancel(tabID: 2)
            expect(q.current == nil)
            expectEqual(q.waitingCount, 0)
            for n in made { expectEqual(log.count(n), 1, n) }
        }
    }
    test("willChange: current・input が変わるたびに呼ぶ") {
        let q = DialogQueue(), log = DialogLog()
        var n = 0
        q.willChange = { n += 1 }
        q.present(dlg("a", tab: 1, .prompt("d"), log))
        let afterPresent = n
        expect(afterPresent >= 1)
        q.present(dlg("b", tab: 1, log))
        expectEqual(n, afterPresent, "列に並べるだけなら呼ばない（画面は変わらない）")
        q.input = "x"
        expectEqual(n, afterPresent + 1)
        q.answer(ok: true)
        expect(n >= afterPresent + 2, "答えると呼ぶ")
        let beforeCancel = n
        q.cancel(tabID: 1)
        expect(n > beforeCancel, "出ているものを取り消すと呼ぶ")
    }
}
