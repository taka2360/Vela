// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 1 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

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
            if !store.isOnline {
                OfflineBanner()
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
                DownloadsButton(manager: store.downloads, show: $store.showDownloads)
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
        .sheet(isPresented: $store.showDownloads) { DownloadsView(manager: store.downloads) }
    }
}

/// ネットワークにつながっていないときの帯
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("ネットワークにつながっていません")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.orange)
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
                Button(store.hadCrash ? "前回の記録をコピー（落ちた）" : "前回の記録をコピー") {
                    UIPasteboard.general.string = CrashLog.previous() ?? "（前回の記録はありません）"
                }
                .padding(.leading, 12)
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
            Text("ネットワーク: \(store.isOnline ? "つながっている" : "つながっていない")・ダウンロード中 \(store.downloads.runningCount) 件")
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
