// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 8 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - HTTPResponseParser.swift
// ======================================================================

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
            for v in cls { for p in v.split(separator: ",", omittingEmptySubsequences: false) { values.insert(p.trimmingCharacters(in: .whitespaces)) } }
            guard values.count == 1, let v = values.first, !v.isEmpty, v.count <= 18, v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else {
                fail(.malformed("Content-Length が不正: \(cls.joined(separator: " / ").prefix(60))")); return
            }
            length = n
        }
        if isHead || status == 204 || status == 304 { complete = true; return }
        streaming = decideStreaming?() ?? false
        if !te.isEmpty {
            let codings = te.joined(separator: ",").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

// ======================================================================
// MARK: - HTTPSupport.swift
// ======================================================================

// MARK: - http の小さな道具（ヘッダ・gzip・ブラウザらしさ）
//
// Cookie は CookieJar.swift（WebKit の置き場の写し）と NetPolicy.swift の CookiePolicy に移した

/// ヘッダ（名前, 値）の並び。名前の大文字小文字は区別しない
extension Array where Element == (String, String) {
    func value(for name: String) -> String? {
        let n = name.lowercased()
        return first { $0.0.lowercased() == n }?.1
    }

    func values(for name: String) -> [String] {
        let n = name.lowercased()
        return filter { $0.0.lowercased() == n }.map { $0.1 }
    }

    /// names は小文字で渡す
    mutating func removeAll(named names: Set<String>) {
        removeAll { names.contains($0.0.lowercased()) }
    }
}

// MARK: 縮めた中身を戻す（gzip・deflate・br）

enum ContentDecoding {
    /// 送る Accept-Encoding（Safari と同じ。br は iOS 15 から）
    static var acceptEncoding: String {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return "gzip, deflate, br" }
        return "gzip, deflate"
        #else
        return "identity"
        #endif
    }

    enum Failure: Error, Equatable {
        /// 知らない縮め方（この環境で戻せないものも）
        case unsupported(String)
        /// 壊れている・途中で切れている
        case corrupt(String)
        /// 戻した大きさが上限を超えた（圧縮爆弾など）
        case tooLarge(Int)

        var description: String {
            switch self {
            case .unsupported(let e): return "戻せない縮め方です（\(e)）"
            case .corrupt(let e): return "縮めた中身（\(e)）が壊れています"
            case .tooLarge(let n): return "戻した中身が \(n >> 20)MB を超えます"
            }
        }
    }

    /// Content-Encoding に従って戻す。戻した大きさは maxOutput まで
    static func decode(_ d: Data, encoding: String, maxOutput: Int = 32 << 20) -> Result<Data, Failure> {
        // "gzip, br" のように重ねてあるときは、後ろから戻す
        var out = d
        for e in encoding.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).reversed() {
            let r: Result<Data, Failure>
            switch e {
            case "", "identity": continue
            case "gzip", "x-gzip": r = gunzip(out, maxOutput: maxOutput)
            case "deflate": r = inflateZlib(out, maxOutput: maxOutput)
            case "br": r = brotli(out, maxOutput: maxOutput)
            default: return .failure(.unsupported(e))
            }
            switch r {
            case .success(let g): out = g
            case .failure(let f): return .failure(f)
            }
        }
        return .success(out)
    }

    /// gzip: 前（10 バイト〜）と後ろ（8 バイト）を外して、生の deflate として戻す
    static func gunzip(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return .failure(.corrupt("gzip の頭が違います")) }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { return .failure(.corrupt("gzip")) }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }   // FEXTRA
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                      // FNAME
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                     // FCOMMENT
        if flags & 2 != 0 { p += 2 }                                                                                  // FHCRC
        guard p < b.count else { return .failure(.corrupt("gzip")) }
        return inflateRaw(b[p...], name: "gzip", maxOutput: maxOutput)
    }

    /// deflate: 本当は zlib の包み（2 バイト＋後ろ 4 バイト）付き。包みの無い生の deflate を送るサーバーもあるので両方受ける
    static func inflateZlib(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        let b = [UInt8](d)
        if b.count >= 2 && b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return inflateRaw(b[2...], name: "deflate", maxOutput: maxOutput) }
        return inflateRaw(b[...], name: "deflate", maxOutput: maxOutput)
    }

    static func inflateRaw(_ b: ArraySlice<UInt8>, name: String, maxOutput: Int) -> Result<Data, Failure> {
        #if canImport(Compression)
        return stream(b, COMPRESSION_ZLIB, name: name, maxOutput: maxOutput)      // Apple の ZLIB は「生の deflate」
        #else
        return .failure(.unsupported(name))
        #endif
    }

    static func brotli(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return stream([UInt8](d)[...], COMPRESSION_BROTLI, name: "br", maxOutput: maxOutput) }
        #endif
        return .failure(.unsupported("br"))
    }

    #if canImport(Compression)
    /// 元の大きさが分からなくても戻せるよう、少しずつ戻す。最後まで戻せなかったら壊れている扱い
    private static func stream(_ src: ArraySlice<UInt8>, _ algorithm: compression_algorithm, name: String, maxOutput: Int) -> Result<Data, Failure> {
        if src.isEmpty { return .success(Data()) }
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var s = compression_stream(dst_ptr: out, dst_size: 0, src_ptr: UnsafePointer(out), src_size: 0, state: nil)
        guard compression_stream_init(&s, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return .failure(.unsupported(name)) }
        defer { compression_stream_destroy(&s) }
        var result = Data()
        return src.withUnsafeBufferPointer { sb -> Result<Data, Failure> in
            guard let base = sb.baseAddress else { return .failure(.corrupt(name)) }
            s.src_ptr = base
            s.src_size = sb.count
            while true {
                s.dst_ptr = out
                s.dst_size = chunk
                let st = compression_stream_process(&s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - s.dst_size
                if result.count + produced > maxOutput { return .failure(.tooLarge(maxOutput)) }
                if produced > 0 { result.append(out, count: produced) }
                if st == COMPRESSION_STATUS_END { return .success(result) }
                if st != COMPRESSION_STATUS_OK { return .failure(.corrupt(name)) }
                if produced == 0 && s.src_size == 0 { return .failure(.corrupt("\(name)・途中で切れています")) }
            }
        }
    }
    #endif
}

