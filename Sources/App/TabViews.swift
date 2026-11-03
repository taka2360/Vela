import SwiftUI

// MARK: - タブバー（ツールバーの下）と、タブ一覧（全画面）

struct TabStrip: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.tabs) { tab in
                    TabChip(store: store, tab: tab, selected: tab.id == store.selectedID)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct TabChip: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
            Text(tabTitle(tab)).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(UIColor.systemBackground) : Color(UIColor.tertiarySystemFill)))
        .onTapGesture { store.select(tab) }
        .contextMenu {
            Button { store.closeOthers(tab) } label: { Label("ほかのタブを閉じる", systemImage: "xmark.square") }
            if let u = tab.url {
                Button { store.newTab(url: u, select: true, mode: tab.mode, after: tab) } label: { Label("タブを複製", systemImage: "plus.square.on.square") }
            }
        }
    }
}

/// タブの見出し（タイトルが無ければホスト名）
@MainActor
func tabTitle(_ tab: BrowserTab) -> String {
    if !tab.title.isEmpty { return tab.title }
    let h = AddressInput.shortDisplay(tab.url)
    return h.isEmpty ? "新しいタブ" : h
}

struct TabOverview: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(closeLabel: "完了", closeLeading: 16, close: { dismiss() }) {
                Text("タブ \(store.tabs.count) 枚").font(.headline)
            } trailing: {
                Button {
                    store.newTab(url: nil)
                    dismiss()
                } label: { Image(systemName: "plus").font(.system(size: 20)) }
            }
            .padding()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.tabs) { tab in
                        TabCard(store: store, tab: tab, selected: tab.id == store.selectedID) {
                            store.select(tab)
                            dismiss()
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

struct TabCard: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            Text(tabTitle(tab)).font(.system(size: 13)).lineLimit(1)
            Text("\(tab.mode.short)・\(tab.state.rawValue)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onTapGesture { open() }
    }

    @ViewBuilder private var preview: some View {
        if let img = tab.snapshot {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(UIColor.secondarySystemBackground)
                Image(systemName: "globe").font(.system(size: 30)).foregroundStyle(.secondary)
            }
        }
    }
}
