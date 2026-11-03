// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 5 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import PhotosUI
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - NetLog.swift
// ======================================================================

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
        return id
    }

    func update(_ id: Int, _ change: (inout NetRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard id > 0, let i = positions[id], i < records.count, records[i].id == id else { return }
        change(&records[i])
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
        lock.lock(); records = []; positions = [:]; lock.unlock()
    }

    func export() -> String {
        recent(limit: NetLog.maxRecords).reversed().map { r in
            ([r.line] + r.notes.map { "    " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

// ======================================================================
// MARK: - FilterLists.swift
// ======================================================================

// MARK: - 広告ブロックのリストの管理（ダウンロード・更新・WebKit のルールへのコンパイル・サイトごとの OFF）
//
// ・リストは Application Support/Vela/filters/<id>.txt に置く。状態（いつ更新したか・ルールの数・コンパイル済みの名前）は adblock.json
// ・ダウンロードは標準の通信（URLSession）で行う（VNet が動いていなくても更新できるように）
// ・起動するたびに、置いてあるリストを裏で読んで、BlockEngine（VNet のタブ用）と WebKit のルール（JSON）を作る。
//   WebKit のルールは中身の印（ハッシュ）を名前に入れてあるので、変わっていなければコンパイルし直さずに取り出せる
// ・自動更新はリストの「! Expires:」ごと（無ければ 4 日。uBO の Quick fixes は 8 時間）。起動したときと、アプリが前に来たとき。手で「今すぐ更新」もできる
// ・!#include は落とすときに展開して 1 つのファイルにする（FilterPreparser.expandIncludes）
// ・スクリプトレット（##+js）: 道具（uBO から作った JSON）を 1 日ごとに Vela の GitHub から落とし、署名を確かめてから使う（ScriptletVerify）。
//   trusted の道具は、組み込みの一覧（catalog）で trusted にしたリストの行だけ使う（保存ファイルの id や URL では信じない）

/// VNet の通信から（裏のスレッドで）使う、判定の入れ物
final class BlockEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine = BlockEngine.empty
    private var enabled = true
    private var disabledSites = Set<String>()

    func set(engine e: BlockEngine) { lock.lock(); engine = e; lock.unlock() }
    func set(enabled on: Bool, disabledSites sites: Set<String>) { lock.lock(); enabled = on; disabledSites = sites; lock.unlock() }
    var ruleCount: Int { lock.lock(); defer { lock.unlock() }; return engine.ruleCount }

    /// 止めるなら当たったルール。topHost: タブで開いているページのホスト（サイトごとの OFF の判定）
    func match(url: URL, types: Set<ResourceType>, sourceHost: String?, topHost: String?) -> BlockEngine.Decision? {
        lock.lock()
        let e = engine, on = enabled
        let off = topHost.map { AdBlocker.isDisabled(host: $0, in: disabledSites) } ?? false
        lock.unlock()
        guard on, !off else { return nil }
        return e.match(url: url, types: types, sourceHost: sourceHost)
    }
}

@MainActor
final class AdBlocker: ObservableObject {
    nonisolated static var catalog: [FilterListInfo] { FilterCatalog.lists }
    /// 「! Expires:」が無いリストの更新の間隔
    static let updateInterval: TimeInterval = 4 * 86_400
    /// スクリプトレットの道具（Vela の GitHub。Actions が uBO から作って署名したもの）
    nonisolated static let scriptletsURL = "https://raw.githubusercontent.com/taka2360/Vela/main/resources/ubo-scriptlets.json"
    static let scriptletsInterval: TimeInterval = 86_400
    nonisolated static let idPrefix = "vela-ab-"

    @Published private(set) var lists: [FilterListInfo] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "準備中…"
    @Published private(set) var enabled = true
    @Published private(set) var disabledSites = Set<String>()
    /// 起動してから止めた数（VNet のタブ）
    @Published private(set) var totalBlocked = 0
    /// スクリプトレットの道具の様子（画面に出す）
    @Published private(set) var scriptletStatus = "まだありません"
    @Published private(set) var scriptletRuleCount = 0
    let box = BlockEngineBox()
    private var scriptletLibrary: ScriptletLibrary?
    private var scriptletIndex = ScriptletIndex()
    private var scriptletCache: [String: ScriptletInjection?] = [:]
    private var scriptletsChecked: Date?
    private var checkingScriptlets = false
    /// 最後に読んだリストのスクリプトレットの行（道具が更新されたら、これで索引を作り直す）
    private var lastScriptletSources: [([ScriptletFilter], Bool)] = []
    /// リスト id → WebKit のルール
    private var netLists: [String: WKContentRuleList] = [:]
    private var cosLists: [String: WKContentRuleList] = [:]
    /// ルールが変わったとき（タブに入れ直す）。userAction: 利用者が ON/OFF を切り替えた（開いているページを読み直す）
    var onRuleListsChanged: (@MainActor (_ userAction: Bool) -> Void)?
    private let stateFile = JSONFile<AdBlockState>(name: "adblock.json", delay: 0.5)
    private var lastAutoUpdate: Date?
    private var logs: DevLog?
    private var started = false

    nonisolated init() {}

    private func log(_ s: String, level: LogLevel = .info) { logs?.add(s, level: level, category: .block) }

    nonisolated static var folder: URL {
        let dir = JSONFile<AdBlockState>.defaultDirectory().appendingPathComponent("filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static func textURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).txt") }
    nonisolated static var scriptletsFile: URL { folder.appendingPathComponent("ubo-scriptlets.json") }
    nonisolated static var scriptletsSigFile: URL { folder.appendingPathComponent("ubo-scriptlets.json.sig") }

    nonisolated static func isTrusted(_ l: FilterListInfo) -> Bool { FilterCatalog.isTrusted(l) }

    /// !#if の判定に使う値（UA に Mobile があれば env_mobile）
    nonisolated static var filterEnv: [String] { FilterPreparser.env(userAgent: BrowserIdentity.userAgent) }

    nonisolated static func isDisabled(host: String, in sites: Set<String>) -> Bool {
        let h = host.lowercased()
        return sites.contains { SiteUtil.hostMatches(h, domain: $0) }
    }

    // MARK: 始める

    func start(logs: DevLog) {
        if started { return }
        started = true
        self.logs = logs
        stateFile.log = { s in logs.add(s) }
        let d = UserDefaults.standard
        enabled = d.object(forKey: "adblock.enabled") == nil ? true : d.bool(forKey: "adblock.enabled")
        disabledSites = Set(d.stringArray(forKey: "adblock.disabledSites") ?? [])
        box.set(enabled: enabled, disabledSites: disabledSites)
        let saved = stateFile.load()
        lastAutoUpdate = saved?.lastAutoUpdate
        scriptletsChecked = saved?.scriptletsChecked
        lists = FilterCatalog.merge(saved: saved?.lists ?? [])
        loadScriptletLibrary()
        let dueIDs = self.dueIDs()
        Task {
            await self.updateScriptletsIfDue()
            if dueIDs.isEmpty { await self.rebuild() } else { await self.update(manual: false, only: dueIDs) }
        }
    }

    /// 更新が要るリスト（ファイルが無い・期限切れ）
    private func dueIDs(now: Date = Date()) -> [String] {
        lists.filter { l in
            guard l.enabled else { return false }
            if !FileManager.default.fileExists(atPath: AdBlocker.textURL(l.id).path) { return true }
            guard let last = l.lastUpdated else { return true }
            let interval = l.expiresHours.map { TimeInterval($0) * 3600 } ?? AdBlocker.updateInterval
            return now.timeIntervalSince(last) > interval
        }.map { $0.id }
    }

    /// アプリが前に来たとき: 期限切れのリストと道具だけ更新する
    func updateIfDue() {
        guard started, !busy else { return }
        let ids = dueIDs()
        Task {
            await self.updateScriptletsIfDue()
            if !ids.isEmpty { await self.update(manual: false, only: ids) }
        }
    }

    // MARK: 設定

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "adblock.enabled")
        box.set(enabled: on, disabledSites: disabledSites)
        log(on ? "広告ブロックを使います" : "広告ブロックを止めました")
        onRuleListsChanged?(true)
    }

    func isActive(for host: String?) -> Bool {
        guard enabled else { return false }
        guard let host else { return true }
        return !AdBlocker.isDisabled(host: host, in: disabledSites)
    }

    /// そのサイトで止める・使う
    func toggleSite(_ host: String) {
        let h = SiteUtil.stripWWW(host.lowercased())
        if AdBlocker.isDisabled(host: h, in: disabledSites) {
            disabledSites = disabledSites.filter { !SiteUtil.hostMatches(h, domain: $0) }
            log("\(h) で広告ブロックを使います")
        } else {
            disabledSites.insert(h)
            log("\(h) では広告ブロックを止めます")
        }
        saveSites()
    }

    func removeDisabledSite(_ h: String) {
        disabledSites.remove(h)
        saveSites()
    }

    private func saveSites() {
        UserDefaults.standard.set(Array(disabledSites).sorted(), forKey: "adblock.disabledSites")
        box.set(enabled: enabled, disabledSites: disabledSites)
        onRuleListsChanged?(true)
    }

    func setListEnabled(_ id: String, _ on: Bool) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].enabled = on
        saveState()
        if on && !FileManager.default.fileExists(atPath: AdBlocker.textURL(id).path) {
            Task { await self.update(manual: true, only: [id]) }
        } else {
            Task { await self.rebuild() }
        }
    }

    /// 自分で URL を足す
    func addCustom(_ text: String) {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), let s = u.scheme?.lowercased(), s == "https" || s == "http",
              !lists.contains(where: { $0.url == u.absoluteString }) else { return }
        let id = "custom-" + ContentBlockerCompiler.hash(u.absoluteString)
        lists.append(FilterListInfo(id: id, name: u.host ?? u.absoluteString, url: u.absoluteString, enabled: true, builtIn: false))
        saveState()
        Task { await self.update(manual: true, only: [id]) }
    }

    func removeList(_ id: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }), !lists[i].builtIn else { return }
        let l = lists.remove(at: i)
        try? FileManager.default.removeItem(at: AdBlocker.textURL(id))
        for rid in [l.netID, l.cosID].compactMap({ $0 }) { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: rid) { _ in } }
        saveState()
        Task { await self.rebuild() }
    }

    func noteBlocked() { totalBlocked += 1 }

    /// そのタブに入れる WebKit のルール（VNet のタブは隠すルールだけ。通信は BlockEngine が調べる）
    func ruleLists(for mode: NetMode, host: String?) -> [WKContentRuleList] {
        guard isActive(for: host) else { return [] }
        let ids = lists.filter { $0.enabled }.map { $0.id }
        var out = ids.compactMap { cosLists[$0] }
        if !mode.usesVNet { out += ids.compactMap { netLists[$0] } }
        return out
    }

    var ruleCount: Int { box.ruleCount }

    // MARK: 更新

    /// ダウンロードしてから作り直す。only: そのリストだけ
    func update(manual: Bool, only: [String]? = nil) async {
        if busy { return }
        busy = true
        let targets = lists.filter { $0.enabled && (only == nil || only!.contains($0.id)) }
        log("広告ブロックのリストを更新します（\(targets.count) 個\(manual ? "・手で" : "・自動")）")
        for (n, l) in targets.enumerated() {
            status = "ダウンロード中 \(n + 1)/\(targets.count): \(l.name)"
            let result = await AdBlocker.download(l.url)
            guard let i = lists.firstIndex(where: { $0.id == l.id }) else { continue }
            if var text = result.text {
                // !#include を展開する（同じ場所のものだけ。捨てる !#if の枝の中のものは読まない）
                if text.contains("!#include"), let base = URL(string: l.url) {
                    status = "ダウンロード中 \(n + 1)/\(targets.count): \(l.name)（中のリスト）"
                    let ex = await FilterPreparser.expandIncludes(text, base: base, env: AdBlocker.filterEnv) { u in
                        await AdBlocker.download(u.absoluteString, checkFormat: false).text
                    }
                    text = ex.text
                    if !ex.included.isEmpty { log("\(l.name): 中のリスト \(ex.included.count) 個を読みました") }
                    if !ex.failed.isEmpty { log("⚠️ \(l.name): 読めなかった中のリスト: \(ex.failed.joined(separator: "・"))", level: .warning) }
                }
                do {
                    try Data(text.utf8).write(to: AdBlocker.textURL(l.id), options: .atomic)
                    lists[i].lastUpdated = Date()
                    lists[i].lastError = nil
                    lists[i].expiresHours = FilterPreparser.expiresHours(text)
                    log("✓ \(l.name): \(text.utf8.count / 1024)KB\(lists[i].expiresHours.map { "（\($0) 時間ごと）" } ?? "")")
                } catch {
                    lists[i].lastError = "保存できません: \(error.localizedDescription)"
                }
            } else {
                let message = result.error ?? "不明"
                lists[i].lastError = message
                log("⚠️ \(l.name) をダウンロードできません: \(message)", level: .warning)
            }
        }
        if only == nil { lastAutoUpdate = Date() }
        saveState()
        busy = false
        await rebuild()
    }

    /// ダウンロードの結果（text か error のどちらか）
    struct Downloaded: Sendable { var text: String?; var error: String? }

    /// checkFormat: 広告ブロックのリストの形か確かめる（!#include の中のリストは確かめない）
    nonisolated static func download(_ urlString: String, checkFormat: Bool = true) async -> Downloaded {
        guard let u = URL(string: urlString) else { return Downloaded(error: "URL が正しくありません") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<Downloaded, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error { c.resume(returning: Downloaded(error: error.localizedDescription)); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data, let text = String(data: data, encoding: .utf8) else {
                    c.resume(returning: Downloaded(error: "サーバーの返事が \(status) です")); return
                }
                // HTML（ログインやエラーのページ）などをリストだと思わないように
                let head = text.prefix(2000)
                guard !checkFormat || head.contains("!") || head.contains("[Adblock") || head.contains("##") || head.contains("||") else {
                    c.resume(returning: Downloaded(error: "広告ブロックのリストではないようです")); return
                }
                c.resume(returning: Downloaded(text: text))
            }.resume()
        }
    }

    // MARK: 作り直す（BlockEngine と WebKit のルール）

    private struct Built {
        let id: String
        let network: [NetworkRule]
        let scriptlets: [ScriptletFilter]
        let trusted: Bool
        let netJSON: String
        let cosJSON: String
        let networkCount: Int
        let cosmeticCount: Int
        let unsupported: Int
        let skipped: Int
    }

    /// 置いてあるリストを裏で読んで、BlockEngine を作り、WebKit のルールを（変わったものだけ）コンパイルする
    func rebuild() async {
        busy = true
        status = "リストを読んでいます…"
        let enabledLists = lists.filter { $0.enabled }
        let start = Date()
        let env = AdBlocker.filterEnv
        let built: [Built] = await Task.detached(priority: .utility) {
            enabledLists.compactMap { l -> Built? in
                guard let d = try? Data(contentsOf: AdBlocker.textURL(l.id)) else { return nil }
                let p = ABPParser.parse(String(decoding: d, as: UTF8.self), env: env)
                let net = ContentBlockerCompiler.networkJSON(p.network)
                let cos = ContentBlockerCompiler.cosmeticJSON(p.cosmetic)
                return Built(id: l.id, network: p.network, scriptlets: p.scriptlets, trusted: AdBlocker.isTrusted(l),
                             netJSON: net.json, cosJSON: cos.json, networkCount: p.network.count,
                             cosmeticCount: p.cosmetic.count, unsupported: p.unsupported, skipped: net.skipped + cos.skipped)
            }
        }.value
        let engine: BlockEngine = await Task.detached(priority: .utility) {
            BlockEngine(rules: built.flatMap { $0.network })
        }.value
        box.set(engine: engine)
        log("広告ブロック: VNet 用のルール \(engine.ruleCount) 個を作りました（\(Int(Date().timeIntervalSince(start) * 1000))ms）")
        await rebuildScriptlets(built.map { ($0.scriptlets, $0.trusted) })

        var newNet: [String: WKContentRuleList] = [:], newCos: [String: WKContentRuleList] = [:]
        for (n, b) in built.enumerated() {
            status = "WebKit のルールを用意しています \(n + 1)/\(built.count)…"
            guard let i = lists.firstIndex(where: { $0.id == b.id }) else { continue }
            lists[i].networkRules = b.networkCount
            lists[i].cosmeticRules = b.cosmeticCount
            lists[i].unsupported = b.unsupported + b.skipped
            lists[i].scriptletRules = b.scriptlets.count
            let netID = "\(AdBlocker.idPrefix)\(b.id)-net-\(ContentBlockerCompiler.hash(b.netJSON))"
            let cosID = "\(AdBlocker.idPrefix)\(b.id)-cos-\(ContentBlockerCompiler.hash(b.cosJSON))"
            if let l = await compile(netID, b.netJSON, name: "\(lists[i].name) の通信") { newNet[b.id] = l; lists[i].netID = netID }
            if let l = await compile(cosID, b.cosJSON, name: "\(lists[i].name) の隠すルール") { newCos[b.id] = l; lists[i].cosID = cosID }
        }
        netLists = newNet
        cosLists = newCos
        saveState()
        removeUnusedCompiled()
        busy = false
        status = "ルール \(engine.ruleCount) 個（VNet）・リスト \(built.count) 個"
        onRuleListsChanged?(false)
    }

    // MARK: スクリプトレット

    /// 行の束から、ホストごとの索引を作り直す（道具が無ければ空）
    private func rebuildScriptlets(_ sources: [([ScriptletFilter], Bool)]) async {
        lastScriptletSources = sources
        guard let lib = scriptletLibrary else {
            scriptletIndex = ScriptletIndex()
            scriptletCache = [:]
            scriptletRuleCount = 0
            return
        }
        let idx: ScriptletIndex = await Task.detached(priority: .utility) {
            var idx = ScriptletIndex()
            for (rules, trusted) in sources { for r in rules { idx.add(r, trusted: trusted, library: lib) } }
            return idx
        }.value
        scriptletIndex = idx
        scriptletCache = [:]
        scriptletRuleCount = idx.size
        var line = "スクリプトレット \(idx.size) 個・道具 uBO \(lib.ubo)（\(lib.count) 個）"
        if idx.rejectedTrust > 0 { line += "・信頼しないリストの trusted \(idx.rejectedTrust) 個を除いた" }
        if idx.badTargets > 0 { line += "・読めないドメイン \(idx.badTargets) 個" }
        log(line)
        if !idx.unknown.isEmpty {
            let top = idx.unknown.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)（\($0.value)）" }
            log("⚠️ 道具に無いスクリプトレット（リストの方が新しい uBO を前提にしている）: \(top.joined(separator: "・"))", level: .warning)
        }
    }

    /// 置いてある道具を読む（署名を確かめ直す）
    private func loadScriptletLibrary() {
        guard let d = try? Data(contentsOf: AdBlocker.scriptletsFile),
              let sig = try? String(contentsOf: AdBlocker.scriptletsSigFile, encoding: .utf8) else {
            scriptletStatus = "まだありません（ダウンロードします）"
            return
        }
        switch ScriptletVerify.verify(d, signature: sig, current: nil) {
        case .success(let lib):
            scriptletLibrary = lib
            scriptletStatus = "uBO \(lib.ubo)（\(lib.count) 個）・署名 OK"
        case .failure(let e):
            scriptletStatus = "使えません: \(e)"
            log("⚠️ 置いてあるスクリプトレットの道具が使えません: \(e)", level: .warning)
        }
    }

    /// 1 日ごとに道具を落とす（署名・形式・古くないかを確かめたものだけ置き換える）
    func updateScriptletsIfDue(force: Bool = false) async {
        if checkingScriptlets { return }
        if !force, scriptletLibrary != nil, let last = scriptletsChecked, Date().timeIntervalSince(last) < AdBlocker.scriptletsInterval { return }
        checkingScriptlets = true
        defer { checkingScriptlets = false }
        let j = await AdBlocker.fetchData(AdBlocker.scriptletsURL)
        let s = await AdBlocker.fetchData(AdBlocker.scriptletsURL + ".sig")
        scriptletsChecked = Date()
        saveState()
        guard let j, let s, let sigText = String(data: s, encoding: .utf8) else {
            log("⚠️ スクリプトレットの道具をダウンロードできません", level: .warning)
            return
        }
        switch ScriptletVerify.verify(j, signature: sigText, current: scriptletLibrary) {
        case .success(let lib):
            if lib.generated == scriptletLibrary?.generated { return }
            do {
                try j.write(to: AdBlocker.scriptletsFile, options: .atomic)
                try s.write(to: AdBlocker.scriptletsSigFile, options: .atomic)
            } catch {
                log("⚠️ スクリプトレットの道具を保存できません: \(error.localizedDescription)", level: .warning)
                return
            }
            scriptletLibrary = lib
            scriptletStatus = "uBO \(lib.ubo)（\(lib.count) 個）・署名 OK"
            log("スクリプトレットの道具を更新しました: uBO \(lib.ubo)（\(lib.generated ?? "?")）")
            if !lastScriptletSources.isEmpty {
                await rebuildScriptlets(lastScriptletSources)
                onRuleListsChanged?(false)
            }
        case .failure(let e):
            scriptletStatus = (scriptletLibrary.map { "uBO \($0.ubo)（\($0.count) 個）・署名 OK" } ?? "使えません") + "／新しいもの: \(e)"
            log("⚠️ 落としたスクリプトレットの道具を使いません: \(e)", level: .warning)
        }
    }

    nonisolated static func fetchData(_ urlString: String) async -> Data? {
        guard let u = URL(string: urlString) else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                c.resume(returning: (error == nil && status == 200) ? data : nil)
            }.resume()
        }
    }

    /// 自己テストなどで、今の道具を使う
    var currentScriptletLibrary: ScriptletLibrary? { scriptletLibrary }

    /// そのタブに入れるスクリプトレット。top: トップのページ・frames: サブフレーム（URL が分かったもの）
    func scriptlets(top: URL?, frames: [URL]) -> ScriptletInjection? {
        guard let lib = scriptletLibrary, scriptletIndex.size > 0, let top, isActive(for: top.host) else { return nil }
        let all = [top] + frames
        let cacheKey = all.map { $0.absoluteString }.joined(separator: "\n")
        if let c = scriptletCache[cacheKey] { return c }
        var picked: [(host: String, selection: ScriptletIndex.Selection)] = []
        for (i, u) in all.enumerated() {
            guard let h = u.host?.lowercased(), !h.isEmpty else { continue }
            picked.append((h, scriptletIndex.retrieve(url: u, ancestors: i == 0 ? [] : [top])))
        }
        let out = ScriptletAssembler.assemble(picked, library: lib)
        let r: ScriptletInjection? = out.isEmpty ? nil
            : ScriptletInjection(key: ContentBlockerCompiler.hash(out.main + "\u{0}" + out.isolated), main: out.main, isolated: out.isolated, filters: out.filters)
        if scriptletCache.count > 64 { scriptletCache = [:] }
        scriptletCache[cacheKey] = r
        return r
    }

    /// 同じ名前のものがあれば取り出し、無ければコンパイルする
    private func compile(_ id: String, _ json: String, name: String) async -> WKContentRuleList? {
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        if let found = await withCheckedContinuation({ (c: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: id) { l, _ in c.resume(returning: l) }
        }) { return found }
        let t0 = Date()
        let (list, error) = await withCheckedContinuation { (c: CheckedContinuation<(WKContentRuleList?, String?), Never>) in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { l, e in
                c.resume(returning: (l, e.map { "\($0)" }))
            }
        }
        if let list {
            log("WebKit のルールをコンパイルしました: \(name)（\(Int(Date().timeIntervalSince(t0) * 1000))ms）")
            return list
        }
        log("⚠️ WebKit のルールをコンパイルできません: \(name)（\(error ?? "不明")）", level: .warning)
        return nil
    }

    /// 使っていない古いコンパイル済みのルールを消す
    private func removeUnusedCompiled() {
        let keep = Set(lists.flatMap { [$0.netID, $0.cosID] }.compactMap { $0 })
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        let lg = logs
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix(AdBlocker.idPrefix) && !keep.contains(id) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
                lg?.add("古い WebKit のルールを消しました: \(id)", level: .debug, category: .block)
            }
        }
    }

    private func saveState() {
        stateFile.save(AdBlockState(lists: lists, lastAutoUpdate: lastAutoUpdate, scriptletsChecked: scriptletsChecked))
    }
}

