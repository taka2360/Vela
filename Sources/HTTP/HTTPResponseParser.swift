import Foundation

// MARK: - http の返事を少しずつ読む
//
// ヘッダ → 中身。中身の終わりは「長さ指定（Content-Length）」「chunked」「閉じるまで」のどれか。
// 100 Continue などの途中の返事は読み飛ばす。
//
// 外から来るデータなので、おかしなものは「壊れている（malformed）」「大きすぎる（tooLarge）」として止める（落ちない・貯めすぎない）:
//  ・Content-Length は 0 以上の整数だけ。違う値が重複していたら拒否（同じ値の重複は 1 つにまとめる）
//  ・Transfer-Encoding と Content-Length が両方あったら拒否（中身の境目があいまいになり、取り違えの元になるため）
//  ・chunked: サイズは 16 進の数字だけ。チャンクの後ろは必ず CRLF。行・トレーラーの長さに上限
//  ・ヘッダの合計・1 行・行数に上限。中身は limits.maxBody まで
// 止めた接続は使い回さない（呼ぶ側の HTTPConn が閉じる）
//
// 流す形（ストリーミング）: ヘッダを読んだところで decideStreaming が true を返したら、中身は貯めずに
// 届いた分ずつ onChunk に渡す（大きいファイル・動画でメモリを使わない）。そのときは maxBody の上限はかけない

final class ResponseParser {
    struct Limits {
        var maxHeaderBytes = 64 * 1024
        var maxHeaderLine = 8 * 1024
        var maxHeaderCount = 100
        var maxBody = 32 << 20
        var maxChunkLine = 1024
        var maxTrailerBytes = 8 * 1024
        init() {}
    }

    enum Failure: Equatable {
        case malformed(String)
        case tooLarge(String)
        var description: String {
            switch self {
            case .malformed(let s): return "返事が壊れています（\(s)）"
            case .tooLarge(let s): return "返事が大きすぎます（\(s)）"
            }
        }
    }

    let isHead: Bool
    let limits: Limits
    private(set) var status = 0
    private(set) var headers: [(String, String)] = []
    private(set) var body = [UInt8]()
    private(set) var complete = false
    private(set) var keepAlive = true
    /// 届いたバイト数（何も届かずに切れたかを見るため）
    private(set) var received = 0
    /// おかしな返事だった（nil なら問題なし）
    private(set) var failure: Failure?
    /// 中身が増えたとき（増えたバイト数）。アプリ全体の貯めている量を数えるのに使う（流す形のときは呼ばない）
    var onBodyGrow: ((Int) -> Void)?
    /// ヘッダを読み終えたとき（100 Continue などを除く）。true を返すと、中身を流す形にする
    var decideStreaming: (() -> Bool)?
    /// 流す形のときの中身（届いた分ずつ）
    var onChunk: ((Data) -> Void)?
    /// 流す形にしたか
    private(set) var streaming = false
    /// 受け取った中身のバイト数（流す形でも数える）
    private(set) var bodyCount = 0

    private var head = [UInt8]()
    private var headDone = false
    private enum Mode { case length(Int), chunked, untilClose }
    private var mode = Mode.untilClose
    private enum Chunk { case size, data(Int), cr, lf, trailer }
    private var chunk = Chunk.size
    private var line = [UInt8]()
    private var trailerBytes = 0

    init(isHead: Bool, limits: Limits = Limits()) {
        self.isHead = isHead
        self.limits = limits
    }

    func feed(_ d: Data) {
        received += d.count
        var bytes = [UInt8](d)
        while !complete && failure == nil && !bytes.isEmpty {
            if headDone {
                bytes = consumeBody(bytes)
                continue
            }
            head.append(contentsOf: bytes)
            guard let end = findHeadEnd() else {
                if head.count > limits.maxHeaderBytes { fail(.tooLarge("ヘッダが \(limits.maxHeaderBytes / 1024)KB を超えています")) }
                return
            }
            if end > limits.maxHeaderBytes { fail(.tooLarge("ヘッダが \(limits.maxHeaderBytes / 1024)KB を超えています")); return }
            bytes = Array(head[(end + 4)...])
            let headBytes = Array(head[0..<end])
            head = []
            parseHead(headBytes)
            if failure != nil { return }
            if status >= 100 && status < 200 { headDone = false }     // 100 Continue など: 次のヘッダを読む
        }
    }

    /// 相手が閉じた: 「閉じるまで」の形なら、ここで終わり
    func closed() -> Bool {
        if complete { return true }
        if failure != nil { return false }
        if headDone, case .untilClose = mode { complete = true; keepAlive = false; return true }
        return false
    }

    private func fail(_ f: Failure) {
        if failure == nil { failure = f }
        keepAlive = false
    }

    private func findHeadEnd() -> Int? {
        if head.count < 4 { return nil }
        for i in 0...(head.count - 4) where head[i] == 13 && head[i + 1] == 10 && head[i + 2] == 13 && head[i + 3] == 10 { return i }
        return nil
    }

    private func appendBody<C: Collection>(_ b: C) where C.Element == UInt8 {
        if b.isEmpty { return }
        if streaming {
            bodyCount += b.count
            onChunk?(Data(b))
            return
        }
        if body.count + b.count > limits.maxBody {
            fail(.tooLarge("中身が \(limits.maxBody >> 20)MB を超えています"))
            return
        }
        body.append(contentsOf: b)
        bodyCount += b.count
        onBodyGrow?(b.count)
    }

