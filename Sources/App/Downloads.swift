import SwiftUI
import WebKit

// MARK: - ダウンロード
//
// ・WebKit の WKDownload を使う（VNet のタブでも標準の通信のタブでも同じ。VNet は返事を流す形で渡すので、大きいファイルでもメモリにためない）
// ・保存先は Documents/Downloads（同じ名前があれば「名前 (2).zip」のようにする）
// ・進み具合は 0.5 秒ごとに見る。取り消し・やり直し（途中から: resumeData）・共有（「ファイル」に保存など）・削除ができる
// ・起動したときに、前にダウンロードしたファイルを一覧に戻す

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    @Published var filename: String
    @Published var received: Int64 = 0
    @Published var expected: Int64 = -1
    @Published var state = State.running
    @Published var fileURL: URL?
    let source: URL?
    var download: WKDownload?
    var resumeData: Data?
    /// VNet が自分で書いているダウンロード（VNet のタブ）
    var vnet: VNetDownload?
    /// やり直すとき（VNet のダウンロードは、同じ URL をもう一度 VNet で読む）
    var restart: (() -> Void)?

    /// VNet のダウンロードの様子を写す
    func syncVNet() {
        guard let v = vnet else { return }
        received = v.received
        switch v.state {
        case .running: state = .running
        case .finished: state = .finished; expected = received
        case .cancelled: state = .cancelled
        case .failed(let why): state = .failed(why)
        }
    }

    init(filename: String, source: URL?) {
        self.filename = filename
        self.source = source
    }

    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// やり直し（途中から）に使う WebView を返す
    var webViewForResume: (() -> WKWebView?)?
    private var timer: Timer?

    /// BrowserStore の nonisolated init から作られるので、ここでは何もしない（準備は loadExisting）
    nonisolated override init() {
        super.init()
    }

    var runningCount: Int { items.filter { $0.state == .running }.count }

    nonisolated static var folder: URL { DownloadFiles.folder }

    /// 前にダウンロードしたファイルを一覧に入れる（新しい順）
    func loadExisting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: DownloadManager.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for f in sorted where !f.lastPathComponent.hasPrefix(".") {
            let item = DownloadItem(filename: f.lastPathComponent, source: nil)
            item.fileURL = f
            item.state = .finished
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0
            item.received = size
            item.expected = size
            items.append(item)
        }
    }

    /// WebKit がダウンロードに変えたものを受け取る
    func adopt(_ d: WKDownload, source: URL?) {
        let item = DownloadItem(filename: source?.lastPathComponent ?? "download", source: source)
        item.download = d
        d.delegate = self
        items.insert(item, at: 0)
        log?("⬇︎ ダウンロード開始: \(source?.absoluteString ?? "?")")
        startTimer()
    }

    /// VNet が自分で書き始めたダウンロードを一覧に入れる
    func register(_ dl: VNetDownload, restart: (() -> Void)?) {
        let item = DownloadItem(filename: dl.fileURL.lastPathComponent, source: dl.source)
        item.vnet = dl
        item.fileURL = dl.fileURL
        item.expected = dl.expected
        item.restart = restart
        dl.onChange = { [weak item] in
            let it = item
            Task { @MainActor in it?.syncVNet() }
        }
        items.insert(item, at: 0)
        item.syncVNet()
        log?("⬇︎ ダウンロード開始（VNet）: \(dl.source.absoluteString)")
    }

    private func item(for d: WKDownload) -> DownloadItem? { items.first { $0.download === d } }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let url = DownloadFiles.uniqueURL(for: suggestedFilename)
        if let item = item(for: download) {
            item.filename = url.lastPathComponent
            item.fileURL = url
            item.expected = response.expectedContentLength
        }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        if let f = item.fileURL, let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value {
            item.received = size
            item.expected = size
        }
        item.download = nil
        log?("⬇︎ ダウンロード完了: \(item.filename)（\(item.received / 1024)KB）")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.resumeData = resumeData
        item.download = nil
        if item.state == .cancelled { return }
        item.state = .failed(error.localizedDescription)
        log?("⬇︎✕ ダウンロード失敗: \(item.filename)：\(error.localizedDescription)\(resumeData != nil ? "（途中から再開できます）" : "")")
    }

    // MARK: 操作

    func cancel(_ item: DownloadItem) {
        if let v = item.vnet {
            item.state = .cancelled
            v.cancel()
            log?("⬇︎ ダウンロードを取り消しました: \(item.filename)")
            return
        }
        guard let d = item.download else { return }
        item.state = .cancelled
        d.cancel { [weak item] data in
            item?.resumeData = data
        }
        log?("⬇︎ ダウンロードを取り消しました: \(item.filename)")
    }

    /// やり直す（途中までのデータがあれば、そこから）
    func retry(_ item: DownloadItem) {
        if item.vnet != nil {
            let again = item.restart
            remove(item)
            again?()
            return
        }
        if let data = item.resumeData, let wv = webViewForResume?() {
            item.state = .running
            item.resumeData = nil
            wv.resumeDownload(fromResumeData: data) { [weak self, weak item] d in
                guard let self, let item else { return }
                item.download = d
                d.delegate = self
                self.startTimer()
            }
            log?("⬇︎ 途中から再開します: \(item.filename)")
        } else if let src = item.source, let wv = webViewForResume?() {
            remove(item)
            wv.startDownload(using: URLRequest(url: src)) { [weak self] d in
                self?.adopt(d, source: src)
            }
        }
    }

    /// 一覧から外して、ファイルも消す
    func remove(_ item: DownloadItem) {
        if item.state == .running { cancel(item) }
        if let f = item.fileURL { try? FileManager.default.removeItem(at: f) }
        items.removeAll { $0 === item }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    private func startTimer() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let me = self
            Task { @MainActor in me?.tick() }
        }
    }

    private func tick() {
        var running = false
        for item in items where item.state == .running {
            guard let d = item.download else { continue }
            running = true
            item.received = d.progress.completedUnitCount
            if d.progress.totalUnitCount > 0 { item.expected = d.progress.totalUnitCount }
        }
        if !running { timer?.invalidate(); timer = nil }
    }
}