// ======================================================================
// MARK: - FilterCatalog.swift
// ======================================================================

// MARK: - 広告ブロックのリストの一覧（組み込みのもの）と、保存する形
// UI・WebKit に頼らない（テストできるように FilterLists.swift から分けた）

struct FilterListInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var builtIn: Bool
    var lastUpdated: Date?
    var networkRules = 0
    var cosmeticRules = 0
    var unsupported = 0
    var lastError: String?
    /// スクリプトレットの行の数・リストの「! Expires:」（時間）。古い adblock.json には無いので Optional
    var scriptletRules: Int?
    var expiresHours: Int?
    /// コンパイル済みの WebKit のルールの名前
    var netID: String?
    var cosID: String?
}

struct AdBlockState: Codable {
    var lists: [FilterListInfo]
    var lastAutoUpdate: Date?
    /// スクリプトレットの道具を最後に確かめた時
    var scriptletsChecked: Date?
}

/// タブに入れるスクリプトレット（ScriptletAssembler の結果と、入れ替えの判定に使う印）
struct ScriptletInjection: Equatable {
    var key: String
    var main: String
    var isolated: String
    var filters: [String]
}

enum FilterCatalog {
    static let lists: [FilterListInfo] = [
        FilterListInfo(id: "easylist", name: "EasyList（広告）", url: "https://easylist.to/easylist/easylist.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy（トラッカー）", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "adguard-ja", name: "AdGuard Japanese（日本の広告）", url: "https://filters.adtidy.org/extension/ublock/filters/7.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-filters", name: "uBlock filters（YouTube など）", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes（すぐの直し）", url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt", enabled: true, builtIn: true),
    ]
    /// trusted の道具（trusted-*・rpnt など）を使ってよいリスト。uBO も自分のリスト（ublock-）だけを信頼する
    static let trustedIDs: Set<String> = ["ublock-filters", "ublock-quick-fixes"]

