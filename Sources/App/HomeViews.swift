import SwiftUI
import PhotosUI

// MARK: - ホーム（新しいタブの画面）: 背景・ブックマークとよく見るサイトのタイル・カスタマイズの画面
//
// ・タイルを長押しすると、新しいタブで開く・コピー・名前を変える・並べ替え・削除（ブックマーク）、ブックマークに入れる・外す（よく見るサイト）
// ・下の「編集」から、出す項目と背景（用意した色・自分の写真）を変えられる

/// ホームのタイル 1 つ分
struct HomeSite: Identifiable {
    let title: String
    let url: String
    /// ブックマークのタイルなら、そのブックマーク
    let bookmark: Bookmark?
    var id: String { (bookmark?.id.uuidString ?? "top") + url }
}

@MainActor
struct StartPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: Library
    @ObservedObject var home: HomeStore
    @ObservedObject var icons: SiteIconStore
    @State private var customizing = false
    @State private var renaming: Bookmark?
    @State private var newTitle = ""
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]
    static let maxBookmarks = 24

    var body: some View {
        let layout = home.layout
        let onImage = layout.background != .none
        let favorites = layout.showBookmarks ? Array(library.bookmarks.items.prefix(StartPage.maxBookmarks)) : []
        let top = layout.showTopSites ? layout.visibleTopSites(library.history) : []
        ZStack {
            HomeBackgroundView(background: layout.background, photo: home.wallpaper)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if favorites.isEmpty && top.isEmpty {
                        HomeEmptyNote(onImage: onImage)
                            .padding(.top, 120)
                    }
                    if !favorites.isEmpty {
                        SiteGrid(title: "ブックマーク", onImage: onImage, columns: columns,
                                 sites: favorites.map { HomeSite(title: $0.title, url: $0.url, bookmark: $0) }) { site in
                            tile(site, onImage: onImage)
                        }
                    }
                    if !top.isEmpty {
                        SiteGrid(title: "よく見るサイト", onImage: onImage, columns: columns,
                                 sites: top.map { HomeSite(title: $0.title, url: $0.url, bookmark: nil) }) { site in
                            tile(site, onImage: onImage)
                        }
                    }
                    HStack {
                        Spacer()
                        Button { customizing = true } label: {
                            Label("編集", systemImage: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 760)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $customizing) {
            HomeCustomizeView(home: home)
        }
        .alert("名前を変える", isPresented: Binding.present({ renaming }, clear: { renaming = nil })) {
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

    private func tile(_ site: HomeSite, onImage: Bool) -> some View {
        SiteTile(title: site.title, url: site.url, icon: icons.image(for: site.url), onImage: onImage) {
            open(site.url, newTab: false)
        }
        .onAppear { icons.ensure(site.url, viaVNet: store.defaultMode.usesVNet) }
        .contextMenu {
            SiteLinkMenuItems(url: site.url) { open(site.url, newTab: true) }
            if let b = site.bookmark {
                Button {
                    newTitle = b.title
                    renaming = b
                } label: { Label("名前を変える", systemImage: "pencil") }
                Button { library.moveBookmark(b.id, by: -1) } label: { Label("前へ", systemImage: "arrow.left") }
                Button { library.moveBookmark(b.id, by: 1) } label: { Label("後ろへ", systemImage: "arrow.right") }
                Button(role: .destructive) { library.removeBookmark(b.id) } label: { Label("削除", systemImage: "trash") }
            } else {
                if !library.bookmarks.contains(site.url), let u = URL(string: site.url) {
                    Button { library.toggleBookmark(url: u, title: site.title) } label: { Label("ブックマークに入れる", systemImage: "book") }
                }
                Button(role: .destructive) { home.hideTopSite(site.url) } label: { Label("よく見るサイトから外す", systemImage: "eye.slash") }
            }
        }
    }

    private func open(_ url: String, newTab: Bool) {
        guard let u = URL(string: url) else { return }
        store.open(url: u, newTab: newTab)
    }
}

/// 何も無いときの案内（背景が画像なら白い字）
struct HomeEmptyNote: View {
    let onImage: Bool

    var body: some View {
        if onImage {
            VStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 36))
                Text("上のアドレス欄に、URL か調べたいことを入れてください").multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .frame(maxWidth: .infinity)
        } else {
            EmptyNote(icon: "globe", text: "上のアドレス欄に、URL か調べたいことを入れてください")
        }
    }
}

struct SiteGrid<Tile: View>: View {
    let title: String
    let onImage: Bool
    let columns: [GridItem]
    let sites: [HomeSite]
    @ViewBuilder let tile: (HomeSite) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
                .foregroundColor(onImage ? .white : .primary)
                .shadow(color: onImage ? .black.opacity(0.5) : .clear, radius: 3)
            // タイルの高さはそろえてある（SiteTile.titleHeight）ので、アイコンの y は名前の長さで変わらない
            LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
                ForEach(sites) { site in tile(site) }
            }
        }
    }
}

