import SwiftUI

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
