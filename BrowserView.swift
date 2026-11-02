import SwiftUI
import WebKit

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