    private func parseHead(_ headBytes: [UInt8]) {
        headDone = true
        var lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        // 状態の行: "HTTP/1.1 200 OK"
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3, let st = Int(parts[1]), (100...599).contains(st) else {
            fail(.malformed("状態の行が読めません: \(first.prefix(60))")); return
        }
        status = st
        if lines.count > limits.maxHeaderCount { fail(.tooLarge("ヘッダが \(limits.maxHeaderCount) 行を超えています")); return }
        var hs: [(String, String)] = []
        for l in lines {
            if l.utf8.count > limits.maxHeaderLine { fail(.tooLarge("ヘッダの 1 行が \(limits.maxHeaderLine / 1024)KB を超えています")); return }
            if l.isEmpty { continue }
            guard let c = l.firstIndex(of: ":") else {
                if l.first == " " || l.first == "\t" { fail(.malformed("折り返したヘッダ（obs-fold）")); return }
                continue
            }
            let name = String(l[..<c])
            if name.isEmpty || name.contains(" ") || name.contains("\t") { fail(.malformed("ヘッダの名前が不正: \(name.prefix(40))")); return }
            hs.append((name, String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
        }
        headers = hs
        let conn = headers.value(for: "Connection")?.lowercased() ?? ""
        keepAlive = first.hasPrefix("HTTP/1.0") ? conn.contains("keep-alive") : !conn.contains("close")
        if status >= 100 && status < 200 { return }

        // 中身の長さの決め方
        let te = headers.values(for: "Transfer-Encoding")
        let cls = headers.values(for: "Content-Length")
        if !te.isEmpty && !cls.isEmpty { fail(.malformed("Transfer-Encoding と Content-Length が両方あります")); return }
        var length: Int?
        if !cls.isEmpty {
            var values = Set<String>()
            for v in cls { for p in HeaderTokens.list(v, lowercase: false) { values.insert(p) } }      // 空の要素も残す（"5," は不正）
            guard values.count == 1, let v = values.first, !v.isEmpty, v.count <= 18, v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else {
                fail(.malformed("Content-Length が不正: \(cls.joined(separator: " / ").prefix(60))")); return
            }
            length = n
        }
        if isHead || status == 204 || status == 304 { complete = true; return }
        streaming = decideStreaming?() ?? false
        if !te.isEmpty {
            let codings = HeaderTokens.list(te.joined(separator: ","), lowercase: true).filter { !$0.isEmpty }
            if codings.last == "chunked" { mode = .chunked }
            else { mode = .untilClose; keepAlive = false }          // chunked で終わらないなら、閉じるまで（RFC 9112 6.3）
        } else if let n = length {
            if n > limits.maxBody && !streaming { fail(.tooLarge("Content-Length が \(limits.maxBody >> 20)MB を超えています（\(n)）")); return }
            mode = .length(n)
            if n == 0 { complete = true }
        } else {
            mode = .untilClose; keepAlive = false
        }
    }

    /// 中身を読む。余り（次の返事の分。普通は無い）を返す
    private func consumeBody(_ b: [UInt8]) -> [UInt8] {
        switch mode {
        case .untilClose:
            appendBody(b)
            return []
        case .length(let n):
            let take = min(max(n - bodyCount, 0), b.count)
            appendBody(b[0..<take])
            if bodyCount >= n { complete = true }
            return Array(b[take...])
        case .chunked:
            var i = 0
            while i < b.count && !complete && failure == nil {
                switch chunk {
                case .size, .trailer:
                    let c = b[i]; i += 1
                    if c != 10 {
                        line.append(c)
                        if case .trailer = chunk {
                            trailerBytes += 1
                            if trailerBytes > limits.maxTrailerBytes { fail(.tooLarge("トレーラーが \(limits.maxTrailerBytes / 1024)KB を超えています")) }
                        } else if line.count > limits.maxChunkLine {
                            fail(.malformed("チャンクのサイズの行が長すぎます"))
                        }
                        continue
                    }
                    if line.last == 13 { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    line = []
                    if case .trailer = chunk {
                        if text.isEmpty { complete = true }
                    } else {
                        let sizeText = (text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                        guard !sizeText.isEmpty, sizeText.count <= 16, sizeText.allSatisfy({ $0.isHexDigit }), let n = Int(sizeText, radix: 16) else {
                            fail(.malformed("チャンクのサイズが不正: \(sizeText.prefix(20))")); break
                        }
                        if !streaming && n > limits.maxBody - body.count { fail(.tooLarge("チャンクが大きすぎます（\(n)）")); break }
                        chunk = n == 0 ? .trailer : .data(n)
                    }
                case .data(let remain):
                    let take = min(remain, b.count - i)
                    appendBody(b[i..<(i + take)])
                    i += take
                    chunk = remain - take == 0 ? .cr : .data(remain - take)
                case .cr:                                     // 中身のあとの \r\n（必ずこの 2 バイト）
                    guard b[i] == 13 else { fail(.malformed("チャンクの後ろが CRLF ではありません")); break }
                    i += 1
                    chunk = .lf
                case .lf:
                    guard b[i] == 10 else { fail(.malformed("チャンクの後ろが CRLF ではありません")); break }
                    i += 1
                    chunk = .size
                }
            }
            return Array(b[min(i, b.count)...])
        }
    }
}
