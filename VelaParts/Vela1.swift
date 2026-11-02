// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 1 / 6。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import ObjectiveC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - MyApp.swift
// ======================================================================

@main
struct VelaApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}

// ======================================================================
// MARK: - BrowserView.swift
// ======================================================================

// MARK: - 画面（iPad の Safari に近い形）
//
//  ┌ ツールバー: [戻る][進む]  [ アドレス欄（触っていないときはドメインと鍵） ]  [再読み込み/止める][…][＋][タブ一覧]
//  │            └ 下に読み込みの進み具合
//  ├ タブバー（タブが 2 枚以上のとき）
//  └ ページ（見ているタブの WKWebView）
// 中身は BrowserStore と BrowserTab。ここは見た目だけ。
// Playgrounds で作るのが遅くならないよう、1 つの View を小さく分けている（大きな式は型チェックが遅い）

struct BrowserView: View {
    @StateObject private var store = BrowserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let tab = store.selectedTab {
                TopBar(store: store, tab: tab)
            }
            if store.tabs.count > 1 {
                TabStrip(store: store)
            }
            Divider()
            PageArea(store: store)
        }
        .sheet(isPresented: $store.showDevPanel) { DevPanel(store: store) }
        .fullScreenCover(isPresented: $store.showTabOverview) { TabOverview(store: store) }
        .modifier(DialogModifier(store: store))
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.saveSessionNow() }
        }
    }
}

// MARK: ツールバー

struct TopBar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavButtons(tab: tab)
                AddressField(store: store, tab: tab)
                ReloadButton(tab: tab)
                MoreMenu(store: store, tab: tab)
                Button { store.newTab(url: nil) } label: { Image(systemName: "plus") }
                    .keyboardShortcut("t", modifiers: .command)
                Button { store.openTabOverview() } label: { Image(systemName: "square.on.square") }
            }
            .font(.system(size: 18))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            LoadingBar(progress: tab.progress, visible: tab.isLoading)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct NavButtons: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 18) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack)
                .contextMenu { HistoryMenu(tab: tab, back: true) }
                .keyboardShortcut("[", modifiers: .command)
            Button { tab.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward)
                .contextMenu { HistoryMenu(tab: tab, back: false) }
                .keyboardShortcut("]", modifiers: .command)
        }
    }
}

/// 戻る・進むボタンの長押しで出す履歴
struct HistoryMenu: View {
    let tab: BrowserTab
    let back: Bool

    var body: some View {
        let list = tab.webView?.backForwardList
        let items = (back ? list?.backList.reversed() : list?.forwardList) ?? []
        ForEach(Array(items.prefix(15).enumerated()), id: \.offset) { _, item in
            Button(item.title?.isEmpty == false ? item.title! : (VNetURL.toReal(item.url) ?? item.url).absoluteString) {
                tab.go(to: item)
            }
        }
    }
}

struct ReloadButton: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Button {
            if tab.isLoading { tab.stop() } else { tab.reload() }
        } label: {
            Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
    }
}

/// 読み込みの進み具合（ツールバーの下の細い線）
struct LoadingBar: View {
    let progress: Double
    let visible: Bool

    var body: some View {
        GeometryReader { g in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: g.size.width * CGFloat(max(0.05, min(progress, 1))), height: 2)
        }
        .frame(height: 2)
        .opacity(visible ? 1 : 0)
    }
}

// MARK: アドレス欄

