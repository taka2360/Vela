import Foundation

// MARK: - DNS のメッセージ（A レコードだけ）
//
// ゲスト側: query で問い合わせを作り、firstA で返事から IPv4 アドレスを取り出す
// ルーター側: question で問い合わせを読み、reply で返事を作る

enum DNSMessage {
    /// A レコードの問い合わせ（再帰あり）
    static func query(name: String, id: UInt16) -> [UInt8] {
        var q: [UInt8] = []
        q.appendBE16(id)
        q += [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]      // RD=1・質問 1 つ
        for label in name.split(separator: ".") {
            let b = Array(label.utf8.prefix(63))
            q.append(UInt8(b.count))
            q += b
        }
        q += [0, 0, 1, 0, 1]                           // 名前の終わり・A・IN
        return q
    }

    /// 返事から最初の A レコード（IPv4 アドレス）を取り出す
    static func firstA(_ r: [UInt8]) -> [UInt8]? {
        guard r.count >= 12, r[3] & 0x0F == 0 else { return nil }
        let qd = Int(r.be16(at: 4)), an = Int(r.be16(at: 6))
        var i = 12
        func skipName() {
            while i < r.count {
                let l = Int(r[i])
                if l == 0 { i += 1; return }
                if l & 0xC0 == 0xC0 { i += 2; return }
                i += 1 + l
            }
        }
        for _ in 0..<qd { skipName(); i += 4 }
        for _ in 0..<an {
            skipName()
            guard i + 10 <= r.count else { return nil }
            let type = r.be16(at: i)
            let rdlen = Int(r.be16(at: i + 8))
            i += 10
            if type == 1 && rdlen == 4 && i + 4 <= r.count { return Array(r[i..<(i + 4)]) }
            i += rdlen
        }
        return nil
    }

    struct Question {
        let name: String
        let type: UInt16
        /// 質問の終わり（返事はここまでを写して作る）
        let end: Int
    }

    /// 問い合わせの最初の質問を読む（形が変なら nil）
    static func question(_ q: [UInt8]) -> Question? {
        var i = 12
        var labels: [String] = []
        while i < q.count {
            let l = Int(q[i])
            if l == 0 { i += 1; break }
            guard l < 64, i + 1 + l <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + l)], as: UTF8.self))
            i += 1 + l
        }
        guard i + 4 <= q.count else { return nil }
        return Question(name: labels.joined(separator: "."), type: q.be16(at: i), end: i + 4)
    }

    /// 返事を作る（問い合わせの先頭 questionEnd バイトを写し、A レコードを並べる）
    static func reply(to q: [UInt8], questionEnd: Int, rcode: UInt8, answers: [[UInt8]]) -> [UInt8] {
        var r = Array(q[0..<min(questionEnd, q.count)])
        r[2] = 0x81                                    // QR=1・RD=1
        r[3] = 0x80 | rcode                            // RA=1
        r.setBE16(UInt16(answers.count), at: 6)
        for k in 8..<12 { r[k] = 0 }
        for a in answers {
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + a   // 名前は質問を指す・A・IN・60 秒・4 バイト
        }
        return r
    }
}
