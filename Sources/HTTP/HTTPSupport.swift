import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif

// MARK: - http の小さな道具（ヘッダ・gzip・ブラウザらしさ）
//
// Cookie は CookieJar.swift（WebKit の置き場の写し）と Cookies.swift の CookiePolicy に移した

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

// MARK: カンマ区切りのヘッダの値

enum HeaderTokens {
    /// "a, b ,,c" → ["a", "b", "", "c"]。lowercase なら先に全体を小文字にする。カンマで分け（空の要素も残す）、
    /// 各要素の前後の空白（.whitespaces。改行は含まない）を取る。空の要素をどうするかは呼ぶ側が決める
    static func list(_ s: String, lowercase: Bool) -> [String] {
        (lowercase ? s.lowercased() : s).split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

enum HeaderParams {
    /// 「key=value」の属性 1 つを分ける（Set-Cookie の属性・Strict-Transport-Security の指示）。
    /// part は前後の空白を取った、空でないもの（呼ぶ側が trim して空を飛ばす）。最初の = で分け、
    /// キーは前後の空白を取って小文字、値は前後の空白を取る。= が無ければ（全体を小文字, ""）。引用符は外さない
    static func splitAttribute(_ part: String) -> (key: String, value: String) {
        guard let eq = part.firstIndex(of: "=") else { return (part.lowercased(), "") }
        return (part[..<eq].trimmingCharacters(in: .whitespaces).lowercased(),
                part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }
}

// MARK: gzip・zlib の頭（純 Swift。一括と流す形の両方が使う）

enum GzipHeader {
    enum Outcome: Equatable {
        /// 頭がまだ全部届いていない（一括なら壊れている扱い、流す形なら続きを待つ。決めるのは呼ぶ側）
        case needMore
        case bad(String)
        /// 頭の長さ（ここから後ろが deflate）。length <= 渡したバイト数
        case length(Int)
    }

    /// gzip の頭を読む。見るのはマジック・CM=8・FEXTRA・FNAME・FCOMMENT・FHCRC（予約フラグ・CRC は見ない。長さの上限も無い）
    static func parse(_ b: [UInt8]) -> Outcome {
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
        return .length(p)
    }

    /// zlib の包み（2 バイト）か: CM=8 で、2 バイトを 16 ビットとして見ると 31 の倍数
    static func isZlib(_ b0: UInt8, _ b1: UInt8) -> Bool { b0 & 0x0F == 8 && (Int(b0) << 8 | Int(b1)) % 31 == 0 }
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
        for e in HeaderTokens.list(encoding, lowercase: true).reversed() {         // 空の要素は下の case "" で飛ばす
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
        // 一括では、頭が途中までしか無い（needMore）・頭の後ろに 1 バイトも無い、はどちらも壊れている扱い
        switch GzipHeader.parse(b) {
        case .needMore: return .failure(.corrupt("gzip"))
        case .bad(let why): return .failure(.corrupt(why))
        case .length(let p):
            guard p < b.count else { return .failure(.corrupt("gzip")) }
            return inflateRaw(b[p...], name: "gzip", maxOutput: maxOutput)
        }
    }

    /// deflate: 本当は zlib の包み（2 バイト＋後ろ 4 バイト）付き。包みの無い生の deflate を送るサーバーもあるので両方受ける
    static func inflateZlib(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        let b = [UInt8](d)
        if b.count >= 2 && GzipHeader.isZlib(b[0], b[1]) { return inflateRaw(b[2...], name: "deflate", maxOutput: maxOutput) }
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
        let list = HeaderTokens.list(encoding, lowercase: true).filter { !$0.isEmpty && $0 != "identity" }
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
            if GzipHeader.isZlib(b[0], b[1]) { return .done(Array(b[2...])) }
            return .done(b)
        case .gzip:
            // 流す形では、頭が途中までなら続きを待つ（最後まで来ても足りなければ finish が「頭の途中で終わりました」）
            switch GzipHeader.parse(b) {
            case .needMore: return .needMore
            case .bad(let why): return .bad(why)
            case .length(let p): return .done(Array(b[p...]))
            }
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
