import Foundation

// 通信の決まりの部品（NetPolicy.swift の続き）。ローカルネットワーク（LAN）への接続の制御

// MARK: - ローカルネットワーク（LAN）

/// アドレスの種類
enum IPClass: String, Sendable {
    case publicAddress = "公開"
    case privateAddress = "LAN"
    case loopback = "ループバック"
    case linkLocal = "リンクローカル"
    /// VNet の中（10.0.2.x。ルーター・DNS など）
    case vnetInternal = "VNet 内部"
    case unspecified = "未指定"

    /// LAN 側（公開でない）か
    var isLocal: Bool { self != .publicAddress }
}

/// Vela 独自のローカルネットワークへの接続の制御（Chrome の Private Network Access / Local Network Access とは別物）
enum LocalNetworkPolicy {
    static func classify(_ ip: [UInt8]) -> IPClass {
        guard ip.count == 4 else { return .publicAddress }
        switch (ip[0], ip[1]) {
        case (0, _): return .unspecified
        case (10, 0) where ip[2] == 2: return .vnetInternal
        case (10, _): return .privateAddress
        case (127, _): return .loopback
        case (169, 254): return .linkLocal
        case (172, 16...31): return .privateAddress
        case (192, 168): return .privateAddress
        case (100, 64...127): return .privateAddress          // CGNAT（100.64/10）
        default: return ip[0] >= 224 ? .unspecified : .publicAddress   // マルチキャストなど
        }
    }

    static func classify(v6 g: [UInt16]) -> IPClass {
        guard g.count == 8 else { return .publicAddress }
        if g.allSatisfy({ $0 == 0 }) { return .unspecified }
        if g[0..<7].allSatisfy({ $0 == 0 }) && g[7] == 1 { return .loopback }
        if g[0..<5].allSatisfy({ $0 == 0 }) && g[5] == 0xFFFF {        // ::ffff:a.b.c.d
            return classify([UInt8(g[6] >> 8), UInt8(g[6] & 0xFF), UInt8(g[7] >> 8), UInt8(g[7] & 0xFF)])
        }
        if g[0] & 0xFE00 == 0xFC00 { return .privateAddress }           // fc00::/7（ULA）
        if g[0] & 0xFFC0 == 0xFE80 { return .linkLocal }                // fe80::/10
        if g[0] & 0xFF00 == 0xFF00 { return .unspecified }              // マルチキャスト
        return .publicAddress
    }

    /// ホスト名だけで分かるときの種類（数字のアドレス・localhost・.local）。名前を引かないと分からないなら nil
    static func classify(host: String) -> IPClass? {
        let h = SiteUtil.normalizeHost(host)
        if let v4 = IPAddressText.v4(h) { return classify(v4) }
        if let v6 = IPAddressText.v6(h) { return classify(v6: v6) }
        if h == "localhost" || h.hasSuffix(".localhost") { return .loopback }
        if h.hasSuffix(".local") || h.hasSuffix(".home.arpa") { return .privateAddress }
        return nil
    }

    enum Decision: Equatable, Sendable {
        case allow
        case block(String)
        /// トップレベルの移動: ユーザーに確かめてから
        case askUser(String)
    }

    /// target: 接続先のアドレスの種類。topClass: トップのページの種類。fromClass: 1 つ前（リダイレクト元・移動を起こしたページ）の種類
    static func decide(target: IPClass, ctx: RequestContext, topClass: IPClass?, fromClass: IPClass?) -> Decision {
        guard target.isLocal else { return .allow }
        if target == .vnetInternal || target == .unspecified { return .block("\(target.rawValue)のアドレスには接続しません") }
        if ctx.isTopLevel {
            if ctx.userInitiated && ctx.previousURL == nil { return .allow }     // アドレス欄から直接
            if let f = fromClass, f.isLocal { return .allow }                     // LAN のページから LAN へ
            if ctx.previousURL != nil && fromClass == .publicAddress {
                return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト")
            }
            return .askUser("ページが LAN（\(target.rawValue)）へ移動しようとしています")
        }
        if let t = topClass, t.isLocal { return .allow }                          // LAN のページの部品
        if ctx.previousURL != nil { return .block("公開のサイトから LAN（\(target.rawValue)）へのリダイレクト") }
        return .block("公開のサイトから LAN（\(target.rawValue)）の部品を読み込もうとしました")
    }
}
