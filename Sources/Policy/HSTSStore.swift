import Foundation

// MARK: - HSTS（「このサイトは https だけで開く」の記録）
//
// 決まり（README と開発者パネルにも書く）:
//  ・VNet が受け取った https の応答で、トップレベルかファーストパーティ（トップと同じサイト）のものからだけ登録する
//    （サードパーティの応答・http の応答・数字のアドレスのホストは無視する。サードパーティから登録させると、追跡に使えてしまう）
//  ・max-age で期限を決める。max-age=0 は消す。includeSubDomains に対応
//  ・ホスト名は SiteUtil.normalizeHost でそろえる
//  ・Application Support に保存する（期限切れは読み込むときに消す。最大 maxEntries 件。あふれたら期限の近いものから消す）
//  ・使い道: http:// への移動とリダイレクトを https に上げる

struct HSTSEntry: Codable, Equatable, Sendable {
    var host: String
    var expires: Date
    var includeSubDomains: Bool
}

enum HSTSPolicy {
    /// Strict-Transport-Security の値を読む。読めなければ nil
    static func parse(_ header: String) -> (maxAge: Int, includeSubDomains: Bool)? {
        var maxAge: Int?
        var sub = false
        var seen = Set<String>()
        for raw in header.split(separator: ";") {
            let d = raw.trimmingCharacters(in: .whitespaces)
            if d.isEmpty { continue }
            let (k, raw) = HeaderParams.splitAttribute(d)
            let v = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))      // HSTS では値の引用符を外す
            if !seen.insert(k).inserted { return nil }     // 同じ指示が 2 回あるものは無効（RFC 6797）
            switch k {
            case "max-age":
                guard let n = Int(v), n >= 0 else { return nil }
                maxAge = n
            case "includesubdomains": sub = true
            default: break
            }
        }
        guard let m = maxAge else { return nil }
        return (m, sub)
    }

    /// この応答から登録してよいか
    static func mayRecord(url: URL, ctx: RequestContext) -> Bool {
        guard url.scheme?.lowercased() == "https", let h = SiteUtil.host(of: url), !SiteUtil.isIPLiteral(h) else { return false }
        if ctx.isTopLevel { return true }
        guard let top = ctx.topURL else { return false }
        return SiteUtil.isSameSite(top, url)
    }
}

/// HSTS の記録（どのスレッドからでも使える）
final class HSTSStore: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var entries: [String: HSTSEntry] = [:]
    private let fileURL: URL?
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "vela-hsts-save")
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?

    /// fileURL が nil なら保存しない（テスト用）
    init(fileURL: URL?, now: Date = Date()) {
        self.fileURL = fileURL
        if let f = fileURL, let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([HSTSEntry].self, from: d) {
            for e in list where e.expires > now { entries[e.host] = e }
        }
    }

    /// 既定の置き場（Application Support/Vela/hsts.json）
    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hsts.json")
    }

    /// このホストを https に上げるべきか
    func shouldUpgrade(_ host: String, now: Date = Date()) -> Bool {
        let h = SiteUtil.normalizeHost(host)
        if SiteUtil.isIPLiteral(h) { return false }
        lock.lock(); defer { lock.unlock() }
        if let e = entries[h], e.expires > now { return true }
        // 親のドメインが includeSubDomains で登録されているか
        var labels = h.split(separator: ".")
        while labels.count > 1 {
            labels.removeFirst()
            if let e = entries[labels.joined(separator: ".")], e.includeSubDomains, e.expires > now { return true }
        }
        return false
    }

    /// 応答の Strict-Transport-Security を記録する（mayRecord を満たすときだけ）
    func record(header: String, url: URL, ctx: RequestContext, now: Date = Date()) {
        guard HSTSPolicy.mayRecord(url: url, ctx: ctx), let h = SiteUtil.host(of: url) else { return }
        guard let (maxAge, sub) = HSTSPolicy.parse(header) else { log?("HSTS の値が読めません（\(h)）: \(header)"); return }
        lock.lock()
        var changed = false
        if maxAge == 0 {
            changed = entries.removeValue(forKey: h) != nil
        } else {
            let e = HSTSEntry(host: h, expires: now.addingTimeInterval(TimeInterval(maxAge)), includeSubDomains: sub)
            let old = entries[h]
            entries[h] = e
            // 期限が少し延びただけなら保存しない（毎回書くと重い）
            changed = old == nil || old!.includeSubDomains != sub || abs(old!.expires.timeIntervalSince(e.expires)) > 86400
            if entries.count > HSTSStore.maxEntries {
                let drop = entries.values.sorted { $0.expires < $1.expires }.prefix(entries.count - HSTSStore.maxEntries)
                for d in drop { entries[d.host] = nil }
            }
        }
        lock.unlock()
        if changed {
            log?(maxAge == 0 ? "HSTS を消しました: \(h)" : "HSTS を記録: \(h)（\(maxAge / 86400) 日\(sub ? "・サブドメインも" : "")）")
            scheduleSave()
        }
    }

    func all() -> [HSTSEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.host < $1.host }
    }

    func remove(_ host: String) {
        lock.lock(); entries[SiteUtil.normalizeHost(host)] = nil; lock.unlock()
        scheduleSave()
    }

    func removeAll() {
        lock.lock(); entries = [:]; lock.unlock()
        scheduleSave()
    }

    /// まとめて 2 秒後に書く
    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        guard let f = fileURL else { return }
        lock.lock()
        saveScheduled = false
        let list = Array(entries.values)
        lock.unlock()
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: f, options: .atomic) }
    }
}
