import Foundation

// MARK: - http の返事を少しずつ読む
//
// ヘッダ → 中身。中身の終わりは「長さ指定（Content-Length）」「chunked」「閉じるまで」のどれか。
// 100 Continue などの途中の返事は読み飛ばす

final class ResponseParser {
    let isHead: Bool
    private(set) var status = 0
    private(set) var headers: [(String, String)] = []
    private(set) var body = [UInt8]()
    private(set) var complete = false
    private(set) var keepAlive = true
    /// 届いたバイト数（何も届かずに切れたかを見るため）
    private(set) var received = 0

    private var head = [UInt8]()
    private var headDone = false
    private enum Mode { case length(Int), chunked, untilClose }
    private var mode = Mode.untilClose
    private enum Chunk { case size, data(Int), dataEnd(Int), trailer }
    private var chunk = Chunk.size
    private var line = [UInt8]()

    init(isHead: Bool) { self.isHead = isHead }

    func feed(_ d: Data) {
        received += d.count
        var bytes = [UInt8](d)
        while !complete && !bytes.isEmpty {
            if headDone {
                bytes = consumeBody(bytes)
                continue
            }
            head.append(contentsOf: bytes)
            guard let end = findHeadEnd() else { return }
            bytes = Array(head[(end + 4)...])
            parseHead(Array(head[0..<end]))
            head = []
            if status >= 100 && status < 200 { headDone = false }     // 100 Continue など: 次のヘッダを読む
        }
    }

    /// 相手が閉じた: 「閉じるまで」の形なら、ここで終わり
    func closed() -> Bool {
        if complete { return true }
        if headDone, case .untilClose = mode { complete = true; keepAlive = false; return true }
        return false
    }

    private func findHeadEnd() -> Int? {
        if head.count < 4 { return nil }
        for i in 0...(head.count - 4) where head[i] == 13 && head[i + 1] == 10 && head[i + 2] == 13 && head[i + 3] == 10 { return i }
        return nil
    }

    private func parseHead(_ headBytes: [UInt8]) {
        headDone = true
        var lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        let parts = first.split(separator: " ")
        status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        headers = lines.compactMap { l -> (String, String)? in
            guard let c = l.firstIndex(of: ":") else { return nil }
            return (String(l[..<c]).trimmingCharacters(in: .whitespaces), String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces))
        }
        let conn = headers.value(for: "Connection")?.lowercased() ?? ""
        keepAlive = first.hasPrefix("HTTP/1.0") ? conn.contains("keep-alive") : !conn.contains("close")
        if status >= 100 && status < 200 { return }
        if isHead || status == 204 || status == 304 { complete = true; return }
        if headers.value(for: "Transfer-Encoding")?.lowercased().contains("chunked") == true { mode = .chunked }
        else if let l = headers.value(for: "Content-Length"), let n = Int(l) { mode = .length(n); if n == 0 { complete = true } }
        else { mode = .untilClose; keepAlive = false }
    }

    /// 中身を読む。余り（次の返事の分。普通は無い）を返す
    private func consumeBody(_ b: [UInt8]) -> [UInt8] {
        switch mode {
        case .untilClose:
            body.append(contentsOf: b)
            return []
        case .length(let n):
            let take = min(n - body.count, b.count)
            body.append(contentsOf: b[0..<take])
            if body.count >= n { complete = true }
            return Array(b[take...])
        case .chunked:
            var i = 0
            while i < b.count && !complete {
                switch chunk {
                case .size, .trailer:
                    let c = b[i]; i += 1
                    guard c == 10 else { line.append(c); continue }
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    line = []
                    if case .trailer = chunk {
                        if text.isEmpty { complete = true }
                    } else {
                        let sizeText = text.split(separator: ";").first.map(String.init) ?? ""
                        let n = Int(sizeText, radix: 16) ?? 0
                        chunk = n == 0 ? .trailer : .data(n)
                    }
                case .data(let remain):
                    let take = min(remain, b.count - i)
                    body.append(contentsOf: b[i..<(i + take)])
                    i += take
                    chunk = remain - take == 0 ? .dataEnd(2) : .data(remain - take)
                case .dataEnd(let k):                          // 中身のあとの \r\n
                    i += 1
                    chunk = k - 1 == 0 ? .size : .dataEnd(k - 1)
                }
            }
            return Array(b[i...])
        }
    }
}