// MARK: - 画面

/// ツールバーのダウンロードのボタン（ダウンロードがあるときだけ出す）
struct DownloadsButton: View {
    @ObservedObject var manager: DownloadManager
    @Binding var show: Bool

    var body: some View {
        if !manager.items.isEmpty {
            Button { show = true } label: {
                Image(systemName: manager.runningCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: URL?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(closeLabel: "閉じる", closeLeading: 12, close: { dismiss() }) {
                Text("ダウンロード").font(.headline)
            } trailing: {
                Button("終わったものを一覧から外す") { manager.clearFinished() }
            }
            .padding()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(manager.items) { item in
                        DownloadRow(manager: manager, item: item) { sharing = $0 }
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: Binding.present({ sharing }, clear: { sharing = nil })) {
            if let u = sharing { ShareSheet(items: [u]) }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    let share: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc").font(.system(size: 24)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1)
                if item.state == .running {
                    ProgressView(value: item.fraction ?? 0)
                }
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            buttons
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
    }

    @ViewBuilder private var buttons: some View {
        switch item.state {
        case .running:
            Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle") }
        case .finished:
            if let f = item.fileURL {
                Button { share(f) } label: { Image(systemName: "square.and.arrow.up") }
            }
            Button { manager.remove(item) } label: { Image(systemName: "trash") }
        case .failed, .cancelled:
            Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise") }
            Button { manager.remove(item) } label: { Image(systemName: "trash") }
        }
    }

    private var statusText: String {
        let size = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        switch item.state {
        case .running:
            if item.expected > 0 { return "\(size) / \(ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file))" }
            return size
        case .finished: return "完了・\(size)"
        case .failed(let why): return "失敗: \(why)\(item.resumeData != nil ? "（途中から再開できます）" : "")"
        case .cancelled: return "取り消しました"
        }
    }
}

/// 共有シート（「ファイル」に保存・ほかのアプリで開く など）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension Binding where Value == Bool {
    /// 「値があるあいだ出す」シート・アラート用（閉じられたら clear を呼ぶ）。
    /// Binding(get: { x != nil }, set: { if !$0 { x = nil } }) と同じ
    static func present<T>(_ value: @escaping () -> T?, clear: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value() != nil }, set: { if !$0 { clear() } })
    }
}
