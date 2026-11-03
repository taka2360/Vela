import Foundation

// MARK: - ホーム（新しいタブの画面）の設定と、サイトのアイコンの選び方（UI と WebKit に頼らない部分。Linux でテストする）
//
// ・ホームの設定（背景・出す項目・よく見るサイトから外したもの）は home.json
// ・アイコンはホストごとに 1 つ（「www.」は外して比べる）。ページの <link rel="icon"> などから選び、無ければ /favicon.ico
// ・取れたものは 14 日、取れなかったものは 1 日たったら取り直す

/// ホームの背景
enum HomeBackground: Equatable {
    case none
    /// 用意した色（id は HomeLayout.presetIDs のどれか）
    case preset(String)
    /// 自分で選んだ写真（Application Support/Vela/home-wallpaper.jpg）
    case photo

    init(code: String) {
        if code == "photo" { self = .photo }
        else if code.hasPrefix("preset:"), HomeLayout.presetIDs.contains(String(code.dropFirst(7))) { self = .preset(String(code.dropFirst(7))) }
        else { self = .none }
    }

    var code: String {
        switch self {
        case .none: return "none"
        case .preset(let id): return "preset:" + id
        case .photo: return "photo"
        }
    }
}

struct HomeLayout: Codable, Equatable {
    /// 用意した背景の色の名前（見た目は HomeViews.swift）
    static let presetIDs = ["sky", "sunset", "forest", "ocean", "lavender", "night"]
    static let maxTopSites = 8

    /// HomeBackground.code
    var backgroundCode = "none"
    var showBookmarks = true
    var showTopSites = true
    /// よく見るサイトから外したホスト（SiteIconPick.key の形）
    var hiddenTopSites: [String] = []

    var background: HomeBackground {
        get { HomeBackground(code: backgroundCode) }
        set { backgroundCode = newValue.code }
    }

    init() {}

    // 後から項目を足しても、前の home.json を読めるように（無い項目は初期値）
    private enum CodingKeys: String, CodingKey { case backgroundCode, showBookmarks, showTopSites, hiddenTopSites }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backgroundCode = try c.decodeIfPresent(String.self, forKey: .backgroundCode) ?? "none"
        showBookmarks = try c.decodeIfPresent(Bool.self, forKey: .showBookmarks) ?? true
        showTopSites = try c.decodeIfPresent(Bool.self, forKey: .showTopSites) ?? true
        hiddenTopSites = try c.decodeIfPresent([String].self, forKey: .hiddenTopSites) ?? []
    }

    /// よく見るサイトから外す（同じものは 1 つ。多すぎたら古いものから忘れる）
    mutating func hideTopSite(_ url: String) {
        guard let k = SiteIconPick.key(for: url), !hiddenTopSites.contains(k) else { return }
        hiddenTopSites.append(k)
        if hiddenTopSites.count > 200 { hiddenTopSites.removeFirst(hiddenTopSites.count - 200) }
    }

    /// ホームに出すよく見るサイト（外したものを除いて limit 件）
    func visibleTopSites(_ history: HistoryLog, limit: Int = HomeLayout.maxTopSites) -> [HistoryEntry] {
        let hidden = Set(hiddenTopSites)
        let all = history.topSites(limit: limit + hidden.count)
        return Array(all.filter { e in SiteIconPick.key(for: e.url).map { !hidden.contains($0) } ?? true }.prefix(limit))
    }
}

// MARK: サイトのアイコン

/// ページの <link> 1 つ（ページの JavaScript で集める。href は絶対の URL にしてある）
struct IconLink: Codable, Equatable {
    var rel: String
    var href: String
    var sizes: String = ""
    var type: String = ""
}

/// アイコンを取りに行った記録（ホストごと）
struct IconRecord: Codable, Equatable {
    var fetched: Date
    var ok: Bool
    /// ページの <link> を見て取りに行ったか（false なら /favicon.ico などを当てずっぽうで試しただけ）
    var fromPage: Bool
}

enum SiteIconPick {
    static let refreshOK: TimeInterval = 14 * 86_400
    static let retryFailed: TimeInterval = 86_400
    /// 1 つのサイトで試す URL の数
    static let maxTries = 4