// MARK: 少しずつ届く縮めた中身を、少しずつ戻す（流す形のとき）

/// 流す形の返事の Content-Encoding を、届いた分ずつ戻す。1 種類の縮め方だけ（重ねてあるものは流さずに貯める形で読む）
final class StreamDecoder {
    enum Kind { case gzip, deflate, br }

    /// 縮め方から作る。縮めていない（identity）なら nil。流す形で戻せないものは失敗
    static func make(encoding: String) -> Result<StreamDecoder?, ContentDecoding.Failure> {
        let list = encoding.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "identity" }
        if list.isEmpty { return .success(nil) }
        guard list.count == 1 else { return .failure(.unsupported(encoding)) }
        let kind: Kind
        switch list[0] {
        case "gzip", "x-gzip": kind = .gzip
        case "deflate": kind = .deflate
        case "br": kind = .br
        default: return .failure(.unsupported(list[0]))
        }
        #if canImport(Compression)
        if kind == .br, #unavailable(iOS 15.0, macOS 12.0) { return .failure(.unsupported("br")) }
        guard let d = StreamDecoder(kind: kind) else { return .failure(.unsupported(list[0])) }
        return .success(d)
        #else
        return .failure(.unsupported(list[0]))
        #endif
    }

    let kind: Kind
    let maxOutput: Int
    private(set) var produced = 0
    /// 頭（gzip の 10 バイト〜・zlib の 2 バイト）を読み終えるまで貯めておく
    private var head = [UInt8]()
    private var headDone = false
    private var ended = false

    #if canImport(Compression)
    private var stream: compression_stream
    private var started = false

    private init?(kind: Kind, maxOutput: Int = Int.max) {
        self.kind = kind
        self.maxOutput = maxOutput
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        let algorithm: compression_algorithm
        if kind == .br {
            if #available(iOS 15.0, macOS 12.0, *) { algorithm = COMPRESSION_BROTLI } else { return nil }
        } else {
            algorithm = COMPRESSION_ZLIB      // Apple の ZLIB は「生の deflate」
        }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        started = true
    }

    deinit { if started { compression_stream_destroy(&stream) } }
    #else
    private init?(kind: Kind, maxOutput: Int = Int.max) { return nil }
    #endif

    /// 届いた分を戻す
    func feed(_ d: Data) -> Result<Data, ContentDecoding.Failure> {
        if ended { return .success(Data()) }          // 終わった後のもの（gzip の後ろの 8 バイトなど）は捨てる
        var bytes = [UInt8](d)
        if !headDone {
            head += bytes
            switch skipHead() {
            case .needMore: return .success(Data())
            case .bad(let why): return .failure(.corrupt(why))
            case .done(let rest): headDone = true; bytes = rest; head = []
            }
        }
        return process(bytes, finalize: false)
    }

    /// 最後まで届いた
    func finish() -> Result<Data, ContentDecoding.Failure> {
        if ended { return .success(Data()) }
        if !headDone { return .failure(.corrupt("頭の途中で終わりました")) }
        return process([], finalize: true)
    }

    private enum HeadResult { case needMore, bad(String), done([UInt8]) }

    private func skipHead() -> HeadResult {
        let b = head
        switch kind {
        case .br:
            return .done(b)
        case .deflate:
            // zlib の包み（2 バイト）があれば外す。無いもの（生の deflate）も受ける
            if b.count < 2 { return .needMore }
            if b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return .done(Array(b[2...])) }
            return .done(b)
        case .gzip:
            if b.count < 10 { return .needMore }
            guard b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return .bad("gzip の頭が違います") }
            let flags = b[3]
            var p = 10
            if flags & 4 != 0 {                                         // FEXTRA
                guard p + 2 <= b.count else { return .needMore }
                p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
            }
            for flag in [UInt8(8), 16] where flags & flag != 0 {        // FNAME・FCOMMENT（0 で終わる）
                guard let z = b[min(p, b.count)...].firstIndex(of: 0) else { return .needMore }
                p = z + 1
            }
            if flags & 2 != 0 { p += 2 }                                 // FHCRC
            if p > b.count { return .needMore }
            return .done(Array(b[p...]))
        }
    }

    private func process(_ src: [UInt8], finalize: Bool) -> Result<Data, ContentDecoding.Failure> {
        #if canImport(Compression)
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var result = Data()
        let name = "\(kind)"
        return src.withUnsafeBufferPointer { sb -> Result<Data, ContentDecoding.Failure> in
            let empty: [UInt8] = [0]
            return empty.withUnsafeBufferPointer { eb -> Result<Data, ContentDecoding.Failure> in
                stream.src_ptr = sb.baseAddress ?? eb.baseAddress!
                stream.src_size = sb.count
                while true {
                    stream.dst_ptr = out
                    stream.dst_size = chunk
                    let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let st = compression_stream_process(&stream, flags)
                    let n = chunk - stream.dst_size
                    if produced + n > maxOutput { return .failure(.tooLarge(maxOutput)) }
                    if n > 0 { result.append(out, count: n); produced += n }
                    if st == COMPRESSION_STATUS_END { ended = true; return .success(result) }
                    if st != COMPRESSION_STATUS_OK { return .failure(.corrupt(name)) }
                    // 入れたものを全部使い切って、出てくるものも無くなったら、次の分を待つ
                    if stream.src_size == 0 && n < chunk {
                        if finalize && n == 0 { return .failure(.corrupt("\(name)・途中で切れています")) }
                        if !finalize { return .success(result) }
                    }
                }
            }
        }
        #else
        return .failure(.unsupported("\(kind)"))
        #endif
    }
}

