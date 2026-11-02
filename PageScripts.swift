import WebKit

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
