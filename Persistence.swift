import Foundation

// MARK: - 設定（UserDefaults に置く）
//
// 通信まわりの設定は、アプリを起動し直したときに効く（WebView や通信の作りを、起動のときに決めるため）

enum VelaSettings {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: 通信（VNet）

    /// VNet を使わず、標準の通信（WebKit 内蔵）だけで読む
    static var vnetDisabled: Bool {
        get { bool("vnet.disabled", false) } set { d.set(newValue, forKey: "vnet.disabled") }
    }
    /// 確かめていない iOS の版でも、https の横取り（非公開 API）を試す
    static var allowUntestedOS: Bool {
        get { bool("vnet.allowUntestedOS", false) } set { d.set(newValue, forKey: "vnet.allowUntestedOS") }
    }
    /// 開発者向け: 横取りできないとき、標準の通信ではなく予備の vnets:// の作りを使う（安全ではない。CSP などを外すため）
    static var legacyVNetsFallback: Bool {
        get { bool("vnet.legacyVNets", false) } set { d.set(newValue, forKey: "vnet.legacyVNets") }
    }

    // MARK: プライバシー・守り

    /// サードパーティ Cookie をブロックする
    static var blockThirdPartyCookies: Bool {
        get { bool("cookies.blockThirdParty", true) } set { d.set(newValue, forKey: "cookies.blockThirdParty") }
    }
    /// SameSite が無い Cookie を Lax として扱う
    static var cookiesLaxByDefault: Bool {
        get { bool("cookies.laxByDefault", true) } set { d.set(newValue, forKey: "cookies.laxByDefault") }
    }
    /// LAN の保護（公開のサイトから LAN の機器へ届かせない）
    static var localNetworkProtection: Bool {
        get { bool("lan.protection", true) } set { d.set(newValue, forKey: "lan.protection") }
    }

    /// 今の設定から作る Cookie の決まり
    static var cookiePolicy: CookiePolicy.Settings {
        var s = CookiePolicy.Settings()
        s.blockThirdParty = blockThirdPartyCookies
        s.laxByDefault = cookiesLaxByDefault
        return s
    }
}
