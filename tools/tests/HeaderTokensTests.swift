import Foundation

// MARK: - カンマ区切りのヘッダの読み方のテスト（今の動きを書き留めたもの）
// 展開の一覧（Content-Encoding）・流す形の一覧・Content-Length・Transfer-Encoding の 4 か所

private func feed(_ s: String) -> ResponseParser {
    let p = ResponseParser(isHead: false)
    p.feed(Data(s.utf8))
    return p
}

private func encodingOutcome(_ enc: String) -> String {
    switch ContentDecoding.decode(Data([1, 2, 3]), encoding: enc) {
    case .success(let d): return "ok:\(d.count)"
    case .failure(.unsupported(let s)): return "unsupported:\(s)"
    case .failure(.corrupt(let s)): return "corrupt:\(s)"
    case .failure(.tooLarge): return "tooLarge"
    }
}

private func streamOutcome(_ enc: String) -> String {
    switch StreamDecoder.make(encoding: enc) {
    case .success(nil): return "none"
    case .success: return "decoder"
    case .failure(.unsupported(let s)): return "unsupported:\(s)"
    case .failure(let f): return "other:\(f)"
    }
}

func headerTokenTests() {
    print("カンマ区切りのヘッダ")
    test("HeaderTokens.list: 空の要素も残す・前後の空白を取る・lowercase") {
        expectEqual(HeaderTokens.list("", lowercase: true), [""])
        expectEqual(HeaderTokens.list(" , ", lowercase: true), ["", ""])
        expectEqual(HeaderTokens.list(",gzip,,", lowercase: true), ["", "gzip", "", ""])
        expectEqual(HeaderTokens.list("GZIP,\tbr", lowercase: true), ["gzip", "br"])
        expectEqual(HeaderTokens.list("GZIP,\tbr", lowercase: false), ["GZIP", "br"])
        expectEqual(HeaderTokens.list("5, 5", lowercase: false), ["5", "5"])
        expectEqual(HeaderTokens.list("5,", lowercase: false), ["5", ""])
        expectEqual(HeaderTokens.list("a\nb, c", lowercase: false), ["a\nb", "c"], "改行は取らない")
    }
    test("Content-Encoding（一括）: 空・空白・identity は飛ばし、知らないものはそれ（小文字・空白を取った形）で失敗") {
        expectEqual(encodingOutcome(""), "ok:3")
        expectEqual(encodingOutcome(" , ,"), "ok:3")
        expectEqual(encodingOutcome("identity"), "ok:3")
        expectEqual(encodingOutcome("Identity , ,IDENTITY"), "ok:3")
        expectEqual(encodingOutcome(" ZSTD "), "unsupported:zstd")
        expectEqual(encodingOutcome("zstd,\tidentity"), "unsupported:zstd", "後ろから順に戻す（identity は飛ばす）")
        expectEqual(encodingOutcome("x,y"), "unsupported:y", "後ろのものから")
    }
    test("流す形の一覧: 空・identity だけなら無し、2 つ以上は元の文字のまま失敗、知らないものは小文字で失敗") {
        expectEqual(streamOutcome(""), "none")
        expectEqual(streamOutcome(" , identity ,"), "none")
        expectEqual(streamOutcome("GZIP, Br"), "unsupported:GZIP, Br", "2 つ以上は元の文字")
        expectEqual(streamOutcome(" ZSTD "), "unsupported:zstd")
        #if !canImport(Compression)
        expectEqual(streamOutcome("gzip"), "unsupported:gzip", "Linux では戻せない")
        #endif
    }
    test("Content-Length: 空の要素は残す（「5,」は不正）・同じ値の重複は通す") {
        expect(feed("HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\n\r\nhello").complete)
        expect(feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello").complete)
        expect(feed("HTTP/1.1 200 OK\r\nContent-Length: \t5 ,5\r\n\r\nhello").complete)
        for bad in ["5,", "5,,5", ",5", " , ", "5, 6"] {
            let p = feed("HTTP/1.1 200 OK\r\nContent-Length: \(bad)\r\n\r\nhello")
            if case .malformed = p.failure {} else { expect(false, "不正にならない: \(bad)") }
        }
    }
    test("Transfer-Encoding: 全部の行をつないで小文字にし、空は飛ばして、最後が chunked か") {
        let chunked = "5\r\nhello\r\n0\r\n\r\n"
        for te in ["chunked", "gzip, CHUNKED", "chunked, ", " , chunked"] {
            let p = feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: \(te)\r\n\r\n" + chunked)
            expect(p.complete && p.body == Array("hello".utf8), "chunked: \(te)")
        }
        let two = feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n" + chunked)
        expect(two.complete, "2 行に分かれていても、つないで見る")
        let notLast = feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\nabc")
        expect(!notLast.complete && notLast.failure == nil, "最後が chunked でなければ、閉じるまで読む")
    }
}
