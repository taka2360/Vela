import SwiftUI

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
