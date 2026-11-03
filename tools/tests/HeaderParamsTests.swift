import Foundation

// MARK: - 「key=value」の属性の読み方のテスト（Set-Cookie の属性・Strict-Transport-Security）

func headerParamsTests() {
    print("key=value の属性")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func cookie(_ s: String) -> CookieRecord? {
        if case .cookie(let c) = SetCookieParser.parse(s, url: url("https://www.example.com/app/x"), now: now) { return c }
        return nil
    }
    test("Set-Cookie の属性: キーは大文字・小文字・前後の空白を問わない、値は前後の空白を取る") {
        let c = cookie("a=1;   PATH = /app  ;SECURE;httponly ; SameSite = Lax ; Max-Age = 30")
        expectEqual(c?.path, "/app")
        expectEqual(c?.secure, true); expectEqual(c?.httpOnly, true)
        expectEqual(c?.sameSite, .lax)
        expectEqual(c?.expires, now.addingTimeInterval(30))
    }
    test("Set-Cookie の属性: = が無い・空のキー・= が 2 つ・引用符") {
        expectEqual(cookie("a=1; Secure=yes")?.secure, true, "Secure=yes も Secure（キーだけ見る）")
        expectEqual(cookie("a=1; =x; Path=/app")?.path, "/app", "空のキーは知らない属性として飛ばす")
        expectEqual(cookie("a=1; Path=/a=b")?.path, "/a=b", "最初の = で分ける")
        expectEqual(cookie("a=1; Path=\"/other\"")?.path, "/app", "引用符は外さない（\"/other\" は / で始まらないので使われず、URL から決めた /app のまま）")
        expectEqual(cookie("a=1; ; ;Path=/app")?.path, "/app", "空の属性は飛ばす")
        expectEqual(cookie("a=1; Max-Age")?.expires, nil, "= が無ければ値は空")
    }
    test("Strict-Transport-Security: キーは大文字・小文字・空白を問わない、値の引用符は外す、同じキー 2 回は無効") {
        expect(HSTSPolicy.parse(" MAX-AGE = 10 ; INCLUDESUBDOMAINS ")! == (10, true))
        expect(HSTSPolicy.parse("max-age=\"20\"")! == (20, false))
        expect(HSTSPolicy.parse("max-age=\"\"30\"")! == (30, false), "引用符は前後に何個あっても外す")
        expect(HSTSPolicy.parse("max-age=5;;;")! == (5, false), "空は飛ばす")
        expect(HSTSPolicy.parse("max-age=5; preload")! == (5, false), "知らないキーは飛ばす")
        expect(HSTSPolicy.parse("max-age=5; includeSubDomains; INCLUDESUBDOMAINS") == nil, "同じキー 2 回")
        expect(HSTSPolicy.parse("max-age=5; =x")! == (5, false), "空のキー")
        expect(HSTSPolicy.parse("max-age=5=6") == nil, "最初の = で分ける（値 \"5=6\" は数でない）")
    }
}
