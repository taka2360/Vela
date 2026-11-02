import SwiftUI

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
