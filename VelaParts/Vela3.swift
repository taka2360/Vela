// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 3 / 6。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import ObjectiveC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - HTTPSTakeover.swift
// ======================================================================

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

// ======================================================================
// MARK: - PageScripts.swift
// ======================================================================

// MARK: - ページに入れる小さなスクリプトと、そこから届く知らせ

enum PageScripts {
    /// JavaScript が使う https:// のアドレスを vnets:// に直す（予備の vnets:// の作りのときだけ使う）
    static let rewriteURLs = #"""
    (function () {
      const map = (u) => {
        try {
          if (u == null) return u;
          const s = String(u);
          if (/^https:\/\//i.test(s)) return 'vnets://' + s.slice(8);
          if (/^http:\/\//i.test(s)) return 'vnet://' + s.slice(7);
          if (s.startsWith('//')) return location.protocol + s;
          return s;
        } catch (e) { return u; }
      };
      const of = window.fetch;
      if (of) window.fetch = function (input, init) {
        if (typeof input === 'string' || input instanceof URL) input = map(input);
        else if (input && input.url && /^(https?:)?\/\//i.test(input.url)) input = new Request(map(input.url), input);
        return of.call(this, input, init);
      };
      const oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u, ...rest) { return oo.call(this, m, map(u), ...rest); };
      const props = [[window.HTMLImageElement, 'src'], [window.HTMLScriptElement, 'src'], [window.HTMLLinkElement, 'href'],
                     [window.HTMLIFrameElement, 'src'], [window.HTMLSourceElement, 'src'], [window.HTMLMediaElement, 'src']];
      for (const [C, p] of props) {
        if (!C) continue;
        const d = Object.getOwnPropertyDescriptor(C.prototype, p);
        if (d && d.set) Object.defineProperty(C.prototype, p, { get: d.get, set(v) { d.set.call(this, map(v)); }, configurable: true, enumerable: d.enumerable });
      }
      const sa = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (n, v) {
        const ln = String(n).toLowerCase();
        if (ln === 'src' || ln === 'href' || ln === 'action' || ln === 'poster') v = map(v);
        else if (ln === 'srcset' && v) v = String(v).replace(/https:\/\//gi, 'vnets://').replace(/http:\/\//gi, 'vnet://');
        return sa.call(this, n, v);
      };
      const wo = window.open;
      window.open = function (u, ...rest) { return wo.call(this, map(u), ...rest); };
    })();
    """#

    /// 知らせの名前（window.webkit.messageHandlers.<この名前>）
    static let cookieHandlerName = "vnetCookie"
    /// エラーページのボタン・守りのスクリプトからの知らせ
    static let actionHandlerName = "velaAction"

    /// JavaScript が Cookie を変えたこと（document.cookie・cookieStore）を、アプリに「合図」だけ知らせる。
    /// Cookie の中身は送らない・信じない（HttpOnly や Domain を偽れるため）。アプリは合図を受けて、WebKit の置き場（正本）を読み直す
    static let watchCookies = #"""
    (function () {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vnetCookie;
        if (!h) return;
        let queued = false;
        const tell = () => {
          if (queued) return;
          queued = true;
          setTimeout(() => { queued = false; try { h.postMessage({}); } catch (e) {} }, 50);
        };
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (d && d.set) {
          Object.defineProperty(Document.prototype, 'cookie', {
            get: d.get,
            set(v) { d.set.call(this, v); tell(); },
            configurable: true, enumerable: d.enumerable
          });
        }
        const cs = window.cookieStore;
        if (cs && cs.set) {
          const os = cs.set.bind(cs), od = cs.delete ? cs.delete.bind(cs) : null;
          cs.set = function (a, b) { const r = os(a, b); Promise.resolve(r).then(tell, tell); return r; };
          if (od) cs.delete = function (a) { const r = od(a); Promise.resolve(r).then(tell, tell); return r; };
        }
      } catch (e) {}
    })();
    """#

    /// LAN の保護（WebSocket）: WebSocket は VNet を通らないので、ページの中で止める。
    /// 公開のサイトのページから、数字の LAN のアドレス・localhost・.local への WebSocket を拒否する。
    /// 限界: ホスト名で LAN に解決されるものは分からない。スクリプトの守りは、ページに回避される可能性がある
    static let webSocketGuard = #"""
    (function () {
      try {
        const W = window.WebSocket;
        if (!W) return;
        const isLocal = (h) => {
          h = String(h || '').toLowerCase().replace(/^\[|\]$/g, '');
          return /^(10|127)\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) ||
                 /^172\.(1[6-9]|2[0-9]|3[01])\./.test(h) || /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./.test(h) ||
                 h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') ||
                 h === '::1' || /^f[cd][0-9a-f]{2}:/.test(h) || /^fe[89ab][0-9a-f]:/.test(h);
        };
        let pageLocal = false;
        try { pageLocal = isLocal(window.top.location.hostname); } catch (e) { pageLocal = isLocal(location.hostname); }
        if (pageLocal) return;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.velaAction;
        const Guarded = function WebSocket(url, protocols) {
          let host = '';
          try { host = new URL(url, location.href).hostname; } catch (e) {}
          if (isLocal(host)) {
            try { h && h.postMessage({ action: 'blockedWebSocket', url: String(url) }); } catch (e) {}
            throw new DOMException('Vela: 公開のサイトから LAN への WebSocket は止めました', 'SecurityError');
          }
          return protocols === undefined ? new W(url) : new W(url, protocols);
        };
        Guarded.prototype = W.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Guarded[k] = W[k];
        window.WebSocket = Guarded;
      } catch (e) {}
    })();
    """#

    /// VNet を通らない通信（WebSocket）を使ったら、アプリに 1 回だけ知らせる（アドレス欄の札に出す）
    static let trackNonVNet = #"""
    (function () {
      try {
        const W = window.WebSocket;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.velaAction;
        if (!W || !h) return;
        let told = false;
        const Tracked = function WebSocket(url, protocols) {
          if (!told) { told = true; try { h.postMessage({ action: 'usedWebSocket' }); } catch (e) {} }
          return protocols === undefined ? new W(url) : new W(url, protocols);
        };
        Tracked.prototype = W.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Tracked[k] = W[k];
        window.WebSocket = Tracked;
      } catch (e) {}
    })();
    """#

    /// LAN の保護（標準の通信のタブと WebSocket 用）: WebKit のルールで、LAN でないページから数字の LAN のアドレスなどへの読み込みを止める。
    /// トップのページが LAN のもの（ユーザーがアドレス欄で開いた機器のページなど）なら止めない。
    /// WebKit の正規表現は「|」が使えないので、アドレスの範囲ごとに 1 行にする
    static let localNetworkPatterns: [String] = [
        #"^[a-z]+://10\."#, #"^[a-z]+://127\."#, #"^[a-z]+://192\.168\."#, #"^[a-z]+://169\.254\."#,
        #"^[a-z]+://172\.1[6-9]\."#, #"^[a-z]+://172\.2[0-9]\."#, #"^[a-z]+://172\.3[01]\."#,
        #"^[a-z]+://localhost[:/]"#, #"^[a-z]+://[a-z0-9.-]*\.local[:/]"#,
        #"^[a-z]+://\[::1\]"#, #"^[a-z]+://\[f[cd]"#, #"^[a-z]+://\[fe[89ab]"#,
    ]

    static var localNetworkRules: String {
        let quoted = localNetworkPatterns.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\") + "\"" }
        let unless = "[" + quoted.joined(separator: ",") + "]"
        let rules = quoted.map { #"{"trigger":{"url-filter":\#($0),"unless-top-url":\#(unless)},"action":{"type":"block"}}"# }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

/// ページのスクリプト（PageScripts.watchCookies）からの「Cookie が変わったかも」という合図を受ける。
/// 中身は受け取らない。合図を受けたら onSignal（WebKit の置き場を読み直す）
final class CookieBridge: NSObject, WKScriptMessageHandler {
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 合図を受けたとき（画面のスレッドで呼ばれる）
    var onSignal: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let o = message.frameInfo.securityOrigin
        log?("🍪 ページの JavaScript が Cookie を変えました（\(o.protocol)://\(o.host)\(o.port == 0 ? "" : ":\(o.port)")）")
        onSignal?()
    }
}

/// エラーページのボタン・守りのスクリプトからの知らせを受ける
final class PageActionBridge: NSObject, WKScriptMessageHandler {
    /// (中身, メインフレームか, 送ってきたページのオリジン)。画面のスレッドで呼ばれる
    var onAction: (([String: Any], Bool, String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        let o = message.frameInfo.securityOrigin
        onAction?(d, message.frameInfo.isMainFrame, "\(o.protocol)://\(o.host)")
    }
}

/// WebKit の Cookie の置き場（正本）と CookieJar（写し）をそろえる
@MainActor
final class WebCookieSync: NSObject, WKHTTPCookieStoreObserver {
    let store: WKHTTPCookieStore
    let jar: CookieJar
    var log: (@Sendable (String) -> Void)?
    private var refreshScheduled = false
    /// WebKit の置き場に入れている途中の数（その間は写しを作り直さない。入れる前の中身で上書きしないため）
    private var pushing = 0
    private var refreshAfterPush = false

    init(store: WKHTTPCookieStore, jar: CookieJar) {
        self.store = store
        self.jar = jar
        super.init()
        store.add(self)
        refresh()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.scheduleRefresh() }
    }

    /// 少し待ってから読み直す（続けて変わったときに、何度も読まないように）
    func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let me = self
            Task { @MainActor in
                me?.refreshScheduled = false
                me?.refresh()
            }
        }
    }

    func refresh() {
        if pushing > 0 { refreshAfterPush = true; return }
        let s = store, j = jar
        Task { @MainActor in
            let all = await s.allCookies()
            j.replaceAll(all.compactMap { CookieRecord(httpCookie: $0) })
        }
    }

    /// VNet が受け取った Cookie の変更を、WebKit の置き場にも入れる
    func apply(_ changes: [CookieChange]) async {
        pushing += 1
        for ch in changes {
            guard let c = ch.record.httpCookie() else { log?("🍪 WebKit に渡せない Cookie: \(ch.record.name)"); continue }
            if ch.delete { await store.deleteCookie(c) } else { await store.setCookie(c) }
        }
        pushing -= 1
        if pushing == 0 && refreshAfterPush { refreshAfterPush = false; refresh() }
    }
}

// ======================================================================
// MARK: - NetPolicy.swift
// ======================================================================

// MARK: - 通信の決まり（セキュリティの判定）
//
// 画面や WebKit に頼らない「判定だけ」の部品。Linux のテスト（tools/tests）でも動かす。
//  SiteUtil           … ホスト名の正規化・「サイト」「オリジン」の判定
//  RequestContext     … 要求の文脈（トップのページ・トップレベルの移動か・リダイレクトの経路 など）
//  CookiePolicy       … Cookie を送るか・保存するか（SameSite・サードパーティ・送る順番）
//  SetCookieParser    … Set-Cookie の 1 行を CookieRecord にする（属性の検査も）
//  RedirectPolicy     … 3xx から次の要求を作る（ここ以外では作らない）
//  CORSPassthrough    … サーバーの CORS ヘッダをそのまま通す（Vela が許可を作らない）
//  LocalNetworkPolicy … Vela 独自のローカルネットワーク（LAN）への接続の制御（Chrome の PNA / LNA とは別物）

// MARK: - サイト・オリジン

enum SiteUtil {
    /// ホスト名をそろえる（小文字・末尾の「.」を外す・IPv6 の [ ] を外す）。
    /// IDN（日本語ドメインなど）は、WebKit から届く URL の時点で punycode（xn--…）になっているので、ここでは変換しない
    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func host(of url: URL) -> String? {
        guard let h = url.host, !h.isEmpty else { return nil }
        return normalizeHost(h)
    }

    /// IPv4 か IPv6 の数字のアドレスか
    static func isIPLiteral(_ host: String) -> Bool {
        let h = normalizeHost(host)
        return IPAddressText.v4(h) != nil || h.contains(":")
    }

    /// 2 段以上の「公開の末尾」（Public Suffix List の、よく使う所だけ）。ここに無いものは最後の 1 段を末尾とみなす
    static let multiLevelSuffixes: Set<String> = [
        // 日本
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "lg.jp", "gr.jp", "ad.jp",
        "tokyo.jp", "osaka.jp", "kyoto.jp", "aichi.jp", "kanagawa.jp", "hokkaido.jp", "fukuoka.jp", "saitama.jp", "chiba.jp", "hyogo.jp",
        // ほかの国
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.sg", "edu.sg", "gov.sg", "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "co.id", "or.id", "ac.id", "go.id", "co.th", "or.th", "ac.th", "go.th", "in.th",
        "com.my", "com.mx", "com.ar", "co.za", "com.tr", "com.vn", "com.ph", "com.ua", "co.il",
        // 誰でも下にサイトを作れる所（別のサイトとして扱う）
        "github.io", "githubusercontent.com", "blogspot.com", "herokuapp.com", "netlify.app", "vercel.app",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net",
        "appspot.com", "glitch.me", "gitlab.io", "s3.amazonaws.com", "fly.dev", "onrender.com", "repl.co",
    ]

    /// 公開の末尾そのものか（例: "jp"・"co.jp"・"github.io"）。Cookie の Domain に使えない
    static func isPublicSuffix(_ domain: String) -> Bool {
        let d = normalizeHost(domain)
        if d.isEmpty { return true }
        if !d.contains(".") { return !isIPLiteral(d) && d != "localhost" }
        return multiLevelSuffixes.contains(d)
    }

    /// 「登録できるドメイン」（サイトの単位）。www.example.co.jp → example.co.jp、a.b.example.com → example.com
    static func registrableDomain(_ host: String) -> String {
        let h = normalizeHost(host)
        if isIPLiteral(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count <= 2 {
            // "co.jp" のように末尾そのもの・"example.com"・"localhost"
            return h
        }
        // 長い末尾から順に見る（"s3.amazonaws.com" のような 3 段もある）
        for n in stride(from: min(3, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if multiLevelSuffixes.contains(suffix) { return labels.suffix(n + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// 同じサイトか（スキームは見ない。WebKit の「サードパーティ」の考え方と同じ）
    static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let ha = host(of: a), let hb = host(of: b) else { return false }
        return registrableDomain(ha) == registrableDomain(hb)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https", "wss", "vnets": return 443
        case "http", "ws", "vnet": return 80
        default: return nil
        }
    }

    /// オリジン（"https://example.com" ・ 既定でないポートなら ":8443" も付ける）
    static func origin(of url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), let h = host(of: url) else { return nil }
        let hostText = h.contains(":") ? "[\(h)]" : h
        if let p = url.port, p != defaultPort(s) { return "\(s)://\(hostText):\(p)" }
        return "\(s)://\(hostText)"
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        return oa == ob
    }

    static func isSecureScheme(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        return s == "https" || s == "wss" || s == "vnets"
    }
}

/// 数字のアドレスを読む
enum IPAddressText {
    /// "192.168.0.1" → [192, 168, 0, 1]
    static func v4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// IPv6 を 8 個の 16 ビットにする（"::" の省略・末尾の IPv4 表記・"%zone" に対応）
    static func v6(_ text: String) -> [UInt16]? {
        var s = SiteUtil.normalizeHost(text)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard s.contains(":") else { return nil }
        var tail4: [UInt16] = []
        if let lastColon = s.lastIndex(of: ":"), let v4 = v4(String(s[s.index(after: lastColon)...])) {
            tail4 = [UInt16(v4[0]) << 8 | UInt16(v4[1]), UInt16(v4[2]) << 8 | UInt16(v4[3])]
            s = String(s[...lastColon]) + "0:0"   // IPv4 の分（16 ビット 2 個）を形だけ置いておき、あとで差し替える
        }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ t: String) -> [UInt16]? {
            if t.isEmpty { return [] }
            var g: [UInt16] = []
            for p in t.split(separator: ":", omittingEmptySubsequences: false) {
                guard !p.isEmpty, p.count <= 4, let v = UInt16(p, radix: 16) else { return nil }
                g.append(v)
            }
            return g
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let back = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - back.count
            guard fill >= 1 else { return nil }
            all = head + Array(repeating: 0, count: fill) + back
        } else {
            all = head
        }
        guard all.count == 8 else { return nil }
        if !tail4.isEmpty { all.removeLast(); all.removeLast(); all += tail4 }
        return all
    }
}

// MARK: - 要求の文脈

/// 要求がどんな場面で出たか。Cookie・リダイレクト・LAN の判定に使う
struct RequestContext: Sendable {
    /// トップのページの URL（WebKit の mainDocumentURL）
    var topURL: URL?
    /// トップレベルの移動（ページそのものを開く要求）か
    var isTopLevel = false
    /// 要求を出したページ（Referer）。トップレベルの移動で、どこから来たかを見るのに使う
    var initiator: URL?
    /// リダイレクトの経路で、一度でもクロスサイトになったか（なったら、そのあとはずっとクロスサイト扱い）
    var crossSiteChain = false
    /// Cookie を送受信してよいか（URLRequest.httpShouldHandleCookies。Fetch の credentials: omit と同じものではない）
    var cookiesAllowed = true
    /// ユーザーがアドレス欄・ブックマークなどから開いた移動か（ページのリンクや JavaScript ではない）
    var userInitiated = false
    /// リダイレクトのとき、1 つ前の URL
    var previousURL: URL?
    /// どのタブの要求か（ログ用）
    var tabID = 0

    init(topURL: URL? = nil, isTopLevel: Bool = false, initiator: URL? = nil) {
        self.topURL = topURL
        self.isTopLevel = isTopLevel
        self.initiator = initiator
    }

    /// リダイレクトで次の URL に進んだときの文脈
    func redirected(from: URL, to next: URL) -> RequestContext {
        var c = self
        if !SiteUtil.isSameSite(from, next) { c.crossSiteChain = true }
        c.previousURL = from
        // トップレベルの移動なら、トップのページは移動先になる
        if isTopLevel { c.topURL = next }
        return c
    }
}

// MARK: - Cookie

/// Cookie 1 つ（WebKit の置き場の写し・Set-Cookie から作ったもの）
struct CookieRecord: Sendable, Equatable {
    enum SameSite: String, Sendable { case unspecified, none, lax, strict }

    var name: String
    var value: String
    /// 先頭の「.」は外した形（小文字）
    var domain: String
    /// Domain 属性が無かった（このホストだけに送る）
    var hostOnly: Bool
    var path: String
    var secure = false
    var httpOnly = false
    var sameSite = SameSite.unspecified
    /// nil ならセッションの間だけ
    var expires: Date?
    /// 作られた時刻（送る順番に使う。WebKit の置き場には無いので、写しで覚える）
    var created: Date

    var key: String { "\(name)\u{1}\(domain)\u{1}\(path)" }

    func isExpired(_ now: Date) -> Bool {
        if let e = expires { return e <= now }
        return false
    }

    /// このホストに送ってよいドメインか
    func domainMatches(_ host: String) -> Bool {
        let h = SiteUtil.normalizeHost(host)
        if hostOnly { return h == domain }
        if h == domain { return true }
        return !SiteUtil.isIPLiteral(h) && h.hasSuffix("." + domain)
    }

    /// このパスに送ってよいか（RFC 6265 5.1.4）
    func pathMatches(_ requestPath: String) -> Bool {
        let p = requestPath.isEmpty ? "/" : requestPath
        if p == path { return true }
        guard p.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        return p.dropFirst(path.count).first == "/"
    }
}

/// Set-Cookie の 1 行を読む（RFC 6265 / 6265bis）。だめな Cookie は nil と理由
enum SetCookieParser {
    static let maxNameValueBytes = 4096

    enum Outcome {
        case cookie(CookieRecord)
        case rejected(String)
    }

    static func parse(_ line: String, url: URL, now: Date = Date()) -> Outcome {
        guard let host = SiteUtil.host(of: url) else { return .rejected("ホスト名がありません") }
        var parts = line.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        let pair = parts.removeFirst()
        var name = "", value = ""
        if let eq = pair.firstIndex(of: "=") {
            name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else {
            value = pair.trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty && value.isEmpty { return .rejected("名前も値もありません") }
        if name.utf8.count + value.utf8.count > maxNameValueBytes { return .rejected("大きすぎます") }
        if (name + value).unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) {
            return .rejected("制御文字が入っています")
        }

        var rec = CookieRecord(name: name, value: value, domain: host, hostOnly: true, path: defaultPath(url), created: now)
        var maxAge: Int?
        var expires: Date?
        for raw in parts {
            let a = raw.trimmingCharacters(in: .whitespaces)
            if a.isEmpty { continue }
            let k: String, v: String
            if let eq = a.firstIndex(of: "=") {
                k = String(a[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                v = String(a[a.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                k = a.lowercased(); v = ""
            }
            switch k {
            case "expires": if let d = HTTPDate.parse(v) { expires = d }
            case "max-age":
                if let n = Int(v) { maxAge = n }
            case "domain":
                var d = v.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                d = SiteUtil.normalizeHost(d)
                if d.isEmpty { continue }
                if SiteUtil.isPublicSuffix(d) {
                    if d == host { continue }          // ホストそのものなら、このホストだけの Cookie として受ける
                    return .rejected("公開の末尾（\(d)）には付けられません")
                }
                let probe = CookieRecord(name: "", value: "", domain: d, hostOnly: false, path: "/", created: now)
                guard probe.domainMatches(host) else { return .rejected("Domain=\(d) はこのホスト（\(host)）に合いません") }
                rec.domain = d
                rec.hostOnly = SiteUtil.isIPLiteral(host)   // IP のときは Domain があってもそのアドレスだけ
            case "path":
                if v.hasPrefix("/") { rec.path = v }
            case "secure": rec.secure = true
            case "httponly": rec.httpOnly = true
            case "samesite":
                switch v.lowercased() {
                case "strict": rec.sameSite = .strict
                case "lax": rec.sameSite = .lax
                case "none": rec.sameSite = .none
                default: rec.sameSite = .unspecified
                }
            default: break
            }
        }
        if let m = maxAge { rec.expires = m <= 0 ? Date(timeIntervalSince1970: 0) : now.addingTimeInterval(TimeInterval(m)) }
        else if let e = expires { rec.expires = e }

        let secureURL = SiteUtil.isSecureScheme(url)
        if rec.secure && !secureURL { return .rejected("Secure の Cookie は https からしか作れません") }
        if rec.sameSite == .none && !rec.secure { return .rejected("SameSite=None には Secure が必要です") }
        if name.hasPrefix("__Secure-") && !(rec.secure && secureURL) { return .rejected("__Secure- には Secure が必要です") }
        if name.hasPrefix("__Host-") && !(rec.secure && secureURL && rec.hostOnly && rec.path == "/") {
            return .rejected("__Host- には Secure・Domain なし・Path=/ が必要です")
        }
        return .cookie(rec)
    }

    /// 既定の Path（RFC 6265 5.1.4: 最後の「/」の手前まで）
    static func defaultPath(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard p.hasPrefix("/"), let last = p.lastIndex(of: "/"), last != p.startIndex else { return "/" }
        return String(p[..<last])
    }
}

/// http の日付（Expires）を読む
enum HTTPDate {
    private static let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                  "EEE MMM d HH:mm:ss yyyy", "EEE, dd MMM yy HH:mm:ss zzz", "EEE, dd-MMM-yy HH:mm:ss zzz",
                                  "dd MMM yyyy HH:mm:ss zzz"]
    private static let formatters: [DateFormatter] = formats.map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "GMT")
        d.dateFormat = f
        return d
    }
    private static let lock = NSLock()

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        for f in formatters { if let d = f.date(from: t) { return d } }
        return nil
    }
}

enum CookiePolicy {
    struct Settings: Sendable, Equatable {
        /// サードパーティ Cookie を保存も送信もしない（Safari の ITP や Storage Access API の例外までは再現しない）
        var blockThirdParty = true
        /// SameSite が無い Cookie を Lax として扱う
        var laxByDefault = true
        /// Lax-by-default の例外: 作られてからこの秒数の間は、クロスサイトのトップレベルの POST にも付ける（0 で例外なし）
        var laxPostGrace: TimeInterval = 120
        init() {}
    }

    static let safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "TRACE"]

    /// この要求はクロスサイトか（SameSite の判定用）
    static func isCrossSite(_ url: URL, method: String, ctx: RequestContext) -> Bool {
        if ctx.crossSiteChain { return true }
        if ctx.isTopLevel {
            // どこから来たかで決める。分からないとき: 安全なメソッドならユーザーの操作とみなす、それ以外はクロスサイト扱い
            if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
            if ctx.userInitiated { return false }
            return !safeMethods.contains(method.uppercased())
        }
        if let t = ctx.topURL { return !SiteUtil.isSameSite(t, url) }
        if let i = ctx.initiator { return !SiteUtil.isSameSite(i, url) }
        return false
    }

    /// サードパーティの要求か（ページの中の部品・iframe が、トップと別のサイトのもの）
    static func isThirdParty(_ url: URL, ctx: RequestContext) -> Bool {
        if ctx.isTopLevel { return false }
        if ctx.crossSiteChain { return true }
        guard let t = ctx.topURL else { return false }
        return !SiteUtil.isSameSite(t, url)
    }

    /// 1 つの Cookie を送るか。送らないなら理由
    static func sendDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext,
                             settings: Settings, now: Date = Date()) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if c.isExpired(now) { return "期限切れ" }
        guard let host = SiteUtil.host(of: url), c.domainMatches(host) else { return "ドメインが合わない" }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if !c.pathMatches(path) { return "パスが合わない" }
        if c.secure && !SiteUtil.isSecureScheme(url) { return "Secure なのに https でない" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        guard isCrossSite(url, method: method, ctx: ctx) else { return nil }
        let topLevelSafe = ctx.isTopLevel && safeMethods.contains(method.uppercased())
        switch c.sameSite {
        case .strict:
            return "SameSite=Strict でクロスサイト"
        case .lax:
            return topLevelSafe ? nil : "SameSite=Lax でクロスサイト"
        case .none:
            return nil
        case .unspecified:
            if !settings.laxByDefault { return nil }
            if topLevelSafe { return nil }
            if ctx.isTopLevel && method.uppercased() == "POST" && settings.laxPostGrace > 0
                && now.timeIntervalSince(c.created) <= settings.laxPostGrace { return nil }
            return "SameSite なし（Lax 扱い）でクロスサイト"
        }
    }

    /// 送る Cookie を順番に並べる（パスが長い順 → 作られた順）
    static func cookiesToSend(_ jar: [CookieRecord], url: URL, method: String, ctx: RequestContext,
                              settings: Settings, now: Date = Date()) -> (send: [CookieRecord], skipped: [(String, String)]) {
        var send: [CookieRecord] = []
        var skipped: [(String, String)] = []
        for c in jar {
            if let why = sendDecision(c, url: url, method: method, ctx: ctx, settings: settings, now: now) {
                // ドメイン・パスが合わないものはログに出さない（関係ない Cookie なので）
                if why != "ドメインが合わない" && why != "パスが合わない" && why != "期限切れ" { skipped.append((c.name, why)) }
            } else {
                send.append(c)
            }
        }
        send.sort { a, b in a.path.count != b.path.count ? a.path.count > b.path.count : a.created < b.created }
        return (send, skipped)
    }

    static func header(_ cookies: [CookieRecord]) -> String? {
        if cookies.isEmpty { return nil }
        return cookies.map { $0.name.isEmpty ? $0.value : "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 届いた Cookie を保存してよいか。だめなら理由
    static func storeDecision(_ c: CookieRecord, url: URL, method: String, ctx: RequestContext, settings: Settings) -> String? {
        if !ctx.cookiesAllowed { return "Cookie を扱わない要求" }
        if settings.blockThirdParty && isThirdParty(url, ctx: ctx) { return "サードパーティ Cookie をブロック" }
        // クロスサイトの部品の応答からは、SameSite=Lax / Strict の Cookie を作らせない（6265bis）
        if !ctx.isTopLevel && isCrossSite(url, method: method, ctx: ctx) && (c.sameSite == .lax || c.sameSite == .strict) {
            return "クロスサイトの部品からの SameSite=\(c.sameSite.rawValue)"
        }
        return nil
    }
}

// MARK: - リダイレクト

enum RedirectPolicy {
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    static let maxRedirects = 20
    /// 本体に関するヘッダ（メソッドが GET に変わったら外す）
    static let bodyHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "content-language", "content-location"]
    /// オリジンが変わったら外す
    static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]

    struct Next: Sendable {
        var url: URL
        var method: String
        var headers: [(String, String)]
        var body: Data?
        var crossOrigin: Bool
        var upgradedByHSTS: Bool
        /// 外したヘッダの名前（ログ用）
        var dropped: [String]
    }

    enum Failure: Error, Equatable, Sendable {
        case noLocation, badLocation(String), unsupportedScheme(String), tooMany
    }

    /// 3xx の応答から、次の要求を作る
    /// - hsts: そのホストを https に上げるべきか
    static func next(from url: URL, method: String, headers: [(String, String)], body: Data?, status: Int,
                     location: String?, redirectCount: Int, hsts: (String) -> Bool = { _ in false }) -> Result<Next, Failure> {
        if redirectCount >= maxRedirects { return .failure(.tooMany) }
        guard let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else { return .failure(.noLocation) }
        guard var nextURL = URL(string: loc, relativeTo: url)?.absoluteURL else { return .failure(.badLocation(loc)) }
        let scheme = nextURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        var upgraded = false
        if scheme == "http", let h = SiteUtil.host(of: nextURL), hsts(h), var c = URLComponents(url: nextURL, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            if let u = c.url { nextURL = u; upgraded = true }
        }

        var m = method.uppercased()
        var b = body
        var drop = Set<String>()
        if status == 303 && m != "HEAD" || (status == 301 || status == 302) && m == "POST" {
            m = "GET"
            b = nil
            drop.formUnion(bodyHeaders)
        }
        let crossOrigin = !SiteUtil.isSameOrigin(url, nextURL)
        // Cookie は移動先で CookiePolicy がもう一度決める（前の相手のものを持ち越さない）
        drop.insert("cookie")
        if crossOrigin { drop.formUnion(credentialHeaders) }

        var out: [(String, String)] = []
        var dropped: [String] = []
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "host" { continue }
            if drop.contains(lk) { dropped.append(k); continue }
            switch lk {
            case "origin":
                // クロスオリジンに移ったら、元のオリジンは「null」にする（Fetch の仕様）
                if crossOrigin, let target = SiteUtil.origin(of: nextURL), v != target { out.append((k, "null")) } else { out.append((k, v)) }
            case "referer":
                guard let ref = URL(string: v) else { dropped.append(k); continue }
                if SiteUtil.isSecureScheme(ref) && !SiteUtil.isSecureScheme(nextURL) { dropped.append(k); continue }  // https → http では送らない
                if !SiteUtil.isSameOrigin(ref, nextURL), let o = SiteUtil.origin(of: ref) { out.append((k, o + "/")) }  // 別オリジンにはオリジンだけ
                else { out.append((k, v)) }
            default:
                out.append((k, v))
            }
        }
        return .success(Next(url: nextURL, method: m, headers: out, body: b, crossOrigin: crossOrigin, upgradedByHSTS: upgraded, dropped: dropped))
    }
}

// MARK: - CORS

/// サーバーの Access-Control-* をそのまま通す。Vela が自分で許可を作ることはしない
enum CORSPassthrough {
    /// vnetsMode: 予備の vnets:// 方式（開発者向け）。そのときだけ、許可されたオリジンの https:// を vnets:// に読み替える
    static func headers(_ server: [(String, String)], vnetsMode: Bool) -> [(String, String)] {
        server.compactMap { k, v in
            let lk = k.lowercased()
            guard lk.hasPrefix("access-control-") else { return nil }
            if vnetsMode && lk == "access-control-allow-origin" {
                if v.lowercased().hasPrefix("https://") { return (k, "vnets://" + v.dropFirst(8)) }
                if v.lowercased().hasPrefix("http://") { return (k, "vnet://" + v.dropFirst(7)) }
            }
            return (k, v)
        }
    }
}

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

// ======================================================================
// MARK: - CookieJar.swift
// ======================================================================

// MARK: - Cookie の写し（正本は WebKit の WKHTTPCookieStore）
//
// ・正本は WebKit の置き場だけ。ここはその写しで、VNet が要求を送るとき（vnet-guest のキュー）に、待たずに読めるようにするためのもの
// ・WebKit の置き場が変わったら（WKHTTPCookieStoreObserver）、写しを作り直す（replaceAll）。この同期は WebCookieSync（PageScripts.swift）がやる
// ・VNet の応答の Set-Cookie は、CookiePolicy で許されたものだけを写しに入れて、変更（CookieChange）として返す。
//   呼んだ側が WebKit の置き場にも入れる（入れ終わってから、ページに返事を渡す）
// ・ページの JavaScript から届く「Cookie の文字列」は、一切ここに入れない（HttpOnly や Domain を偽れるため）

/// 写しの変更（WebKit の置き場にも同じことをする）
struct CookieChange: Sendable {
    var record: CookieRecord
    /// true なら消す
    var delete: Bool
}

final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: CookieRecord] = [:]
    private var _settings = CookiePolicy.Settings()
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?

    init() {}

    var settings: CookiePolicy.Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return cookies.count }

    func snapshot() -> [CookieRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(cookies.values)
    }

    /// 送る Cookie ヘッダ（送らないものがあれば理由も返す）
    func header(for url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> (header: String?, skipped: [(String, String)]) {
        lock.lock()
        let all = Array(cookies.values)
        let s = _settings
        lock.unlock()
        let (send, skipped) = CookiePolicy.cookiesToSend(all, url: url, method: method, ctx: ctx, settings: s, now: now)
        return (CookiePolicy.header(send), skipped)
    }

    /// 応答の Set-Cookie を受け取る。許されたものを写しに入れ、変更を返す
    func receive(_ lines: [String], url: URL, method: String, ctx: RequestContext, now: Date = Date()) -> [CookieChange] {
        var changes: [CookieChange] = []
        let s = settings
        for (i, line) in lines.enumerated() {
            // 同じ返事の中の Cookie は、届いた順に作られたことにする（送る順番が毎回変わらないように、1 マイクロ秒ずつずらす）
            switch SetCookieParser.parse(line, url: url, now: now.addingTimeInterval(Double(i) * 1e-6)) {
            case .rejected(let why):
                log?("🍪✕ 受け取らない（\(SiteUtil.host(of: url) ?? "")）: \(why)")
            case .cookie(var rec):
                if let why = CookiePolicy.storeDecision(rec, url: url, method: method, ctx: ctx, settings: s) {
                    log?("🍪✕ 保存しない \(rec.name)（\(rec.domain)）: \(why)")
                    continue
                }
                lock.lock()
                if rec.isExpired(now) {
                    let old = cookies.removeValue(forKey: rec.key)
                    lock.unlock()
                    changes.append(CookieChange(record: old ?? rec, delete: true))
                    continue
                }
                // 置き換えるときは、最初に作られた時刻を引き継ぐ（RFC 6265 5.3 の 11.3）
                if let old = cookies[rec.key] { rec.created = old.created }
                cookies[rec.key] = rec
                lock.unlock()
                changes.append(CookieChange(record: rec, delete: false))
            }
        }
        return changes
    }

    /// WebKit の置き場の中身で写しを作り直す。作られた時刻と、WebKit が覚えていない SameSite は、前の写しから引き継ぐ
    func replaceAll(_ records: [CookieRecord], now: Date = Date()) {
        lock.lock()
        var next: [String: CookieRecord] = [:]
        for var r in records where !r.isExpired(now) {
            if let old = cookies[r.key] {
                r.created = old.created
                if r.sameSite == .unspecified { r.sameSite = old.sameSite }
            }
            next[r.key] = r
        }
        cookies = next
        lock.unlock()
    }

    func removeAll() {
        lock.lock(); cookies = [:]; lock.unlock()
    }
}

// MARK: - HTTPCookie との変換

extension CookieRecord {
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
    private static let sameSiteKey = HTTPCookiePropertyKey("SameSite")

    /// WebKit の置き場の HTTPCookie から作る（作られた時刻は分からないので now）
    init?(httpCookie c: HTTPCookie, now: Date = Date()) {
        var d = c.domain.lowercased()
        let hostOnly = !d.hasPrefix(".")
        while d.hasPrefix(".") { d.removeFirst() }
        if d.isEmpty { return nil }
        var ss = SameSite.unspecified
        #if canImport(Darwin)
        if let p = c.sameSitePolicy {
            if p == .sameSiteStrict { ss = .strict } else if p == .sameSiteLax { ss = .lax } else if p.rawValue.lowercased() == "none" { ss = .none }
        }
        #else
        if let p = c.properties?[CookieRecord.sameSiteKey] as? String {
            switch p.lowercased() { case "strict": ss = .strict; case "lax": ss = .lax; case "none": ss = .none; default: break }
        }
        #endif
        self.init(name: c.name, value: c.value, domain: SiteUtil.normalizeHost(d), hostOnly: hostOnly, path: c.path.isEmpty ? "/" : c.path,
                  secure: c.isSecure, httpOnly: c.isHTTPOnly, sameSite: ss, expires: c.expiresDate, created: now)
    }

    /// WebKit の置き場に入れる HTTPCookie にする
    func httpCookie() -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .path: path]
        if hostOnly {
            // Domain 属性なし（このホストだけ）: 先頭に「.」を付けない
            p[.domain] = domain
        } else {
            p[.domain] = "." + domain
        }
        if secure { p[.secure] = "TRUE" }
        if let e = expires { p[.expires] = e } else { p[.discard] = "TRUE" }
        if httpOnly { p[CookieRecord.httpOnlyKey] = "TRUE" }
        #if canImport(Darwin)
        switch sameSite {
        case .strict: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .lax: p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .none, .unspecified: break
        }
        #else
        switch sameSite {
        case .strict: p[CookieRecord.sameSiteKey] = "strict"
        case .lax: p[CookieRecord.sameSiteKey] = "lax"
        case .none, .unspecified: break
        }
        #endif
        return HTTPCookie(properties: p)
    }
}
