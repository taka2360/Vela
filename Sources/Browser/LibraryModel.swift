import Foundation

// MARK: - ブックマーク・履歴・アドレス欄の候補・文字の大きさ（UI と WebKit に頼らない部分。Linux でテストする）
//
// ・同じページかどうかは LibraryKey.normalize で比べる（#… を外す・スキームとホストを小文字に・末尾の「/」だけの違いを無視）
// ・履歴は URL ごとに 1 つ（最後に見た時刻・見た回数・タイトル）。新しい順。最大 HistoryLog.maxEntries 件
// ・候補は「入れた文字で始まるサイト」を一番上に。ブックマーク・よく見る・最近見たものを上げる

enum LibraryKey {
    /// 比べるための形（保存はしない）
    static func normalize(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.path == "/" && c.query == nil { c.path = "" }
        return c.string ?? s
    }

    /// 履歴・ブックマークに入れてよい URL か（http・https だけ）
    static func isRecordable(_ u: URL) -> Bool {
        let s = u.scheme?.lowercased()
        return (s == "http" || s == "https") && u.host?.isEmpty == false
    }

    /// 候補の照らし合わせ用（スキームと「www.」を外して小文字に）
    static func bare(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        return SiteUtil.stripWWW(t)
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var url: String
    var added: Date
}

struct BookmarkList: Codable, Equatable {
    var items: [Bookmark] = []

    func find(_ url: String) -> Bookmark? {
        let k = LibraryKey.normalize(url)
        return items.first { LibraryKey.normalize($0.url) == k }
    }

    func contains(_ url: String) -> Bool { find(url) != nil }

    /// 足す（同じページが既にあれば足さずに false）
    @discardableResult
    mutating func add(title: String, url: String, now: Date = Date()) -> Bool {
        if contains(url) { return false }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(Bookmark(id: UUID(), title: t.isEmpty ? url : t, url: url, added: now))
        return true
    }

    mutating func remove(id: UUID) { items.removeAll { $0.id == id } }

    mutating func remove(url: String) {
        let k = LibraryKey.normalize(url)
        items.removeAll { LibraryKey.normalize($0.url) == k }
    }

    mutating func rename(id: UUID, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = t
    }

    /// 並べ替え（delta: -1 で 1 つ上、+1 で 1 つ下）
    mutating func move(id: UUID, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + delta))
        if i == j { return }
        let b = items.remove(at: i)
        items.insert(b, at: j)
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
    var id: String { url }
}

struct HistoryLog: Codable, Equatable {
    static let maxEntries = 5000
    /// 新しい順
    var entries: [HistoryEntry] = []

    /// 見たページを記録する（http・https だけ）。記録したら true
    @discardableResult
    mutating func record(url: URL, title: String, at now: Date = Date()) -> Bool {
        guard LibraryKey.isRecordable(url) else { return false }
        let s = url.absoluteString
        let k = LibraryKey.normalize(s)
        var e = HistoryEntry(url: s, title: title, lastVisit: now, visits: 1)
        if let i = entries.firstIndex(where: { LibraryKey.normalize($0.url) == k }) {
            let old = entries.remove(at: i)
            e.visits = old.visits + 1
            if title.isEmpty { e.title = old.title }
        }
        entries.insert(e, at: 0)
        if entries.count > HistoryLog.maxEntries { entries.removeLast(entries.count - HistoryLog.maxEntries) }
        return true
    }

    /// ページのタイトルが後から変わった（読み込みの後に JavaScript が変えるなど）
    mutating func updateTitle(url: URL, title: String) {
        guard !title.isEmpty else { return }
        let k = LibraryKey.normalize(url.absoluteString)
        if let i = entries.firstIndex(where: { LibraryKey.normalize($0.url) == k }), entries[i].title != title {
            entries[i].title = title
        }
    }

    mutating func remove(url: String) {
        let k = LibraryKey.normalize(url)
        entries.removeAll { LibraryKey.normalize($0.url) == k }
    }

    /// since より後に見たものを消す（nil なら全部）
    mutating func clear(since: Date?) {
        guard let since else { entries = []; return }
        entries.removeAll { $0.lastVisit >= since }
    }

