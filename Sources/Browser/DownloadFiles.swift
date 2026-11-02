import Foundation

// MARK: - ダウンロードのファイル（UI・WebKit に頼らない部分。Linux でテストする）
//
// ・VNet のタブのダウンロードは、WebKit の WKDownload を使わずに VNet が自分でファイルに書く
//   （VNetScheme が引き受けた読み込みを WebKit がダウンロードに変えると、iPad でアプリが落ちたため）
// ・ここには、ダウンロードにするかの判定・ファイル名の決め方・ファイルに書く部品（VNetDownload）を置く

enum DownloadFiles {
    /// 保存先（Documents/Downloads）
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 同じ名前があれば「名前 (2).拡張子」にする
    static func uniqueURL(for name: String, in dir: URL = folder) -> URL {
        let safe = sanitize(name)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var url = dir.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// ファイル名に使えない文字を外す（パスの区切り・制御文字・先頭の「.」）
    static func sanitize(_ raw: String) -> String {
        var s = String(raw.unicodeScalars.map { c -> Character in
            if c.value < 0x20 || c.value == 0x7F || "/\\:".unicodeScalars.contains(c) { return "_" }
            return Character(c)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            s = String(s.prefix(200 - ext.count - 1)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s.isEmpty ? "download" : s
    }

    /// ページとして表示できる種類か（できないものはダウンロードにする）
    static func isDisplayable(mime raw: String) -> Bool {
        let m = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if m.isEmpty { return true }                         // 種類が無い: WebKit に任せる（中身から判断する）
        for p in ["text/", "image/", "video/", "audio/", "multipart/"] where m.hasPrefix(p) { return true }
        let shown: Set<String> = ["application/xhtml+xml", "application/xml", "application/json", "application/javascript",
                                  "application/x-javascript", "application/ecmascript", "application/pdf", "application/rss+xml",
                                  "application/atom+xml", "application/ld+json", "application/manifest+json",
                                  "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/dash+xml"]
        return shown.contains(m)
    }

    /// この返事をダウンロードにするか（ページ本体の返事のときに使う）
    static func isDownload(status: Int, headers: [(String, String)]) -> Bool {
        guard (200...299).contains(status), status != 204 else { return false }
        if let cd = headers.value(for: "Content-Disposition"), cd.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            return true
        }
        guard let ct = headers.value(for: "Content-Type") else { return false }
        return !isDisplayable(mime: ct)
    }

    /// ファイル名を決める（Content-Disposition の filename* → filename → URL の最後 → "download"。拡張子が無ければ種類から足す）
    static func filename(contentDisposition: String?, url: URL?, mime: String?) -> String {
        var name: String?
        if let cd = contentDisposition {
            let params = parseParams(cd)
            if let star = params["filename*"], let v = decodeRFC5987(star), !v.isEmpty { name = v }
            else if let plain = params["filename"], !plain.isEmpty { name = plain }
        }
        if name == nil, let u = url {
            let last = u.lastPathComponent
            if !last.isEmpty && last != "/" { name = last.removingPercentEncoding ?? last }
        }
        var n = sanitize(name.map { ($0 as NSString).lastPathComponent } ?? "download")
        if (n as NSString).pathExtension.isEmpty, let ext = mime.flatMap(extensionFor) { n += "." + ext }
        return n
    }

    static func extensionFor(mime raw: String) -> String? {
        let m = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let map = ["application/pdf": "pdf", "application/zip": "zip", "application/json": "json", "text/plain": "txt",
                   "text/csv": "csv", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "video/mp4": "mp4",
                   "audio/mpeg": "mp3", "application/gzip": "gz", "application/x-tar": "tar", "application/epub+zip": "epub"]
        return map[m]
    }

    /// 「attachment; filename="a.zip"; filename*=UTF-8''a.zip」を名前 → 値にする（名前は小文字）
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        // 最初の「;」まで（attachment など）は飛ばす
        guard let semi = s.firstIndex(of: ";") else { return out }
        i = s.index(after: semi)
        while i < s.endIndex {
            while i < s.endIndex && (s[i] == " " || s[i] == ";") { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: eq)
            var value = ""
            if i < s.endIndex && s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex && s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i])
                    i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let end = s[i...].firstIndex(of: ";") ?? s.endIndex
                value = s[i..<end].trimmingCharacters(in: .whitespaces)
                i = end
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// RFC 5987: 「UTF-8''%E3%81%82.zip」を戻す（UTF-8 と ISO-8859-1 だけ）
    static func decodeRFC5987(_ v: String) -> String? {
        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        let encoded = String(parts[2])
        if charset == "utf-8" { return encoded.removingPercentEncoding }
        if charset == "iso-8859-1" {
            var bytes: [UInt8] = []
            var it = encoded.utf8.makeIterator()
            while let c = it.next() {
                if c == UInt8(ascii: "%"), let h = it.next(), let l = it.next(), let v = UInt8(String(bytes: [h, l], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(v)
                } else {
                    bytes.append(c)
                }
            }
            return String(bytes: bytes, encoding: .isoLatin1)
        }
        return nil
    }
}

/// VNet が自分でファイルに書くダウンロード 1 つ（どのスレッドからでも使える）
final class VNetDownload: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case running, finished, cancelled
        case failed(String)
    }

    let source: URL
    let fileURL: URL
    let expected: Int64
    /// 取り消すとき（VNet の要求を止める）。始めた側が入れる
    var cancelAction: (@Sendable () -> Void)?
    /// 進み具合・状態が変わったとき（間引いて呼ぶ。どのスレッドから呼ばれるかは決まっていない）
    var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "vela-download")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _received: Int64 = 0
    private var _state = State.running
    private var lastNotify = Date.distantPast

    /// ファイルを作る。作れなければ nil
    init?(source: URL, suggestedName: String, expected: Int64, in dir: URL = DownloadFiles.folder) {
        self.source = source
        self.expected = expected
        fileURL = DownloadFiles.uniqueURL(for: suggestedName, in: dir)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle = h
    }

    var received: Int64 { lock.lock(); defer { lock.unlock() }; return _received }
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    func write(_ d: Data) {
        queue.async {
            guard let h = self.handle, self.state == .running else { return }
            h.write(d)
            self.lock.lock()
            self._received += Int64(d.count)
            let now = Date()
            let notify = now.timeIntervalSince(self.lastNotify) > 0.3
            if notify { self.lastNotify = now }
            self.lock.unlock()
            if notify { self.onChange?() }
        }
    }

    /// 最後まで届いた
    func finish() { end(.finished, removeFile: false) }

    /// 失敗した（途中までのファイルは消す）
    func fail(_ why: String) { end(.failed(why), removeFile: true) }

    /// ユーザーが取り消した
    func cancel() {
        cancelAction?()
        end(.cancelled, removeFile: true)
    }

    /// 書き終わるまで待つ（テスト用）
    func waitUntilIdle() { queue.sync {} }

    private func end(_ s: State, removeFile: Bool) {
        queue.async {
            self.lock.lock()
            if self._state != .running { self.lock.unlock(); return }
            self._state = s
            self.lock.unlock()
            try? self.handle?.close()
            self.handle = nil
            if removeFile { try? FileManager.default.removeItem(at: self.fileURL) }
            self.onChange?()
        }
    }
}