struct AddressField: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.tertiarySystemFill))
            // TextField はいつも置いておく（focused = true にした時に無いとフォーカスが当たらずキーボードが出ない）
            editor
                .opacity(focused ? 1 : 0)
            if !focused {
                Button { beginEditing() } label: { display.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
    }

    private var editor: some View {
        TextField("検索・アドレスを入力", text: $text)
            .focused($focused)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .onSubmit {
                store.open(text, in: tab)
                focused = false
            }
            .padding(.horizontal, 10)
    }

    private var display: some View {
        HStack(spacing: 6) {
            if tab.isSecure { Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text(displayText)
                .lineLimit(1)
                .foregroundColor(tab.url == nil ? .secondary : .primary)
            ModeBadge(tab: tab, ready: store.vnetReady)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
    }

    private var displayText: String {
        if let q = AddressInput.searchTerms(in: tab.url) { return q }
        let s = AddressInput.shortDisplay(tab.url)
        return s.isEmpty ? "検索・アドレスを入力" : s
    }

    private func beginEditing() {
        text = AddressInput.searchTerms(in: tab.url) ?? tab.url?.absoluteString ?? ""
        focused = true
    }
}

/// 通信の作りの小さな札（VNet か標準か。VNet を通らない通信を使っていれば知らせる）
struct ModeBadge: View {
    @ObservedObject var tab: BrowserTab
    let ready: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
                .foregroundColor(color)
            if !tab.nonVNetUsage.isEmpty {
                Text(tab.nonVNetUsage.sorted().joined(separator: "・"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        if tab.mode.usesVNet && !ready { return "VNet 起動中" }
        return tab.mode.short
    }

    private var color: Color { tab.mode.usesVNet ? .green : .blue }
}

// MARK: 「…」メニュー

struct MoreMenu: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Menu {
            if tab.mode.usesVNet {
                Button { tab.switchMode(to: .native) } label: { Label("標準の通信で開き直す", systemImage: "network") }
            } else if store.defaultMode.usesVNet {
                Button { tab.switchMode(to: store.defaultMode) } label: { Label("VNet で開き直す", systemImage: "cpu") }
            }
            if store.canReopenClosedTab {
                Button { store.reopenClosedTab() } label: { Label("閉じたタブを戻す", systemImage: "arrow.uturn.backward") }
            }
            Button { store.close(tab) } label: { Label("このタブを閉じる", systemImage: "xmark.square") }
            Divider()
            Button { store.showDevPanel = true } label: { Label("開発者パネル", systemImage: "wrench.and.screwdriver") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

// MARK: ページ

struct PageArea: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
            if let tab = store.selectedTab {
                TabPage(tab: tab)
            }
        }
    }
}

struct TabPage: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        ZStack {
            WebHost(webView: tab.webView)
            if tab.url == nil {
                StartPage()
            }
        }
    }
}

/// 新しいタブ（何も開いていないとき）
struct StartPage: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("上のアドレス欄に、URL か調べたいことを入れてください").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
}

/// 見ているタブの WKWebView を入れる箱（タブを切り替えたら中身を入れ替える）
struct WebHost: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .systemBackground
        return v
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let wv = webView else {
            for s in container.subviews { s.removeFromSuperview() }
            return
        }
        if wv.superview === container { return }
        for s in container.subviews where s !== wv { s.removeFromSuperview() }
        wv.frame = container.bounds
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(wv)
    }
}

// MARK: ダイアログ（JavaScript の alert・confirm・prompt）

@MainActor
struct DialogModifier: ViewModifier {
    @ObservedObject var store: BrowserStore

    func body(content: Content) -> some View {
        content.alert(title, isPresented: shown) {
            DialogButtons(store: store)
        } message: {
            Text(store.dialog?.message ?? "")
        }
    }

    private var title: String {
        guard let d = store.dialog else { return "" }
        return String(d.origin.drop(while: { $0 != " " }).dropFirst()) + " より"
    }

    private var shown: Binding<Bool> {
        Binding(get: { store.dialog != nil }, set: { v in if !v && store.dialog != nil { store.answerDialog(ok: false) } })
    }
}

struct DialogButtons: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        switch store.dialog?.kind {
        case .prompt?:
            TextField("", text: $store.dialogInput)
            Button("キャンセル", role: .cancel) { store.answerDialog(ok: false) }
            Button("OK") { store.answerDialog(ok: true) }
        case .confirm?:
            Button("キャンセル", role: .cancel) { store.answerDialog(ok: false) }
            Button("OK") { store.answerDialog(ok: true) }
        default:
            Button("OK") { store.answerDialog(ok: true) }
        }
    }
}

// ======================================================================
// MARK: - TabViews.swift
// ======================================================================

// MARK: - タブバー（ツールバーの下）と、タブ一覧（全画面）

struct TabStrip: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.tabs) { tab in
                    TabChip(store: store, tab: tab, selected: tab.id == store.selectedID)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct TabChip: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
            Text(tabTitle(tab)).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(UIColor.systemBackground) : Color(UIColor.tertiarySystemFill)))
        .onTapGesture { store.select(tab) }
        .contextMenu {
            Button { store.closeOthers(tab) } label: { Label("ほかのタブを閉じる", systemImage: "xmark.square") }
            if let u = tab.url {
                Button { store.newTab(url: u, select: true, mode: tab.mode, after: tab) } label: { Label("タブを複製", systemImage: "plus.square.on.square") }
            }
        }
    }
}

/// タブの見出し（タイトルが無ければホスト名）
@MainActor
func tabTitle(_ tab: BrowserTab) -> String {
    if !tab.title.isEmpty { return tab.title }
    let h = AddressInput.shortDisplay(tab.url)
    return h.isEmpty ? "新しいタブ" : h
}

