import SwiftUI

// MARK: - 広告ブロックの設定（「…」メニューから）

struct AdBlockView: View {
    @ObservedObject var adblock: AdBlocker
    @Environment(\.dismiss) private var dismiss
    @State private var customURL = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(closeLabel: "完了", close: { dismiss() }) {
                Text("広告ブロック").font(.headline)
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
                    Text("リスト（リストが決めた間隔で自動で更新。無ければ 4 日ごと）")
                }
                Section {
                    ScriptletStatusRow(adblock: adblock)
                } header: {
                    Text("スクリプトレット（YouTube などの広告をページの中で消す）")
                } footer: {
                    Text("切り替えは、今見ているページを読み直して効かせます。ほかのタブは次にページを開いたときから。")
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
    ・スクリプトレット（uBO の ##+js(…)）: YouTube の動画広告のように、ページ自身のデータに入って届く広告は、通信を止めても消えません。uBlock filters の行と、uBlock Origin の道具（GPLv3。Vela の GitHub が毎日 uBO の最新版から作って署名したもの）で、ページの中で消します。YouTube が仕組みを変えても、リストと道具の自動更新でついていきます。サーバー側で動画に混ぜた広告は消せません。
    ・対応しない書き方（AdGuard のスクリプト・正規表現・$redirect・##^ など）は読み飛ばします。リストの行の「対応外」がその数です。
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
        var s = "通信 \(list.networkRules)・隠す \(list.cosmeticRules)"
        if let n = list.scriptletRules, n > 0 { s += "・スクリプト \(n)" }
        s += "・対応外 \(list.unsupported)・更新 \(date)"
        if let h = list.expiresHours { s += h % 24 == 0 ? "（\(h / 24) 日ごと）" : "（\(h) 時間ごと）" }
        if AdBlocker.isTrusted(list) { s += "・信頼する" }
        return s
    }
}

struct ScriptletStatusRow: View {
    @ObservedObject var adblock: AdBlocker
    @State private var checking = false

    var body: some View {
        HStack {
            if checking { ProgressView().padding(.trailing, 4) }
            VStack(alignment: .leading, spacing: 2) {
                Text("道具: \(adblock.scriptletStatus)").font(.system(size: 13))
                Text("使えるルール \(adblock.scriptletRuleCount) 個").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("道具を確かめる") {
                checking = true
                Task {
                    await adblock.updateScriptletsIfDue(force: true)
                    checking = false
                }
            }
            .disabled(checking)
        }
    }
}