// MARK: ブラウザらしさ（User-Agent・言語）

enum BrowserIdentity {
    /// iPad の Safari（デスクトップ用の表示。iPad の Safari の初期設定と同じ）の User-Agent。
    /// WKWebView の初期値は「Version/… Safari/…」が無く、アプリの中のブラウザやロボットだと思われやすい
    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion).\(v.minorVersion) Safari/605.1.15"
    }()

    /// Accept-Language（端末の言語の順。例: "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"）
    static let acceptLanguage: String = {
        var langs: [String] = []
        for l in Locale.preferredLanguages.prefix(3) {
            let tag = l.replacingOccurrences(of: "_", with: "-")
            if !langs.contains(tag) { langs.append(tag) }
            if let base = tag.split(separator: "-").first.map(String.init), base != tag, !langs.contains(base) { langs.append(base) }
        }
        if langs.isEmpty { langs = ["ja-JP", "ja"] }
        return langs.prefix(6).enumerated().map { i, l in
            i == 0 ? l : "\(l);q=\(String(format: "%.1f", max(0.1, 1.0 - Double(i) * 0.1)))"
        }.joined(separator: ",")
    }()
}

// ======================================================================
// MARK: - TLSClient.swift
// ======================================================================

// MARK: - https の暗号（TLS）を、自作の TCP の上で動かす
//
// iPad の普通の通信の部品（Network.framework）は、自分で作った TCP の上では TLS を使えない。
// そこで、古いけれど今も使える Apple の「SecureTransport」（SSLCreateContext など）を使う。
// これは「読む・書く」を自分で用意できるので、GuestTCP の上で TLS 1.2 を話せる。
// 証明書は iPad と同じ仕組みで確かめる（相手の名前も確かめる）。
// ブラウザらしく見えるよう: ALPN（http/1.1）を名乗る・前の暗号の約束を使い回す（セッション再開。握手が速くなる）
//
// 注意（技術的負債）: SecureTransport は 2019 年から非推奨で、TLS 1.3 には対応しない（Apple TN3151）。
// なので VNet の TLS は 1.2 まで。TLS 1.3 だけのサーバーは版が合わずに失敗する（versionMismatch）。そのときは標準の通信で開く。
// 自作の TCP の上では Network.framework の TLS を使えないので、TLS エンジンの移行は別の課題にしている
//
// 使い方: TLSStream(host:) を作る → TCP がつながったら attach → onReady で write → onData で中身が届く → onClosed
// SecureTransport が無い環境では TLSStream(host:) が nil を返す（https は使えない）

