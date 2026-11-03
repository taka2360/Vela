import SwiftUI

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
