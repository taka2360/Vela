import Foundation

// MARK: - gzip の頭（ヘッダー）の読み方のテスト（今の動きを書き留めたもの）
// 一括（ContentDecoding.decode）は、頭が途中までしか無ければ corrupt("gzip")。
// Linux には Compression が無いので、頭が正しければ unsupported("gzip") で止まる（iPad では戻しに進む）

/// gzip の頭を組み立てる（flags: 2=FHCRC 4=FEXTRA 8=FNAME 16=FCOMMENT）
func gzipHead(flags: UInt8, extra: [UInt8] = [], extraLen: Int? = nil, name: [UInt8]? = nil, comment: [UInt8]? = nil, hcrc: Int = 2,
              magic: [UInt8] = [0x1F, 0x8B], cm: UInt8 = 8) -> [UInt8] {
    var b = magic + [cm, flags, 0, 0, 0, 0, 0, 3]
    if flags & 4 != 0 {
        let n = extraLen ?? extra.count
        b += [UInt8(n & 0xFF), UInt8(n >> 8)]
        b += extra
    }
    if flags & 8 != 0, let name { b += name }
    if flags & 16 != 0, let comment { b += comment }
    if flags & 2 != 0 { b += [UInt8](repeating: 0xAB, count: hcrc) }
    return b
}

/// 一括で戻したときの結果を短い文字にする
func decodeGzipOutcome(_ b: [UInt8]) -> String {
    switch ContentDecoding.decode(Data(b), encoding: "gzip") {
    case .success: return "ok"
    case .failure(.corrupt(let s)): return "corrupt:\(s)"
    case .failure(.unsupported(let s)): return "unsupported:\(s)"
    case .failure(.tooLarge): return "tooLarge"
    }
}

