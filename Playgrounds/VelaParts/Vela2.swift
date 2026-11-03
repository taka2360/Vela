// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 2 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

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
// MARK: - DevPanel.swift
// ======================================================================

// MARK: - 開発者パネル（「…」メニュー・⌘⌥I から。普段の画面とは分ける）
//
// ページ: 概要・ログ・通信・タブ・Cookie・HSTS・広告ブロック・VNet・システム・範囲とリスク
// 開いている間だけ、StatusModel.devTick（0.5 秒ごと）で描き直す。どのページも、数が多いものは新しい方から数百件だけ出す

enum DevPage: String, CaseIterable, Hashable {
    case overview = "概要", log = "ログ", network = "通信", tabs = "タブ", cookies = "Cookie", hsts = "HSTS"
    case adblock = "広告ブロック", vnet = "VNet", system = "システム", scope = "範囲とリスク"
}

@MainActor
struct DevPanel: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var status: StatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = DevPage.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(closeLabel: "閉じる", closeLeading: 12, close: { dismiss() }) {
                Text("開発者パネル").font(.headline)
            } trailing: {
                Menu {
                    Button("ログをコピー") { UIPasteboard.general.string = store.logs.export() }
                    Button("通信の記録をコピー") { UIPasteboard.general.string = store.netLog.export() }
                    Button(status.hadCrash ? "前回の記録をコピー（落ちた）" : "前回の記録をコピー") {
                        UIPasteboard.general.string = CrashLog.previous() ?? "（前回の記録はありません）"
                    }
                } label: {
                    Label(status.hadCrash ? "コピー（前回は落ちた）" : "コピー", systemImage: "doc.on.doc")
                }
            }
            DevPageBar(page: $page)
            DevPageContent(store: store, page: page, tick: status.devTick)
        }
        .padding()
    }
}

@MainActor
struct DevPageBar: View {
    @Binding var page: DevPage

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DevPage.allCases, id: \.self) { p in
                    Button { page = p } label: {
                        Text(p.rawValue)
                            .font(.system(size: 13, weight: page == p ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(page == p ? Color.accentColor.opacity(0.2) : Color(UIColor.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

@MainActor
struct DevPageContent: View {
    @ObservedObject var store: BrowserStore
    let page: DevPage
    /// 変わると描き直す（中身は使わない）。各ページにもそのまま渡す
    let tick: Int

    var body: some View {
        switch page {
        case .overview: DevOverview(store: store, tick: tick, status: store.status)
        case .log: DevLogPage(store: store, tick: tick)
        case .network: DevNetworkPage(store: store, tick: tick)
        case .tabs: DevTabsPage(store: store, tick: tick)
        case .cookies: DevCookiePage(store: store, tick: tick)
        case .hsts: DevHSTSPage(store: store, tick: tick)
        case .adblock: DevAdBlockPage(store: store, tick: tick, adblock: store.adblock)
        case .vnet: DevVNetPage(store: store, tick: tick, status: store.status)
        case .system: DevSystemPage(store: store, tick: tick)
        case .scope: DevScopePage()
        }
    }
}

/// 等幅の小さな文字の行
@MainActor
struct DevLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}

// MARK: 概要

@MainActor
struct DevOverview: View {
    @ObservedObject var store: BrowserStore
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @ObservedObject var status: StatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                DevLine(store.takeover.description)
                DevLine("新しいタブの通信: \(store.defaultMode.rawValue)")
                DevLine("VNet: \(status.vnetStatus)")
                DevLine("タブ \(store.tabs.count) 枚・動いている WebView \(store.liveWebViewCount) / \(BrowserStore.maxLiveWebViews)")
                DevLine("Cookie（写し）\(store.cookieJar.count) 個・HSTS \(store.hsts.all().count) 件")
                DevLine("広告ブロック: \(store.adblock.enabled ? "使う" : "止めている")・VNet 用のルール \(store.adblock.ruleCount) 個・止めた数 \(store.adblock.totalBlocked)")
                DevLine("ネットワーク: \(status.isOnline ? "つながっている" : "つながっていない")・ダウンロード中 \(store.downloads.runningCount) 件")
                DevLine("ログ: 警告 \(store.logs.count(.warning))・エラー \(store.logs.count(.error))・通信の記録 \(store.netLog.count) 件")
                if status.hadCrash { DevLine("⚠️ 前回は落ちて終わりました（右上の「コピー」→ 前回の記録）") }
                }
                Divider().padding(.vertical, 6)
                Text("最近の警告・エラー").font(.subheadline)
                ForEach(store.logs.all().filter { $0.level >= .warning }.suffix(30).reversed()) { e in
                    DevLine(e.line).foregroundColor(e.level == .error ? .red : .orange)
                }
            }
        }
    }
}

// MARK: ログ

@MainActor
struct DevLogPage: View {
    @ObservedObject var store: BrowserStore
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @State private var minLevel = LogLevel.info
    @State private var category: LogCategory?
    @State private var onlyThisTab = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu("重さ: \(levelName(minLevel)) 以上") {
                    ForEach(LogLevel.allCases, id: \.self) { l in Button(levelName(l)) { minLevel = l } }
                }
                Menu("種類: \(category?.rawValue ?? "全部")") {
                    Button("全部") { category = nil }
                    ForEach(LogCategory.allCases, id: \.self) { c in Button(c.rawValue) { category = c } }
                }
                Toggle("このタブだけ", isOn: $onlyThisTab).fixedSize()
                TextField("探す", text: $query).searchFieldStyle()
                Button("コピー") { UIPasteboard.general.string = filtered.map { $0.line }.joined(separator: "\n") }
                Button("消す") { store.logs.clear() }
            }
            .font(.system(size: 13))
            DevLogView(text: filtered.suffix(400).map { $0.line }.joined(separator: "\n"))
        }
    }

    private var filtered: [LogEntry] {
        let dq = DevQuery(onlyThisTab: onlyThisTab, query: query)
        let tab = dq.tab(selected: store.selectedID)
        return store.logs.all().filter { e in
            e.level >= minLevel && (category == nil || e.category == category) && (tab == nil || e.tab == tab)
                && dq.matches(e.message)
        }
    }

    private func levelName(_ l: LogLevel) -> String {
        switch l { case .debug: return "細かい"; case .info: return "普通"; case .warning: return "警告"; case .error: return "エラー" }
    }
}

