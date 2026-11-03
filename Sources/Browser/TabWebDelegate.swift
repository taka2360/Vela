import SwiftUI
import WebKit

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
        // サブフレーム: 読み込む前にそのホストのスクリプトレットを足す（uBO もフレームのホストごとに選ぶ）
        if !main, let u = navigationAction.request.url { tab.noteSubframe(u) }
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
