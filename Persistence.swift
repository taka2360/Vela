import Foundation

// MARK: - データのファイル（Application Support/Vela/ の JSON）
//
// タブ・ブックマーク・履歴などを Codable の JSON で置く。書き込みはまとめて（delay 秒後に 1 回）、裏のキューで、
// いったん別の名前に書いてから置き換える（.atomic。書いている途中で落ちても前のものが残る）

final class JSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    /// 読み書きの失敗（開発者向けのログに出す）
    var log: (@Sendable (String) -> Void)?

    /// name: ファイルの名前（例: "tabs.json"）。directory を省くと Application Support/Vela/
    init(name: String, directory: URL? = nil, delay: TimeInterval = 1.0) {
        let dir = directory ?? JSONFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.delay = delay
        queue = DispatchQueue(label: "vela-json-\(name)")
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
    }

    /// 読む（無い・壊れているなら nil。壊れていたファイルは .broken に名前を変えて残す）
    func load() -> Value? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: d)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を読めません（\(error)）。.broken として残します")
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return nil
        }
    }

    /// 保存する（delay 秒の間に何度呼んでも、書くのは最後の 1 回）
    func save(_ v: Value) {
        lock.lock()
        pending = v
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// 待っている分をすぐ書く（アプリが裏に回るときなど）。書き終わるまで待つ
    func saveNow(_ v: Value? = nil) {
        if let v { lock.lock(); pending = v; lock.unlock() }
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let v = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let v else { return }
        do {
            let d = try JSONEncoder().encode(v)
            try d.write(to: url, options: .atomic)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を書けません（\(error)）")
        }
    }
}

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

    // MARK: 使い勝手

    /// 検索エンジン
    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "search.engine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "search.engine") }
    }
    /// HTTPS-First: ページを開く http:// を、まず https で試す（だめなら「http のまま開く」を出す）
    static var httpsFirst: Bool {
        get { bool("nav.httpsFirst", true) } set { d.set(newValue, forKey: "nav.httpsFirst") }
    }
    /// VNet でページを読めなかったら（TLS・つながらない など）、標準の通信に自動で切り替える
    static var autoFallbackToNative: Bool {
        get { bool("vnet.autoFallback", false) } set { d.set(newValue, forKey: "vnet.autoFallback") }
    }
    /// Mac の Safari の Web インスペクタからつなげるようにする（iOS 16.4 から）
    static var webInspector: Bool {
        get { bool("dev.webInspector", false) } set { d.set(newValue, forKey: "dev.webInspector") }
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