@MainActor
struct DevLogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: タブ

@MainActor
struct DevTabsPage: View {
    @ObservedObject var store: BrowserStore
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.tabs) { tab in
                    DevTabBlock(tab: tab, selected: tab.id == store.selectedID)
                }
            }
        }
    }
}

@MainActor
struct DevTabBlock: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            DevLine("\(selected ? "▶" : " ") #\(tab.id) [\(tab.mode.short)・\(tab.state.rawValue)\(tab.isLoading ? "・読み込み中 \(Int(tab.progress * 100))%" : "")]"
                    + "・WebView \(tab.webView == nil ? "なし" : "あり")・文字 \(PageZoom.percent(tab.zoom))・ブロック \(tab.blockedCount)")
            DevLine("   \(tab.url?.absoluteString ?? "（空）")")
            if !tab.nonVNetUsage.isEmpty { DevLine("   VNet を通らない通信: \(tab.nonVNetUsage.sorted().joined(separator: "・"))") }
            ForEach(Array(tab.navEvents.suffix(8).enumerated()), id: \.offset) { _, ev in
                DevLine("   \(DevTime.format(ev.0)) \(ev.1)").foregroundStyle(.secondary)
            }
        }
    }
}

enum DevTime {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static func format(_ d: Date) -> String { formatter.string(from: d) }
}

// ======================================================================
// MARK: - DevPanelPages.swift
// ======================================================================

// MARK: - 開発者パネルのページ（通信・Cookie・HSTS・広告ブロック・VNet・システム・範囲とリスク）

// MARK: 通信

