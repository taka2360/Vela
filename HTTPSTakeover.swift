import WebKit
import ObjectiveC

// MARK: - WKWebView の https・http の読み込みを、アプリが引き受けるための仕掛け

/// WKWebView に「https・http も自分で引き受けます」と言えるようにする
///
/// 普通は https を setURLSchemeHandler に渡すと「それは WebKit が自分でやる」と止められる（アプリが落ちる）。
/// WebKit はそれを WKWebView.handlesURLScheme で確かめているので、そこだけ「http・https は扱わない」と答えさせる。
/// こうすると、ページのアドレスは本物の https://… のまま、読み込みは全部 VNetScheme（自作の通信）に来る。
/// YouTube やログインのように「アドレスが https か」を確かめるページも、そのまま動く。
///
/// 受け入れたリスク（README と開発者パネルにも書く）:
/// ・WebKit の中の作り（handlesURLScheme の差し替え・_willPerformRedirection:）に頼っている。実行時に確かめても、
///   WebKit が変われば動かなくなる・落ちる可能性は消せない。App Store に出すアプリには使えない
/// ・守り: 確かめた iOS の版（testedMajorVersions）だけで使う。差し替えた後の確認に失敗したら、元の実装に戻して標準の通信にする。
///   設定の「VNet を使わない」で、差し替え自体をしないようにできる
enum HTTPSTakeover {
    enum Outcome: Equatable {
        /// https・http を VNetScheme が引き受けられる
        case installed
        /// 設定で VNet を使わない
        case disabledBySetting
        /// 確かめていない iOS の版（設定で許せば試す）
        case untestedOS(Int)
        /// 差し替えられなかった・確認に失敗した（元に戻した）
        case failed(String)

        var description: String {
            switch self {
            case .installed: return "https の横取り: 成功"
            case .disabledBySetting: return "https の横取り: 設定で使わない"
            case .untestedOS(let v): return "https の横取り: 確かめていない iOS \(v) なので使わない（設定で試せます）"
            case .failed(let why): return "https の横取り: 失敗（\(why)）。元に戻しました"
            }
        }
    }

    /// 動くことを確かめた iOS の版（大きい番号）
    static let testedMajorVersions = 16...26

    // 1 回目の結果。@MainActor にはしない（NSObject の override init など、隔離の扱いが iPad の Swift で揺れる所から呼ぶため）。
    // 代わりにロックで守る。WKWebView.handlesURLScheme は Objective-C の API なので、どのスレッドから呼んでもコンパイルは通る
    private static let lock = NSLock()
    private static var result: Outcome?

    /// 1 回だけ行う（2 回目からは 1 回目の結果）。画面のスレッドから呼ぶこと
    static func install() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        let r = tryInstall()
        result = r
        return r
    }

    private static func tryInstall() -> Outcome {
        if VelaSettings.vnetDisabled { return .disabledBySetting }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if !testedMajorVersions.contains(major) && !VelaSettings.allowUntestedOS { return .untestedOS(major) }
        let sel = NSSelectorFromString("handlesURLScheme:")
        guard let m = class_getClassMethod(WKWebView.self, sel) else { return .failed("handlesURLScheme: が見つかりません") }
        let original = method_getImplementation(m)
        let others = ["data", "blob", "about", "vnets"]
        let before = others.map { WKWebView.handlesURLScheme($0) }
        swap(m, sel: sel, original: original)
        // 差し替えが効いているか・ほかのスキームの答えが変わっていないかを確かめる。だめなら元に戻す
        let ok = !WKWebView.handlesURLScheme("https") && !WKWebView.handlesURLScheme("http")
            && others.map({ WKWebView.handlesURLScheme($0) }) == before
        if !ok {
            _ = method_setImplementation(m, original)
            return .failed("差し替えた後の確認に失敗")
        }
        return .installed
    }

    private static func swap(_ m: Method, sel: Selector, original: IMP) {
        typealias Orig = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let orig = unsafeBitCast(original, to: Orig.self)
        let block: @convention(block) (AnyObject, NSString) -> Bool = { cls, scheme in
            let s = (scheme as String).lowercased()
            if s == "http" || s == "https" { return false }
            return orig(cls, sel, scheme)
        }
        _ = method_setImplementation(m, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
    }
}

/// 読み込みの途中の「移動（リダイレクト）」を WebKit に伝える
///
/// WKURLSchemeTask の公開の作りには移動を伝える方法が無い。そのままだと、移動先の中身を元のアドレスのまま見せることになり、
/// 相対リンク・オリジン・クッキーがずれて、ページが壊れたりログインできなかったりする。
/// WebKit の中にある _willPerformRedirection:newRequest:completionHandler:（iOS 13 から）を使って、本当の移動として伝える。
/// 無ければ false（そのときは前のやり方: 自分で追いかけて、最後の返事だけ渡す）
enum SchemeTaskRedirect {
    private static let selector = NSSelectorFromString("_willPerformRedirection:newRequest:completionHandler:")

    static func isAvailable(_ task: WKURLSchemeTask) -> Bool {
        class_getInstanceMethod(object_getClass(task), selector) != nil
    }

    /// 移動を伝える。WebKit が受け入れたら done(次の要求)、やめたら done(nil)
    static func perform(_ task: WKURLSchemeTask, response: URLResponse, request: NSURLRequest,
                        done: @escaping (NSURLRequest?) -> Void) -> Bool {
        guard let m = class_getInstanceMethod(object_getClass(task), selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, URLResponse, NSURLRequest, @escaping @convention(block) (NSURLRequest?) -> Void) -> Void
        let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (NSURLRequest?) -> Void = { done($0) }
        f(task as AnyObject, selector, response, request, block)
        return true
    }
}

/// 予備の作りで使う自分用のアドレス: https://… ⇄ vnets://…、http://… ⇄ vnet://…
enum VNetURL {
    /// https://… → vnets://…、http://… → vnet://…（vnets・vnet はそのまま）
    static func toVNet(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "vnets"
        case "http": c.scheme = "vnet"
        case "vnet", "vnets": break
        default: return nil
        }
        return c.url
    }

    /// vnets://… → https://…、vnet://… → http://…（https・http はそのまま）
    static func toReal(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "vnets": c.scheme = "https"
        case "vnet": c.scheme = "http"
        case "https", "http": return u
        default: return nil
        }
        return c.url
    }

    /// 自分用のアドレス（vnet://・vnets://）か
    static func isVNet(_ u: URL) -> Bool { u.scheme?.lowercased().hasPrefix("vnet") ?? false }
}
