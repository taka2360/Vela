import SwiftUI
import WebKit

// MARK: - スクリプトレットの自己テスト（開発者パネルの「広告ブロック」から）
//
// 本物の WKWebView に、今の道具（uBO から作った JSON）とテスト用のルールで組み立てたスクリプトを、タブと同じ形で入れる
// （main は WKContentWorld.page・isolated は .defaultClient・atDocumentStart・全フレーム）。
// https://vela-selftest.invalid/ として HTML を開き、ページの中で道具が効いたかを確かめて知らせてもらう。
// node のテスト（tools/ubo/test_assembled.mjs）では確かめられない XHR・DOM・world の違いを、iPad の WebKit で見るためのもの。
// 通信はしない（fetch・XHR は blob: の URL に向ける）

@MainActor
final class ScriptletSelfTest: ObservableObject {
    struct Result: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
        static func == (a: Result, b: Result) -> Bool { a.name == b.name && a.ok == b.ok && a.detail == b.detail }
    }

    @Published private(set) var running = false
    @Published private(set) var results: [Result] = []
    @Published private(set) var summary = "まだ動かしていません"

    private var webView: WKWebView?
    private var bridge: SelfTestBridge?
    private var timeout: Task<Void, Never>?

    func run(library: ScriptletLibrary?) {
        guard !running else { return }
        guard let library, !library.isEmpty else {
            summary = "道具がありません（広告ブロックの画面で「道具を確かめる」）"
            return
        }
        let (out, unknown) = ScriptletSelfTestPage.assemble(library: library)
        var notes: [String] = []
        if !unknown.isEmpty { notes.append("道具に無い: \(unknown.keys.sorted().joined(separator: ", "))") }

        running = true
        results = []
        summary = "動かしています…（uBO \(library.ubo)・ルール \(out.filters.count) 個）"
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        if !out.main.isEmpty { content.addUserScript(WKUserScript(source: out.main, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)) }
        if !out.isolated.isEmpty { content.addUserScript(WKUserScript(source: out.isolated, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)) }
        let b = SelfTestBridge()
        b.onResults = { [weak self] list in
            let me = self
            Task { @MainActor in me?.finish(list, notes: notes) }
        }
        content.add(b, name: "velaSelfTest")
        bridge = b
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView = wv
        wv.loadHTMLString(ScriptletSelfTestPage.page, baseURL: URL(string: "https://\(ScriptletSelfTestPage.host)/"))
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.running else { return }
            self.finish([], notes: notes + ["15 秒たっても結果が来ません"])
        }
    }

    private func finish(_ list: [[String: Any]], notes: [String]) {
        guard running else { return }
        timeout?.cancel()
        results = list.map { Result(name: $0["name"] as? String ?? "?", ok: $0["ok"] as? Bool ?? false, detail: $0["detail"] as? String ?? "") }
        let ng = results.filter { !$0.ok }.count
        summary = (results.isEmpty ? "結果がありません" : ng == 0 ? "全部 ○（\(results.count) 個）" : "× が \(ng) 個（\(results.count) 個中）")
            + (notes.isEmpty ? "" : "・" + notes.joined(separator: "・"))
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "velaSelfTest")
        webView = nil
        bridge = nil
        running = false
    }
}

final class SelfTestBridge: NSObject, WKScriptMessageHandler {
    var onResults: (([[String: Any]]) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onResults?(message.body as? [[String: Any]] ?? [])
    }
}

@MainActor
struct ScriptletSelfTestView: View {
    let adblock: AdBlocker
    @StateObject private var test = ScriptletSelfTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("スクリプトレットの自己テスト").font(.subheadline)
                Spacer()
                if test.running { ProgressView() }
                Button("動かす") { test.run(library: adblock.currentScriptletLibrary) }
                    .disabled(test.running)
            }
            DevLine(test.summary)
            ForEach(test.results) { r in
                DevLine("\(r.ok ? "○" : "×") \(r.name)\(r.ok || r.detail.isEmpty ? "" : "  [\(r.detail.prefix(200))]")")
                    .foregroundColor(r.ok ? nil : .red)
            }
        }
    }
}