struct TabOverview: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("タブ \(store.tabs.count) 枚").font(.headline)
                Spacer()
                Button {
                    store.newTab(url: nil)
                    dismiss()
                } label: { Image(systemName: "plus").font(.system(size: 20)) }
                Button("完了") { dismiss() }.padding(.leading, 16)
            }
            .padding()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.tabs) { tab in
                        TabCard(store: store, tab: tab, selected: tab.id == store.selectedID) {
                            store.select(tab)
                            dismiss()
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

struct TabCard: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            Text(tabTitle(tab)).font(.system(size: 13)).lineLimit(1)
            Text("\(tab.mode.short)・\(tab.state.rawValue)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onTapGesture { open() }
    }

    @ViewBuilder private var preview: some View {
        if let img = tab.snapshot {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(UIColor.secondarySystemBackground)
                Image(systemName: "globe").font(.system(size: 30)).foregroundStyle(.secondary)
            }
        }
    }
}

// ======================================================================
// MARK: - DevPanel.swift
// ======================================================================

// MARK: - 開発者パネル（簡易版。完成版はフェーズ G）
//
// 通信の様子・タブごとの状態・ログ。普段の画面とは分けて、「…」メニューから開く

struct DevPanel: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("開発者パネル").font(.headline)
                Spacer()
                Button("ログをコピー") { UIPasteboard.general.string = store.logs.export() }
                Button("閉じる") { dismiss() }.padding(.leading, 12)
            }
            DevStatus(store: store)
            DevTabList(store: store)
            DevLogView(text: store.logText)
        }
        .padding()
    }
}

struct DevStatus: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.takeover.description)
            Text("新しいタブの通信: \(store.defaultMode.rawValue)")
            Text("VNet: \(store.vnetStatus)")
            Text("タブ \(store.tabs.count) 枚・動いている WebView \(store.liveWebViewCount) / \(BrowserStore.maxLiveWebViews)")
            Text("Cookie（写し）\(store.cookieJar.count) 個・HSTS \(store.hsts.all().count) 件")
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

struct DevTabList: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.tabs) { tab in
                DevTabRow(tab: tab, selected: tab.id == store.selectedID)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

struct DevTabRow: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool

    var body: some View {
        Text("\(selected ? "▶" : " ") #\(tab.id) [\(tab.mode.short)・\(tab.state.rawValue)\(tab.isLoading ? "・読み込み中 \(Int(tab.progress * 100))%" : "")] \(tab.url?.absoluteString ?? "（空）")")
            .lineLimit(1)
    }
}

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

// ======================================================================
// MARK: - BrowserStore.swift
// ======================================================================

// MARK: - アプリ全体（タブ・共有の部品・保存）
//
// ・タブ 1 枚 = BrowserTab（WKWebView は必要なときだけ作る。動いている WebView は maxLiveWebViews 枚まで）
// ・通信（VNetMachine）・Cookie の写し・HSTS・ログ・LAN の保護のルールは、全部のタブで 1 つを共有する
// ・タブの並び（と各タブの戻る/進むの履歴）を session.json に保存して、次に起動したときに戻す
// ・メモリが足りなくなったら（メモリ警告）、見ていないタブの WebView を捨てる（スナップショットと履歴は残す）

/// 通信の作り（タブごと）
enum NetMode: String, Codable {
    /// https・http をそのまま VNetScheme が引き受ける（アドレスは本物の https://…）
    case vnetDirect = "VNet"
    /// 予備の vnets://… の作り（開発者向けの実験。CSP などを外すので安全ではない）
    case vnetsLegacy = "VNet（vnets://・実験）"
    /// 標準の通信（WebKit 内蔵）
    case native = "標準"

    var usesVNet: Bool { self != .native }
    var short: String {
        switch self { case .vnetDirect: return "VNet"; case .vnetsLegacy: return "vnets"; case .native: return "標準" }
    }
}

/// ページの JavaScript からのダイアログ（alert・confirm・prompt）
struct JSDialog: Identifiable {
    enum Kind { case alert, confirm, prompt(String) }
    let id = UUID()
    let kind: Kind
    let message: String
    let origin: String
    /// (OK か, prompt の入力)
    let respond: (Bool, String?) -> Void
}

/// 保存するタブ
struct SavedTab: Codable {
    var id: Int
    var url: String?
    var title: String
    var mode: NetMode
    /// WebKit の戻る/進むの履歴（WKWebView.interactionState）
    var state: Data?
}