    /// そのリストの行が trusted の道具を使ってよいか（組み込みの一覧にあって、URL も一覧と同じもの。保存ファイルの id だけでは信じない）
    static func isTrusted(_ l: FilterListInfo) -> Bool {
        trustedIDs.contains(l.id) && lists.contains { $0.id == l.id && $0.url == l.url }
    }

    /// 保存してあった一覧と組み込みの一覧を合わせる。組み込みのものは名前と URL を一覧のもので上書きする（保存ファイルで偽れないように）。
    /// 一覧に無いのに「組み込み」になっているものは、自分で足したものとして扱う
    static func merge(saved: [FilterListInfo]) -> [FilterListInfo] {
        var merged = saved.map { l -> FilterListInfo in
            var l = l
            if let c = lists.first(where: { $0.id == l.id }) {
                l.name = c.name; l.url = c.url; l.builtIn = true
            } else {
                l.builtIn = false
            }
            return l
        }
        for c in lists where !merged.contains(where: { $0.id == c.id }) { merged.append(c) }
        return merged
    }
}

// ======================================================================
// MARK: - FilterPreparser.swift
// ======================================================================

// MARK: - リストの前処理（!#if / !#else / !#endif と !#include）
//
// uBlock Origin（uBO）1.75.2 の static-filtering-parser.js の preparser（preparserTokens・evaluateExpr・splitter・expandIncludes）を写したもの。
// ・知らない名前の !#if は「判定しない」（中も外も残す）。cap_ で始まる知らない名前だけは偽
// ・env は uBO が持つ値の名前（"ublock"・"mobile" など）。Vela は ext_ublock を真にし、UA に Mobile があれば env_mobile も真（uBO の vapi-common.js と同じ判定）
// ・!#include は、URL の形と「..」を含むものを断り、元のリストと同じ場所（サブフォルダは可）から読む。捨てる枝の中の include は読まない