@MainActor
struct DevNetworkPage: View {
    @ObservedObject var store: BrowserStore
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @State private var onlyProblems = false
    @State private var onlyThisTab = false
    @State private var query = ""
    @State private var opened: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("失敗・ブロックだけ", isOn: $onlyProblems).fixedSize()
                Toggle("このタブだけ", isOn: $onlyThisTab).fixedSize()
                TextField("URL を探す", text: $query).searchFieldStyle()
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
        let dq = DevQuery(onlyThisTab: onlyThisTab, query: query)
        let tab = dq.tab(selected: store.selectedID)
        return store.netLog.recent(limit: 300) { r in
            (!onlyProblems || r.isProblem) && (tab == nil || r.tab == tab) && dq.matches(r.url)
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
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("ドメイン・名前で探す", text: $query).searchFieldStyle()
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
        let exp = c.expires.map { "期限 \(DevDate.dateTime($0)) \(Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0)日後" } ?? "セッション"
        let v = c.value.count > 16 ? String(c.value.prefix(16)) + "…" : c.value
        return "\(c.domain)\(c.path)  \(c.name)=\(v)  [\(flags.joined(separator: " "))・\(exp)]"
    }
}

// MARK: HSTS

@MainActor
struct DevHSTSPage: View {
    @ObservedObject var store: BrowserStore
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HSTS の記録 \(store.hsts.all().count) 件（このホストは http でも https で開く）").font(.system(size: 13))
                Spacer()
                Button("全部消す") { store.clearHSTS() }
            }
            List {
                ForEach(store.hsts.all().sorted { $0.host < $1.host }, id: \.host) { e in
                    DevLine("\(e.host)\(e.includeSubDomains ? "（サブドメインも）" : "")  期限 \(DevDate.dateTime(e.expires))")
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
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @ObservedObject var adblock: AdBlocker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine("状態: \(adblock.enabled ? "使う" : "止めている")・\(adblock.status)")
                DevLine("VNet 用のルール \(adblock.ruleCount) 個・起動してから止めた数 \(adblock.totalBlocked)")
                DevLine("止めているサイト: \(adblock.disabledSites.isEmpty ? "なし" : adblock.disabledSites.sorted().joined(separator: ", "))")
                DevLine("スクリプトレット: \(adblock.scriptletRuleCount) 個・道具 \(adblock.scriptletStatus)")
                ForEach(adblock.lists) { l in
                    DevLine("\(l.enabled ? "●" : "○") \(l.name): 通信 \(l.networkRules)・隠す \(l.cosmeticRules)・スクリプト \(l.scriptletRules ?? 0)・対応外 \(l.unsupported)"
                            + "・WebKit \(l.netID == nil ? "なし" : "通信あり")/\(l.cosID == nil ? "なし" : "隠すあり")\(l.lastError.map { "・⚠️ \($0)" } ?? "")")
                }
                Divider().padding(.vertical, 6)
                ScriptletSelfTestView(adblock: adblock)
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
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int
    @ObservedObject var status: StatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine(store.takeover.description)
                DevLine("新しいタブの通信: \(store.defaultMode.rawValue)")
                if let s = status.vnetStats {
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
    /// 変わると描き直す（中身は使わない）。@Published でない値（ログ・通信の記録・Cookie・HSTS・WebView の数・
    /// ダウンロード中の数）を毎秒出し直すため。今は store が毎秒変わることでも描き直している
    let tick: Int

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
            SheetHeader(closeLabel: "完了", close: { dismiss() }) {
                Text("設定").font(.headline)
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
        Binding.present({ confirm }, clear: { confirm = nil })
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
            SheetHeader(closeLabel: "完了", close: { dismiss() }) {
                Text("広告ブロック").font(.headline)
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
                    Text("リスト（リストが決めた間隔で自動で更新。無ければ 4 日ごと）")
                }
                Section {
                    ScriptletStatusRow(adblock: adblock)
                } header: {
                    Text("スクリプトレット（YouTube などの広告をページの中で消す）")
                } footer: {
                    Text("切り替えは、今見ているページを読み直して効かせます。ほかのタブは次にページを開いたときから。")
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
    ・スクリプトレット（uBO の ##+js(…)）: YouTube の動画広告のように、ページ自身のデータに入って届く広告は、通信を止めても消えません。uBlock filters の行と、uBlock Origin の道具（GPLv3。Vela の GitHub が毎日 uBO の最新版から作って署名したもの）で、ページの中で消します。YouTube が仕組みを変えても、リストと道具の自動更新でついていきます。サーバー側で動画に混ぜた広告は消せません。
    ・対応しない書き方（AdGuard のスクリプト・正規表現・$redirect・##^ など）は読み飛ばします。リストの行の「対応外」がその数です。
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
        var s = "通信 \(list.networkRules)・隠す \(list.cosmeticRules)"
        if let n = list.scriptletRules, n > 0 { s += "・スクリプト \(n)" }
        s += "・対応外 \(list.unsupported)・更新 \(date)"
        if let h = list.expiresHours { s += h % 24 == 0 ? "（\(h / 24) 日ごと）" : "（\(h) 時間ごと）" }
        if AdBlocker.isTrusted(list) { s += "・信頼する" }
        return s
    }
}

struct ScriptletStatusRow: View {
    @ObservedObject var adblock: AdBlocker
    @State private var checking = false

    var body: some View {
        HStack {
            if checking { ProgressView().padding(.trailing, 4) }
            VStack(alignment: .leading, spacing: 2) {
                Text("道具: \(adblock.scriptletStatus)").font(.system(size: 13))
                Text("使えるルール \(adblock.scriptletRuleCount) 個").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("道具を確かめる") {
                checking = true
                Task {
                    await adblock.updateScriptletsIfDue(force: true)
                    checking = false
                }
            }
            .disabled(checking)
        }
    }
}

// ======================================================================
// MARK: - ScriptletSelfTest.swift
// ======================================================================

// MARK: - スクリプトレットの自己テスト（開発者パネルの「広告ブロック」から）
//
// 本物の WKWebView に、今の道具（uBO から作った JSON）とテスト用のルールで組み立てたスクリプトを、タブと同じ形で入れる
// （main は WKContentWorld.page・isolated は .defaultClient・atDocumentStart・全フレーム）。
// https://vela-selftest.invalid/ として HTML を開き、ページの中で道具が効いたかを確かめて知らせてもらう。
// node のテスト（tools/ubo/test_assembled.mjs）では確かめられない XHR・DOM・world の違いを、iPad の WebKit で見るためのもの。
// 通信はしない（fetch・XHR は blob: の URL に向ける）

@MainActor
final class ScriptletSelfTest: ObservableObject {
    struct Result: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
        static func == (a: Result, b: Result) -> Bool { a.name == b.name && a.ok == b.ok && a.detail == b.detail }
    }

    @Published private(set) var running = false
    @Published private(set) var results: [Result] = []
    @Published private(set) var summary = "まだ動かしていません"

    private var webView: WKWebView?
    private var bridge: SelfTestBridge?
    private var timeout: Task<Void, Never>?

    func run(library: ScriptletLibrary?) {
        guard !running else { return }
        guard let library, !library.isEmpty else {
            summary = "道具がありません（広告ブロックの画面で「道具を確かめる」）"
            return
        }
        let (out, unknown) = ScriptletSelfTestPage.assemble(library: library)
        var notes: [String] = []
        if !unknown.isEmpty { notes.append("道具に無い: \(unknown.keys.sorted().joined(separator: ", "))") }

        running = true
        results = []
        summary = "動かしています…（uBO \(library.ubo)・ルール \(out.filters.count) 個）"
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        if !out.main.isEmpty { content.addUserScript(WKUserScript(source: out.main, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)) }
        if !out.isolated.isEmpty { content.addUserScript(WKUserScript(source: out.isolated, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)) }
        let b = SelfTestBridge()
        b.onResults = { [weak self] list in
            let me = self
            Task { @MainActor in me?.finish(list, notes: notes) }
        }
        content.add(b, name: "velaSelfTest")
        bridge = b
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView = wv
        wv.loadHTMLString(ScriptletSelfTestPage.page, baseURL: URL(string: "https://\(ScriptletSelfTestPage.host)/"))
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.running else { return }
            self.finish([], notes: notes + ["15 秒たっても結果が来ません"])
        }
    }

    private func finish(_ list: [[String: Any]], notes: [String]) {
        guard running else { return }
        timeout?.cancel()
        results = list.map { Result(name: $0["name"] as? String ?? "?", ok: $0["ok"] as? Bool ?? false, detail: $0["detail"] as? String ?? "") }
        let ng = results.filter { !$0.ok }.count
        summary = (results.isEmpty ? "結果がありません" : ng == 0 ? "全部 ○（\(results.count) 個）" : "× が \(ng) 個（\(results.count) 個中）")
            + (notes.isEmpty ? "" : "・" + notes.joined(separator: "・"))
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "velaSelfTest")
        webView = nil
        bridge = nil
        running = false
    }
}

final class SelfTestBridge: NSObject, WKScriptMessageHandler {
    var onResults: (([[String: Any]]) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onResults?(message.body as? [[String: Any]] ?? [])
    }
}

@MainActor
struct ScriptletSelfTestView: View {
    let adblock: AdBlocker
    @StateObject private var test = ScriptletSelfTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("スクリプトレットの自己テスト").font(.subheadline)
                Spacer()
                if test.running { ProgressView() }
                Button("動かす") { test.run(library: adblock.currentScriptletLibrary) }
                    .disabled(test.running)
            }
            DevLine(test.summary)
            ForEach(test.results) { r in
                DevLine("\(r.ok ? "○" : "×") \(r.name)\(r.ok || r.detail.isEmpty ? "" : "  [\(r.detail.prefix(200))]")")
                    .foregroundColor(r.ok ? nil : .red)
            }
        }
    }
}

