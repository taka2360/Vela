// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 4 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import PhotosUI
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
    /// 履歴を全部消したとき（サイトのアイコンも消す）
    var onClearAllHistory: (() -> Void)?
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
        if since == nil { onClearAllHistory?() }
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
// MARK: - HomeStore.swift
// ======================================================================

// MARK: - ホームの設定の置き場（home.json）と、背景の写真（home-wallpaper.jpg）
//
// 中身の決まりは HomeModel.swift の HomeLayout。ここは保存と画面への知らせだけ

@MainActor
final class HomeStore: ObservableObject {
    @Published private(set) var layout = HomeLayout()
    /// 自分で選んだ写真（選んだことがなければ nil。背景を色にしても残しておき、また選べるようにする）
    @Published private(set) var wallpaper: UIImage?
    /// 写真を縮めている間
    @Published private(set) var preparingPhoto = false
    var log: ((String) -> Void)?
    private let file = JSONFile<HomeLayout>(name: "home.json", delay: 0.5)
    private var loaded = false

    /// 写真の長い辺の上限（px）
    static let maxWallpaperSide: CGFloat = 2400

    /// BrowserStore の初期値として作られる（MainActor の外のことがある）ので、ここでは何もしない。読むのは load
    nonisolated init() {}

    nonisolated static var wallpaperURL: URL { AppPaths.support.appendingPathComponent("home-wallpaper.jpg") }

    func load(logs: DevLog) {
        if loaded { return }
        loaded = true
        log = { s in logs.add(s, level: .info, category: .app) }
        file.log = { s in logs.add(s) }
        layout = file.load() ?? HomeLayout()
        if let d = try? Data(contentsOf: HomeStore.wallpaperURL) { wallpaper = UIImage(data: d) }
        if layout.background == .photo && wallpaper == nil { update { $0.background = .none } }
    }

    func update(_ change: (inout HomeLayout) -> Void) {
        var l = layout
        change(&l)
        if l == layout { return }
        layout = l
        file.save(l)
    }

    func setBackground(_ b: HomeBackground) {
        if b == .photo && wallpaper == nil { return }
        update { $0.background = b }
    }

    func hideTopSite(_ url: String) { update { $0.hideTopSite(url) } }
    func restoreTopSites() { update { $0.hiddenTopSites = [] } }

    /// 選んだ写真を背景にする（縮めて JPEG で置く）
    func setPhoto(_ data: Data) {
        preparingPhoto = true
        Task { @MainActor in
            let jpg = await Task.detached(priority: .userInitiated) { HomeStore.prepareWallpaper(data) }.value
            preparingPhoto = false
            guard let jpg, let img = UIImage(data: jpg) else {
                log?("⚠️ 背景の写真を読めませんでした")
                return
            }
            do {
                try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
                try jpg.write(to: HomeStore.wallpaperURL, options: .atomic)
            } catch {
                log?("⚠️ 背景の写真を書けません（\(error)）")
            }
            wallpaper = img
            update { $0.background = .photo }
        }
    }

    /// 写真を消す（背景が写真なら「なし」に戻す）
    func removePhoto() {
        try? FileManager.default.removeItem(at: HomeStore.wallpaperURL)
        wallpaper = nil
        if layout.background == .photo { update { $0.background = .none } }
    }

