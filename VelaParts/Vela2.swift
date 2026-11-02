// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 2 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - DevPanelPages.swift
// ======================================================================

// MARK: - 開発者パネルのページ（通信・Cookie・HSTS・広告ブロック・VNet・システム・範囲とリスク）

// MARK: 通信

@MainActor
struct DevNetworkPage: View {
    @ObservedObject var store: BrowserStore
    @State private var onlyProblems = false
    @State private var onlyThisTab = false
    @State private var query = ""
    @State private var opened: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("失敗・ブロックだけ", isOn: $onlyProblems).fixedSize()
                Toggle("このタブだけ", isOn: $onlyThisTab).fixedSize()
                TextField("URL を探す", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("消す") { store.netLog.clear() }
            }
            .font(.system(size: 13))
            Text("VNet が引き受けた要求だけを記録します（標準の通信のタブ・WebSocket は入りません）。行を押すと、途中で決めたことが出ます")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(records) { r in
                        DevNetRow(record: r, opened: opened == r.id) { opened = opened == r.id ? nil : r.id }
                    }
                }
            }
        }
    }

    private var records: [NetRecord] {
        let tab = onlyThisTab ? store.selectedID : nil
        let q = query.lowercased()
        return store.netLog.recent(limit: 300) { r in
            (!onlyProblems || r.isProblem) && (tab == nil || r.tab == tab) && (q.isEmpty || r.url.lowercased().contains(q))
        }
    }
}

@MainActor
struct DevNetRow: View {
    let record: NetRecord
    let opened: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(DevTime.format(record.started)) \(record.tab.map { "#\($0) " } ?? "")\(record.line)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(opened ? nil : 1)
                .foregroundColor(color)
            if opened {
                ForEach(Array(record.notes.enumerated()), id: \.offset) { _, n in
                    Text("    " + n).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                if record.notes.isEmpty {
                    Text("    （メモなし）").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var color: Color {
        switch record.outcome {
        case .blocked: return .purple
        case .failed: return .red
        case .pending: return .secondary
        default: return (record.status ?? 0) >= 400 ? .orange : .primary
        }
    }
}

// MARK: Cookie

@MainActor
struct DevCookiePage: View {
    @ObservedObject var store: BrowserStore
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("ドメイン・名前で探す", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("\(cookies.count) / \(store.cookieJar.count) 個").font(.system(size: 13))
            }
            Text("VNet が使う Cookie の写し（正本は WebKit の置き場）。値は先頭だけ出します。消すのは 設定 → データ からできます")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(cookies.prefix(500).enumerated()), id: \.offset) { _, c in
                        DevLine(describe(c))
                    }
                }
            }
        }
    }

    private var cookies: [CookieRecord] {
        let q = query.lowercased()
        return store.cookieJar.snapshot()
            .filter { q.isEmpty || $0.domain.contains(q) || $0.name.lowercased().contains(q) }
            .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }

    private func describe(_ c: CookieRecord) -> String {
        var flags: [String] = []
        if c.hostOnly { flags.append("host-only") }
        if c.secure { flags.append("Secure") }
        if c.httpOnly { flags.append("HttpOnly") }
        flags.append("SameSite=\(c.sameSite.rawValue)")
        let exp = c.expires.map { "期限 \(DevTime.format($0)) \(Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0)日後" } ?? "セッション"
        let v = c.value.count > 16 ? String(c.value.prefix(16)) + "…" : c.value
        return "\(c.domain)\(c.path)  \(c.name)=\(v)  [\(flags.joined(separator: " "))・\(exp)]"
    }
}

// MARK: HSTS

