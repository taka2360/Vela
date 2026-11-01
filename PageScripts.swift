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

    /// JavaScript が作ったクッキー（document.cookie・cookieStore）をアプリにも知らせる。
    /// アプリは自分の置き場（HTTPCookieStorage）に入れて、自作の通信で送る
    static let watchCookies = #"""
    (function () {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vnetCookie;
        if (!h) return;
        const tell = (c) => { try { h.postMessage({ c: String(c), u: location.href }); } catch (e) {} };
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (d && d.set) {
          Object.defineProperty(Document.prototype, 'cookie', {
            get: d.get,
            set(v) { d.set.call(this, v); tell(v); },
            configurable: true, enumerable: d.enumerable
          });
        }
        const cs = window.cookieStore;
        if (cs && cs.set) {
          const os = cs.set.bind(cs), od = cs.delete ? cs.delete.bind(cs) : null;
          cs.set = function (a, b) {
            const o = typeof a === 'string' ? { name: a, value: b } : (a || {});
            let s = o.name + '=' + (o.value == null ? '' : o.value) + '; path=' + (o.path || '/');
            if (o.domain) s += '; domain=' + o.domain;
            if (o.expires) s += '; expires=' + new Date(o.expires).toUTCString();
            tell(s);
            return os(a, b);
          };
          if (od) cs.delete = function (a) {
            const o = typeof a === 'string' ? { name: a } : (a || {});
            let s = o.name + '=; path=' + (o.path || '/') + '; expires=Thu, 01 Jan 1970 00:00:00 GMT';
            if (o.domain) s += '; domain=' + o.domain;
            tell(s);
            return od(a);
          };
        }
      } catch (e) {}
    })();
    """#
}

/// ページのスクリプト（PageScripts.watchCookies）から届いたクッキーを、自分の置き場に入れる
final class CookieBridge: NSObject, WKScriptMessageHandler {
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let c = d["c"] as? String,
              let us = d["u"] as? String, let u = URL(string: us), let real = VNetURL.toReal(u) else { return }
        CookieSync.store(c, url: real)
        let name = c.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "?"
        log?("🍪 ページ → \(name)（\(real.host ?? "")）")
    }
}
