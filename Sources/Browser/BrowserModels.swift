import Foundation

// MARK: - アプリ全体で使う小さな型（通信の作り・JS のダイアログ・保存するタブ・セッション）

/// 通信の作り（タブごと）
enum NetMode: String, Codable {
    /// https・http をそのまま VNetScheme が引き受ける（アドレスは本物の https://…）
    case vnetDirect = "VNet"
    /// 予備の vnets://… の作り（開発者向けの実験。CSP などを外すので安全ではない）
    case vnetsLegacy = "VNet（vnets://・実験）"
    /// 標準の通信（WebKit 内蔵）
    case native = "標準"

    var usesVNet: Bool { self != .native }
    var short: String {
        switch self { case .vnetDirect: return "VNet"; case .vnetsLegacy: return "vnets"; case .native: return "標準" }
    }
}

/// ページの JavaScript からのダイアログ（alert・confirm・prompt）
struct JSDialog: Identifiable {
    enum Kind { case alert, confirm, prompt(String) }
    let id = UUID()
    let kind: Kind
    let message: String
    /// 出したタブ（タブを閉じたとき、そのタブのものを取り消すのに使う）
    let tabID: Int
    /// 出したページのホスト（見出しの「〇〇 より」）。頼まれたときに決め、後で URL が変わっても変えない
    let host: String
    /// (OK か, prompt の入力)
    let respond: (Bool, String?) -> Void

    /// 見出し（host が空なら「 より」）
    var title: String { host + " より" }

    /// ホストの決め方: フレームのオリジンのホスト。空なら、そのときのタブの URL のホスト。それも無ければ空（小文字にはしない）
    static func originHost(frameHost: String, tabURL: URL?) -> String {
        frameHost.isEmpty ? (tabURL?.host ?? "") : frameHost
    }
}

/// JavaScript のダイアログの順番待ち（決まりは全部ここ。画面のスレッドだけで使う）。
/// ・出すのは 1 つだけ（current）。残りは全部のタブで 1 本の列に、来た順で並ぶ
/// ・答えたとき: ①今のを外す ②その respond を (ok, ok ? 入力 : nil) で呼ぶ ③列の先頭を出す
///   （入力欄は、prompt ならその既定値、それ以外は ""）
/// ・タブを閉じたとき: ①列の中のそのタブのものを、並び順に (false, nil) で答えて外す
///   ②出しているものがそのタブのものなら、「答えたとき」と同じ手順を false で行う（次はほかのタブのものでもよい）
/// ・どのダイアログの respond も、ちょうど 1 回だけ呼ぶ（WebKit の完了を 2 回呼ぶと落ちるため）
final class DialogQueue {
    /// いま出しているダイアログ
    private(set) var current: JSDialog? { willSet { willChange?() } }
    /// prompt の入力欄
    var input = "" { willSet { willChange?() } }
    /// 順番待ち（変わっても willChange は呼ばない。画面に出ないため）
    private var waiting: [JSDialog] = []
    /// current・input が変わる直前に呼ぶ（画面に知らせる）
    var willChange: (() -> Void)?

    var waitingCount: Int { waiting.count }

    func present(_ d: JSDialog) {
        if current == nil { show(d) } else { waiting.append(d) }
    }

    private func show(_ d: JSDialog) {
        if case .prompt(let def) = d.kind { input = def } else { input = "" }
        current = d
    }

    /// 出しているダイアログを閉じる（ok: OK を押したか）。何も出ていなければ何もしない
    func answer(ok: Bool) {
        guard let d = current else { return }
        current = nil
        d.respond(ok, ok ? input : nil)
        if !waiting.isEmpty { show(waiting.removeFirst()) }
    }

    /// そのタブのダイアログを全部取り消す（タブを閉じたとき）
    func cancel(tabID: Int) {
        let mine = waiting.filter { $0.tabID == tabID }
        waiting.removeAll { $0.tabID == tabID }
        for d in mine { d.respond(false, nil) }
        if let d = current, d.tabID == tabID { answer(ok: false) }
    }
}

/// 保存するタブ
struct SavedTab: Codable {
    var id: Int
    var url: String?
    var title: String
    var mode: NetMode
    /// WebKit の戻る/進むの履歴（WKWebView.interactionState）
    var state: Data?
}

/// ブックマーク・履歴の画面のどちらを見せるか
enum LibraryPage: String, CaseIterable, Hashable {
    case bookmarks = "ブックマーク"
    case history = "履歴"
}

struct SessionData: Codable {
    var tabs: [SavedTab]
    var selected: Int?
}