    /// 文字で探す（タイトルと URL。新しい順）
    func search(_ q: String, limit: Int = 500) -> [HistoryEntry] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return Array(entries.prefix(limit)) }
        return Array(entries.lazy.filter { $0.title.lowercased().contains(t) || $0.url.lowercased().contains(t) }.prefix(limit))
    }

    /// よく見るサイト（ホストごとに 1 つ。回数の多い順）
    func topSites(limit: Int = 8) -> [HistoryEntry] {
        var best: [String: HistoryEntry] = [:]
        var total: [String: Int] = [:]
        for e in entries {
            guard let h = URL(string: e.url)?.host?.lowercased() else { continue }
            total[h, default: 0] += e.visits
            if let b = best[h], b.visits >= e.visits { continue }
            best[h] = e
        }
        return best.sorted { a, b in
            let ta = total[a.key] ?? 0, tb = total[b.key] ?? 0
            return ta != tb ? ta > tb : a.value.lastVisit > b.value.lastVisit
        }.prefix(limit).map { $0.value }
    }

    /// 日ごとに分ける（見出し・その日の分）。entries は新しい順のまま渡す
    static func groupByDay(_ list: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, entries: [HistoryEntry])] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        var out: [(title: String, entries: [HistoryEntry])] = []
        var lastDay: Date?
        for e in list {
            let day = calendar.startOfDay(for: e.lastVisit)
            if day != lastDay {
                let title: String
                if calendar.isDate(day, inSameDayAs: now) { title = "今日" }
                else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { title = "昨日" }
                else { title = f.string(from: day) }
                out.append((title, []))
                lastDay = day
            }
            out[out.count - 1].entries.append(e)
        }
        return out
    }
}

// MARK: アドレス欄の候補

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable { case bookmark, history }
    let kind: Kind
    let title: String
    let url: String
    var id: String { url }
}

enum Suggestions {
    static func rank(query: String, bookmarks: [Bookmark], history: [HistoryEntry], now: Date = Date(), limit: Int = 8) -> [Suggestion] {
        let q = LibraryKey.bare(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty { return [] }
        var scored: [String: (Int, Suggestion)] = [:]
        func consider(_ s: Suggestion, bonus: Int) {
            let u = LibraryKey.bare(s.url)
            let title = s.title.lowercased()
            var score: Int
            if u.hasPrefix(q) { score = 100 }
            else if title.hasPrefix(q) || title.contains(" " + q) { score = 60 }
            else if u.contains(q) || title.contains(q) { score = 30 }
            else { return }
            score += bonus
            let k = LibraryKey.normalize(s.url)
            if let old = scored[k], old.0 >= score { return }
            scored[k] = (score, s)
        }
        for b in bookmarks { consider(Suggestion(kind: .bookmark, title: b.title, url: b.url), bonus: 25) }
        // 履歴は全部を見ると重いので、新しい 2,000 件まで
        for h in history.prefix(2000) {
            var bonus = min(h.visits, 20) * 2
            let age = now.timeIntervalSince(h.lastVisit)
            if age < 86_400 { bonus += 10 } else if age < 7 * 86_400 { bonus += 5 }
            // 短い URL（サイトの入口）を少し上げる
            if (URL(string: h.url)?.path.count ?? 0) <= 1 { bonus += 8 }
            consider(Suggestion(kind: .history, title: h.title, url: h.url), bonus: bonus)
        }
        return scored.values.sorted { a, b in
            a.0 != b.0 ? a.0 > b.0 : a.1.url.count < b.1.url.count
        }.prefix(limit).map { $0.1 }
    }
}

// MARK: 文字の大きさ（ページの拡大率）

enum PageZoom {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// 今の値から段を delta だけ動かした値（delta が 0 なら 100%）
    static func step(from z: Double, by delta: Int) -> Double {
        if delta == 0 { return 1.0 }
        // 今の値に一番近い段から動かす
        let i = steps.indices.min { abs(steps[$0] - z) < abs(steps[$1] - z) } ?? 3
        return steps[max(0, min(steps.count - 1, i + delta))]
    }

    static func percent(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }
}
