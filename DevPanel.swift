import SwiftUI

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
