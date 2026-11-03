import Foundation

// MARK: - JavaScript のダイアログ（どのタブ・どのホストからか）のテスト

func jsDialogTests() {
    print("JSDialog")
    test("originHost: フレームのホスト → タブの URL のホスト → 空") {
        expectEqual(JSDialog.originHost(frameHost: "Frame.Example", tabURL: url("https://tab.test/")), "Frame.Example", "小文字にはしない")
        expectEqual(JSDialog.originHost(frameHost: "", tabURL: url("https://Tab.Test/x")), url("https://Tab.Test/x").host ?? "?")
        expectEqual(JSDialog.originHost(frameHost: "", tabURL: url("about:blank")), "")
        expectEqual(JSDialog.originHost(frameHost: "", tabURL: nil), "")
    }
    test("見出しは host + \" より\"（空なら「 より」）。前の origin（\"#番号 ホスト\"）から作っていた見出しと同じ") {
        for (id, host) in [(1, "a.test"), (12, ""), (3, "xn--eckwd4c7c.xn--zckzah")] {
            let d = JSDialog(kind: .alert, message: "m", tabID: id, host: host) { _, _ in }
            let oldOrigin = "#\(id) \(host)"
            let oldTitle = String(oldOrigin.drop(while: { $0 != " " }).dropFirst()) + " より"
            expectEqual(d.title, oldTitle)
        }
        expectEqual(JSDialog(kind: .alert, message: "", tabID: 1, host: "") { _, _ in }.title, " より")
    }
    test("tabID で選ぶのは、前の「#番号 」で始まるかと同じ（#1 は #12 に当たらない）") {
        let ids = [1, 12, 2, 21]
        for want in ids {
            for other in ids {
                let oldMatch = "#\(other) host".hasPrefix("#\(want) ")
                expectEqual(other == want, oldMatch, "\(want) と \(other)")
            }
        }
    }
}