struct SiteTile: View {
    let title: String
    let url: String
    let icon: UIImage?
    let onImage: Bool
    let open: () -> Void

    static let iconSide: CGFloat = 64
    /// 名前は 2 行まで。1 行でも 2 行分の高さを取って、アイコンの位置（y）をそろえる
    static let titleHeight: CGFloat = 30

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                SiteIconView(icon: icon, initial: initial, onImage: onImage)
                Text(title.isEmpty ? host : title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(onImage ? .white : .primary)
                    .shadow(color: onImage ? .black.opacity(0.6) : .clear, radius: 2)
                    .frame(maxWidth: .infinity, minHeight: SiteTile.titleHeight, maxHeight: SiteTile.titleHeight, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var host: String { AddressInput.shortDisplay(URL(string: url)) }
    private var initial: String { String(host.first ?? "?").uppercased() }
}

/// タイルのアイコン（サイトのアイコンが無ければ頭文字）
struct SiteIconView: View {
    let icon: UIImage?
    let initial: String
    let onImage: Bool

    /// これより小さいアイコン（16・32px の favicon）は、引き伸ばさずに真ん中に小さく出す
    static let smallIcon: CGFloat = 60

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            if let icon {
                shape.fill(Color.white)
                if icon.size.width * icon.scale < SiteIconView.smallIcon {
                    Image(uiImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
                } else {
                    Image(uiImage: icon).resizable().aspectRatio(contentMode: .fit)
                }
            } else {
                if onImage { shape.fill(.ultraThinMaterial) } else { shape.fill(Color(UIColor.tertiarySystemFill)) }
                Text(initial).font(.system(size: 26, weight: .semibold))
                    .foregroundColor(onImage ? .white : .secondary)
            }
        }
        .frame(width: SiteTile.iconSide, height: SiteTile.iconSide)
        .clipShape(shape)
        .shadow(color: .black.opacity(onImage ? 0.25 : 0.08), radius: 3, y: 1)
    }
}

// MARK: 背景

enum HomePresets {
    static func title(_ id: String) -> String {
        switch id {
        case "sky": return "空"
        case "sunset": return "夕焼け"
        case "forest": return "森"
        case "ocean": return "海"
        case "lavender": return "ラベンダー"
        case "night": return "夜"
        default: return id
        }
    }

    static func colors(_ id: String) -> [Color] {
        switch id {
        case "sky": return [Color(red: 0.30, green: 0.56, blue: 0.92), Color(red: 0.55, green: 0.78, blue: 0.98)]
        case "sunset": return [Color(red: 0.93, green: 0.42, blue: 0.36), Color(red: 0.62, green: 0.30, blue: 0.62)]
        case "forest": return [Color(red: 0.16, green: 0.45, blue: 0.33), Color(red: 0.42, green: 0.66, blue: 0.40)]
        case "ocean": return [Color(red: 0.05, green: 0.30, blue: 0.48), Color(red: 0.14, green: 0.60, blue: 0.66)]
        case "lavender": return [Color(red: 0.52, green: 0.44, blue: 0.80), Color(red: 0.80, green: 0.56, blue: 0.80)]
        case "night": return [Color(red: 0.07, green: 0.08, blue: 0.20), Color(red: 0.24, green: 0.20, blue: 0.42)]
        default: return [Color.gray, Color.gray]
        }
    }

