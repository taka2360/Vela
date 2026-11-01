import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif

// MARK: - http の小さな道具（ヘッダ・gzip・クッキー）

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

    /// Content-Encoding に従って戻す。知らない形・戻せないときは nil
    static func decode(_ d: Data, encoding: String) -> Data? {
        // "gzip, br" のように重ねてあるときは、後ろから戻す
        var out = d
        for e in encoding.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).reversed() {
            switch e {
            case "", "identity": continue
            case "gzip", "x-gzip": guard let g = gunzip(out) else { return nil }; out = g
            case "deflate": guard let g = inflateZlib(out) else { return nil }; out = g
            case "br": guard let g = brotli(out) else { return nil }; out = g
            default: return nil
            }
        }
        return out
    }

    /// gzip: 前（10 バイト〜）と後ろ（8 バイト）を外して、生の deflate として戻す
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { return nil }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }   // FEXTRA
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                      // FNAME
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                     // FCOMMENT
        if flags & 2 != 0 { p += 2 }                                                                                  // FHCRC
        guard p < b.count else { return nil }
        return inflateRaw(b[p...])
    }

    /// deflate: 本当は zlib の包み（2 バイト＋後ろ 4 バイト）付き。包みの無い生の deflate を送るサーバーもあるので両方受ける
    static func inflateZlib(_ d: Data) -> Data? {
        let b = [UInt8](d)
        if b.count >= 2 && b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return inflateRaw(b[2...]) }
        return inflateRaw(b[...])
    }

    static func inflateRaw(_ b: ArraySlice<UInt8>) -> Data? {
        #if canImport(Compression)
        return stream(b, COMPRESSION_ZLIB)      // Apple の ZLIB は「生の deflate」
        #else
        return nil
        #endif
    }

    static func brotli(_ d: Data) -> Data? {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return stream([UInt8](d)[...], COMPRESSION_BROTLI) }
        #endif
        return nil
    }

    #if canImport(Compression)
    /// 元の大きさが分からなくても戻せるよう、少しずつ戻す
    private static func stream(_ src: ArraySlice<UInt8>, _ algorithm: compression_algorithm) -> Data? {
        if src.isEmpty { return Data() }
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var s = compression_stream(dst_ptr: out, dst_size: 0, src_ptr: UnsafePointer(out), src_size: 0, state: nil)
        guard compression_stream_init(&s, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&s) }
        var result = Data()
        return src.withUnsafeBufferPointer { sb -> Data? in
            guard let base = sb.baseAddress else { return nil }
            s.src_ptr = base
            s.src_size = sb.count
            while true {
                s.dst_ptr = out
                s.dst_size = chunk
                let st = compression_stream_process(&s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - s.dst_size
                if produced > 0 { result.append(out, count: produced) }
                if st == COMPRESSION_STATUS_END { return result }
                // 壊れている・途中で切れている: 戻せた所までを使う（何も戻せなければ失敗）
                if st != COMPRESSION_STATUS_OK || (produced == 0 && s.src_size == 0) { return result.isEmpty ? nil : result }
                if result.count > 256 << 20 { return nil }
            }
        }
    }
    #endif
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

// MARK: クッキー

/// Set-Cookie の 1 行と、それが来たアドレス
struct CookieLine: Sendable {
    let header: String
    let url: URL
}

/// クッキーを自分の置き場（HTTPCookieStorage）に入れる・送る。
/// 期限切れのものは消す（サーバーも JavaScript も「消す」を期限切れで伝える）
enum CookieSync {
    static func parse(_ line: String, url: URL) -> [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
    }

    static func store(_ line: String, url: URL) {
        let st = HTTPCookieStorage.shared
        for c in parse(line, url: url) {
            if let e = c.expiresDate, e <= Date() {
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                for old in st.cookies ?? [] where old.name == c.name && old.path == c.path
                    && (old.domain == d || old.domain == "." + d) {
                    st.deleteCookie(old)
                }
            } else {
                st.setCookie(c)
            }
        }
    }

    /// 送る Cookie ヘッダの中身。ブラウザ（WebKit）が付けてきたものを先に、
    /// 足りない名前を自分の置き場から足す（同じ名前は 1 つだけ）。無ければ nil
    static func header(for url: URL, browserCookies: [String]) -> String? {
        var jar: [String] = []
        var seen = Set<String>()
        for line in browserCookies {
            for part in line.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces)
                guard !kv.isEmpty else { continue }
                let name = kv.split(separator: "=", maxSplits: 1).first.map(String.init) ?? kv
                if seen.insert(name).inserted { jar.append(kv) }
            }
        }
        for c in HTTPCookieStorage.shared.cookies(for: url) ?? [] where seen.insert(c.name).inserted {
            jar.append("\(c.name)=\(c.value)")
        }
        return jar.isEmpty ? nil : jar.joined(separator: "; ")
    }
}
