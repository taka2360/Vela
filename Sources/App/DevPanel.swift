import SwiftUI

// MARK: - 開発者パネル（「…」メニュー・⌘⌥I から。普段の画面とは分ける）
//
// ページ: 概要・ログ・通信・タブ・Cookie・HSTS・広告ブロック・VNet・システム・範囲とリスク
// 開いている間だけ、BrowserStore.devTick（0.5 秒ごと）で描き直す。どのページも、数が多いものは新しい方から数百件だけ出す

enum DevPage: String, CaseIterable, Hashable {
    case overview = "概要", log = "ログ", network = "通信", tabs = "タブ", cookies = "Cookie", hsts = "HSTS"
    case adblock = "広告ブロック", vnet = "VNet", system = "システム", scope = "範囲とリスク"
}

@MainActor
struct DevPanel: View {
    @ObservedObject var store: BrowserStore
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
                    Button(store.hadCrash ? "前回の記録をコピー（落ちた）" : "前回の記録をコピー") {
                        UIPasteboard.general.string = CrashLog.previous() ?? "（前回の記録はありません）"
                    }
                } label: {
                    Label(store.hadCrash ? "コピー（前回は落ちた）" : "コピー", systemImage: "doc.on.doc")
                }
            }
            DevPageBar(page: $page)
            DevPageContent(store: store, page: page, tick: store.devTick)
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
    /// 変わると描き直す（中身は使わない）
    let tick: Int

    var body: some View {
        switch page {
        case .overview: DevOverview(store: store)
        case .log: DevLogPage(store: store)
        case .network: DevNetworkPage(store: store)
        case .tabs: DevTabsPage(store: store)
        case .cookies: DevCookiePage(store: store)
        case .hsts: DevHSTSPage(store: store)
        case .adblock: DevAdBlockPage(store: store, adblock: store.adblock)
        case .vnet: DevVNetPage(store: store)
        case .system: DevSystemPage(store: store)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                DevLine(store.takeover.description)
                DevLine("新しいタブの通信: \(store.defaultMode.rawValue)")
                DevLine("VNet: \(store.vnetStatus)")
                DevLine("タブ \(store.tabs.count) 枚・動いている WebView \(store.liveWebViewCount) / \(BrowserStore.maxLiveWebViews)")
                DevLine("Cookie（写し）\(store.cookieJar.count) 個・HSTS \(store.hsts.all().count) 件")
                DevLine("広告ブロック: \(store.adblock.enabled ? "使う" : "止めている")・VNet 用のルール \(store.adblock.ruleCount) 個・止めた数 \(store.adblock.totalBlocked)")
                DevLine("ネットワーク: \(store.isOnline ? "つながっている" : "つながっていない")・ダウンロード中 \(store.downloads.runningCount) 件")
                DevLine("ログ: 警告 \(store.logs.count(.warning))・エラー \(store.logs.count(.error))・通信の記録 \(store.netLog.count) 件")
                if store.hadCrash { DevLine("⚠️ 前回は落ちて終わりました（右上の「コピー」→ 前回の記録）") }
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
