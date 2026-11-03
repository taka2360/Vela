import SwiftUI
import WebKit

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
