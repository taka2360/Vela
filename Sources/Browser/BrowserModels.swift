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
    let origin: String
    /// (OK か, prompt の入力)
    let respond: (Bool, String?) -> Void
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