enum FilterPreparser {
    /// uBO の preparserTokens（!#if の名前 → env の値の名前）
    static let tokens: [String: String] = [
        "ext_ublock": "ublock",
        "ext_ubol": "ubol",
        "ext_devbuild": "devbuild",
        "env_brave": "brave",
        "env_chromium": "chromium",
        "env_edge": "edge",
        "env_firefox": "firefox",
        "env_legacy": "legacy",
        "env_mobile": "mobile",
        "env_mv3": "mv3",
        "env_safari": "safari",
        "cap_html_filtering": "html_filtering",
        "cap_ipaddress": "ipaddress",
        "false": "false",
        "ext_abp": "false",
        "adguard": "adguard",
        "adguard_app_android": "false",
        "adguard_app_cli": "false",
        "adguard_app_ios": "false",
        "adguard_app_mac": "false",
        "adguard_app_windows": "false",
        "adguard_ext_android_cb": "false",
        "adguard_ext_chromium": "chromium",
        "adguard_ext_chromium_mv3": "mv3",
        "adguard_ext_edge": "edge",
        "adguard_ext_firefox": "firefox",
        "adguard_ext_opera": "chromium",
        "adguard_ext_safari": "false",
    ]

    /// Vela の env（uBO の vAPI.webextFlavor.soup のうち、!#if が見るもの）
    static func env(userAgent: String) -> [String] {
        var e = ["ublock"]
        if userAgent.range(of: #"\bMobile\b"#, options: .regularExpression) != nil { e.append("mobile") }
        return e
    }

    /// 1 つの名前（先頭の ! は打ち消し）。知らない名前なら nil
    static func evaluateToken(_ raw: String, _ env: [String]) -> Bool? {
        var token = Substring(raw)
        let not = token.hasPrefix("!")
        if not { token = token.dropFirst() }
        var state = tokens[String(token)]
        if state == nil {
            if !token.hasPrefix("cap_") { return nil }
            state = "false"
        }
        // JS: state === 'false' && not || env.includes(state) !== not
        return (state == "false" && not) || (env.contains(state!) != not)
    }

    /// 式（&& と || は左から順に。括弧は全体を囲むものだけ）。判定できなければ nil
    static func evaluateExpr(_ raw: String, _ env: [String]) -> Bool? {
        var expr = Substring(raw)
        if expr.hasPrefix("(") && expr.hasSuffix(")") && expr.count >= 2 { expr = expr.dropFirst().dropLast() }
        // uBO: /(?:(?:&&|\|\|)\s+)?\S+/g
        let words = expr.split(whereSeparator: { $0.isWhitespace })
        var matches: [(op: Substring?, word: Substring)] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            if (w == "&&" || w == "||") && i + 1 < words.count {
                matches.append((w, words[i + 1])); i += 2
            } else {
                matches.append((nil, w)); i += 1
            }
        }
        guard let first = matches.first else { return nil }
        if first.op != nil || first.word.hasPrefix("|") || first.word.hasPrefix("&") { return nil }
        var result = evaluateToken(String(first.word), env)
        for m in matches.dropFirst() {
            guard let op = m.op else { return nil }       // 「a b」のような並び
            guard let state = evaluateToken(String(m.word), env) else { return nil }
            if op == "||" {
                result = (result == true) ? true : state  // undefined || x → x
            } else {
                result = (result == nil) ? nil : (result! && state)
            }
        }
        return result
    }

