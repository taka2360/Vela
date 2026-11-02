import SwiftUI

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