#if canImport(Security) && os(iOS)
final class TLSStream: @unchecked Sendable {
    static let isSupported = true
    let host: String
    private let ctx: SSLContext
    private var tcp: GuestTCP?
    /// TCP から届いて、まだ TLS に渡していないもの（inbox[inboxPos...]）。先頭を消すと遅いので、位置で覚える
    private var inbox = [UInt8]()
    private var inboxPos = 0
    private var tcpEnded = false
    private var handshaking = true
    private var pendingWrite = Data()
    private var done = false
    /// 握手に失敗したときの番号（0 なら握手の失敗ではない）
    private(set) var handshakeError: OSStatus = 0
    /// 決まった版（"TLS 1.2" など）
    private(set) var version = ""
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    init?(host: String, port: UInt16 = 443) {
        self.host = host
        guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
        ctx = c
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetProtocolVersionMax(ctx, .tlsProtocol12)      // SecureTransport は 1.3 を話せない
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
        SSLSetALPNProtocols(ctx, ["http/1.1"] as CFArray)
        let peer = Array("\(host):\(port)".utf8)
        _ = peer.withUnsafeBytes { SSLSetPeerID(ctx, $0.baseAddress, $0.count) }
    }

    /// 証明書の問題での失敗か
    var failedOnCertificate: Bool { handshakeError <= -9807 && handshakeError >= -9815 }

