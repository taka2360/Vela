import Foundation

// MARK: - 失敗の分類（FetchError への変換）のテスト

func fetchErrorTests() {
    print("FetchError")
    test("返事を読めなかった（ResponseParser.Failure）: tooLarge と、それ以外は malformed") {
        let cases: [(ResponseParser.Failure, FetchError.Kind)] = [
            (.tooLarge("ヘッダが 64KB を超えます"), .tooLarge),
            (.malformed("Content-Length が不正"), .malformed),
            (.malformed(""), .malformed),
        ]
        for (f, kind) in cases {
            let e = FetchError(f)
            expectEqual(e.kind, kind, f.description)
            expectEqual(e.description, f.description)
        }
    }
    test("縮めた中身を戻せなかった（ContentDecoding.Failure）: tooLarge と、それ以外は malformed") {
        let cases: [(ContentDecoding.Failure, FetchError.Kind)] = [
            (.tooLarge(32 << 20), .tooLarge),
            (.corrupt("gzip"), .malformed),
            (.corrupt("頭の途中で終わりました"), .malformed),
            (.unsupported("zstd"), .malformed),
        ]
        for (f, kind) in cases {
            let e = FetchError(f)
            expectEqual(e.kind, kind, f.description)
            expectEqual(e.description, f.description)
        }
    }
}
