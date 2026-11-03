import Foundation

// MARK: - 広告ブロックのリストの一覧（組み込みのもの）と、保存する形
// UI・WebKit に頼らない（テストできるように FilterLists.swift から分けた）

struct FilterListInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var builtIn: Bool
    var lastUpdated: Date?
    var networkRules = 0
    var cosmeticRules = 0
    var unsupported = 0
    var lastError: String?
    /// スクリプトレットの行の数・リストの「! Expires:」（時間）。古い adblock.json には無いので Optional
    var scriptletRules: Int?
    var expiresHours: Int?
    /// コンパイル済みの WebKit のルールの名前
    var netID: String?
    var cosID: String?
}

struct AdBlockState: Codable {
    var lists: [FilterListInfo]
    var lastAutoUpdate: Date?
    /// スクリプトレットの道具を最後に確かめた時
    var scriptletsChecked: Date?
}

/// タブに入れるスクリプトレット（ScriptletAssembler の結果と、入れ替えの判定に使う印）
struct ScriptletInjection: Equatable {
    var key: String
    var main: String
    var isolated: String
    var filters: [String]
}

enum FilterCatalog {
    static let lists: [FilterListInfo] = [
        FilterListInfo(id: "easylist", name: "EasyList（広告）", url: "https://easylist.to/easylist/easylist.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy（トラッカー）", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "adguard-ja", name: "AdGuard Japanese（日本の広告）", url: "https://filters.adtidy.org/extension/ublock/filters/7.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-filters", name: "uBlock filters（YouTube など）", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", enabled: true, builtIn: true),
        FilterListInfo(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes（すぐの直し）", url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt", enabled: true, builtIn: true),
    ]
    /// trusted の道具（trusted-*・rpnt など）を使ってよいリスト。uBO も自分のリスト（ublock-）だけを信頼する
    static let trustedIDs: Set<String> = ["ublock-filters", "ublock-quick-fixes"]

    /// そのリストの行が trusted の道具を使ってよいか（組み込みの一覧にあって、URL も一覧と同じもの。保存ファイルの id だけでは信じない）
    static func isTrusted(_ l: FilterListInfo) -> Bool {
        trustedIDs.contains(l.id) && lists.contains { $0.id == l.id && $0.url == l.url }
    }

    /// 保存してあった一覧と組み込みの一覧を合わせる。組み込みのものは名前と URL を一覧のもので上書きする（保存ファイルで偽れないように）。
    /// 一覧に無いのに「組み込み」になっているものは、自分で足したものとして扱う
    static func merge(saved: [FilterListInfo]) -> [FilterListInfo] {
        var merged = saved.map { l -> FilterListInfo in
            var l = l
            if let c = lists.first(where: { $0.id == l.id }) {
                l.name = c.name; l.url = c.url; l.builtIn = true
            } else {
                l.builtIn = false
            }
            return l
        }
        for c in lists where !merged.contains(where: { $0.id == c.id }) { merged.append(c) }
        return merged
    }
}