    nonisolated private static func prepareWallpaper(_ d: Data) -> Data? {
        guard let img = UIImage(data: d) else { return nil }
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard w >= 1, h >= 1 else { return nil }
        let f = min(1, maxWallpaperSide / max(w, h))
        let size = CGSize(width: (w * f).rounded(), height: (h * f).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// ======================================================================
// MARK: - SiteIcons.swift
// ======================================================================

// MARK: - サイトのアイコン（ホームのタイルに出す）
//
// ・ページを読み終えたら、ページの <link rel="icon"> などを集めて、よいものから取りに行く（選び方は HomeModel.swift の SiteIconPick）
// ・まだ開いていないサイト（前からあるブックマークなど）は、ホームに出たときに /apple-touch-icon.png・/favicon.ico を試す
// ・VNet のタブは VNet で、標準の通信のタブは URLSession で取る（どちらも Cookie は送らない）
// ・取れたものは 180px までに縮めて PNG で Application Support/Vela/Icons/<ホスト>.png に置く。記録は icons.json

@MainActor
final class SiteIconStore: ObservableObject {
    /// VNet で 1 つ取りに行く（BrowserStore が入れる。終わったら done(中身 か nil)）
    typealias VNetFetch = @Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void

    /// 新しいアイコンが入るたびに増える（ホームを描き直す合図）
    @Published private(set) var revision = 0
    var log: ((String) -> Void)?
    /// VNet で取る方法（VNet が動いていないなら nil）
    var vnetFetch: VNetFetch?

    static let maxBytes = 1_000_000
    static let maxSide: CGFloat = 180
    static let maxRecords = 1500

    private var records: [String: IconRecord] = [:]
    private var cache: [String: UIImage] = [:]
    /// ファイルが無いと分かっているもの（何度もディスクを見ないように）
    private var missing = Set<String>()
    private var inFlight = Set<String>()
    private let indexFile = JSONFile<[String: IconRecord]>(name: "icons.json", delay: 2)
    private var loaded = false

    /// BrowserStore の初期値として作られる（MainActor の外のことがある）ので、ここでは何もしない。読むのは load
    nonisolated init() {}

    nonisolated static var folder: URL { AppPaths.support.appendingPathComponent("Icons", isDirectory: true) }

    func load(logs: DevLog) {
        if loaded { return }
        loaded = true
        log = { s in logs.add(s, level: .info, category: .app) }
        indexFile.log = { s in logs.add(s) }
        records = indexFile.load() ?? [:]
        try? FileManager.default.createDirectory(at: SiteIconStore.folder, withIntermediateDirectories: true)
    }

    /// そのサイトのアイコン（無ければ nil）
    func image(for url: String) -> UIImage? {
        guard let k = SiteIconPick.key(for: url) else { return nil }
        if let i = cache[k] { return i }
        if missing.contains(k) { return nil }
        if let d = try? Data(contentsOf: fileURL(k)), let i = UIImage(data: d) {
            cache[k] = i
            return i
        }
        missing.insert(k)
        return nil
    }

    /// ページを読み終えた: ページの <link> を見て、要るなら取りに行く
    func pageLoaded(_ webView: WKWebView, page: URL, viaVNet: Bool) {
        guard let k = SiteIconPick.key(for: page.absoluteString), !inFlight.contains(k),
              SiteIconPick.needsFetch(records[k], havePageLinks: true) else { return }
        inFlight.insert(k)
        // 返事は 1 回だけ来る（self を持っていても循環しない）
        webView.evaluateJavaScript(SiteIconPick.collectScript) { result, _ in
            let json = result as? String ?? ""
            Task { @MainActor in
                let links = SiteIconPick.parseLinks(json)
                self.fetch(key: k, candidates: SiteIconPick.candidates(links: links, page: page), fromPage: true, viaVNet: viaVNet)
            }
        }
    }

    /// ホームに出た: まだ一度も試していないサイトなら、/apple-touch-icon.png・/favicon.ico を試す
    func ensure(_ url: String, viaVNet: Bool) {
        guard let k = SiteIconPick.key(for: url), !inFlight.contains(k), let u = URL(string: url),
              SiteIconPick.needsFetch(records[k], havePageLinks: false) else { return }
        inFlight.insert(k)
        fetch(key: k, candidates: SiteIconPick.fallbackCandidates(page: u), fromPage: false, viaVNet: viaVNet)
    }

    /// 全部消す（履歴を全部消したとき）
    func removeAll() {
        records = [:]
        cache = [:]
        missing = []
        indexFile.saveNow(records)
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: SiteIconStore.folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
        revision += 1
        log?("サイトのアイコンを全部消しました")
    }

    // MARK: 取りに行く

    private func fetch(key k: String, candidates: [URL], fromPage: Bool, viaVNet: Bool) {
        let vnet = viaVNet ? vnetFetch : nil
        let fallback = VelaSettings.autoFallbackToNative
        Task { @MainActor in
            var png: Data?
            var source: URL?
            for u in candidates {
                guard let d = await SiteIconStore.download(u, vnet: vnet, fallbackToNative: fallback) else { continue }
                if let p = SiteIconStore.prepare(d) { png = p; source = u; break }
            }
            self.finish(k, png: png, source: source, fromPage: fromPage)
        }
    }

    private func finish(_ k: String, png: Data?, source: URL?, fromPage: Bool) {
        inFlight.remove(k)
        let file = fileURL(k)
        if let png, let img = UIImage(data: png) {
            do {
                try FileManager.default.createDirectory(at: SiteIconStore.folder, withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
                cache[k] = img
                missing.remove(k)
                revision += 1
                log?("アイコンを取りました: \(k)（\(source?.absoluteString ?? "")）")
            } catch {
                log?("⚠️ アイコンを書けません: \(k)（\(error)）")
            }
        }
        // 取り直しに失敗しても、前のものが残っていれば「ある」のまま
        let has = cache[k] != nil || FileManager.default.fileExists(atPath: file.path)
        records[k] = IconRecord(fetched: Date(), ok: has, fromPage: fromPage)
        prune()
        indexFile.save(records)
    }

    /// 記録が増えすぎたら、古いものから忘れる（ファイルも消す）
    private func prune() {
        guard records.count > SiteIconStore.maxRecords else { return }
        let old = records.sorted { $0.value.fetched < $1.value.fetched }.prefix(records.count - SiteIconStore.maxRecords)
        for (k, _) in old {
            records[k] = nil
            cache[k] = nil
            try? FileManager.default.removeItem(at: fileURL(k))
        }
    }

    private func fileURL(_ k: String) -> URL {
        let safe = String(k.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return SiteIconStore.folder.appendingPathComponent(safe + ".png")
    }

    /// 1 つ取る（200 で、大きすぎないものだけ）
    nonisolated private static func download(_ u: URL, vnet: VNetFetch?, fallbackToNative: Bool) async -> Data? {
        if let vnet {
            let d: Data? = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                vnet(u) { d in c.resume(returning: d) }
            }
            if d != nil || !fallbackToNative { return d }
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue(BrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            URLSession.shared.dataTask(with: req) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data, !data.isEmpty, data.count <= maxBytes else {
                    c.resume(returning: nil); return
                }
                c.resume(returning: data)
            }.resume()
        }
    }

    /// 画像として読めるか確かめて、maxSide までに縮めた PNG にする（読めなければ nil。HTML のエラーページなど）
    private static func prepare(_ d: Data) -> Data? {
        guard let img = UIImage(data: d) else { return nil }
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard w >= 8, h >= 8 else { return nil }
        let f = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * f).rounded(), height: (h * f).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// ======================================================================
// MARK: - HomeModel.swift
// ======================================================================

// MARK: - ホーム（新しいタブの画面）の設定と、サイトのアイコンの選び方（UI と WebKit に頼らない部分。Linux でテストする）
//
// ・ホームの設定（背景・出す項目・よく見るサイトから外したもの）は home.json
// ・アイコンはホストごとに 1 つ（「www.」は外して比べる）。ページの <link rel="icon"> などから選び、無ければ /favicon.ico
// ・取れたものは 14 日、取れなかったものは 1 日たったら取り直す

/// ホームの背景
enum HomeBackground: Equatable {
    case none
    /// 用意した色（id は HomeLayout.presetIDs のどれか）
    case preset(String)
    /// 自分で選んだ写真（Application Support/Vela/home-wallpaper.jpg）
    case photo

    init(code: String) {
        if code == "photo" { self = .photo }
        else if code.hasPrefix("preset:"), HomeLayout.presetIDs.contains(String(code.dropFirst(7))) { self = .preset(String(code.dropFirst(7))) }
        else { self = .none }
    }

    var code: String {
        switch self {
        case .none: return "none"
        case .preset(let id): return "preset:" + id
        case .photo: return "photo"
        }
    }
}

struct HomeLayout: Codable, Equatable {
    /// 用意した背景の色の名前（見た目は HomeViews.swift）
    static let presetIDs = ["sky", "sunset", "forest", "ocean", "lavender", "night"]
    static let maxTopSites = 8

    /// HomeBackground.code
    var backgroundCode = "none"
    var showBookmarks = true
    var showTopSites = true
    /// よく見るサイトから外したホスト（SiteIconPick.key の形）
    var hiddenTopSites: [String] = []

    var background: HomeBackground {
        get { HomeBackground(code: backgroundCode) }
        set { backgroundCode = newValue.code }
    }

    init() {}

    // 後から項目を足しても、前の home.json を読めるように（無い項目は初期値）
    private enum CodingKeys: String, CodingKey { case backgroundCode, showBookmarks, showTopSites, hiddenTopSites }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backgroundCode = try c.decodeIfPresent(String.self, forKey: .backgroundCode) ?? "none"
        showBookmarks = try c.decodeIfPresent(Bool.self, forKey: .showBookmarks) ?? true
        showTopSites = try c.decodeIfPresent(Bool.self, forKey: .showTopSites) ?? true
        hiddenTopSites = try c.decodeIfPresent([String].self, forKey: .hiddenTopSites) ?? []
    }

    /// よく見るサイトから外す（同じものは 1 つ。多すぎたら古いものから忘れる）
    mutating func hideTopSite(_ url: String) {
        guard let k = SiteIconPick.key(for: url), !hiddenTopSites.contains(k) else { return }
        hiddenTopSites.append(k)
        if hiddenTopSites.count > 200 { hiddenTopSites.removeFirst(hiddenTopSites.count - 200) }
    }

    /// ホームに出すよく見るサイト（外したものを除いて limit 件）
    func visibleTopSites(_ history: HistoryLog, limit: Int = HomeLayout.maxTopSites) -> [HistoryEntry] {
        let hidden = Set(hiddenTopSites)
        let all = history.topSites(limit: limit + hidden.count)
        return Array(all.filter { e in SiteIconPick.key(for: e.url).map { !hidden.contains($0) } ?? true }.prefix(limit))
    }
}

// MARK: サイトのアイコン

/// ページの <link> 1 つ（ページの JavaScript で集める。href は絶対の URL にしてある）
struct IconLink: Codable, Equatable {
    var rel: String
    var href: String
    var sizes: String = ""
    var type: String = ""
}

/// アイコンを取りに行った記録（ホストごと）
struct IconRecord: Codable, Equatable {
    var fetched: Date
    var ok: Bool
    /// ページの <link> を見て取りに行ったか（false なら /favicon.ico などを当てずっぽうで試しただけ）
    var fromPage: Bool
}

enum SiteIconPick {
    static let refreshOK: TimeInterval = 14 * 86_400
    static let retryFailed: TimeInterval = 86_400
    /// 1 つのサイトで試す URL の数
    static let maxTries = 4

    /// ページから <link> を集める JavaScript（JSON の文字列を返す）
    static let collectScript = """
    (() => { const out = []; \
    for (const l of document.querySelectorAll('link[rel][href]')) { \
    const r = (l.getAttribute('rel') || '').toLowerCase(); \
    if (!/(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/.test(r)) continue; \
    out.push({ rel: r, href: String(l.href || ''), sizes: l.getAttribute('sizes') || '', type: l.getAttribute('type') || '' }); \
    if (out.length >= 30) break; } \
    return JSON.stringify(out); })()
    """

    /// アイコンを覚えるときのホストの名前（小文字・「www.」を外す）。http・https でなければ nil
    static func key(for url: String) -> String? {
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              let h = u.host, !h.isEmpty else { return nil }
        return SiteUtil.stripWWW(SiteUtil.normalizeHost(h))
    }

    static func parseLinks(_ json: String) -> [IconLink] {
        guard let d = json.data(using: .utf8), let v = try? JSONDecoder().decode([IconLink].self, from: d) else { return [] }
        return v
    }

    /// sizes="16x16 32x32" の一番大きい辺（無い・any なら nil）
    static func largestSize(_ sizes: String) -> Int? {
        var best: Int?
        for part in sizes.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }) {
            let wh = part.split(separator: "x")
            guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { continue }
            best = max(best ?? 0, min(w, h))
        }
        return best
    }

    /// 取りに行ってよい URL か（http・https。公開のページから LAN の機器へは取りに行かない）
    static func isAllowed(_ icon: URL, page: URL) -> Bool {
        guard let s = icon.scheme?.lowercased(), s == "http" || s == "https", let h = icon.host, !h.isEmpty else { return false }
        if LocalNetworkPolicy.classify(host: h)?.isLocal == true {
            return LocalNetworkPolicy.classify(host: page.host ?? "")?.isLocal == true
        }
        return true
    }

    /// 試す順の URL（よいものから。最後は /favicon.ico）
    static func candidates(links: [IconLink], page: URL) -> [URL] {
        var scored: [(Int, URL)] = []
        for l in links {
            let type = l.type.lowercased()
            let lower = l.href.lowercased()
            // SVG は UIImage で読めない
            if type.contains("svg") || lower.hasSuffix(".svg") || lower.contains(".svg?") { continue }
            guard let u = URL(string: l.href), isAllowed(u, page: page) else { continue }
            let apple = l.rel.contains("apple-touch-icon")
            let size = largestSize(l.sizes) ?? (apple ? 180 : (lower.contains(".ico") ? 32 : 48))
            // 大きいほどよい（256 まで）。apple-touch-icon は四角く作ってあるので上げる。小さすぎるものは下げる
            var score = min(size, 256)
            if apple { score += 120 }
            if size < 32 { score -= 40 }
            scored.append((score, u))
        }
        var out: [URL] = []
        for (_, u) in scored.sorted(by: { $0.0 > $1.0 }) where !out.contains(u) { out.append(u) }
        for f in fallbackCandidates(page: page) where !out.contains(f) { out.append(f) }
        return Array(out.prefix(maxTries))
    }

    /// ページを見ないで試すもの（/apple-touch-icon.png と /favicon.ico）
    static func fallbackCandidates(page: URL) -> [URL] {
        guard var c = URLComponents(url: page, resolvingAgainstBaseURL: false), c.host != nil,
              let s = c.scheme?.lowercased(), s == "http" || s == "https" else { return [] }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        var out: [URL] = []
        for p in ["/apple-touch-icon.png", "/favicon.ico"] {
            c.path = p
            if let u = c.url { out.append(u) }
        }
        return out
    }

    /// 取りに行くべきか（havePageLinks: ページの <link> を見られる）
    static func needsFetch(_ r: IconRecord?, havePageLinks: Bool, now: Date = Date()) -> Bool {
        guard let r else { return true }
        let age = now.timeIntervalSince(r.fetched)
        // 当てずっぽうで取ったもの・取れなかったものは、ページを見られたらすぐ試し直す（よい大きさのものがあるかもしれない）
        if havePageLinks && !r.fromPage { return true }
        return age > (r.ok ? refreshOK : retryFailed)
    }
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