    /// 版や暗号の組み合わせが合わずに失敗したか（相手が TLS 1.3 だけなど）
    /// -9836: errSSLPeerProtocolVersion（相手が版を断った）、-9831: errSSLPeerHandshakeFail、-9801: errSSLNegotiation、-9830: errSSLIllegalParam
    var versionMismatch: Bool { [-9836, -9831, -9801].contains(handshakeError) }

    /// TCP がつながったら呼ぶ
    func attach(_ t: GuestTCP) {
        tcp = t
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        drive()
    }

    /// TCP から届いたもの
    func tcpData(_ d: Data) {
        if inboxPos > 65536 && inboxPos * 2 > inbox.count { inbox.removeFirst(inboxPos); inboxPos = 0 }
        inbox.append(contentsOf: d)
        drive()
    }

    func tcpClosed(_ error: String?) {
        tcpEnded = true
        // まだ attach していない（TCP がつながる前に閉じた・取り消した）: SecureTransport には触らない。
        // SSLSetConnection の前に SSLHandshake を呼ぶと、tlsWrite に null が来て落ちた（実機の記録: TLSStream.writeFrom で 0x28）
        if tcp != nil { drive() }
        if !done { finish(error ?? (handshaking ? "TLS の途中で切れました" : nil)) }
    }

    /// 暗号にして送る（つながる前なら、つながってから送る）
    func write(_ d: Data) {
        if done { return }
        if handshaking { pendingWrite.append(d); return }
        // 書き込みの関数（tlsWrite）は全部を TCP に渡すので、普通は 1 回で全部書ける。
        // それでも、書けた分を確かめて残りを書く。エラーなら閉じる（黙って捨てない）
        var offset = 0
        while offset < d.count {
            var processed = 0
            let st = d.withUnsafeBytes { buf -> OSStatus in
                SSLWrite(ctx, buf.baseAddress! + offset, d.count - offset, &processed)
            }
            offset += processed
            if st == errSSLWouldBlock && processed > 0 { continue }
            if st != errSecSuccess {
                finish("TLS の書き込みに失敗（\(st)）")
                return
            }
            if processed == 0 { finish("TLS の書き込みが進みません"); return }
        }
    }

    private func finish(_ error: String?) {
        if done { return }
        done = true
        tcp?.abort()
        onClosed?(error)
    }

    /// 進められるところまで進める（握手 → 読む）
    private func drive() {
        if done || tcp == nil { return }
        if handshaking {
            let st = SSLHandshake(ctx)
            if st == errSSLWouldBlock { return }
            if st != errSecSuccess {
                handshakeError = st
                finish("TLS の握手に失敗（\(st)）" + (failedOnCertificate ? "：証明書を確かめられません"
                                                   : versionMismatch ? "：TLS の版が合いません（VNet は TLS 1.2 まで）" : ""))
                return
            }
            handshaking = false
            var p = SSLProtocol.sslProtocolUnknown
            SSLGetNegotiatedProtocolVersion(ctx, &p)
            version = p == .tlsProtocol13 ? "TLS 1.3" : p == .tlsProtocol12 ? "TLS 1.2" : "TLS（\(p.rawValue)）"
            onReady?()
            if !pendingWrite.isEmpty { let w = pendingWrite; pendingWrite = Data(); write(w) }
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var n = 0
            let st = buf.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress!, $0.count, &n) }
            if n > 0 { onData?(Data(buf[0..<n])) }
            if st == errSSLWouldBlock { if tcpEnded && inboxPos >= inbox.count { finish(nil) }; return }
            if st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == errSSLClosedAbort { finish(nil); return }
            if st != errSecSuccess { finish("TLS の読み込みに失敗（\(st)）"); return }
        }
    }

    // SecureTransport から呼ばれる「読む・書く」
    fileprivate func readInto(_ p: UnsafeMutableRawPointer, _ want: Int) -> (Int, OSStatus) {
        let avail = inbox.count - inboxPos
        if avail <= 0 { return (0, tcpEnded ? errSSLClosedNoNotify : errSSLWouldBlock) }
        let n = min(want, avail)
        inbox.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + inboxPos, byteCount: n) }
        inboxPos += n
        return (n, n < want ? errSSLWouldBlock : errSecSuccess)
    }

    fileprivate func writeFrom(_ p: UnsafeRawPointer, _ n: Int) -> OSStatus {
        guard let t = tcp else { return errSSLClosedAbort }
        t.write(Data(bytes: p, count: n))
        return errSecSuccess
    }
}

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    // 念のため: 接続の印が無ければ（SSLSetConnection の前）何も読まない
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    let (n, st) = s.readInto(data, length.pointee)
    length.pointee = n
    return st
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    return s.writeFrom(data, length.pointee)
}
#else
/// SecureTransport が無い環境用の代わり（作れない）
final class TLSStream: @unchecked Sendable {
    static let isSupported = false
    let handshakeError: Int32 = 0
    let version = ""
    var failedOnCertificate: Bool { false }
    var versionMismatch: Bool { false }
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?
    init?(host: String, port: UInt16 = 443) { return nil }
    func attach(_ t: GuestTCP) {}
    func tcpData(_ d: Data) {}
    func tcpClosed(_ error: String?) {}
    func write(_ d: Data) {}
}
#endif