    enum Directive { case ifExpr(String), elseBranch, endif }

    /// 「!#if 式」「!#else」「!#endif」の行か（uBO: /^!#(if|else|endif)\b([^\n]*)/）
    static func directive(_ line: Substring) -> Directive? {
        guard line.hasPrefix("!#") else { return nil }
        let rest = line.dropFirst(2)
        func word(_ w: String) -> Substring? {
            guard rest.hasPrefix(w) else { return nil }
            let after = rest.dropFirst(w.count)
            if let c = after.first, c.isLetter || c.isNumber || c == "_" { return nil }
            return after
        }
        if let a = word("endif") { _ = a; return .endif }
        if let a = word("else") { _ = a; return .elseBranch }
        if let a = word("if") { return .ifExpr(a.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// uBO の splitter を行ごとに。残す行なら true を返す閉包を、行を順に渡して使う
    final class Splitter {
        private final class Details { var known: Bool; var discard: Bool; init(_ k: Bool, _ d: Bool) { known = k; discard = d } }
        private var stack: [Details] = []
        private(set) var discarding = false
        let env: [String]
        init(env: [String]) { self.env = env }

        private func shouldDiscard() -> Bool { stack.contains { $0.known && $0.discard } }
        private func begif(_ d: Details) {
            if !discarding && d.known && d.discard { discarding = true }
            stack.append(d)
        }
        private func endif() {
            if !stack.isEmpty { stack.removeLast() }
            if discarding && !shouldDiscard() { discarding = false }
        }

        /// その行を残すか（!#if などの行そのものは、どちらにしても注釈として読み飛ばされる）
        func keep(_ line: Substring) -> Bool {
            switch directive(line) {
            case .ifExpr(let e)?:
                let r = FilterPreparser.evaluateExpr(e, env)
                begif(Details(r != nil, r == false))
                return false
            case .elseBranch?:
                guard let d = stack.last else { return false }
                endif()
                d.discard = !d.discard
                begif(d)
                return false
            case .endif?:
                endif()
                return false
            case nil:
                return !discarding
            }
        }
    }

    /// !#if で捨てる行を除いたもの（行の区切りは \n）
    static func prune(_ text: String, env: [String]) -> String {
        let s = Splitter(env: env)
        var out: [Substring] = []
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).forEach { line in
            if s.keep(line) { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: !#include

    static let maxIncludeDepth = 3
    static let maxTotalBytes = 16 << 20

    /// include の名前から、読みに行く URL（だめなら nil）。uBO: URL の形と「..」は断る。元のリストの最後の / までに付ける
    static func includeURL(_ name: String, base: URL) -> URL? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.contains("..") { return nil }
        if let u = URL(string: n), u.scheme != nil { return nil }
        let b = base.absoluteString
        guard let slash = b.lastIndex(of: "/") else { return nil }
        return URL(string: String(b[...slash]) + n)
    }

    /// 残る枝の中の「!#include 名前」の名前（uBO: /^!#include +(\S+)/）
    static func includeName(_ line: Substring) -> String? {
        guard line.hasPrefix("!#include ") else { return nil }
        let rest = line.dropFirst("!#include".count).drop(while: { $0 == " " })
        let name = rest.prefix(while: { !$0.isWhitespace })
        return name.isEmpty ? nil : String(name)
    }

    struct Expanded {
        var text: String
        var included: [URL] = []
        var failed: [String] = []
    }

    /// include を読んで、その位置に埋め込む。fetch は読めなければ nil。同じ URL は 1 回だけ・深さと合計の大きさに上限
    static func expandIncludes(_ text: String, base: URL, env: [String],
                               fetch: (URL) async -> String?) async -> Expanded {
        var seen: Set<String> = [base.absoluteString]
        var total = text.utf8.count
        var included: [URL] = [], failed: [String] = []
        func expand(_ text: String, base: URL, depth: Int) async -> String {
            let s = Splitter(env: env)
            var out: [String] = []
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let kept = s.keep(line)
                out.append(String(line))
                guard kept, let name = includeName(line) else { continue }
                guard let u = includeURL(name, base: base) else { failed.append("\(name)（読めない名前）"); continue }
                if seen.contains(u.absoluteString) { continue }
                seen.insert(u.absoluteString)
                if depth >= maxIncludeDepth { failed.append("\(name)（深すぎる）"); continue }
                guard let sub = await fetch(u) else { failed.append("\(name)（読めない）"); continue }
                if total + sub.utf8.count > maxTotalBytes { failed.append("\(name)（大きすぎる）"); continue }
                total += sub.utf8.count
                included.append(u)
                let body = await expand(sub, base: u, depth: depth + 1)
                out.append("! >>>>>>>> \(u.absoluteString)")
                out.append(body)
                out.append("! <<<<<<<< \(u.absoluteString)")
            }
            return out.joined(separator: "\n")
        }
        let t = await expand(text, base: base, depth: 0)
        return Expanded(text: t, included: included, failed: failed)
    }

    /// 「! Expires: 8 hours」「! Expires: 4 days (update frequency)」→ 時間（1〜168 に丸める）。無ければ nil
    static func expiresHours(_ text: String) -> Int? {
        for line in text.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true).prefix(60) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.lowercased().hasPrefix("! expires:") else { continue }
            let rest = l.dropFirst("! expires:".count).trimmingCharacters(in: .whitespaces).lowercased()
            let num = rest.prefix(while: { $0.isNumber })
            guard let v = Int(num), v > 0 else { return nil }
            let unit = rest.dropFirst(num.count).trimmingCharacters(in: .whitespaces)
            let hours = unit.hasPrefix("h") ? v : v * 24
            return min(max(hours, 1), 168)
        }
        return nil
    }
}

// ======================================================================
// MARK: - ABPFilter.swift
// ======================================================================

// MARK: - 広告ブロックのルール（Adblock Plus の書き方）を読む
//
// EasyList・EasyPrivacy・AdGuard Japanese などの 1 行ずつのルールを、通信のルールと、要素を隠すルールに分ける。
// 対応するもの:
//   通信: ||host^ ・ |先頭 ・ 末尾| ・ * ・ ^ ・ @@（例外）と、$ の後の指定
//         （third-party / first-party、script / image / stylesheet / xmlhttprequest / subdocument / font / media /
//          websocket / ping / other / document、domain=、match-case、important、~ の打ち消し）
//   隠す: ##セレクタ（全部のサイト）・a.com,b.com##セレクタ（そのサイト）・#@#（例外）
//   スクリプトレット: ##+js(…)・#@#+js(…)（uBO の書き方。Scriptlets.swift）
// 対応しないもの（数えて読み飛ばす）: /正規表現/、$redirect・$csp・$removeparam など、#?#・#$#・#%#（AdGuard などのスクリプト・拡張の書き方）、
//   $popup・$elemhide など、:has-text() などの拡張セレクタ

/// 読み込みの種類（ルールの $script などと照らし合わせる）
enum ResourceType: String, CaseIterable, Hashable {
    case document, subdocument, script, image, stylesheet, font, media, xhr, websocket, ping, other
}

struct NetworkRule: Equatable {
    /// 本体（$ の前。|| や | の印は外してある。match-case でなければ小文字）
    var body: String
    var hostAnchor = false      // ||
    var startAnchor = false     // |…
    var endAnchor = false       // …|
    var isException = false     // @@
    var important = false
    var matchCase = false
    /// third-party: true / first-party: false / 指定なし: nil
    var thirdParty: Bool?
    /// 当てはまる種類（nil なら全部）
    var types: Set<ResourceType>?
    /// domain= の、当てはまるサイトと除くサイト
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    /// 元の行（ログ・開発者向け）
    var text: String
}

struct CosmeticRule: Equatable {
    var selector: String
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    var isException = false
}

struct ParsedFilterList {
    var network: [NetworkRule] = []
    var cosmetic: [CosmeticRule] = []
    /// ##+js(…) / #@#+js(…)（Scriptlets.swift）
    var scriptlets: [ScriptletFilter] = []
    var unsupported = 0
    /// リストの見出しの「! Title:」
    var title: String?
}

enum ABPParser {
    /// env: !#if の判定に使う値（FilterPreparser.env）。既定は uBO の拡張と同じ（ext_ublock だけ真）
    static func parse(_ text: String, env: [String] = ["ublock"]) -> ParsedFilterList {
        var out = ParsedFilterList()
        let splitter = FilterPreparser.Splitter(env: env)
        text.enumerateLines { raw, _ in
            // !#if で捨てる枝の行は読まない（uBO の preparser と同じ）
            guard splitter.keep(Substring(raw)) else { return }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            if line.hasPrefix("!") {
                if out.title == nil, line.hasPrefix("! Title:") { out.title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                return
            }
            if line.hasPrefix("[") { return }
            if let r = parseLine(line) {
                switch r {
                case .network(let n): out.network.append(n)
                case .cosmetic(let c): out.cosmetic.append(c)
                case .scriptlet(let s): out.scriptlets.append(s)
                }
            } else {
                out.unsupported += 1
            }
        }
        return out
    }

    enum Rule { case network(NetworkRule), cosmetic(CosmeticRule), scriptlet(ScriptletFilter) }

    /// 1 行を読む。対応しない書き方なら nil
    static func parseLine(_ line: String) -> Rule? {
        // スクリプトレット（uBO の ##+js(…)）
        if let s = ScriptletParser.parse(line) { return .scriptlet(s) }
        // 隠すルール（## / #@#）。スクリプトや拡張の書き方（#?# #$# #%# #@?# など）は読まない
        if let r = line.range(of: "#@#") ?? line.range(of: "##") {
            let isException = line[r] == "#@#"
            let domainsPart = String(line[..<r.lowerBound])
            let selector = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if domainsPart.contains("#") || domainsPart.contains("$") || domainsPart.contains("/") { return nil }
            guard isSafeSelector(selector) else { return nil }
            var c = CosmeticRule(selector: selector, isException: isException)
            for d in domainsPart.split(separator: ",") {
                let t = d.trimmingCharacters(in: .whitespaces).lowercased()
                if t.isEmpty { continue }
                if t.hasPrefix("~") { c.excludeDomains.append(String(t.dropFirst())) } else { c.includeDomains.append(t) }
            }
            if c.includeDomains.contains(where: { $0.contains("*") }) || c.excludeDomains.contains(where: { $0.contains("*") }) { return nil }
            return .cosmetic(c)
        }
        if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("$$") || line.contains("#@") { return nil }
        return parseNetwork(line).map { .network($0) }
    }

    /// WebKit の css-display-none に渡しても大丈夫そうなセレクタか（拡張の書き方・壊れたものを入れるとリスト全体がだめになる）
    static func isSafeSelector(_ s: String) -> Bool {
        if s.isEmpty || s.count > 500 { return false }
        if s.hasPrefix("+js") || s.hasPrefix("^") || s.contains("\\") || s.contains("{") || s.contains("}") { return false }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) else { return false }
        // 使ってよい疑似クラスだけ
        if s.contains(":") {
            let allowed = [":not(", ":nth-child(", ":nth-of-type(", ":first-child", ":last-child", ":first-of-type", ":last-of-type",
                           ":only-child", ":empty", ":has(", ":is(", ":where("]
            var rest = s
            for a in allowed { rest = rest.replacingOccurrences(of: a, with: "") }
            // 属性の中の「:」（[href^="http:"] など）は構わない
            var depth = 0
            for ch in rest {
                if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 } else if ch == ":" && depth == 0 { return false }
            }
        }
        // 括弧・角括弧・引用符の数が合っているか（壊れたセレクタを避ける）
        var paren = 0, bracket = 0, dq = 0, sq = 0
        for ch in s {
            switch ch {
            case "(": paren += 1
            case ")": paren -= 1; if paren < 0 { return false }
            case "[": bracket += 1
            case "]": bracket -= 1; if bracket < 0 { return false }
            case "\"": dq += 1
            case "'": sq += 1
            default: break
            }
        }
        return paren == 0 && bracket == 0 && dq % 2 == 0 && sq % 2 == 0
    }