@MainActor
struct DevHSTSPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HSTS の記録 \(store.hsts.all().count) 件（このホストは http でも https で開く）").font(.system(size: 13))
                Spacer()
                Button("全部消す") { store.clearHSTS() }
            }
            List {
                ForEach(store.hsts.all().sorted { $0.host < $1.host }, id: \.host) { e in
                    DevLine("\(e.host)\(e.includeSubDomains ? "（サブドメインも）" : "")  期限 \(e.expires)")
                }
                .onDelete { idx in
                    let hosts = store.hsts.all().sorted { $0.host < $1.host }.map { $0.host }
                    for i in idx { store.hsts.remove(hosts[i]) }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: 広告ブロック

@MainActor
struct DevAdBlockPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var adblock: AdBlocker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine("状態: \(adblock.enabled ? "使う" : "止めている")・\(adblock.status)")
                DevLine("VNet 用のルール \(adblock.ruleCount) 個・起動してから止めた数 \(adblock.totalBlocked)")
                DevLine("止めているサイト: \(adblock.disabledSites.isEmpty ? "なし" : adblock.disabledSites.sorted().joined(separator: ", "))")
                ForEach(adblock.lists) { l in
                    DevLine("\(l.enabled ? "●" : "○") \(l.name): 通信 \(l.networkRules)・隠す \(l.cosmeticRules)・対応外 \(l.unsupported)"
                            + "・WebKit \(l.netID == nil ? "なし" : "通信あり")/\(l.cosID == nil ? "なし" : "隠すあり")\(l.lastError.map { "・⚠️ \($0)" } ?? "")")
                }
                Divider().padding(.vertical, 6)
                Text("最近止めたもの").font(.subheadline)
                ForEach(store.netLog.recent(limit: 100) { if case .blocked = $0.outcome { return true } else { return false } }) { r in
                    DevLine("\(DevTime.format(r.started)) \(r.tab.map { "#\($0) " } ?? "")\(r.url)")
                    if case .blocked(let rule) = r.outcome { DevLine("    \(rule)").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: VNet

@MainActor
struct DevVNetPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine(store.takeover.description)
                DevLine("新しいタブの通信: \(store.defaultMode.rawValue)")
                if let s = store.vnetStats {
                    DevLine("IP: \(s.ready ? s.ip : "（まだ）")")
                    DevLine("フレーム: 送 \(s.framesOut)（\(s.bytesOut / 1024)KB）・受 \(s.framesIn)（\(s.bytesIn / 1024)KB）・捨てた \(s.droppedRx)")
                    DevLine("TCP: 送り直し \(s.tcpRetransmits)・順番を直した \(s.tcpReordered)")
                    DevLine("接続: 新しく \(s.pool.opened)・使い回し \(s.pool.reused)・使用中 \(s.pool.busy)・空き \(s.pool.idle)・待ち \(s.pool.waiting)")
                    DevLine("読み途中の中身: \(s.pool.bufferedBytes / 1024)KB・DNS の覚え \(s.pool.dnsCached) 件")
                } else {
                    DevLine("（数字を集めています…）")
                }
                let limits = PoolLimits()
                DevLine("上限: 1 要求 \(limits.maxBodyPerRequest >> 20)MB・全体の読み途中 \(limits.maxBufferedTotal >> 20)MB・接続 ホストごと \(limits.maxPerHost)・全体 \(limits.maxTotalConnections)・待ち \(limits.maxWaiting)")
                Divider().padding(.vertical, 6)
                Text("最近の VNet・通信のログ").font(.subheadline)
                ForEach(store.logs.all().filter { $0.category == .vnet || $0.category == .net }.suffix(60).reversed()) { e in
                    DevLine(e.line)
                }
            }
        }
    }
}

// MARK: システム

@MainActor
struct DevSystemPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let p = ProcessInfo.processInfo
                DevLine("OS: \(p.operatingSystemVersionString)")
                DevLine("メモリ（端末）: \(p.physicalMemory >> 20)MB・CPU \(p.activeProcessorCount) 個")
                DevLine("起動してから: \(Int(Date().timeIntervalSince(store.launchedAt)) / 60) 分")
                DevLine("動いている WebView: \(store.liveWebViewCount) 枚（上限 \(BrowserStore.maxLiveWebViews)）")
                DevLine("ブックマーク \(store.library.bookmarks.items.count) 件・履歴 \(store.library.history.entries.count) 件")
                Divider().padding(.vertical, 6)
                Text("データのファイル（Application Support/Vela）").font(.subheadline)
                ForEach(DevFiles.list(), id: \.0) { f in DevLine("\(f.0)  \(f.1 / 1024)KB") }
            }
        }
    }
}

