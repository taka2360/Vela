import SwiftUI
import WebKit

// MARK: - サイトのアイコン（ホームのタイルに出す）
//
// ・ページを読み終えたら、ページの <link rel="icon"> などを集めて、よいものから取りに行く（選び方は HomeModel.swift の SiteIconPick）
// ・まだ開いていないサイト（前からあるブックマークなど）は、ホームに出たときに /apple-touch-icon.png・/favicon.ico を試す
// ・VNet のタブは VNet で、標準の通信のタブは URLSession で取る（どちらも Cookie は送らない）
// ・取れたものは 180px までに縮めて PNG で Application Support/Vela/Icons/<ホスト>.png に置く。記録は icons.json

@MainActor
final class SiteIconStore: ObservableObject {
    /// VNet で 1 つ取りに行く（BrowserStore が入れる。終わったら done(中身 か nil)）
    typealias VNetFetch = @Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void

    /// 新しいアイコンが入るたびに増える（ホームを描き直す合図）
    @Published private(set) var revision = 0
    var log: ((String) -> Void)?
    /// VNet で取る方法（VNet が動いていないなら nil）
    var vnetFetch: VNetFetch?

    static let maxBytes = 1_000_000
    static let maxSide: CGFloat = 180
    static let maxRecords = 1500

    private var records: [String: IconRecord] = [:]
    private var cache: [String: UIImage] = [:]
    /// ファイルが無いと分かっているもの（何度もディスクを見ないように）
    private var missing = Set<String>()
    private var inFlight = Set<String>()
    private let indexFile = JSONFile<[String: IconRecord]>(name: "icons.json", delay: 2)
    private var loaded = false

    /// BrowserStore の初期値として作られる（MainActor の外のことがある）ので、ここでは何もしない。読むのは load
    nonisolated init() {}

    nonisolated static var folder: URL { AppPaths.support.appendingPathComponent("Icons", isDirectory: true) }

    func load(logs: DevLog) {
        if loaded { return }
        loaded = true
        log = { s in logs.add(s, level: .info, category: .app) }
        indexFile.log = { s in logs.add(s) }
        records = indexFile.load() ?? [:]
        try? FileManager.default.createDirectory(at: SiteIconStore.folder, withIntermediateDirectories: true)
    }

    /// そのサイトのアイコン（無ければ nil）
    func image(for url: String) -> UIImage? {
        guard let k = SiteIconPick.key(for: url) else { return nil }
        if let i = cache[k] { return i }
        if missing.contains(k) { return nil }
        if let d = try? Data(contentsOf: fileURL(k)), let i = UIImage(data: d) {
            cache[k] = i
            return i
        }
        missing.insert(k)
        return nil
    }

    /// ページを読み終えた: ページの <link> を見て、要るなら取りに行く
    func pageLoaded(_ webView: WKWebView, page: URL, viaVNet: Bool) {
        guard let k = SiteIconPick.key(for: page.absoluteString), !inFlight.contains(k),
              SiteIconPick.needsFetch(records[k], havePageLinks: true) else { return }
        inFlight.insert(k)
        // 返事は 1 回だけ来る（self を持っていても循環しない）
        webView.evaluateJavaScript(SiteIconPick.collectScript) { result, _ in
            let json = result as? String ?? ""
            Task { @MainActor in
                let links = SiteIconPick.parseLinks(json)
                self.fetch(key: k, candidates: SiteIconPick.candidates(links: links, page: page), fromPage: true, viaVNet: viaVNet)
            }
        }
    }

    /// ホームに出た: まだ一度も試していないサイトなら、/apple-touch-icon.png・/favicon.ico を試す
    func ensure(_ url: String, viaVNet: Bool) {
        guard let k = SiteIconPick.key(for: url), !inFlight.contains(k), let u = URL(string: url),
              SiteIconPick.needsFetch(records[k], havePageLinks: false) else { return }
        inFlight.insert(k)
        fetch(key: k, candidates: SiteIconPick.fallbackCandidates(page: u), fromPage: false, viaVNet: viaVNet)
    }

    /// 全部消す（履歴を全部消したとき）
    func removeAll() {
        records = [:]
        cache = [:]
        missing = []
        indexFile.saveNow(records)
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: SiteIconStore.folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
        revision += 1
        log?("サイトのアイコンを全部消しました")
    }

    // MARK: 取りに行く

    private func fetch(key k: String, candidates: [URL], fromPage: Bool, viaVNet: Bool) {
        let vnet = viaVNet ? vnetFetch : nil
        let fallback = VelaSettings.autoFallbackToNative
        Task { @MainActor in
            var png: Data?
            var source: URL?
            for u in candidates {
                guard let d = await SiteIconStore.download(u, vnet: vnet, fallbackToNative: fallback) else { continue }
                if let p = SiteIconStore.prepare(d) { png = p; source = u; break }
            }
            self.finish(k, png: png, source: source, fromPage: fromPage)
        }
    }

    private func finish(_ k: String, png: Data?, source: URL?, fromPage: Bool) {
        inFlight.remove(k)
        let file = fileURL(k)
        if let png, let img = UIImage(data: png) {
            do {
                try FileManager.default.createDirectory(at: SiteIconStore.folder, withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
                cache[k] = img
                missing.remove(k)
                revision += 1
                log?("アイコンを取りました: \(k)（\(source?.absoluteString ?? "")）")
            } catch {
                log?("⚠️ アイコンを書けません: \(k)（\(error)）")
            }
        }
        // 取り直しに失敗しても、前のものが残っていれば「ある」のまま
        let has = cache[k] != nil || FileManager.default.fileExists(atPath: file.path)
        records[k] = IconRecord(fetched: Date(), ok: has, fromPage: fromPage)
        prune()
        indexFile.save(records)
    }

    /// 記録が増えすぎたら、古いものから忘れる（ファイルも消す）
    private func prune() {
        guard records.count > SiteIconStore.maxRecords else { return }
        let old = records.sorted { $0.value.fetched < $1.value.fetched }.prefix(records.count - SiteIconStore.maxRecords)
        for (k, _) in old {
            records[k] = nil
            cache[k] = nil
            try? FileManager.default.removeItem(at: fileURL(k))
        }
    }

    private func fileURL(_ k: String) -> URL {
        let safe = String(k.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return SiteIconStore.folder.appendingPathComponent(safe + ".png")
    }

    /// 1 つ取る（200 で、大きすぎないものだけ）
    nonisolated private static func download(_ u: URL, vnet: VNetFetch?, fallbackToNative: Bool) async -> Data? {
        if let vnet {
            let d: Data? = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                vnet(u) { d in c.resume(returning: d) }
            }
            if d != nil || !fallbackToNative { return d }
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data, !data.isEmpty, data.count <= maxBytes else {
                    c.resume(returning: nil); return
                }
                c.resume(returning: data)
            }.resume()
        }
    }

    /// 画像として読めるか確かめて、maxSide までに縮めた PNG にする（読めなければ nil。HTML のエラーページなど）
    private static func prepare(_ d: Data) -> Data? {
        guard let img = UIImage(data: d) else { return nil }
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard w >= 8, h >= 8 else { return nil }
        let f = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * f).rounded(), height: (h * f).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