// ======================================================================
// MARK: - Downloads.swift
// ======================================================================

// MARK: - ダウンロードの画面（中身は Browser/DownloadManager.swift）

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
            SheetHeader(closeLabel: "閉じる", closeLeading: 12, close: { dismiss() }) {
                Text("ダウンロード").font(.headline)
            } trailing: {
                Button("終わったものを一覧から外す") { manager.clearFinished() }
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
        .sheet(isPresented: Binding.present({ sharing }, clear: { sharing = nil })) {
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

extension Binding where Value == Bool {
    /// 「値があるあいだ出す」シート・アラート用（閉じられたら clear を呼ぶ）。
    /// Binding(get: { x != nil }, set: { if !$0 { x = nil } }) と同じ
    static func present<T>(_ value: @escaping () -> T?, clear: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value() != nil }, set: { if !$0 { clear() } })
    }
}

// ======================================================================
// MARK: - SharedViews.swift
// ======================================================================

// MARK: - いくつもの画面で同じ形の部品（シートの見出し など）

/// シートの上の行: 見出し・Spacer・右の部品・閉じるボタン（HStack だけ。外側の padding は呼ぶ側が付ける）。
/// 閉じるボタンの文言（完了・閉じる）と左の余白は、画面ごとに今の値を渡す（0 なら余白なし）
struct SheetHeader<Title: View, Trailing: View>: View {
    let closeLabel: String
    var closeLeading: CGFloat = 0
    let close: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            title()
            Spacer()
            trailing()
            Button(closeLabel) { close() }.padding(.leading, closeLeading)
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(closeLabel: String, closeLeading: CGFloat = 0, close: @escaping () -> Void, @ViewBuilder title: @escaping () -> Title) {
        self.init(closeLabel: closeLabel, closeLeading: closeLeading, close: close, title: title, trailing: { EmptyView() })
    }
}

extension View {
    /// 検索欄（開発者パネルのログ・通信・Cookie、履歴）: 角丸の枠 → 自動修正なし → 大文字にしない。
    /// アドレス欄と広告ブロックの URL 入力は並びが違うので使わない
    func searchFieldStyle() -> some View {
        textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
    }
}

/// ブックマーク・履歴の長押しメニューの先頭 2 つ: 「新しいタブで開く」と「リンクをコピー」（文字のまま写す）。
/// 開き方（URL に直せないときは何もしない など）は、各行の open(newTab:) が決める
struct SiteLinkMenuItems: View {
    let url: String
    let openInNewTab: () -> Void

    var body: some View {
        Button { openInNewTab() } label: { Label("新しいタブで開く", systemImage: "plus.square.on.square") }
        Button { UIPasteboard.general.string = url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
    }
}

// ======================================================================
// MARK: - DownloadManager.swift
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
