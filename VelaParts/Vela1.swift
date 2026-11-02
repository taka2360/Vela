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
            Text("広告ブロック: \(store.adblock.enabled ? "使う" : "止めている")・VNet 用のルール \(store.adblock.ruleCount) 個・止めた数 \(store.adblock.totalBlocked)")
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