func gzipTests() {
    print("gzip の頭")
    #if canImport(Compression)
    let valid = "ok"            // iPad・Mac では本当に戻しに進む（中身が deflate として正しいとは限らない）
    #else
    let valid = "unsupported:gzip"
    #endif
    let body = [UInt8](repeating: 0x03, count: 10)        // 頭の後ろの中身（deflate と後ろの 8 バイトの代わり）
    test("一括: 正しい頭（フラグの組み合わせ）は先へ進む") {
        guard valid == "unsupported:gzip" else { return }      // Linux でだけ、結果の形まで確かめる
        expectEqual(decodeGzipOutcome(gzipHead(flags: 0) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 4, extra: [1, 2, 3]) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 8, name: Array("a.txt".utf8) + [0]) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 16, comment: Array("hi".utf8) + [0]) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 2) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 2 | 4 | 8 | 16, extra: [9], name: [0x61, 0], comment: [0x62, 0]) + body), valid)
        expectEqual(decodeGzipOutcome(gzipHead(flags: 4, extra: [UInt8](repeating: 7, count: 65535)) + body), valid, "FEXTRA 65535")
        expectEqual(decodeGzipOutcome(gzipHead(flags: 0xE0) + body), valid, "予約フラグは見ていない")
    }
    test("一括: 頭が違う・短すぎる") {
        expectEqual(decodeGzipOutcome(gzipHead(flags: 0, magic: [0x1F, 0x8C]) + body), "corrupt:gzip の頭が違います")
        expectEqual(decodeGzipOutcome(gzipHead(flags: 0, cm: 9) + body), "corrupt:gzip の頭が違います")
        expectEqual(decodeGzipOutcome(Array((gzipHead(flags: 0) + body).prefix(17))), "corrupt:gzip の頭が違います", "18 バイト未満")
        expectEqual(decodeGzipOutcome([]), "corrupt:gzip の頭が違います", "空（中身が空なら戻さないのは HTTPClient.result の方）")
    }
    test("GzipHeader.parse（流す形の決まり: 足りなければ needMore）") {
        expectEqual(GzipHeader.parse([]), .needMore)
        expectEqual(GzipHeader.parse(Array(gzipHead(flags: 0).prefix(9))), .needMore, "10 バイト未満")
        expectEqual(GzipHeader.parse(gzipHead(flags: 0)), .length(10), "ちょうど最後で終わる")
        expectEqual(GzipHeader.parse(gzipHead(flags: 0) + body), .length(10))
        expectEqual(GzipHeader.parse(gzipHead(flags: 0, magic: [0x1F, 0x8C])), .bad("gzip の頭が違います"))
        expectEqual(GzipHeader.parse(gzipHead(flags: 0, cm: 9)), .bad("gzip の頭が違います"))
        expectEqual(GzipHeader.parse(gzipHead(flags: 0xE0) + body), .length(10), "予約フラグは見ていない")
        // FEXTRA: 長さの 2 バイトが途中で切れる・中身が途中で切れる・65535
        expectEqual(GzipHeader.parse(Array(gzipHead(flags: 4, extra: [1]).prefix(11))), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 4, extra: [1, 2], extraLen: 5)), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 4, extra: [1, 2, 3])), .length(15))
        expectEqual(GzipHeader.parse(gzipHead(flags: 4, extra: [UInt8](repeating: 7, count: 65535)) + body), .length(12 + 65535))
        // FNAME・FCOMMENT: 0 が無ければ needMore、あればその次から
        expectEqual(GzipHeader.parse(gzipHead(flags: 8, name: [0x61, 0x62])), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 16, comment: [0x61])), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 8 | 16, name: [0x61, 0], comment: [0x62])), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 8 | 16, name: [0x61, 0], comment: [0x62, 0])), .length(14))
        // FHCRC: 2 バイト足りなければ needMore
        expectEqual(GzipHeader.parse(gzipHead(flags: 2, hcrc: 1)), .needMore)
        expectEqual(GzipHeader.parse(gzipHead(flags: 2)), .length(12))
        expectEqual(GzipHeader.parse(gzipHead(flags: 2 | 4 | 8 | 16, extra: [9], name: [0x61, 0], comment: [0x62, 0])), .length(19))
        // FEXTRA の長さで先へ飛んだ後の FNAME（0 を探す所が無い）
        expectEqual(GzipHeader.parse(gzipHead(flags: 4 | 8, extra: [], extraLen: 100, name: [0])), .needMore)
    }
    test("GzipHeader.isZlib") {
        expect(GzipHeader.isZlib(0x78, 0x9C)); expect(GzipHeader.isZlib(0x78, 0x01)); expect(GzipHeader.isZlib(0x78, 0xDA))
        expect(!GzipHeader.isZlib(0x78, 0x9D), "31 の倍数でない")
        expect(!GzipHeader.isZlib(0x79, 0x9C), "CM が 8 でない")
    }
    test("一括: 頭が途中までしか無い → corrupt(gzip)") {
        // FEXTRA の中身が途中で切れる（長さは 65535 と言っているのに 10 バイトしか無い）
        expectEqual(decodeGzipOutcome(gzipHead(flags: 4, extra: [UInt8](repeating: 1, count: 10), extraLen: 65535)), "corrupt:gzip")
        // FNAME・FCOMMENT の 0 が無い
        expectEqual(decodeGzipOutcome(gzipHead(flags: 8, name: [UInt8](repeating: 0x61, count: 20))), "corrupt:gzip")
        expectEqual(decodeGzipOutcome(gzipHead(flags: 16, comment: [UInt8](repeating: 0x61, count: 20))), "corrupt:gzip")
        expectEqual(decodeGzipOutcome(gzipHead(flags: 8 | 16, name: [0x61, 0], comment: [UInt8](repeating: 0x62, count: 20))), "corrupt:gzip")
        // FHCRC の 2 バイトが足りない（頭が 18 バイト以上になるように FNAME で長くする）
        expectEqual(decodeGzipOutcome(gzipHead(flags: 8 | 2, name: [UInt8](repeating: 0x61, count: 7) + [0], hcrc: 1)), "corrupt:gzip")
        // 頭がちょうど最後で終わる（中身が 1 バイトも無い）
        expectEqual(decodeGzipOutcome(gzipHead(flags: 8, name: [UInt8](repeating: 0x61, count: 9) + [0])), "corrupt:gzip")
    }
}