    /// ページから <link> を集める JavaScript（JSON の文字列を返す）
    static let collectScript = """
    (() => { const out = []; \
    for (const l of document.querySelectorAll('link[rel][href]')) { \
    const r = (l.getAttribute('rel') || '').toLowerCase(); \
    if (!/(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/.test(r)) continue; \
    out.push({ rel: r, href: String(l.href || ''), sizes: l.getAttribute('sizes') || '', type: l.getAttribute('type') || '' }); \
    if (out.length >= 30) break; } \
    return JSON.stringify(out); })()
    """

    /// アイコンを覚えるときのホストの名前（小文字・「www.」を外す）。http・https でなければ nil
    static func key(for url: String) -> String? {
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              let h = u.host, !h.isEmpty else { return nil }
        return SiteUtil.stripWWW(SiteUtil.normalizeHost(h))
    }

    static func parseLinks(_ json: String) -> [IconLink] {
        guard let d = json.data(using: .utf8), let v = try? JSONDecoder().decode([IconLink].self, from: d) else { return [] }
        return v
    }

    /// sizes="16x16 32x32" の一番大きい辺（無い・any なら nil）
    static func largestSize(_ sizes: String) -> Int? {
        var best: Int?
        for part in sizes.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }) {
            let wh = part.split(separator: "x")
            guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { continue }
            best = max(best ?? 0, min(w, h))
        }
        return best
    }

    /// 取りに行ってよい URL か（http・https。公開のページから LAN の機器へは取りに行かない）
    static func isAllowed(_ icon: URL, page: URL) -> Bool {
        guard let s = icon.scheme?.lowercased(), s == "http" || s == "https", let h = icon.host, !h.isEmpty else { return false }
        if LocalNetworkPolicy.classify(host: h)?.isLocal == true {
            return LocalNetworkPolicy.classify(host: page.host ?? "")?.isLocal == true
        }
        return true
    }

    /// 試す順の URL（よいものから。最後は /favicon.ico）
    static func candidates(links: [IconLink], page: URL) -> [URL] {
        var scored: [(Int, URL)] = []
        for l in links {
            let type = l.type.lowercased()
            let lower = l.href.lowercased()
            // SVG は UIImage で読めない
            if type.contains("svg") || lower.hasSuffix(".svg") || lower.contains(".svg?") { continue }
            guard let u = URL(string: l.href), isAllowed(u, page: page) else { continue }
            let apple = l.rel.contains("apple-touch-icon")
            let size = largestSize(l.sizes) ?? (apple ? 180 : (lower.contains(".ico") ? 32 : 48))
            // 大きいほどよい（256 まで）。apple-touch-icon は四角く作ってあるので上げる。小さすぎるものは下げる
            var score = min(size, 256)
            if apple { score += 120 }
            if size < 32 { score -= 40 }
            scored.append((score, u))
        }
        var out: [URL] = []
        for (_, u) in scored.sorted(by: { $0.0 > $1.0 }) where !out.contains(u) { out.append(u) }
        for f in fallbackCandidates(page: page) where !out.contains(f) { out.append(f) }
        return Array(out.prefix(maxTries))
    }

    /// ページを見ないで試すもの（/apple-touch-icon.png と /favicon.ico）
    static func fallbackCandidates(page: URL) -> [URL] {
        guard var c = URLComponents(url: page, resolvingAgainstBaseURL: false), c.host != nil,
              let s = c.scheme?.lowercased(), s == "http" || s == "https" else { return [] }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        var out: [URL] = []
        for p in ["/apple-touch-icon.png", "/favicon.ico"] {
            c.path = p
            if let u = c.url { out.append(u) }
        }
        return out
    }

    /// 取りに行くべきか（havePageLinks: ページの <link> を見られる）
    static func needsFetch(_ r: IconRecord?, havePageLinks: Bool, now: Date = Date()) -> Bool {
        guard let r else { return true }
        let age = now.timeIntervalSince(r.fetched)
        // 当てずっぽうで取ったもの・取れなかったものは、ページを見られたらすぐ試し直す（よい大きさのものがあるかもしれない）
        if havePageLinks && !r.fromPage { return true }
        return age > (r.ok ? refreshOK : retryFailed)
    }
}
