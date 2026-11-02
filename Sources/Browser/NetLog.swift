import Foundation

// MARK: - 通信の記録（開発者パネルの「通信」。VNet が引き受けた要求 1 つずつ）
//
// 要求ごとに、メソッド・URL・種類・結果（返事の番号・大きさ・かかった時間）と、途中で決めたこと
// （HSTS で https に上げた・リダイレクト・Cookie を保存した・広告ブロックで止めた など）をメモとして持つ。
// 最新 maxRecords 件まで。どのスレッドから書いてもよい

struct NetRecord: Identifiable, Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case pending
        case ok
        case failed(String)
        case blocked(String)
        case cancelled
        case download

        var label: String {
            switch self {
            case .pending: return "…"
            case .ok: return "完了"
            case .failed: return "失敗"
            case .blocked: return "ブロック"
            case .cancelled: return "取り消し"
            case .download: return "ダウンロード"
            }
        }
    }

    let id: Int
    let tab: Int?
    let started: Date
    var method: String
    var url: String
    /// 種類（ページ・画像・スクリプト など。当て推量）
    var kind: String
    var topLevel: Bool
    var status: Int?
    var bytes = 0
    var finished: Date?
    var outcome = Outcome.pending
    var notes: [String] = []

    var durationMs: Int? { finished.map { Int($0.timeIntervalSince(started) * 1000) } }
    var isProblem: Bool {
        switch outcome {
        case .failed, .blocked: return true
        default: return (status ?? 0) >= 400
        }
    }

    /// 1 行の説明
    var line: String {
        let st = status.map(String.init) ?? outcome.label
        let ms = durationMs.map { "\($0)ms" } ?? "…"
        let kb = bytes > 0 ? "・\(bytes / 1024)KB" : ""
        var s = "\(st) \(method) \(kind)\(topLevel ? "（ページ）" : "") \(ms)\(kb) \(url)"
        switch outcome {
        case .failed(let m): s += "  ✕ \(m)"
        case .blocked(let r): s += "  🚫 \(r)"
        default: break
        }
        return s
    }
}

final class NetLog: @unchecked Sendable {
    static let maxRecords = 1000
    private let lock = NSLock()
    private var records: [NetRecord] = []
    private var positions: [Int: Int] = [:]     // id → records の中の位置
    private var nextID = 1
    /// 変わるたびに増える（画面が描き直すかを決める）
    private(set) var version = 0

    init() {}

    /// 始まった要求を記録して、番号を返す
    func begin(tab: Int?, method: String, url: String, kind: String, topLevel: Bool, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        records.append(NetRecord(id: id, tab: tab, started: now, method: method, url: url, kind: kind, topLevel: topLevel))
        positions[id] = records.count - 1
        if records.count > NetLog.maxRecords + 100 {
            // まとめて古いものを捨てる（1 件ずつだと位置の付け直しが重い）
            records.removeFirst(records.count - NetLog.maxRecords)
            positions = [:]
            for (i, r) in records.enumerated() { positions[r.id] = i }
        }
        version += 1
        return id
    }

    func update(_ id: Int, _ change: (inout NetRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard id > 0, let i = positions[id], i < records.count, records[i].id == id else { return }
        change(&records[i])
        version += 1
    }

    func note(_ id: Int, _ s: String) {
        update(id) { $0.notes.append(s) }
    }

    /// 終わった（status が分かっていれば入れる）
    func finish(_ id: Int, outcome: NetRecord.Outcome, status: Int? = nil, bytes: Int? = nil, now: Date = Date()) {
        update(id) { r in
            if r.finished != nil && r.outcome != .pending { return }      // 先に終わっていたら変えない
            r.outcome = outcome
            if let status { r.status = status }
            if let bytes { r.bytes = bytes }
            r.finished = now
        }
    }

    /// 新しい順
    func recent(limit: Int = 300, filter: (NetRecord) -> Bool = { _ in true }) -> [NetRecord] {
        lock.lock(); defer { lock.unlock() }
        var out: [NetRecord] = []
        for r in records.reversed() where filter(r) {
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    func clear() {
        lock.lock(); records = []; positions = [:]; version += 1; lock.unlock()
    }

    func export() -> String {
        recent(limit: NetLog.maxRecords).reversed().map { r in
            ([r.line] + r.notes.map { "    " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