enum DevFiles {
    /// Vela のデータのフォルダの中身（名前, 大きさ）。filters の中も数える
    static func list() -> [(String, Int)] {
        let fm = FileManager.default
        let dir = JSONFile<SessionData>.defaultDirectory()
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var out: [(String, Int)] = []
        for case let u as URL in e {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 { out.append((u.path.replacingOccurrences(of: dir.path + "/", with: ""), size)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

// MARK: 範囲とリスク

@MainActor
struct DevScopePage: View {
    var body: some View {
        ScrollView {
            Text(DevScopePage.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    static let text = """
    【VNet が処理するもの】
    ・ページ本体とサブリソースの http / https（HTTP/1.1）、fetch・XHR、リダイレクト
    ・Vela 独自の守り（Cookie の判定・LAN の保護・HSTS・広告ブロックの判定と数）は、VNet を通る通信にだけ効く

    【VNet が処理しないもの・未対応】
    ・WebSocket（ws / wss）は VNet を通らない（WebKit が直接つなぐ）。LAN の保護は WebKit のルールとスクリプトで補うが、名前で LAN に向くものは防げない
    ・HTTP/2・HTTP/3・TLS 1.3・IPv6 は未対応（TLS 1.3 だけのサーバーは「標準の通信で開く」）
    ・標準の通信のタブは、全部 WebKit が処理する（通信の記録・広告ブロックの数は出ない）

    【受け入れたリスク】
    ・https の横取りに非公開の API を使う（WKWebView.handlesURLScheme の差し替え、_willPerformRedirection）。iOS が変わると動かなくなることがある。確かめていない iOS の版では使わず、失敗したら元に戻して標準の通信にする。設定の「VNet を使わない」で止められる
    ・TLS は SecureTransport（2019 年から非推奨・TLS 1.2 まで）を使っている
    ・サードパーティ Cookie は既定でブロックする。Safari の ITP や Storage Access API の例外は再現していない
    ・広告ブロックは、スクリプトを使う書き方・正規表現・$redirect などに対応しない
    ・Cookie の正本は WebKit の置き場。VNet は写しを使うので、ページの JavaScript が変えた直後は少し遅れることがある
    """
}

// ======================================================================
// MARK: - SettingsView.swift
// ======================================================================

// MARK: - 設定（「…」メニューから）
//
// 値は VelaSettings（UserDefaults）。すぐ効くもの（検索エンジン・Cookie の決まり・HTTPS-First など）は BrowserStore.applySettings で入れ直す。
// 通信の作りを決めるもの（VNet を使わない など）は、アプリを起動し直したときに効く

@MainActor
struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    /// 変えたら描き直す（VelaSettings は @Published ではないので）
    @State private var tick = 0
    @State private var confirm: DataAction?

    enum DataAction: String, Identifiable {
        case history = "履歴を全部消す"
        case websiteData = "Cookie とサイトのデータを全部消す"
        case hsts = "HSTS の記録を消す"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("設定").font(.headline)
                Spacer()
                Button("完了") { dismiss() }
            }
            .padding()
            List {
                Section {
                    Picker("検索エンジン", selection: engine) {
                        ForEach(SearchEngine.allCases, id: \.self) { e in Text(e.name).tag(e) }
                    }
                    toggle("HTTPS-First（http のページはまず https で開く）", get: { VelaSettings.httpsFirst }, set: { VelaSettings.httpsFirst = $0 })
                } header: { Text("ブラウズ") }

                Section {
                    toggle("サードパーティ Cookie をブロック", get: { VelaSettings.blockThirdPartyCookies }, set: { VelaSettings.blockThirdPartyCookies = $0 })
                    toggle("SameSite の無い Cookie を Lax として扱う", get: { VelaSettings.cookiesLaxByDefault }, set: { VelaSettings.cookiesLaxByDefault = $0 })
                    toggle("LAN の保護（公開のサイトから LAN の機器に届かせない）※起動し直すと効く", get: { VelaSettings.localNetworkProtection },
                           set: { VelaSettings.localNetworkProtection = $0 })
                } header: { Text("プライバシーと守り") } footer: { Text("Cookie の決まりは VNet のタブに効きます") }

                Section {
                    toggle("VNet でページを読めなかったら、標準の通信に自動で切り替える", get: { VelaSettings.autoFallbackToNative }, set: { VelaSettings.autoFallbackToNative = $0 })
                    toggle("VNet を使わない（標準の通信だけ）※起動し直すと効く", get: { VelaSettings.vnetDisabled }, set: { VelaSettings.vnetDisabled = $0 })
                } header: { Text("通信") } footer: { Text("いまの状態: \(store.takeover.description)") }

                Section {
                    toggle("Web インスペクタ（Mac の Safari からつなぐ）", get: { VelaSettings.webInspector }, set: { VelaSettings.webInspector = $0 })
                    toggle("確かめていない iOS の版でも https の横取りを試す ※起動し直すと効く", get: { VelaSettings.allowUntestedOS }, set: { VelaSettings.allowUntestedOS = $0 })
                    toggle("横取りできないとき vnets:// の作りを使う（安全ではない）※起動し直すと効く", get: { VelaSettings.legacyVNetsFallback },
                           set: { VelaSettings.legacyVNetsFallback = $0 })
                } header: { Text("開発者向け") }

                Section {
                    ForEach([DataAction.history, .websiteData, .hsts]) { a in
                        Button(role: .destructive) { confirm = a } label: { Text(a.rawValue) }
                    }
                } header: { Text("データ") } footer: { Text("ブックマークとダウンロードしたファイルは消えません") }
            }
            .listStyle(.insetGrouped)
            .id(tick)
        }
        .alert(confirm?.rawValue ?? "", isPresented: confirmShown) {
            Button("キャンセル", role: .cancel) { confirm = nil }
            Button("消す", role: .destructive) { run(confirm) }
        } message: {
            Text("元に戻せません")
        }
    }

    private var engine: Binding<SearchEngine> {
        Binding(get: { VelaSettings.searchEngine }, set: { VelaSettings.searchEngine = $0; changed() })
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    }

    private func toggle(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: get, set: { v in set(v); changed() }))
    }

    private func changed() {
        tick += 1
        store.applySettings()
    }

    private func run(_ a: DataAction?) {
        switch a {
        case .history?: store.library.clearHistory(since: nil)
        case .websiteData?: store.clearWebsiteData()
        case .hsts?: store.clearHSTS()
        case nil: break
        }
        confirm = nil
    }
}

// ======================================================================
// MARK: - AdBlockView.swift
// ======================================================================

// MARK: - 広告ブロックの設定（「…」メニューから）

struct AdBlockView: View {
    @ObservedObject var adblock: AdBlocker
    @Environment(\.dismiss) private var dismiss
    @State private var customURL = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("広告ブロック").font(.headline)
                Spacer()
                Button("完了") { dismiss() }
            }
            .padding()
            List {
                Section {
                    Toggle("広告とトラッカーをブロックする", isOn: enabledBinding)
                    AdBlockStatusRow(adblock: adblock)
                }
                Section {
                    ForEach(adblock.lists) { l in
                        FilterListRow(adblock: adblock, list: l)
                    }
                    .onDelete { idx in
                        let ids = idx.map { adblock.lists[$0] }.filter { !$0.builtIn }.map { $0.id }
                        for id in ids { adblock.removeList(id) }
                    }
                    HStack {
                        TextField("リストの URL を足す（https://…）", text: $customURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button("追加") {
                            adblock.addCustom(customURL)
                            customURL = ""
                        }
                        .disabled(customURL.isEmpty || adblock.busy)
                    }
                } header: {
                    Text("リスト（4 日ごとに自動で更新）")
                }
                if !adblock.disabledSites.isEmpty {
                    Section {
                        ForEach(adblock.disabledSites.sorted(), id: \.self) { h in Text(h) }
                            .onDelete { idx in
                                let sites = adblock.disabledSites.sorted()
                                for i in idx { adblock.removeDisabledSite(sites[i]) }
                            }
                    } header: {
                        Text("広告ブロックを止めているサイト")
                    }
                }
                Section {
                    Text(AdBlockView.notes).font(.system(size: 12)).foregroundStyle(.secondary)
                } header: {
                    Text("しくみと制限")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { adblock.enabled }, set: { adblock.setEnabled($0) })
    }

    static let notes = """
    ・VNet のタブ: 通信は Vela が 1 つずつ調べて止めます（止めた数をアドレス欄に出し、開発者パネルのログに記録します）。広告の枠を隠すのは WebKit のルールです。
    ・標準の通信のタブ: 通信も枠を隠すのも WebKit のルールで止めます（止めた数は数えられません）。
    ・ページそのもの（アドレス欄で開くページ）は止めません。
    ・対応しない書き方（スクリプトを使うもの・正規表現・$redirect など）は読み飛ばします。リストの行の「対応外」がその数です。
    ・リストのダウンロードは標準の通信で行います。起動してすぐの数秒は、リストを読み終わるまでブロックが効きません。
    """
}

struct AdBlockStatusRow: View {
    @ObservedObject var adblock: AdBlocker

    var body: some View {
        HStack {
            if adblock.busy { ProgressView().padding(.trailing, 4) }
            VStack(alignment: .leading, spacing: 2) {
                Text(adblock.status).font(.system(size: 13))
                Text("起動してから止めた数（VNet）: \(adblock.totalBlocked)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("今すぐ更新") { Task { await adblock.update(manual: true) } }
                .disabled(adblock.busy)
        }
    }
}

struct FilterListRow: View {
    let adblock: AdBlocker
    let list: FilterListInfo

    var body: some View {
        Toggle(isOn: Binding(get: { list.enabled }, set: { adblock.setListEnabled(list.id, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                if let e = list.lastError {
                    Text(e).font(.system(size: 11)).foregroundColor(.red)
                }
            }
        }
    }

    private var detail: String {
        let date: String
        if let d = list.lastUpdated {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M/d HH:mm"
            date = f.string(from: d)
        } else {
            date = "まだ"
        }
        return "通信 \(list.networkRules)・隠す \(list.cosmeticRules)・対応外 \(list.unsupported)・更新 \(date)"
    }
}

// ======================================================================
// MARK: - Downloads.swift
// ======================================================================

// MARK: - ダウンロード
//
// ・WebKit の WKDownload を使う（VNet のタブでも標準の通信のタブでも同じ。VNet は返事を流す形で渡すので、大きいファイルでもメモリにためない）
// ・保存先は Documents/Downloads（同じ名前があれば「名前 (2).zip」のようにする）
// ・進み具合は 0.5 秒ごとに見る。取り消し・やり直し（途中から: resumeData）・共有（「ファイル」に保存など）・削除ができる
// ・起動したときに、前にダウンロードしたファイルを一覧に戻す

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    @Published var filename: String
    @Published var received: Int64 = 0
    @Published var expected: Int64 = -1
    @Published var state = State.running
    @Published var fileURL: URL?
    let source: URL?
    var download: WKDownload?
    var resumeData: Data?
    /// VNet が自分で書いているダウンロード（VNet のタブ）
    var vnet: VNetDownload?
    /// やり直すとき（VNet のダウンロードは、同じ URL をもう一度 VNet で読む）
    var restart: (() -> Void)?

    /// VNet のダウンロードの様子を写す
    func syncVNet() {
        guard let v = vnet else { return }
        received = v.received
        switch v.state {
        case .running: state = .running
        case .finished: state = .finished; expected = received
        case .cancelled: state = .cancelled
        case .failed(let why): state = .failed(why)
        }
    }

    init(filename: String, source: URL?) {
        self.filename = filename
        self.source = source
    }

    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// やり直し（途中から）に使う WebView を返す
    var webViewForResume: (() -> WKWebView?)?
    private var timer: Timer?

    /// BrowserStore の nonisolated init から作られるので、ここでは何もしない（準備は loadExisting）
    nonisolated override init() {
        super.init()
    }

    var runningCount: Int { items.filter { $0.state == .running }.count }

    nonisolated static var folder: URL { DownloadFiles.folder }

    /// 前にダウンロードしたファイルを一覧に入れる（新しい順）
    func loadExisting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: DownloadManager.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for f in sorted where !f.lastPathComponent.hasPrefix(".") {
            let item = DownloadItem(filename: f.lastPathComponent, source: nil)
            item.fileURL = f
            item.state = .finished
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0
            item.received = size
            item.expected = size
            items.append(item)
        }
    }

    /// WebKit がダウンロードに変えたものを受け取る
    func adopt(_ d: WKDownload, source: URL?) {
        let item = DownloadItem(filename: source?.lastPathComponent ?? "download", source: source)
        item.download = d
        d.delegate = self
        items.insert(item, at: 0)
        log?("⬇︎ ダウンロード開始: \(source?.absoluteString ?? "?")")
        startTimer()
    }

    /// VNet が自分で書き始めたダウンロードを一覧に入れる
    func register(_ dl: VNetDownload, restart: (() -> Void)?) {
        let item = DownloadItem(filename: dl.fileURL.lastPathComponent, source: dl.source)
        item.vnet = dl
        item.fileURL = dl.fileURL
        item.expected = dl.expected
        item.restart = restart
        dl.onChange = { [weak item] in
            let it = item
            Task { @MainActor in it?.syncVNet() }
        }
        items.insert(item, at: 0)
        item.syncVNet()
        log?("⬇︎ ダウンロード開始（VNet）: \(dl.source.absoluteString)")
    }

    private func item(for d: WKDownload) -> DownloadItem? { items.first { $0.download === d } }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let url = DownloadFiles.uniqueURL(for: suggestedFilename)
        if let item = item(for: download) {
            item.filename = url.lastPathComponent
            item.fileURL = url
            item.expected = response.expectedContentLength
        }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        if let f = item.fileURL, let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value {
            item.received = size
            item.expected = size
        }
        item.download = nil
        log?("⬇︎ ダウンロード完了: \(item.filename)（\(item.received / 1024)KB）")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.resumeData = resumeData
        item.download = nil
        if item.state == .cancelled { return }
        item.state = .failed(error.localizedDescription)
        log?("⬇︎✕ ダウンロード失敗: \(item.filename)：\(error.localizedDescription)\(resumeData != nil ? "（途中から再開できます）" : "")")
    }

    // MARK: 操作

    func cancel(_ item: DownloadItem) {
        if let v = item.vnet {
            item.state = .cancelled
            v.cancel()
            log?("⬇︎ ダウンロードを取り消しました: \(item.filename)")
            return
        }
        guard let d = item.download else { return }
        item.state = .cancelled
        d.cancel { [weak item] data in
            item?.resumeData = data
        }
        log?("⬇︎ ダウンロードを取り消しました: \(item.filename)")
    }

    /// やり直す（途中までのデータがあれば、そこから）
    func retry(_ item: DownloadItem) {
        if item.vnet != nil {
            let again = item.restart
            remove(item)
            again?()
            return
        }
        if let data = item.resumeData, let wv = webViewForResume?() {
            item.state = .running
            item.resumeData = nil
            wv.resumeDownload(fromResumeData: data) { [weak self, weak item] d in
                guard let self, let item else { return }
                item.download = d
                d.delegate = self
                self.startTimer()
            }
            log?("⬇︎ 途中から再開します: \(item.filename)")
        } else if let src = item.source, let wv = webViewForResume?() {
            remove(item)
            wv.startDownload(using: URLRequest(url: src)) { [weak self] d in
                self?.adopt(d, source: src)
            }
        }
    }

    /// 一覧から外して、ファイルも消す
    func remove(_ item: DownloadItem) {
        if item.state == .running { cancel(item) }
        if let f = item.fileURL { try? FileManager.default.removeItem(at: f) }
        items.removeAll { $0 === item }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    private func startTimer() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let me = self
            Task { @MainActor in me?.tick() }
        }
    }

    private func tick() {
        var running = false
        for item in items where item.state == .running {
            guard let d = item.download else { continue }
            running = true
            item.received = d.progress.completedUnitCount
            if d.progress.totalUnitCount > 0 { item.expected = d.progress.totalUnitCount }
        }
        if !running { timer?.invalidate(); timer = nil }
    }
}

// MARK: - 画面

/// ツールバーのダウンロードのボタン（ダウンロードがあるときだけ出す）
struct DownloadsButton: View {
    @ObservedObject var manager: DownloadManager
    @Binding var show: Bool

    var body: some View {
        if !manager.items.isEmpty {
            Button { show = true } label: {
                Image(systemName: manager.runningCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ダウンロード").font(.headline)
                Spacer()
                Button("終わったものを一覧から外す") { manager.clearFinished() }
                Button("閉じる") { dismiss() }.padding(.leading, 12)
            }
            .padding()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(manager.items) { item in
                        DownloadRow(manager: manager, item: item) { sharing = $0 }
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let u = sharing { ShareSheet(items: [u]) }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    let share: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc").font(.system(size: 24)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1)
                if item.state == .running {
                    ProgressView(value: item.fraction ?? 0)
                }
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            buttons
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
    }

    @ViewBuilder private var buttons: some View {
        switch item.state {
        case .running:
            Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle") }
        case .finished:
            if let f = item.fileURL {
                Button { share(f) } label: { Image(systemName: "square.and.arrow.up") }
            }
            Button { manager.remove(item) } label: { Image(systemName: "trash") }
        case .failed, .cancelled:
            Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise") }
            Button { manager.remove(item) } label: { Image(systemName: "trash") }
        }
    }

    private var statusText: String {
        let size = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        switch item.state {
        case .running:
            if item.expected > 0 { return "\(size) / \(ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file))" }
            return size
        case .finished: return "完了・\(size)"
        case .failed(let why): return "失敗: \(why)\(item.resumeData != nil ? "（途中から再開できます）" : "")"
        case .cancelled: return "取り消しました"
        }
    }
}

/// 共有シート（「ファイル」に保存・ほかのアプリで開く など）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// ======================================================================
// MARK: - DownloadFiles.swift
// ======================================================================

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