    static func gradient(_ id: String) -> LinearGradient {
        LinearGradient(colors: colors(id), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct HomeBackgroundView: View {
    let background: HomeBackground
    let photo: UIImage?

    var body: some View {
        Group {
            switch background {
            case .none:
                Color(UIColor.systemBackground)
            case .preset(let id):
                HomePresets.gradient(id)
            case .photo:
                if let photo {
                    GeometryReader { g in
                        Image(uiImage: photo).resizable().scaledToFill()
                            .frame(width: g.size.width, height: g.size.height)
                            .clipped()
                    }
                    // 白い字を読みやすくする
                    .overlay(Color.black.opacity(0.18))
                } else {
                    Color(UIColor.systemBackground)
                }
            }
        }
        .ignoresSafeArea()
        // .clipped() は見た目を切るだけで、触れる範囲は切らない。scaledToFill ではみ出した写真が
        // ツールバーの上に重なって、ボタンを押せなくなる。背景は触れないようにする
        .allowsHitTesting(false)
    }
}

// MARK: カスタマイズの画面

@MainActor
struct HomeCustomizeView: View {
    @ObservedObject var home: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var picked: PhotosPickerItem?
    private let swatchColumns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(closeLabel: "完了", close: { dismiss() }) {
                Text("ホームをカスタマイズ").font(.headline)
            }
            .padding()
            List {
                Section("表示する項目") {
                    Toggle("ブックマーク", isOn: flag(\.showBookmarks))
                    Toggle("よく見るサイト", isOn: flag(\.showTopSites))
                    if !home.layout.hiddenTopSites.isEmpty {
                        Button("外したよく見るサイトを戻す（\(home.layout.hiddenTopSites.count) 件）") { home.restoreTopSites() }
                    }
                }
                Section("背景") {
                    LazyVGrid(columns: swatchColumns, spacing: 12) {
                        swatch(.none, title: "なし") { Color(UIColor.systemBackground) }
                        ForEach(HomeLayout.presetIDs, id: \.self) { id in
                            swatch(.preset(id), title: HomePresets.title(id)) { HomePresets.gradient(id) }
                        }
                        if let photo = home.wallpaper {
                            swatch(.photo, title: "写真") {
                                Image(uiImage: photo).resizable().scaledToFill()
                            }
                        }
                        PhotosPicker(selection: $picked, matching: .images) {
                            SwatchBox(title: home.preparingPhoto ? "読み込み中…" : "写真を選ぶ", selected: false) {
                                ZStack {
                                    Color(UIColor.tertiarySystemFill)
                                    Image(systemName: "photo.on.rectangle").font(.system(size: 22)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(home.preparingPhoto)
                    }
                    .padding(.vertical, 6)
                    if home.wallpaper != nil {
                        Button("写真を削除", role: .destructive) { home.removePhoto() }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            Task { @MainActor in
                if let d = try? await item.loadTransferable(type: Data.self) { home.setPhoto(d) }
                picked = nil
            }
        }
    }

    private func flag(_ k: WritableKeyPath<HomeLayout, Bool>) -> Binding<Bool> {
        Binding(get: { home.layout[keyPath: k] }, set: { v in home.update { $0[keyPath: k] = v } })
    }

    private func swatch<P: View>(_ b: HomeBackground, title: String, @ViewBuilder preview: () -> P) -> some View {
        Button { home.setBackground(b) } label: {
            SwatchBox(title: title, selected: home.layout.background == b, preview: preview)
        }
        .buttonStyle(.plain)
    }
}

/// 背景の見本 1 つ（選んでいるものは青い枠）
struct SwatchBox<P: View>: View {
    let title: String
    let selected: Bool
    let preview: P

    init(title: String, selected: Bool, @ViewBuilder preview: () -> P) {
        self.title = title
        self.selected = selected
        self.preview = preview()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 4) {
            preview
                .frame(width: 80, height: 56)
                .clipShape(shape)
                .allowsHitTesting(false)     // はみ出した写真が、隣の見本を押せなくしないように
                .overlay(shape.stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 3 : 1))
            Text(title).font(.system(size: 12)).lineLimit(1).foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