struct SessionData: Codable {
    var tabs: [SavedTab]
    var selected: Int?
}

@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: Int?
    @Published var showTabOverview = false
    @Published var showDevPanel = false
    /// いま出しているダイアログ（順番待ちは dialogQueue）
    @Published private(set) var dialog: JSDialog?
    @Published var dialogInput = ""
    /// VNet の様子（ツールバー・開発者パネル用）
    @Published private(set) var vnetReady = false
    @Published private(set) var vnetStatus = "準備中…"
    /// 開発者パネルのログ（パネルを開いている間だけ更新する）
    @Published private(set) var logText = ""

    let machine = VNetMachine(factory: NWUserNetFactory())
    /// Cookie の写し（正本は WebKit の置き場）
    let cookieJar = CookieJar()
    /// HSTS の記録
    let hsts = HSTSStore(fileURL: HSTSStore.defaultFileURL())
    /// 開発者向けのログ（どのスレッドからでも書ける）
    let logs = DevLog()
    /// https の横取りの結果・新しいタブの通信の作り（setUp で決める）
    private(set) var takeover: HTTPSTakeover.Outcome = .disabledBySetting
    private(set) var defaultMode: NetMode = .native
    /// 全部のタブに入れる WebKit のルール（LAN の保護など）
    private(set) var contentRuleLists: [WKContentRuleList] = []
    private var cookieSync: WebCookieSync?
    private var nextTabID = 1
    /// 閉じたタブ（⌘⇧T で戻す。新しいものが後ろ）
    private var closedTabs: [SavedTab] = []
    private var dialogQueue: [JSDialog] = []
    private let session = JSONFile<SessionData>(name: "session.json")
    private var timers: [Timer] = []
    private var memoryObserver: NSObjectProtocol?
    private var didSetUp = false

    /// 動いている WebView の上限（これを超えたら、長く見ていないタブから WebView を捨てる）
    static let maxLiveWebViews = 6
    static let maxClosedTabs = 20

    /// @StateObject から作られる。iPad の Swift ではここが MainActor の中と見なされないことがあるので、
    /// 自分の @MainActor のものは触らず、準備は setUp に回す
    nonisolated init() {
        Task { @MainActor in self.setUp() }
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var searchEngine: SearchEngine { VelaSettings.searchEngine }
    var liveWebViewCount: Int { tabs.filter { $0.webView != nil }.count }

    private func setUp() {
        if didSetUp { return }
        didSetUp = true
        let lb = logs
        takeover = HTTPSTakeover.install()
        if takeover == .installed { defaultMode = .vnetDirect }
        else if VelaSettings.legacyVNetsFallback && !VelaSettings.vnetDisabled { defaultMode = .vnetsLegacy }
        else { defaultMode = .native }
        logs.add(takeover.description)
        logs.add("新しいタブの通信: \(defaultMode.rawValue)")
        if defaultMode == .vnetsLegacy { logs.add("⚠️ 予備の vnets://… の作りで読みます（開発者向けの実験。CSP などを外すので安全ではありません）") }
        session.log = { s in lb.add(s) }

        // VNet: Cookie の正本は WebKit の置き場。CookieJar はその写し
        cookieJar.settings = VelaSettings.cookiePolicy
        cookieJar.log = { s in lb.add(s) }
        hsts.log = { s in lb.add(s) }
        machine.log = { s in lb.add(s) }
        if takeover == .installed || defaultMode == .vnetsLegacy {
            let sync = WebCookieSync(store: WKWebsiteDataStore.default().httpCookieStore, jar: cookieJar)
            sync.log = { s in lb.add(s) }
            cookieSync = sync
            machine.configurePolicies(cookieJar: cookieJar, hsts: hsts, localNetworkProtection: VelaSettings.localNetworkProtection)
            // 自作の通信で送る User-Agent も同じもの（ページの JavaScript から見えるものと食い違うと、ロボットだと思われる）
            machine.setUserAgent(BrowserIdentity.userAgent)
            machine.boot()
        }
        if VelaSettings.localNetworkProtection { compileLocalNetworkRules() } else { logs.add("⚠️ LAN の保護は切ってあります") }
        if defaultMode == .vnetsLegacy { compileVNetOnlyRules() }

        restoreSession()
        if tabs.isEmpty { newTab(url: nil) }

        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.handleMemoryWarning() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.refreshStatus() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let store = self
            Task { @MainActor in store?.flushLogIfVisible() }
        })
    }

    // MARK: タブ

    /// 新しいタブ（url が nil なら空のタブ）。select: すぐ見るか
    @discardableResult
    func newTab(url: URL?, select: Bool = true, mode: NetMode? = nil, after: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(id: nextTabID, store: self, mode: mode ?? defaultMode)
        nextTabID += 1
        if let after, let i = tabs.firstIndex(where: { $0 === after }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if let url { tab.load(url, userInitiated: true) }
        if select { self.select(tab) }
        saveSession()
        return tab
    }

    /// ページが開いた新しい窓（target=_blank・window.open）。WebKit が渡した設定で WebView を作ってタブにする
    func adoptPopup(configuration: WKWebViewConfiguration, opener: BrowserTab) -> WKWebView {
        let tab = BrowserTab(id: nextTabID, store: self, mode: opener.mode)
        nextTabID += 1
        if let i = tabs.firstIndex(where: { $0 === opener }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        let wv = tab.adopt(configuration: configuration, scheme: opener.scheme)
        select(tab)
        logs.add("新しい窓をタブにしました（#\(opener.id) から）", level: .info, category: .nav, tab: tab.id)
        return wv
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        tab.lastSelected = Date()
        tab.ensureWebView()
        trimLiveWebViews()
        saveSession()
    }

    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        closedTabs.append(tab.saved())
        if closedTabs.count > BrowserStore.maxClosedTabs { closedTabs.removeFirst(closedTabs.count - BrowserStore.maxClosedTabs) }
        tab.tearDown()
        tabs.remove(at: i)
        logs.add("タブを閉じました", level: .info, category: .nav, tab: tab.id)
        if tabs.isEmpty { newTab(url: nil); return }
        if selectedID == tab.id { select(tabs[min(i, tabs.count - 1)]) }
        saveSession()
    }

    func closeOthers(_ keep: BrowserTab) {
        for t in tabs where t !== keep { close(t) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let s = closedTabs.popLast() else { return }
        let tab = BrowserTab(id: nextTabID, store: self, mode: s.mode)
        nextTabID += 1
        tab.restore(from: s)
        tabs.append(tab)
        select(tab)
    }

    func selectNextTab(_ step: Int) {
        guard let cur = selectedTab, let i = tabs.firstIndex(where: { $0 === cur }), !tabs.isEmpty else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    /// アドレス欄から開く（URL か検索語か）
    func open(_ text: String, in tab: BrowserTab? = nil) {
        guard let r = AddressInput.resolve(text, engine: searchEngine) else { return }
        let target = tab ?? selectedTab ?? newTab(url: nil)
        switch r {
        case .url(let u):
            logs.add("―― \(u.absoluteString) を開きます ――", level: .info, category: .nav, tab: target.id)
            target.load(u, userInitiated: true)
        case .search(let q, let u):
            logs.add("―― 「\(q)」を検索します（\(searchEngine.name)）――", level: .info, category: .nav, tab: target.id)
            target.load(u, userInitiated: true)
        }
    }

    /// 動いている WebView が多すぎたら、長く見ていないタブ（見ているタブ以外）から WebView を捨てる
    private func trimLiveWebViews() {
        let live = tabs.filter { $0.webView != nil && $0.id != selectedID }.sorted { $0.lastSelected < $1.lastSelected }
        let over = live.count + (selectedTab?.webView != nil ? 1 : 0) - BrowserStore.maxLiveWebViews
        if over <= 0 { return }
        for t in live.prefix(over) { t.suspend(reason: "動いている WebView が \(BrowserStore.maxLiveWebViews) 枚を超えた") }
    }

    private func handleMemoryWarning() {
        let others = tabs.filter { $0.webView != nil && $0.id != selectedID }
        logs.add("⚠️ メモリ警告: 見ていないタブ \(others.count) 枚の WebView を捨てます", level: .warning, category: .app)
        for t in others { t.suspend(reason: "メモリ警告") }
    }

    /// タブ一覧を開く前に、動いているタブのスナップショットを撮る
    func openTabOverview() {
        for t in tabs where t.webView != nil { t.takeSnapshot() }
        showTabOverview = true
    }

    // MARK: 保存

    func saveSession() {
        session.save(SessionData(tabs: tabs.map { $0.saved() }, selected: selectedID))
    }

    /// アプリが裏に回るとき: すぐ書く
    func saveSessionNow() {
        session.saveNow(SessionData(tabs: tabs.map { $0.saved() }, selected: selectedID))
        hsts.saveNow()
    }

    private func restoreSession() {
        guard let s = session.load(), !s.tabs.isEmpty else { return }
        for st in s.tabs {
            var mode = st.mode
            if mode.usesVNet && defaultMode == .native { mode = .native }      // VNet が使えないときは標準の通信で
            if mode == .vnetDirect && defaultMode == .vnetsLegacy { mode = .vnetsLegacy }
            let tab = BrowserTab(id: st.id, store: self, mode: mode)
            tab.restore(from: st)
            tabs.append(tab)
            nextTabID = max(nextTabID, st.id + 1)
        }
        logs.add("前のタブを \(s.tabs.count) 枚戻しました", level: .info, category: .app)
        select(tabs.first { $0.id == s.selected } ?? tabs[0])
    }

    // MARK: ダイアログ（JavaScript の alert・confirm・prompt）

    func presentDialog(_ d: JSDialog) {
        if dialog == nil { show(d) } else { dialogQueue.append(d) }
    }

    private func show(_ d: JSDialog) {
        if case .prompt(let def) = d.kind { dialogInput = def } else { dialogInput = "" }
        dialog = d
    }

    /// ダイアログを閉じる（ok: OK を押したか）
    func answerDialog(ok: Bool) {
        guard let d = dialog else { return }
        dialog = nil
        d.respond(ok, ok ? dialogInput : nil)
        if !dialogQueue.isEmpty { show(dialogQueue.removeFirst()) }
    }

    /// そのタブのダイアログを全部取り消す（タブを閉じたとき）
    func cancelDialogs(for tab: BrowserTab) {
        let mine = dialogQueue.filter { $0.origin.hasPrefix("#\(tab.id) ") }
        dialogQueue.removeAll { $0.origin.hasPrefix("#\(tab.id) ") }
        for d in mine { d.respond(false, nil) }
        if let d = dialog, d.origin.hasPrefix("#\(tab.id) ") { answerDialog(ok: false) }
    }

    // MARK: WebKit のルール

    /// LAN の保護のルール（標準の通信のタブ・WebSocket・VNet の手前）
    private func compileLocalNetworkRules() {
        let lb = logs
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vela-lan-protection", encodedContentRuleList: PageScripts.localNetworkRules) { [weak self] list, error in
            let store = self
            if let list {
                Task { @MainActor in store?.addRuleList(list) }
            } else {
                lb.add("⚠️ LAN の保護のルールを WebKit に入れられません: \(error.map { "\($0)" } ?? "不明")")
            }
        }
    }

    /// 予備の vnets:// の作りで、ブラウザが自分で外へ読みに行くのを止める（自作の通信だけで読む実験のため）
    private func compileVNetOnlyRules() {
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vnet-only", encodedContentRuleList: rules) { [weak self] list, _ in
            let store = self
            if let list { Task { @MainActor in store?.addRuleList(list, onlyVNetsLegacy: true) } }
        }
    }

    private var vnetsOnlyRuleLists: [WKContentRuleList] = []

    private func addRuleList(_ list: WKContentRuleList, onlyVNetsLegacy: Bool = false) {
        if onlyVNetsLegacy { vnetsOnlyRuleLists.append(list) } else { contentRuleLists.append(list) }
        for t in tabs { t.addRuleList(list, onlyVNetsLegacy: onlyVNetsLegacy) }
    }

    /// そのタブに入れるルール
    func ruleLists(for mode: NetMode) -> [WKContentRuleList] {
        contentRuleLists + (mode == .vnetsLegacy ? vnetsOnlyRuleLists : [])
    }

    /// VNet のタブの Cookie を WebKit の置き場に入れる（VNetScheme から）
    func pushCookies(_ changes: [CookieChange]) async {
        await cookieSync?.apply(changes)
    }

    func cookiesChangedByPage() {
        cookieSync?.scheduleRefresh()
    }

    // MARK: 様子

    private func refreshStatus() {
        guard defaultMode.usesVNet || tabs.contains(where: { $0.mode.usesVNet }) else {
            vnetStatus = "VNet: 使っていません（\(takeover.description)）"
            return
        }
        machine.stats { [weak self] s in
            let store = self
            let text = (s.ready ? "IP \(s.ip)" : "IP をもらっています…") + "・" + s.summary
            Task { @MainActor in
                store?.vnetReady = s.ready
                store?.vnetStatus = text
            }
        }
    }

    private func flushLogIfVisible() {
        guard showDevPanel, let t = logs.take(lines: 400) else { return }
        logText = t
    }
}
