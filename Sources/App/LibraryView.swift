import SwiftUI

// MARK: - ブックマーク・履歴の画面（シート）、アドレス欄の候補、新しいタブの画面

struct LibraryView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(closeLabel: "完了", close: { dismiss() }) {
                Picker("表示", selection: $store.libraryPage) {
                    ForEach(LibraryPage.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            .padding()
            if store.libraryPage == .bookmarks {
                BookmarksPage(store: store, library: library) { dismiss() }
            } else {
                HistoryPage(store: store, library: library) { dismiss() }
            }
        }
    }
}

@MainActor
struct BookmarksPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    let done: () -> Void
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    var body: some View {
        Group {
            if library.bookmarks.items.isEmpty {
                EmptyNote(icon: "book", text: "ブックマークはまだありません。\n「ぁあ」メニューか ⌘D で、見ているページを入れられます")
            } else {
                List {
                    ForEach(library.bookmarks.items) { b in
                        BookmarkRow(store: store, library: library, bookmark: b, done: done) {
                            newTitle = b.title
                            renaming = b
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { library.bookmarks.items[$0].id }
                        for id in ids { library.removeBookmark(id) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .alert("名前を変える", isPresented: renameShown) {
            TextField("名前", text: $newTitle)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("OK") {
                if let b = renaming { library.renameBookmark(b.id, title: newTitle) }
                renaming = nil
            }
        } message: {
            Text(renaming?.url ?? "")
        }
    }

    private var renameShown: Binding<Bool> {
        Binding.present({ renaming }, clear: { renaming = nil })
    }
}

@MainActor
struct BookmarkRow: View {
    let store: BrowserStore
    let library: Library
    let bookmark: Bookmark
    let done: () -> Void
    let rename: () -> Void

    var body: some View {
        Button {
            open(newTab: false)
        } label: {
            SiteRow(icon: "book", title: bookmark.title, url: bookmark.url)
        }
        .contextMenu {
            Button { open(newTab: true) } label: { Label("新しいタブで開く", systemImage: "plus.square.on.square") }
            Button { UIPasteboard.general.string = bookmark.url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
            Button { rename() } label: { Label("名前を変える", systemImage: "pencil") }
            Button { library.moveBookmark(bookmark.id, by: -1) } label: { Label("上へ", systemImage: "arrow.up") }
            Button { library.moveBookmark(bookmark.id, by: 1) } label: { Label("下へ", systemImage: "arrow.down") }
            Button(role: .destructive) { library.removeBookmark(bookmark.id) } label: { Label("削除", systemImage: "trash") }
        }
    }

    private func open(newTab: Bool) {
        guard let u = URL(string: bookmark.url) else { return }
        store.open(url: u, newTab: newTab)
        done()
    }
}

struct HistoryPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("履歴を検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                ClearHistoryMenu(library: library)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            if library.history.entries.isEmpty {
                EmptyNote(icon: "clock", text: "履歴はありません")
            } else {
                HistoryList(store: store, library: library, groups: HistoryLog.groupByDay(library.history.search(query)), done: done)
            }
        }
    }
}

struct HistoryList: View {
    let store: BrowserStore
    let library: Library
    let groups: [(title: String, entries: [HistoryEntry])]
    let done: () -> Void

    var body: some View {
        List {
            ForEach(groups, id: \.title) { g in
                Section {
                    ForEach(g.entries) { e in
                        HistoryRow(store: store, library: library, entry: e, done: done)
                    }
                    .onDelete { idx in
                        let urls = idx.map { g.entries[$0].url }
                        for u in urls { library.removeHistory(u) }
                    }
                } header: {
                    Text(g.title)
                }
            }
        }
        .listStyle(.plain)
    }
}

@MainActor
struct HistoryRow: View {
    let store: BrowserStore
    let library: Library
    let entry: HistoryEntry
    let done: () -> Void

    var body: some View {
        Button {
            open(newTab: false)
        } label: {
            SiteRow(icon: "clock", title: entry.title.isEmpty ? entry.url : entry.title, url: entry.url)
        }
        .contextMenu {
            Button { open(newTab: true) } label: { Label("新しいタブで開く", systemImage: "plus.square.on.square") }
            Button { UIPasteboard.general.string = entry.url } label: { Label("リンクをコピー", systemImage: "doc.on.doc") }
            Button(role: .destructive) { library.removeHistory(entry.url) } label: { Label("履歴から消す", systemImage: "trash") }
        }
    }

    private func open(newTab: Bool) {
        guard let u = URL(string: entry.url) else { return }
        store.open(url: u, newTab: newTab)
        done()
    }
}

struct ClearHistoryMenu: View {
    let library: Library

    var body: some View {
        Menu {
            Button(role: .destructive) { library.clearHistory(since: Date().addingTimeInterval(-3600)) } label: { Text("直近 1 時間") }
            Button(role: .destructive) { library.clearHistory(since: Calendar.current.startOfDay(for: Date())) } label: { Text("今日") }
            Button(role: .destructive) { library.clearHistory(since: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)) } label: { Text("今日と昨日") }
            Button(role: .destructive) { library.clearHistory(since: nil) } label: { Text("すべて") }
        } label: {
            Text("消去…").foregroundColor(.red)
        }
    }
}

/// 一覧の 1 行（タイトルと URL）
struct SiteRow: View {
    let icon: String
    let title: String
    let url: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).foregroundColor(.primary)
                Text(url).font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: アドレス欄の候補（打っている間、ページの上に重ねる）

struct SuggestionOverlay: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var editor: AddressEditor

    var body: some View {
        if editor.editing {
            ZStack(alignment: .top) {
                // 外を押したらアドレス欄から離れる
                Color.black.opacity(0.08)
                    .onTapGesture { editor.blur() }
                if !editor.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    SuggestionList(store: store, editor: editor, items: store.library.suggestions(for: editor.text))
                }
            }
        }
    }
}