// ======================================================================
// MARK: - GuestStack.swift
// ======================================================================

// MARK: - ゲスト側の小さな TCP/IP（Linux の代わり）
//
// ・DHCP で IP アドレスをもらう（ルーター UserNet が 10.0.2.15 をくれる）
// ・ARP でルーター（10.0.2.2）の MAC アドレスを調べる
// ・DNS（10.0.2.3）で名前を IP アドレスにする
// ・TCP でつなぐ（GuestTCP。送り直し・順番の確認など最低限）
// すべて queue（VNetMachine.queue）の上で動く

final class GuestStack: @unchecked Sendable {
    let queue: DispatchQueue
    /// フレームを送る（ドライバへ）
    var output: (([UInt8]) -> Void)?
    /// 何が起きたかを知らせる（画面のログ用）
    var trace: ((String) -> Void)?
    /// TCP の送り直しの回数（開発者向け。queue の上で数える）
    var retransmits = 0
    /// 順番を飛ばして届き、取っておいた TCP のセグメントの数（開発者向け）
    var reordered = 0

    var mac = Net.guestMAC
    private(set) var ip = Net.zeroIP
    private(set) var router = Net.gateway
    private(set) var dns = Net.dns
    private(set) var ready = false
    private var routerMAC: [UInt8]?
    /// ルーターの MAC が分かるまで待たせる IP パケット
    private var waitingForARP: [[UInt8]] = []
    private var ipID: UInt16 = 1
    private var nextPort: UInt16 = 40000
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: 受け取り

    func input(_ f: [UInt8]) {
        guard f.count >= Ethernet.headerSize else { return }
        let body = Array(f[Ethernet.headerSize...])
        switch f.be16(at: 12) {
        case EtherType.arp: handleARP(body)
        case EtherType.ipv4: handleIPv4(body)
        default: break
        }
    }

    // MARK: イーサネット・ARP

    private func sendEthernet(_ type: UInt16, to dst: [UInt8], _ payload: [UInt8]) {
        output?(Ethernet.frame(dst: dst, src: mac, type: type, payload))
    }

    private func askRouterMAC() {
        let a = ARP.packet(op: ARP.request, senderMAC: mac, senderIP: ip, targetMAC: Net.zeroMAC, targetIP: router)
        sendEthernet(EtherType.arp, to: Net.broadcastMAC, a)
        trace?("→ ARP \(router.ipString) はどこ？")
    }

