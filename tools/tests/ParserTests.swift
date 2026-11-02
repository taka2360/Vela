import Foundation

// MARK: - ResponseParser（外から来る返事の検査）と ContentDecoding のテスト

private func parse(_ chunks: [String], isHead: Bool = false, limits: ResponseParser.Limits = ResponseParser.Limits()) -> ResponseParser {
    let p = ResponseParser(isHead: isHead, limits: limits)
    for c in chunks { p.feed(Data(c.utf8)) }
    return p
}

private func isMalformed(_ p: ResponseParser) -> Bool { if case .malformed = p.failure { return true }; return false }
private func isTooLarge(_ p: ResponseParser) -> Bool { if case .tooLarge = p.failure { return true }; return false }

func parserTests() {
    print("ResponseParser")
    test("Content-Length で読む・少しずつ届いても同じ") {
        let whole = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
        let p = parse([whole])
        expect(p.complete); expectEqual(p.status, 200); expectEqual(String(decoding: p.body, as: UTF8.self), "hello")
        let q = parse(whole.map { String($0) })
        expect(q.complete); expectEqual(q.body, p.body)
    }
    test("chunked（拡張・トレーラー付き）") {
        let p = parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "5;ext=1\r\nhel", "lo\r\n", "0\r\nX-T: 1\r\n\r\n"])
        expect(p.complete); expectEqual(String(decoding: p.body, as: UTF8.self), "hello"); expect(p.failure == nil)
    }
    test("100 Continue を飛ばす・HEAD と 204 は中身なし") {
        let p = parse(["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"])
        expect(p.complete); expectEqual(p.status, 200)
        expect(parse(["HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"], isHead: true).complete)
        expect(parse(["HTTP/1.1 204 No Content\r\n\r\n"]).complete)
    }
    test("閉じるまで読む形") {
        let p = parse(["HTTP/1.1 200 OK\r\n\r\nabc"])
        expect(!p.complete); expect(p.closed()); expectEqual(p.body.count, 3); expect(!p.keepAlive)
    }
    test("Content-Length: -1 は拒否（前はここで落ちた）") {
        let p = parse(["HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nabc"])
        expect(isMalformed(p)); expect(!p.complete)
    }
    test("Content-Length が数字でない・違う値の重複は拒否、同じ値の重複は通す") {
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nContent-Length: 1e3\r\n\r\n"])))
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd"])))
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nContent-Length: 3, 4\r\n\r\nabcd"])))
        let ok = parse(["HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc"])
        expect(ok.complete && ok.failure == nil)
    }
    test("Transfer-Encoding と Content-Length の両方は拒否") {
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n"])))
    }
    test("チャンクの後ろが CRLF でない・サイズが不正なら拒否") {
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n"])))
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n"])), "負のサイズ（前はここで落ちた）")
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"])))
        expect(isMalformed(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n12345678901234567\r\n"])), "長すぎるサイズ")
    }
    test("ヘッダの上限（合計・1 行・行数）") {
        var l = ResponseParser.Limits(); l.maxHeaderBytes = 200; l.maxHeaderLine = 50; l.maxHeaderCount = 3
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 300)], limits: l)), "ヘッダが終わらない")
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 60) + "\r\n\r\n"], limits: l)))
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n\r\n"], limits: l)))
    }
    test("中身の上限（長さ指定・chunked・閉じるまで）") {
        var l = ResponseParser.Limits(); l.maxBody = 10
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n"], limits: l)))
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFF\r\n"], limits: l)), "巨大なチャンク")
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n12345678\r\n8\r\n12345678\r\n"], limits: l)))
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 11)], limits: l)))
        var t = ResponseParser.Limits(); t.maxTrailerBytes = 10
        expect(isTooLarge(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Long: 12345678901234\r\n\r\n"], limits: t)))
    }
    test("状態の行が壊れている") {
        expect(isMalformed(parse(["HTTP/2 200\r\n\r\n"])))
        expect(isMalformed(parse(["HTTP/1.1 2000 OK\r\n\r\n"])))
        expect(isMalformed(parse(["garbage\r\n\r\n"])))
    }
    test("途中で切れた（長さ指定）は完了にしない") {
        let p = parse(["HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"])
        expect(!p.closed())
    }
    test("中身が増えた分を知らせる") {
        let p = ResponseParser(isHead: false)
        var grown = 0
        p.onBodyGrow = { grown += $0 }
        p.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nabc".utf8)); p.feed(Data("def".utf8))
        expectEqual(grown, 6)
    }

    test("流す形: 中身を貯めずに渡す・上限をかけない・少しずつ届いても同じ") {
        var l = ResponseParser.Limits(); l.maxBody = 4
        let p = ResponseParser(isHead: false, limits: l)
        var got = Data()
        p.decideStreaming = { true }
        p.onChunk = { got.append($0) }
        p.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8))
        p.feed(Data("lo\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        expect(p.complete); expect(p.failure == nil); expect(p.streaming)
        expectEqual(String(decoding: got, as: UTF8.self), "hello world")
        expect(p.body.isEmpty, "貯めていない"); expectEqual(p.bodyCount, 11)
        let q = ResponseParser(isHead: false, limits: l)
        var n = 0
        q.decideStreaming = { true }
        q.onChunk = { n += $0.count }
        q.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789extra".utf8))
        expect(q.complete); expectEqual(n, 10)
        let r = ResponseParser(isHead: false)
        r.decideStreaming = { false }
        r.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nab".utf8))
        expect(!r.streaming); expectEqual(r.body.count, 2)
    }

    print("ContentDecoding")
    test("知らない縮め方は失敗（生のまま渡さない）") {
        if case .failure(.unsupported("zstd")) = ContentDecoding.decode(Data([1, 2, 3]), encoding: "zstd") {} else { expect(false) }
        if case .success(let d) = ContentDecoding.decode(Data([1, 2]), encoding: "identity") { expectEqual(d, Data([1, 2])) } else { expect(false) }
        // Linux では Compression が無いので gzip は「戻せない」。iPad では壊れた gzip が corrupt になる
        if case .failure = ContentDecoding.decode(Data([0x1f, 0x8b, 8, 0] + [UInt8](repeating: 0, count: 20)), encoding: "gzip") {} else { expect(false) }
    }
}