@MainActor
struct SuggestionList: View {
    let store: BrowserStore
    let editor: AddressEditor
    let items: [Suggestion]

    var body: some View {
        VStack(spacing: 0) {
            Button { go(nil) } label: {
                SiteRow(icon: "magnifyingglass", title: editor.text, url: firstLine)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ForEach(items) { s in
                Divider()
                Button { go(s) } label: {
                    SiteRow(icon: s.kind == .bookmark ? "book" : "clock", title: s.title.isEmpty ? s.url : s.title, url: s.url)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.systemBackground)))
        .shadow(radius: 8, y: 2)
        .frame(maxWidth: 680)
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private var firstLine: String {
        switch AddressInput.resolve(editor.text, engine: store.searchEngine) {
        case .url(let u)?: return "\(u.absoluteString) を開く"
        default: return "\(store.searchEngine.name) で検索"
        }
    }

    private func go(_ s: Suggestion?) {
        if let s, let u = URL(string: s.url) { store.open(url: u) } else { store.open(editor.text) }
        editor.blur()
    }
}

// MARK: 新しいタブの画面（ブックマークとよく見るサイト）

struct StartPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let favorites = Array(library.bookmarks.items.prefix(12))
                let top = library.history.topSites(limit: 8)
                if favorites.isEmpty && top.isEmpty {
                    EmptyNote(icon: "globe", text: "上のアドレス欄に、URL か調べたいことを入れてください")
                        .padding(.top, 120)
                }
                if !favorites.isEmpty {
                    SiteGrid(store: store, title: "ブックマーク", sites: favorites.map { ($0.title, $0.url) }, columns: columns)
                }
                if !top.isEmpty {
                    SiteGrid(store: store, title: "よく見るサイト", sites: top.map { ($0.title, $0.url) }, columns: columns)
                }
            }
            .frame(maxWidth: 760)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(UIColor.systemBackground))
    }
}

struct SiteGrid: View {
    let store: BrowserStore
    let title: String
    let sites: [(String, String)]
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sites, id: \.1) { site in
                    SiteTile(title: site.0, url: site.1) {
                        if let u = URL(string: site.1) { store.open(url: u) }
                    }
                }
            }
        }
    }
}

struct SiteTile: View {
    let title: String
    let url: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.tertiarySystemFill))
                    Text(initial).font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                Text(title.isEmpty ? host : title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var host: String { AddressInput.shortDisplay(URL(string: url)) }
    private var initial: String { String(host.first ?? "?").uppercased() }
}