    static func parseNetwork(_ line: String) -> NetworkRule? {
        var s = Substring(line)
        var r = NetworkRule(body: "", text: line)
        if s.hasPrefix("@@") { r.isException = true; s = s.dropFirst(2) }
        // 正規表現のルールは読まない
        if s.hasPrefix("/") && s.count > 2 && (s.hasSuffix("/") || s.contains("/$")) { return nil }
        // $ の後の指定（最後の $ から。本体に $ を含むことはまれ）
        if let dollar = s.lastIndex(of: "$") {
            let opts = s[s.index(after: dollar)...]
            let body = s[..<dollar]
            if !opts.isEmpty, !opts.contains("/") || opts.contains("domain=") {
                guard applyOptions(String(opts), to: &r) else { return nil }
                s = body
            }
        }
        if s.hasPrefix("||") { r.hostAnchor = true; s = s.dropFirst(2) }
        else if s.hasPrefix("|") { r.startAnchor = true; s = s.dropFirst() }
        if s.hasSuffix("|") { r.endAnchor = true; s = s.dropLast() }
        // 先頭・末尾の * は意味が無い
        while s.hasPrefix("*") { s = s.dropFirst(); r.hostAnchor = false; r.startAnchor = false }
        while s.hasSuffix("*") { s = s.dropLast(); r.endAnchor = false }
        if s.isEmpty && r.includeDomains.isEmpty { return nil }      // 全部に当たるルールは危ないので読まない
        if s.contains("|") { return nil }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) else { return nil }
        r.body = r.matchCase ? String(s) : s.lowercased()
        return r
    }

    /// $ の後の指定を読む。対応しない指定があれば false（ルールごと読まない）
    static func applyOptions(_ opts: String, to r: inout NetworkRule) -> Bool {
        var include = Set<ResourceType>(), exclude = Set<ResourceType>()
        for raw in opts.split(separator: ",") {
            var o = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = o.hasPrefix("~")
            if negated { o.removeFirst() }
            let type: ResourceType?
            switch o {
            case "script": type = .script
            case "image": type = .image
            case "stylesheet", "css": type = .stylesheet
            case "xmlhttprequest", "xhr": type = .xhr
            case "subdocument", "frame": type = .subdocument
            case "document", "doc": type = .document
            case "font": type = .font
            case "media": type = .media
            case "websocket": type = .websocket
            case "ping", "beacon": type = .ping
            case "other", "object", "object-subrequest": type = .other
            default: type = nil
            }
            if let type {
                if negated { exclude.insert(type) } else { include.insert(type) }
                continue
            }
            switch o {
            case "third-party", "3p": r.thirdParty = !negated
            case "first-party", "1p": r.thirdParty = negated
            case "match-case": r.matchCase = true
            case "important": r.important = true
            case "all": include.formUnion(ResourceType.allCases)
            case "cname": break
            default:
                if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                    let list = o.drop(while: { $0 != "=" }).dropFirst()
                    for d in list.split(separator: "|") {
                        let t = String(d)
                        if t.contains("*") || t.hasPrefix("/") { return false }
                        if t.hasPrefix("~") { r.excludeDomains.append(String(t.dropFirst())) } else { r.includeDomains.append(t) }
                    }
                } else {
                    // redirect・csp・removeparam・popup・elemhide・badfilter など
                    return false
                }
            }
        }
        if !include.isEmpty { r.types = include.subtracting(exclude) }
        else if !exclude.isEmpty { r.types = Set(ResourceType.allCases).subtracting(exclude).subtracting([.document]) }
        if r.types?.isEmpty == true { return false }
        return true
    }
}