    private func handleARP(_ p: [UInt8]) {
        guard p.count >= 28 else { return }
        let op = p.be16(at: 6)
        let senderMAC = Array(p[8..<14]), senderIP = Array(p[14..<18]), target = Array(p[24..<28])
        if op == ARP.reply && senderIP == router {
            if routerMAC == nil { trace?("← ARP \(router.ipString) は \(senderMAC.macString)") }
            routerMAC = senderMAC
            let w = waitingForARP
            waitingForARP = []
            for pkt in w { sendEthernet(EtherType.ipv4, to: senderMAC, pkt) }
        } else if op == ARP.request && target == ip && ip != Net.zeroIP {
            let r = ARP.packet(op: ARP.reply, senderMAC: mac, senderIP: ip, targetMAC: senderMAC, targetIP: senderIP)
            sendEthernet(EtherType.arp, to: senderMAC, r)
        }
    }

    // MARK: IPv4

    private func sendIPv4(proto: UInt8, dst: [UInt8], _ body: [UInt8], broadcast: Bool = false) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: ip, dst: dst, body)
        ipID &+= 1
        if broadcast { sendEthernet(EtherType.ipv4, to: Net.broadcastMAC, pkt); return }
        // 外へは全部ルーター経由（10.0.2.x もルーターが答える）
        if let m = routerMAC { sendEthernet(EtherType.ipv4, to: m, pkt) } else {
            waitingForARP.append(pkt)
            askRouterMAC()
        }
    }

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p) else { return }
        switch pkt.proto {
        case IPProto.tcp: handleTCP(src: pkt.src, pkt.body)
        case IPProto.udp: handleUDP(pkt.body)
        default: break
        }
    }

    // MARK: UDP（DHCP と DNS）

    private func sendUDP(sport: UInt16, dst: [UInt8], dport: UInt16, _ payload: [UInt8], broadcast: Bool = false) {
        let u = UDPDatagram.build(src: ip, dst: dst, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, dst: dst, u, broadcast: broadcast)
    }

    private func handleUDP(_ b: [UInt8]) {
        guard let u = UDPDatagram(b) else { return }
        if u.sport == 67 && u.dport == 68 { handleDHCP(u.payload) }
        else if u.sport == 53, let q = dnsQueries.removeValue(forKey: u.dport) { q.finish(u.payload) }
    }

    private func allocPort() -> UInt16 {
        nextPort = nextPort >= 60000 ? 40000 : nextPort + 1
        return nextPort
    }

    // MARK: DHCP

    private let dhcpXID = UInt32.random(in: 1...UInt32.max)
    private var dhcpSentAt = Date.distantPast
    private var onReady: [() -> Void] = []

    /// IP アドレスをもらう（もらえたら done が呼ばれる）
    func start(_ done: @escaping () -> Void) {
        onReady.append(done)
        sendDHCP(type: DHCP.discover, requested: nil)
    }

    private func sendDHCP(type: UInt8, requested: [UInt8]?) {
        var m = [UInt8](repeating: 0, count: 236)
        m[0] = 1; m[1] = 1; m[2] = 6                       // 問い合わせ・イーサネット・MAC は 6 バイト
        m.setBE32(dhcpXID, at: 4)
        m[10] = 0x80                                       // ブロードキャストで返してほしい
        m.replaceSubrange(28..<34, with: mac)
        m += DHCP.magicCookie
        m += [53, 1, type]
        if let r = requested {
            // 配列を + でつなぐと型チェックがとても遅いので、1 つずつ足す
            m.append(contentsOf: [50, 4] as [UInt8])
            m.append(contentsOf: r)
            m.append(contentsOf: [54, 4] as [UInt8])
            m.append(contentsOf: router)
        }
        m += [55, 3, 1, 3, 6, 255]                         // ほしいもの: サブネット・ルーター・DNS
        sendUDP(sport: 68, dst: Net.broadcastIP, dport: 67, m, broadcast: true)
        dhcpSentAt = Date()
        trace?(type == DHCP.discover ? "→ DHCP DISCOVER（IP アドレスをください）" : "→ DHCP REQUEST")
    }

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 2, p.be32(at: 4) == dhcpXID else { return }
        let yiaddr = Array(p[16..<20])
        let opts = DHCP.options(p)
        if let r = opts[3], r.count >= 4 { router = Array(r[0..<4]) }
        if let d = opts[6], d.count >= 4 { dns = Array(d[0..<4]) }
        let type = opts[53]?.first ?? 0
        if type == DHCP.offer {
            trace?("← DHCP OFFER \(yiaddr.ipString)")
            sendDHCP(type: DHCP.request, requested: yiaddr)
        } else if type == DHCP.ack && !ready {
            ip = yiaddr
            ready = true
            trace?("← DHCP ACK: IP \(ip.ipString)・ルーター \(router.ipString)・DNS \(dns.ipString)")
            let w = onReady
            onReady = []
            for f in w { f() }
        }
    }

    // MARK: DNS

    private final class DNSQuery {
        let packet: [UInt8]
        let done: ([UInt8]?) -> Void
        var sentAt = Date()
        var tries = 0
        private var finished = false
        init(packet: [UInt8], done: @escaping ([UInt8]?) -> Void) { self.packet = packet; self.done = done }
        func finish(_ reply: [UInt8]?) {
            if finished { return }
            finished = true
            done(reply.flatMap(DNSMessage.firstA))
        }
    }
    private var dnsQueries: [UInt16: DNSQuery] = [:]

    /// 名前を IPv4 アドレスにする（IP アドレスの形ならそのまま）
    func resolve(_ name: String, _ done: @escaping ([UInt8]?) -> Void) {
        let labels = name.split(separator: ".")
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4 && octets.count == 4 { done(octets); return }
        let packet = DNSMessage.query(name: name, id: .random(in: 0...UInt16.max))
        let port = allocPort()
        dnsQueries[port] = DNSQuery(packet: packet) { [weak self] ip in
            self?.trace?("← DNS \(name) = " + (ip?.ipString ?? "見つからない"))
            done(ip)
        }
        trace?("→ DNS \(name) は？")
        sendUDP(sport: port, dst: dns, dport: 53, packet)
    }

    // MARK: TCP

    private struct TCPKey: Hashable { let lport: UInt16; let rip: [UInt8]; let rport: UInt16 }
    private var tcps: [TCPKey: GuestTCP] = [:]

    private static func key(_ c: GuestTCP) -> TCPKey { TCPKey(lport: c.lport, rip: c.rip, rport: c.rport) }

    /// TCP でつなぐ
    func connect(_ rip: [UInt8], _ rport: UInt16, handler: GuestTCP.Handler) -> GuestTCP {
        let c = GuestTCP(stack: self, lport: allocPort(), rip: rip, rport: rport, handler: handler)
        tcps[GuestStack.key(c)] = c
        c.sendSYN()
        trace?("→ TCP SYN \(rip.ipString):\(rport)")
        return c
    }

    /// 終わった接続を忘れる（GuestTCP から呼ぶ）
    func forget(_ c: GuestTCP) {
        tcps[GuestStack.key(c)] = nil
    }

    /// 組み立てた TCP セグメントを送る（GuestTCP から呼ぶ）
    func sendTCP(to dst: [UInt8], _ segment: [UInt8]) {
        sendIPv4(proto: IPProto.tcp, dst: dst, segment)
    }

    private func handleTCP(src: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b), let c = tcps[TCPKey(lport: h.dport, rip: src, rport: h.sport)] else { return }
        c.input(h, payload: b[h.headerLength...])
    }

    // MARK: 時間で見るもの（DHCP・DNS・TCP の送り直し）

    private func tick() {
        let now = Date()
        if !ready && now.timeIntervalSince(dhcpSentAt) > 2 && !onReady.isEmpty { sendDHCP(type: DHCP.discover, requested: nil) }
        for (port, q) in dnsQueries where now.timeIntervalSince(q.sentAt) > 2 {
            q.tries += 1
            if q.tries > 3 { dnsQueries[port] = nil; q.finish(nil); continue }
            q.sentAt = now
            sendUDP(sport: port, dst: dns, dport: 53, q.packet)
        }
        for c in Array(tcps.values) { c.tick(now) }
    }
}
