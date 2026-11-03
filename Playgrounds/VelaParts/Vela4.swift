// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 4 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - TabWebDelegate.swift
// ======================================================================

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

    /// HTTPS-First で https に上げたが開けなかったときのページ（標準の通信・VNet で同じ）。
    /// ボタンは「http のまま開く」（http の URL）→「再試行」（開けなかった URL）の順に、actions で合言葉を作る
    static func httpsFirst(http: URL, failing: URL, message: String, actions: PageActions) -> String {
        html(title: "https では開けませんでした", lines: [
            "\(http.host ?? "") は、安全な接続（https）に対応していないようです。",
            "http のまま開くと、通信の中身を途中で見られたり、書き換えられたりする可能性があります。"],
            detail: "\(failing.absoluteString)\n\(message)",
            buttons: [Button(label: "http のまま開く", nonce: actions.make("openHTTP", url: http), primary: false),
                      Button(label: "再試行", nonce: actions.make("retry", url: failing), primary: true)],
            kind: "httpsFirst")
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
        return id
    }

    func update(_ id: Int, _ change: (inout NetRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard id > 0, let i = positions[id], i < records.count, records[i].id == id else { return }
        change(&records[i])
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
        lock.lock(); records = []; positions = [:]; lock.unlock()
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
// ・自動更新はリストの「! Expires:」ごと（無ければ 4 日。uBO の Quick fixes は 8 時間）。起動したときと、アプリが前に来たとき。手で「今すぐ更新」もできる
// ・!#include は落とすときに展開して 1 つのファイルにする（FilterPreparser.expandIncludes）
// ・スクリプトレット（##+js）: 道具（uBO から作った JSON）を 1 日ごとに Vela の GitHub から落とし、署名を確かめてから使う（ScriptletVerify）。
//   trusted の道具は、組み込みの一覧（catalog）で trusted にしたリストの行だけ使う（保存ファイルの id や URL では信じない）

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
    nonisolated static var catalog: [FilterListInfo] { FilterCatalog.lists }
    /// 「! Expires:」が無いリストの更新の間隔
    static let updateInterval: TimeInterval = 4 * 86_400
    /// スクリプトレットの道具（Vela の GitHub。Actions が uBO から作って署名したもの）
    nonisolated static let scriptletsURL = "https://raw.githubusercontent.com/taka2360/Vela/main/resources/ubo-scriptlets.json"
    static let scriptletsInterval: TimeInterval = 86_400
    nonisolated static let idPrefix = "vela-ab-"

    @Published private(set) var lists: [FilterListInfo] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "準備中…"
    @Published private(set) var enabled = true
    @Published private(set) var disabledSites = Set<String>()
    /// 起動してから止めた数（VNet のタブ）
    @Published private(set) var totalBlocked = 0
    /// スクリプトレットの道具の様子（画面に出す）
    @Published private(set) var scriptletStatus = "まだありません"
    @Published private(set) var scriptletRuleCount = 0
    let box = BlockEngineBox()
    private var scriptletLibrary: ScriptletLibrary?
    private var scriptletIndex = ScriptletIndex()
    private var scriptletCache: [String: ScriptletInjection?] = [:]
    private var scriptletsChecked: Date?
    private var checkingScriptlets = false
    /// 最後に読んだリストのスクリプトレットの行（道具が更新されたら、これで索引を作り直す）
    private var lastScriptletSources: [([ScriptletFilter], Bool)] = []
    /// リスト id → WebKit のルール
    private var netLists: [String: WKContentRuleList] = [:]
    private var cosLists: [String: WKContentRuleList] = [:]
    /// ルールが変わったとき（タブに入れ直す）。userAction: 利用者が ON/OFF を切り替えた（開いているページを読み直す）
    var onRuleListsChanged: (@MainActor (_ userAction: Bool) -> Void)?
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
    nonisolated static var scriptletsFile: URL { folder.appendingPathComponent("ubo-scriptlets.json") }
    nonisolated static var scriptletsSigFile: URL { folder.appendingPathComponent("ubo-scriptlets.json.sig") }

    nonisolated static func isTrusted(_ l: FilterListInfo) -> Bool { FilterCatalog.isTrusted(l) }

    /// !#if の判定に使う値（UA に Mobile があれば env_mobile）
    nonisolated static var filterEnv: [String] { FilterPreparser.env(userAgent: BrowserIdentity.userAgent) }

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
        scriptletsChecked = saved?.scriptletsChecked
        lists = FilterCatalog.merge(saved: saved?.lists ?? [])
        loadScriptletLibrary()
        let dueIDs = self.dueIDs()
        Task {
            await self.updateScriptletsIfDue()
            if dueIDs.isEmpty { await self.rebuild() } else { await self.update(manual: false, only: dueIDs) }
        }
    }

    /// 更新が要るリスト（ファイルが無い・期限切れ）
    private func dueIDs(now: Date = Date()) -> [String] {
        lists.filter { l in
            guard l.enabled else { return false }
            if !FileManager.default.fileExists(atPath: AdBlocker.textURL(l.id).path) { return true }
            guard let last = l.lastUpdated else { return true }
            let interval = l.expiresHours.map { TimeInterval($0) * 3600 } ?? AdBlocker.updateInterval
            return now.timeIntervalSince(last) > interval
        }.map { $0.id }
    }

    /// アプリが前に来たとき: 期限切れのリストと道具だけ更新する
    func updateIfDue() {
        guard started, !busy else { return }
        let ids = dueIDs()
        Task {
            await self.updateScriptletsIfDue()
            if !ids.isEmpty { await self.update(manual: false, only: ids) }
        }
    }

    // MARK: 設定

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "adblock.enabled")
        box.set(enabled: on, disabledSites: disabledSites)
        log(on ? "広告ブロックを使います" : "広告ブロックを止めました")
        onRuleListsChanged?(true)
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
        onRuleListsChanged?(true)
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
            if var text = result.text {
                // !#include を展開する（同じ場所のものだけ。捨てる !#if の枝の中のものは読まない）
                if text.contains("!#include"), let base = URL(string: l.url) {
                    status = "ダウンロード中 \(n + 1)/\(targets.count): \(l.name)（中のリスト）"
                    let ex = await FilterPreparser.expandIncludes(text, base: base, env: AdBlocker.filterEnv) { u in
                        await AdBlocker.download(u.absoluteString, checkFormat: false).text
                    }
                    text = ex.text
                    if !ex.included.isEmpty { log("\(l.name): 中のリスト \(ex.included.count) 個を読みました") }
                    if !ex.failed.isEmpty { log("⚠️ \(l.name): 読めなかった中のリスト: \(ex.failed.joined(separator: "・"))", level: .warning) }
                }
                do {
                    try Data(text.utf8).write(to: AdBlocker.textURL(l.id), options: .atomic)
                    lists[i].lastUpdated = Date()
                    lists[i].lastError = nil
                    lists[i].expiresHours = FilterPreparser.expiresHours(text)
                    log("✓ \(l.name): \(text.utf8.count / 1024)KB\(lists[i].expiresHours.map { "（\($0) 時間ごと）" } ?? "")")
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

    /// checkFormat: 広告ブロックのリストの形か確かめる（!#include の中のリストは確かめない）
    nonisolated static func download(_ urlString: String, checkFormat: Bool = true) async -> Downloaded {
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
                guard !checkFormat || head.contains("!") || head.contains("[Adblock") || head.contains("##") || head.contains("||") else {
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
        let scriptlets: [ScriptletFilter]
        let trusted: Bool
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
        let enabledLists = lists.filter { $0.enabled }
        let start = Date()
        let env = AdBlocker.filterEnv
        let built: [Built] = await Task.detached(priority: .utility) {
            enabledLists.compactMap { l -> Built? in
                guard let d = try? Data(contentsOf: AdBlocker.textURL(l.id)) else { return nil }
                let p = ABPParser.parse(String(decoding: d, as: UTF8.self), env: env)
                let net = ContentBlockerCompiler.networkJSON(p.network)
                let cos = ContentBlockerCompiler.cosmeticJSON(p.cosmetic)
                return Built(id: l.id, network: p.network, scriptlets: p.scriptlets, trusted: AdBlocker.isTrusted(l),
                             netJSON: net.json, cosJSON: cos.json, networkCount: p.network.count,
                             cosmeticCount: p.cosmetic.count, unsupported: p.unsupported, skipped: net.skipped + cos.skipped)
            }
        }.value
        let engine: BlockEngine = await Task.detached(priority: .utility) {
            BlockEngine(rules: built.flatMap { $0.network })
        }.value
        box.set(engine: engine)
        log("広告ブロック: VNet 用のルール \(engine.ruleCount) 個を作りました（\(Int(Date().timeIntervalSince(start) * 1000))ms）")
        await rebuildScriptlets(built.map { ($0.scriptlets, $0.trusted) })

        var newNet: [String: WKContentRuleList] = [:], newCos: [String: WKContentRuleList] = [:]
        for (n, b) in built.enumerated() {
            status = "WebKit のルールを用意しています \(n + 1)/\(built.count)…"
            guard let i = lists.firstIndex(where: { $0.id == b.id }) else { continue }
            lists[i].networkRules = b.networkCount
            lists[i].cosmeticRules = b.cosmeticCount
            lists[i].unsupported = b.unsupported + b.skipped
            lists[i].scriptletRules = b.scriptlets.count
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
        onRuleListsChanged?(false)
    }

    // MARK: スクリプトレット

    /// 行の束から、ホストごとの索引を作り直す（道具が無ければ空）
    private func rebuildScriptlets(_ sources: [([ScriptletFilter], Bool)]) async {
        lastScriptletSources = sources
        guard let lib = scriptletLibrary else {
            scriptletIndex = ScriptletIndex()
            scriptletCache = [:]
            scriptletRuleCount = 0
            return
        }
        let idx: ScriptletIndex = await Task.detached(priority: .utility) {
            var idx = ScriptletIndex()
            for (rules, trusted) in sources { for r in rules { idx.add(r, trusted: trusted, library: lib) } }
            return idx
        }.value
        scriptletIndex = idx
        scriptletCache = [:]
        scriptletRuleCount = idx.size
        var line = "スクリプトレット \(idx.size) 個・道具 uBO \(lib.ubo)（\(lib.count) 個）"
        if idx.rejectedTrust > 0 { line += "・信頼しないリストの trusted \(idx.rejectedTrust) 個を除いた" }
        if idx.badTargets > 0 { line += "・読めないドメイン \(idx.badTargets) 個" }
        log(line)
        if !idx.unknown.isEmpty {
            let top = idx.unknown.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)（\($0.value)）" }
            log("⚠️ 道具に無いスクリプトレット（リストの方が新しい uBO を前提にしている）: \(top.joined(separator: "・"))", level: .warning)
        }
    }

    /// 置いてある道具を読む（署名を確かめ直す）
    private func loadScriptletLibrary() {
        guard let d = try? Data(contentsOf: AdBlocker.scriptletsFile),
              let sig = try? String(contentsOf: AdBlocker.scriptletsSigFile, encoding: .utf8) else {
            scriptletStatus = "まだありません（ダウンロードします）"
            return
        }
        switch ScriptletVerify.verify(d, signature: sig, current: nil) {
        case .success(let lib):
            scriptletLibrary = lib
            scriptletStatus = "uBO \(lib.ubo)（\(lib.count) 個）・署名 OK"
        case .failure(let e):
            scriptletStatus = "使えません: \(e)"
            log("⚠️ 置いてあるスクリプトレットの道具が使えません: \(e)", level: .warning)
        }
    }

    /// 1 日ごとに道具を落とす（署名・形式・古くないかを確かめたものだけ置き換える）
    func updateScriptletsIfDue(force: Bool = false) async {
        if checkingScriptlets { return }
        if !force, scriptletLibrary != nil, let last = scriptletsChecked, Date().timeIntervalSince(last) < AdBlocker.scriptletsInterval { return }
        checkingScriptlets = true
        defer { checkingScriptlets = false }
        let j = await AdBlocker.fetchData(AdBlocker.scriptletsURL)
        let s = await AdBlocker.fetchData(AdBlocker.scriptletsURL + ".sig")
        scriptletsChecked = Date()
        saveState()
        guard let j, let s, let sigText = String(data: s, encoding: .utf8) else {
            log("⚠️ スクリプトレットの道具をダウンロードできません", level: .warning)
            return
        }
        switch ScriptletVerify.verify(j, signature: sigText, current: scriptletLibrary) {
        case .success(let lib):
            if lib.generated == scriptletLibrary?.generated { return }
            do {
                try j.write(to: AdBlocker.scriptletsFile, options: .atomic)
                try s.write(to: AdBlocker.scriptletsSigFile, options: .atomic)
            } catch {
                log("⚠️ スクリプトレットの道具を保存できません: \(error.localizedDescription)", level: .warning)
                return
            }
            scriptletLibrary = lib
            scriptletStatus = "uBO \(lib.ubo)（\(lib.count) 個）・署名 OK"
            log("スクリプトレットの道具を更新しました: uBO \(lib.ubo)（\(lib.generated ?? "?")）")
            if !lastScriptletSources.isEmpty {
                await rebuildScriptlets(lastScriptletSources)
                onRuleListsChanged?(false)
            }
        case .failure(let e):
            scriptletStatus = (scriptletLibrary.map { "uBO \($0.ubo)（\($0.count) 個）・署名 OK" } ?? "使えません") + "／新しいもの: \(e)"
            log("⚠️ 落としたスクリプトレットの道具を使いません: \(e)", level: .warning)
        }
    }

    nonisolated static func fetchData(_ urlString: String) async -> Data? {
        guard let u = URL(string: urlString) else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                c.resume(returning: (error == nil && status == 200) ? data : nil)
            }.resume()
        }
    }

    /// 自己テストなどで、今の道具を使う
    var currentScriptletLibrary: ScriptletLibrary? { scriptletLibrary }

    /// そのタブに入れるスクリプトレット。top: トップのページ・frames: サブフレーム（URL が分かったもの）
    func scriptlets(top: URL?, frames: [URL]) -> ScriptletInjection? {
        guard let lib = scriptletLibrary, scriptletIndex.size > 0, let top, isActive(for: top.host) else { return nil }
        let all = [top] + frames
        let cacheKey = all.map { $0.absoluteString }.joined(separator: "\n")
        if let c = scriptletCache[cacheKey] { return c }
        var picked: [(host: String, selection: ScriptletIndex.Selection)] = []
        for (i, u) in all.enumerated() {
            guard let h = u.host?.lowercased(), !h.isEmpty else { continue }
            picked.append((h, scriptletIndex.retrieve(url: u, ancestors: i == 0 ? [] : [top])))
        }
        let out = ScriptletAssembler.assemble(picked, library: lib)
        let r: ScriptletInjection? = out.isEmpty ? nil
            : ScriptletInjection(key: ContentBlockerCompiler.hash(out.main + "\u{0}" + out.isolated), main: out.main, isolated: out.isolated, filters: out.filters)
        if scriptletCache.count > 64 { scriptletCache = [:] }
        scriptletCache[cacheKey] = r
        return r
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
        stateFile.save(AdBlockState(lists: lists, lastAutoUpdate: lastAutoUpdate, scriptletsChecked: scriptletsChecked))
    }
}
