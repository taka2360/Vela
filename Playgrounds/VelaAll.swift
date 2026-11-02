// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// 元ファイル: MyApp.swift, BrowserView.swift, BrowserControls.swift, TabViews.swift, LibraryView.swift, DevPanel.swift, DevPanelPages.swift, SettingsView.swift, AdBlockView.swift, Downloads.swift, DownloadFiles.swift, BrowserStore.swift, BrowserTab.swift, Library.swift, LibraryModel.swift, AddressInput.swift, ErrorPages.swift, NetLog.swift, FilterLists.swift, ABPFilter.swift, BlockEngine.swift, ContentBlocker.swift, Persistence.swift, DevLog.swift, CrashLog.swift, VNetScheme.swift, HTTPSTakeover.swift, PageScripts.swift, NetPolicy.swift, CookieJar.swift, HSTSStore.swift, HTTPClient.swift, HTTPResponseParser.swift, HTTPSupport.swift, TLSClient.swift, GuestStack.swift, GuestTCP.swift, DNSMessage.swift, Packet.swift, VNetMachine.swift, VNetCore.swift, VNetDriver.swift, UserNet.swift, UserNetApple.swift

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

@MainActor
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
                .overlay(alignment: .top) { SuggestionOverlay(store: store, editor: store.address) }
        }
        .background(ShortcutKeys(store: store))
        .sheet(isPresented: $store.showDevPanel) { DevPanel(store: store) }
        .sheet(isPresented: $store.showAdBlock) { AdBlockView(adblock: store.adblock) }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $store.showLibrary) { LibraryView(store: store, library: store.library) }
        .sheet(isPresented: shareShown) { if let u = store.shareURL { ShareSheet(items: [u]) } }
        .fullScreenCover(isPresented: $store.showTabOverview) { TabOverview(store: store) }
        .modifier(DialogModifier(store: store))
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.saveSessionNow() }
        }
    }

    private var shareShown: Binding<Bool> {
        Binding(get: { store.shareURL != nil }, set: { if !$0 { store.shareURL = nil } })
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
                Button { store.openLibrary(.bookmarks) } label: { Image(systemName: "book") }
                AddressField(store: store, tab: tab, editor: store.address, library: store.library)
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
    @ObservedObject var editor: AddressEditor
    let library: Library
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if !focused {
                PageMenu(store: store, tab: tab, library: library)
            }
            ZStack {
                // TextField はいつも置いておく（focused = true にした時に無いとフォーカスが当たらずキーボードが出ない）
                field
                    .opacity(focused ? 1 : 0)
                if !focused {
                    Button { beginEditing() } label: { display.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.tertiarySystemFill)))
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .onChange(of: focused) { f in
            if editor.editing != f { editor.editing = f }
        }
        .onChange(of: editor.focusRequest) { _ in beginEditing() }
        .onChange(of: editor.blurRequest) { _ in focused = false }
    }

    private var field: some View {
        TextField("検索・アドレスを入力", text: $editor.text)
            .focused($focused)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .onSubmit {
                store.open(editor.text, in: tab)
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
            if tab.blockedCount > 0 {
                Label("\(tab.blockedCount)", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
        editor.text = AddressInput.searchTerms(in: tab.url) ?? tab.url?.absoluteString ?? ""
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
            Button { store.openLibrary(.bookmarks) } label: { Label("ブックマーク", systemImage: "book") }
            Button { store.openLibrary(.history) } label: { Label("履歴", systemImage: "clock") }
            Divider()
            if store.canReopenClosedTab {
                Button { store.reopenClosedTab() } label: { Label("閉じたタブを戻す", systemImage: "arrow.uturn.backward") }
            }
            Button { store.close(tab) } label: { Label("このタブを閉じる", systemImage: "xmark.square") }
            Divider()
            Button { store.showAdBlock = true } label: { Label("広告ブロック", systemImage: "shield.lefthalf.filled") }
            Button { store.showSettings = true } label: { Label("設定", systemImage: "gearshape") }
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
                TabPage(store: store, tab: tab)
            }
        }
    }
}

struct TabPage: View {
    let store: BrowserStore
    @ObservedObject var tab: BrowserTab

    var body: some View {
        ZStack {
            WebHost(webView: tab.webView)
            if tab.url == nil {
                StartPage(store: store, library: store.library)
            }
        }
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
// MARK: - BrowserControls.swift
// ======================================================================

// MARK: - 「ぁあ」メニュー（ページごとの操作）と、キーボードショートカット

/// アドレス欄の左の「ぁあ」: 文字の大きさ・ページ内を検索・ブックマーク・共有・通信の切り替え
struct PageMenu: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject var library: Library

    var body: some View {
        Menu {
            Button { tab.changeZoom(1) } label: { Label("文字を大きく", systemImage: "textformat.size.larger") }
            Button { tab.changeZoom(0) } label: { Label("文字の大きさ: \(PageZoom.percent(tab.zoom))（元に戻す）", systemImage: "textformat.size") }
            Button { tab.changeZoom(-1) } label: { Label("文字を小さく", systemImage: "textformat.size.smaller") }
            Divider()
            Button { tab.findInPage() } label: { Label("ページ内を検索", systemImage: "doc.text.magnifyingglass") }
            if tab.url != nil {
                Button { store.toggleBookmark() } label: {
                    library.isBookmarked(tab.url)
                        ? Label("ブックマークを外す", systemImage: "book.fill")
                        : Label("ブックマークに入れる", systemImage: "book")
                }
                Button { UIPasteboard.general.url = tab.url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
                Button { store.shareURL = tab.url } label: { Label("共有…", systemImage: "square.and.arrow.up") }
            }
            Divider()
            AdBlockMenuItems(store: store, tab: tab, adblock: store.adblock)
            Divider()
            if tab.mode.usesVNet {
                Button { tab.switchMode(to: .native) } label: { Label("標準の通信で開き直す", systemImage: "network") }
            } else if store.defaultMode.usesVNet {
                Button { tab.switchMode(to: store.defaultMode) } label: { Label("VNet で開き直す", systemImage: "cpu") }
            }
        } label: {
            Text("ぁあ")
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 6)
        }
    }
}

/// 「ぁあ」メニューの広告ブロックの所
struct AdBlockMenuItems: View {
    let store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject var adblock: AdBlocker

    var body: some View {
        if let host = tab.url?.host, adblock.enabled {
            Button {
                adblock.toggleSite(host)
                tab.reload()      // 今のページにも効かせる
            } label: {
                adblock.isActive(for: host)
                    ? Label(tab.mode.usesVNet ? "広告ブロック: \(tab.blockedCount) 件（このサイトでは止める）" : "このサイトでは広告ブロックを止める",
                            systemImage: "shield.slash")
                    : Label("このサイトで広告ブロックを使う", systemImage: "shield.lefthalf.filled")
            }
        }
        Button { store.showAdBlock = true } label: { Label("広告ブロックの設定…", systemImage: "gearshape") }
    }
}

/// キーボードのショートカット（見えないボタン。⌘ を長押しすると一覧に出る）
/// ⌘T・⌘R・⌘[・⌘] はツールバーのボタンに付けてある
struct ShortcutKeys: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            Group {
            Button("アドレス欄へ") { store.focusAddressBar() }.keyboardShortcut("l", modifiers: .command)
            Button("タブを閉じる") { if let t = store.selectedTab { store.close(t) } }.keyboardShortcut("w", modifiers: .command)
            Button("閉じたタブを戻す") { store.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("次のタブ") { store.selectNextTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("前のタブ") { store.selectNextTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("次のタブ ") { store.selectNextTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("前のタブ ") { store.selectNextTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            TabNumberKeys(store: store)
            }
            Group {
            Button("ページ内を検索") { store.selectedTab?.findInPage() }.keyboardShortcut("f", modifiers: .command)
            Button("ブックマークに入れる・外す") { store.toggleBookmark() }.keyboardShortcut("d", modifiers: .command)
            Button("ブックマーク") { store.openLibrary(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("履歴") { store.openLibrary(.history) }.keyboardShortcut("y", modifiers: .command)
            Button("文字を大きく") { store.selectedTab?.changeZoom(1) }.keyboardShortcut("+", modifiers: .command)
            Button("文字を大きく ") { store.selectedTab?.changeZoom(1) }.keyboardShortcut("=", modifiers: .command)
            Button("文字を小さく") { store.selectedTab?.changeZoom(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("文字の大きさを元に戻す") { store.selectedTab?.changeZoom(0) }.keyboardShortcut("0", modifiers: .command)
            Button("読み込みを止める") { store.selectedTab?.stop() }.keyboardShortcut(".", modifiers: .command)
            Button("開発者パネル") { store.showDevPanel = true }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

/// ⌘1〜⌘9: タブを選ぶ（9 は最後のタブ）
struct TabNumberKeys: View {
    let store: BrowserStore

    var body: some View {
        ForEach(1..<10) { n in
            Button("タブ \(n)") { store.selectTab(number: n) }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
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
// MARK: - LibraryView.swift
// ======================================================================

// MARK: - ブックマーク・履歴の画面（シート）、アドレス欄の候補、新しいタブの画面

struct LibraryView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("表示", selection: $store.libraryPage) {
                    ForEach(LibraryPage.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
                Button("完了") { dismiss() }
            }
            .padding()
            if store.libraryPage == .bookmarks {
                BookmarksPage(store: store, library: library) { dismiss() }
            } else {
                HistoryPage(store: store, library: library) { dismiss() }
            }
        }
    }
}

@MainActor
struct BookmarksPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    let done: () -> Void
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    var body: some View {
        Group {
            if library.bookmarks.items.isEmpty {
                EmptyNote(icon: "book", text: "ブックマークはまだありません。\n「ぁあ」メニューか ⌘D で、見ているページを入れられます")
            } else {
                List {
                    ForEach(library.bookmarks.items) { b in
                        BookmarkRow(store: store, library: library, bookmark: b, done: done) {
                            newTitle = b.title
                            renaming = b
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { library.bookmarks.items[$0].id }
                        for id in ids { library.removeBookmark(id) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .alert("名前を変える", isPresented: renameShown) {
            TextField("名前", text: $newTitle)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("OK") {
                if let b = renaming { library.renameBookmark(b.id, title: newTitle) }
                renaming = nil
            }
        } message: {
            Text(renaming?.url ?? "")
        }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

@MainActor
struct BookmarkRow: View {
    let store: BrowserStore
    let library: Library
    let bookmark: Bookmark
    let done: () -> Void
    let rename: () -> Void

    var body: some View {
        Button {
            open(newTab: false)
        } label: {
            SiteRow(icon: "book", title: bookmark.title, url: bookmark.url)
        }
        .contextMenu {
            Button { open(newTab: true) } label: { Label("新しいタブで開く", systemImage: "plus.square.on.square") }
            Button { UIPasteboard.general.string = bookmark.url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
            Button { rename() } label: { Label("名前を変える", systemImage: "pencil") }
            Button { library.moveBookmark(bookmark.id, by: -1) } label: { Label("上へ", systemImage: "arrow.up") }
            Button { library.moveBookmark(bookmark.id, by: 1) } label: { Label("下へ", systemImage: "arrow.down") }
            Button(role: .destructive) { library.removeBookmark(bookmark.id) } label: { Label("削除", systemImage: "trash") }
        }
    }

    private func open(newTab: Bool) {
        guard let u = URL(string: bookmark.url) else { return }
        store.open(url: u, newTab: newTab)
        done()
    }
}

struct HistoryPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("履歴を検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                ClearHistoryMenu(library: library)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            if library.history.entries.isEmpty {
                EmptyNote(icon: "clock", text: "履歴はありません")
            } else {
                HistoryList(store: store, library: library, groups: HistoryLog.groupByDay(library.history.search(query)), done: done)
            }
        }
    }
}

struct HistoryList: View {
    let store: BrowserStore
    let library: Library
    let groups: [(title: String, entries: [HistoryEntry])]
    let done: () -> Void

    var body: some View {
        List {
            ForEach(groups, id: \.title) { g in
                Section {
                    ForEach(g.entries) { e in
                        HistoryRow(store: store, library: library, entry: e, done: done)
                    }
                    .onDelete { idx in
                        let urls = idx.map { g.entries[$0].url }
                        for u in urls { library.removeHistory(u) }
                    }
                } header: {
                    Text(g.title)
                }
            }
        }
        .listStyle(.plain)
    }
}

@MainActor
struct HistoryRow: View {
    let store: BrowserStore
    let library: Library
    let entry: HistoryEntry
    let done: () -> Void

    var body: some View {
        Button {
            open(newTab: false)
        } label: {
            SiteRow(icon: "clock", title: entry.title.isEmpty ? entry.url : entry.title, url: entry.url)
        }
        .contextMenu {
            Button { open(newTab: true) } label: { Label("新しいタブで開く", systemImage: "plus.square.on.square") }
            Button { UIPasteboard.general.string = entry.url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
            Button(role: .destructive) { library.removeHistory(entry.url) } label: { Label("履歴から消す", systemImage: "trash") }
        }
    }

    private func open(newTab: Bool) {
        guard let u = URL(string: entry.url) else { return }
        store.open(url: u, newTab: newTab)
        done()
    }
}

struct ClearHistoryMenu: View {
    let library: Library

    var body: some View {
        Menu {
            Button(role: .destructive) { library.clearHistory(since: Date().addingTimeInterval(-3600)) } label: { Text("直近 1 時間") }
            Button(role: .destructive) { library.clearHistory(since: Calendar.current.startOfDay(for: Date())) } label: { Text("今日") }
            Button(role: .destructive) { library.clearHistory(since: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)) } label: { Text("今日と昨日") }
            Button(role: .destructive) { library.clearHistory(since: nil) } label: { Text("すべて") }
        } label: {
            Text("消去…").foregroundColor(.red)
        }
    }
}

/// 一覧の 1 行（タイトルと URL）
struct SiteRow: View {
    let icon: String
    let title: String
    let url: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).foregroundColor(.primary)
                Text(url).font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: アドレス欄の候補（打っている間、ページの上に重ねる）

struct SuggestionOverlay: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var editor: AddressEditor

    var body: some View {
        if editor.editing {
            ZStack(alignment: .top) {
                // 外を押したらアドレス欄から離れる
                Color.black.opacity(0.08)
                    .onTapGesture { editor.blur() }
                if !editor.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    SuggestionList(store: store, editor: editor, items: store.library.suggestions(for: editor.text))
                }
            }
        }
    }
}

@MainActor
struct SuggestionList: View {
    let store: BrowserStore
    let editor: AddressEditor
    let items: [Suggestion]

    var body: some View {
        VStack(spacing: 0) {
            Button { go(nil) } label: {
                SiteRow(icon: "magnifyingglass", title: editor.text, url: firstLine)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ForEach(items) { s in
                Divider()
                Button { go(s) } label: {
                    SiteRow(icon: s.kind == .bookmark ? "book" : "clock", title: s.title.isEmpty ? s.url : s.title, url: s.url)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.systemBackground)))
        .shadow(radius: 8, y: 2)
        .frame(maxWidth: 680)
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private var firstLine: String {
        switch AddressInput.resolve(editor.text, engine: store.searchEngine) {
        case .url(let u)?: return "\(u.absoluteString) を開く"
        default: return "\(store.searchEngine.name) で検索"
        }
    }

    private func go(_ s: Suggestion?) {
        if let s, let u = URL(string: s.url) { store.open(url: u) } else { store.open(editor.text) }
        editor.blur()
    }
}

// MARK: 新しいタブの画面（ブックマークとよく見るサイト）

struct StartPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let favorites = Array(library.bookmarks.items.prefix(12))
                let top = library.history.topSites(limit: 8)
                if favorites.isEmpty && top.isEmpty {
                    EmptyNote(icon: "globe", text: "上のアドレス欄に、URL か調べたいことを入れてください")
                        .padding(.top, 120)
                }
                if !favorites.isEmpty {
                    SiteGrid(store: store, title: "ブックマーク", sites: favorites.map { ($0.title, $0.url) }, columns: columns)
                }
                if !top.isEmpty {
                    SiteGrid(store: store, title: "よく見るサイト", sites: top.map { ($0.title, $0.url) }, columns: columns)
                }
            }
            .frame(maxWidth: 760)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(UIColor.systemBackground))
    }
}

struct SiteGrid: View {
    let store: BrowserStore
    let title: String
    let sites: [(String, String)]
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sites, id: \.1) { site in
                    SiteTile(title: site.0, url: site.1) {
                        if let u = URL(string: site.1) { store.open(url: u) }
                    }
                }
            }
        }
    }
}

struct SiteTile: View {
    let title: String
    let url: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.tertiarySystemFill))
                    Text(initial).font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                Text(title.isEmpty ? host : title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var host: String { AddressInput.shortDisplay(URL(string: url)) }
    private var initial: String { String(host.first ?? "?").uppercased() }
}

// ======================================================================
// MARK: - DevPanel.swift
// ======================================================================

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
            HStack {
                Text("開発者パネル").font(.headline)
                Spacer()
                Menu {
                    Button("ログをコピー") { UIPasteboard.general.string = store.logs.export() }
                    Button("通信の記録をコピー") { UIPasteboard.general.string = store.netLog.export() }
                    Button(store.hadCrash ? "前回の記録をコピー（落ちた）" : "前回の記録をコピー") {
                        UIPasteboard.general.string = CrashLog.previous() ?? "（前回の記録はありません）"
                    }
                } label: {
                    Label(store.hadCrash ? "コピー（前回は落ちた）" : "コピー", systemImage: "doc.on.doc")
                }
                Button("閉じる") { dismiss() }.padding(.leading, 12)
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
                TextField("探す", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("コピー") { UIPasteboard.general.string = filtered.map { $0.line }.joined(separator: "\n") }
                Button("消す") { store.logs.clear() }
            }
            .font(.system(size: 13))
            DevLogView(text: filtered.suffix(400).map { $0.line }.joined(separator: "\n"))
        }
    }

    private var filtered: [LogEntry] {
        let tab = onlyThisTab ? store.selectedID : nil
        let q = query.lowercased()
        return store.logs.all().filter { e in
            e.level >= minLevel && (category == nil || e.category == category) && (tab == nil || e.tab == tab)
                && (q.isEmpty || e.message.lowercased().contains(q))
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

    /// 「Text/HTML; charset=utf-8」→「text/html」（「;」の前の部分を小文字に。空の部分は飛ばす）
    static func mimeEssence(_ raw: String) -> String {
        raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// ページとして表示できる種類か（できないものはダウンロードにする）
    static func isDisplayable(mime raw: String) -> Bool {
        let m = mimeEssence(raw)
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
        let m = mimeEssence(raw)
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

/// ブックマーク・履歴の画面のどちらを見せるか
enum LibraryPage: String, CaseIterable, Hashable {
    case bookmarks = "ブックマーク"
    case history = "履歴"
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
    /// 開発者パネルを描き直す合図（パネルを開いている間だけ、0.5 秒ごとに増える）
    @Published private(set) var devTick = 0
    /// VNet の数字（開発者パネル用）
    @Published private(set) var vnetStats: VNetMachine.Stats?
    @Published var showSettings = false
    /// 起動した時刻
    let launchedAt = Date()
    /// 通信の記録（VNet が引き受けた要求 1 つずつ）
    let netLog = NetLog()
    @Published var showDownloads = false
    /// 前回は落ちて終わった（開発者パネルで前回の記録を見られる）
    @Published private(set) var hadCrash = false
    /// ネットワークにつながっているか（NWPathMonitor）
    @Published private(set) var isOnline = true
    /// ダウンロード
    let downloads = DownloadManager()
    /// ブックマークと履歴
    let library = Library()
    /// 広告ブロック
    let adblock = AdBlocker()
    @Published var showAdBlock = false
    /// アドレス欄の入力（打つたびに変わるので分けてある）
    let address = AddressEditor()
    /// ブックマーク・履歴の画面
    @Published var showLibrary = false
    @Published var libraryPage = LibraryPage.bookmarks
    /// 共有する URL（共有の画面を出している間）
    @Published var shareURL: URL?
    private let pathMonitor = NWPathMonitor()

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
        CrashLog.start()
        let lb = logs
        if let crash = CrashLog.previousCrashSummary() {
            logs.add("⚠️ 前回は落ちて終わりました: \(crash)（開発者パネルの「前回の記録」で、落ちる前のログが見られます）", level: .error, category: .app)
            hadCrash = true
        }
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

        library.load(logs: logs)
        adblock.onRuleListsChanged = { [weak self] in
            guard let self else { return }
            for t in self.tabs { t.applyAdBlock(for: t.url) }
        }
        adblock.start(logs: logs)
        downloads.log = { s in lb.add(s, level: .info, category: .download) }
        downloads.webViewForResume = { [weak self] in self?.selectedTab?.webView }
        downloads.loadExisting()

        // ネットワークの様子（つながっていないときは帯を出す）
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let store = self
            Task { @MainActor in store?.setOnline(online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vela-path"))

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

    /// ⌘1〜⌘9: その番号のタブへ（9 は最後のタブ）
    func selectTab(number n: Int) {
        guard !tabs.isEmpty else { return }
        select(n >= 9 ? tabs[tabs.count - 1] : tabs[min(n, tabs.count) - 1])
    }

    // MARK: ブックマーク・履歴

    /// 見ているページのブックマークを付ける・外す（⌘D）
    func toggleBookmark() {
        guard let tab = selectedTab, let u = tab.url else { return }
        library.toggleBookmark(url: u, title: tab.title)
    }

    func openLibrary(_ page: LibraryPage) {
        libraryPage = page
        showLibrary = true
    }

    /// ブックマーク・履歴・候補から開く（newTab: 新しいタブで）
    func open(url: URL, newTab inNew: Bool = false) {
        if inNew { newTab(url: url); return }
        let target = selectedTab ?? newTab(url: nil)
        logs.add("―― \(url.absoluteString) を開きます ――", level: .info, category: .nav, tab: target.id)
        target.load(url, userInitiated: true)
    }

    /// タブがページを読み終えた: 履歴に入れる
    func recordVisit(url: URL, title: String) {
        library.recordVisit(url: url, title: title)
    }

    /// ⌘L: アドレス欄へ
    func focusAddressBar() {
        address.focus()
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
        library.saveNow()
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

    private func setOnline(_ online: Bool) {
        if online == isOnline { return }
        isOnline = online
        logs.add(online ? "ネットワークにつながりました" : "⚠️ ネットワークにつながっていません", level: online ? .info : .warning, category: .app)
    }

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
                if store?.showDevPanel == true { store?.vnetStats = s }
            }
        }
    }

    private func flushLogIfVisible() {
        guard showDevPanel else { return }
        devTick += 1
    }

    // MARK: 設定・データ

    /// Cookie の決まりなど、すぐ効かせられる設定を入れ直す
    func applySettings() {
        cookieJar.settings = VelaSettings.cookiePolicy
        for t in tabs { t.applySettings() }
        logs.add("設定を変えました", level: .info, category: .app)
    }

    /// Cookie・キャッシュ・サイトのデータを消す
    func clearWebsiteData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date.distantPast) { [weak self] in
            let store = self
            Task { @MainActor in
                store?.cookieJar.removeAll()
                store?.logs.add("Cookie とサイトのデータを消しました", level: .info, category: .cookie)
            }
        }
    }

    func clearHSTS() {
        hsts.removeAll()
        logs.add("HSTS の記録を消しました", level: .info, category: .security)
    }

    func clearClosedTabs() { closedTabs = [] }
}

// ======================================================================
// MARK: - BrowserTab.swift
// ======================================================================

// MARK: - タブ 1 枚
//
// ・WKWebView は必要なときだけ作る（ensureWebView）。見ていない間に捨てられたら（suspend）、スナップショットと
//   戻る/進むの履歴（interactionState）だけを持っておき、次に見るときに作り直して戻す
// ・WebView の状態（URL・タイトル・読み込みの進み具合・戻れるか）は KVO で受け取る
// ・通信の作り（VNet / 標準）は WebView を作るときにしか決められないので、切り替えは作り直しで行う
// ・捨てるときは、デリゲート・スクリプトの受け口・KVO を外して、読み込み中の要求を止める（循環参照と漏れを防ぐ）

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    enum LifeState: String {
        case live = "動いている"
        case suspended = "休止中"
        case crashed = "落ちた"
    }

    let id: Int
    private weak var store: BrowserStore?
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isSecure = false
    @Published private(set) var mode: NetMode
    @Published private(set) var state = LifeState.suspended
    @Published private(set) var snapshot: UIImage?
    /// このページが使った、VNet を通らない通信（"WebSocket" など）
    @Published private(set) var nonVNetUsage: Set<String> = []
    /// このページで広告ブロックが止めた数（VNet のタブだけ数えられる）
    @Published private(set) var blockedCount = 0
    /// 文字の大きさ（ページの拡大率。サイトごとに覚える）
    @Published private(set) var zoom = 1.0
    /// 最後に見た時刻（WebView を捨てる順番を決める）
    var lastSelected = Date()

    private(set) var webView: WKWebView?
    /// VNet のタブの、要求を引き受ける部品（タブごとに 1 つ。通信の machine は共有）
    private(set) var scheme: VNetScheme?
    private var delegate: TabWebDelegate?
    private var observations: [NSKeyValueObservation] = []
    private let cookies = CookieBridge()
    private let actions = PageActionBridge()
    private var refresh: UIRefreshControl?
    /// 休止中のときの、戻る/進むの履歴（WKWebView.interactionState）と開く URL
    private var savedState: Data?
    private var pendingURL: URL?
    /// 標準の通信のときのエラーページのボタンの合言葉（VNet のときは VNetScheme が持つ）
    private let pageActions = PageActions()
    /// HTTPS-First（標準の通信）: https に上げて試している元の http の URL
    private var httpsFirstFrom: URL?
    /// HTTPS-First で「http のまま開く」を選んだホスト
    private var httpAllowedHosts = Set<String>()
    /// 移動の出来事（開発者パネル。最新 200 件）
    private(set) var navEvents: [(Date, String)] = []
    /// いま入れている広告ブロックの WebKit のルール
    private var adRuleLists: [WKContentRuleList] = []
    /// エラーページを出した URL（履歴に入れない）
    private var errorPageURL: URL?
    /// 最後に履歴に入れた URL（後からタイトルが変わったら直す）
    private var lastRecorded: URL?

    init(id: Int, store: BrowserStore, mode: NetMode) {
        self.id = id
        self.store = store
        self.mode = mode
    }

    private func log(_ s: String, level: LogLevel = .info, category: LogCategory = .nav) {
        store?.logs.add(s, level: level, category: category, tab: id)
    }

    // MARK: WebView を作る・捨てる

    /// 見るときに呼ぶ。WebView が無ければ作って、休止中の履歴を戻す
    func ensureWebView() {
        if let wv = webView {
            // 見ていない間にページのプロセスが落ちていた: 見るときに読み直す
            if state == .crashed {
                log("落ちていたページを読み直します")
                wv.reload()
                state = .live
            }
            return
        }
        let wv = makeWebView(configuration: nil, scheme: nil)
        if let s = savedState {
            wv.interactionState = s as NSData
            savedState = nil
            log("休止中の履歴から戻しました")
        } else if let u = pendingURL ?? url {
            pendingURL = nil
            load(u, userInitiated: true)
        }
        state = .live
    }

    /// ページが開いた新しい窓。WebKit が渡した設定で作る（設定を変えると WebKit が止まるので、そのまま使う）
    func adopt(configuration: WKWebViewConfiguration, scheme opener: VNetScheme?) -> WKWebView {
        let wv = makeWebView(configuration: configuration, scheme: opener)
        state = .live
        return wv
    }

    private func makeWebView(configuration given: WKWebViewConfiguration?, scheme opener: VNetScheme?) -> WKWebView {
        let config: WKWebViewConfiguration
        if let given {
            config = given
            scheme = opener
        } else {
            config = makeConfiguration()
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        // User-Agent を iPad の Safari と同じにする。WKWebView の初期値には「Version/… Safari/…」が無く、
        // アプリの中のブラウザやロボットだと思われて、エラーや「不審なトラフィック」の画面になりやすい
        wv.customUserAgent = BrowserIdentity.userAgent
        wv.allowsBackForwardNavigationGestures = true
        // ページ内を検索（⌘F・「ぁあ」メニュー）
        wv.isFindInteractionEnabled = true
        if #available(iOS 16.4, *) { wv.isInspectable = VelaSettings.webInspector }
        let d = TabWebDelegate(tab: self)
        wv.navigationDelegate = d
        wv.uiDelegate = d
        delegate = d
        // 引っ張って再読み込み
        let rc = UIRefreshControl()
        rc.addAction(UIAction { [weak self, weak rc] _ in
            self?.webView?.reload()
            rc?.endRefreshing()
        }, for: .valueChanged)
        wv.scrollView.refreshControl = rc
        refresh = rc
        observe(wv)
        webView = wv
        adRuleLists = []
        applyAdBlock(for: pendingURL ?? url)
        log("WebView を作りました（\(mode.rawValue)）")
        return wv
    }

    /// 通信の作りに合わせた設定（スキームの引き受け・スクリプト・ルール）
    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        if mode.usesVNet, let store {
            let s = VNetScheme()
            s.machine = store.machine
            s.hsts = store.hsts
            s.httpsFirst = VelaSettings.httpsFirst
            s.httpAllowedHosts = httpAllowedHosts
            s.onTopLevelFailure = { [weak self] u, e in
                let tab = self
                Task { @MainActor in tab?.vnetFailed(u, e) }
            }
            s.blocker = store.adblock.box
            s.netLog = store.netLog
            s.tabID = id
            s.onBlocked = { [weak self] _, _ in
                let tab = self
                Task { @MainActor in tab?.noteBlocked() }
            }
            s.onDownloadStarted = { [weak self] dl in
                let tab = self
                Task { @MainActor in tab?.registerVNetDownload(dl) }
            }
            let tabID = id
            let lb = store.logs
            s.log = { m in lb.add(m, tab: tabID) }
            s.pushCookies = { [weak store] changes, done in
                let st = store
                Task { @MainActor in
                    await st?.pushCookies(changes)
                    done()
                }
            }
            scheme = s
            if mode == .vnetDirect {
                config.setURLSchemeHandler(s, forURLScheme: "https")
                config.setURLSchemeHandler(s, forURLScheme: "http")
            } else {
                config.setURLSchemeHandler(s, forURLScheme: "vnet")
                config.setURLSchemeHandler(s, forURLScheme: "vnets")
                content.addUserScript(WKUserScript(source: PageScripts.rewriteURLs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            // Cookie: ページの JavaScript が変えたら「合図」だけもらって、WebKit の置き場（正本）を読み直す
            content.addUserScript(WKUserScript(source: PageScripts.watchCookies, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            cookies.log = { m in lb.add(m, tab: tabID) }
            cookies.onSignal = { [weak store] in
                let st = store
                Task { @MainActor in st?.cookiesChangedByPage() }
            }
            content.add(cookies, name: PageScripts.cookieHandlerName)
        } else {
            scheme = nil
        }
        // LAN の保護: WebSocket は VNet を通らないので、ページの中でも止める
        if VelaSettings.localNetworkProtection {
            content.addUserScript(WKUserScript(source: PageScripts.webSocketGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // VNet を通らない通信（WebSocket）を使ったら知らせてもらう
        content.addUserScript(WKUserScript(source: PageScripts.trackNonVNet, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        actions.onAction = { [weak self] body, isMain, origin in
            let tab = self
            Task { @MainActor in tab?.handleAction(body, isMainFrame: isMain, origin: origin) }
        }
        content.add(actions, name: PageScripts.actionHandlerName)
        for r in store?.ruleLists(for: mode) ?? [] { content.add(r) }
        // 動画: 全画面にせずページの中で再生する・自動再生を許す
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // iPad の Safari と同じ「デスクトップ用の表示」にする（User-Agent と、ページから見える端末の情報を揃えるため）
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        return config
    }

    /// WebKit のルールを後から足す（コンパイルが終わったとき）
    func addRuleList(_ list: WKContentRuleList, onlyVNetsLegacy: Bool) {
        if onlyVNetsLegacy && mode != .vnetsLegacy { return }
        webView?.configuration.userContentController.add(list)
    }

    private func observe(_ wv: WKWebView) {
        // KVO の知らせは画面のスレッドで来るが、閉包は MainActor の外なので、Task で戻ってから触る
        let sync: (WKWebView) -> Void = { [weak self] _ in
            let tab = self
            Task { @MainActor in tab?.syncFromWebView() }
        }
        observations = [
            wv.observe(\.url, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.title, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.estimatedProgress, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.isLoading, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.canGoBack, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.canGoForward, options: [.new]) { w, _ in sync(w) },
            wv.observe(\.hasOnlySecureContent, options: [.new]) { w, _ in sync(w) },
        ]
    }

    func syncFromWebView() {
        guard let wv = webView else { return }
        let real = wv.url.flatMap { VNetURL.toReal($0) } ?? wv.url
        if real != url, real != nil {
            url = real
            nonVNetUsage = []
        }
        let newTitle = wv.title ?? ""
        if newTitle != title, !newTitle.isEmpty, let r = lastRecorded, r == real {
            store?.library.updateTitle(url: r, title: newTitle)
        }
        title = newTitle
        progress = wv.estimatedProgress
        isLoading = wv.isLoading
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        isSecure = wv.hasOnlySecureContent && (real?.scheme?.lowercased() == "https")
    }

    /// WebView を捨てて休止する（スナップショット・履歴・URL は残す）
    func suspend(reason: String) {
        guard let wv = webView else { return }
        if let st = wv.interactionState as? Data { savedState = st } else if let st = wv.interactionState as? NSData { savedState = st as Data }
        pendingURL = url
        log("休止します（\(reason)）")
        tearDownWebView()
        state = .suspended
    }

    /// タブを閉じるとき
    func tearDown() {
        store?.cancelDialogs(for: self)
        tearDownWebView()
    }

    private func tearDownWebView() {
        guard let wv = webView else { return }
        observations = []
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        let content = wv.configuration.userContentController
        content.removeScriptMessageHandler(forName: PageScripts.cookieHandlerName)
        content.removeScriptMessageHandler(forName: PageScripts.actionHandlerName)
        wv.scrollView.refreshControl = nil
        wv.removeFromSuperview()
        webView = nil
        delegate = nil
        refresh = nil
        scheme = nil
        isLoading = false
        progress = 0
    }

    func takeSnapshot() {
        guard let wv = webView, wv.bounds.width > 0 else { return }
        wv.takeSnapshot(with: nil) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    // MARK: 読み込み

    /// 開く。userInitiated: ユーザーの操作（アドレス欄・ブックマークなど）か（LAN の保護・SameSite の判定に使う）
    func load(_ u: URL, userInitiated: Bool) {
        guard let wv = webView else {
            pendingURL = u
            url = u
            savedState = nil
            return
        }
        var target = u
        if mode == .vnetsLegacy {
            guard let v = VNetURL.toVNet(u) else { log("vnets:// にできないアドレスです: \(u.absoluteString)", level: .warning); return }
            target = v
        }
        if userInitiated { scheme?.noteUserNavigation(target) }
        url = u
        nonVNetUsage = []
        wv.load(URLRequest(url: target))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { if webView == nil { ensureWebView() } else { webView?.reload() } }
    func stop() { webView?.stopLoading() }

    /// 戻る/進むの履歴の項目へ
    func go(to item: WKBackForwardListItem) { webView?.go(to: item) }

    /// 通信の作りを変える（同じ URL で WebView を作り直す）
    /// 通信の作りを変える（同じ URL か、target で開き直す）
    func switchMode(to m: NetMode, url target: URL? = nil) {
        guard m != mode else { if let target { load(target, userInitiated: true) }; return }
        let u = target ?? url
        log("通信を \(mode.rawValue) → \(m.rawValue) に切り替えます")
        tearDownWebView()
        savedState = nil
        mode = m
        pendingURL = u
        ensureWebView()
        store?.saveSession()
    }

    // MARK: 保存

    func saved() -> SavedTab {
        var st = savedState
        if let wv = webView {
            if let d = wv.interactionState as? Data { st = d } else if let d = wv.interactionState as? NSData { st = d as Data }
        }
        return SavedTab(id: id, url: url?.absoluteString, title: title, mode: mode, state: st)
    }

    func restore(from s: SavedTab) {
        url = s.url.flatMap { URL(string: $0) }
        title = s.title
        savedState = s.state
        pendingURL = url
        state = .suspended
    }

    /// エラーページのボタン
    private func pageAction(_ item: PageActions.Item) {
        switch item.action {
        case "retry":
            load(item.url, userInitiated: true)
        case "openNative":
            log("標準の通信で開き直します（ユーザーの操作）")
            switchMode(to: .native, url: item.url)
        case "openHTTP":
            if let h = item.url.host?.lowercased() {
                httpAllowedHosts.insert(h)
                scheme?.httpAllowedHosts.insert(h)
            }
            log("http のまま開きます: \(item.url.absoluteString)", category: .security)
            // VNet の http（80 番）は今の環境では 400 にされるので、標準の通信で開く
            if mode.usesVNet { switchMode(to: .native, url: item.url) } else { load(item.url, userInitiated: true) }
        case "allowLocalNetwork":
            log("🛡 LAN の確認: ユーザーが許可しました → \(item.url.absoluteString)", category: .security)
            load(item.url, userInitiated: true)
        default:
            break
        }
    }

    /// VNet でページ本体を読めなかった。設定で選んであれば、標準の通信に自動で切り替える
    private func vnetFailed(_ u: URL, _ e: FetchError) {
        errorPageURL = u
        let kinds: Set<FetchError.Kind> = [.tls, .tlsVersion, .connect, .timeout, .reset, .malformed, .notReady]
        guard VelaSettings.autoFallbackToNative, mode.usesVNet, kinds.contains(e.kind) else { return }
        log("VNet で読めなかったので、標準の通信に自動で切り替えます（\(e.kind.rawValue)）", level: .warning)
        switchMode(to: .native, url: u)
    }

    // MARK: 標準の通信のエラー・HTTPS-First

    /// HTTPS-First（標準の通信）: ページを開く http:// を https に上げるなら、その URL
    func httpsFirstUpgrade(_ u: URL) -> URL? {
        guard VelaSettings.httpsFirst, mode == .native, u.scheme?.lowercased() == "http", let h = u.host?.lowercased(),
              !httpAllowedHosts.contains(h), !SiteUtil.isIPLiteral(h), LocalNetworkPolicy.classify(host: h) == nil, u.port == nil,
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        httpsFirstFrom = u
        log("🔒 HTTPS-First: \(u.absoluteString) → https", category: .security)
        return c.url
    }

    func didCommitNavigation() {
        httpsFirstFrom = nil
        syncFromWebView()
        applySiteZoom()
    }

    func didStartNavigation() {
        errorPageURL = nil
        blockedCount = 0
    }

    // MARK: 広告ブロック

    private func noteBlocked() {
        blockedCount += 1
        store?.adblock.noteBlocked()
    }

    /// 開くページに合わせて、広告ブロックの WebKit のルールを入れ替える（サイトごとの OFF・リストの更新）
    func applyAdBlock(for target: URL?) {
        guard let wv = webView, let store else { return }
        let want = store.adblock.ruleLists(for: mode, host: target?.host)
        if want.map({ $0.identifier }) == adRuleLists.map({ $0.identifier }) { return }
        let content = wv.configuration.userContentController
        for l in adRuleLists { content.remove(l) }
        for l in want { content.add(l) }
        adRuleLists = want
    }

    // MARK: 文字の大きさ・ページ内を検索

    /// そのサイトで覚えている大きさにする
    private func applySiteZoom() {
        guard let wv = webView else { return }
        let z = VelaSettings.zoom(for: url?.host)
        zoom = z
        if abs(Double(wv.pageZoom) - z) > 0.001 { wv.pageZoom = CGFloat(z) }
    }

    /// 大きく（+1）・小さく（-1）・元に戻す（0）。サイトごとに覚える
    func changeZoom(_ delta: Int) {
        let z = PageZoom.step(from: zoom, by: delta)
        VelaSettings.setZoom(z, for: url?.host)
        applySiteZoom()
        log("文字の大きさ: \(PageZoom.percent(z))（\(url?.host ?? "")）")
    }

    func findInPage() {
        ensureWebView()
        webView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// WebKit（標準の通信など）が読めなかった: エラーページを出す
    func showLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }      // 取り消し（次の移動など）
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return } // ダウンロードに変わった など
        guard let wv = webView else { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        guard let f = failing.flatMap({ VNetURL.toReal($0) }) else { return }
        errorPageURL = f
        let html: String
        if let http = httpsFirstFrom, f.host?.lowercased() == http.host?.lowercased() {
            html = ErrorPage.html(title: "https では開けませんでした", lines: [
                "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
                "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
                detail: "\(f.absoluteString)\n\(ns.localizedDescription)",
                buttons: [ErrorPage.Button(label: "http のまま開く", nonce: pageActions.make("openHTTP", url: http), primary: false),
                          ErrorPage.Button(label: "再試行", nonce: pageActions.make("retry", url: f), primary: true)],
                kind: "httpsFirst")
            httpsFirstFrom = nil
        } else {
            let d = ErrorPage.describe(nsErrorCode: ns.code, domain: ns.domain, message: ns.localizedDescription)
            html = ErrorPage.html(title: d.title, lines: [d.hint, f.absoluteString], detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)",
                                  buttons: [ErrorPage.Button(label: "再試行", nonce: pageActions.make("retry", url: f), primary: true)],
                                  kind: "\(ns.domain)/\(ns.code)")
        }
        wv.loadHTMLString(html, baseURL: f)
    }

    // MARK: ダウンロード

    func adoptDownload(_ d: WKDownload, source: URL?) {
        store?.downloads.adopt(d, source: source ?? url)
    }

    /// VNet が自分で書き始めたダウンロードを一覧に入れる
    func registerVNetDownload(_ dl: VNetDownload) {
        let src = dl.source
        store?.downloads.register(dl) { [weak self] in self?.startDownload(src) }
    }

    /// URL をダウンロードする。VNet のタブは VNet で（WebKit の WKDownload は VNet の読み込みで落ちるため）、標準の通信は WebKit で
    func startDownload(_ u: URL) {
        let s = u.scheme?.lowercased() ?? ""
        if mode.usesVNet, s == "http" || s == "https", let scheme {
            scheme.startDownload(url: u, referer: url)
        } else if let wv = webView {
            wv.startDownload(using: URLRequest(url: u)) { [weak self] d in self?.adoptDownload(d, source: u) }
        }
    }

    // MARK: WebKit からの知らせ（TabWebDelegate から）

    func navigationEvent(_ s: String, level: LogLevel = .info) {
        log(s, level: level)
        navEvents.append((Date(), s))
        if navEvents.count > 200 { navEvents.removeFirst(navEvents.count - 200) }
    }

    /// 設定を変えたとき（すぐ効かせられるものだけ）
    func applySettings() {
        scheme?.httpsFirst = VelaSettings.httpsFirst
        if #available(iOS 16.4, *) { webView?.isInspectable = VelaSettings.webInspector }
    }

    func didFinish() {
        syncFromWebView()
        // 履歴に入れる（エラーページは入れない）
        if let u = url, u != errorPageURL, LibraryKey.isRecordable(u) {
            store?.recordVisit(url: u, title: title)
            lastRecorded = u
        }
        store?.saveSession()
    }

    func processTerminated() {
        log("⚠️ ページのプロセスが落ちました", level: .warning)
        if store?.selectedTab === self {
            webView?.reload()
        } else {
            state = .crashed
        }
    }

    func openInNewTab(_ u: URL, select: Bool) {
        store?.newTab(url: u, select: select, mode: mode, after: self)
    }

    func popup(configuration: WKWebViewConfiguration) -> WKWebView? {
        store?.adoptPopup(configuration: configuration, opener: self)
    }

    func closeByPage() {
        log("ページがタブを閉じました（window.close）")
        store?.close(self)
    }

    func presentDialog(_ kind: JSDialog.Kind, message: String, frame: WKFrameInfo, respond: @escaping (Bool, String?) -> Void) {
        let o = frame.securityOrigin
        let origin = "#\(id) \(o.host.isEmpty ? (url?.host ?? "") : o.host)"
        store?.presentDialog(JSDialog(kind: kind, message: message, origin: origin, respond: respond))
    }

    /// エラーページのボタン・守りのスクリプトからの知らせ
    private func handleAction(_ body: [String: Any], isMainFrame: Bool, origin: String) {
        switch body["action"] as? String {
        case "page":
            // エラーページ・確認のページ（メインフレーム）からの、合言葉の合っている知らせだけを受け付ける
            guard isMainFrame, let nonce = body["nonce"] as? String,
                  let item = scheme?.actions.consume(nonce) ?? pageActions.consume(nonce) else {
                log("🛡 ページのボタン: 受け付けない知らせです（\(origin)）", category: .security)
                return
            }
            pageAction(item)
        case "blockedWebSocket":
            log("🛡 LAN の保護: WebSocket を止めました（\(origin) → \(body["url"] as? String ?? "?")）", category: .security)
        case "usedWebSocket":
            if !nonVNetUsage.contains("WebSocket") {
                nonVNetUsage.insert("WebSocket")
                log("このページは WebSocket を使っています（VNet を通りません）", category: .net)
            }
        default:
            break
        }
    }
}

// MARK: - WebKit のデリゲート（タブ 1 枚に 1 つ）

@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
        super.init()
    }

    // リンクを押したとき: ダウンロードの指定（<a download>）・HTTPS-First（標準の通信）・vnets:// の作りの読み替え
    // Objective-C の名前を明示する（Playgrounds のプレビューは関数名を __preview_ に変えるので、2 つの async 版が同じ名前になってぶつかる）
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let tab else { return .allow }
        if navigationAction.shouldPerformDownload {
            // VNet のタブの http(s) は、WebKit のダウンロードにしない（落ちるため）。VNet で読んでファイルに書く
            if tab.mode.usesVNet, let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" {
                tab.startDownload(VNetURL.toReal(u) ?? u)
                return .cancel
            }
            return .download
        }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        if main, let u = navigationAction.request.url { tab.applyAdBlock(for: VNetURL.toReal(u) ?? u) }
        if main, let u = navigationAction.request.url, let up = tab.httpsFirstUpgrade(u) {
            webView.load(URLRequest(url: up))
            return .cancel
        }
        guard tab.mode == .vnetsLegacy else { return .allow }
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https",
           navigationAction.targetFrame?.isMainFrame ?? true, let v = VNetURL.toVNet(u) {
            webView.load(URLRequest(url: v))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.didStartNavigation()
        tab?.navigationEvent("読み込み開始: \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.didCommitNavigation()
    }

    /// 表示できない種類（zip・PDF の一部など）や「添付ファイル」の指定なら、ダウンロードにする
    @objc(webView:decidePolicyForNavigationResponse:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        var attachment = false
        if let http = navigationResponse.response as? HTTPURLResponse {
            // 204 No Content: 移動しない（VNet がダウンロードに変えたときにも返す。ここでダウンロードを始めると二重になる）
            if http.statusCode == 204 { return .cancel }
            let cd = http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "content-disposition" }?.value as? String
            if let cd, cd.lowercased().hasPrefix("attachment") { attachment = true }
        }
        guard attachment || !navigationResponse.canShowMIMEType else { return .allow }
        // VNet のタブ: WebKit のダウンロードにはしない（VNetScheme の読み込みを変えると落ちる）。止めて、VNet で読み直してファイルに書く
        if let tab, tab.mode.usesVNet, let u = navigationResponse.response.url {
            tab.startDownload(VNetURL.toReal(u) ?? u)
            return .cancel
        }
        return .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        tab?.adoptDownload(download, source: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        tab?.adoptDownload(download, source: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.navigationEvent("読み込み完了: \(webView.title ?? "")")
        tab?.didFinish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.navigationEvent("✕ 読み込みに失敗: \(error.localizedDescription)", level: .error)
        tab?.syncFromWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.navigationEvent("✕ 読み込みに失敗: \(error.localizedDescription)", level: .error)
        tab?.showLoadError(error)
        tab?.syncFromWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.processTerminated()
    }

    // MARK: WKUIDelegate

    /// target=_blank・window.open: 新しいタブにする
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        tab?.popup(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        tab?.closeByPage()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let tab else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            tab.presentDialog(.alert, message: message, frame: frame) { _, _ in c.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let tab else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            tab.presentDialog(.confirm, message: message, frame: frame) { ok, _ in c.resume(returning: ok) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let tab else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            tab.presentDialog(.prompt(defaultText ?? ""), message: prompt, frame: frame) { ok, text in c.resume(returning: ok ? (text ?? "") : nil) }
        }
    }

    /// リンクの長押しメニュー: 「新しいタブで開く」などを足す（WebKit の元のメニューも残す）
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL else { completionHandler(nil); return }
        let real = VNetURL.toReal(link) ?? link
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let open = UIAction(title: "新しいタブで開く", image: UIImage(systemName: "plus.square.on.square")) { _ in
                let d = self
                Task { @MainActor in d?.tab?.openInNewTab(real, select: true) }
            }
            let back = UIAction(title: "裏のタブで開く", image: UIImage(systemName: "square.on.square")) { _ in
                let d = self
                Task { @MainActor in d?.tab?.openInNewTab(real, select: false) }
            }
            let copy = UIAction(title: "リンクをコピー", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = real
            }
            return UIMenu(title: real.absoluteString, children: [open, back, copy] + suggested)
        }
        completionHandler(config)
    }
}

// ======================================================================
// MARK: - Library.swift
// ======================================================================

// MARK: - ブックマークと履歴の置き場（bookmarks.json・history.json）と、アドレス欄の入力の様子
//
// 中身の決まり（重ならない・上限・候補の順番）は LibraryModel.swift。ここは保存と画面への知らせだけ

@MainActor
final class Library: ObservableObject {
    @Published private(set) var bookmarks = BookmarkList()
    @Published private(set) var history = HistoryLog()
    var log: ((String) -> Void)?
    private let bookmarkFile = JSONFile<BookmarkList>(name: "bookmarks.json", delay: 0.5)
    /// 履歴はページを開くたびに変わるので、まとめて書く
    private let historyFile = JSONFile<HistoryLog>(name: "history.json", delay: 5)
    private var loaded = false

    /// BrowserStore の初期値として作られる（MainActor の外のことがある）ので、ここでは何もしない。読むのは load
    nonisolated init() {}

    func load(logs: DevLog) {
        if loaded { return }
        loaded = true
        log = { s in logs.add(s, level: .info, category: .app) }
        bookmarkFile.log = { s in logs.add(s) }
        historyFile.log = { s in logs.add(s) }
        bookmarks = bookmarkFile.load() ?? BookmarkList()
        history = historyFile.load() ?? HistoryLog()
        log?("ブックマーク \(bookmarks.items.count) 件・履歴 \(history.entries.count) 件を読みました")
    }

    func saveNow() {
        bookmarkFile.saveNow()
        historyFile.saveNow()
    }

    // MARK: ブックマーク

    func isBookmarked(_ u: URL?) -> Bool {
        guard let u else { return false }
        return bookmarks.contains(u.absoluteString)
    }

    /// 付いていなければ付ける、付いていれば外す。付けたら true
    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        let s = url.absoluteString
        if bookmarks.contains(s) {
            bookmarks.remove(url: s)
            log?("ブックマークを外しました: \(s)")
            bookmarkFile.save(bookmarks)
            return false
        }
        guard LibraryKey.isRecordable(url) else { return false }
        bookmarks.add(title: title, url: s)
        log?("ブックマークに入れました: \(s)")
        bookmarkFile.save(bookmarks)
        return true
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.remove(id: id)
        bookmarkFile.save(bookmarks)
    }

    func renameBookmark(_ id: UUID, title: String) {
        bookmarks.rename(id: id, title: title)
        bookmarkFile.save(bookmarks)
    }

    func moveBookmark(_ id: UUID, by delta: Int) {
        bookmarks.move(id: id, by: delta)
        bookmarkFile.save(bookmarks)
    }

    // MARK: 履歴

    func recordVisit(url: URL, title: String) {
        if history.record(url: url, title: title) { historyFile.save(history) }
    }

    func updateTitle(url: URL, title: String) {
        let before = history
        history.updateTitle(url: url, title: title)
        if history != before { historyFile.save(history) }
    }

    func removeHistory(_ url: String) {
        history.remove(url: url)
        historyFile.save(history)
    }

    /// since より後の履歴を消す（nil なら全部）
    func clearHistory(since: Date?) {
        history.clear(since: since)
        historyFile.saveNow(history)
        log?(since == nil ? "履歴を全部消しました" : "履歴を消しました（\(since!) から後）")
    }

    func suggestions(for text: String) -> [Suggestion] {
        Suggestions.rank(query: text, bookmarks: bookmarks.items, history: history.entries)
    }
}

/// アドレス欄の入力（打つたびに変わるので、BrowserStore とは分けて、見る所だけを描き直す）
@MainActor
final class AddressEditor: ObservableObject {
    @Published var text = ""
    @Published var editing = false
    /// 増やすとアドレス欄にフォーカスを当てる（⌘L）
    @Published private(set) var focusRequest = 0
    /// 増やすとアドレス欄から離れる（候補を選んだ・外を押した）
    @Published private(set) var blurRequest = 0

    nonisolated init() {}

    func focus() { focusRequest += 1 }
    func blur() { blurRequest += 1 }
}

// ======================================================================
// MARK: - LibraryModel.swift
// ======================================================================

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

// ======================================================================
// MARK: - AddressInput.swift
// ======================================================================

// MARK: - アドレス欄に入れた文字を、開く URL にする（URL か検索語かを決める）
//
// ・「://」がある・about: で始まる → そのまま URL
// ・空白がある → 検索
// ・ホスト名らしい（example.com・192.168.0.1・localhost・[::1]・ポートやパス付きも） → URL
//   LAN のアドレス（数字の LAN・localhost・.local）は http://、それ以外は https://
// ・それ以外 → 検索

enum SearchEngine: String, CaseIterable, Codable, Sendable {
    case google, duckDuckGo, bing, yahooJapan

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yahooJapan: return "Yahoo! JAPAN"
        }
    }

    func searchURL(_ query: String) -> URL? {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .duckDuckGo: c = URLComponents(string: "https://duckduckgo.com/")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yahooJapan: c = URLComponents(string: "https://search.yahoo.co.jp/search")!; c.queryItems = [URLQueryItem(name: "p", value: query)]
        }
        // URLComponents は「+」をそのまま残すので、検索語の「+」を %2B にする（空白と区別するため）
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }
}

enum AddressInput {
    enum Resolved: Equatable {
        case url(URL)
        case search(String, URL)
    }

    /// 入れた文字を開く URL にする。空なら nil
    static func resolve(_ raw: String, engine: SearchEngine) -> Resolved? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") { return URL(string: lower).map { .url($0) } }
        if text.contains("://"), let u = URL(string: text), u.scheme != nil, u.host != nil || lower.hasPrefix("file:") {
            return .url(u)
        }
        if text.rangeOfCharacter(from: .whitespaces) == nil, let u = hostLikeURL(text) { return .url(u) }
        return engine.searchURL(text).map { .search(text, $0) }
    }

    /// ホスト名らしいものなら URL にする
    static func hostLikeURL(_ text: String) -> URL? {
        // ホストの部分（最初の / ? # まで）
        let hostEnd = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        var hostPort = String(text[..<hostEnd])
        let rest = String(text[hostEnd...])
        if hostPort.isEmpty { return nil }
        var host = hostPort
        // ポート（[v6]:8080 と host:8080）
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if !after.isEmpty && !(after.hasPrefix(":") && after.dropFirst().allSatisfy({ $0.isNumber }) && after.count > 1) { return nil }
            guard IPAddressText.v6(host) != nil else { return nil }
        } else if let colon = hostPort.lastIndex(of: ":") {
            let port = hostPort[hostPort.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(port), p > 0, p < 65536 else { return nil }
            host = String(hostPort[..<colon])
        }
        host = host.lowercased()
        hostPort = hostPort.lowercased()
        let local: Bool
        if hostPort.hasPrefix("[") {
            local = LocalNetworkPolicy.classify(host: host)?.isLocal ?? false
        } else if IPAddressText.v4(host) != nil {
            local = LocalNetworkPolicy.classify(host: host)?.isLocal ?? false
        } else if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            local = true
        } else {
            guard looksLikeDomain(host) else { return nil }
            local = false
        }
        return URL(string: (local ? "http://" : "https://") + hostPort + rest)
    }

    /// ドメイン名らしいか（点で区切った各部分が英数字とハイフン、最後は英字 2 文字以上か xn--）
    static func looksLikeDomain(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard !l.isEmpty, l.count <= 63, !l.hasPrefix("-"), !l.hasSuffix("-"),
                  l.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        let tld = labels.last!
        return tld.hasPrefix("xn--") || (tld.count >= 2 && tld.allSatisfy { $0.isLetter })
    }

    /// アドレス欄を触っていないときに見せる短い形（ホスト名。www. は外す）
    static func shortDisplay(_ url: URL?) -> String {
        guard let u = url else { return "" }
        if u.scheme == "about" { return "" }
        guard let h = u.host, !h.isEmpty else { return u.absoluteString }
        return SiteUtil.stripWWW(h)
    }

    /// 検索の結果のページなら、その検索語（アドレス欄に戻すため）
    static func searchTerms(in url: URL?) -> String? {
        guard let u = url, let c = URLComponents(url: u, resolvingAgainstBaseURL: false), let host = u.host?.lowercased() else { return nil }
        let key: String
        if host.hasSuffix("google.com") && u.path == "/search" { key = "q" }
        else if host == "duckduckgo.com" { key = "q" }
        else if host.hasSuffix("bing.com") && u.path == "/search" { key = "q" }
        else if host == "search.yahoo.co.jp" { key = "p" }
        else { return nil }
        return c.queryItems?.first(where: { $0.name == key })?.value
    }
}

// ======================================================================
// MARK: - ErrorPages.swift
// ======================================================================

// MARK: - エラーページ・確認のページ
//
// ・読めなかったときに、原因の説明と、できること（再試行・標準の通信で開く など）のボタンを出す
// ・ボタンは window.webkit.messageHandlers.velaAction に {action: "page", nonce} を送る。
//   合言葉（nonce）は 1 回だけ・10 分まで使える。ページは失敗した URL のオリジンで出すので、元のページからは合言葉を読めない
//   （LAN の確認のように、押されると困るボタンもあるため。合言葉の無い知らせは受け付けない）

/// ページのボタンの合言葉 → してほしいこと（画面のスレッドでだけ使う）
final class PageActions {
    struct Item {
        let action: String
        let url: URL
        let at: Date
    }
    private var items: [String: Item] = [:]
    static let lifetime: TimeInterval = 600

    init() {}

    /// 合言葉を作る
    func make(_ action: String, url: URL, now: Date = Date()) -> String {
        items = items.filter { now.timeIntervalSince($0.value.at) < PageActions.lifetime }
        let n = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        items[n] = Item(action: action, url: url, at: now)
        return n
    }

    /// 合言葉を確かめて、してほしいことを返す（1 回だけ）
    func consume(_ nonce: String, now: Date = Date()) -> Item? {
        guard let i = items.removeValue(forKey: nonce), now.timeIntervalSince(i.at) < PageActions.lifetime else { return nil }
        return i
    }
}

enum ErrorPage {
    /// ページの中のボタン（label・合言葉）
    struct Button {
        let label: String
        let nonce: String
        let primary: Bool
    }

    /// 説明（見出し・ひとこと・標準の通信で開く案内を出すか）
    struct Description {
        let title: String
        let hint: String
        let offerNative: Bool
    }

    static func describe(_ e: FetchError) -> Description {
        switch e.kind {
        case .dns: return Description(title: "サーバーが見つかりません", hint: "アドレスが正しいか、ネットワークにつながっているかを確かめてください。", offerNative: true)
        case .timeout: return Description(title: "時間切れです", hint: "サーバーから返事がありません。しばらくしてから試してください。", offerNative: true)
        case .tls: return Description(title: "安全な接続を作れませんでした", hint: "証明書に問題があるか、VNet の TLS では話せない相手です。", offerNative: true)
        case .tlsVersion: return Description(title: "このサイトは VNet の TLS では開けません", hint: "相手が TLS 1.3 だけを使っています（VNet の TLS は 1.2 まで）。標準の通信なら開けます。", offerNative: true)
        case .connect: return Description(title: "サーバーにつながりません", hint: "サーバーが止まっているか、ネットワークに問題があります。", offerNative: true)
        case .reset: return Description(title: "接続が途中で切れました", hint: "もう一度試してください。", offerNative: true)
        case .malformed, .tooLarge: return Description(title: "サーバーの返事を読めません", hint: e.description, offerNative: true)
        case .redirect: return Description(title: "リダイレクトが多すぎます", hint: "サーバーの設定に問題があるかもしれません。", offerNative: false)
        case .busy: return Description(title: "要求が多すぎます", hint: "少し待ってから試してください。", offerNative: false)
        case .blocked: return Description(title: "Vela の守りで止めました", hint: e.description, offerNative: false)
        case .localNetworkConsent: return Description(title: "LAN の機器を開きますか？", hint: e.description, offerNative: false)
        case .notReady: return Description(title: "VNet の準備ができていません", hint: "少し待ってから試してください。", offerNative: true)
        case .cancelled: return Description(title: "取り消しました", hint: "", offerNative: false)
        case .other: return Description(title: "読めませんでした", hint: e.description, offerNative: true)
        }
    }

    /// 標準の通信（WebKit）の失敗の説明（NSURLErrorDomain の番号）
    static func describe(nsErrorCode code: Int, domain: String, message: String) -> Description {
        guard domain == NSURLErrorDomain else { return Description(title: "読めませんでした", hint: message, offerNative: false) }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return Description(title: "インターネットにつながっていません", hint: "Wi-Fi やモバイル通信を確かめてください。", offerNative: false)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return Description(title: "サーバーが見つかりません", hint: "アドレスが正しいかを確かめてください。", offerNative: false)
        case NSURLErrorTimedOut:
            return Description(title: "時間切れです", hint: "サーバーから返事がありません。", offerNative: false)
        case NSURLErrorCannotConnectToHost:
            return Description(title: "サーバーにつながりません", hint: message, offerNative: false)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return Description(title: "安全な接続を作れませんでした", hint: "証明書に問題があります。このサイトは開かないでください。", offerNative: false)
        default:
            return Description(title: "読めませんでした", hint: message, offerNative: false)
        }
    }

    /// エラーページの HTML（文字は全部エスケープする。暗い表示にも合わせる）
    static func html(title: String, lines: [String], detail: String? = nil, buttons: [Button], kind: String) -> String {
        var s = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(escape(title))</title><style>
        body{font:17px -apple-system,system-ui;margin:0;padding:48px 24px;color:#1c1c1e;background:#f2f2f7}
        @media (prefers-color-scheme:dark){body{color:#f2f2f7;background:#1c1c1e}.d{background:#2c2c2e}}
        main{max-width:620px;margin:0 auto}h1{font-size:24px;margin:0 0 16px}p{line-height:1.5;word-break:break-all}
        .u{color:#8e8e93;font-size:14px}.d{background:#e5e5ea;border-radius:8px;padding:8px 12px;font:12px ui-monospace,monospace;white-space:pre-wrap}
        button{font-size:16px;padding:10px 20px;margin:8px 8px 0 0;border-radius:10px;border:0;background:#d1d1d6;color:inherit}
        button.p{background:#0a84ff;color:#fff}
        </style></head><body><main>
        """
        s += "<h1>\(escape(title))</h1>"
        for l in lines where !l.isEmpty { s += "<p>\(escape(l))</p>" }
        if !buttons.isEmpty {
            s += "<div>"
            for b in buttons {
                let js = "window.webkit.messageHandlers.velaAction.postMessage({action:'page',nonce:'\(b.nonce)'})"
                s += "<button class=\"\(b.primary ? "p" : "")\" onclick=\"\(escape(js))\">\(escape(b.label))</button>"
            }
            s += "</div>"
        }
        if let d = detail, !d.isEmpty { s += "<details><summary class=\"u\">くわしく</summary><p class=\"d\">\(escape(d))</p></details>" }
        s += "</main></body></html><!-- vela-error:\(escape(kind)) -->"
        return s
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }
}

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

// ======================================================================
// MARK: - FilterLists.swift
// ======================================================================

// MARK: - 広告ブロックのリストの管理（ダウンロード・更新・WebKit のルールへのコンパイル・サイトごとの OFF）
//
// ・リストは Application Support/Vela/filters/<id>.txt に置く。状態（いつ更新したか・ルールの数・コンパイル済みの名前）は adblock.json
// ・ダウンロードは標準の通信（URLSession）で行う（VNet が動いていなくても更新できるように）
// ・起動するたびに、置いてあるリストを裏で読んで、BlockEngine（VNet のタブ用）と WebKit のルール（JSON）を作る。
//   WebKit のルールは中身の印（ハッシュ）を名前に入れてあるので、変わっていなければコンパイルし直さずに取り出せる
// ・自動更新は 4 日ごと（起動したとき）。手で「今すぐ更新」もできる

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
    /// コンパイル済みの WebKit のルールの名前
    var netID: String?
    var cosID: String?
}

struct AdBlockState: Codable {
    var lists: [FilterListInfo]
    var lastAutoUpdate: Date?
}

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
    static let catalog: [FilterListInfo] = [
        FilterListInfo(id: "easylist", name: "EasyList（広告）", url: "https://easylist.to/easylist/easylist.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy（トラッカー）", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "adguard-ja", name: "AdGuard Japanese（日本の広告）", url: "https://filters.adtidy.org/extension/ublock/filters/7.txt", enabled: true, builtIn: true),
    ]
    static let updateInterval: TimeInterval = 4 * 86_400
    nonisolated static let idPrefix = "vela-ab-"

    @Published private(set) var lists: [FilterListInfo] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "準備中…"
    @Published private(set) var enabled = true
    @Published private(set) var disabledSites = Set<String>()
    /// 起動してから止めた数（VNet のタブ）
    @Published private(set) var totalBlocked = 0
    let box = BlockEngineBox()
    /// リスト id → WebKit のルール
    private var netLists: [String: WKContentRuleList] = [:]
    private var cosLists: [String: WKContentRuleList] = [:]
    /// ルールが変わったとき（タブに入れ直す）
    var onRuleListsChanged: (@MainActor () -> Void)?
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
        var merged = saved?.lists ?? []
        for c in AdBlocker.catalog where !merged.contains(where: { $0.id == c.id }) { merged.append(c) }
        lists = merged
        let missing = lists.contains { $0.enabled && !FileManager.default.fileExists(atPath: AdBlocker.textURL($0.id).path) }
        let due = lastAutoUpdate.map { Date().timeIntervalSince($0) > AdBlocker.updateInterval } ?? true
        if missing || due {
            Task { await self.update(manual: false) }
        } else {
            Task { await self.rebuild() }
        }
    }

    // MARK: 設定

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "adblock.enabled")
        box.set(enabled: on, disabledSites: disabledSites)
        log(on ? "広告ブロックを使います" : "広告ブロックを止めました")
        onRuleListsChanged?()
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
        onRuleListsChanged?()
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
            if let text = result.text {
                do {
                    try Data(text.utf8).write(to: AdBlocker.textURL(l.id), options: .atomic)
                    lists[i].lastUpdated = Date()
                    lists[i].lastError = nil
                    log("✓ \(l.name): \(text.utf8.count / 1024)KB")
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

    nonisolated static func download(_ urlString: String) async -> Downloaded {
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
                guard head.contains("!") || head.contains("[Adblock") || head.contains("##") || head.contains("||") else {
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
        let ids = lists.filter { $0.enabled }.map { $0.id }
        let start = Date()
        let built: [Built] = await Task.detached(priority: .utility) {
            ids.compactMap { id -> Built? in
                guard let d = try? Data(contentsOf: AdBlocker.textURL(id)) else { return nil }
                let p = ABPParser.parse(String(decoding: d, as: UTF8.self))
                let net = ContentBlockerCompiler.networkJSON(p.network)
                let cos = ContentBlockerCompiler.cosmeticJSON(p.cosmetic)
                return Built(id: id, network: p.network, netJSON: net.json, cosJSON: cos.json, networkCount: p.network.count,
                             cosmeticCount: p.cosmetic.count, unsupported: p.unsupported, skipped: net.skipped + cos.skipped)
            }
        }.value
        let engine: BlockEngine = await Task.detached(priority: .utility) {
            BlockEngine(rules: built.flatMap { $0.network })
        }.value
        box.set(engine: engine)
        log("広告ブロック: VNet 用のルール \(engine.ruleCount) 個を作りました（\(Int(Date().timeIntervalSince(start) * 1000))ms）")

        var newNet: [String: WKContentRuleList] = [:], newCos: [String: WKContentRuleList] = [:]
        for (n, b) in built.enumerated() {
            status = "WebKit のルールを用意しています \(n + 1)/\(built.count)…"
            guard let i = lists.firstIndex(where: { $0.id == b.id }) else { continue }
            lists[i].networkRules = b.networkCount
            lists[i].cosmeticRules = b.cosmeticCount
            lists[i].unsupported = b.unsupported + b.skipped
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
        onRuleListsChanged?()
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
        stateFile.save(AdBlockState(lists: lists, lastAutoUpdate: lastAutoUpdate))
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
// 対応しないもの（数えて読み飛ばす）: /正規表現/、$redirect・$csp・$removeparam など、#?#・#$#・#%#（スクリプト・拡張の書き方）、
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
    var lines = 0
    var unsupported = 0
    /// リストの見出しの「! Title:」
    var title: String?
}

enum ABPParser {
    static func parse(_ text: String) -> ParsedFilterList {
        var out = ParsedFilterList()
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            out.lines += 1
            if line.hasPrefix("!") {
                if out.title == nil, line.hasPrefix("! Title:") { out.title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                return
            }
            if line.hasPrefix("[") { return }
            if let r = parseLine(line) {
                switch r {
                case .network(let n): out.network.append(n)
                case .cosmetic(let c): out.cosmetic.append(c)
                }
            } else {
                out.unsupported += 1
            }
        }
        return out
    }

    enum Rule { case network(NetworkRule), cosmetic(CosmeticRule) }

    /// 1 行を読む。対応しない書き方なら nil
    static func parseLine(_ line: String) -> Rule? {
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

// ======================================================================
// MARK: - BlockEngine.swift
// ======================================================================

// MARK: - 広告ブロックの判定（VNet のタブの通信を 1 つずつ調べる）
//
// ルールが何万もあるので、全部を毎回調べない。ルールごとに「必ず URL に入っている言葉」（英数字の並び）を 1 つ選んで索引にし、
// URL に入っている言葉の索引だけを調べる（言葉を選べないルールは毎回調べる）。
// 当てはめは正規表現を使わず、* と ^ だけの簡単な照らし合わせ（速い）。
// 作った後は変えないので、どのスレッドから使ってもよい

final class BlockEngine: @unchecked Sendable {
    struct Decision: Equatable {
        /// 当たったブロックのルール（元の行）
        let rule: String
    }

    private struct Compiled {
        let rule: NetworkRule
        let body: [UInt8]
    }

    private var blocks: [Compiled] = []
    private var exceptions: [Compiled] = []
    private var important: [Compiled] = []
    /// 言葉 → ルールの番号（種類ごと）
    private var blockIndex: [String: [Int]] = [:]
    private var exceptionIndex: [String: [Int]] = [:]
    private var importantIndex: [String: [Int]] = [:]
    private var blockGeneric: [Int] = []
    private var exceptionGeneric: [Int] = []
    private var importantGeneric: [Int] = []

    private(set) var ruleCount = 0

    init(rules: [NetworkRule] = []) {
        // 言葉は「ルールの中で一番珍しいもの」を選ぶ（"ads" などに何千ものルールが集まると、毎回たくさん調べることになる）
        let candidates = rules.map { BlockEngine.candidateTokens($0) }
        var freq: [String: Int] = [:]
        for c in candidates { for t in c { freq[t, default: 0] += 1 } }
        for (r, c) in zip(rules, candidates) {
            let token = c.min { a, b in
                let fa = freq[a] ?? 0, fb = freq[b] ?? 0
                return fa != fb ? fa < fb : a.count > b.count
            }
            add(r, token: token)
        }
    }

    /// 調べたときの数（開発者向け）: (言葉の種類, 言葉を選べなかったルール)
    var indexStats: (tokens: Int, generic: Int) {
        (blockIndex.count + exceptionIndex.count + importantIndex.count, blockGeneric.count + exceptionGeneric.count + importantGeneric.count)
    }

    static let empty = BlockEngine()

    private func add(_ r: NetworkRule, token: String?) {
        // document だけのルール（ページそのものを止める）は VNet では使わない（ページ本体は止めない）
        if let t = r.types, t == [.document] { return }
        let c = Compiled(rule: r, body: Array(r.body.utf8))
        if r.isException {
            exceptions.append(c)
            BlockEngine.insert(token, exceptions.count - 1, &exceptionIndex, &exceptionGeneric)
        } else if r.important {
            important.append(c)
            BlockEngine.insert(token, important.count - 1, &importantIndex, &importantGeneric)
        } else {
            blocks.append(c)
            BlockEngine.insert(token, blocks.count - 1, &blockIndex, &blockGeneric)
        }
        ruleCount += 1
    }

    private static func insert(_ token: String?, _ i: Int, _ index: inout [String: [Int]], _ generic: inout [Int]) {
        if let token { index[token, default: []].append(i) } else { generic.append(i) }
    }

    /// 言葉として使わないもの（ほとんどの URL に入っている）
    private static let commonTokens: Set<String> = ["http", "https", "www", "com", "net", "org", "html", "js", "jpg", "png", "gif"]

    /// 必ず URL に丸ごと入っている英数字の並びのうち、一番長いもの
    static func bestToken(_ r: NetworkRule) -> String? {
        candidateTokens(r).max { $0.count < $1.count }
    }

    /// 必ず URL に丸ごと入っている英数字の並び（索引に使えるもの）
    static func candidateTokens(_ r: NetworkRule) -> [String] {
        let b = Array(r.body.lowercased().utf8)
        var out: [String] = []
        var i = 0
        while i < b.count {
            guard isAlnum(b[i]) else { i += 1; continue }
            var j = i
            while j < b.count && isAlnum(b[j]) { j += 1 }
            // 前後が「*」や本体の端（印の無い端）だと、URL の中ではもっと長い並びの一部かもしれない
            let leftOK = i > 0 ? b[i - 1] != UInt8(ascii: "*") : (r.hostAnchor || r.startAnchor)
            let rightOK = j < b.count ? b[j] != UInt8(ascii: "*") : r.endAnchor
            if leftOK && rightOK && j - i >= 2 {
                let t = String(decoding: b[i..<j], as: UTF8.self)
                if !commonTokens.contains(t) { out.append(t) }
            }
            i = j
        }
        return out
    }

    @inline(__always) static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    /// 「^」に当たる文字（英数字と _ - . % 以外）
    @inline(__always) static func isSeparator(_ c: UInt8) -> Bool {
        !(isAlnum(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "%"))
    }

    /// 調べる。止めるなら、当たったルール
    /// - types: 読み込みの種類（はっきりしないときは、ありそうなもの全部）
    /// - sourceHost: その読み込みをしたページのホスト（domain= と third-party の判定）
    func match(url: URL, types: Set<ResourceType>, sourceHost: String?) -> Decision? {
        let s = url.absoluteString
        let lower = Array(s.lowercased().utf8)
        let original = Array(s.utf8)
        guard let hostRange = BlockEngine.hostRange(lower) else { return nil }
        let host = String(decoding: lower[hostRange], as: UTF8.self)
        let thirdParty: Bool? = sourceHost.map { SiteUtil.registrableDomain($0.lowercased()) != SiteUtil.registrableDomain(host) }
        let tokens = BlockEngine.tokens(lower)
        let req = Request(lower: lower, original: original, host: hostRange, types: types,
                          source: sourceHost?.lowercased(), thirdParty: thirdParty)
        if let i = find(important, importantIndex, importantGeneric, tokens, req) { return Decision(rule: important[i].rule.text) }
        guard let i = find(blocks, blockIndex, blockGeneric, tokens, req) else { return nil }
        if find(exceptions, exceptionIndex, exceptionGeneric, tokens, req) != nil { return nil }
        return Decision(rule: blocks[i].rule.text)
    }

    private struct Request {
        let lower: [UInt8]
        let original: [UInt8]
        let host: Range<Int>
        let types: Set<ResourceType>
        let source: String?
        let thirdParty: Bool?
    }

    private func find(_ list: [Compiled], _ index: [String: [Int]], _ generic: [Int], _ tokens: [String], _ req: Request) -> Int? {
        for t in tokens {
            if let ids = index[t] { for i in ids where BlockEngine.matches(list[i], req) { return i } }
        }
        for i in generic where BlockEngine.matches(list[i], req) { return i }
        return nil
    }

    private static func matches(_ c: Compiled, _ req: Request) -> Bool {
        let r = c.rule
        if let t = r.types, t.isDisjoint(with: req.types) { return false }
        if let tp = r.thirdParty {
            guard let actual = req.thirdParty, actual == tp else { return false }
        }
        if !r.includeDomains.isEmpty || !r.excludeDomains.isEmpty {
            guard let src = req.source else { return false }
            if r.excludeDomains.contains(where: { domainMatches(src, $0) }) { return false }
            if !r.includeDomains.isEmpty && !r.includeDomains.contains(where: { domainMatches(src, $0) }) { return false }
        }
        if c.body.isEmpty { return true }
        return patternMatches(c.body, in: r.matchCase ? req.original : req.lower, host: req.host,
                              hostAnchor: r.hostAnchor, startAnchor: r.startAnchor, endAnchor: r.endAnchor)
    }

    static func domainMatches(_ host: String, _ d: String) -> Bool {
        SiteUtil.hostMatches(host, domain: d)
    }

    /// URL のホストの位置（"scheme://" の後から、/ ? # : の前まで）
    static func hostRange(_ u: [UInt8]) -> Range<Int>? {
        var i = 0
        while i + 2 < u.count, !(u[i] == UInt8(ascii: ":") && u[i + 1] == UInt8(ascii: "/") && u[i + 2] == UInt8(ascii: "/")) { i += 1 }
        guard i + 2 < u.count else { return nil }
        let start = i + 3
        var end = start
        while end < u.count, ![UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: ":")].contains(u[end]) { end += 1 }
        return start < end ? start..<end : nil
    }

    static func tokens(_ u: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < u.count {
            guard isAlnum(u[i]) else { i += 1; continue }
            var j = i
            while j < u.count && isAlnum(u[j]) { j += 1 }
            if j - i >= 2 { out.append(String(decoding: u[i..<j], as: UTF8.self)) }
            i = j
        }
        return out
    }

    /// * と ^ の入った本体を、URL に当てはめる
    static func patternMatches(_ p: [UInt8], in u: [UInt8], host: Range<Int>, hostAnchor: Bool, startAnchor: Bool, endAnchor: Bool) -> Bool {
        // 「*」で区切る
        var segments: [ArraySlice<UInt8>] = []
        var s = 0
        for (i, c) in p.enumerated() where c == UInt8(ascii: "*") {
            if i > s { segments.append(p[s..<i]) }
            s = i + 1
        }
        if s < p.count { segments.append(p[s..<p.count]) }
        if segments.isEmpty { return true }

        func matchAt(_ seg: ArraySlice<UInt8>, _ pos: Int) -> Int? {
            var k = pos
            for c in seg {
                if c == UInt8(ascii: "^") {
                    if k == u.count { continue }       // 終わりにも当たる
                    if !isSeparator(u[k]) { return nil }
                } else {
                    if k >= u.count || u[k] != c { return nil }
                }
                k += 1
            }
            return min(k, u.count)
        }
        func search(_ seg: ArraySlice<UInt8>, from: Int) -> (Int, Int)? {
            var i = from
            while i <= u.count {
                if let e = matchAt(seg, i) { return (i, e) }
                i += 1
            }
            return nil
        }
        func rest(_ from: Int, _ idx: Int) -> Bool {
            var pos = from
            for k in idx..<segments.count {
                if k == segments.count - 1 && endAnchor {
                    // 最後の区切りは URL の終わりで終わらなければならない
                    var i = pos
                    while i <= u.count {
                        if let e = matchAt(segments[k], i), e == u.count { return true }
                        i += 1
                    }
                    return false
                }
                guard let (_, e) = search(segments[k], from: pos) else { return false }
                pos = e
            }
            return true
        }

        var starts: [Int] = []
        if hostAnchor {
            // ホストの始め、またはホストの中の「.」の後
            starts.append(host.lowerBound)
            for i in host where u[i] == UInt8(ascii: ".") { starts.append(i + 1) }
        } else if startAnchor {
            starts.append(0)
        } else {
            if segments.count == 1 && !endAnchor { return search(segments[0], from: 0) != nil }
            // 最初の区切りが当たる所を順に試す
            var i = 0
            while let (st, e) = search(segments[0], from: i) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
                i = st + 1
            }
            return false
        }
        for st in starts {
            if let e = matchAt(segments[0], st) {
                if segments.count == 1 { if !endAnchor || e == u.count { return true } }
                else if rest(e, 1) { return true }
            }
        }
        return false
    }

    /// VNet が受けた要求の種類を当てる（WebKit は種類を教えてくれないので、Accept と拡張子から）
    static func guessTypes(url: URL, accept: String?, isTopLevel: Bool) -> Set<ResourceType> {
        if isTopLevel { return [.document] }
        let a = (accept ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        if a.hasPrefix("text/html") || a.hasPrefix("application/xhtml") { return [.subdocument] }
        if a.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico", "bmp"].contains(ext) { return [.image] }
        if a.hasPrefix("text/css") || ext == "css" { return [.stylesheet] }
        if ["woff", "woff2", "ttf", "otf", "eot"].contains(ext) || a.hasPrefix("font/") { return [.font] }
        if ["mp4", "webm", "m3u8", "ts", "mp3", "m4a", "aac", "ogg", "mov"].contains(ext) || a.hasPrefix("video/") || a.hasPrefix("audio/") { return [.media] }
        if ext == "js" || ext == "mjs" { return [.script] }
        // 分からない: スクリプトか、fetch / XHR か、その他
        return [.script, .xhr, .other, .ping]
    }
}

// ======================================================================
// MARK: - ContentBlocker.swift
// ======================================================================

// MARK: - 広告ブロックのルールを WebKit のルール（WKContentRuleList の JSON）にする
//
// ・通信のルール（標準の通信のタブで使う。VNet のタブは BlockEngine が自分で調べて数える）と、
//   隠すルール（どちらのタブでも使う）を、別々の JSON にする
// ・WebKit の例外（ignore-previous-rules）は、同じリストの前にあるルールだけを打ち消す。なので
//   並びは「ブロック → 例外 → important のブロック」
// ・WebKit の url-filter は正規表現の一部（| や {n} が使えない・ASCII だけ）。^ は「区切りの文字」に置き換える
// ・1 つのリストは maxRules まで（WebKit の上限は 15 万）

enum ContentBlockerCompiler {
    static let maxRules = 140_000
    /// 1 つの css-display-none にまとめるセレクタの数
    static let selectorsPerRule = 200

    struct Output {
        var json: String
        var count: Int
        var skipped: Int
    }

    // MARK: 通信のルール

    static func networkJSON(_ rules: [NetworkRule]) -> Output {
        var blocks: [String] = [], exceptions: [String] = [], important: [String] = []
        var skipped = 0
        for r in rules {
            guard let obj = networkRule(r) else { skipped += 1; continue }
            if r.isException { exceptions.append(obj) } else if r.important { important.append(obj) } else { blocks.append(obj) }
        }
        var all = blocks + exceptions + important
        if all.count > maxRules {
            skipped += all.count - maxRules
            // 例外と important は残して、普通のブロックを減らす
            all = Array(blocks.prefix(max(0, maxRules - exceptions.count - important.count))) + exceptions + important
        }
        return Output(json: "[" + all.joined(separator: ",") + "]", count: all.count, skipped: skipped)
    }

    static func networkRule(_ r: NetworkRule) -> String? {
        guard let filter = urlFilter(r) else { return nil }
        var trigger = "\"url-filter\":\(quote(filter))"
        if r.matchCase { trigger += ",\"url-filter-is-case-sensitive\":true" }
        // WebKit のサイトの指定は ASCII だけ（日本語のドメインはリスト全体のエラーになる）
        let inc = r.includeDomains.filter(isASCIIDomain), exc = r.excludeDomains.filter(isASCIIDomain)
        if !r.includeDomains.isEmpty && inc.isEmpty { return nil }
        if !inc.isEmpty {
            trigger += ",\"if-domain\":" + list(inc.map { "*" + $0 })
        } else if !exc.isEmpty {
            trigger += ",\"unless-domain\":" + list(exc.map { "*" + $0 })
        }
        if let tp = r.thirdParty { trigger += ",\"load-type\":[\"\(tp ? "third-party" : "first-party")\"]" }
        // 種類の指定が無いルールも、ページそのもの（document）は止めない（記事の URL に「/ads/」が入っていても開けるように）
        let types = r.types ?? Set(ResourceType.allCases).subtracting([.document, .subdocument])
        let wk = Set(types.map(webKitType)).sorted()
        trigger += ",\"resource-type\":" + list(wk)
        let action = r.isException ? "ignore-previous-rules" : "block"
        return "{\"trigger\":{\(trigger)},\"action\":{\"type\":\"\(action)\"}}"
    }

    static func isASCIIDomain(_ d: String) -> Bool {
        !d.isEmpty && d.unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "." || $0 == "-" }
    }

    static func webKitType(_ t: ResourceType) -> String {
        switch t {
        case .document, .subdocument: return "document"
        case .script: return "script"
        case .image: return "image"
        case .stylesheet: return "style-sheet"
        case .font: return "font"
        case .media: return "media"
        case .xhr, .websocket, .ping, .other: return "raw"
        }
    }

    /// ABP の本体を、WebKit の url-filter（正規表現の一部）にする
    static func urlFilter(_ r: NetworkRule) -> String? {
        var out = ""
        if r.hostAnchor { out = "^[a-z][a-z0-9.+-]*://([^/?#]*\\.)?" }
        else if r.startAnchor { out = "^" }
        for ch in r.body.unicodeScalars {
            guard ch.isASCII else { return nil }
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-zA-Z0-9_.%-]"
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(ch)
            default: out.unicodeScalars.append(ch)
            }
        }
        if r.endAnchor { out += "$" }
        if out.isEmpty { out = ".*" }
        return out
    }

    // MARK: 隠すルール

    static func cosmeticJSON(_ rules: [CosmeticRule]) -> Output {
        // 全部のサイトに効く例外（#@#.ad）はセレクタごと外す。サイトを指定した例外は、そのサイトを unless-domain にする
        var removed = Set<String>()
        var exceptDomains: [String: [String]] = [:]
        let rules = rules.compactMap { r -> CosmeticRule? in
            var c = r
            c.includeDomains = r.includeDomains.filter(isASCIIDomain)
            c.excludeDomains = r.excludeDomains.filter(isASCIIDomain)
            return (!r.includeDomains.isEmpty && c.includeDomains.isEmpty) ? nil : c
        }
        for r in rules where r.isException {
            if r.includeDomains.isEmpty { removed.insert(r.selector) }
            else { exceptDomains[r.selector, default: []] += r.includeDomains }
        }
        var generic: [String] = []
        var genericWithExceptions: [String: [String]] = [:]
        var specific: [String: [String]] = [:]      // サイトの組 → セレクタ
        var seen = Set<String>()
        for r in rules where !r.isException && !removed.contains(r.selector) {
            if r.includeDomains.isEmpty {
                guard seen.insert(r.selector).inserted else { continue }
                let unless = r.excludeDomains + (exceptDomains[r.selector] ?? [])
                if unless.isEmpty { generic.append(r.selector) } else { genericWithExceptions[r.selector] = unless }
            } else {
                let key = r.includeDomains.sorted().joined(separator: ",")
                specific[key, default: []].append(r.selector)
            }
        }
        var out: [String] = []
        var i = 0
        while i < generic.count {
            let chunk = generic[i..<min(i + selectorsPerRule, generic.count)]
            out.append(hideRule(Array(chunk), ifDomains: nil, unlessDomains: nil))
            i += selectorsPerRule
        }
        for (sel, unless) in genericWithExceptions.sorted(by: { $0.key < $1.key }) {
            out.append(hideRule([sel], ifDomains: nil, unlessDomains: unless))
        }
        for (key, sels) in specific.sorted(by: { $0.key < $1.key }) {
            let domains = key.split(separator: ",").map(String.init)
            var j = 0
            while j < sels.count {
                out.append(hideRule(Array(sels[j..<min(j + selectorsPerRule, sels.count)]), ifDomains: domains, unlessDomains: nil))
                j += selectorsPerRule
            }
        }
        var skipped = 0
        if out.count > maxRules { skipped = out.count - maxRules; out = Array(out.prefix(maxRules)) }
        return Output(json: "[" + out.joined(separator: ",") + "]", count: out.count, skipped: skipped)
    }

    static func hideRule(_ selectors: [String], ifDomains: [String]?, unlessDomains: [String]?) -> String {
        var trigger = "\"url-filter\":\".*\""
        if let d = ifDomains { trigger += ",\"if-domain\":" + list(d.map { "*" + $0 }) }
        else if let d = unlessDomains { trigger += ",\"unless-domain\":" + list(d.map { "*" + $0 }) }
        return "{\"trigger\":{\(trigger)},\"action\":{\"type\":\"css-display-none\",\"selector\":\(quote(selectors.joined(separator: ", ")))}}"
    }

    // MARK: JSON の文字

    static func quote(_ s: String) -> String {
        var o = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) } else { o.unicodeScalars.append(ch) }
            }
        }
        return o + "\""
    }

    static func list(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ",") + "]" }

    /// ルールの中身から作る、変わったかどうかの印（FNV-1a 64 bit。コンパイル済みのリストの名前に使う）
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// ======================================================================
// MARK: - Persistence.swift
// ======================================================================

// MARK: - データのファイル（Application Support/Vela/ の JSON）
//
// タブ・ブックマーク・履歴などを Codable の JSON で置く。書き込みはまとめて（delay 秒後に 1 回）、裏のキューで、
// いったん別の名前に書いてから置き換える（.atomic。書いている途中で落ちても前のものが残る）

enum AppPaths {
    /// Application Support/Vela（取れなければ一時フォルダの Vela）。フォルダは作らない（作るのは使う側）
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
    }
}

final class JSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    /// 読み書きの失敗（開発者向けのログに出す）
    var log: (@Sendable (String) -> Void)?

    /// name: ファイルの名前（例: "tabs.json"）。directory を省くと Application Support/Vela/
    init(name: String, directory: URL? = nil, delay: TimeInterval = 1.0) {
        let dir = directory ?? JSONFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.delay = delay
        queue = DispatchQueue(label: "vela-json-\(name)")
    }

    static func defaultDirectory() -> URL { AppPaths.support }

    /// 読む（無い・壊れているなら nil。壊れていたファイルは .broken に名前を変えて残す）
    func load() -> Value? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: d)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を読めません（\(error)）。.broken として残します")
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return nil
        }
    }

    /// 保存する（delay 秒の間に何度呼んでも、書くのは最後の 1 回）
    func save(_ v: Value) {
        lock.lock()
        pending = v
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// 待っている分をすぐ書く（アプリが裏に回るときなど）。書き終わるまで待つ
    func saveNow(_ v: Value? = nil) {
        if let v { lock.lock(); pending = v; lock.unlock() }
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let v = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let v else { return }
        do {
            let d = try JSONEncoder().encode(v)
            try d.write(to: url, options: .atomic)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を書けません（\(error)）")
        }
    }
}

// MARK: - 設定（UserDefaults に置く）
//
// 通信まわりの設定は、アプリを起動し直したときに効く（WebView や通信の作りを、起動のときに決めるため）

enum VelaSettings {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: 通信（VNet）

    /// VNet を使わず、標準の通信（WebKit 内蔵）だけで読む
    static var vnetDisabled: Bool {
        get { bool("vnet.disabled", false) } set { d.set(newValue, forKey: "vnet.disabled") }
    }
    /// 確かめていない iOS の版でも、https の横取り（非公開 API）を試す
    static var allowUntestedOS: Bool {
        get { bool("vnet.allowUntestedOS", false) } set { d.set(newValue, forKey: "vnet.allowUntestedOS") }
    }
    /// 開発者向け: 横取りできないとき、標準の通信ではなく予備の vnets:// の作りを使う（安全ではない。CSP などを外すため）
    static var legacyVNetsFallback: Bool {
        get { bool("vnet.legacyVNets", false) } set { d.set(newValue, forKey: "vnet.legacyVNets") }
    }

    // MARK: 使い勝手

    /// 検索エンジン
    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "search.engine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "search.engine") }
    }
    /// HTTPS-First: ページを開く http:// を、まず https で試す（だめなら「http のまま開く」を出す）
    static var httpsFirst: Bool {
        get { bool("nav.httpsFirst", true) } set { d.set(newValue, forKey: "nav.httpsFirst") }
    }
    /// VNet でページを読めなかったら（TLS・つながらない など）、標準の通信に自動で切り替える
    static var autoFallbackToNative: Bool {
        get { bool("vnet.autoFallback", false) } set { d.set(newValue, forKey: "vnet.autoFallback") }
    }
    /// Mac の Safari の Web インスペクタからつなげるようにする（iOS 16.4 から）
    static var webInspector: Bool {
        get { bool("dev.webInspector", false) } set { d.set(newValue, forKey: "dev.webInspector") }
    }

    /// サイト（ホスト）ごとの文字の大きさ（100% のものは持たない）
    static func zoom(for host: String?) -> Double {
        guard let h = host?.lowercased(), let z = (d.dictionary(forKey: "zoom.sites") as? [String: Double])?[h] else { return 1.0 }
        return z
    }
    static func setZoom(_ z: Double, for host: String?) {
        guard let h = host?.lowercased(), !h.isEmpty else { return }
        var m = (d.dictionary(forKey: "zoom.sites") as? [String: Double]) ?? [:]
        m[h] = abs(z - 1.0) < 0.001 ? nil : z
        if m.count > 500 { m = [h: z] }      // 増えすぎたら覚え直す（めったに起きない）
        d.set(m, forKey: "zoom.sites")
    }

    // MARK: プライバシー・守り

    /// サードパーティ Cookie をブロックする
    static var blockThirdPartyCookies: Bool {
        get { bool("cookies.blockThirdParty", true) } set { d.set(newValue, forKey: "cookies.blockThirdParty") }
    }
    /// SameSite が無い Cookie を Lax として扱う
    static var cookiesLaxByDefault: Bool {
        get { bool("cookies.laxByDefault", true) } set { d.set(newValue, forKey: "cookies.laxByDefault") }
    }
    /// LAN の保護（公開のサイトから LAN の機器へ届かせない）
    static var localNetworkProtection: Bool {
        get { bool("lan.protection", true) } set { d.set(newValue, forKey: "lan.protection") }
    }

    /// 今の設定から作る Cookie の決まり
    static var cookiePolicy: CookiePolicy.Settings {
        var s = CookiePolicy.Settings()
        s.blockThirdParty = blockThirdPartyCookies
        s.laxByDefault = cookiesLaxByDefault
        return s
    }
}

// ======================================================================
// MARK: - DevLog.swift
// ======================================================================

// MARK: - 開発者向けのログ（どのスレッドからでも書ける）
//
// 1 行ずつ「時刻・重さ・種類・タブ・本文」を持って、最新 maxEntries 件まで覚える（古いものから消す）。
// 今までの log?("…") の文字列も、そのまま add で入れられる（先頭の記号から種類と重さを決める）。
// 画面へは、必要なときに entries(after:) で差分だけ取り出す（毎回全部を作り直すと重い）

enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug, info, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var mark: String {
        switch self { case .debug: return "·"; case .info: return " "; case .warning: return "⚠"; case .error: return "✕" }
    }
}

enum LogCategory: String, Sendable, CaseIterable {
    case app = "アプリ"
    case vnet = "VNet"
    case net = "通信"
    case nav = "移動"
    case cookie = "Cookie"
    case security = "守り"
    case block = "ブロック"
    case download = "ダウンロード"
    case js = "JS"
}

struct LogEntry: Sendable, Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let category: LogCategory
    /// どのタブのものか（タブに関係ないものは nil）
    let tab: Int?
    let message: String

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var line: String {
        "\(LogEntry.timeFormat.string(from: time)) \(level.mark) [\(category.rawValue)\(tab.map { "#\($0)" } ?? "")] \(message)"
    }
}

final class DevLog: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var start = 0           // ring の中で一番古いものの位置（いっぱいになってから使う）
    private var nextID = 1
    private var dirty = false
    /// ログを書いた回数（重さごと。開発者パネル用）
    private var counts: [LogLevel: Int] = [:]

    init() {}

    /// 今までの文字列のログ。先頭の記号などから種類と重さを決める
    func add(_ message: String, tab: Int? = nil) {
        let (level, category) = DevLog.classify(message)
        add(message, level: level, category: category, tab: tab)
    }

    func add(_ message: String, level: LogLevel, category: LogCategory, tab: Int? = nil) {
        lock.lock()
        let e = LogEntry(id: nextID, time: Date(), level: level, category: category, tab: tab, message: message)
        nextID += 1
        if ring.count < DevLog.maxEntries {
            ring.append(e)
        } else {
            ring[start] = e
            start = (start + 1) % DevLog.maxEntries
        }
        counts[level, default: 0] += 1
        dirty = true
        lock.unlock()
        // 落ちたときのために、すぐファイルにも書く（CrashLog.start の前は何もしない）
        CrashLog.writeLine(e.line)
    }

    /// 古い順に全部
    func all() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[start...] + ring[..<start])
    }

    /// id より新しいもの（古い順）。画面は最後に見た id を覚えておいて、差分だけもらう
    func entries(after id: Int) -> [LogEntry] {
        all().filter { $0.id > id }
    }

    func count(_ level: LogLevel) -> Int { lock.lock(); defer { lock.unlock() }; return counts[level] ?? 0 }

    /// 変わっていれば、最新 lines 行を 1 つの文字列にして返す（今の簡易のログ表示用）
    func take(lines: Int = 200) -> String? {
        lock.lock()
        if !dirty { lock.unlock(); return nil }
        dirty = false
        lock.unlock()
        return all().suffix(lines).map { $0.message }.joined(separator: "\n")
    }

    /// 書き出し用（共有・コピー）
    func export(minLevel: LogLevel = .debug) -> String {
        all().filter { $0.level >= minLevel }.map { $0.line }.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); ring = []; start = 0; dirty = true; lock.unlock()
    }

    /// 文字列から種類と重さを決める（今までのログの書き方に合わせる）
    static func classify(_ m: String) -> (LogLevel, LogCategory) {
        let level: LogLevel = m.hasPrefix("✕") || m.contains("失敗") ? .error
            : m.hasPrefix("⚠") ? .warning : .info
        let category: LogCategory
        if m.hasPrefix("🍪") { category = .cookie }
        else if m.hasPrefix("🚫") { category = .block }
        else if m.hasPrefix("🛡") || m.hasPrefix("🔒") || m.contains("HSTS") || m.contains("横取り") { category = .security }
        else if m.hasPrefix("✓") || m.hasPrefix("✕") || m.hasPrefix("↪") || m.hasPrefix("――") { category = .net }
        else if m.hasPrefix("→") || m.hasPrefix("←") || m.contains("TLS") || m.contains("DHCP") || m.contains("カード")
                    || m.contains("[ネット]") || m.contains("TCP") { category = .vnet }
        else { category = .app }
        return (level, category)
    }
}

// ======================================================================
// MARK: - CrashLog.swift
// ======================================================================

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 落ちたときの記録（次に起動したときに、開発者パネルで見る）
//
// ・ログを 1 行ずつ、すぐファイルに書く（落ちる直前まで残るように。メモリのログは落ちると消える）
// ・Objective-C の例外（WebKit などが投げる）は、名前・理由・呼び出しの順をファイルに書く
// ・致命的なシグナル（Swift の強制終了・不正なメモリアクセスなど）は、番号・落ちたスレッド・呼び出しの順を書く
//   （シグナルの中ではほとんど何もできないので、用意しておいた文字と backtrace_symbols_fd で、ファイルに直接書くだけ）
// ・起動するたびに、前回の記録を crash-previous.txt に移す。前回が落ちて終わっていたら、ログに知らせる

/// シグナルの中から使うので、ファイルの番号は global に置く（Swift の static は初めて触るときに準備が走るので、シグナルの中では使わない）
private var crashFD: Int32 = -1
private let signalMessages: [Int32: [UInt8]] = {
    var m: [Int32: [UInt8]] = [:]
    for (s, name) in [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")] {
        m[s] = Array("\n【シグナル】\(name)（\(s)）でアプリが止まりました\n".utf8)
    }
    return m
}()
/// 呼び出しの順を入れる場所（シグナルの中では作れないので、先に用意する）
private let backtraceCapacity: Int32 = 64
private let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private let mainThreadText = Array("落ちたスレッド: 画面のスレッド（main）\n呼び出しの順:\n".utf8)
private let otherThreadText = Array("落ちたスレッド: 裏のスレッド（main 以外）\n呼び出しの順:\n".utf8)

// backtrace・backtrace_symbols_fd（C の execinfo.h）。iPad の Swift Playgrounds では Darwin から見えなかった
// （「cannot find 'backtrace' in scope」）ので、C の関数の名前で直接つなぐ。iOS・Linux の libc のどちらにもある
@_silgen_name("backtrace")
private func cBacktrace(_ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd")
private func cBacktraceSymbolsFD(_ buffer: UnsafePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)

/// 致命的なシグナルの受け口。シグナルの中なので、用意しておいたものを write で書くだけにする
private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        if let m = signalMessages[sig] { _ = m.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) } }
        #if canImport(Darwin)
        let isMain = pthread_main_np() != 0
        #else
        let isMain = false
        #endif
        let t = isMain ? mainThreadText : otherThreadText
        _ = t.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        let n = cBacktrace(backtraceBuffer, backtraceCapacity)
        cBacktraceSymbolsFD(backtraceBuffer, n, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashLog {
    private static let lock = NSLock()
    private static var written = 0
    static let maxBytes = 2 << 20
    static let exceptionMark = "【例外】"
    static let signalMark = "【シグナル】"

    static var folder: URL {
        let dir = AppPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var currentURL: URL { folder.appendingPathComponent("crash-current.txt") }
    static var previousURL: URL { folder.appendingPathComponent("crash-previous.txt") }

    /// 起動したときに 1 回。前回の記録を移して、新しいファイルを開き、例外とシグナルの受け口を入れる
    static func start() {
        lock.lock(); defer { lock.unlock() }
        if crashFD >= 0 { return }
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        if fm.fileExists(atPath: currentURL.path) { try? fm.moveItem(at: currentURL, to: previousURL) }
        crashFD = open(currentURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = (signalMessages, mainThreadText, otherThreadText, backtraceBuffer)     // シグナルの中で準備が走らないよう、先に作っておく
        #if canImport(Darwin)
        NSSetUncaughtExceptionHandler { e in CrashLog.recordException(e) }
        #endif
        _ = cBacktrace(backtraceBuffer, 1)     // 初めて呼ぶときの準備を、シグナルの中ではなくここで済ませておく
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(s, crashSignalHandler)
        }
        // ここはもう lock を持っているので、writeLine ではなく writeLineLocked（NSLock は 2 回取ると止まる）
        writeLineLocked("―― 起動 \(Date()) ――")
    }

    /// 1 行書く（DevLog から全部の行が来る）
    static func writeLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        writeLineLocked(s)
    }

    /// lock を持っているときに呼ぶ
    private static func writeLineLocked(_ s: String) {
        guard crashFD >= 0 else { return }
        let bytes = Array((s + "\n").utf8)
        if written + bytes.count > maxBytes {
            // 大きくなりすぎたら最初から（落ちる直前の分があればよい）
            _ = ftruncate(crashFD, 0)
            _ = lseek(crashFD, 0, SEEK_SET)
            written = 0
        }
        _ = bytes.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        written += bytes.count
    }

    #if canImport(Darwin)
    static func recordException(_ e: NSException) {
        var s = "\n\(exceptionMark)\(e.name.rawValue): \(e.reason ?? "（理由なし）")\n"
        s += e.callStackSymbols.prefix(40).joined(separator: "\n")
        writeLine(s)
    }
    #endif

    /// 前回の記録（最後の lines 行）。無ければ nil
    static func previous(lines: Int = 300) -> String? {
        guard let d = try? Data(contentsOf: previousURL), !d.isEmpty else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// 前回は落ちて終わったか（例外かシグナルの記録がある）。あれば、その行
    static func previousCrashSummary() -> String? {
        guard let p = previous(lines: 2000) else { return nil }
        let lines = p.split(separator: "\n")
        return lines.last { $0.contains(exceptionMark) || $0.contains(signalMark) }.map(String.init)
    }
}

// ======================================================================
// MARK: - VNetScheme.swift
// ======================================================================

// MARK: - WKWebView の読み込みを引き受けて、自作の通信（VNetMachine）で取ってくる
//
// https:// と http://（予備の作りでは vnets:// と vnet://）の読み込みが全部ここに来る。
// WebKit は画面のスレッドから呼ぶ。こちらも pending は画面のスレッドの上でだけ触る
//
// 守っていること（NetPolicy.swift の決まりを使う）:
// ・CORS はサーバーの答えをそのまま渡す（OPTIONS もサーバーに送る）。Vela が許可を作ることはしない
// ・CSP・X-Frame-Options などの守りのヘッダは消さない（予備の vnets:// の作りだけは、書き換えと合わないので外す）
// ・リダイレクトの次の要求は RedirectPolicy だけで作る（Authorization を別のオリジンへ持ち越さない・POST を二重に送らない）
// ・Cookie は CookieJar（WebKit の置き場の写し）と CookiePolicy。届いた Cookie は WebKit の置き場に入れてから、ページに返事を渡す
// ・HSTS: 記録があれば http を https に上げる。https の応答から記録する（HSTSPolicy の条件のときだけ）
// ・LAN の保護で「確認が必要」になった移動は、確認のページを出す（ユーザーが押したら、ユーザーの操作として開き直す）
// ・直接の作り（https をそのまま引き受ける）では、返事を流す形で渡す: ヘッダが来たら WebKit に返事を渡し、中身は届いた分ずつ渡す
//   （大きいファイル・動画でもメモリにためない。3xx は貯めて移動として渡す。vnets:// の作りは中身を書き換えるので貯める）

final class VNetScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var machine: VNetMachine?
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 届いた Cookie の変更をブラウザ（WebKit）の置き場に入れる。入れ終わったら done を呼ぶこと
    var pushCookies: (([CookieChange], _ done: @escaping @Sendable () -> Void) -> Void)?
    /// HSTS の記録（nil なら使わない）
    var hsts: HSTSStore?
    /// エラーページ・確認のページのボタンの合言葉（nonce）→ してほしいこと。
    /// ページは失敗した URL のオリジンで出すので、元の公開のページからは合言葉を読めない
    let actions = PageActions()
    /// HTTPS-First: ページを開く http:// を、まず https で試す（公開のホストだけ）
    var httpsFirst = true
    /// HTTPS-First で https がだめで、ユーザーが「http のまま開く」を選んだホスト
    var httpAllowedHosts = Set<String>()
    /// ページ本体の読み込みに失敗したとき（標準の通信へ自動で切り替えるかを、タブが決める）
    var onTopLevelFailure: ((URL, FetchError) -> Void)?
    /// VNet が自分でファイルに書くダウンロードを始めたとき（画面のスレッドで呼ぶ）。
    /// WebKit の WKDownload は使わない（VNetScheme が引き受けた読み込みを WebKit がダウンロードに変えると、アプリが落ちたため）
    var onDownloadStarted: ((VNetDownload) -> Void)?
    /// 通信の記録（開発者パネル）と、このタブの番号
    var netLog: NetLog?
    var tabID: Int?
    /// 広告ブロックの判定（nil なら調べない）。ページ本体は止めず、サブリソースだけを調べる
    var blocker: BlockEngineBox?
    /// 広告ブロックで止めたとき（画面のスレッドで呼ぶ）
    var onBlocked: ((URL, String) -> Void)?
    /// ダウンロードに変えた要求（WebKit の要求は 204 で終わらせ、中身はファイルに書く）
    private var downloadsInFlight: [Int: VNetDownload] = [:]

    /// 読み込み中の要求
    private struct Pending {
        let task: WKURLSchemeTask
        /// WebKit が頼んできたアドレス（vnets://… か https://…）。移動（リダイレクト）すると変わる
        var shownURL: URL
        /// 本当に読みに行くアドレス（https://…）
        var realURL: URL
        let started: Date
        /// WebKit からの要求（移動のときに、次の要求を作るのに使う）
        var request: URLRequest
        var body: Data?
        var redirects = 0
        /// 移動（3xx）を WebKit に伝えられるか。できないときは、自分で追いかけて最後の返事だけ渡す
        var webKitRedirects: Bool
        /// 要求の文脈（Cookie・LAN・HSTS の判定）
        var context: RequestContext
        /// 取り消しの印（WebKit がやめたら、裏の通信も止める）
        let token = RequestToken()
        /// 予備の vnets:// の作りの要求か
        var vnetsMode: Bool { VNetURL.isVNet(shownURL) }
        /// 流す形の様子: none（まだ・貯める形）→ pushing（Cookie を WebKit に入れている）→ sending（中身を渡している）
        var streamPhase = StreamPhase.none
        /// sending になる前に届いた中身
        var streamQueue: [Data] = []
        /// sending になる前に読み終わった（失敗した）
        var streamDone: Result<HTTPResult, FetchError>?
        var streamBytes = 0
        /// HTTPS-First で https に上げた元の http の URL（https で失敗したら「http のまま開く」を出す）
        var httpsFirstFrom: URL?
        /// 自分で作った移動（HSTS・HTTPS-First）を WebKit に伝えている途中
        var syntheticRedirect = false
        /// 通信の記録の番号（0 なら記録していない）
        var logID = 0
    }
    private enum StreamPhase { case none, pushing, sending }
    /// 読み込み中の要求（番号 → 要求）。番号は要求ごとに 1 つずつ増やす（使い回さない）。
    /// WebKit の要求のアドレス（ObjectIdentifier）で引くと、止めた要求のアドレスを次の要求が使い回したときに、
    /// 前の要求の遅れて届いた返事が新しい要求に渡ってしまい、WebKit が例外を出して落ちた
    private var pending: [Int: Pending] = [:]
    /// WebKit の要求 → 番号（stop で引く。使い回されたアドレスかどうかは task が同じものかで確かめる）
    private var taskIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    /// ユーザーがアドレス欄などから開いた URL（1 回だけ使える印。ページのリンクや JavaScript の移動と見分ける）
    private var userNavigation: (url: URL, at: Date)?

    /// アプリが load() する直前に呼ぶ（画面のスレッドから）
    func noteUserNavigation(_ url: URL) {
        userNavigation = (VNetURL.toReal(url) ?? url, Date())
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        start(task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 裏の通信も止める（待ち行列から外す・読んでいる途中の接続は切る）
        let key = ObjectIdentifier(task)
        guard let id = taskIDs[key], let p = pending[id], (p.task as AnyObject) === (task as AnyObject) else { return }
        taskIDs[key] = nil
        pending[id] = nil
        p.token.cancel()
        netLog?.finish(p.logID, outcome: .cancelled)
    }

    /// 読み込み中の要求の数（開発者向け）
    var pendingCount: Int { pending.count }

    private func start(_ task: WKURLSchemeTask) {
        guard let shown = task.request.url, let real = VNetURL.toReal(shown), let machine else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let body = VNetScheme.body(of: task.request)
        let ctx = context(for: task.request, real: real)
        let types = BlockEngine.guessTypes(url: real, accept: task.request.value(forHTTPHeaderField: "Accept"), isTopLevel: ctx.isTopLevel)
        let logID = netLog?.begin(tab: tabID, method: task.request.httpMethod ?? "GET", url: real.absoluteString,
                                  kind: VNetScheme.kindLabel(types), topLevel: ctx.isTopLevel) ?? 0
        // 広告ブロック（サブリソースだけ）。止めたものは通信しない
        if !ctx.isTopLevel, let blocker {
            if let d = blocker.match(url: real, types: types, sourceHost: ctx.initiator?.host ?? ctx.topURL?.host, topHost: ctx.topURL?.host) {
                log?("🚫 広告ブロック: \(real.absoluteString)（\(d.rule)）")
                netLog?.finish(logID, outcome: .blocked(d.rule))
                onBlocked?(real, d.rule)
                task.didFailWithError(NSError(domain: "VelaAdBlock", code: 1, userInfo: [NSLocalizedDescriptionKey: "広告ブロックで止めました"]))
                return
            }
        }
        let id = nextID
        nextID += 1
        // 終わった要求の分は、ときどきまとめて消す（増え続けないように）
        if taskIDs.count > 256 { taskIDs = taskIDs.filter { pending[$0.value] != nil || downloadsInFlight[$0.value] != nil } }
        taskIDs[ObjectIdentifier(task)] = id
        let webKitRedirects = SchemeTaskRedirect.isAvailable(task)
        var p = Pending(task: task, shownURL: shown, realURL: real, started: Date(), request: task.request, body: body,
                        webKitRedirects: webKitRedirects, context: ctx)
        p.logID = logID
        if ctx.userInitiated { netLog?.note(logID, "ユーザーの操作で開いた") }
        if let i = ctx.initiator, !ctx.isTopLevel, let top = ctx.topURL,
           SiteUtil.registrableDomain(i.host ?? "") != SiteUtil.registrableDomain(top.host ?? "") {
            netLog?.note(logID, "読み込んだのは別のサイト: \(i.host ?? "")")
        }
        pending[id] = p
        // HSTS・HTTPS-First: http を https に上げてから読む（WebKit にも移動として伝える）
        if let (up, reason) = upgradeTarget(real, ctx: ctx) {
            log?("🔒 \(reason): \(real.absoluteString) → https")
            netLog?.note(logID, "🔒 \(reason): https に上げた")
            if reason == "HTTPS-First" { p.httpsFirstFrom = real }
            if webKitRedirects {
                p.syntheticRedirect = true
                pending[id] = p
                let next = RedirectPolicy.Next(url: up, method: task.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(task.request),
                                               body: body, crossOrigin: true, upgradedByHSTS: true, dropped: [])
                redirect(id, p, status: 307, serverHeaders: [("Non-Authoritative-Reason", reason)], type: "text/plain", next: next)
                return
            }
            p.realURL = up
            p.context = ctx.redirected(from: real, to: up)
            pending[id] = p
            fetch(id, makeRequest(task.request, url: up, body: body, ctx: p.context), followRedirects: true, machine: machine)
            return
        }
        fetch(id, makeRequest(task.request, url: real, body: body, ctx: ctx), followRedirects: !webKitRedirects, machine: machine)
    }

    /// http を https に上げるか（HSTS の記録がある・HTTPS-First）。上げるなら (https の URL, 理由)
    private func upgradeTarget(_ real: URL, ctx: RequestContext) -> (URL, String)? {
        guard real.scheme?.lowercased() == "http", let h = SiteUtil.host(of: real),
              var c = URLComponents(url: real, resolvingAgainstBaseURL: false) else { return nil }
        let reason: String
        if hsts?.shouldUpgrade(h) == true {
            reason = "HSTS"
        } else if httpsFirst && ctx.isTopLevel && !httpAllowedHosts.contains(h) && !SiteUtil.isIPLiteral(h)
                    && LocalNetworkPolicy.classify(host: h) == nil && c.port == nil {
            // 公開の名前のホストだけ（LAN・数字のアドレス・ポート指定は、https が無いことが多いので上げない）
            reason = "HTTPS-First"
        } else {
            return nil
        }
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        guard let up = c.url else { return nil }
        return (up, reason)
    }

    private func fetch(_ id: Int, _ req: HTTPRequest, followRedirects: Bool, machine: VNetMachine) {
        var req = req
        req.token = pending[id]?.token
        // 直接の作りでは、流す形で受け取る（3xx は貯めて、移動として渡す・追いかける）
        if let p = pending[id], !p.vnetsMode {
            req.sink = StreamSink(shouldStream: { status, _ in !RedirectPolicy.statuses.contains(status) },
                                  onHead: { [weak self] h in
                                      let me = self
                                      DispatchQueue.main.async { me?.streamHead(id, h) }
                                  },
                                  onData: { [weak self] d in
                                      let me = self
                                      DispatchQueue.main.async { me?.streamData(id, d) }
                                  })
        }
        machine.send(req, followRedirects: followRedirects) { [weak self] result in
            let me = self   // weak の self は var なので、並行で動く閉包からは直接さわれない。let に受け直す
            DispatchQueue.main.async { me?.finish(id, result) }
        }
    }

    private func finish(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        if let dl = downloadsInFlight.removeValue(forKey: id) {
            switch result {
            case .success: dl.finish()
            case .failure(let e): if e.kind != .cancelled { dl.fail(e.description) }
            }
            return
        }
        guard var p = pending[id] else { return }
        // 流す形で返事をもう渡し始めている: 終わりを伝える（まだ Cookie を入れている途中なら、渡し始めてから）
        if p.streamPhase != .none {
            if p.streamPhase == .sending { endStream(id, result) } else { p.streamDone = result; pending[id] = p }
            return
        }
        // Cookie が届いていたら、先にブラウザの置き場に入れてから返事を渡す（ページがすぐ document.cookie を読んでも間に合うように）
        if case .success(let r) = result, !r.cookieChanges.isEmpty, let pushCookies {
            pushCookies(r.cookieChanges) { [weak self] in
                let me = self
                DispatchQueue.main.async { me?.complete(id, result) }
            }
            return
        }
        complete(id, result)
    }

    /// 返事を WebKit に渡す（途中で止められていたら何もしない）
    private func complete(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        guard let p = pending[id] else { return }
        if case .success(let r) = result, let sts = r.header("Strict-Transport-Security") {
            hsts?.record(header: sts, url: r.url, ctx: p.context)
            netLog?.note(p.logID, "HSTS の指定: \(sts)")
        }
        if case .success(let r) = result, !r.cookieChanges.isEmpty {
            netLog?.note(p.logID, "🍪 Cookie を \(r.cookieChanges.count) 個保存・変更")
        }
        // 移動（3xx）: WebKit に「移動した」と伝える（アドレス・相対リンク・オリジン・クッキーが移動先のものになる）
        if case .success(let r) = result, p.webKitRedirects, RedirectPolicy.statuses.contains(r.status) {
            let hsts = self.hsts
            switch RedirectPolicy.next(from: p.realURL, method: p.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(p.request),
                                       body: p.body, status: r.status, location: r.header("Location"), redirectCount: p.redirects,
                                       hsts: { hsts?.shouldUpgrade($0) ?? false }) {
            case .success(let next):
                redirect(id, p, status: r.status, serverHeaders: r.headers, type: VNetScheme.contentType(r, real: p.realURL), next: next)
                return
            case .failure(.tooMany):
                pending[id] = nil
                fail(p, FetchError("リダイレクトが多すぎます", kind: .redirect))
                return
            case .failure(let f):
                log?("↪ \(r.status) を追いかけません（\(f)）。そのまま渡します")
            }
        }
        pending[id] = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        let real = p.realURL
        switch result {
        case .failure(let e):
            fail(p, e)
        case .success(let r):
            let range = r.header("Content-Range").map { "・\($0)" } ?? ""
            log?("✓ \(r.status) \(r.url.absoluteString)（\(r.body.count / 1024)KB・\(ms)ms\(range)）")
            netLog?.finish(p.logID, outcome: .ok, status: r.status, bytes: r.body.count)
            var type = VNetScheme.contentType(r, real: real)
            var body = r.body
            // vnets:// の作りのときだけ: HTML と CSS の中の https:// を vnets:// に書き換える（部品も自作の通信で読むため）
            // （https をそのまま引き受けているときは、書き換えなくても全部ここに来る）
            let lower = type.lowercased()
            if p.vnetsMode && (lower.contains("text/html") || lower.contains("text/css")) {
                body = VNetScheme.rewriteLinks(body)
                if !lower.contains("charset") { type += "; charset=utf-8" }
            }
            // 自分で追いかけた移動の先のアドレスで表示する（相対アドレスがずれないように）
            let shownReal = VNetURL.toReal(p.shownURL) ?? p.shownURL
            let shown = r.url == shownReal ? p.shownURL : (p.vnetsMode ? (VNetURL.toVNet(r.url) ?? p.shownURL) : r.url)
            respond(p.task, url: shown, status: r.status, type: type, body: body, vnetsMode: p.vnetsMode, extra: r.headers)
        }
    }

    // MARK: 流す形

    /// 流す形の返事のヘッダが来た: Cookie を WebKit の置き場に入れてから、返事を渡す
    private func streamHead(_ id: Int, _ h: HTTPHead) {
        guard var p = pending[id] else { return }
        // ページ本体の返事がダウンロード（添付ファイル・表示できない種類）なら、WebKit には渡さずにファイルに書く
        if p.context.isTopLevel, onDownloadStarted != nil, DownloadFiles.isDownload(status: h.status, headers: h.headers),
           let dl = makeDownload(h) {
            let token = p.token
            dl.cancelAction = { token.cancel() }
            downloadsInFlight[id] = dl
            pending[id] = nil
            if !h.cookieChanges.isEmpty { pushCookies?(h.cookieChanges) {} }
            // ページはそのまま（204 No Content は「移動しない」）
            if let resp = HTTPURLResponse(url: p.shownURL, statusCode: 204, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/plain", "Content-Length": "0"]) {
                p.task.didReceive(resp)
                p.task.didFinish()
            }
            log?("⬇︎ ダウンロードにします: \(h.url.absoluteString) → \(dl.fileURL.lastPathComponent)")
            netLog?.finish(p.logID, outcome: .download, status: h.status)
            onDownloadStarted?(dl)
            return
        }
        p.streamPhase = .pushing
        pending[id] = p
        netLog?.update(p.logID) { $0.status = h.status }
        if !h.cookieChanges.isEmpty { netLog?.note(p.logID, "🍪 Cookie を \(h.cookieChanges.count) 個保存・変更") }
        if let sts = h.header("Strict-Transport-Security") {
            hsts?.record(header: sts, url: h.url, ctx: p.context)
            netLog?.note(p.logID, "HSTS の指定: \(sts)")
        }
        if !h.cookieChanges.isEmpty, let pushCookies {
            pushCookies(h.cookieChanges) { [weak self] in
                let me = self
                DispatchQueue.main.async { me?.startSending(id, h) }
            }
        } else {
            startSending(id, h)
        }
    }

    /// ダウンロードのファイルを作る
    private static func download(for h: HTTPHead) -> VNetDownload? {
        let name = DownloadFiles.filename(contentDisposition: h.header("Content-Disposition"), url: h.url, mime: h.header("Content-Type"))
        let expected = h.header("Content-Length").flatMap { Int64($0) } ?? -1
        return VNetDownload(source: h.url, suggestedName: name, expected: expected)
    }

    private func makeDownload(_ h: HTTPHead) -> VNetDownload? { VNetScheme.download(for: h) }

    /// URL をダウンロードする（<a download> のリンク・やり直しなど。WebKit を通さずに VNet で読んでファイルに書く）
    func startDownload(url: URL, referer: URL?) {
        guard let machine else { return }
        var r = URLRequest(url: url)
        if let referer { r.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        var ctx = RequestContext(topURL: url, isTopLevel: true, initiator: referer)
        ctx.userInitiated = true
        var req = makeRequest(r, url: url, body: nil, ctx: ctx)
        let token = RequestToken()
        req.token = token
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var download: VNetDownload?
            var status = 0
        }
        let box = Box()
        let started: (VNetDownload, [CookieChange]) -> Void = { [weak self] dl, changes in
            let me = self
            DispatchQueue.main.async {
                if !changes.isEmpty { me?.pushCookies?(changes) {} }
                me?.onDownloadStarted?(dl)
            }
        }
        req.sink = StreamSink(shouldStream: { status, _ in !RedirectPolicy.statuses.contains(status) },
                              onHead: { h in
                                  guard let dl = VNetScheme.download(for: h) else { return }
                                  dl.cancelAction = { token.cancel() }
                                  box.lock.lock(); box.download = dl; box.status = h.status; box.lock.unlock()
                                  started(dl, h.cookieChanges)
                              },
                              onData: { d in
                                  box.lock.lock(); let dl = box.download; box.lock.unlock()
                                  dl?.write(d)
                              })
        let lg = log
        lg?("⬇︎ VNet でダウンロードします: \(url.absoluteString)")
        machine.send(req, followRedirects: true) { result in
            box.lock.lock(); var dl = box.download; let status = box.status; box.lock.unlock()
            switch result {
            case .success(let r):
                // 流す形にならなかった（縮め方が流せないなど）: 貯めた中身をまとめて書く
                if dl == nil, let made = VNetScheme.download(for: HTTPHead(status: r.status, headers: r.headers, url: r.url, cookieChanges: r.cookieChanges)) {
                    made.cancelAction = { token.cancel() }
                    made.write(r.body)
                    dl = made
                    started(made, r.cookieChanges)
                }
                let code = r.streamed ? status : r.status
                if (200...299).contains(code) { dl?.finish() } else { dl?.fail("サーバーの返事 \(code)") }
            case .failure(let e):
                if e.kind != .cancelled { dl?.fail(e.description) }
                lg?("⬇︎✕ ダウンロード失敗: \(url.absoluteString)：\(e.description)")
            }
        }
    }

    private func startSending(_ id: Int, _ h: HTTPHead) {
        guard var p = pending[id] else { return }
        let shownReal = VNetURL.toReal(p.shownURL) ?? p.shownURL
        let shown = h.url == shownReal ? p.shownURL : h.url
        let type = VNetScheme.contentType(headers: h.headers, real: h.url)
        let length = h.header("Content-Length").flatMap { Int($0) }
        let headers = VNetScheme.responseHeaders(type: type, length: length, vnetsMode: false, extra: h.headers)
        guard let resp = HTTPURLResponse(url: shown, statusCode: h.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            pending[id] = nil
            p.task.didFailWithError(URLError(.badServerResponse))
            return
        }
        p.task.didReceive(resp)
        p.streamPhase = .sending
        let queued = p.streamQueue
        p.streamQueue = []
        for d in queued { p.task.didReceive(d); p.streamBytes += d.count }
        let done = p.streamDone
        pending[id] = p
        if let done { endStream(id, done) }
    }

    private func streamData(_ id: Int, _ d: Data) {
        if let dl = downloadsInFlight[id] { dl.write(d); return }
        guard var p = pending[id] else { return }
        if p.streamPhase == .sending {
            p.task.didReceive(d)
            p.streamBytes += d.count
        } else {
            p.streamQueue.append(d)
        }
        pending[id] = p
    }

    private func endStream(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        switch result {
        case .success(let r):
            log?("✓ \(r.status) \(r.url.absoluteString)（\(p.streamBytes / 1024)KB・\(ms)ms・流す形）")
            netLog?.finish(p.logID, outcome: .ok, status: r.status, bytes: p.streamBytes)
            // リダイレクトの途中で届いた Cookie もあれば、WebKit の置き場に入れておく（同じものを入れ直しても害は無い）
            if !r.cookieChanges.isEmpty { pushCookies?(r.cookieChanges) {} }
            p.task.didFinish()
        case .failure(let e):
            log?("✕ \(p.realURL.absoluteString)：途中で失敗（\(p.streamBytes / 1024)KB まで）：\(e.description)")
            netLog?.finish(p.logID, outcome: .failed("途中で失敗: \(e.description)"), bytes: p.streamBytes)
            p.task.didFailWithError(URLError(e.kind == .timeout ? .timedOut : .networkConnectionLost))
        }
    }

    /// 失敗をページにする（説明と、できることのボタン。LAN への移動なら確認のページ）
    private func fail(_ p: Pending, _ e: FetchError) {
        let real = p.realURL
        log?("✕ \(real.absoluteString)：\(e.description)")
        netLog?.finish(p.logID, outcome: e.kind == .cancelled ? .cancelled : .failed("\(e.kind.rawValue): \(e.description)"))
        let html: String
        if e.kind == .localNetworkConsent && p.context.isTopLevel {
            html = ErrorPage.html(title: "LAN の機器を開きますか？", lines: [
                "ページが、LAN（家や会社の中のネットワーク）にある次のアドレスへ移動しようとしています。",
                real.absoluteString, "心当たりがなければ開かないでください。"],
                detail: e.description,
                buttons: [ErrorPage.Button(label: "開く", nonce: actions.make("allowLocalNetwork", url: real), primary: false)],
                kind: e.kind.rawValue)
        } else if let http = p.httpsFirstFrom, p.context.isTopLevel, e.kind != .blocked {
            html = ErrorPage.html(title: "https では開けませんでした", lines: [
                "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
                "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
                detail: "\(real.absoluteString)\n\(e.description)",
                buttons: [ErrorPage.Button(label: "http のまま開く", nonce: actions.make("openHTTP", url: http), primary: false),
                          ErrorPage.Button(label: "再試行", nonce: actions.make("retry", url: real), primary: true)],
                kind: "httpsFirst")
        } else {
            let d = ErrorPage.describe(e)
            var buttons = [ErrorPage.Button(label: "再試行", nonce: actions.make("retry", url: real), primary: true)]
            if d.offerNative && p.context.isTopLevel {
                buttons.append(ErrorPage.Button(label: "標準の通信で開く", nonce: actions.make("openNative", url: real), primary: false))
            }
            html = ErrorPage.html(title: d.title, lines: [d.hint, real.absoluteString], detail: e.description, buttons: buttons, kind: e.kind.rawValue)
        }
        respond(p.task, url: p.shownURL, status: 502, type: "text/html; charset=utf-8", body: Data(html.utf8), vnetsMode: p.vnetsMode)
        if p.context.isTopLevel, let cb = onTopLevelFailure {
            let u = p.httpsFirstFrom ?? real
            DispatchQueue.main.async { cb(u, e) }
        }
    }

    // MARK: 移動（リダイレクト）

    /// 3xx を WebKit に伝える。WebKit が次の要求を返してきたら、それを読みに行く
    private func redirect(_ id: Int, _ p: Pending, status: Int, serverHeaders: [(String, String)], type: String, next: RedirectPolicy.Next) {
        let nextShown = p.vnetsMode ? (VNetURL.toVNet(next.url) ?? next.url) : next.url
        let dropped = next.dropped.isEmpty ? "" : "（外したヘッダ: \(next.dropped.joined(separator: ", "))）"
        log?("↪ \(status) \(p.realURL.absoluteString) → \(next.url.absoluteString)\(dropped)")
        netLog?.note(p.logID, "↪ \(status) → \(next.url.absoluteString)\(dropped)")
        var h = VNetScheme.responseHeaders(type: type, length: 0, vnetsMode: p.vnetsMode, extra: serverHeaders)
        h["Location"] = nextShown.absoluteString
        let nr = NSMutableURLRequest(url: nextShown)
        nr.httpMethod = next.method
        var fields: [String: String] = [:]
        for (k, v) in next.headers { fields[k] = v }
        nr.allHTTPHeaderFields = fields
        nr.httpBody = next.body
        nr.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? nextShown : p.request.mainDocumentURL
        let body = next.body
        guard let resp = HTTPURLResponse(url: p.shownURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h),
              SchemeTaskRedirect.perform(p.task, response: resp, request: nr, done: { [weak self] newReq in
                  let me = self
                  DispatchQueue.main.async { me?.afterRedirect(id, newReq, body: body) }
              }) else {
            // 伝えられなかった: 受け取った 3xx から作った次の要求を、自分で追いかける（元の要求は送り直さない。POST を二重に送らないため）
            guard var q = pending[id], let machine else { return }
            q.webKitRedirects = false
            q.context = q.context.redirected(from: q.realURL, to: next.url)
            q.realURL = next.url
            q.redirects += 1
            pending[id] = q
            var r = URLRequest(url: next.url)
            r.httpMethod = next.method
            r.allHTTPHeaderFields = fields
            r.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? next.url : p.request.mainDocumentURL.flatMap { VNetURL.toReal($0) }
            r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
            fetch(id, makeRequest(r, url: next.url, body: next.body, ctx: q.context), followRedirects: true, machine: machine)
            return
        }
    }

    /// WebKit が移動を受け入れた（newReq が次の要求）。nil なら WebKit がやめた（このあと stop が来る）
    private func afterRedirect(_ id: Int, _ newReq: NSURLRequest?, body: Data?) {
        guard var p = pending[id] else { return }
        guard let newReq, let u = newReq.url, let real = VNetURL.toReal(u), let machine else {
            pending[id] = nil
            return
        }
        var r = URLRequest(url: u)
        r.httpMethod = newReq.httpMethod
        r.allHTTPHeaderFields = newReq.allHTTPHeaderFields
        r.mainDocumentURL = newReq.mainDocumentURL
        r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
        let b = newReq.httpBody ?? body
        // サーバーの移動なら、HTTPS-First の「http のまま開く」は出さない（自分で作った移動のときだけ残す）
        if p.syntheticRedirect { p.syntheticRedirect = false } else { p.httpsFirstFrom = nil }
        p.context = p.context.redirected(from: p.realURL, to: real)
        p.shownURL = u
        p.realURL = real
        p.request = r
        p.body = b
        p.redirects += 1
        pending[id] = p
        fetch(id, makeRequest(r, url: real, body: b, ctx: p.context), followRedirects: false, machine: machine)
    }

    // MARK: 要求を作る

    /// WebKit の要求から、文脈（トップのページ・トップレベルの移動か・どこから来たか・ユーザーの操作か）を作る
    private func context(for r: URLRequest, real: URL) -> RequestContext {
        let top = r.mainDocumentURL.flatMap { VNetURL.toReal($0) }
        let isTop = r.mainDocumentURL != nil && r.mainDocumentURL == r.url
        // どこから来たか: Referer。無ければ Origin（Referrer-Policy: no-referrer でも、POST には Origin が付く。"null" は分からない扱い）
        let referer = r.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) }
        let originHeader = r.value(forHTTPHeaderField: "Origin").flatMap { $0 == "null" ? nil : URL(string: $0) }
        let initiator = (referer ?? originHeader).flatMap { VNetURL.toReal($0) }
        var ctx = RequestContext(topURL: top, isTopLevel: isTop, initiator: initiator)
        ctx.cookiesAllowed = r.httpShouldHandleCookies
        // 実機で確かめること: WebKit がスキームハンダの要求に httpShouldHandleCookies を正しく入れてくるか（ページ本体で false なら怪しい）
        if isTop && !r.httpShouldHandleCookies { log?("🍪 ページ本体の要求が httpShouldHandleCookies=false です（\(real.absoluteString)）") }
        if isTop, let u = userNavigation, Date().timeIntervalSince(u.at) < 15, VNetScheme.sameIgnoringFragment(u.url, real) {
            ctx.userInitiated = true
            userNavigation = nil
        }
        return ctx
    }

    static func sameIgnoringFragment(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false), cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil; cb?.fragment = nil
        return ca?.url?.absoluteString == cb?.url?.absoluteString
    }

    /// URLRequest のヘッダを（名前, 値）の並びにする
    static func headerPairs(_ r: URLRequest) -> [(String, String)] {
        (r.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
    }

    /// WebKit の要求を、自作の通信の要求にする
    func makeRequest(_ r: URLRequest, url: URL, body: Data?, ctx: RequestContext) -> HTTPRequest {
        var req = VNetScheme.makeRequest(r, url: url, body: body)
        req.context = ctx
        return req
    }

    /// WebKit の要求を、自作の通信の要求にする（ヘッダの変換だけ。文脈は makeRequest(_:url:body:ctx:) で付ける）
    static func makeRequest(_ r: URLRequest, url: URL, body: Data?) -> HTTPRequest {
        var req = HTTPRequest(url: url)
        req.method = r.httpMethod ?? "GET"
        for (k, v) in r.allHTTPHeaderFields ?? [:] {
            switch k.lowercased() {
            case "origin", "referer":
                // vnets://… なら https://… に戻して送る（https://… ならそのまま）
                if v.lowercased().hasPrefix("vnet"), let u = URL(string: v), let real = VNetURL.toReal(u) {
                    let s = real.absoluteString
                    req.headers.append((k, k.lowercased() == "origin" ? s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : s))
                } else if v.lowercased().hasPrefix("http") {
                    req.headers.append((k, v))
                }
            case "range":
                // 「最後まで全部」は、少しずつ（2MB ずつ）にする。動画を丸ごと読み終わるまで待たないように
                req.headers.append((k, clampRange(v) ?? v))
            default:
                req.headers.append((k, v))
            }
        }
        req.body = body
        // ページを開く要求（ページ本体）に Sec-Fetch-* が無ければ付ける（Safari は必ず付ける。無いとロボットだと思われやすい）
        if req.headers.value(for: "Sec-Fetch-Dest") == nil, let main = r.mainDocumentURL, main == r.url {
            var site = "none"
            if let ref = req.headers.value(for: "Referer").flatMap({ URL(string: $0) }), let rh = ref.host?.lowercased(),
               let h = url.host?.lowercased() {
                if ref.scheme?.lowercased() == url.scheme?.lowercased() && rh == h && ref.port == url.port { site = "same-origin" }
                else { site = siteOf(rh) == siteOf(h) ? "same-site" : "cross-site" }
            }
            req.headers += [("Sec-Fetch-Site", site), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")]
            if req.headers.value(for: "Upgrade-Insecure-Requests") == nil { req.headers.append(("Upgrade-Insecure-Requests", "1")) }
        }
        return req
    }

    /// 「サイト」（example.co.jp → example.co.jp、www.example.com → example.com）
    static func siteOf(_ host: String) -> String { SiteUtil.registrableDomain(host) }

    static func body(of r: URLRequest) -> Data? {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return nil }
        var d = Data()
        s.open()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        s.close()
        return d
    }

    /// 1 回に読む大きさ（動画の Range）
    static let rangeChunk = 2 << 20

    /// "bytes=a-"（最後まで）や、大きすぎる "bytes=a-b" を "bytes=a-(a+2MB-1)" に直す。直さなくて良いときは nil
    static func clampRange(_ v: String) -> String? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("bytes="), !s.contains(",") else { return nil }
        let parts = s.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let maxEnd = a + rangeChunk - 1
        if let b = Int(parts[1].trimmingCharacters(in: .whitespaces)), b <= maxEnd { return nil }
        return "bytes=\(a)-\(maxEnd)"
    }

    // MARK: 返事を作る

    /// 拡張子から動画・音声の種類を決める
    static let mediaTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
                                               "webm": "video/webm", "mp3": "audio/mpeg", "m4a": "audio/mp4",
                                               "aac": "audio/aac", "wav": "audio/wav", "m3u8": "application/vnd.apple.mpegurl",
                                               "ts": "video/mp2t"]

    /// Content-Type。種類が書いていない動画・音声は、拡張子から決める（でないと再生できない）
    /// 記録に出す種類の名前
    static func kindLabel(_ t: Set<ResourceType>) -> String {
        if t.count > 1 { return "その他" }
        switch t.first {
        case .document?: return "ページ"
        case .subdocument?: return "フレーム"
        case .script?: return "スクリプト"
        case .image?: return "画像"
        case .stylesheet?: return "CSS"
        case .font?: return "フォント"
        case .media?: return "動画・音声"
        case .xhr?: return "XHR"
        default: return "その他"
        }
    }

    static func contentType(_ r: HTTPResult, real: URL) -> String {
        contentType(headers: r.headers, real: real)
    }

    static func contentType(headers: [(String, String)], real: URL) -> String {
        let type = headers.value(for: "Content-Type") ?? "application/octet-stream"
        let lower = type.lowercased()
        if lower.hasPrefix("application/octet-stream") || lower.hasPrefix("binary/"),
           let guess = mediaTypes[real.pathExtension.lowercased()] {
            return guess
        }
        return type
    }

    /// HTML・CSS の中の https:// を vnets://（http:// を vnet://）に書き換える
    static func rewriteLinks(_ body: Data) -> Data {
        var s = String(decoding: body, as: UTF8.self)
        for (from, to) in [("https://", "vnets://"), ("http://", "vnet://"), ("https:\\/\\/", "vnets:\\/\\/")] {
            for q in ["\"", "'", "(", "=", " "] { s = s.replacingOccurrences(of: q + from, with: q + to) }
        }
        return Data(s.utf8)
    }

    /// 相手の返事のヘッダのうち、WebKit にそのまま渡さないもの（長さ・縮め方は自分で決め直す。Cookie は CookieJar 経由で WebKit の置き場に入れる）
    static let dropHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "content-type", "connection",
                                           "keep-alive", "set-cookie", "set-cookie2", "alt-svc", "location"]
    /// 予備の vnets:// の作りのときだけ外すもの（アドレスを書き換えるので、ページの守りの決まりと合わない。この作りは開発者向けの実験で、安全ではない）
    static let vnetsOnlyDropHeaders: Set<String> = ["content-security-policy", "content-security-policy-report-only", "x-frame-options"]

    /// 返事のヘッダ: 相手のヘッダ（CSP・X-Frame-Options・動画に要る Content-Range など）＋ 長さ・種類。
    /// CORS（Access-Control-*）はサーバーの答えをそのまま渡す（CORSPassthrough）。Vela が許可を足すことはしない
    /// length が nil なら Content-Length を付けない（流す形で、長さが分からないとき）
    static func responseHeaders(type: String, length: Int?, vnetsMode: Bool, extra: [(String, String)]) -> [String: String] {
        var h: [String: String] = [:]
        var names: [String: String] = [:]      // 小文字の名前 → h での名前（同じ名前が何行もあれば「, 」でつなぐ）
        func add(_ k: String, _ v: String) {
            let lk = k.lowercased()
            if let ek = names[lk], let old = h[ek] { h[ek] = old + ", " + v } else { names[lk] = k; h[k] = v }
        }
        for (k, v) in extra {
            let lk = k.lowercased()
            if dropHeaders.contains(lk) || lk.hasPrefix("access-control-") { continue }
            if vnetsMode && vnetsOnlyDropHeaders.contains(lk) { continue }
            add(k, v)
        }
        for (k, v) in CORSPassthrough.headers(extra, vnetsMode: vnetsMode) { add(k, v) }
        h["Content-Type"] = type
        if let length { h["Content-Length"] = String(length) }
        return h
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data, vnetsMode: Bool, extra: [(String, String)] = []) {
        let h = VNetScheme.responseHeaders(type: type, length: body.count, vnetsMode: vnetsMode, extra: extra)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

// ======================================================================
// MARK: - HTTPSTakeover.swift
// ======================================================================

// MARK: - WKWebView の https・http の読み込みを、アプリが引き受けるための仕掛け

/// WKWebView に「https・http も自分で引き受けます」と言えるようにする
///
/// 普通は https を setURLSchemeHandler に渡すと「それは WebKit が自分でやる」と止められる（アプリが落ちる）。
/// WebKit はそれを WKWebView.handlesURLScheme で確かめているので、そこだけ「http・https は扱わない」と答えさせる。
/// こうすると、ページのアドレスは本物の https://… のまま、読み込みは全部 VNetScheme（自作の通信）に来る。
/// YouTube やログインのように「アドレスが https か」を確かめるページも、そのまま動く。
///
/// 受け入れたリスク（README と開発者パネルにも書く）:
/// ・WebKit の中の作り（handlesURLScheme の差し替え・_willPerformRedirection:）に頼っている。実行時に確かめても、
///   WebKit が変われば動かなくなる・落ちる可能性は消せない。App Store に出すアプリには使えない
/// ・守り: 確かめた iOS の版（testedMajorVersions）だけで使う。差し替えた後の確認に失敗したら、元の実装に戻して標準の通信にする。
///   設定の「VNet を使わない」で、差し替え自体をしないようにできる
enum HTTPSTakeover {
    enum Outcome: Equatable {
        /// https・http を VNetScheme が引き受けられる
        case installed
        /// 設定で VNet を使わない
        case disabledBySetting
        /// 確かめていない iOS の版（設定で許せば試す）
        case untestedOS(Int)
        /// 差し替えられなかった・確認に失敗した（元に戻した）
        case failed(String)

        var description: String {
            switch self {
            case .installed: return "https の横取り: 成功"
            case .disabledBySetting: return "https の横取り: 設定で使わない"
            case .untestedOS(let v): return "https の横取り: 確かめていない iOS \(v) なので使わない（設定で試せます）"
            case .failed(let why): return "https の横取り: 失敗（\(why)）。元に戻しました"
            }
        }
    }

    /// 動くことを確かめた iOS の版（大きい番号）
    static let testedMajorVersions = 16...26

    // 1 回目の結果。@MainActor にはしない（NSObject の override init など、隔離の扱いが iPad の Swift で揺れる所から呼ぶため）。
    // 代わりにロックで守る。WKWebView.handlesURLScheme は Objective-C の API なので、どのスレッドから呼んでもコンパイルは通る
    private static let lock = NSLock()
    private static var result: Outcome?

    /// 1 回だけ行う（2 回目からは 1 回目の結果）。画面のスレッドから呼ぶこと
    static func install() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        let r = tryInstall()
        result = r
        return r
    }

    private static func tryInstall() -> Outcome {
        if VelaSettings.vnetDisabled { return .disabledBySetting }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if !testedMajorVersions.contains(major) && !VelaSettings.allowUntestedOS { return .untestedOS(major) }
        let sel = NSSelectorFromString("handlesURLScheme:")
        guard let m = class_getClassMethod(WKWebView.self, sel) else { return .failed("handlesURLScheme: が見つかりません") }
        let original = method_getImplementation(m)
        let others = ["data", "blob", "about", "vnets"]
        let before = others.map { WKWebView.handlesURLScheme($0) }
        swap(m, sel: sel, original: original)
        // 差し替えが効いているか・ほかのスキームの答えが変わっていないかを確かめる。だめなら元に戻す
        let ok = !WKWebView.handlesURLScheme("https") && !WKWebView.handlesURLScheme("http")
            && others.map({ WKWebView.handlesURLScheme($0) }) == before
        if !ok {
            _ = method_setImplementation(m, original)
            return .failed("差し替えた後の確認に失敗")
        }
        return .installed
    }

    private static func swap(_ m: Method, sel: Selector, original: IMP) {
        // scheme は nil のこともありうる（Objective-C は nil を止めない）。nil を NSString として受けて触ると、
        // 不正なメモリアクセスで落ちるので、Optional で受けて、nil は元の実装に任せる
        typealias Orig = @convention(c) (AnyObject, Selector, NSString?) -> Bool
        let orig = unsafeBitCast(original, to: Orig.self)
        let block: @convention(block) (AnyObject, NSString?) -> Bool = { cls, scheme in
            guard let scheme else { return orig(cls, sel, nil) }
            let s = (scheme as String).lowercased()
            if s == "http" || s == "https" { return false }
            return orig(cls, sel, scheme)
        }
        _ = method_setImplementation(m, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
    }
}

/// 読み込みの途中の「移動（リダイレクト）」を WebKit に伝える
///
/// WKURLSchemeTask の公開の作りには移動を伝える方法が無い。そのままだと、移動先の中身を元のアドレスのまま見せることになり、
/// 相対リンク・オリジン・クッキーがずれて、ページが壊れたりログインできなかったりする。
/// WebKit の中にある _willPerformRedirection:newRequest:completionHandler:（iOS 13 から）を使って、本当の移動として伝える。
/// 無ければ false（そのときは前のやり方: 自分で追いかけて、最後の返事だけ渡す）
enum SchemeTaskRedirect {
    private static let selector = NSSelectorFromString("_willPerformRedirection:newRequest:completionHandler:")

    static func isAvailable(_ task: WKURLSchemeTask) -> Bool {
        class_getInstanceMethod(object_getClass(task), selector) != nil
    }

    /// 移動を伝える。WebKit が受け入れたら done(次の要求)、やめたら done(nil)
    static func perform(_ task: WKURLSchemeTask, response: URLResponse, request: NSURLRequest,
                        done: @escaping (NSURLRequest?) -> Void) -> Bool {
        guard let m = class_getInstanceMethod(object_getClass(task), selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, URLResponse, NSURLRequest, @escaping @convention(block) (NSURLRequest?) -> Void) -> Void
        let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (NSURLRequest?) -> Void = { done($0) }
        f(task as AnyObject, selector, response, request, block)
        return true
    }
}

/// 予備の作りで使う自分用のアドレス: https://… ⇄ vnets://…、http://… ⇄ vnet://…
enum VNetURL {
    /// https://… → vnets://…、http://… → vnet://…（vnets・vnet はそのまま）
    static func toVNet(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "vnets"
        case "http": c.scheme = "vnet"
        case "vnet", "vnets": break
        default: return nil
        }
        return c.url
    }

    /// vnets://… → https://…、vnet://… → http://…（https・http はそのまま）
    static func toReal(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "vnets": c.scheme = "https"
        case "vnet": c.scheme = "http"
        case "https", "http": return u
        default: return nil
        }
        return c.url
    }

    /// 自分用のアドレス（vnet://・vnets://）か
    static func isVNet(_ u: URL) -> Bool { u.scheme?.lowercased().hasPrefix("vnet") ?? false }
}

// ======================================================================
// MARK: - PageScripts.swift
// ======================================================================

// MARK: - ページに入れる小さなスクリプトと、そこから届く知らせ

enum PageScripts {
    /// JavaScript が使う https:// のアドレスを vnets:// に直す（予備の vnets:// の作りのときだけ使う）
    static let rewriteURLs = #"""
    (function () {
      const map = (u) => {
        try {
          if (u == null) return u;
          const s = String(u);
          if (/^https:\/\//i.test(s)) return 'vnets://' + s.slice(8);
          if (/^http:\/\//i.test(s)) return 'vnet://' + s.slice(7);
          if (s.startsWith('//')) return location.protocol + s;
          return s;
        } catch (e) { return u; }
      };
      const of = window.fetch;
      if (of) window.fetch = function (input, init) {
        if (typeof input === 'string' || input instanceof URL) input = map(input);
        else if (input && input.url && /^(https?:)?\/\//i.test(input.url)) input = new Request(map(input.url), input);
        return of.call(this, input, init);
      };
      const oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u, ...rest) { return oo.call(this, m, map(u), ...rest); };
      const props = [[window.HTMLImageElement, 'src'], [window.HTMLScriptElement, 'src'], [window.HTMLLinkElement, 'href'],
                     [window.HTMLIFrameElement, 'src'], [window.HTMLSourceElement, 'src'], [window.HTMLMediaElement, 'src']];
      for (const [C, p] of props) {
        if (!C) continue;
        const d = Object.getOwnPropertyDescriptor(C.prototype, p);
        if (d && d.set) Object.defineProperty(C.prototype, p, { get: d.get, set(v) { d.set.call(this, map(v)); }, configurable: true, enumerable: d.enumerable });
      }
      const sa = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (n, v) {
        const ln = String(n).toLowerCase();
        if (ln === 'src' || ln === 'href' || ln === 'action' || ln === 'poster') v = map(v);
        else if (ln === 'srcset' && v) v = String(v).replace(/https:\/\//gi, 'vnets://').replace(/http:\/\//gi, 'vnet://');
        return sa.call(this, n, v);
      };
      const wo = window.open;
      window.open = function (u, ...rest) { return wo.call(this, map(u), ...rest); };
    })();
    """#

    /// 知らせの名前（window.webkit.messageHandlers.<この名前>）
    static let cookieHandlerName = "vnetCookie"
    /// エラーページのボタン・守りのスクリプトからの知らせ
    static let actionHandlerName = "velaAction"

    /// JavaScript が Cookie を変えたこと（document.cookie・cookieStore）を、アプリに「合図」だけ知らせる。
    /// Cookie の中身は送らない・信じない（HttpOnly や Domain を偽れるため）。アプリは合図を受けて、WebKit の置き場（正本）を読み直す
    static let watchCookies = #"""
    (function () {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vnetCookie;
        if (!h) return;
        let queued = false;
        const tell = () => {
          if (queued) return;
          queued = true;
          setTimeout(() => { queued = false; try { h.postMessage({}); } catch (e) {} }, 50);
        };
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (d && d.set) {
          Object.defineProperty(Document.prototype, 'cookie', {
            get: d.get,
            set(v) { d.set.call(this, v); tell(); },
            configurable: true, enumerable: d.enumerable
          });
        }
        const cs = window.cookieStore;
        if (cs && cs.set) {
          const os = cs.set.bind(cs), od = cs.delete ? cs.delete.bind(cs) : null;
          cs.set = function (a, b) { const r = os(a, b); Promise.resolve(r).then(tell, tell); return r; };
          if (od) cs.delete = function (a) { const r = od(a); Promise.resolve(r).then(tell, tell); return r; };
        }
      } catch (e) {}
    })();
    """#

    /// LAN の保護（WebSocket）: WebSocket は VNet を通らないので、ページの中で止める。
    /// 公開のサイトのページから、数字の LAN のアドレス・localhost・.local への WebSocket を拒否する。
    /// 限界: ホスト名で LAN に解決されるものは分からない。スクリプトの守りは、ページに回避される可能性がある
    static let webSocketGuard = #"""
    (function () {
      try {
        const W = window.WebSocket;
        if (!W) return;
        const isLocal = (h) => {
          h = String(h || '').toLowerCase().replace(/^\[|\]$/g, '');
          return /^(10|127)\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) ||
                 /^172\.(1[6-9]|2[0-9]|3[01])\./.test(h) || /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./.test(h) ||
                 h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') ||
                 h === '::1' || /^f[cd][0-9a-f]{2}:/.test(h) || /^fe[89ab][0-9a-f]:/.test(h);
        };
        let pageLocal = false;
        try { pageLocal = isLocal(window.top.location.hostname); } catch (e) { pageLocal = isLocal(location.hostname); }
        if (pageLocal) return;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.velaAction;
        const Guarded = function WebSocket(url, protocols) {
          let host = '';
          try { host = new URL(url, location.href).hostname; } catch (e) {}
          if (isLocal(host)) {
            try { h && h.postMessage({ action: 'blockedWebSocket', url: String(url) }); } catch (e) {}
            throw new DOMException('Vela: 公開のサイトから LAN への WebSocket は止めました', 'SecurityError');
          }
          return protocols === undefined ? new W(url) : new W(url, protocols);
        };
        Guarded.prototype = W.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Guarded[k] = W[k];
        window.WebSocket = Guarded;
      } catch (e) {}
    })();
    """#

    /// VNet を通らない通信（WebSocket）を使ったら、アプリに 1 回だけ知らせる（アドレス欄の札に出す）
    static let trackNonVNet = #"""
    (function () {
      try {
        const W = window.WebSocket;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.velaAction;
        if (!W || !h) return;
        let told = false;
        const Tracked = function WebSocket(url, protocols) {
          if (!told) { told = true; try { h.postMessage({ action: 'usedWebSocket' }); } catch (e) {} }
          return protocols === undefined ? new W(url) : new W(url, protocols);
        };
        Tracked.prototype = W.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Tracked[k] = W[k];
        window.WebSocket = Tracked;
      } catch (e) {}
    })();
    """#

    /// LAN の保護（標準の通信のタブと WebSocket 用）: WebKit のルールで、LAN でないページから数字の LAN のアドレスなどへの読み込みを止める。
    /// トップのページが LAN のもの（ユーザーがアドレス欄で開いた機器のページなど）なら止めない。
    /// WebKit の正規表現は「|」が使えないので、アドレスの範囲ごとに 1 行にする
    static let localNetworkPatterns: [String] = [
        #"^[a-z]+://10\."#, #"^[a-z]+://127\."#, #"^[a-z]+://192\.168\."#, #"^[a-z]+://169\.254\."#,
        #"^[a-z]+://172\.1[6-9]\."#, #"^[a-z]+://172\.2[0-9]\."#, #"^[a-z]+://172\.3[01]\."#,
        #"^[a-z]+://localhost[:/]"#, #"^[a-z]+://[a-z0-9.-]*\.local[:/]"#,
        #"^[a-z]+://\[::1\]"#, #"^[a-z]+://\[f[cd]"#, #"^[a-z]+://\[fe[89ab]"#,
    ]

    static var localNetworkRules: String {
        let quoted = localNetworkPatterns.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\") + "\"" }
        let unless = "[" + quoted.joined(separator: ",") + "]"
        let rules = quoted.map { #"{"trigger":{"url-filter":\#($0),"unless-top-url":\#(unless)},"action":{"type":"block"}}"# }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

/// ページのスクリプト（PageScripts.watchCookies）からの「Cookie が変わったかも」という合図を受ける。
/// 中身は受け取らない。合図を受けたら onSignal（WebKit の置き場を読み直す）
final class CookieBridge: NSObject, WKScriptMessageHandler {
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 合図を受けたとき（画面のスレッドで呼ばれる）
    var onSignal: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let o = message.frameInfo.securityOrigin
        log?("🍪 ページの JavaScript が Cookie を変えました（\(o.protocol)://\(o.host)\(o.port == 0 ? "" : ":\(o.port)")）")
        onSignal?()
    }
}

/// エラーページのボタン・守りのスクリプトからの知らせを受ける
final class PageActionBridge: NSObject, WKScriptMessageHandler {
    /// (中身, メインフレームか, 送ってきたページのオリジン)。画面のスレッドで呼ばれる
    var onAction: (([String: Any], Bool, String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        let o = message.frameInfo.securityOrigin
        onAction?(d, message.frameInfo.isMainFrame, "\(o.protocol)://\(o.host)")
    }
}

/// WebKit の Cookie の置き場（正本）と CookieJar（写し）をそろえる
@MainActor
final class WebCookieSync: NSObject, WKHTTPCookieStoreObserver {
    let store: WKHTTPCookieStore
    let jar: CookieJar
    var log: (@Sendable (String) -> Void)?
    private var refreshScheduled = false
    /// WebKit の置き場に入れている途中の数（その間は写しを作り直さない。入れる前の中身で上書きしないため）
    private var pushing = 0
    private var refreshAfterPush = false

    init(store: WKHTTPCookieStore, jar: CookieJar) {
        self.store = store
        self.jar = jar
        super.init()
        store.add(self)
        refresh()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.scheduleRefresh() }
    }

    /// 少し待ってから読み直す（続けて変わったときに、何度も読まないように）
    func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let me = self
            Task { @MainActor in
                me?.refreshScheduled = false
                me?.refresh()
            }
        }
    }

    func refresh() {
        if pushing > 0 { refreshAfterPush = true; return }
        let s = store, j = jar
        Task { @MainActor in
            let all = await s.allCookies()
            j.replaceAll(all.compactMap { CookieRecord(httpCookie: $0) })
        }
    }

    /// VNet が受け取った Cookie の変更を、WebKit の置き場にも入れる
    func apply(_ changes: [CookieChange]) async {
        pushing += 1
        for ch in changes {
            guard let c = ch.record.httpCookie() else { log?("🍪 WebKit に渡せない Cookie: \(ch.record.name)"); continue }
            if ch.delete { await store.deleteCookie(c) } else { await store.setCookie(c) }
        }
        pushing -= 1
        if pushing == 0 && refreshAfterPush { refreshAfterPush = false; refresh() }
    }
}

// ======================================================================
// MARK: - NetPolicy.swift
// ======================================================================

// MARK: - 通信の決まり（セキュリティの判定）
//
// 画面や WebKit に頼らない「判定だけ」の部品。Linux のテスト（tools/tests）でも動かす。
//  SiteUtil           … ホスト名の正規化・「サイト」「オリジン」の判定
//  RequestContext     … 要求の文脈（トップのページ・トップレベルの移動か・リダイレクトの経路 など）
//  CookiePolicy       … Cookie を送るか・保存するか（SameSite・サードパーティ・送る順番）
//  SetCookieParser    … Set-Cookie の 1 行を CookieRecord にする（属性の検査も）
//  RedirectPolicy     … 3xx から次の要求を作る（ここ以外では作らない）
//  CORSPassthrough    … サーバーの CORS ヘッダをそのまま通す（Vela が許可を作らない）
//  LocalNetworkPolicy … Vela 独自のローカルネットワーク（LAN）への接続の制御（Chrome の PNA / LNA とは別物）

// MARK: - サイト・オリジン

enum SiteUtil {
    /// ホスト名をそろえる（小文字・末尾の「.」を外す・IPv6 の [ ] を外す）。
    /// IDN（日本語ドメインなど）は、WebKit から届く URL の時点で punycode（xn--…）になっているので、ここでは変換しない
    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func host(of url: URL) -> String? {
        guard let h = url.host, !h.isEmpty else { return nil }
        return normalizeHost(h)
    }

    /// host が domain そのもの、またはその下（a.domain）か。小文字にはしない（呼ぶ側でそろえる）
    static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// 先頭の「www.」を 1 回だけ外す。小文字にはしない（呼ぶ側でそろえる）
    static func stripWWW(_ s: String) -> String {
        s.hasPrefix("www.") ? String(s.dropFirst(4)) : s
    }

    /// IPv4 か IPv6 の数字のアドレスか
    static func isIPLiteral(_ host: String) -> Bool {
        let h = normalizeHost(host)
        return IPAddressText.v4(h) != nil || h.contains(":")
    }

    /// 2 段以上の「公開の末尾」（Public Suffix List の、よく使う所だけ）。ここに無いものは最後の 1 段を末尾とみなす
    static let multiLevelSuffixes: Set<String> = [
        // 日本
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "lg.jp", "gr.jp", "ad.jp",
        "tokyo.jp", "osaka.jp", "kyoto.jp", "aichi.jp", "kanagawa.jp", "hokkaido.jp", "fukuoka.jp", "saitama.jp", "chiba.jp", "hyogo.jp",
        // ほかの国
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.sg", "edu.sg", "gov.sg", "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "co.id", "or.id", "ac.id", "go.id", "co.th", "or.th", "ac.th", "go.th", "in.th",
        "com.my", "com.mx", "com.ar", "co.za", "com.tr", "com.vn", "com.ph", "com.ua", "co.il",
        // 誰でも下にサイトを作れる所（別のサイトとして扱う）
        "github.io", "githubusercontent.com", "blogspot.com", "herokuapp.com", "netlify.app", "vercel.app",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net",
        "appspot.com", "glitch.me", "gitlab.io", "s3.amazonaws.com", "fly.dev", "onrender.com", "repl.co",
    ]

    /// 公開の末尾そのものか（例: "jp"・"co.jp"・"github.io"）。Cookie の Domain に使えない
    static func isPublicSuffix(_ domain: String) -> Bool {
        let d = normalizeHost(domain)
        if d.isEmpty { return true }
        if !d.contains(".") { return !isIPLiteral(d) && d != "localhost" }
        return multiLevelSuffixes.contains(d)
    }

    /// 「登録できるドメイン」（サイトの単位）。www.example.co.jp → example.co.jp、a.b.example.com → example.com
    static func registrableDomain(_ host: String) -> String {
        let h = normalizeHost(host)
        if isIPLiteral(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count <= 2 {
            // "co.jp" のように末尾そのもの・"example.com"・"localhost"
            return h
        }
        // 長い末尾から順に見る（"s3.amazonaws.com" のような 3 段もある）
        for n in stride(from: min(3, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if multiLevelSuffixes.contains(suffix) { return labels.suffix(n + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// 同じサイトか（スキームは見ない。WebKit の「サードパーティ」の考え方と同じ）
    static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let ha = host(of: a), let hb = host(of: b) else { return false }
        return registrableDomain(ha) == registrableDomain(hb)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https", "wss", "vnets": return 443
        case "http", "ws", "vnet": return 80
        default: return nil
        }
    }

    /// オリジン（"https://example.com" ・ 既定でないポートなら ":8443" も付ける）
    static func origin(of url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), let h = host(of: url) else { return nil }
        let hostText = h.contains(":") ? "[\(h)]" : h
        if let p = url.port, p != defaultPort(s) { return "\(s)://\(hostText):\(p)" }
        return "\(s)://\(hostText)"
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        return oa == ob
    }

    static func isSecureScheme(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        return s == "https" || s == "wss" || s == "vnets"
    }
}

/// 数字のアドレスを読む
enum IPAddressText {
    /// "192.168.0.1" → [192, 168, 0, 1]
    static func v4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// IPv6 を 8 個の 16 ビットにする（"::" の省略・末尾の IPv4 表記・"%zone" に対応）
    static func v6(_ text: String) -> [UInt16]? {
        var s = SiteUtil.normalizeHost(text)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard s.contains(":") else { return nil }
        var tail4: [UInt16] = []
        if let lastColon = s.lastIndex(of: ":"), let v4 = v4(String(s[s.index(after: lastColon)...])) {
            tail4 = [UInt16(v4[0]) << 8 | UInt16(v4[1]), UInt16(v4[2]) << 8 | UInt16(v4[3])]
            s = String(s[...lastColon]) + "0:0"   // IPv4 の分（16 ビット 2 個）を形だけ置いておき、あとで差し替える
        }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ t: String) -> [UInt16]? {
            if t.isEmpty { return [] }
            var g: [UInt16] = []
            for p in t.split(separator: ":", omittingEmptySubsequences: false) {
                guard !p.isEmpty, p.count <= 4, let v = UInt16(p, radix: 16) else { return nil }
                g.append(v)
            }
            return g
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let back = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - back.count
            guard fill >= 1 else { return nil }
            all = head + Array(repeating: 0, count: fill) + back
        } else {
            all = head
        }
        guard all.count == 8 else { return nil }
        if !tail4.isEmpty { all.removeLast(); all.removeLast(); all += tail4 }
        return all
    }
}

// MARK: - 要求の文脈

/// 要求がどんな場面で出たか。Cookie・リダイレクト・LAN の判定に使う
struct RequestContext: Sendable {
    /// トップのページの URL（WebKit の mainDocumentURL）
    var topURL: URL?
    /// トップレベルの移動（ページそのものを開く要求）か
    var isTopLevel = false
    /// 要求を出したページ（Referer）。トップレベルの移動で、どこから来たかを見るのに使う
    var initiator: URL?
    /// リダイレクトの経路で、一度でもクロスサイトになったか（なったら、そのあとはずっとクロスサイト扱い）
    var crossSiteChain = false
    /// Cookie を送受信してよいか（URLRequest.httpShouldHandleCookies。Fetch の credentials: omit と同じものではない）
    var cookiesAllowed = true
    /// ユーザーがアドレス欄・ブックマークなどから開いた移動か（ページのリンクや JavaScript ではない）
    var userInitiated = false
    /// リダイレクトのとき、1 つ前の URL
    var previousURL: URL?
    /// どのタブの要求か（ログ用）
    var tabID = 0

    init(topURL: URL? = nil, isTopLevel: Bool = false, initiator: URL? = nil) {
        self.topURL = topURL
        self.isTopLevel = isTopLevel
        self.initiator = initiator
    }

    /// リダイレクトで次の URL に進んだときの文脈
    func redirected(from: URL, to next: URL) -> RequestContext {
        var c = self
        if !SiteUtil.isSameSite(from, next) { c.crossSiteChain = true }
        c.previousURL = from
        // トップレベルの移動なら、トップのページは移動先になる
        if isTopLevel { c.topURL = next }
        return c
    }
}

// MARK: - Cookie

/// Cookie 1 つ（WebKit の置き場の写し・Set-Cookie から作ったもの）
struct CookieRecord: Sendable, Equatable {
    enum SameSite: String, Sendable { case unspecified, none, lax, strict }

    var name: String
    var value: String
    /// 先頭の「.」は外した形（小文字）
    var domain: String
    /// Domain 属性が無かった（このホストだけに送る）
    var hostOnly: Bool
    var path: String
    var secure = false
    var httpOnly = false
    var sameSite = SameSite.unspecified
    /// nil ならセッションの間だけ
    var expires: Date?
    /// 作られた時刻（送る順番に使う。WebKit の置き場には無いので、写しで覚える）
    var created: Date

    var key: String { "\(name)\u{1}\(domain)\u{1}\(path)" }

    func isExpired(_ now: Date) -> Bool {
        if let e = expires { return e <= now }
        return false
    }

    /// このホストに送ってよいドメインか
    func domainMatches(_ host: String) -> Bool {
        let h = SiteUtil.normalizeHost(host)
        if hostOnly { return h == domain }
        if h == domain { return true }
        return !SiteUtil.isIPLiteral(h) && h.hasSuffix("." + domain)
    }

    /// このパスに送ってよいか（RFC 6265 5.1.4）
    func pathMatches(_ requestPath: String) -> Bool {
        let p = requestPath.isEmpty ? "/" : requestPath
        if p == path { return true }
        guard p.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        return p.dropFirst(path.count).first == "/"
    }
}

/// Set-Cookie の 1 行を読む（RFC 6265 / 6265bis）。だめな Cookie は nil と理由
enum SetCookieParser {
    static let maxNameValueBytes = 4096

    enum Outcome {
        case cookie(CookieRecord)
        case rejected(String)
    }

    static func parse(_ line: String, url: URL, now: Date = Date()) -> Outcome {
        guard let host = SiteUtil.host(of: url) else { return .rejected("ホスト名がありません") }
        var parts = line.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        let pair = parts.removeFirst()
        var name = "", value = ""
        if let eq = pair.firstIndex(of: "=") {
            name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else {
            value = pair.trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty && value.isEmpty { return .rejected("名前も値もありません") }
        if name.utf8.count + value.utf8.count > maxNameValueBytes { return .rejected("大きすぎます") }
        if (name + value).unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) {
            return .rejected("制御文字が入っています")
        }

        var rec = CookieRecord(name: name, value: value, domain: host, hostOnly: true, path: defaultPath(url), created: now)
        var maxAge: Int?
        var expires: Date?
        for raw in parts {
            let a = raw.trimmingCharacters(in: .whitespaces)
            if a.isEmpty { continue }
            let k: String, v: String
            if let eq = a.firstIndex(of: "=") {
                k = String(a[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                v = String(a[a.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                k = a.lowercased(); v = ""
            }
            switch k {
            case "expires": if let d = HTTPDate.parse(v) { expires = d }
            case "max-age":
                if let n = Int(v) { maxAge = n }
            case "domain":
                var d = v.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                d = SiteUtil.normalizeHost(d)
                if d.isEmpty { continue }
                if SiteUtil.isPublicSuffix(d) {
                    if d == host { continue }          // ホストそのものなら、このホストだけの Cookie として受ける
                    return .rejected("公開の末尾（\(d)）には付けられません")
                }
                let probe = CookieRecord(name: "", value: "", domain: d, hostOnly: false, path: "/", created: now)
                guard probe.domainMatches(host) else { return .rejected("Domain=\(d) はこのホスト（\(host)）に合いません") }
                rec.domain = d
                rec.hostOnly = SiteUtil.isIPLiteral(host)   // IP のときは Domain があってもそのアドレスだけ
            case "path":
                if v.hasPrefix("/") { rec.path = v }
            case "secure": rec.secure = true
            case "httponly": rec.httpOnly = true
            case "samesite":
                switch v.lowercased() {
                case "strict": rec.sameSite = .strict
                case "lax": rec.sameSite = .lax
                case "none": rec.sameSite = .none
                default: rec.sameSite = .unspecified
                }
            default: break
            }
        }
        if let m = maxAge { rec.expires = m <= 0 ? Date(timeIntervalSince1970: 0) : now.addingTimeInterval(TimeInterval(m)) }
        else if let e = expires { rec.expires = e }

        let secureURL = SiteUtil.isSecureScheme(url)
        if rec.secure && !secureURL { return .rejected("Secure の Cookie は https からしか作れません") }
        if rec.sameSite == .none && !rec.secure { return .rejected("SameSite=None には Secure が必要です") }
        if name.hasPrefix("__Secure-") && !(rec.secure && secureURL) { return .rejected("__Secure- には Secure が必要です") }
        if name.hasPrefix("__Host-") && !(rec.secure && secureURL && rec.hostOnly && rec.path == "/") {
            return .rejected("__Host- には Secure・Domain なし・Path=/ が必要です")
        }
        return .cookie(rec)
    }

    /// 既定の Path（RFC 6265 5.1.4: 最後の「/」の手前まで）
    static func defaultPath(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard p.hasPrefix("/"), let last = p.lastIndex(of: "/"), last != p.startIndex else { return "/" }
        return String(p[..<last])
    }
}

/// http の日付（Expires）を読む
enum HTTPDate {
    private static let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                  "EEE MMM d HH:mm:ss yyyy", "EEE, dd MMM yy HH:mm:ss zzz", "EEE, dd-MMM-yy HH:mm:ss zzz",
                                  "dd MMM yyyy HH:mm:ss zzz"]
    private static let formatters: [DateFormatter] = formats.map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "GMT")
        d.dateFormat = f
        return d
    }
    private static let lock = NSLock()

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        for f in formatters { if let d = f.date(from: t) { return d } }
        return nil
    }
}

enum CookiePolicy {
    struct Settings: Sendable, Equatable {
        /// サードパーティ Cookie を保存も送信もしない（Safari の ITP や Storage Access API の例外までは再現しない）
        var blockThirdParty = true
        /// SameSite が無い Cookie を Lax として扱う
        var laxByDefault = true
        /// Lax-by-default の例外: 作られてからこの秒数の間は、クロスサイトのトップレベルの POST にも付ける（0 で例外なし）
        var laxPostGrace: TimeInterval = 120
        init() {}
    }

    static let safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "TRACE"]

    /// この要求はクロスサイトか（SameSite の判定用）
    static func isCrossSite(_ url: URL, method: String, ctx: RequestContext) -> Bool {
        if ctx.crossSiteChain { return true }
        if ctx.isTopLevel {
            // どこから来たかで決める。分からないとき: 安全なメソッドならユーザーの操作とみなす、それ以外はクロスサイト扱い
            if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
            if ctx.userInitiated { return false }
            return !safeMethods.contains(method.uppercased())
        }
        if let t = ctx.topURL { return !SiteUtil.isSameSite(t, url) }
        if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
        return false
    }

    /// サードパーティの要求か（ページの中の部品・iframe が、トップと別のサイトのもの）
    static func isThirdParty(_ url: URL, ctx: RequestContext) -> Bool {
        if ctx.isTopLevel { return false }
        if ctx.crossSiteChain { return true }
        guard let t = ctx.topURL else { return false }
        return !SiteUtil.isSameSite(t, url)
    }

    /// 1 つの Cookie を送るか。送らないなら理由
    static func sendDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext,
                             settings: Settings, now: Date = Date()) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if c.isExpired(now) { return "期限切れ" }
        guard let host = SiteUtil.host(of: url), c.domainMatches(host) else { return "ドメインが合わない" }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if !c.pathMatches(path) { return "パスが合わない" }
        if c.secure && !SiteUtil.isSecureScheme(url) { return "Secure なのに https でない" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        guard isCrossSite(url, method: method, ctx: ctx) else { return nil }
        let topLevelSafe = ctx.isTopLevel && safeMethods.contains(method.uppercased())
        switch c.sameSite {
        case .strict:
            return "SameSite=Strict でクロスサイト"
        case .lax:
            return topLevelSafe ? nil : "SameSite=Lax でクロスサイト"
        case .none:
            return nil
        case .unspecified:
            if !settings.laxByDefault { return nil }
            if topLevelSafe { return nil }
            if ctx.isTopLevel && method.uppercased() == "POST" && settings.laxPostGrace > 0
                && now.timeIntervalSince(c.created) <= settings.laxPostGrace { return nil }
            return "SameSite なし（Lax 扱い）でクロスサイト"
        }
    }

    /// 送る Cookie を順番に並べる（パスが長い順 → 作られた順）
    static func cookiesToSend(_ jar: [CookieRecord], url: URL, method: String, ctx: RequestContext,
                              settings: Settings, now: Date = Date()) -> (send: [CookieRecord], skipped: [(String, String)]) {
        var send: [CookieRecord] = []
        var skipped: [(String, String)] = []
        for c in jar {
            if let why = sendDecision(c, url: url, method: method, ctx: ctx, settings: settings, now: now) {
                // ドメイン・パスが合わないものはログに出さない（関係ない Cookie なので）
                if why != "ドメインが合わない" && why != "パスが合わない" && why != "期限切れ" { skipped.append((c.name, why)) }
            } else {
                send.append(c)
            }
        }
        send.sort { a, b in a.path.count != b.path.count ? a.path.count > b.path.count : a.created < b.created }
        return (send, skipped)
    }

    static func header(_ cookies: [CookieRecord]) -> String? {
        if cookies.isEmpty { return nil }
        return cookies.map { $0.name.isEmpty ? $0.value : "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 届いた Cookie を保存してよいか。だめなら理由
    static func storeDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext, settings: Settings) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        // クロスサイトの部品の応答からは、SameSite=Lax / Strict の Cookie を作らせない（6265bis）
        if !ctx.isTopLevel && isCrossSite(url, method: method, ctx: ctx) && (c.sameSite == .lax || c.sameSite == .strict) {
            return "クロスサイトの部品からの SameSite=\(c.sameSite.rawValue)"
        }
        return nil
    }
}

// MARK: - リダイレクト

enum RedirectPolicy {
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    static let maxRedirects = 20
    /// 本体に関するヘッダ（メソッドが GET に変わったら外す）
    static let bodyHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "content-language", "content-location"]
    /// オリジンが変わったら外す
    static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]

    struct Next: Sendable {
        var url: URL
        var method: String
        var headers: [(String, String)]
        var body: Data?
        var crossOrigin: Bool
        var upgradedByHSTS: Bool
        /// 外したヘッダの名前（ログ用）
        var dropped: [String]
    }

    enum Failure: Error, Equatable, Sendable {
        case noLocation, badLocation(String), unsupportedScheme(String), tooMany
    }

    /// 3xx の応答から、次の要求を作る
    /// - hsts: そのホストを https に上げるべきか
    static func next(from url: URL, method: String, headers: [(String, String)], body: Data?, status: Int,
                     location: String?, redirectCount: Int, hsts: (String) -> Bool = { _ in false }) -> Result<Next, Failure> {
        if redirectCount >= maxRedirects { return .failure(.tooMany) }
        guard let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else { return .failure(.noLocation) }
        guard var nextURL = URL(string: loc, relativeTo: url)?.absoluteURL else { return .failure(.badLocation(loc)) }
        let scheme = nextURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        var upgraded = false
        if scheme == "http", let h = SiteUtil.host(of: nextURL), hsts(h), var c = URLComponents(url: nextURL, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            if let u = c.url { nextURL = u; upgraded = true }
        }

        var m = method.uppercased()
        var b = body
        var drop = Set<String>()
        if status == 303 && m != "HEAD" || (status == 301 || status == 302) && m == "POST" {
            m = "GET"
            b = nil
            drop.formUnion(bodyHeaders)
        }
        let crossOrigin = !SiteUtil.isSameOrigin(url, nextURL)
        // Cookie は移動先で CookiePolicy がもう一度決める（前の相手のものを持ち越さない）
        drop.insert("cookie")
        if crossOrigin { drop.formUnion(credentialHeaders) }

        var out: [(String, String)] = []
        var dropped: [String] = []
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "host" { continue }
            if drop.contains(lk) { dropped.append(k); continue }
            switch lk {
            case "origin":
                // クロスオリジンに移ったら、元のオリジンは「null」にする（Fetch の仕様）
                if crossOrigin, let target = SiteUtil.origin(of: nextURL), v != target { out.append((k, "null")) } else { out.append((k, v)) }
            case "referer":
                guard let ref = URL(string: v) else { dropped.append(k); continue }
                if SiteUtil.isSecureScheme(ref) && !SiteUtil.isSecureScheme(nextURL) { dropped.append(k); continue }  // https → http では送らない
                if !SiteUtil.isSameOrigin(ref, nextURL), let o = SiteUtil.origin(of: ref) { out.append((k, o + "/")) }  // 別オリジンにはオリジンだけ
                else { out.append((k, v)) }
            default:
                out.append((k, v))
            }
        }
        return .success(Next(url: nextURL, method: m, headers: out, body: b, crossOrigin: crossOrigin, upgradedByHSTS: upgraded, dropped: dropped))
    }
}

// MARK: - CORS

/// サーバーの Access-Control-* をそのまま通す。Vela が自分で許可を作ることはしない
enum CORSPassthrough {
    /// vnetsMode: 予備の vnets:// 方式（開発者向け）。そのときだけ、許可されたオリジンの https:// を vnets:// に読み替える
    static func headers(_ server: [(String, String)], vnetsMode: Bool) -> [(String, String)] {
        server.compactMap { k, v in
            let lk = k.lowercased()
            guard lk.hasPrefix("access-control-") else { return nil }
            if vnetsMode && lk == "access-control-allow-origin" {
                if v.lowercased().hasPrefix("https://") { return (k, "vnets://" + v.dropFirst(8)) }
                if v.lowercased().hasPrefix("http://") { return (k, "vnet://" + v.dropFirst(7)) }
            }
            return (k, v)
        }
    }
}

// MARK: - ローカルネットワーク（LAN）

/// アドレスの種類
enum IPClass: String, Sendable {
    case publicAddress = "公開"
    case privateAddress = "LAN"
    case loopback = "ループバック"
    case linkLocal = "リンクローカル"
    /// VNet の中（10.0.2.x。ルーター・DNS など）
    case vnetInternal = "VNet 内部"
    case unspecified = "未指定"

    /// LAN 側（公開でない）か
    var isLocal: Bool { self != .publicAddress }
}

/// Vela 独自のローカルネットワークへの接続の制御（Chrome の Private Network Access / Local Network Access とは別物）
enum LocalNetworkPolicy {
    static func classify(_ ip: [UInt8]) -> IPClass {
        guard ip.count == 4 else { return .publicAddress }
        switch (ip[0], ip[1]) {
        case (0, _): return .unspecified
        case (10, 0) where ip[2] == 2: return .vnetInternal
        case (10, _): return .privateAddress
        case (127, _): return .loopback
        case (169, 254): return .linkLocal
        case (172, 16...31): return .privateAddress
        case (192, 168): return .privateAddress
        case (100, 64...127): return .privateAddress          // CGNAT（100.64/10）
        default: return ip[0] >= 224 ? .unspecified : .publicAddress   // マルチキャストなど
        }
    }

    static func classify(v6 g: [UInt16]) -> IPClass {
        guard g.count == 8 else { return .publicAddress }
        if g.allSatisfy({ $0 == 0 }) { return .unspecified }
        if g[0..<7].allSatisfy({ $0 == 0 }) && g[7] == 1 { return .loopback }
        if g[0..<5].allSatisfy({ $0 == 0 }) && g[5] == 0xFFFF {        // ::ffff:a.b.c.d
            return classify([UInt8(g[6] >> 8), UInt8(g[6] & 0xFF), UInt8(g[7] >> 8), UInt8(g[7] & 0xFF)])
        }
        if g[0] & 0xFE00 == 0xFC00 { return .privateAddress }           // fc00::/7（ULA）
        if g[0] & 0xFFC0 == 0xFE80 { return .linkLocal }                // fe80::/10
        if g[0] & 0xFF00 == 0xFF00 { return .unspecified }              // マルチキャスト
        return .publicAddress
    }

    /// ホスト名だけで分かるときの種類（数字のアドレス・localhost・.local）。名前を引かないと分からないなら nil
    static func classify(host: String) -> IPClass? {
        let h = SiteUtil.normalizeHost(host)
        if let v4 = IPAddressText.v4(h) { return classify(v4) }
        if let v6 = IPAddressText.v6(h) { return classify(v6: v6) }
        if h == "localhost" || h.hasSuffix(".localhost") { return .loopback }
        if h.hasSuffix(".local") || h.hasSuffix(".home.arpa") { return .privateAddress }
        return nil
    }

    enum Decision: Equatable, Sendable {
        case allow
        case block(String)
        /// トップレベルの移動: ユーザーに確かめてから
        case askUser(String)
    }

    /// target: 接続先のアドレスの種類。topClass: トップのページの種類。fromClass: 1 つ前（リダイレクト元・移動を起こしたページ）の種類
    static func decide(target: IPClass, ctx: RequestContext, topClass: IPClass?, fromClass: IPClass?) -> Decision {
        guard target.isLocal else { return .allow }
        if target == .vnetInternal || target == .unspecified { return .block("\(target.rawValue)のアドレスには接続しません") }
        if ctx.isTopLevel {
            if ctx.userInitiated && ctx.previousURL == nil { return .allow }     // アドレス欄から直接
            if let f = fromClass, f.isLocal { return .allow }                     // LAN のページから LAN へ
            if ctx.previousURL != nil && fromClass == .publicAddress {
                return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト")
            }
            return .askUser("ページが LAN（\(target.rawValue)）へ移動しようとしています")
        }
        if let t = topClass, t.isLocal { return .allow }                          // LAN のページの部品
        if ctx.previousURL != nil { return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト") }
        return .block("公開のサイトから LAN（\(target.rawValue)）の部品を読み込もうとしました")
    }
}

// ======================================================================
// MARK: - CookieJar.swift
// ======================================================================

// MARK: - Cookie の写し（正本は WebKit の WKHTTPCookieStore）
//
// ・正本は WebKit の置き場だけ。ここはその写しで、VNet が要求を送るとき（vnet-guest のキュー）に、待たずに読めるようにするためのもの
// ・WebKit の置き場が変わったら（WKHTTPCookieStoreObserver）、写しを作り直す（replaceAll）。この同期は WebCookieSync（PageScripts.swift）がやる
// ・VNet の応答の Set-Cookie は、CookiePolicy で許されたものだけを写しに入れて、変更（CookieChange）として返す。
//   呼んだ側が WebKit の置き場にも入れる（入れ終わってから、ページに返事を渡す）
// ・ページの JavaScript から届く「Cookie の文字列」は、一切ここに入れない（HttpOnly や Domain を偽れるため）

/// 写しの変更（WebKit の置き場にも同じことをする）
struct CookieChange: Sendable {
    var record: CookieRecord
    /// true なら消す
    var delete: Bool
}

final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: CookieRecord] = [:]
    private var _settings = CookiePolicy.Settings()
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?

    init() {}

    var settings: CookiePolicy.Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return cookies.count }

    func snapshot() -> [CookieRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(cookies.values)
    }

    /// 送る Cookie ヘッダ（送らないものがあれば理由も返す）
    func header(for url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> (header: String?, skipped: [(String, String)]) {
        lock.lock()
        let all = Array(cookies.values)
        let s = _settings
        lock.unlock()
        let (send, skipped) = CookiePolicy.cookiesToSend(all, url: url, method: method, ctx: ctx, settings: s, now: now)
        return (CookiePolicy.header(send), skipped)
    }

    /// 応答の Set-Cookie を受け取る。許されたものを写しに入れ、変更を返す
    func receive(_ lines: [String], url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> [CookieChange] {
        var changes: [CookieChange] = []
        let s = settings
        for (i, line) in lines.enumerated() {
            // 同じ返事の中の Cookie は、届いた順に作られたことにする（送る順番が毎回変わらないように、1 マイクロ秒ずつずらす）
            switch SetCookieParser.parse(line, url: url, now: now.addingTimeInterval(Double(i) * 1e-6)) {
            case .rejected(let why):
                log?("🍪✕ 受け取らない（\(SiteUtil.host(of: url) ?? "")）: \(why)")
            case .cookie(var rec):
                if let why = CookiePolicy.storeDecision(rec, url: url, method: method, ctx: ctx, settings: s) {
                    log?("🍪✕ 保存しない \(rec.name)（\(rec.domain)）: \(why)")
                    continue
                }
                lock.lock()
                if rec.isExpired(now) {
                    let old = cookies.removeValue(forKey: rec.key)
                    lock.unlock()
                    changes.append(CookieChange(record: old ?? rec, delete: true))
                    continue
                }
                // 置き換えるときは、最初に作られた時刻を引き継ぐ（RFC 6265 5.3 の 11.3）
                if let old = cookies[rec.key] { rec.created = old.created }
                cookies[rec.key] = rec
                lock.unlock()
                changes.append(CookieChange(record: rec, delete: false))
            }
        }
        return changes
    }

    /// WebKit の置き場の中身で写しを作り直す。作られた時刻と、WebKit が覚えていない SameSite は、前の写しから引き継ぐ
    func replaceAll(_ records: [CookieRecord], now: Date = Date()) {
        lock.lock()
        var next: [String: CookieRecord] = [:]
        for var r in records where !r.isExpired(now) {
            if let old = cookies[r.key] {
                r.created = old.created
                if r.sameSite == .unspecified { r.sameSite = old.sameSite }
            }
            next[r.key] = r
        }
        cookies = next
        lock.unlock()
    }

    func removeAll() {
        lock.lock(); cookies = [:]; lock.unlock()
    }
}

// MARK: - HTTPCookie との変換

extension CookieRecord {
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
    private static let sameSiteKey = HTTPCookiePropertyKey("SameSite")

    /// WebKit の置き場の HTTPCookie から作る（作られた時刻は分からないので now）
    init?(httpCookie c: HTTPCookie, now: Date = Date()) {
        var d = c.domain.lowercased()
        let hostOnly = !d.hasPrefix(".")
        while d.hasPrefix(".") { d.removeFirst() }
        if d.isEmpty { return nil }
        var ss = SameSite.unspecified
        #if canImport(Darwin)
        if let p = c.sameSitePolicy {
            if p == .sameSiteStrict { ss = .strict } else if p == .sameSiteLax { ss = .lax } else if p.rawValue.lowercased() == "none" { ss = .none }
        }
        #else
        if let p = c.properties?[CookieRecord.sameSiteKey] as? String {
            switch p.lowercased() { case "strict": ss = .strict; case "lax": ss = .lax; case "none": ss = .none; default: break }
        }
        #endif
        self.init(name: c.name, value: c.value, domain: SiteUtil.normalizeHost(d), hostOnly: hostOnly, path: c.path.isEmpty ? "/" : c.path,
                  secure: c.isSecure, httpOnly: c.isHTTPOnly, sameSite: ss, expires: c.expiresDate, created: now)
    }

    /// WebKit の置き場に入れる HTTPCookie にする
    func httpCookie() -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .path: path]
        if hostOnly {
            // Domain 属性なし（このホストだけ）: 先頭に「.」を付けない
            p[.domain] = domain
        } else {
            p[.domain] = "." + domain
        }
        if secure { p[.secure] = "TRUE" }
        if let e = expires { p[.expires] = e } else { p[.discard] = "TRUE" }
        if httpOnly { p[CookieRecord.httpOnlyKey] = "TRUE" }
        #if canImport(Darwin)
        switch sameSite {
        case .strict: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .lax: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .none, .unspecified: break
        }
        #else
        switch sameSite {
        case .strict: p[CookieRecord.sameSiteKey] = "strict"
        case .lax: p[CookieRecord.sameSiteKey] = "lax"
        case .none, .unspecified: break
        }
        #endif
        return HTTPCookie(properties: p)
    }
}

// ======================================================================
// MARK: - HSTSStore.swift
// ======================================================================

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
            let k: String, v: String
            if let eq = d.firstIndex(of: "=") {
                k = d[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                v = d[d.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else {
                k = d.lowercased(); v = ""
            }
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

// ======================================================================
// MARK: - HTTPClient.swift
// ======================================================================

// MARK: - 自作の TCP/IP（GuestStack）の上の http / https
//
// 速くするための工夫:
// ・接続を使い回す（HTTP/1.1 の keep-alive）。https は暗号の握手（TLS）に時間がかかるので、とても効く
// ・同じ相手には同時に 6 本まで（ブラウザと同じ）。それ以上は空くまで待つ
// ・名前（DNS）の答えを覚えておく
// ・gzip・br で縮めて送ってもらう（HTML・JavaScript・CSS が数分の 1 になる）
// ほかに: クッキーを送る（CookieJar と CookiePolicy で判定）・リダイレクトを追いかける（RedirectPolicy）・POST も送れる
// 守り: 名前を引いた後、LAN への接続を LocalNetworkPolicy で判定する（DNS リバインディングも、ここで止める）
// 「ロボットだ」と思われないよう、ヘッダは Safari と同じものを、毎回同じ順番で送る
// 返事が来ないまま止まった接続は、時間切れで切る（でないと、その相手への読み込みがずっと止まる）

struct HTTPRequest: Sendable {
    var method = "GET"
    var url: URL
    var headers: [(String, String)] = []
    var body: Data?
    /// どんな場面の要求か（Cookie・リダイレクト・LAN の判定に使う）
    var context = RequestContext()
    /// 取り消しの印（WebKit が読み込みをやめたら cancel される）
    var token: RequestToken?
    /// 流す形で受け取る相手（nil なら全部貯めてから返す）
    var sink: StreamSink?
}

/// 流す形にした返事のヘッダ
struct HTTPHead: Sendable {
    var status: Int
    /// 中身を戻すときは Content-Encoding・Content-Length を外してある
    var headers: [(String, String)]
    var url: URL
    /// この返事で CookieJar に入れた Cookie の変更（WebKit の置き場にも入れてから、ページに返事を渡すこと）
    var cookieChanges: [CookieChange]
    func header(_ name: String) -> String? { headers.value(for: name) }
}

/// 流す形で受け取る相手（VNetScheme）。どれも stack.queue の上で呼ばれる
final class StreamSink: @unchecked Sendable {
    /// ヘッダを見て、流す形にするか（3xx などは貯めて、追いかけたり WebKit に移動として渡したりする）
    let shouldStream: (_ status: Int, _ headers: [(String, String)]) -> Bool
    /// 流す形にした返事のヘッダ（中身より先に 1 回だけ）
    let onHead: (HTTPHead) -> Void
    /// 中身（戻したもの。届いた分ずつ）
    let onData: (Data) -> Void

    init(shouldStream: @escaping (_ status: Int, _ headers: [(String, String)]) -> Bool,
         onHead: @escaping (HTTPHead) -> Void, onData: @escaping (Data) -> Void) {
        self.shouldStream = shouldStream
        self.onHead = onHead
        self.onData = onData
    }
}

struct HTTPResult: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var url: URL
    /// CookieJar に入れた Cookie の変更（リダイレクトの途中の分も）。ブラウザ（WebKit）の Cookie の置き場にも同じことをする
    var cookieChanges: [CookieChange] = []
    /// 中身は流す形で StreamSink に渡した（body は空）
    var streamed = false
    func header(_ name: String) -> String? { headers.value(for: name) }
}

struct FetchError: Error, Sendable, CustomStringConvertible {
    /// 失敗の種類（エラーページの説明・標準の通信へ切り替える案内に使う）
    enum Kind: String, Sendable {
        case other, dns, timeout, tls, connect, reset, malformed, tooLarge, redirect, notReady, cancelled
        /// TLS の版が合わない（相手が TLS 1.3 だけなど。VNet の TLS は 1.2 まで）
        case tlsVersion
        /// 決まり（LAN の保護など）で止めた
        case blocked
        /// ページが LAN へ移動しようとした。ユーザーが許可すれば開ける
        case localNetworkConsent
        /// 要求が多すぎて受け付けられない（待ち行列がいっぱい）
        case busy
    }
    let description: String
    var kind: Kind
    init(_ description: String, kind: Kind = .other) { self.description = description; self.kind = kind }
}

// MARK: - 1 本の接続

/// 1 本の接続（TCP、https ならその上に TLS）。使い終わったら、次の要求に使い回す
final class HTTPConn: @unchecked Sendable {
    /// 返事を読み終わった（または失敗した）。reusable: 次の要求に使える。gotNothing: 何も届かずに切れた
    typealias Completion = (Result<ResponseParser, FetchError>, _ reusable: Bool, _ gotNothing: Bool) -> Void

    let key: String
    private(set) var alive = true
    private(set) var uses = 0
    /// 最後に何か届いた（または送り始めた）時刻。時間切れを見る
    private var lastActivity = Date()
    /// 使い終わって置き場に戻った時刻
    var idleSince = Date()
    /// 何回目の要求か（時間切れの見張りが、前の要求の分を見ないように）
    private var serial = 0
    private var queue: DispatchQueue?
    /// 返事を待っている間に、これだけ何も届かなければ切る（秒）
    static let timeout: TimeInterval = 30
    private var tcp: GuestTCP?
    private var tls: TLSStream?
    private var ready = false
    /// TCP がつながったか（失敗の種類を「つながらない」と「途中で切れた」に分ける）
    private var tcpConnected = false
    private var queued: Data?
    private var parser: ResponseParser?
    private var onDone: Completion?

    init(key: String) { self.key = key }

    func open(stack: GuestStack, ip: [UInt8], port: UInt16, host: String, https: Bool) {
        queue = stack.queue
        guard https else {
            tcp = stack.connect(ip, port, handler: .init(
                connected: { [weak self] in self?.tcpConnected = true; self?.becameReady() },
                data: { [weak self] d in self?.got(d) },
                closed: { [weak self] err in self?.ended(err) }))
            return
        }
        guard let t = TLSStream(host: host, port: port) else { fail("TLS を用意できません", kind: .tls); return }
        tls = t
        t.onReady = { [weak self, weak t] in
            stack.trace?("TLS つながった（\(host)・\(t?.version ?? "")）")
            self?.becameReady()
        }
        t.onData = { [weak self] d in self?.got(d) }
        t.onClosed = { [weak self] err in self?.ended(err) }
        tcp = stack.connect(ip, port, handler: .init(
            connected: { [weak self] in guard let self, let tc = self.tcp else { return }; self.tcpConnected = true; self.tls?.attach(tc) },
            data: { [weak self] d in self?.lastActivity = Date(); self?.tls?.tcpData(d) },
            closed: { [weak self] err in self?.tls?.tcpClosed(err) }))
    }

    /// 要求を 1 つ送る（返事を読み終わったら done）。何回目の要求か（取り消しに使う番号）を返す
    /// onGrow: 返事の中身が増えたとき（増えたバイト数）
    @discardableResult
    /// decide: ヘッダを読んだところで呼ぶ。中身を受け取る関数を返したら、流す形にする
    func send(_ bytes: Data, isHead: Bool, limits: ResponseParser.Limits = ResponseParser.Limits(),
              onGrow: ((Int) -> Void)? = nil, decide: ((ResponseParser) -> ((Data) -> Void)?)? = nil,
              done: @escaping Completion) -> Int {
        uses += 1
        serial += 1
        if !alive { done(.failure(FetchError("接続が閉じています", kind: .reset)), false, true); return serial }
        let p = ResponseParser(isHead: isHead, limits: limits)
        p.onBodyGrow = onGrow
        if let decide {
            p.decideStreaming = { [unowned p] in
                guard let h = decide(p) else { return false }
                p.onChunk = h
                return true
            }
        }
        parser = p
        onDone = done
        lastActivity = Date()
        watch(serial)
        if ready { write(bytes) } else { queued = bytes }
        return serial
    }

    /// 読んでいる途中の要求を取り消す（その要求の番号のときだけ）。接続は切って、使い回さない
    func cancel(serial s: Int) {
        guard s == serial, onDone != nil else { return }
        alive = false
        finishCurrent(.failure(HTTPPool.cancelled), reusable: false)
        tcp?.abort()
    }

    /// 時間切れの見張り（5 秒ごと）。返事を待っている間に長く何も届かなければ切る
    private func watch(_ s: Int) {
        queue?.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.serial == s, self.onDone != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) < HTTPConn.timeout { self.watch(s); return }
            self.alive = false
            self.finishCurrent(.failure(FetchError("時間切れ（\(Int(HTTPConn.timeout)) 秒なにも届きません）", kind: .timeout)), reusable: false)
            self.tcp?.abort()
        }
    }

    func close() {
        alive = false
        tcp?.close()
    }

    private func write(_ d: Data) {
        if let tls { tls.write(d) } else { tcp?.write(d) }
    }

    private func becameReady() {
        ready = true
        if let q = queued { queued = nil; write(q) }
    }

    private func got(_ d: Data) {
        lastActivity = Date()
        guard let p = parser else { return }
        p.feed(d)
        if let f = p.failure {
            // おかしな返事: その要求は失敗にして、接続は切る（続きのバイトの区切りが信用できないため）
            alive = false
            let kind: FetchError.Kind
            if case .tooLarge = f { kind = .tooLarge } else { kind = .malformed }
            finishCurrent(.failure(FetchError(f.description, kind: kind)), reusable: false)
            tcp?.abort()
            return
        }
        if p.complete { finishCurrent(.success(p), reusable: p.keepAlive && alive) }
    }

    private func ended(_ err: String?) {
        alive = false
        guard let p = parser else { return }
        if p.closed() { finishCurrent(.success(p), reusable: false) }
        else if let t = tls, t.handshakeError != 0 {
            finishCurrent(.failure(FetchError(err ?? "TLS の握手に失敗", kind: t.versionMismatch ? .tlsVersion : .tls)), reusable: false)
        }
        else { finishCurrent(.failure(FetchError(err ?? "途中で切れました", kind: tcpConnected ? .reset : .connect)), reusable: false, gotNothing: p.received == 0) }
    }

    private func fail(_ s: String, kind: FetchError.Kind = .other) {
        alive = false
        finishCurrent(.failure(FetchError(s, kind: kind)), reusable: false, gotNothing: true)
    }

    private func finishCurrent(_ r: Result<ResponseParser, FetchError>, reusable: Bool, gotNothing: Bool = false) {
        let cb = onDone
        onDone = nil
        parser = nil
        cb?(r, reusable, gotNothing)
    }
}

// MARK: - 取り消し

/// 要求の取り消しの印。WebKit が読み込みをやめたら（VNetScheme.stop）cancel() する。
/// HTTPPool は、待っている要求は列から外し、読んでいる途中の接続は切る（使い回さない）
final class RequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    init() {}

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 取り消す（何度呼んでもよい）。登録された処理は、呼んだスレッドで 1 回ずつ動く
    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let hs = handlers
        handlers = []
        lock.unlock()
        for h in hs { h() }
    }

    /// 取り消されたときの処理を登録する（もう取り消されていれば、すぐ動く）
    func onCancel(_ h: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); h(); return }
        handlers.append(h)
        lock.unlock()
    }
}

// MARK: - 接続の置き場と、要求の受付

/// 資源の上限（メモリ・接続の数・待ち行列）
struct PoolLimits: Sendable {
    /// 同じ相手への同時の接続（ブラウザと同じ）
    var maxPerHost = 6
    /// 全部の相手への接続の合計（使っていないものも含む）
    var maxTotalConnections = 32
    /// 待っている要求の合計（これを超えたら失敗にする）
    var maxWaiting = 256
    /// 1 つの返事の中身の上限（縮めたものを戻した後も同じ）
    var maxBodyPerRequest = 32 << 20
    /// 読んでいる途中の返事の中身の合計。超えている間は、新しい要求を待たせる
    var maxBufferedTotal = 128 << 20
    init() {}
}

/// 開発者向けの数字（queue の上で作ったスナップショット）
struct PoolStats: Sendable {
    var opened = 0, reused = 0
    var busy = 0, idle = 0, waiting = 0
    var bufferedBytes = 0
    var dnsCached = 0
}

/// 接続の置き場（相手ごと）と、要求の受付。すべて stack.queue の上で呼ぶ
final class HTTPPool: @unchecked Sendable {
    let stack: GuestStack
    /// ブラウザ（WebKit）が User-Agent を付けてこなかったときに使う
    var userAgent = BrowserIdentity.userAgent
    var limits = PoolLimits()

    /// 待っている要求（取り消されたら、順番が来たときに cancel を呼んで飛ばす）
    private struct Waiter {
        let token: RequestToken?
        let run: () -> Void
        let cancel: () -> Void
    }
    private var idle: [String: [HTTPConn]] = [:]
    private var busy: [String: Int] = [:]
    /// 相手ごとの待ち（同じ相手への接続が maxPerHost 本使われている）
    private var waiting: [String: [Waiter]] = [:]
    /// 全体の待ち（接続の合計が上限・貯めている中身が上限）
    private var admission: [Waiter] = []
    private var dnsCache: [String: (ip: [UInt8], at: Date)] = [:]
    /// 名前を引いて分かったアドレスの種類（トップのページが LAN のものかを見るのに使う）
    private var hostClass: [String: IPClass] = [:]
    /// 使っていない接続を、これより長く置いておかない（相手はたいてい黙って閉じている）
    let idleLimit: TimeInterval = 50
    private(set) var reused = 0, opened = 0
    /// 読んでいる途中の返事の中身の合計（バイト）
    private(set) var bufferedBytes = 0
    /// Cookie の写し（正本は WebKit）。nil なら Cookie を送らない・受け取らない
    var cookieJar: CookieJar?
    /// HSTS の記録（リダイレクトを https に上げる）
    var hsts: HSTSStore?
    /// LAN の保護（LocalNetworkPolicy）を使うか
    var localNetworkProtection = true
    /// 判定のログ（Cookie を送らなかった理由・LAN を止めた理由など）
    var policyLog: ((String) -> Void)?

    init(stack: GuestStack) {
        self.stack = stack
    }

    func stats() -> PoolStats {
        pruneIdle()
        return PoolStats(opened: opened, reused: reused, busy: busy.values.reduce(0, +), idle: idle.values.reduce(0) { $0 + $1.count },
                         waiting: waitingCount(), bufferedBytes: bufferedBytes, dnsCached: dnsCache.count)
    }

    /// 送って返事を受け取る（リダイレクトは追いかける）
    /// followRedirects が false なら 3xx もそのまま返す（移動はブラウザ（WebKit）に任せるとき）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, redirects: Int = 0, carried: [CookieChange] = [], done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        if req.token?.isCancelled == true { done(.failure(HTTPPool.cancelled)); return }
        sendOnce(req, retry: true) { [weak self] r in
            guard let self else { return }
            guard case .success(var res) = r else { done(r); return }
            if followRedirects, RedirectPolicy.statuses.contains(res.status) {
                let hsts = self.hsts
                switch RedirectPolicy.next(from: req.url, method: req.method, headers: req.headers, body: req.body, status: res.status,
                                           location: res.header("Location"), redirectCount: redirects,
                                           hsts: { hsts?.shouldUpgrade($0) ?? false }) {
                case .success(let nx):
                    var n = req
                    n.url = nx.url
                    n.method = nx.method
                    n.headers = nx.headers
                    n.body = nx.body
                    n.context = req.context.redirected(from: req.url, to: nx.url)
                    let dropped = nx.dropped.isEmpty ? "" : "（外したヘッダ: \(nx.dropped.joined(separator: ", "))）"
                    self.stack.trace?("↪ \(res.status) → \(nx.url.absoluteString)\(nx.upgradedByHSTS ? "（HSTS で https に）" : "")\(dropped)")
                    self.send(n, followRedirects: true, redirects: redirects + 1, carried: carried + res.cookieChanges, done: done)
                    return
                case .failure(let f):
                    // 追いかけられない 3xx（Location が無い・javascript: など）は、そのまま返す。回数の上限は失敗にする
                    if f == .tooMany { done(.failure(FetchError("リダイレクトが多すぎます", kind: .redirect))); return }
                    self.stack.trace?("↪ \(res.status) を追いかけません: \(f)")
                }
            }
            res.cookieChanges = carried + res.cookieChanges
            done(.success(res))
        }
    }

    static let cancelled = FetchError("取り消しました", kind: .cancelled)

    private func sendOnce(_ req: HTTPRequest, retry: Bool, done: @escaping (Result<HTTPResult, FetchError>) -> Void) {
        guard let rawHost = req.url.host, let scheme = req.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            done(.failure(FetchError("http か https のアドレスではありません"))); return
        }
        let host = SiteUtil.normalizeHost(rawHost)
        let https = scheme == "https"
        if https && !TLSStream.isSupported { done(.failure(FetchError("この環境では https を使えません", kind: .tls))); return }
        let port = UInt16(req.url.port ?? (https ? 443 : 80))
        let key = "\(scheme)://\(host):\(port)"
        // 先に名前を引いて、LAN への接続かを判定する（接続を使い回すときも、要求ごとに判定する）
        resolve(host) { [weak self] ip in
            guard let self else { return }
            if req.token?.isCancelled == true { done(.failure(HTTPPool.cancelled)); return }
            guard let ip else { done(.failure(FetchError("名前が見つかりません: \(host)", kind: .dns))); return }
            if let e = self.checkLocalNetwork(req, host: host, ip: ip) { done(.failure(e)); return }
            let bytes = self.requestBytes(req, host: host)
            let run: (HTTPConn) -> Void = { [weak self] c in
                guard let self else { return }
                if req.token?.isCancelled == true {
                    self.release(c, reusable: c.alive)
                    done(.failure(HTTPPool.cancelled))
                    return
                }
                var held = 0
                let stream = StreamState()
                let decide: ((ResponseParser) -> ((Data) -> Void)?)? = req.sink.map { sink in
                    { [weak self] p in self?.startStream(p, req: req, sink: sink, state: stream) }
                }
                let serial = c.send(bytes, isHead: req.method == "HEAD", limits: self.parserLimits(),
                                    onGrow: { [weak self] n in held += n; self?.bufferedBytes += n },
                                    decide: decide) { [weak self] r, reusable, gotNothing in
                    guard let self else { return }
                    self.bufferedBytes -= held
                    held = 0
                    self.release(c, reusable: reusable)
                    switch r {
                    case .success(let p) where p.streaming:
                        done(self.finishStream(p, req: req, state: stream))
                    case .success(let p):
                        done(self.result(p, req: req))
                    case .failure(let e):
                        // 使い回した接続が、相手に閉じられていた: 新しい接続でもう一度（取り消したものは除く）
                        if e.kind != .cancelled && retry && gotNothing && c.uses > 1 { self.sendOnce(req, retry: false, done: done) }
                        else { done(.failure(e)) }
                    }
                }
                let q = self.stack.queue
                req.token?.onCancel { [weak c] in q.async { c?.cancel(serial: serial) } }
            }
            self.admit(req.token, cancel: { done(.failure(HTTPPool.cancelled)) }, fail: { done(.failure($0)) }) { [weak self] in
                self?.acquire(key: key, host: host, ip: ip, port: port, https: https, token: req.token,
                              cancel: { done(.failure(HTTPPool.cancelled)) }, fail: { done(.failure($0)) }, run: run)
            }
        }
    }

    /// 流す形の途中の様子（1 つの要求の間だけ）
    private final class StreamState {
        var sink: StreamSink?
        var decoder: StreamDecoder?
        var head: HTTPHead?
        var failure: FetchError?
        var bytes = 0
    }

    /// ヘッダを読んだところで、流す形にするかを決める。流すなら、Cookie を入れて onHead を呼び、中身を受け取る関数を返す
    private func startStream(_ p: ResponseParser, req: HTTPRequest, sink: StreamSink, state: StreamState) -> ((Data) -> Void)? {
        guard sink.shouldStream(p.status, p.headers) else { return nil }
        var headers = p.headers
        let enc = headers.value(for: "Content-Encoding") ?? ""
        let decoder: StreamDecoder?
        switch StreamDecoder.make(encoding: enc) {
        case .success(let d): decoder = d
        case .failure: return nil            // 流す形で戻せない縮め方（重ねてあるなど）: 貯める形で読む
        }
        if decoder != nil { headers.removeAll(named: ["content-encoding", "content-length"]) }
        headers.removeAll(named: ["transfer-encoding"])
        var changes: [CookieChange] = []
        let lines = headers.values(for: "Set-Cookie")
        if !lines.isEmpty, let jar = cookieJar { changes = jar.receive(lines, url: req.url, method: req.method, ctx: req.context) }
        let head = HTTPHead(status: p.status, headers: headers, url: req.url, cookieChanges: changes)
        state.sink = sink
        state.decoder = decoder
        state.head = head
        sink.onHead(head)
        return { [weak state] chunk in
            guard let state, state.failure == nil else { return }
            state.bytes += chunk.count
            guard let d = state.decoder else { sink.onData(chunk); return }
            switch d.feed(chunk) {
            case .success(let out): if !out.isEmpty { sink.onData(out) }
            case .failure(let f): state.failure = FetchError(f.description, kind: .malformed)
            }
        }
    }

    /// 流す形の返事を読み終えた
    private func finishStream(_ p: ResponseParser, req: HTTPRequest, state: StreamState) -> Result<HTTPResult, FetchError> {
        if let d = state.decoder, state.failure == nil {
            switch d.finish() {
            case .success(let out): if !out.isEmpty { state.sink?.onData(out) }
            case .failure(let f): state.failure = FetchError(f.description, kind: .malformed)
            }
        }
        if let f = state.failure {
            stack.trace?("流す形の中身を戻せませんでした: \(req.url.absoluteString)（\(f.description)）")
            return .failure(f)
        }
        let h = state.head
        return .success(HTTPResult(status: p.status, headers: h?.headers ?? p.headers, body: Data(), url: req.url,
                                   cookieChanges: h?.cookieChanges ?? [], streamed: true))
    }

    private func parserLimits() -> ResponseParser.Limits {
        var l = ResponseParser.Limits()
        l.maxBody = limits.maxBodyPerRequest
        return l
    }

    /// LAN への接続を判定する。止めるならエラーを返す
    private func checkLocalNetwork(_ req: HTTPRequest, host: String, ip: [UInt8]) -> FetchError? {
        let target = LocalNetworkPolicy.classify(ip)
        hostClass[host] = target
        // VNet の中のアドレス（ルーター・DNS）には、設定に関係なく接続しない
        if !localNetworkProtection && target != .vnetInternal { return nil }
        let ctx = req.context
        let topClass = ctx.topURL.flatMap { classOf($0) }
        let from = ctx.previousURL ?? ctx.initiator
        let fromClass = from.flatMap { classOf($0) }
        switch LocalNetworkPolicy.decide(target: target, ctx: ctx, topClass: topClass, fromClass: fromClass) {
        case .allow:
            return nil
        case .block(let why):
            policyLog?("🛡 LAN の保護: \(req.url.absoluteString)（\(ip.ipString)）を止めました: \(why)")
            return FetchError("\(why)（\(host) → \(ip.ipString)）", kind: .blocked)
        case .askUser(let why):
            policyLog?("🛡 LAN の保護: \(req.url.absoluteString)（\(ip.ipString)）は確認が必要です: \(why)")
            return FetchError("\(why)（\(host) → \(ip.ipString)）", kind: .localNetworkConsent)
        }
    }

    /// URL のホストのアドレスの種類（数字のアドレスならそのまま。名前なら、引いたことがあればその結果。分からなければ公開とみなす）
    private func classOf(_ u: URL) -> IPClass? {
        guard let h = SiteUtil.host(of: u) else { return nil }
        return LocalNetworkPolicy.classify(host: h) ?? hostClass[h] ?? .publicAddress
    }

    // MARK: 待ち行列と上限

    private func waitingCount() -> Int {
        admission.filter { $0.token?.isCancelled != true }.count
            + waiting.values.reduce(0) { $0 + $1.filter { $0.token?.isCancelled != true }.count }
    }

    /// 待ち行列に入れる（いっぱいなら失敗）
    private func enqueue(_ w: Waiter, key: String?, fail: (FetchError) -> Void) {
        if waitingCount() >= limits.maxWaiting {
            fail(FetchError("要求が多すぎます（\(limits.maxWaiting) 件待っています）", kind: .busy))
            return
        }
        if let key { waiting[key, default: []].append(w) } else { admission.append(w) }
    }

    /// 貯めている中身が上限なら待たせる。空いていればすぐ go
    private func admit(_ token: RequestToken?, cancel: @escaping () -> Void, fail: (FetchError) -> Void, _ go: @escaping () -> Void) {
        if bufferedBytes < limits.maxBufferedTotal { go(); return }
        stack.trace?("読んでいる途中の中身が \(bufferedBytes >> 20)MB あるので、新しい要求を待たせます")
        enqueue(Waiter(token: token, run: go, cancel: cancel), key: nil, fail: fail)
    }

    /// 死んだ・古い「使っていない接続」を片付ける
    private func pruneIdle() {
        let now = Date()
        for (k, list) in idle {
            let keep = list.filter { c in
                if c.alive && now.timeIntervalSince(c.idleSince) <= idleLimit { return true }
                c.close()
                return false
            }
            idle[k] = keep.isEmpty ? nil : keep
        }
    }

    private var totalConnections: Int { busy.values.reduce(0, +) + idle.values.reduce(0) { $0 + $1.count } }

    /// 空いている接続を使う。無ければ作る（上限まで）。いっぱいなら空くまで待つ
    private func acquire(key: String, host: String, ip: [UInt8], port: UInt16, https: Bool, token: RequestToken?,
                         cancel: @escaping () -> Void, fail: @escaping (FetchError) -> Void, run: @escaping (HTTPConn) -> Void) {
        pruneIdle()
        if var list = idle[key], let c = list.popLast() {
            idle[key] = list.isEmpty ? nil : list
            busy[key, default: 0] += 1
            reused += 1
            run(c)
            return
        }
        let again = { [weak self] () -> Void in
            self?.acquire(key: key, host: host, ip: ip, port: port, https: https, token: token, cancel: cancel, fail: fail, run: run)
        }
        if busy[key, default: 0] >= limits.maxPerHost {
            enqueue(Waiter(token: token, run: again, cancel: cancel), key: key, fail: fail)
            return
        }
        if totalConnections >= limits.maxTotalConnections {
            // ほかの相手の、使っていない接続を 1 本閉じて場所を空ける。それも無ければ待つ
            if let (k, list) = idle.first(where: { !$0.value.isEmpty }) {
                var l = list
                l.removeFirst().close()
                idle[k] = l.isEmpty ? nil : l
            } else {
                enqueue(Waiter(token: token, run: again, cancel: cancel), key: nil, fail: fail)
                return
            }
        }
        busy[key, default: 0] += 1
        let c = HTTPConn(key: key)
        opened += 1
        c.open(stack: stack, ip: ip, port: port, host: host, https: https)
        run(c)
    }

    /// 使い終わった接続を戻す（使い回せなければ閉じる）。待っている要求があれば進める
    private func release(_ c: HTTPConn, reusable: Bool) {
        if reusable && c.alive { c.idleSince = Date(); idle[c.key, default: []].append(c) } else { c.close() }
        busy[c.key, default: 1] -= 1
        if busy[c.key] == 0 { busy[c.key] = nil }
        drain(key: c.key)
    }

    /// 待っている要求を進める（相手ごとの待ち → 全体の待ち）。取り消されたものは飛ばす
    private func drain(key: String) {
        while var w = waiting[key], !w.isEmpty {
            let next = w.removeFirst()
            waiting[key] = w.isEmpty ? nil : w
            if next.token?.isCancelled == true { next.cancel(); continue }
            next.run()
            break
        }
        while !admission.isEmpty && bufferedBytes < limits.maxBufferedTotal && totalConnections < limits.maxTotalConnections {
            let next = admission.removeFirst()
            if next.token?.isCancelled == true { next.cancel(); continue }
            next.run()
        }
    }

    private func resolve(_ host: String, _ done: @escaping ([UInt8]?) -> Void) {
        if let c = dnsCache[host], Date().timeIntervalSince(c.at) < 300 { done(c.ip); return }
        stack.resolve(host) { [weak self] ip in
            if let ip { self?.dnsCache[host] = (ip, Date()) }
            done(ip)
        }
    }

    /// こちらで決め直すので、ブラウザから来ても送らないヘッダ
    private static let ownHeaders: Set<String> = ["host", "connection", "accept-encoding", "content-length", "user-agent",
                                                  "cookie", "keep-alive", "proxy-connection", "te", "upgrade"]

    /// ヘッダを送る順番（Safari に合わせる）。ここに無い名前は "content-type" の所に、来た順で入れる
    /// （ブラウザから来るヘッダは辞書なので順番がばらばら。毎回順番が変わると、ロボットだと思われやすい）
    private static let headerOrder: [String] = ["host", "origin", "content-type", "accept", "sec-fetch-site", "sec-fetch-dest",
                                                "accept-language", "sec-fetch-mode", "user-agent", "upgrade-insecure-requests",
                                                "referer", "range", "if-none-match", "if-modified-since", "content-length",
                                                "accept-encoding", "cookie", "priority", "connection"]

    private func requestBytes(_ req: HTTPRequest, host: String) -> Data {
        let comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? "/"
        if path.isEmpty { path = "/" }
        if let q = comps?.percentEncodedQuery { path += "?" + q }
        var h: [(String, String)] = [("Host", req.url.port.map { "\(host):\($0)" } ?? host)]
        h += req.headers.filter { !HTTPPool.ownHeaders.contains($0.0.lowercased()) }
        if h.value(for: "Accept") == nil { h.append(("Accept", "*/*")) }
        if h.value(for: "Accept-Language") == nil { h.append(("Accept-Language", BrowserIdentity.acceptLanguage)) }
        // User-Agent はブラウザ（WebKit）が付けてきたものを使う（ページの JavaScript から見える navigator.userAgent と同じにする）
        h.append(("User-Agent", req.headers.value(for: "User-Agent") ?? userAgent))
        // 途中から読む（Range。動画など）ときは縮めてもらわない。縮めると「何バイト目」がずれる
        h.append(("Accept-Encoding", req.headers.value(for: "Range") == nil ? ContentDecoding.acceptEncoding : "identity"))
        if let cookie = cookieHeader(req) { h.append(("Cookie", cookie)) }
        if let b = req.body { h.append(("Content-Length", String(b.count))) }
        else if req.method == "POST" || req.method == "PUT" || req.method == "PATCH" { h.append(("Content-Length", "0")) }
        h.append(("Connection", "keep-alive"))
        let order = HTTPPool.headerOrder
        let other = order.firstIndex(of: "content-type") ?? 0
        let rank = { (name: String) -> Int in order.firstIndex(of: name.lowercased()) ?? other }
        let sorted = h.enumerated().sorted { a, b in
            let ra = rank(a.element.0), rb = rank(b.element.0)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        var s = "\(req.method) \(path) HTTP/1.1\r\n"
        for (_, kv) in sorted { s += "\(kv.0): \(kv.1)\r\n" }
        s += "\r\n"
        var d = Data(s.utf8)
        if let b = req.body { d.append(b) }
        return d
    }

    /// 送る Cookie。WebKit が付けてきたものがあれば、それをそのまま使う（WebKit が自分の決まりで選んだもの）。
    /// 無ければ CookieJar（WebKit の置き場の写し）から、CookiePolicy で許されたものだけ
    private func cookieHeader(_ req: HTTPRequest) -> String? {
        if !req.context.cookiesAllowed { return nil }
        let fromWebKit = req.headers.values(for: "Cookie").filter { !$0.isEmpty }
        if !fromWebKit.isEmpty { return fromWebKit.joined(separator: "; ") }
        guard let jar = cookieJar else { return nil }
        let (header, skipped) = jar.header(for: req.url, method: req.method, ctx: req.context)
        if !skipped.isEmpty, let log = policyLog {
            log("🍪 送らない（\(req.url.host ?? "")）: " + skipped.map { "\($0.0)＝\($0.1)" }.joined(separator: "、"))
        }
        return header
    }

    /// 返事をまとめる（Cookie を CookieJar に入れる・縮めた中身を戻す）
    private func result(_ p: ResponseParser, req: HTTPRequest) -> Result<HTTPResult, FetchError> {
        let url = req.url
        var headers = p.headers
        let lines = headers.values(for: "Set-Cookie")
        var changes: [CookieChange] = []
        if !lines.isEmpty, let jar = cookieJar {
            changes = jar.receive(lines, url: url, method: req.method, ctx: req.context)
        }
        var body = Data(p.body)
        if let enc = headers.value(for: "Content-Encoding"), !body.isEmpty {
            switch ContentDecoding.decode(body, encoding: enc, maxOutput: limits.maxBodyPerRequest) {
            case .success(let g):
                body = g
                headers.removeAll(named: ["content-encoding", "content-length"])
            case .failure(let f):
                // 戻せない中身をそのまま渡すと、ページには壊れたデータになる。失敗にする
                stack.trace?("縮めた中身（\(enc)）を戻せませんでした: \(url.absoluteString)（\(f.description)）")
                if case .tooLarge = f { return .failure(FetchError(f.description, kind: .tooLarge)) }
                return .failure(FetchError(f.description, kind: .malformed))
            }
        }
        headers.removeAll(named: ["transfer-encoding"])
        return .success(HTTPResult(status: p.status, headers: headers, body: body, url: url, cookieChanges: changes))
    }
}

// ======================================================================
// MARK: - HTTPResponseParser.swift
// ======================================================================

// MARK: - http の返事を少しずつ読む
//
// ヘッダ → 中身。中身の終わりは「長さ指定（Content-Length）」「chunked」「閉じるまで」のどれか。
// 100 Continue などの途中の返事は読み飛ばす。
//
// 外から来るデータなので、おかしなものは「壊れている（malformed）」「大きすぎる（tooLarge）」として止める（落ちない・貯めすぎない）:
//  ・Content-Length は 0 以上の整数だけ。違う値が重複していたら拒否（同じ値の重複は 1 つにまとめる）
//  ・Transfer-Encoding と Content-Length が両方あったら拒否（中身の境目があいまいになり、取り違えの元になるため）
//  ・chunked: サイズは 16 進の数字だけ。チャンクの後ろは必ず CRLF。行・トレーラーの長さに上限
//  ・ヘッダの合計・1 行・行数に上限。中身は limits.maxBody まで
// 止めた接続は使い回さない（呼ぶ側の HTTPConn が閉じる）
//
// 流す形（ストリーミング）: ヘッダを読んだところで decideStreaming が true を返したら、中身は貯めずに
// 届いた分ずつ onChunk に渡す（大きいファイル・動画でメモリを使わない）。そのときは maxBody の上限はかけない

final class ResponseParser {
    struct Limits {
        var maxHeaderBytes = 64 * 1024
        var maxHeaderLine = 8 * 1024
        var maxHeaderCount = 100
        var maxBody = 32 << 20
        var maxChunkLine = 1024
        var maxTrailerBytes = 8 * 1024
        init() {}
    }

    enum Failure: Equatable {
        case malformed(String)
        case tooLarge(String)
        var description: String {
            switch self {
            case .malformed(let s): return "返事が壊れています（\(s)）"
            case .tooLarge(let s): return "返事が大きすぎます（\(s)）"
            }
        }
    }

    let isHead: Bool
    let limits: Limits
    private(set) var status = 0
    private(set) var headers: [(String, String)] = []
    private(set) var body = [UInt8]()
    private(set) var complete = false
    private(set) var keepAlive = true
    /// 届いたバイト数（何も届かずに切れたかを見るため）
    private(set) var received = 0
    /// おかしな返事だった（nil なら問題なし）
    private(set) var failure: Failure?
    /// 中身が増えたとき（増えたバイト数）。アプリ全体の貯めている量を数えるのに使う（流す形のときは呼ばない）
    var onBodyGrow: ((Int) -> Void)?
    /// ヘッダを読み終えたとき（100 Continue などを除く）。true を返すと、中身を流す形にする
    var decideStreaming: (() -> Bool)?
    /// 流す形のときの中身（届いた分ずつ）
    var onChunk: ((Data) -> Void)?
    /// 流す形にしたか
    private(set) var streaming = false
    /// 受け取った中身のバイト数（流す形でも数える）
    private(set) var bodyCount = 0

    private var head = [UInt8]()
    private var headDone = false
    private enum Mode { case length(Int), chunked, untilClose }
    private var mode = Mode.untilClose
    private enum Chunk { case size, data(Int), cr, lf, trailer }
    private var chunk = Chunk.size
    private var line = [UInt8]()
    private var trailerBytes = 0

    init(isHead: Bool, limits: Limits = Limits()) {
        self.isHead = isHead
        self.limits = limits
    }

    func feed(_ d: Data) {
        received += d.count
        var bytes = [UInt8](d)
        while !complete && failure == nil && !bytes.isEmpty {
            if headDone {
                bytes = consumeBody(bytes)
                continue
            }
            head.append(contentsOf: bytes)
            guard let end = findHeadEnd() else {
                if head.count > limits.maxHeaderBytes { fail(.tooLarge("ヘッダが \(limits.maxHeaderBytes / 1024)KB を超えています")) }
                return
            }
            if end > limits.maxHeaderBytes { fail(.tooLarge("ヘッダが \(limits.maxHeaderBytes / 1024)KB を超えています")); return }
            bytes = Array(head[(end + 4)...])
            let headBytes = Array(head[0..<end])
            head = []
            parseHead(headBytes)
            if failure != nil { return }
            if status >= 100 && status < 200 { headDone = false }     // 100 Continue など: 次のヘッダを読む
        }
    }

    /// 相手が閉じた: 「閉じるまで」の形なら、ここで終わり
    func closed() -> Bool {
        if complete { return true }
        if failure != nil { return false }
        if headDone, case .untilClose = mode { complete = true; keepAlive = false; return true }
        return false
    }

    private func fail(_ f: Failure) {
        if failure == nil { failure = f }
        keepAlive = false
    }

    private func findHeadEnd() -> Int? {
        if head.count < 4 { return nil }
        for i in 0...(head.count - 4) where head[i] == 13 && head[i + 1] == 10 && head[i + 2] == 13 && head[i + 3] == 10 { return i }
        return nil
    }

    private func appendBody<C: Collection>(_ b: C) where C.Element == UInt8 {
        if b.isEmpty { return }
        if streaming {
            bodyCount += b.count
            onChunk?(Data(b))
            return
        }
        if body.count + b.count > limits.maxBody {
            fail(.tooLarge("中身が \(limits.maxBody >> 20)MB を超えています"))
            return
        }
        body.append(contentsOf: b)
        bodyCount += b.count
        onBodyGrow?(b.count)
    }

    private func parseHead(_ headBytes: [UInt8]) {
        headDone = true
        var lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        // 状態の行: "HTTP/1.1 200 OK"
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3, let st = Int(parts[1]), (100...599).contains(st) else {
            fail(.malformed("状態の行が読めません: \(first.prefix(60))")); return
        }
        status = st
        if lines.count > limits.maxHeaderCount { fail(.tooLarge("ヘッダが \(limits.maxHeaderCount) 行を超えています")); return }
        var hs: [(String, String)] = []
        for l in lines {
            if l.utf8.count > limits.maxHeaderLine { fail(.tooLarge("ヘッダの 1 行が \(limits.maxHeaderLine / 1024)KB を超えています")); return }
            if l.isEmpty { continue }
            guard let c = l.firstIndex(of: ":") else {
                if l.first == " " || l.first == "\t" { fail(.malformed("折り返したヘッダ（obs-fold）")); return }
                continue
            }
            let name = String(l[..<c])
            if name.isEmpty || name.contains(" ") || name.contains("\t") { fail(.malformed("ヘッダの名前が不正: \(name.prefix(40))")); return }
            hs.append((name, String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
        }
        headers = hs
        let conn = headers.value(for: "Connection")?.lowercased() ?? ""
        keepAlive = first.hasPrefix("HTTP/1.0") ? conn.contains("keep-alive") : !conn.contains("close")
        if status >= 100 && status < 200 { return }

        // 中身の長さの決め方
        let te = headers.values(for: "Transfer-Encoding")
        let cls = headers.values(for: "Content-Length")
        if !te.isEmpty && !cls.isEmpty { fail(.malformed("Transfer-Encoding と Content-Length が両方あります")); return }
        var length: Int?
        if !cls.isEmpty {
            var values = Set<String>()
            for v in cls { for p in v.split(separator: ",", omittingEmptySubsequences: false) { values.insert(p.trimmingCharacters(in: .whitespaces)) } }
            guard values.count == 1, let v = values.first, !v.isEmpty, v.count <= 18, v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else {
                fail(.malformed("Content-Length が不正: \(cls.joined(separator: " / ").prefix(60))")); return
            }
            length = n
        }
        if isHead || status == 204 || status == 304 { complete = true; return }
        streaming = decideStreaming?() ?? false
        if !te.isEmpty {
            let codings = te.joined(separator: ",").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if codings.last == "chunked" { mode = .chunked }
            else { mode = .untilClose; keepAlive = false }          // chunked で終わらないなら、閉じるまで（RFC 9112 6.3）
        } else if let n = length {
            if n > limits.maxBody && !streaming { fail(.tooLarge("Content-Length が \(limits.maxBody >> 20)MB を超えています（\(n)）")); return }
            mode = .length(n)
            if n == 0 { complete = true }
        } else {
            mode = .untilClose; keepAlive = false
        }
    }

    /// 中身を読む。余り（次の返事の分。普通は無い）を返す
    private func consumeBody(_ b: [UInt8]) -> [UInt8] {
        switch mode {
        case .untilClose:
            appendBody(b)
            return []
        case .length(let n):
            let take = min(max(n - bodyCount, 0), b.count)
            appendBody(b[0..<take])
            if bodyCount >= n { complete = true }
            return Array(b[take...])
        case .chunked:
            var i = 0
            while i < b.count && !complete && failure == nil {
                switch chunk {
                case .size, .trailer:
                    let c = b[i]; i += 1
                    if c != 10 {
                        line.append(c)
                        if case .trailer = chunk {
                            trailerBytes += 1
                            if trailerBytes > limits.maxTrailerBytes { fail(.tooLarge("トレーラーが \(limits.maxTrailerBytes / 1024)KB を超えています")) }
                        } else if line.count > limits.maxChunkLine {
                            fail(.malformed("チャンクのサイズの行が長すぎます"))
                        }
                        continue
                    }
                    if line.last == 13 { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    line = []
                    if case .trailer = chunk {
                        if text.isEmpty { complete = true }
                    } else {
                        let sizeText = (text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                        guard !sizeText.isEmpty, sizeText.count <= 16, sizeText.allSatisfy({ $0.isHexDigit }), let n = Int(sizeText, radix: 16) else {
                            fail(.malformed("チャンクのサイズが不正: \(sizeText.prefix(20))")); break
                        }
                        if !streaming && n > limits.maxBody - body.count { fail(.tooLarge("チャンクが大きすぎます（\(n)）")); break }
                        chunk = n == 0 ? .trailer : .data(n)
                    }
                case .data(let remain):
                    let take = min(remain, b.count - i)
                    appendBody(b[i..<(i + take)])
                    i += take
                    chunk = remain - take == 0 ? .cr : .data(remain - take)
                case .cr:                                     // 中身のあとの \r\n（必ずこの 2 バイト）
                    guard b[i] == 13 else { fail(.malformed("チャンクの後ろが CRLF ではありません")); break }
                    i += 1
                    chunk = .lf
                case .lf:
                    guard b[i] == 10 else { fail(.malformed("チャンクの後ろが CRLF ではありません")); break }
                    i += 1
                    chunk = .size
                }
            }
            return Array(b[min(i, b.count)...])
        }
    }
}

// ======================================================================
// MARK: - HTTPSupport.swift
// ======================================================================

// MARK: - http の小さな道具（ヘッダ・gzip・ブラウザらしさ）
//
// Cookie は CookieJar.swift（WebKit の置き場の写し）と NetPolicy.swift の CookiePolicy に移した

/// ヘッダ（名前, 値）の並び。名前の大文字小文字は区別しない
extension Array where Element == (String, String) {
    func value(for name: String) -> String? {
        let n = name.lowercased()
        return first { $0.0.lowercased() == n }?.1
    }

    func values(for name: String) -> [String] {
        let n = name.lowercased()
        return filter { $0.0.lowercased() == n }.map { $0.1 }
    }

    /// names は小文字で渡す
    mutating func removeAll(named names: Set<String>) {
        removeAll { names.contains($0.0.lowercased()) }
    }
}

// MARK: 縮めた中身を戻す（gzip・deflate・br）

enum ContentDecoding {
    /// 送る Accept-Encoding（Safari と同じ。br は iOS 15 から）
    static var acceptEncoding: String {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return "gzip, deflate, br" }
        return "gzip, deflate"
        #else
        return "identity"
        #endif
    }

    enum Failure: Error, Equatable {
        /// 知らない縮め方（この環境で戻せないものも）
        case unsupported(String)
        /// 壊れている・途中で切れている
        case corrupt(String)
        /// 戻した大きさが上限を超えた（圧縮爆弾など）
        case tooLarge(Int)

        var description: String {
            switch self {
            case .unsupported(let e): return "戻せない縮め方です（\(e)）"
            case .corrupt(let e): return "縮めた中身（\(e)）が壊れています"
            case .tooLarge(let n): return "戻した中身が \(n >> 20)MB を超えます"
            }
        }
    }

    /// Content-Encoding に従って戻す。戻した大きさは maxOutput まで
    static func decode(_ d: Data, encoding: String, maxOutput: Int = 32 << 20) -> Result<Data, Failure> {
        // "gzip, br" のように重ねてあるときは、後ろから戻す
        var out = d
        for e in encoding.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).reversed() {
            let r: Result<Data, Failure>
            switch e {
            case "", "identity": continue
            case "gzip", "x-gzip": r = gunzip(out, maxOutput: maxOutput)
            case "deflate": r = inflateZlib(out, maxOutput: maxOutput)
            case "br": r = brotli(out, maxOutput: maxOutput)
            default: return .failure(.unsupported(e))
            }
            switch r {
            case .success(let g): out = g
            case .failure(let f): return .failure(f)
            }
        }
        return .success(out)
    }

    /// gzip: 前（10 バイト〜）と後ろ（8 バイト）を外して、生の deflate として戻す
    static func gunzip(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return .failure(.corrupt("gzip の頭が違います")) }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { return .failure(.corrupt("gzip")) }; p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }   // FEXTRA
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                      // FNAME
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }                                     // FCOMMENT
        if flags & 2 != 0 { p += 2 }                                                                                  // FHCRC
        guard p < b.count else { return .failure(.corrupt("gzip")) }
        return inflateRaw(b[p...], name: "gzip", maxOutput: maxOutput)
    }

    /// deflate: 本当は zlib の包み（2 バイト＋後ろ 4 バイト）付き。包みの無い生の deflate を送るサーバーもあるので両方受ける
    static func inflateZlib(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        let b = [UInt8](d)
        if b.count >= 2 && b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return inflateRaw(b[2...], name: "deflate", maxOutput: maxOutput) }
        return inflateRaw(b[...], name: "deflate", maxOutput: maxOutput)
    }

    static func inflateRaw(_ b: ArraySlice<UInt8>, name: String, maxOutput: Int) -> Result<Data, Failure> {
        #if canImport(Compression)
        return stream(b, COMPRESSION_ZLIB, name: name, maxOutput: maxOutput)      // Apple の ZLIB は「生の deflate」
        #else
        return .failure(.unsupported(name))
        #endif
    }

    static func brotli(_ d: Data, maxOutput: Int) -> Result<Data, Failure> {
        #if canImport(Compression)
        if #available(iOS 15.0, macOS 12.0, *) { return stream([UInt8](d)[...], COMPRESSION_BROTLI, name: "br", maxOutput: maxOutput) }
        #endif
        return .failure(.unsupported("br"))
    }

    #if canImport(Compression)
    /// 元の大きさが分からなくても戻せるよう、少しずつ戻す。最後まで戻せなかったら壊れている扱い
    private static func stream(_ src: ArraySlice<UInt8>, _ algorithm: compression_algorithm, name: String, maxOutput: Int) -> Result<Data, Failure> {
        if src.isEmpty { return .success(Data()) }
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var s = compression_stream(dst_ptr: out, dst_size: 0, src_ptr: UnsafePointer(out), src_size: 0, state: nil)
        guard compression_stream_init(&s, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return .failure(.unsupported(name)) }
        defer { compression_stream_destroy(&s) }
        var result = Data()
        return src.withUnsafeBufferPointer { sb -> Result<Data, Failure> in
            guard let base = sb.baseAddress else { return .failure(.corrupt(name)) }
            s.src_ptr = base
            s.src_size = sb.count
            while true {
                s.dst_ptr = out
                s.dst_size = chunk
                let st = compression_stream_process(&s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - s.dst_size
                if result.count + produced > maxOutput { return .failure(.tooLarge(maxOutput)) }
                if produced > 0 { result.append(out, count: produced) }
                if st == COMPRESSION_STATUS_END { return .success(result) }
                if st != COMPRESSION_STATUS_OK { return .failure(.corrupt(name)) }
                if produced == 0 && s.src_size == 0 { return .failure(.corrupt("\(name)・途中で切れています")) }
            }
        }
    }
    #endif
}

// MARK: 少しずつ届く縮めた中身を、少しずつ戻す（流す形のとき）

/// 流す形の返事の Content-Encoding を、届いた分ずつ戻す。1 種類の縮め方だけ（重ねてあるものは流さずに貯める形で読む）
final class StreamDecoder {
    enum Kind { case gzip, deflate, br }

    /// 縮め方から作る。縮めていない（identity）なら nil。流す形で戻せないものは失敗
    static func make(encoding: String) -> Result<StreamDecoder?, ContentDecoding.Failure> {
        let list = encoding.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "identity" }
        if list.isEmpty { return .success(nil) }
        guard list.count == 1 else { return .failure(.unsupported(encoding)) }
        let kind: Kind
        switch list[0] {
        case "gzip", "x-gzip": kind = .gzip
        case "deflate": kind = .deflate
        case "br": kind = .br
        default: return .failure(.unsupported(list[0]))
        }
        #if canImport(Compression)
        if kind == .br, #unavailable(iOS 15.0, macOS 12.0) { return .failure(.unsupported("br")) }
        guard let d = StreamDecoder(kind: kind) else { return .failure(.unsupported(list[0])) }
        return .success(d)
        #else
        return .failure(.unsupported(list[0]))
        #endif
    }

    let kind: Kind
    let maxOutput: Int
    private(set) var produced = 0
    /// 頭（gzip の 10 バイト〜・zlib の 2 バイト）を読み終えるまで貯めておく
    private var head = [UInt8]()
    private var headDone = false
    private var ended = false

    #if canImport(Compression)
    private var stream: compression_stream
    private var started = false

    private init?(kind: Kind, maxOutput: Int = Int.max) {
        self.kind = kind
        self.maxOutput = maxOutput
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        let algorithm: compression_algorithm
        if kind == .br {
            if #available(iOS 15.0, macOS 12.0, *) { algorithm = COMPRESSION_BROTLI } else { return nil }
        } else {
            algorithm = COMPRESSION_ZLIB      // Apple の ZLIB は「生の deflate」
        }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        started = true
    }

    deinit { if started { compression_stream_destroy(&stream) } }
    #else
    private init?(kind: Kind, maxOutput: Int = Int.max) { return nil }
    #endif

    /// 届いた分を戻す
    func feed(_ d: Data) -> Result<Data, ContentDecoding.Failure> {
        if ended { return .success(Data()) }          // 終わった後のもの（gzip の後ろの 8 バイトなど）は捨てる
        var bytes = [UInt8](d)
        if !headDone {
            head += bytes
            switch skipHead() {
            case .needMore: return .success(Data())
            case .bad(let why): return .failure(.corrupt(why))
            case .done(let rest): headDone = true; bytes = rest; head = []
            }
        }
        return process(bytes, finalize: false)
    }

    /// 最後まで届いた
    func finish() -> Result<Data, ContentDecoding.Failure> {
        if ended { return .success(Data()) }
        if !headDone { return .failure(.corrupt("頭の途中で終わりました")) }
        return process([], finalize: true)
    }

    private enum HeadResult { case needMore, bad(String), done([UInt8]) }

    private func skipHead() -> HeadResult {
        let b = head
        switch kind {
        case .br:
            return .done(b)
        case .deflate:
            // zlib の包み（2 バイト）があれば外す。無いもの（生の deflate）も受ける
            if b.count < 2 { return .needMore }
            if b[0] & 0x0F == 8 && (Int(b[0]) << 8 | Int(b[1])) % 31 == 0 { return .done(Array(b[2...])) }
            return .done(b)
        case .gzip:
            if b.count < 10 { return .needMore }
            guard b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return .bad("gzip の頭が違います") }
            let flags = b[3]
            var p = 10
            if flags & 4 != 0 {                                         // FEXTRA
                guard p + 2 <= b.count else { return .needMore }
                p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
            }
            for flag in [UInt8(8), 16] where flags & flag != 0 {        // FNAME・FCOMMENT（0 で終わる）
                guard let z = b[min(p, b.count)...].firstIndex(of: 0) else { return .needMore }
                p = z + 1
            }
            if flags & 2 != 0 { p += 2 }                                 // FHCRC
            if p > b.count { return .needMore }
            return .done(Array(b[p...]))
        }
    }

    private func process(_ src: [UInt8], finalize: Bool) -> Result<Data, ContentDecoding.Failure> {
        #if canImport(Compression)
        let chunk = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var result = Data()
        let name = "\(kind)"
        return src.withUnsafeBufferPointer { sb -> Result<Data, ContentDecoding.Failure> in
            let empty: [UInt8] = [0]
            return empty.withUnsafeBufferPointer { eb -> Result<Data, ContentDecoding.Failure> in
                stream.src_ptr = sb.baseAddress ?? eb.baseAddress!
                stream.src_size = sb.count
                while true {
                    stream.dst_ptr = out
                    stream.dst_size = chunk
                    let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let st = compression_stream_process(&stream, flags)
                    let n = chunk - stream.dst_size
                    if produced + n > maxOutput { return .failure(.tooLarge(maxOutput)) }
                    if n > 0 { result.append(out, count: n); produced += n }
                    if st == COMPRESSION_STATUS_END { ended = true; return .success(result) }
                    if st != COMPRESSION_STATUS_OK { return .failure(.corrupt(name)) }
                    // 入れたものを全部使い切って、出てくるものも無くなったら、次の分を待つ
                    if stream.src_size == 0 && n < chunk {
                        if finalize && n == 0 { return .failure(.corrupt("\(name)・途中で切れています")) }
                        if !finalize { return .success(result) }
                    }
                }
            }
        }
        #else
        return .failure(.unsupported("\(kind)"))
        #endif
    }
}

// MARK: ブラウザらしさ（User-Agent・言語）

enum BrowserIdentity {
    /// iPad の Safari（デスクトップ用の表示。iPad の Safari の初期設定と同じ）の User-Agent。
    /// WKWebView の初期値は「Version/… Safari/…」が無く、アプリの中のブラウザやロボットだと思われやすい
    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion).\(v.minorVersion) Safari/605.1.15"
    }()

    /// Accept-Language（端末の言語の順。例: "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"）
    static let acceptLanguage: String = {
        var langs: [String] = []
        for l in Locale.preferredLanguages.prefix(3) {
            let tag = l.replacingOccurrences(of: "_", with: "-")
            if !langs.contains(tag) { langs.append(tag) }
            if let base = tag.split(separator: "-").first.map(String.init), base != tag, !langs.contains(base) { langs.append(base) }
        }
        if langs.isEmpty { langs = ["ja-JP", "ja"] }
        return langs.prefix(6).enumerated().map { i, l in
            i == 0 ? l : "\(l);q=\(String(format: "%.1f", max(0.1, 1.0 - Double(i) * 0.1)))"
        }.joined(separator: ",")
    }()
}

// ======================================================================
// MARK: - TLSClient.swift
// ======================================================================

// MARK: - https の暗号（TLS）を、自作の TCP の上で動かす
//
// iPad の普通の通信の部品（Network.framework）は、自分で作った TCP の上では TLS を使えない。
// そこで、古いけれど今も使える Apple の「SecureTransport」（SSLCreateContext など）を使う。
// これは「読む・書く」を自分で用意できるので、GuestTCP の上で TLS 1.2 を話せる。
// 証明書は iPad と同じ仕組みで確かめる（相手の名前も確かめる）。
// ブラウザらしく見えるよう: ALPN（http/1.1）を名乗る・前の暗号の約束を使い回す（セッション再開。握手が速くなる）
//
// 注意（技術的負債）: SecureTransport は 2019 年から非推奨で、TLS 1.3 には対応しない（Apple TN3151）。
// なので VNet の TLS は 1.2 まで。TLS 1.3 だけのサーバーは版が合わずに失敗する（versionMismatch）。そのときは標準の通信で開く。
// 自作の TCP の上では Network.framework の TLS を使えないので、TLS エンジンの移行は別の課題にしている
//
// 使い方: TLSStream(host:) を作る → TCP がつながったら attach → onReady で write → onData で中身が届く → onClosed
// SecureTransport が無い環境では TLSStream(host:) が nil を返す（https は使えない）

#if canImport(Security) && os(iOS)
final class TLSStream: @unchecked Sendable {
    static let isSupported = true
    let host: String
    private let ctx: SSLContext
    private var tcp: GuestTCP?
    /// TCP から届いて、まだ TLS に渡していないもの（inbox[inboxPos...]）。先頭を消すと遅いので、位置で覚える
    private var inbox = [UInt8]()
    private var inboxPos = 0
    private var tcpEnded = false
    private var handshaking = true
    private var pendingWrite = Data()
    private var done = false
    /// 握手に失敗したときの番号（0 なら握手の失敗ではない）
    private(set) var handshakeError: OSStatus = 0
    /// 決まった版（"TLS 1.2" など）
    private(set) var version = ""
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    init?(host: String, port: UInt16 = 443) {
        self.host = host
        guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
        ctx = c
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetProtocolVersionMax(ctx, .tlsProtocol12)      // SecureTransport は 1.3 を話せない
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
        SSLSetALPNProtocols(ctx, ["http/1.1"] as CFArray)
        let peer = Array("\(host):\(port)".utf8)
        _ = peer.withUnsafeBytes { SSLSetPeerID(ctx, $0.baseAddress, $0.count) }
    }

    /// 証明書の問題での失敗か
    var failedOnCertificate: Bool { handshakeError <= -9807 && handshakeError >= -9815 }

    /// 版や暗号の組み合わせが合わずに失敗したか（相手が TLS 1.3 だけなど）
    /// -9836: errSSLPeerProtocolVersion（相手が版を断った）、-9831: errSSLPeerHandshakeFail、-9801: errSSLNegotiation、-9830: errSSLIllegalParam
    var versionMismatch: Bool { [-9836, -9831, -9801].contains(handshakeError) }

    /// TCP がつながったら呼ぶ
    func attach(_ t: GuestTCP) {
        tcp = t
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        drive()
    }

    /// TCP から届いたもの
    func tcpData(_ d: Data) {
        if inboxPos > 65536 && inboxPos * 2 > inbox.count { inbox.removeFirst(inboxPos); inboxPos = 0 }
        inbox.append(contentsOf: d)
        drive()
    }

    func tcpClosed(_ error: String?) {
        tcpEnded = true
        // まだ attach していない（TCP がつながる前に閉じた・取り消した）: SecureTransport には触らない。
        // SSLSetConnection の前に SSLHandshake を呼ぶと、tlsWrite に null が来て落ちた（実機の記録: TLSStream.writeFrom で 0x28）
        if tcp != nil { drive() }
        if !done { finish(error ?? (handshaking ? "TLS の途中で切れました" : nil)) }
    }

    /// 暗号にして送る（つながる前なら、つながってから送る）
    func write(_ d: Data) {
        if done { return }
        if handshaking { pendingWrite.append(d); return }
        // 書き込みの関数（tlsWrite）は全部を TCP に渡すので、普通は 1 回で全部書ける。
        // それでも、書けた分を確かめて残りを書く。エラーなら閉じる（黙って捨てない）
        var offset = 0
        while offset < d.count {
            var processed = 0
            let st = d.withUnsafeBytes { buf -> OSStatus in
                SSLWrite(ctx, buf.baseAddress! + offset, d.count - offset, &processed)
            }
            offset += processed
            if st == errSSLWouldBlock && processed > 0 { continue }
            if st != errSecSuccess {
                finish("TLS の書き込みに失敗（\(st)）")
                return
            }
            if processed == 0 { finish("TLS の書き込みが進みません"); return }
        }
    }

    private func finish(_ error: String?) {
        if done { return }
        done = true
        tcp?.abort()
        onClosed?(error)
    }

    /// 進められるところまで進める（握手 → 読む）
    private func drive() {
        if done || tcp == nil { return }
        if handshaking {
            let st = SSLHandshake(ctx)
            if st == errSSLWouldBlock { return }
            if st != errSecSuccess {
                handshakeError = st
                finish("TLS の握手に失敗（\(st)）" + (failedOnCertificate ? "：証明書を確かめられません"
                                                   : versionMismatch ? "：TLS の版が合いません（VNet は TLS 1.2 まで）" : ""))
                return
            }
            handshaking = false
            var p = SSLProtocol.sslProtocolUnknown
            SSLGetNegotiatedProtocolVersion(ctx, &p)
            version = p == .tlsProtocol13 ? "TLS 1.3" : p == .tlsProtocol12 ? "TLS 1.2" : "TLS（\(p.rawValue)）"
            onReady?()
            if !pendingWrite.isEmpty { let w = pendingWrite; pendingWrite = Data(); write(w) }
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var n = 0
            let st = buf.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress!, $0.count, &n) }
            if n > 0 { onData?(Data(buf[0..<n])) }
            if st == errSSLWouldBlock { if tcpEnded && inboxPos >= inbox.count { finish(nil) }; return }
            if st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == errSSLClosedAbort { finish(nil); return }
            if st != errSecSuccess { finish("TLS の読み込みに失敗（\(st)）"); return }
        }
    }

    // SecureTransport から呼ばれる「読む・書く」
    fileprivate func readInto(_ p: UnsafeMutableRawPointer, _ want: Int) -> (Int, OSStatus) {
        let avail = inbox.count - inboxPos
        if avail <= 0 { return (0, tcpEnded ? errSSLClosedNoNotify : errSSLWouldBlock) }
        let n = min(want, avail)
        inbox.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + inboxPos, byteCount: n) }
        inboxPos += n
        return (n, n < want ? errSSLWouldBlock : errSecSuccess)
    }

    fileprivate func writeFrom(_ p: UnsafeRawPointer, _ n: Int) -> OSStatus {
        guard let t = tcp else { return errSSLClosedAbort }
        t.write(Data(bytes: p, count: n))
        return errSecSuccess
    }
}

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    // 念のため: 接続の印が無ければ（SSLSetConnection の前）何も読まない
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    let (n, st) = s.readInto(data, length.pointee)
    length.pointee = n
    return st
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    return s.writeFrom(data, length.pointee)
}
#else
/// SecureTransport が無い環境用の代わり（作れない）
final class TLSStream: @unchecked Sendable {
    static let isSupported = false
    let handshakeError: Int32 = 0
    let version = ""
    var failedOnCertificate: Bool { false }
    var versionMismatch: Bool { false }
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?
    init?(host: String, port: UInt16 = 443) { return nil }
    func attach(_ t: GuestTCP) {}
    func tcpData(_ d: Data) {}
    func tcpClosed(_ error: String?) {}
    func write(_ d: Data) {}
}
#endif

// ======================================================================
// MARK: - GuestStack.swift
// ======================================================================

// MARK: - ゲスト側の小さな TCP/IP（Linux の代わり）
//
// ・DHCP で IP アドレスをもらう（ルーター UserNet が 10.0.2.15 をくれる）
// ・ARP でルーター（10.0.2.2）の MAC アドレスを調べる
// ・DNS（10.0.2.3）で名前を IP アドレスにする
// ・TCP でつなぐ（GuestTCP。送り直し・順番の確認など最低限）
// すべて queue（VNetMachine.queue）の上で動く

final class GuestStack: @unchecked Sendable {
    let queue: DispatchQueue
    /// フレームを送る（ドライバへ）
    var output: (([UInt8]) -> Void)?
    /// 何が起きたかを知らせる（画面のログ用）
    var trace: ((String) -> Void)?
    /// TCP の送り直しの回数（開発者向け。queue の上で数える）
    var retransmits = 0
    /// 順番を飛ばして届き、取っておいた TCP のセグメントの数（開発者向け）
    var reordered = 0

    var mac = Net.guestMAC
    private(set) var ip = Net.zeroIP
    private(set) var router = Net.gateway
    private(set) var dns = Net.dns
    private(set) var ready = false
    private var routerMAC: [UInt8]?
    /// ルーターの MAC が分かるまで待たせる IP パケット
    private var waitingForARP: [[UInt8]] = []
    private var ipID: UInt16 = 1
    private var nextPort: UInt16 = 40000
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: 受け取り

    func input(_ f: [UInt8]) {
        guard let e = EthernetFrame(f) else { return }
        switch e.type {
        case EtherType.arp: handleARP(e.body)
        case EtherType.ipv4: handleIPv4(e.body)
        default: break
        }
    }

    // MARK: イーサネット・ARP

    private func sendEthernet(_ type: UInt16, to dst: [UInt8], _ payload: [UInt8]) {
        output?(Ethernet.frame(dst: dst, src: mac, type: type, payload))
    }

    private func askRouterMAC() {
        let a = ARP.packet(op: ARP.request, senderMAC: mac, senderIP: ip, targetMAC: Net.zeroMAC, targetIP: router)
        sendEthernet(EtherType.arp, to: Net.broadcastMAC, a)
        trace?("→ ARP \(router.ipString) はどこ？")
    }

    private func handleARP(_ p: [UInt8]) {
        guard let a = ARPPacket(p) else { return }
        let op = a.op, senderMAC = a.senderMAC, senderIP = a.senderIP, target = a.targetIP
        if op == ARP.reply && senderIP == router {
            if routerMAC == nil { trace?("← ARP \(router.ipString) は \(senderMAC.macString)") }
            routerMAC = senderMAC
            let w = waitingForARP
            waitingForARP = []
            for pkt in w { sendEthernet(EtherType.ipv4, to: senderMAC, pkt) }
        } else if op == ARP.request && target == ip && ip != Net.zeroIP {
            let r = ARP.packet(op: ARP.reply, senderMAC: mac, senderIP: ip, targetMAC: senderMAC, targetIP: senderIP)
            sendEthernet(EtherType.arp, to: senderMAC, r)
        }
    }

    // MARK: IPv4

    private func sendIPv4(proto: UInt8, dst: [UInt8], _ body: [UInt8], broadcast: Bool = false) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: ip, dst: dst, body)
        ipID &+= 1
        if broadcast { sendEthernet(EtherType.ipv4, to: Net.broadcastMAC, pkt); return }
        // 外へは全部ルーター経由（10.0.2.x もルーターが答える）
        if let m = routerMAC { sendEthernet(EtherType.ipv4, to: m, pkt) } else {
            waitingForARP.append(pkt)
            askRouterMAC()
        }
    }

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p) else { return }
        switch pkt.proto {
        case IPProto.tcp: handleTCP(src: pkt.src, pkt.body)
        case IPProto.udp: handleUDP(pkt.body)
        default: break
        }
    }

    // MARK: UDP（DHCP と DNS）

    private func sendUDP(sport: UInt16, dst: [UInt8], dport: UInt16, _ payload: [UInt8], broadcast: Bool = false) {
        let u = UDPDatagram.build(src: ip, dst: dst, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, dst: dst, u, broadcast: broadcast)
    }

    private func handleUDP(_ b: [UInt8]) {
        guard let u = UDPDatagram(b) else { return }
        if u.sport == Port.dhcpServer && u.dport == Port.dhcpClient { handleDHCP(u.payload) }
        else if u.sport == Port.dns, let q = dnsQueries.removeValue(forKey: u.dport) { q.finish(u.payload) }
    }

    private func allocPort() -> UInt16 {
        nextPort = nextPort >= 60000 ? 40000 : nextPort + 1
        return nextPort
    }

    // MARK: DHCP

    private let dhcpXID = UInt32.random(in: 1...UInt32.max)
    private var dhcpSentAt = Date.distantPast
    private var onReady: [() -> Void] = []

    /// IP アドレスをもらう（もらえたら done が呼ばれる）
    func start(_ done: @escaping () -> Void) {
        onReady.append(done)
        sendDHCP(type: DHCP.discover, requested: nil)
    }

    private func sendDHCP(type: UInt8, requested: [UInt8]?) {
        var m = [UInt8](repeating: 0, count: 236)
        m[0] = 1; m[1] = 1; m[2] = 6                       // 問い合わせ・イーサネット・MAC は 6 バイト
        m.setBE32(dhcpXID, at: 4)
        m[10] = 0x80                                       // ブロードキャストで返してほしい
        m.replaceSubrange(28..<34, with: mac)
        m += DHCP.magicCookie
        m += [DHCP.Opt.messageType, 1, type]
        if let r = requested {
            // 配列を + でつなぐと型チェックがとても遅いので、1 つずつ足す
            m.append(contentsOf: [DHCP.Opt.requestedIP, 4] as [UInt8])
            m.append(contentsOf: r)
            m.append(contentsOf: [DHCP.Opt.serverID, 4] as [UInt8])
            m.append(contentsOf: router)
        }
        m += [DHCP.Opt.paramList, 3, DHCP.Opt.subnetMask, DHCP.Opt.router, DHCP.Opt.dnsServer, DHCP.Opt.end]                         // ほしいもの: サブネット・ルーター・DNS
        sendUDP(sport: Port.dhcpClient, dst: Net.broadcastIP, dport: Port.dhcpServer, m, broadcast: true)
        dhcpSentAt = Date()
        trace?(type == DHCP.discover ? "→ DHCP DISCOVER（IP アドレスをください）" : "→ DHCP REQUEST")
    }

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 2, p.be32(at: 4) == dhcpXID else { return }
        let yiaddr = Array(p[16..<20])
        let opts = DHCP.options(p)
        if let r = opts[3], r.count >= 4 { router = Array(r[0..<4]) }
        if let d = opts[6], d.count >= 4 { dns = Array(d[0..<4]) }
        let type = opts[DHCP.Opt.messageType]?.first ?? 0
        if type == DHCP.offer {
            trace?("← DHCP OFFER \(yiaddr.ipString)")
            sendDHCP(type: DHCP.request, requested: yiaddr)
        } else if type == DHCP.ack && !ready {
            ip = yiaddr
            ready = true
            trace?("← DHCP ACK: IP \(ip.ipString)・ルーター \(router.ipString)・DNS \(dns.ipString)")
            let w = onReady
            onReady = []
            for f in w { f() }
        }
    }

    // MARK: DNS

    private final class DNSQuery {
        let packet: [UInt8]
        let done: ([UInt8]?) -> Void
        var sentAt = Date()
        var tries = 0
        private var finished = false
        init(packet: [UInt8], done: @escaping ([UInt8]?) -> Void) { self.packet = packet; self.done = done }
        func finish(_ reply: [UInt8]?) {
            if finished { return }
            finished = true
            done(reply.flatMap(DNSMessage.firstA))
        }
    }
    private var dnsQueries: [UInt16: DNSQuery] = [:]

    /// 名前を IPv4 アドレスにする（IP アドレスの形ならそのまま）
    func resolve(_ name: String, _ done: @escaping ([UInt8]?) -> Void) {
        let labels = name.split(separator: ".")
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4 && octets.count == 4 { done(octets); return }
        let packet = DNSMessage.query(name: name, id: .random(in: 0...UInt16.max))
        let port = allocPort()
        dnsQueries[port] = DNSQuery(packet: packet) { [weak self] ip in
            self?.trace?("← DNS \(name) = " + (ip?.ipString ?? "見つからない"))
            done(ip)
        }
        trace?("→ DNS \(name) は？")
        sendUDP(sport: port, dst: dns, dport: Port.dns, packet)
    }

    // MARK: TCP

    private struct TCPKey: Hashable { let lport: UInt16; let rip: [UInt8]; let rport: UInt16 }
    private var tcps: [TCPKey: GuestTCP] = [:]

    private static func key(_ c: GuestTCP) -> TCPKey { TCPKey(lport: c.lport, rip: c.rip, rport: c.rport) }

    /// TCP でつなぐ
    func connect(_ rip: [UInt8], _ rport: UInt16, handler: GuestTCP.Handler) -> GuestTCP {
        let c = GuestTCP(stack: self, lport: allocPort(), rip: rip, rport: rport, handler: handler)
        tcps[GuestStack.key(c)] = c
        c.sendSYN()
        trace?("→ TCP SYN \(rip.ipString):\(rport)")
        return c
    }

    /// 終わった接続を忘れる（GuestTCP から呼ぶ）
    func forget(_ c: GuestTCP) {
        tcps[GuestStack.key(c)] = nil
    }

    /// 組み立てた TCP セグメントを送る（GuestTCP から呼ぶ）
    func sendTCP(to dst: [UInt8], _ segment: [UInt8]) {
        sendIPv4(proto: IPProto.tcp, dst: dst, segment)
    }

    private func handleTCP(src: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b), let c = tcps[TCPKey(lport: h.dport, rip: src, rport: h.sport)] else { return }
        c.input(h, payload: b[h.headerLength...])
    }

    // MARK: 時間で見るもの（DHCP・DNS・TCP の送り直し）

    private func tick() {
        let now = Date()
        if !ready && now.timeIntervalSince(dhcpSentAt) > 2 && !onReady.isEmpty { sendDHCP(type: DHCP.discover, requested: nil) }
        for (port, q) in dnsQueries where now.timeIntervalSince(q.sentAt) > 2 {
            q.tries += 1
            if q.tries > 3 { dnsQueries[port] = nil; q.finish(nil); continue }
            q.sentAt = now
            sendUDP(sport: port, dst: dns, dport: Port.dns, q.packet)
        }
        for c in Array(tcps.values) { c.tick(now) }
    }
}

// ======================================================================
// MARK: - GuestTCP.swift
// ======================================================================

// MARK: - ゲスト側の TCP の接続 1 本
//
// 作るのは GuestStack.connect。届いたセグメント（input）と時間（tick）も GuestStack から渡される。
// すべて GuestStack と同じ queue の上で動く

final class GuestTCP: @unchecked Sendable {
    struct Handler {
        var connected: () -> Void
        var data: (Data) -> Void
        var closed: (_ error: String?) -> Void
    }

    unowned let stack: GuestStack
    let lport: UInt16, rip: [UInt8], rport: UInt16
    private let handler: Handler
    private enum State { case synSent, established, closed }
    private var state = State.synSent
    private let iss = UInt32.random(in: 0...UInt32.max)
    private var sndUna: UInt32, sndNxt: UInt32
    private var rcvNxt: UInt32 = 0
    /// sndUna から先の、まだ受け取ってもらっていないデータ
    private var sendBuf = Data()
    private var wantFIN = false, finSent = false, gotFIN = false
    private var peerWindow = 65535
    private let mss = 1460
    private var lastProgress = Date()
    private var retries = 0
    /// 順番を飛ばして届いたデータ（番号 → 中身）。間が届いたら続けて渡す（落ちたフレームの分だけ送り直してもらえば済む）
    private var ooo: [UInt32: [UInt8]] = [:]
    private var oooBytes = 0
    static let reorderLimit = 256 * 1024
    /// 相手の窓が 0 になってからの時刻（窓を探る「持続タイマー」用）
    private var zeroWindowSince: Date?
    static let maxZeroWindow: TimeInterval = 60

    init(stack: GuestStack, lport: UInt16, rip: [UInt8], rport: UInt16, handler: Handler) {
        self.stack = stack; self.lport = lport; self.rip = rip; self.rport = rport; self.handler = handler
        sndUna = iss
        sndNxt = iss &+ 1
    }

    // MARK: 使う側から

    /// データを送る
    func write(_ d: Data) {
        guard state != .closed else { return }
        sendBuf.append(d)
        pump()
    }

    /// 送り終わったら閉じる
    func close() {
        wantFIN = true
        pump()
    }

    /// すぐに切る（RST）
    func abort() {
        if state != .closed { send([.rst, .ack]) }
        finish(nil)
    }

    // MARK: 送る

    private func send(_ flags: TCPFlags, mss withMSS: Bool = false, payload: ArraySlice<UInt8> = []) {
        let seq = flags.contains(.syn) ? iss : sndNxt
        let seg = TCPSegment.build(src: stack.ip, dst: rip, sport: lport, dport: rport, seq: seq,
                                   ack: flags.contains(.ack) ? rcvNxt : 0, flags: flags, mss: withMSS, payload: payload)
        stack.sendTCP(to: rip, seg)
    }

    /// 最初の SYN（GuestStack.connect から呼ぶ）
    func sendSYN() { send(.syn, mss: true) }

    private func finish(_ error: String?) {
        if state == .closed { return }
        state = .closed
        stack.forget(self)
        handler.closed(error)
    }

    /// 相手の窓の分だけ送る。全部送って閉じたいなら FIN
    private func pump() {
        guard state == .established else { return }
        while true {
            let inFlight = Int(sndNxt &- sndUna)
            let unsent = sendBuf.count - inFlight
            if unsent <= 0 {
                if wantFIN && !finSent {
                    send([.fin, .ack])
                    sndNxt &+= 1
                    finSent = true
                    lastProgress = Date()
                }
                return
            }
            let room = peerWindow - inFlight
            if room <= 0 { return }
            let n = min(unsent, mss, room)
            let start = sendBuf.startIndex + inFlight
            send([.ack, .psh], payload: ArraySlice(sendBuf[start..<(start + n)]))
            sndNxt &+= UInt32(n)
            lastProgress = Date()
        }
    }

    // MARK: GuestStack から

    /// 届いたセグメント
    func input(_ h: TCPHeader, payload: ArraySlice<UInt8>) {
        peerWindow = Int(h.window)
        if peerWindow > 0 { zeroWindowSince = nil } else if zeroWindowSince == nil { zeroWindowSince = Date() }
        if h.flags.contains(.rst) {
            stack.trace?("← TCP RST \(rip.ipString):\(rport)")
            finish(state == .synSent ? "つながりませんでした" : "相手に切られました")
            return
        }
        if state == .synSent {
            guard h.flags.contains([.syn, .ack]), h.ack == iss &+ 1 else { return }
            rcvNxt = h.seq &+ 1
            sndUna = h.ack
            state = .established
            retries = 0
            send(.ack)
            stack.trace?("← TCP SYN+ACK \(rip.ipString):\(rport)（つながった）")
            handler.connected()
            pump()
            return
        }
        guard state == .established else { return }
        if h.flags.contains(.ack) {
            let acked = h.ack &- sndUna
            let inFlight = sndNxt &- sndUna
            if acked > 0 && acked <= inFlight {
                var n = Int(acked)
                if finSent && h.ack == sndNxt { n -= 1 }        // FIN の分
                if n > 0 { sendBuf.removeFirst(min(n, sendBuf.count)) }
                sndUna = h.ack
                lastProgress = Date()
                retries = 0
            }
        }
        var needAck = false
        if !payload.isEmpty {
            deliver(seq: h.seq, Array(payload))
            if state == .closed { return }
            needAck = true
        }
        if h.flags.contains(.fin) && h.seq &+ UInt32(payload.count) == rcvNxt && !gotFIN {
            gotFIN = true
            rcvNxt &+= 1
            needAck = true
        }
        if needAck { send(.ack) }
        pump()
        if gotFIN {
            // 相手が閉じた: こちらも閉じて終わり（ブラウザ用なので、半分だけ閉じた状態は使わない）
            if !finSent { wantFIN = true; pump() }
            finish(nil)
        }
    }

    /// 届いた中身を、番号の順に渡す。重なっている所は外し、先の分は取っておく
    private func deliver(seq start: UInt32, _ bytes: [UInt8]) {
        var seq = start
        var data = bytes
        let before = Int32(bitPattern: rcvNxt &- seq)       // > 0: rcvNxt より前から始まる（送り直しの重なり）
        if before > 0 {
            if Int(before) >= data.count { return }         // 全部受け取り済み
            data.removeFirst(Int(before))
            seq = rcvNxt
        }
        if seq != rcvNxt {
            // 先の分: 窓の中で、置き場に余裕があれば取っておく
            let ahead = Int(Int32(bitPattern: seq &- rcvNxt))
            if ahead > 0 && ahead < GuestTCP.reorderLimit && oooBytes + data.count <= GuestTCP.reorderLimit && ooo[seq] == nil {
                ooo[seq] = data
                oooBytes += data.count
                stack.reordered += 1
            }
            return
        }
        rcvNxt &+= UInt32(data.count)
        handler.data(Data(data))
        // 取っておいた先の分が続いていれば渡す
        while state != .closed, let (k, v) = ooo.first(where: { Int32(bitPattern: rcvNxt &- $0.key) >= 0 }) {
            ooo[k] = nil
            oooBytes -= v.count
            let skip = Int(Int32(bitPattern: rcvNxt &- k))
            if skip < v.count {
                let rest = v[skip...]
                rcvNxt &+= UInt32(rest.count)
                handler.data(Data(rest))
            }
        }
    }

    /// 時間で見る（送り直し・窓を探る）
    func tick(_ now: Date) {
        if now.timeIntervalSince(lastProgress) < 1 { return }
        // 相手の窓が 0: 送り直しの回数に数えずに、1 バイトだけ送って窓が開いたかを探る（持続タイマー）。長く開かなければ切る
        if state == .established && peerWindow == 0 && !sendBuf.isEmpty {
            if let z = zeroWindowSince, now.timeIntervalSince(z) > GuestTCP.maxZeroWindow { abort(); return }
            sndNxt = sndUna
            finSent = false
            send([.ack, .psh], payload: ArraySlice(sendBuf.prefix(1)))
            sndNxt = sndUna &+ 1
            lastProgress = now
            return
        }
        if state == .synSent {
            retries += 1
            if retries > 8 { finish("つながりませんでした（時間切れ）"); return }
            sendSYN()
            lastProgress = now
        } else if state == .established && sndNxt != sndUna {
            retries += 1
            if retries > 12 { abort(); return }
            // 受け取りの返事が来ない: 先頭から送り直す
            stack.retransmits += 1
            sndNxt = sndUna
            finSent = false
            lastProgress = now
            pump()
        }
    }
}

// ======================================================================
// MARK: - DNSMessage.swift
// ======================================================================

// MARK: - DNS のメッセージ（A レコードだけ）
//
// ゲスト側: query で問い合わせを作り、firstA で返事から IPv4 アドレスを取り出す
// ルーター側: question で問い合わせを読み、reply で返事を作る

enum DNSMessage {
    /// A レコードの問い合わせ（再帰あり）
    static func query(name: String, id: UInt16) -> [UInt8] {
        var q: [UInt8] = []
        q.appendBE16(id)
        q += [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]      // RD=1・質問 1 つ
        for label in name.split(separator: ".") {
            let b = Array(label.utf8.prefix(63))
            q.append(UInt8(b.count))
            q += b
        }
        q += [0, 0, 1, 0, 1]                           // 名前の終わり・A・IN
        return q
    }

    /// 返事から最初の A レコード（IPv4 アドレス）を取り出す
    static func firstA(_ r: [UInt8]) -> [UInt8]? {
        guard r.count >= 12, r[3] & 0x0F == 0 else { return nil }
        let qd = Int(r.be16(at: 4)), an = Int(r.be16(at: 6))
        var i = 12
        func skipName() {
            while i < r.count {
                let l = Int(r[i])
                if l == 0 { i += 1; return }
                if l & 0xC0 == 0xC0 { i += 2; return }
                i += 1 + l
            }
        }
        for _ in 0..<qd { skipName(); i += 4 }
        for _ in 0..<an {
            skipName()
            guard i + 10 <= r.count else { return nil }
            let type = r.be16(at: i)
            let rdlen = Int(r.be16(at: i + 8))
            i += 10
            if type == 1 && rdlen == 4 && i + 4 <= r.count { return Array(r[i..<(i + 4)]) }
            i += rdlen
        }
        return nil
    }

    struct Question {
        let name: String
        let type: UInt16
        /// 質問の終わり（返事はここまでを写して作る）
        let end: Int
    }

    /// 問い合わせの最初の質問を読む（形が変なら nil）
    static func question(_ q: [UInt8]) -> Question? {
        var i = 12
        var labels: [String] = []
        while i < q.count {
            let l = Int(q[i])
            if l == 0 { i += 1; break }
            guard l < 64, i + 1 + l <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + l)], as: UTF8.self))
            i += 1 + l
        }
        guard i + 4 <= q.count else { return nil }
        return Question(name: labels.joined(separator: "."), type: q.be16(at: i), end: i + 4)
    }

    /// 返事を作る（問い合わせの先頭 questionEnd バイトを写し、A レコードを並べる）
    static func reply(to q: [UInt8], questionEnd: Int, rcode: UInt8, answers: [[UInt8]]) -> [UInt8] {
        var r = Array(q[0..<min(questionEnd, q.count)])
        r[2] = 0x81                                    // QR=1・RD=1
        r[3] = 0x80 | rcode                            // RA=1
        r.setBE16(UInt16(answers.count), at: 6)
        for k in 8..<12 { r[k] = 0 }
        for a in answers {
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + a   // 名前は質問を指す・A・IN・60 秒・4 バイト
        }
        return r
    }
}

// ======================================================================
// MARK: - Packet.swift
// ======================================================================

// MARK: - パケットを組み立てる・読むための共通の部品
//
// ゲスト側（GuestStack・GuestTCP）とルーター側（UserNet）の両方が使う。
// 数はすべてネットワークの順（ビッグエンディアン）。IP アドレスは 4 バイト、MAC アドレスは 6 バイトの [UInt8]

/// この小さなネットワークの決まった値（QEMU の SLIRP と同じ）
enum Net {
    static let guestIP: [UInt8] = [10, 0, 2, 15]
    static let gateway: [UInt8] = [10, 0, 2, 2]
    static let dns: [UInt8] = [10, 0, 2, 3]
    static let zeroIP: [UInt8] = [0, 0, 0, 0]
    static let broadcastIP: [UInt8] = [255, 255, 255, 255]
    /// ゲスト（仮想 LAN カード）の MAC アドレス（QEMU と同じ）
    static let guestMAC: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
    /// ルーターの MAC アドレス
    static let routerMAC: [UInt8] = [0x52, 0x55, 0x0A, 0x00, 0x02, 0x02]
    static let zeroMAC: [UInt8] = [0, 0, 0, 0, 0, 0]
    static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    /// 10.0.2.x（ルーターが自分で答える範囲）
    static func isLocal(_ ip: [UInt8]) -> Bool { ip.count == 4 && ip[0] == 10 && ip[1] == 0 && ip[2] == 2 }
}

enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
}

enum IPProto {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

// MARK: バイト列の読み書き

extension Array where Element == UInt8 {
    func be16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(at i: Int) -> UInt32 { UInt32(be16(at: i)) << 16 | UInt32(be16(at: i + 2)) }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) { appendBE16(UInt16(v >> 16)); appendBE16(UInt16(v & 0xFFFF)) }
    mutating func setBE16(_ v: UInt16, at i: Int) { self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF) }
    mutating func setBE32(_ v: UInt32, at i: Int) { setBE16(UInt16(v >> 16), at: i); setBE16(UInt16(v & 0xFFFF), at: i + 2) }

    /// 10.0.2.15 の形
    var ipString: String { map { String($0) }.joined(separator: ".") }
    /// 52:54:00:12:34:56 の形
    var macString: String { map { String(format: "%02x", $0) }.joined(separator: ":") }
}

// MARK: 確認用の値（チェックサム）

enum Checksum {
    /// IP などで使う 16 ビットの 1 の補数の和
    static func internet(_ b: [UInt8], initial: UInt32 = 0) -> UInt16 {
        var s = initial
        var i = 0
        while i + 1 < b.count { s &+= UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { s &+= UInt32(b[i]) << 8 }
        while s >> 16 != 0 { s = (s & 0xFFFF) &+ (s >> 16) }
        return ~UInt16(s)
    }

    /// TCP / UDP 用（疑似ヘッダ込み）
    static func l4(proto: UInt8, src: [UInt8], dst: [UInt8], _ seg: [UInt8]) -> UInt16 {
        var s = UInt32(src.be16(at: 0)) &+ UInt32(src.be16(at: 2))
        s &+= UInt32(dst.be16(at: 0)) &+ UInt32(dst.be16(at: 2))
        s &+= UInt32(proto) &+ UInt32(seg.count)
        return internet(seg, initial: s)
    }
}

// MARK: イーサネット・ARP

enum Ethernet {
    static let headerSize = 14
    static func frame(dst: [UInt8], src: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var f = dst + src
        f.appendBE16(type)
        return f + payload
    }
}

/// 届いたイーサネットのフレームを読む（短すぎれば nil）
struct EthernetFrame {
    let raw: [UInt8]
    init?(_ f: [UInt8]) {
        guard f.count >= Ethernet.headerSize else { return nil }
        raw = f
    }
    var type: UInt16 { raw.be16(at: 12) }
    var src: [UInt8] { Array(raw[6..<12]) }
    /// ブロードキャスト・マルチキャストでない送り元か（送り元の先頭のバイトの一番下のビットが 0）
    var srcIsUnicast: Bool { raw[6] & 1 == 0 }
    var body: [UInt8] { Array(raw[Ethernet.headerSize...]) }
}

/// 届いた ARP を読む（イーサネット・IPv4 用。短すぎれば nil）
struct ARPPacket {
    let op: UInt16
    let senderMAC: [UInt8]
    let senderIP: [UInt8]
    let targetIP: [UInt8]
    init?(_ p: [UInt8]) {
        guard p.count >= 28 else { return nil }
        op = p.be16(at: 6)
        senderMAC = Array(p[8..<14])
        senderIP = Array(p[14..<18])
        targetIP = Array(p[24..<28])
    }
}

enum ARP {
    static let request: UInt16 = 1
    static let reply: UInt16 = 2
    /// ARP の中身（イーサネット・IPv4 用）
    static func packet(op: UInt16, senderMAC: [UInt8], senderIP: [UInt8], targetMAC: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        var a: [UInt8] = [0, 1, 8, 0, 6, 4]
        a.appendBE16(op)
        return a + senderMAC + senderIP + targetMAC + targetIP
    }
}

// MARK: IPv4

struct IPv4Packet {
    let proto: UInt8
    let src: [UInt8]
    let dst: [UInt8]
    let body: [UInt8]
    /// 分割されたもの（フラグメント）か
    let isFragment: Bool

    /// 読む（形が変なら nil）
    init?(_ p: [UInt8]) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 15) * 4
        let total = min(Int(p.be16(at: 2)), p.count)
        guard ihl >= 20, total >= ihl else { return nil }
        proto = p[9]
        src = Array(p[12..<16])
        dst = Array(p[16..<20])
        body = Array(p[ihl..<total])
        isFragment = p.be16(at: 6) & 0x3FFF != 0
    }

    /// 組み立てる（オプション無し・TTL 64）
    static func build(proto: UInt8, id: UInt16, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8]) -> [UInt8] {
        var h: [UInt8] = [0x45, 0]
        h.appendBE16(UInt16(20 + body.count))
        h.appendBE16(id)
        h += [dontFragment ? 0x40 : 0, 0, 64, proto, 0, 0]
        h += src + dst
        h.setBE16(Checksum.internet(h), at: 10)
        return h + body
    }
}

// MARK: UDP

struct UDPDatagram {
    let sport: UInt16
    let dport: UInt16
    let payload: [UInt8]

    init?(_ b: [UInt8]) {
        guard b.count >= 8 else { return nil }
        let len = min(Int(b.be16(at: 4)), b.count)
        guard len >= 8 else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        payload = Array(b[8..<len])
    }

    /// 組み立てる（チェックサム込み。0 になったら 0xFFFF にする決まり）
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var u: [UInt8] = []
        u.appendBE16(sport)
        u.appendBE16(dport)
        u.appendBE16(UInt16(8 + payload.count))
        u += [0, 0]
        u += payload
        let c = Checksum.l4(proto: IPProto.udp, src: src, dst: dst, u)
        u.setBE16(c == 0 ? 0xFFFF : c, at: 6)
        return u
    }
}

// MARK: TCP

struct TCPFlags: OptionSet {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 1)
    static let syn = TCPFlags(rawValue: 2)
    static let rst = TCPFlags(rawValue: 4)
    static let psh = TCPFlags(rawValue: 8)
    static let ack = TCPFlags(rawValue: 16)
}

struct TCPHeader {
    let sport: UInt16
    let dport: UInt16
    let seq: UInt32
    let ack: UInt32
    /// ヘッダの長さ（オプション込み）。中身はここから
    let headerLength: Int
    let flags: TCPFlags
    let window: UInt16

    init?(_ b: [UInt8]) {
        guard b.count >= 20 else { return nil }
        let off = Int(b[12] >> 4) * 4
        guard off >= 20, off <= b.count else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        seq = b.be32(at: 4)
        ack = b.be32(at: 8)
        headerLength = off
        flags = TCPFlags(rawValue: b[13])
        window = b.be16(at: 14)
    }

    /// オプションの MSS（無ければ nil）
    static func mss(_ b: [UInt8], headerLength off: Int) -> Int? {
        var i = 20
        while i < off {
            let kind = b[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < off else { break }
            let l = Int(b[i + 1])
            if kind == 2, l == 4, i + 3 < off { return Int(b.be16(at: i + 2)) }
            i += max(2, l)
        }
        return nil
    }
}

enum TCPSegment {
    /// TCP のセグメントを組み立てる（チェックサム込み）。mss = true なら MSS 1460 のオプションを付ける
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, seq: UInt32, ack: UInt32,
                      flags: TCPFlags, window: UInt16 = 0xFFFF, mss: Bool = false,
                      payload: ArraySlice<UInt8> = []) -> [UInt8] {
        let hlen = mss ? 24 : 20
        var t: [UInt8] = []
        t.appendBE16(sport)
        t.appendBE16(dport)
        t.appendBE32(seq)
        t.appendBE32(ack)
        t += [UInt8(hlen / 4) << 4, flags.rawValue]
        t.appendBE16(window)
        t += [0, 0, 0, 0]                              // チェックサム・緊急ポインタ
        if mss { t += [2, 4, 0x05, 0xB4] }
        t += payload
        t.setBE16(Checksum.l4(proto: IPProto.tcp, src: src, dst: dst, t), at: 16)
        return t
    }
}

// MARK: DHCP

/// よく使うポート番号
enum Port {
    static let dns: UInt16 = 53
    static let dhcpServer: UInt16 = 67
    static let dhcpClient: UInt16 = 68
}

enum DHCP {
    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    /// オプションの番号（RFC 2132）
    enum Opt {
        static let subnetMask: UInt8 = 1
        static let router: UInt8 = 3
        static let dnsServer: UInt8 = 6
        static let mtu: UInt8 = 26
        static let requestedIP: UInt8 = 50
        static let leaseTime: UInt8 = 51
        static let messageType: UInt8 = 53
        static let serverID: UInt8 = 54
        static let paramList: UInt8 = 55
        static let end: UInt8 = 255
    }
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let ack: UInt8 = 5

    /// オプション（番号 → 中身）。240 バイト目から読む
    static func options(_ p: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 240
        while i + 1 < p.count {
            let code = p[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            let l = Int(p[i + 1])
            guard i + 2 + l <= p.count else { break }
            out[code] = Array(p[(i + 2)..<(i + 2 + l)])
            i += 2 + l
        }
        return out
    }
}

// ======================================================================
// MARK: - VNetMachine.swift
// ======================================================================

// MARK: - 全部をつなぐ
//
//  [ゲスト側]  HTTPPool（http・https）→ GuestStack → VirtioNetDriver
//                                         ↓ ↑（RAM の中のキューと、レジスタ）
//  [カード]                             VirtioNet
//                                         ↓ onTransmit      ↑ receive
//  [ルーター]                           UserNet（小さなルーター）→ iPad の通信 → インターネット
//
// ゲスト側とカードは queue の上で動く。ルーターは自分のキューで動き、フレームを渡すときだけ行き来する

final class VNetMachine: @unchecked Sendable {
    let queue = DispatchQueue(label: "vnet-guest")
    let ram = GuestRAM(megabytes: 4)
    let card: VirtioNet
    let driver: VirtioNetDriver
    let stack: GuestStack
    let router: UserNet
    let pool: HTTPPool
    /// ログ（どのスレッドからも呼ばれる）
    var log: (@Sendable (String) -> Void)?
    private var ready = false
    private var waiting: [() -> Void] = []
    /// 統計: カードを通ったフレームの数とバイト数
    private var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0

    init(factory: UserNetSocketFactory) {
        card = VirtioNet(memory: ram)
        driver = VirtioNetDriver(dev: card, ram: ram)
        stack = GuestStack(queue: queue)
        router = UserNet(factory: factory)
        pool = HTTPPool(stack: stack)
        // ゲスト → カード → ルーター
        stack.output = { [unowned self] f in self.driver.send(f) }
        card.onTransmit = { [unowned self] f in
            self.framesOut += 1; self.bytesOut += f.count
            self.router.input(f)
        }
        // ルーター → カード → ゲスト（カードとゲストは queue の上で触る）
        router.onFrame = { [weak self] f in
            guard let self else { return }
            self.queue.async {
                self.framesIn += 1; self.bytesIn += f.count
                self.card.receive(f)
                self.driver.poll()          // 割り込みを見て、届いたフレームを取り出す
            }
        }
        driver.onReceive = { [unowned self] f in self.stack.input(f) }
        stack.trace = { [weak self] s in self?.log?(s) }
        router.log = { [weak self] s in self?.log?(s) }
    }

    /// カードを準備して DHCP で IP アドレスをもらう
    func boot() {
        queue.async {
            do {
                try self.driver.start()
                self.stack.mac = self.driver.mac
                self.log?("カードの準備ができました（MAC \(self.driver.mac.macString)）")
            } catch {
                self.log?("カードを準備できません: \(error)")
                return
            }
            self.stack.start {
                self.ready = true
                let w = self.waiting
                self.waiting = []
                for f in w { f() }
            }
        }
    }

    /// 送って返事を受け取る（結果は done に、queue の上で返る）
    /// followRedirects: false なら 3xx もそのまま返す（移動はブラウザに任せる）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, _ done: @escaping @Sendable (Result<HTTPResult, FetchError>) -> Void) {
        queue.async {
            let go = { self.pool.send(req, followRedirects: followRedirects) { r in done(r) } }
            if self.ready { go() } else { self.waiting.append(go) }
        }
    }

    /// ブラウザの User-Agent を使う
    func setUserAgent(_ ua: String) { queue.async { self.pool.userAgent = ua } }

    /// 守りの決まり（Cookie の写し・HSTS・LAN の保護）を渡す。pool は queue の上でしか触らない
    func configurePolicies(cookieJar: CookieJar, hsts: HSTSStore, localNetworkProtection: Bool) {
        queue.async {
            self.pool.cookieJar = cookieJar
            self.pool.hsts = hsts
            self.pool.localNetworkProtection = localNetworkProtection
            self.pool.policyLog = { [weak self] s in self?.log?(s) }
        }
    }

    /// 開発者向けの数字のスナップショット
    struct Stats: Sendable {
        var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0
        var pool = PoolStats()
        var droppedRx = 0
        var tcpRetransmits = 0
        /// 順番を飛ばして届き、取っておいたセグメント
        var tcpReordered = 0
        /// IP アドレスをもらえたか・もらった IP
        var ready = false
        var ip = ""

        var summary: String {
            "フレーム 送 \(framesOut)（\(bytesOut / 1024)KB）・受 \(framesIn)（\(bytesIn / 1024)KB）・接続 新 \(pool.opened) 使い回し \(pool.reused)"
                + "・使用中 \(pool.busy) 待ち \(pool.waiting)" + (pool.bufferedBytes > 0 ? "・読み途中 \(pool.bufferedBytes / 1024)KB" : "")
                + (droppedRx > 0 ? "・捨てたフレーム \(droppedRx)" : "") + (tcpRetransmits > 0 ? "・TCP 送り直し \(tcpRetransmits)" : "")
        }
    }

    /// 数字を queue の上で集めて、done に渡す（画面のスレッドから直接読むと、値を書き換えている途中とぶつかるため）
    func stats(_ done: @escaping @Sendable (Stats) -> Void) {
        queue.async {
            let s = Stats(framesOut: self.framesOut, framesIn: self.framesIn, bytesOut: self.bytesOut, bytesIn: self.bytesIn,
                          pool: self.pool.stats(), droppedRx: self.card.droppedRx, tcpRetransmits: self.stack.retransmits,
                          tcpReordered: self.stack.reordered,
                          ready: self.stack.ready, ip: self.stack.ready ? self.stack.ip.ipString : "")
            done(s)
        }
    }
}

// ======================================================================
// MARK: - VNetCore.swift
// ======================================================================

// MARK: - 実験用の「機械」の部品
//
// Android エミュレータと同じ virtio-net（仮想 LAN カード）を使う。
// 本物のエミュレータでは Linux（ゲスト）がこのカードを動かすが、この実験アプリでは
// ゲストの代わりに、Swift で書いた小さな「ドライバ」と「TCP/IP」（GuestStack）が動かす。
//
//   ブラウザ（WKWebView）→ HTTPPool → GuestStack（TCP/IP）→ VirtioNetDriver
//     → VirtioNet（仮想 LAN カード）→ UserNet（小さなルーター）→ iPad の通信

/// ゲストの RAM（virtio のキューと、フレームの入れ物を置く）。アドレスは 0x4000_0000 から
final class GuestRAM: @unchecked Sendable {
    let base: UInt64 = 0x4000_0000
    let size: UInt64
    private let words: UnsafeMutablePointer<UInt64>
    private var next: UInt64 = 0

    init(megabytes: Int) {
        size = UInt64(megabytes) << 20
        words = .allocate(capacity: Int(size / 8))
        words.initialize(repeating: 0, count: Int(size / 8))
    }
    deinit { words.deallocate() }

    /// 置き場所をもらう（align の倍数に揃える）。戻り値はゲストの物理アドレス
    func alloc(_ count: Int, align: UInt64 = 16) -> UInt64 {
        next = (next + align - 1) / align * align
        let a = base + next
        next += UInt64(count)
        precondition(next <= size, "GuestRAM が足りません")
        return a
    }

    /// ドライバ用（自分で置いた場所なので確かめない）
    func pointer(_ pa: UInt64) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(words) + Int(pa - base) }
    /// カード用（ゲストが書いたアドレスなので、RAM の中に収まるか確かめる）
    func pointer(_ pa: UInt64, count: Int) -> UnsafeMutableRawPointer? {
        let off = pa &- base
        guard pa >= base, off <= size, UInt64(count) <= size - off else { return nil }
        return UnsafeMutableRawPointer(words) + Int(off)
    }

    func load16(_ pa: UInt64) -> UInt16 { pointer(pa).loadUnaligned(as: UInt16.self) }
    func load32(_ pa: UInt64) -> UInt32 { pointer(pa).loadUnaligned(as: UInt32.self) }
    func store16(_ pa: UInt64, _ v: UInt16) { pointer(pa).storeBytes(of: v, as: UInt16.self) }
    func store32(_ pa: UInt64, _ v: UInt32) { pointer(pa).storeBytes(of: v, as: UInt32.self) }
    func store64(_ pa: UInt64, _ v: UInt64) { pointer(pa).storeBytes(of: v, as: UInt64.self) }
}

// MARK: - virtio-mmio の決まり（カードとドライバの両方が使う）

enum VirtioMMIO {
    /// レジスタの位置
    enum Reg {
        static let magic: UInt64 = 0x000
        static let version: UInt64 = 0x004
        static let deviceID: UInt64 = 0x008
        static let vendorID: UInt64 = 0x00C
        static let deviceFeatures: UInt64 = 0x010
        static let deviceFeaturesSel: UInt64 = 0x014
        static let driverFeatures: UInt64 = 0x020
        static let driverFeaturesSel: UInt64 = 0x024
        static let guestPageSize: UInt64 = 0x028          // legacy
        static let queueSel: UInt64 = 0x030
        static let queueNumMax: UInt64 = 0x034
        static let queueNum: UInt64 = 0x038
        static let queueAlign: UInt64 = 0x03C             // legacy
        static let queuePFN: UInt64 = 0x040               // legacy
        static let queueReady: UInt64 = 0x044
        static let queueNotify: UInt64 = 0x050
        static let interruptStatus: UInt64 = 0x060
        static let interruptACK: UInt64 = 0x064
        static let status: UInt64 = 0x070
        static let queueDescLow: UInt64 = 0x080
        static let queueDescHigh: UInt64 = 0x084
        static let queueAvailLow: UInt64 = 0x090
        static let queueAvailHigh: UInt64 = 0x094
        static let queueUsedLow: UInt64 = 0x0A0
        static let queueUsedHigh: UInt64 = 0x0A4
        static let config: UInt64 = 0x100                 // ここから先がカードごとの設定（ネットワークなら MAC アドレス）
    }
    static let magicValue: UInt32 = 0x7472_6976           // "virt"
    static let vendorQEMU: UInt32 = 0x554D_4551           // "QEMU"
    static let deviceNet: UInt32 = 1

    /// 状態（status）のビット
    static let statusAcknowledge: UInt32 = 1
    static let statusDriver: UInt32 = 2
    static let statusDriverOK: UInt32 = 4

    /// 機能のビット
    static let featureNetMAC: UInt64 = 1 << 5
    static let featureVersion1: UInt64 = 1 << 32

    /// 記述子の flags
    static let descNext: UInt16 = 1
    static let descWrite: UInt16 = 2

    /// キューの番号（ネットワーク）
    static let rxQueue = 0
    static let txQueue = 1

    /// virtio_net_hdr の大きさ（古い形 = legacy、MRG_RXBUF なし）
    static let netHeaderSize = 10
}

// MARK: - virtio-mmio のネットワーク（Linux では eth0 になる）
//
// キューは 2 つ: 0 = 受け取り用（OS が空の入れ物を並べておく）、1 = 送り出し用。
// 1 つの入れ物 = [virtio_net_hdr 10 バイト] [イーサネットのフレーム]
// 送り出されたフレームは onTransmit に渡す。外から届いたフレームは receive(_:) で受け取り、
// OS が並べた入れ物に書き込む（入れ物が無ければ、来るまで取っておく）。
// receive はほかのスレッドから呼んでもよい（鍵で守る）。入れ物に書くのは CPU の側（interruptLine を見るとき）
final class VirtioNet: @unchecked Sendable {
    let legacy: Bool
    let mac = Net.guestMAC
    /// OS が送り出したフレーム（ヘッダを除いたイーサネットのフレーム）
    var onTransmit: (([UInt8]) -> Void)?

    static let queueMax: UInt32 = 256
    static let maxPending = 512

    private let ram: GuestRAM

    private struct Queue {
        var num: UInt32 = 0
        var ready: UInt32 = 0
        var desc: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var lastAvail: UInt16 = 0
        var align: UInt32 = 4096
        var pfn: UInt32 = 0
        /// 入れ物の数（ドライバが決めていなければ最大）
        var size: UInt16 { UInt16(num == 0 ? VirtioNet.queueMax : num) }
    }
    private var queues = [Queue(), Queue()]
    private var status: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var queueSel: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var guestPageSize: UInt32 = 4096

    /// まだ OS に渡していない受け取ったフレーム
    private var pending: [[UInt8]] = []
    /// RX キューがいっぱいで捨てたフレームの数（lock で守る）
    private var dropped = 0
    var droppedRx: Int { lock.lock(); defer { lock.unlock() }; return dropped }
    private let lock = NSLock()
    private var hasPending = false

    init(memory: GuestRAM, legacy: Bool = true) {
        ram = memory
        self.legacy = legacy
    }

    var interruptLine: Bool {
        if hasPending { deliverPending() }
        return interruptStatus != 0
    }

    /// 外から届いたフレームを受け取る（どのスレッドからでもよい）
    func receive(_ frame: [UInt8]) {
        lock.lock()
        if pending.count >= VirtioNet.maxPending { pending.removeFirst(); dropped += 1 }
        pending.append(frame)
        hasPending = true
        lock.unlock()
    }

    /// 持っている機能: MAC。バージョン 2 なら VERSION_1 も
    private var deviceFeatures: UInt64 { (legacy ? 0 : VirtioMMIO.featureVersion1) | VirtioMMIO.featureNetMAC }

    private func reset() {
        status = 0
        deviceFeaturesSel = 0
        driverFeaturesSel = 0
        driverFeatures = 0
        queueSel = 0
        interruptStatus = 0
        guestPageSize = 4096
        queues = [Queue(), Queue()]
    }

    // MARK: レジスタ

    func read(_ offset: UInt64, size width: Int) -> UInt64 {
        typealias R = VirtioMMIO.Reg
        if offset >= R.config {
            // 設定領域: 先頭 6 バイトが MAC アドレス
            var r: UInt64 = 0
            for k in 0..<width {
                let i = Int(offset - R.config) + k
                if i < mac.count { r |= UInt64(mac[i]) << UInt64(8 * k) }
            }
            return r
        }
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.magic: return UInt64(VirtioMMIO.magicValue)
        case R.version: return legacy ? 1 : 2
        case R.deviceID: return UInt64(VirtioMMIO.deviceNet)
        case R.vendorID: return UInt64(VirtioMMIO.vendorQEMU)
        case R.deviceFeatures: return deviceFeaturesSel < 2 ? (deviceFeatures >> UInt64(32 * deviceFeaturesSel)) & 0xFFFF_FFFF : 0
        case R.queueNumMax: return ok ? UInt64(VirtioNet.queueMax) : 0
        case R.queuePFN: return legacy && ok ? UInt64(queues[qs].pfn) : 0
        case R.queueReady: return ok ? UInt64(queues[qs].ready) : 0
        case R.interruptStatus: return UInt64(interruptStatus)
        case R.status: return UInt64(status)
        default: return 0
        }
    }

    func write(_ offset: UInt64, size width: Int, value: UInt64) {
        typealias R = VirtioMMIO.Reg
        let v = UInt32(truncatingIfNeeded: value)
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.deviceFeaturesSel: deviceFeaturesSel = v
        case R.driverFeatures:
            if driverFeaturesSel < 2 {
                let shift = UInt64(32 * driverFeaturesSel)
                driverFeatures = (driverFeatures & ~(0xFFFF_FFFF << shift)) | (UInt64(v) << shift)
            }
        case R.driverFeaturesSel: driverFeaturesSel = v
        case R.guestPageSize: if legacy { guestPageSize = v == 0 ? 4096 : v }
        case R.queueSel: queueSel = v
        case R.queueNum: if ok { queues[qs].num = min(v, VirtioNet.queueMax) }
        case R.queueAlign: if legacy && ok { queues[qs].align = v == 0 ? 4096 : v }
        case R.queuePFN: if legacy && ok { setLegacyQueue(qs, pfn: v) }
        case R.queueReady: if ok { queues[qs].ready = v & 1 }
        case R.queueNotify:
            if v == UInt32(VirtioMMIO.txQueue) { transmit() } else if v == UInt32(VirtioMMIO.rxQueue) { deliverPending() }
        case R.interruptACK: interruptStatus &= ~v
        case R.status: if v == 0 { reset() } else { status = v }
        case R.queueDescLow: if ok { queues[qs].desc = setLow(queues[qs].desc, v) }
        case R.queueDescHigh: if ok { queues[qs].desc = setHigh(queues[qs].desc, v) }
        case R.queueAvailLow: if ok { queues[qs].avail = setLow(queues[qs].avail, v) }
        case R.queueAvailHigh: if ok { queues[qs].avail = setHigh(queues[qs].avail, v) }
        case R.queueUsedLow: if ok { queues[qs].used = setLow(queues[qs].used, v) }
        case R.queueUsedHigh: if ok { queues[qs].used = setHigh(queues[qs].used, v) }
        default: break
        }
    }

    /// 古い形: ページ番号（PFN）から、記述子表・avail・used の場所を決める
    private func setLegacyQueue(_ i: Int, pfn: UInt32) {
        queues[i].pfn = pfn
        if pfn == 0 { queues[i].ready = 0; queues[i].lastAvail = 0; return }
        let num = UInt64(queues[i].size)
        let desc = UInt64(pfn) * UInt64(guestPageSize)
        let avail = desc + 16 * num
        let align = UInt64(queues[i].align)
        let availEnd = avail + 4 + 2 * num + 2
        queues[i].desc = desc
        queues[i].avail = avail
        queues[i].used = (availEnd + align - 1) / align * align
        queues[i].lastAvail = 0
        queues[i].ready = 1
    }

    private func setLow(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF_0000_0000) | UInt64(v) }
    private func setHigh(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF) | (UInt64(v) << 32) }

    // MARK: キュー（RAM はゲストが書いた場所なので、確かめながら読み書きする）

    private func load16(_ pa: UInt64) -> UInt16 { ram.pointer(pa, count: 2)?.loadUnaligned(as: UInt16.self) ?? 0 }
    private func load32(_ pa: UInt64) -> UInt32 { ram.pointer(pa, count: 4)?.loadUnaligned(as: UInt32.self) ?? 0 }
    private func load64(_ pa: UInt64) -> UInt64 { ram.pointer(pa, count: 8)?.loadUnaligned(as: UInt64.self) ?? 0 }
    private func store16(_ pa: UInt64, _ v: UInt16) { ram.pointer(pa, count: 2)?.storeBytes(of: v, as: UInt16.self) }
    private func store32(_ pa: UInt64, _ v: UInt32) { ram.pointer(pa, count: 4)?.storeBytes(of: v, as: UInt32.self) }

    /// ドライバが並べた番号（avail.idx）
    private func availIdx(_ q: Queue) -> UInt16 { load16(q.avail + 2) }
    /// 次に取り出す入れ物の先頭の記述子
    private func nextAvailHead(_ q: Queue) -> UInt16 { load16(q.avail + 4 + 2 * UInt64(q.lastAvail % q.size)) }

    /// 記述子のつながり: (アドレス, 長さ, 書き込み用か)
    private func chain(_ q: Queue, head: UInt16) -> [(addr: UInt64, len: Int, writable: Bool)] {
        var out: [(addr: UInt64, len: Int, writable: Bool)] = []
        var i = head
        let num = q.size
        for _ in 0..<Int(num) {
            let d = q.desc + 16 * UInt64(i % num)
            let flags = load16(d + 12)
            out.append((load64(d), Int(load32(d + 8)), flags & VirtioMMIO.descWrite != 0))
            if flags & VirtioMMIO.descNext == 0 { break }
            i = load16(d + 14)
        }
        return out
    }

    /// 使い終わった入れ物を used リングに返す
    private func pushUsed(_ q: Queue, head: UInt16, len: Int) {
        let usedIdx = load16(q.used + 2)
        let slot = q.used + 4 + 8 * UInt64(usedIdx % q.size)
        store32(slot, UInt32(head))
        store32(slot + 4, UInt32(len))
        store16(q.used + 2, usedIdx &+ 1)
    }

    /// 送り出し用のキューに並んだフレームを取り出して onTransmit に渡す
    private func transmit() {
        let qi = VirtioMMIO.txQueue
        guard queues[qi].ready != 0 else { return }
        let end = availIdx(queues[qi])
        var did = false
        var guardCount = 0
        while queues[qi].lastAvail != end && guardCount < Int(queues[qi].size) * 2 {
            guardCount += 1
            let head = nextAvailHead(queues[qi])
            var bytes: [UInt8] = []
            for d in chain(queues[qi], head: head) where !d.writable {
                guard d.len > 0, d.len <= 65536, let p = ram.pointer(d.addr, count: d.len) else { continue }
                bytes.append(contentsOf: UnsafeRawBufferPointer(start: p, count: d.len))
            }
            if bytes.count > VirtioMMIO.netHeaderSize {
                onTransmit?(Array(bytes[VirtioMMIO.netHeaderSize...]))
            }
            pushUsed(queues[qi], head: head, len: 0)
            queues[qi].lastAvail &+= 1
            did = true
        }
        if did { interruptStatus |= 1 }
    }

    /// 取っておいたフレームを、OS が並べた受け取り用の入れ物に書く
    private func deliverPending() {
        let qi = VirtioMMIO.rxQueue
        guard queues[qi].ready != 0 else { return }
        var did = false
        lock.lock()
        while !pending.isEmpty {
            if queues[qi].lastAvail == availIdx(queues[qi]) { break }       // 入れ物が無い: あとで
            let head = nextAvailHead(queues[qi])
            // ヘッダ（10 バイトの 0）+ フレームを、入れ物の記述子に順に詰める
            let full = [UInt8](repeating: 0, count: VirtioMMIO.netHeaderSize) + pending.removeFirst()
            var written = 0
            for d in chain(queues[qi], head: head) where d.writable {
                if written >= full.count { break }
                let n = min(d.len, full.count - written)
                guard n > 0, let p = ram.pointer(d.addr, count: n) else { continue }
                full.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress! + written, byteCount: n) }
                written += n
            }
            pushUsed(queues[qi], head: head, len: written)
            queues[qi].lastAvail &+= 1
            did = true
        }
        hasPending = !pending.isEmpty
        lock.unlock()
        if did { interruptStatus |= 1 }
    }
}

// ======================================================================
// MARK: - VNetDriver.swift
// ======================================================================

// MARK: - ゲスト側の virtio-net ドライバ（Linux の virtio_net ドライバの代わり）
//
// 仮想 LAN カード（VirtioNet）のレジスタを、Linux と同じ順番で読み書きして使えるようにする。
// ・キューは 2 つ: 0 = 受け取り用、1 = 送り出し用（古い形 = legacy の virtio-mmio）
// ・受け取り用には、あらかじめ空の入れ物（2KB）を並べておく。カードが届いたフレームを書いてくれる
// ・送るときは、入れ物に [ヘッダ 10 バイト][フレーム] を書いて、avail リングに並べて「通知」する
// すべて 1 本のキュー（VNetMachine.queue）の上で呼ぶこと
final class VirtioNetDriver: @unchecked Sendable {
    let dev: VirtioNet
    let ram: GuestRAM
    let qsize = 256
    let bufSize = 2048
    private(set) var mac: [UInt8] = []

    /// 1 本のキュー（記述子表・avail・used と、入れ物）
    private struct Ring {
        let ram: GuestRAM
        let size: Int
        var desc: UInt64 = 0, avail: UInt64 = 0, used: UInt64 = 0
        var bufs: [UInt64] = []
        var lastUsed: UInt16 = 0
        var availIdx: UInt16 = 0

        func writeDesc(_ i: Int, len: Int, writable: Bool) {
            let d = desc + 16 * UInt64(i)
            ram.store64(d, bufs[i])
            ram.store32(d + 8, UInt32(len))
            ram.store16(d + 12, writable ? VirtioMMIO.descWrite : 0)
            ram.store16(d + 14, 0)
        }

        /// 入れ物 i を avail リングに積む（カードに見せるのは publish で）
        mutating func offer(_ i: Int) {
            ram.store16(avail + 4 + 2 * UInt64(Int(availIdx) % size), UInt16(i))
            availIdx &+= 1
        }

        /// 積んだ分をカードに見せる
        func publish() { ram.store16(avail + 2, availIdx) }

        /// カードが使い終わった入れ物を 1 つ取る（無ければ nil）
        mutating func takeUsed() -> (id: Int, len: Int)? {
            guard lastUsed != ram.load16(used + 2) else { return nil }
            let slot = used + 4 + 8 * UInt64(Int(lastUsed) % size)
            lastUsed &+= 1
            return (Int(ram.load32(slot)), Int(ram.load32(slot + 4)))
        }
    }
    private var rx: Ring
    private var tx: Ring
    private var txFree: [Int] = []
    /// まだ入れ物が空かず送れていないフレーム
    private var txWaiting: [[UInt8]] = []

    /// 届いたフレーム（ヘッダを除いたイーサネットのフレーム）
    var onReceive: (([UInt8]) -> Void)?

    init(dev: VirtioNet, ram: GuestRAM) {
        self.dev = dev
        self.ram = ram
        rx = Ring(ram: ram, size: qsize)
        tx = Ring(ram: ram, size: qsize)
    }

    struct DriverError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    private func r32(_ off: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: dev.read(off, size: 4)) }
    private func w32(_ off: UInt64, _ v: UInt32) { dev.write(off, size: 4, value: UInt64(v)) }

    /// Linux の virtio_mmio + virtio_net と同じ手順でカードを準備する
    func start() throws {
        typealias R = VirtioMMIO.Reg
        guard r32(R.magic) == VirtioMMIO.magicValue else { throw DriverError("virtio の目印がありません") }
        guard r32(R.deviceID) == VirtioMMIO.deviceNet else { throw DriverError("ネットワークのカードではありません") }
        let ackDriver = VirtioMMIO.statusAcknowledge | VirtioMMIO.statusDriver
        w32(R.status, 0)                                   // リセット
        w32(R.status, VirtioMMIO.statusAcknowledge)        // 見つけた
        w32(R.status, ackDriver)                           // 使い方が分かる
        w32(R.deviceFeaturesSel, 0)
        let features = r32(R.deviceFeatures)
        w32(R.driverFeaturesSel, 0)
        w32(R.driverFeatures, features & UInt32(VirtioMMIO.featureNetMAC))   // MAC アドレスだけ使う
        w32(R.guestPageSize, 4096)
        mac = (0..<6).map { UInt8(truncatingIfNeeded: dev.read(R.config + UInt64($0), size: 1)) }
        rx = setupQueue(VirtioMMIO.rxQueue)
        tx = setupQueue(VirtioMMIO.txQueue)
        // 受け取り用: 空の入れ物を全部並べる
        for i in 0..<qsize {
            rx.writeDesc(i, len: bufSize, writable: true)
            rx.offer(i)
        }
        rx.publish()
        txFree = Array(0..<qsize)
        w32(R.status, ackDriver | VirtioMMIO.statusDriverOK)   // 使い始める
        w32(R.queueNotify, UInt32(VirtioMMIO.rxQueue))
    }

    /// キューを 1 つ用意する（古い形: ページ番号 = PFN で場所を伝える）
    private func setupQueue(_ q: Int) -> Ring {
        typealias R = VirtioMMIO.Reg
        w32(R.queueSel, UInt32(q))
        precondition(Int(r32(R.queueNumMax)) >= qsize)
        w32(R.queueNum, UInt32(qsize))
        w32(R.queueAlign, 4096)
        // 記述子表 (16 × n) + avail (4 + 2n + 2)、used は 4096 の倍数から (4 + 8n + 2)
        let n = UInt64(qsize)
        let availEnd = 16 * n + 4 + 2 * n + 2
        let usedOff = (availEnd + 4095) / 4096 * 4096
        let total = Int(usedOff + 4 + 8 * n + 2)
        let area = ram.alloc(total, align: 4096)
        var r = Ring(ram: ram, size: qsize)
        r.desc = area
        r.avail = area + 16 * n
        r.used = area + usedOff
        r.bufs = (0..<qsize).map { _ in ram.alloc(bufSize, align: 64) }
        w32(R.queuePFN, UInt32(area / 4096))
        return r
    }

    /// フレームを送る（入れ物が無ければ、空くまで待たせる）
    func send(_ frame: [UInt8]) {
        txWaiting.append(frame)
        reclaimTX()
        flushTX()
    }

    private func flushTX() {
        let hdr = VirtioMMIO.netHeaderSize
        var did = false
        while !txWaiting.isEmpty, let i = txFree.popLast() {
            let frame = txWaiting.removeFirst()
            let p = ram.pointer(tx.bufs[i])
            p.initializeMemory(as: UInt8.self, repeating: 0, count: hdr)
            let n = min(frame.count, bufSize - hdr)
            frame.withUnsafeBytes { (p + hdr).copyMemory(from: $0.baseAddress!, byteCount: n) }
            tx.writeDesc(i, len: hdr + n, writable: false)
            tx.offer(i)
            did = true
        }
        if did {
            tx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.txQueue))   // → カードが onTransmit に渡す
        }
    }

    /// 送り終わった入れ物を回収する
    private func reclaimTX() {
        while let u = tx.takeUsed() {
            if u.id < qsize { txFree.append(u.id) }
        }
    }

    /// 割り込みが来ていれば、届いたフレームを取り出す（カードから知らせがあったときに呼ぶ）
    func poll() {
        guard dev.interruptLine else { return }
        w32(VirtioMMIO.Reg.interruptACK, r32(VirtioMMIO.Reg.interruptStatus))   // 割り込みを受け取った
        reclaimTX()
        flushTX()
        let hdr = VirtioMMIO.netHeaderSize
        var reposted = false
        while let u = rx.takeUsed() {
            guard u.id < qsize else { continue }
            if u.len > hdr {
                let p = ram.pointer(rx.bufs[u.id]) + hdr
                onReceive?([UInt8](UnsafeRawBufferPointer(start: p, count: min(u.len, bufSize) - hdr)))
            }
            rx.offer(u.id)                                 // 入れ物を戻す
            reposted = true
        }
        if reposted {
            rx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.rxQueue))
        }
    }
}

// ======================================================================
// MARK: - UserNet.swift
// ======================================================================

// MARK: - アプリの中の小さなルーター（ユーザーモードの NAT。QEMU の「SLIRP」と同じ考え方）
//
// ゲストの eth0 から出たイーサネットのフレームを受け取り、中身の TCP / UDP を
// iPad の普通の通信（Network.framework）に置き換えて外に出す。返事はフレームに組み立て直してゲストに返す。
//
//   ゲスト 10.0.2.15 ── ルーター 10.0.2.2（＝このクラス）── iPad の通信 ── インターネット
//                        DNS は 10.0.2.3（iPad の名前解決を使う）
//
// ・ARP: 10.0.2.x を聞かれたら、自分の MAC で答える
// ・DHCP: 10.0.2.15 を配る（ルーター 10.0.2.2、DNS 10.0.2.3）
// ・DNS: A レコードは iPad で名前解決して答える。AAAA などは「無し」と答える（IPv4 だけ使う）
// ・TCP: ゲストとの TCP はここで終わらせ、外へは iPad の TCP 接続でつなぐ（中身だけ中継する）
// ・UDP: 宛先ごとに iPad の UDP 接続を作って中継する
// ・ping（ICMP）: 10.0.2.x にだけ答える（iPad のアプリは外へ ping を打てない）
// すべて queue（1 本の直列キュー）の上で動く。

/// 外への接続（TCP か UDP）。受け取りは readMore() を呼ぶたびに 1 回分ずつ届く
protocol UserNetSocket: AnyObject, Sendable {
    func send(_ data: Data)
    /// 送り終わったら閉じる（TCP の FIN）
    func finish()
    func close()
    func readMore()
}

/// 外への接続を作るもの（iPad では Network.framework）。
/// 呼び出し（onReady など）は必ず queue の上で行うこと
protocol UserNetSocketFactory {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (_ error: Bool) -> Void) -> UserNetSocket
    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket
}

final class UserNet: @unchecked Sendable {
    let queue = DispatchQueue(label: "usernet")
    let factory: UserNetSocketFactory
    /// ゲストへ送るフレーム（queue の上で呼ばれる）
    var onFrame: (([UInt8]) -> Void)?
    /// ログ
    var log: ((String) -> Void)?
    /// ゲストの MAC アドレス（届いたフレームから覚える）
    private var guestMAC = Net.guestMAC

    private var ipID: UInt16 = 1
    private var tcps: [TCPKey: TCPConn] = [:]
    private var udps: [UDPKey: UDPFlow] = [:]
    private var timer: DispatchSourceTimer?
    /// 名前を IPv4 にする方法（テストでは偽物に差し替える）。どのスレッドから呼ばれてもよいこと
    var resolver: @Sendable (String) -> [[UInt8]]? = { UserNet.resolveIPv4($0) }
    /// ゲストへの送り直しの回数（queue の上で数える。読むときは queue の上で）
    private(set) var retransmits = 0

    init(factory: UserNetSocketFactory) {
        self.factory = factory
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// ゲストから出たフレーム（どのスレッドからでもよい）
    func input(_ frame: [UInt8]) {
        queue.async { self.handleFrame(frame) }
    }

    // MARK: イーサネット

    private func handleFrame(_ f: [UInt8]) {
        guard let e = EthernetFrame(f) else { return }
        if e.srcIsUnicast { guestMAC = e.src }
        switch e.type {
        case EtherType.arp: handleARP(e.body)
        case EtherType.ipv4: handleIPv4(e.body)
        default: break        // IPv6 などは使わない
        }
    }

    private func sendEthernet(_ type: UInt16, _ payload: [UInt8], to dst: [UInt8]? = nil) {
        onFrame?(Ethernet.frame(dst: dst ?? guestMAC, src: Net.routerMAC, type: type, payload))
    }

    // MARK: ARP

    private func handleARP(_ p: [UInt8]) {
        guard let a = ARPPacket(p), a.op == ARP.request else { return }      // 問い合わせだけ
        let target = a.targetIP
        guard Net.isLocal(target), target != Net.guestIP else { return }
        let senderMAC = a.senderMAC, senderIP = a.senderIP
        let r = ARP.packet(op: ARP.reply, senderMAC: Net.routerMAC, senderIP: target, targetMAC: senderMAC, targetIP: senderIP)
        sendEthernet(EtherType.arp, r, to: senderMAC)
    }

    // MARK: IPv4

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p), !pkt.isFragment else { return }   // 分割されたものは扱わない（MTU 1500 なので普通は来ない）
        switch pkt.proto {
        case IPProto.icmp: handleICMP(src: pkt.src, dst: pkt.dst, pkt.body)
        case IPProto.tcp: handleTCP(dst: pkt.dst, pkt.body)
        case IPProto.udp: handleUDP(dst: pkt.dst, pkt.body)
        default: break
        }
    }

    private func sendIPv4(proto: UInt8, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8], to mac: [UInt8]? = nil) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: src, dst: dst, dontFragment: dontFragment, body)
        ipID &+= 1
        sendEthernet(EtherType.ipv4, pkt, to: mac)
    }

    /// ゲストが指定した宛先 IP を、iPad 側でつなぐ相手の名前にする（10.0.2.x・ループバック・マルチキャストはつながない）
    private func hostFor(_ ip: [UInt8]) -> String? {
        if Net.isLocal(ip) || ip[0] == 127 || ip[0] == 0 || ip[0] >= 224 { return nil }
        return ip.ipString
    }

    // MARK: ICMP（ping）

    private func handleICMP(src: [UInt8], dst: [UInt8], _ b: [UInt8]) {
        guard b.count >= 8, b[0] == 8, Net.isLocal(dst) else { return }    // echo request だけ
        var r = b
        r[0] = 0; r[2] = 0; r[3] = 0                                        // echo reply
        r.setBE16(Checksum.internet(r), at: 2)
        sendIPv4(proto: IPProto.icmp, src: dst, dst: src, r)
    }

    // MARK: UDP

    private struct UDPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }
    private final class UDPFlow: @unchecked Sendable {
        var sock: UserNetSocket?
        var last = Date()
    }

    private func sendUDP(src: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) {
        let u = UDPDatagram.build(src: src, dst: Net.guestIP, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, src: src, dst: Net.guestIP, u)
    }

    private func handleUDP(dst: [UInt8], _ b: [UInt8]) {
        guard let d = UDPDatagram(b) else { return }
        if d.dport == Port.dhcpServer { handleDHCP(d.payload); return }
        if dst == Net.dns && d.dport == Port.dns { handleDNS(d.payload, sport: d.sport); return }
        guard let host = hostFor(dst) else { return }
        let sport = d.sport, dport = d.dport
        let key = UDPKey(sport: sport, dst: dst, dport: dport)
        let flow: UDPFlow
        if let f = udps[key] { flow = f } else {
            let f = UDPFlow()
            let sock = factory.udp(host: host, port: dport, queue: queue, onData: { [weak self, weak f] data in
                guard let self else { return }
                f?.last = Date()
                self.sendUDP(src: dst, sport: dport, dport: sport, Array(data))
            }, onClose: { [weak self] in self?.udps[key] = nil })
            f.sock = sock
            flow = f
            udps[key] = f
            sock.readMore()
        }
        flow.last = Date()
        flow.sock?.send(Data(d.payload))
    }

    // MARK: DHCP

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 1, Array(p[236..<240]) == DHCP.magicCookie else { return }
        let reply: UInt8
        switch DHCP.options(p)[DHCP.Opt.messageType]?.first ?? 0 {
        case DHCP.discover: reply = DHCP.offer
        case DHCP.request: reply = DHCP.ack
        default: return
        }
        var r = [UInt8](repeating: 0, count: 236)
        r[0] = 2; r[1] = 1; r[2] = 6
        r.replaceSubrange(4..<8, with: p[4..<8])           // xid
        r[10] = p[10]; r[11] = p[11]                       // flags
        r.replaceSubrange(16..<20, with: Net.guestIP)      // yiaddr
        r.replaceSubrange(20..<24, with: Net.gateway)      // siaddr
        r.replaceSubrange(28..<44, with: p[28..<44])       // chaddr
        r += DHCP.magicCookie
        r += [DHCP.Opt.messageType, 1, reply]
        r += [DHCP.Opt.serverID, 4] + Net.gateway
        r += [DHCP.Opt.leaseTime, 4, 0, 1, 0x51, 0x80]                     // 86400 秒
        r += [DHCP.Opt.subnetMask, 4, 255, 255, 255, 0]
        r += [DHCP.Opt.router, 4] + Net.gateway
        r += [DHCP.Opt.dnsServer, 4] + Net.dns
        r += [DHCP.Opt.mtu, 2, 0x05, 0xDC]                           // MTU 1500
        r += [DHCP.Opt.end]
        // ブロードキャストで返す（ゲストはまだ IP を持っていないので）
        let u = UDPDatagram.build(src: Net.gateway, dst: Net.broadcastIP, sport: Port.dhcpServer, dport: Port.dhcpClient, r)
        sendIPv4(proto: IPProto.udp, src: Net.gateway, dst: Net.broadcastIP, dontFragment: false, u, to: Net.broadcastMAC)
        log?("[ネット] DHCP \(reply == DHCP.offer ? "OFFER" : "ACK") \(Net.guestIP.ipString)")
    }

    // MARK: DNS

    private func handleDNS(_ q: [UInt8], sport: UInt16) {
        guard q.count >= 12 else { return }
        guard q.be16(at: 4) == 1 else {                    // 質問が 1 つでなければ「できません」
            sendDNS(DNSMessage.reply(to: q, questionEnd: 12, rcode: 4, answers: []), sport: sport)
            return
        }
        guard let question = DNSMessage.question(q) else { return }
        if question.type != 1 || question.name.isEmpty {   // A 以外は「無し」
            sendDNS(DNSMessage.reply(to: q, questionEnd: question.end, rcode: 0, answers: []), sport: sport)
            return
        }
        let queue = self.queue
        let resolver = self.resolver
        DispatchQueue.global(qos: .userInitiated).async {
            let addrs = resolver(question.name)
            let r = DNSMessage.reply(to: q, questionEnd: question.end, rcode: addrs == nil ? 3 : 0, answers: addrs ?? [])
            queue.async { [weak self] in self?.sendDNS(r, sport: sport) }
        }
    }

    private func sendDNS(_ r: [UInt8], sport: UInt16) {
        sendUDP(src: Net.dns, sport: Port.dns, dport: sport, r)
    }

    /// 名前を IPv4 アドレスにする（nil = 見つからない）
    static func resolveIPv4(_ name: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if a.pointee.ai_family == AF_INET, let sa = a.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    let v = sin.pointee.sin_addr.s_addr       // ネットワークの順（ビッグエンディアン）のまま
                    let b: [UInt8] = [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                                      UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
                    if !out.contains(b) { out.append(b) }
                }
            }
            p = a.pointee.ai_next
        }
        return out.isEmpty ? nil : Array(out.prefix(8))
    }

    // MARK: TCP

    private struct TCPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }

    private final class TCPConn: @unchecked Sendable {
        let key: TCPKey
        var sock: UserNetSocket?
        var state = State.connecting
        enum State { case connecting, synSent, established, closed }
        var rcvNxt: UInt32 = 0            // ゲストから次に来るはずの番号
        let iss: UInt32                   // こちらの最初の番号
        var sndUna: UInt32                // ゲストがまだ受け取ったと言っていない最初の番号
        var sndNxt: UInt32                // 次に送る番号
        /// 外から来た（まだ受け取りの返事が無い）データ。buf[bufPos...] が sndUna から先。
        /// 先頭を消すとそのたびに全部ずらすことになって遅いので、位置で覚えてときどき詰める
        var buf = [UInt8]()
        var bufPos = 0
        var pending: Int { buf.count - bufPos }
        var window: UInt32 = 65535
        var mss = 536
        var remoteEOF = false             // 外の相手が閉じた
        var finSent = false
        var guestFIN = false
        var lastProgress = Date()
        var retries = 0
        var reading = false
        var lastActivity = Date()
        init(key: TCPKey) {
            self.key = key
            iss = UInt32.random(in: 0...UInt32.max)
            sndUna = iss
            sndNxt = iss
        }

        /// ゲストが受け取ったと言った分を buf から外す
        func dropAcked(_ n: Int) {
            guard n > 0 else { return }
            bufPos += n
            if bufPos == buf.count { buf.removeAll(keepingCapacity: true); bufPos = 0 }
            else if bufPos > 131072 && bufPos * 2 > buf.count { buf.removeFirst(bufPos); bufPos = 0 }
        }
    }

    static let maxBuffered = 512 * 1024

    /// 外の相手のふりをして、ゲストへセグメントを送る
    private func sendTCP(_ c: TCPConn, _ flags: TCPFlags, seq: UInt32, payload: ArraySlice<UInt8> = [], mss: Bool = false) {
        // こちらの受け取り窓は 65535 のまま: 外へ送り切れていない分は気にしない（iPad の接続が受け取る）
        let seg = TCPSegment.build(src: c.key.dst, dst: Net.guestIP, sport: c.key.dport, dport: c.key.sport,
                                   seq: seq, ack: c.rcvNxt, flags: flags, mss: mss, payload: payload)
        sendIPv4(proto: IPProto.tcp, src: c.key.dst, dst: Net.guestIP, seg)
    }

    private func sendSYNACK(_ c: TCPConn) { sendTCP(c, [.syn, .ack], seq: c.iss, mss: true) }

    /// 外の相手のふりをして、ゲストへ RST を送る
    private func sendRST(remote: [UInt8], remotePort: UInt16, guestPort: UInt16, seq: UInt32, ack: UInt32) {
        let seg = TCPSegment.build(src: remote, dst: Net.guestIP, sport: remotePort, dport: guestPort,
                                   seq: seq, ack: ack, flags: [.rst, .ack], window: 0)
        sendIPv4(proto: IPProto.tcp, src: remote, dst: Net.guestIP, seg)
    }

    private func sendRST(_ c: TCPConn, seq: UInt32) {
        sendRST(remote: c.key.dst, remotePort: c.key.dport, guestPort: c.key.sport, seq: seq, ack: c.rcvNxt)
    }

    private func handleTCP(dst: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b) else { return }
        let payload = b[h.headerLength...]
        let key = TCPKey(sport: h.sport, dst: dst, dport: h.dport)
        guard let c = tcps[key] else {
            open(key, h, b)
            return
        }

        c.lastActivity = Date()
        if h.flags.contains(.rst) { remove(c); return }
        if h.flags.contains(.syn) {
            // SYN の送り直し: SYN+ACK を送り直す
            if c.state == .synSent { sendSYNACK(c) }
            return
        }
        if h.flags.contains(.ack) {
            let acked = h.ack &- c.sndUna
            let inFlight = c.sndNxt &- c.sndUna
            if acked > 0 && acked <= inFlight {
                var n = Int(acked)
                if c.state == .synSent { c.state = .established; n -= 1 }     // SYN の分
                c.dropAcked(min(n, c.pending))
                c.sndUna = h.ack
                c.lastProgress = Date()
                c.retries = 0
                readIfRoom(c)
            }
            c.window = UInt32(h.window)
        }
        if c.state == .synSent || c.state == .connecting { return }
        // データ
        var needAck = false
        if !payload.isEmpty {
            // 送り直しで前の分と重なっていたら、新しい所だけ外へ送る（先の分は捨てて、送り直してもらう）
            let before = Int32(bitPattern: c.rcvNxt &- h.seq)
            if before >= 0 && Int(before) < payload.count {
                let rest = payload.dropFirst(Int(before))
                c.sock?.send(Data(rest))
                c.rcvNxt &+= UInt32(rest.count)
            }
            needAck = true
        }
        if h.flags.contains(.fin) && h.seq &+ UInt32(payload.count) == c.rcvNxt && !c.guestFIN {
            c.guestFIN = true
            c.rcvNxt &+= 1
            c.sock?.finish()
            needAck = true
        }
        let before = c.sndNxt
        pump(c)
        if needAck && c.sndNxt == before { sendTCP(c, .ack, seq: c.sndNxt) }
        checkDone(c)
    }

    /// 知らない接続のセグメント: SYN なら外へつなぎに行く（つながったら SYN+ACK を返す）。ほかは RST で終わらせてもらう
    private func open(_ key: TCPKey, _ h: TCPHeader, _ b: [UInt8]) {
        if h.flags.contains(.rst) { return }
        guard h.flags.contains(.syn), !h.flags.contains(.ack), let host = hostFor(key.dst) else {
            let payloadCount = UInt32(b.count - h.headerLength)
            let extra: UInt32 = h.flags.isDisjoint(with: [.syn, .fin]) ? 0 : 1
            sendRST(remote: key.dst, remotePort: key.dport, guestPort: key.sport,
                    seq: h.flags.contains(.ack) ? h.ack : 0, ack: h.seq &+ payloadCount &+ extra)
            return
        }
        let c = TCPConn(key: key)
        c.rcvNxt = h.seq &+ 1
        c.window = UInt32(h.window)
        if let m = TCPHeader.mss(b, headerLength: h.headerLength) { c.mss = min(1460, m) }
        tcps[key] = c
        c.sock = factory.tcp(host: host, port: key.dport, queue: queue, onReady: { [weak self, weak c] in
            guard let self, let c, c.state == .connecting else { return }
            c.state = .synSent
            self.sendSYNACK(c)
            c.sndNxt = c.iss &+ 1
            c.lastProgress = Date()
            self.readIfRoom(c)
        }, onData: { [weak self, weak c] d in
            guard let self, let c else { return }
            c.reading = false
            c.buf.append(contentsOf: d)
            c.lastActivity = Date()
            self.pump(c)
            self.readIfRoom(c)
        }, onClose: { [weak self, weak c] error in
            guard let self, let c else { return }
            c.reading = false
            if c.state == .connecting || (error && c.state != .established) {
                // つながらなかった
                self.sendRST(c, seq: c.iss &+ 1)
                self.remove(c)
                return
            }
            c.remoteEOF = true
            self.pump(c)
        })
    }

    /// 外から来たデータを、ゲストの窓の分だけ送る。外が閉じていて全部送ったら FIN
    private func pump(_ c: TCPConn) {
        guard c.state == .established else { return }
        while !c.finSent {
            let sent = Int(c.sndNxt &- c.sndUna)
            let unsent = c.pending - sent
            if unsent <= 0 {
                if c.remoteEOF {
                    sendTCP(c, [.fin, .ack], seq: c.sndNxt)
                    c.sndNxt &+= 1
                    c.finSent = true
                    c.lastProgress = Date()
                }
                break
            }
            let room = Int(c.window) - sent
            if room <= 0 { break }
            let n = min(unsent, c.mss, room)
            let start = c.bufPos + sent
            sendTCP(c, [.ack, .psh], seq: c.sndNxt, payload: c.buf[start..<(start + n)])
            c.sndNxt &+= UInt32(n)
        }
        checkDone(c)
    }

    private func readIfRoom(_ c: TCPConn) {
        guard !c.reading, !c.remoteEOF, c.state == .established || c.state == .synSent,
              c.pending < UserNet.maxBuffered, let s = c.sock else { return }
        c.reading = true
        s.readMore()
    }

    private func checkDone(_ c: TCPConn) {
        // 両方が閉じて、こちらの FIN も受け取ってもらえたら終わり
        if c.guestFIN && c.finSent && c.sndUna == c.sndNxt { remove(c) }
    }

    private func remove(_ c: TCPConn) {
        if c.state == .closed { return }
        c.state = .closed
        c.sock?.close()
        c.sock = nil
        if tcps[c.key] === c { tcps[c.key] = nil }
    }

    // MARK: 時間で見るもの（送り直しと、古い接続の片付け）

    private func tick() {
        let now = Date()
        for c in Array(tcps.values) {
            if c.state == .synSent && now.timeIntervalSince(c.lastProgress) > 1 {
                c.retries += 1
                if c.retries > 6 { remove(c); continue }
                sendSYNACK(c)
                c.lastProgress = now
            } else if c.state == .established && c.sndNxt == c.sndUna && c.window == 0 && c.pending > 0
                        && now.timeIntervalSince(c.lastProgress) > 1 {
                // ゲストの窓が 0 のまま（送っている途中のものは無い）: 1 バイトだけ送って、窓が開いたかを探る（持続タイマー）
                c.window = 1
                c.lastProgress = now
                pump(c)
            } else if c.state == .established && c.sndNxt != c.sndUna && now.timeIntervalSince(c.lastProgress) > 1 {
                // 受け取りの返事が来ない: 先頭から送り直す（窓が 0 で探っているだけのときは、回数に数えない）
                if c.window > 1 { c.retries += 1 }
                retransmits += 1
                if c.retries > 10 {
                    sendRST(c, seq: c.sndNxt)
                    remove(c); continue
                }
                c.sndNxt = c.sndUna
                c.finSent = false
                c.lastProgress = now
                if c.window == 0 { c.window = 1 }       // 窓が 0 のままなら 1 バイトだけ送って様子を見る
                pump(c)
            } else if now.timeIntervalSince(c.lastActivity) > 600 {
                remove(c)
            }
        }
        for (k, u) in udps where now.timeIntervalSince(u.last) > 60 {
            u.sock?.close()
            udps[k] = nil
        }
    }
}

// ======================================================================
// MARK: - UserNetApple.swift
// ======================================================================

#if canImport(Network)
import Foundation
import Network

// MARK: - UserNet の外への接続を、iPad の Network.framework で作る

final class NWUserNetFactory: UserNetSocketFactory, @unchecked Sendable {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (Bool) -> Void) -> UserNetSocket {
        let opts = NWProtocolTCP.Options()
        opts.noDelay = true
        opts.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: opts)
        // iPad の「プロキシ」（iCloud プライベートリレーなど）を通さず、相手に直接つなぐ。
        // プロキシを通ると、暗号化していない http の要求がプロキシに読まれて「400 Bad Request」で断られることがある
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: params)
        let s = NWUserNetSocket(c, datagram: false, onData: onData, onClose: onClose)
        c.stateUpdateHandler = { [weak s] st in
            guard let s else { return }
            switch st {
            case .ready:
                if !s.readyCalled { s.readyCalled = true; onReady() }
            case .failed, .cancelled:
                s.closed(error: true)
            default:
                // .waiting（つながらない・ネットが無いなど）は、iPad が自分でやり直すので切らない
                // （connectionTimeout を過ぎると failed になる）
                break
            }
        }
        c.start(queue: queue)
        return s
    }

    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket {
        let params = NWParameters.udp
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 53, using: params)
        let s = NWUserNetSocket(c, datagram: true, onData: onData, onClose: { _ in onClose() })
        c.stateUpdateHandler = { [weak s] st in
            switch st {
            case .failed, .cancelled: s?.closed(error: true)
            default: break
            }
        }
        c.start(queue: queue)
        return s
    }
}

final class NWUserNetSocket: UserNetSocket, @unchecked Sendable {
    let conn: NWConnection
    let datagram: Bool
    let onData: @Sendable (Data) -> Void
    let onClose: @Sendable (Bool) -> Void
    var readyCalled = false
    private var done = false

    init(_ c: NWConnection, datagram: Bool, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        conn = c; self.datagram = datagram; self.onData = onData; self.onClose = onClose
    }

    func closed(error: Bool) {
        if done { return }
        done = true
        conn.cancel()
        onClose(error)
    }

    func send(_ data: Data) {
        if done { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func finish() {
        if done || datagram { return }
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        if done { return }
        done = true
        conn.cancel()
    }

    func readMore() {
        if done { return }
        if datagram {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.done else { return }
                if let d = data, !d.isEmpty { self.onData(d) }
                if error != nil { self.closed(error: true); return }
                self.readMore()          // UDP は続けて受け取る
            }
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let d = data, !d.isEmpty {
                self.onData(d)
                if isComplete { self.closed(error: false) }
                return
            }
            if isComplete || error != nil { self.closed(error: error != nil) }
            else { self.readMore() }
        }
    }
}
#endif
