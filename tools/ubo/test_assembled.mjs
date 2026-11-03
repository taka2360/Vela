// Vela が組み立てたスクリプトレットの JS（Swift のテストが tools/ubo/.out/ に書いたもの）を node で動かして確かめる。
//   node tools/ubo/test_assembled.mjs
// ・main.js / isolated.js が JS として正しいこと（両方とも (function(){…})(); で、読み込んだだけで動くこと）
// ・テスト用のホスト（vela-selftest.invalid）で、JSON.parse・fetch・JSON.stringify・set-constant の道具が本当に効くこと
// ・www.youtube.com の本物の行を入れても、道具を仕掛ける所で例外が出ないこと（出たら数を出す）
// ・Chrome（headless）があれば、自己テストのページ（selftest.html）を開き、XHR・DOM（script の中の書き換え）・iframe まで確かめる
// WKWebView の world の違い（isolated）は、アプリの自己テスト（開発者パネル）で確かめる
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import * as child from 'node:child_process';
const require_child = () => child;
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '.out');
if (!existsSync(path.join(out, 'main.js'))) {
    console.log('tools/ubo/.out/main.js がありません（先に Swift のテスト tools/tests/runtests.ps1 を動かす）。飛ばします');
    process.exit(0);
}
const instrument = js => js.replace(/\} catch \(e\) \{\n\n\}/g, '} catch (e) { globalThis.__errors.push(String(e && e.stack || e)); }');
const main = instrument(readFileSync(path.join(out, 'main.js'), 'utf8'));
const isolated = instrument(readFileSync(path.join(out, 'isolated.js'), 'utf8'));

let failed = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? '  ✓' : '  ✕'} ${name}${ok || !detail ? '' : `: ${detail}`}`);
    if (!ok) failed += 1;
};

/// ページの代わり（最小）。fetch は、URL に関係なく body を返す
function makeContext(hostname, fetchBody) {
    const noop = () => {};
    class FakeNode extends EventTarget {
        appendChild(n) { return n; }
        insertBefore(n) { return n; }
        removeChild(n) { return n; }
        querySelectorAll() { return []; }
        querySelector() { return null; }
        getAttribute() { return null; }
        setAttribute() {}
        hasAttribute() { return false; }
        removeAttribute() {}
    }
    class FakeElement extends FakeNode { get textContent() { return ''; } set textContent(v) {} }
    const documentElement = new FakeElement();
    const document = new FakeElement();
    Object.assign(document, {
        readyState: 'loading',
        documentElement, head: documentElement, body: documentElement,
        currentScript: null,
        createElement: () => new FakeElement(),
        createTreeWalker: () => ({ nextNode: () => null }),
        getElementsByTagName: () => [],
        getElementById: () => null,
        cookie: '',
        location: { hostname, href: `https://${hostname}/`, pathname: '/', search: '', hash: '', origin: `https://${hostname}` },
    });
    class FakeXHR extends EventTarget {
        open() {} send() {} setRequestHeader() {} abort() {} getResponseHeader() { return null; } getAllResponseHeaders() { return ''; }
    }
    const fetch = async (input) => new Response(fetchBody, { headers: { 'content-type': 'application/json' } });
    const ctx = {
        console, setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask,
        URL, URLSearchParams, TextEncoder, TextDecoder, Response, Request, Headers, Blob, AbortController,
        EventTarget, Event, CustomEvent: class extends Event { constructor(t, o) { super(t); this.detail = o?.detail; } },
        Node: FakeNode, Element: FakeElement, HTMLElement: FakeElement, HTMLScriptElement: FakeElement, HTMLIFrameElement: FakeElement,
        Document: FakeElement, ShadowRoot: FakeElement, Text: FakeNode,
        XMLHttpRequest: FakeXHR,
        NodeFilter: { SHOW_ALL: 0xFFFFFFFF, SHOW_ELEMENT: 1, SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 },
        MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
        document, location: document.location,
        navigator: { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15' },
        requestAnimationFrame: f => setTimeout(f, 16), requestIdleCallback: f => setTimeout(f, 1),
        addEventListener: noop, removeEventListener: noop, dispatchEvent: () => true,
        getComputedStyle: () => ({}), atob, btoa,
        fetch,
        __errors: [],
    };
    ctx.window = ctx; ctx.self = ctx; ctx.top = ctx; ctx.parent = ctx;
    return vm.createContext(ctx);
}

function run(ctx, code, label) {
    try { vm.runInContext(code, ctx, { filename: label }); return null; } catch (e) { return e; }
}

// 1. 構文と、読み込むだけで動くこと
for (const [label, code] of [['main.js', main], ['isolated.js', isolated]]) {
    let ok = true, msg = '';
    try { new vm.Script(code, { filename: label }); } catch (e) { ok = false; msg = String(e); }
    check(`${label} が JS として正しい`, ok, msg);
    check(`${label} は即時実行の形`, code.startsWith('(function() {') && code.trimEnd().endsWith('})();'));
}

// 2. テスト用のホストで中身が効くか
{
    const ctx = makeContext('vela-selftest.invalid', '{"adPlacements":[1],"adSlots":[2],"b":2}');
    const e = run(ctx, main, 'main.js');
    check('vela-selftest.invalid: main.js が例外なく動く', e === null, String(e));
    check('vela-selftest.invalid: 道具を仕掛ける所で例外が出ない', ctx.__errors.length === 0, ctx.__errors.join('\n'));

    const parsed = vm.runInContext('JSON.parse(\'{"adPlacements":[1],"playerAds":[2],"keep":1}\')', ctx);
    check('json-prune: JSON.parse から adPlacements・playerAds が消える', parsed.adPlacements === undefined && parsed.playerAds === undefined && parsed.keep === 1, JSON.stringify(parsed));

    vm.runInContext('globalThis.ytInitialPlayerResponse = { adSlots: [1], keep: 1 };', ctx);
    const yipr = vm.runInContext('ytInitialPlayerResponse', ctx);
    check('set-constant: ytInitialPlayerResponse.adSlots が undefined', yipr && yipr.adSlots === undefined && yipr.keep === 1, JSON.stringify(yipr));

    const s = vm.runInContext('JSON.stringify({ context: { client: { clientName: "WEB" } } })', ctx);
    check('trusted-edit-inbound-object: JSON.stringify に渡すものに clientScreen が入る', s.includes('"clientScreen":"CHANNEL"'), s);

    const text = await vm.runInContext('fetch("https://vela-selftest.invalid/player?x=1").then(r => r.text())', ctx);
    check('trusted-replace-fetch-response: "adSlots" が "no_ads" に変わる', text.includes('"no_ads"') && !text.includes('"adSlots"'), text);
    const json = await vm.runInContext('fetch("https://vela-selftest.invalid/player?x=1").then(r => r.json())', ctx);
    check('json-prune-fetch-response: Response.json() から adPlacements が消える', json.adPlacements === undefined && json.b === 2, JSON.stringify(json));
    const other = await vm.runInContext('fetch("https://vela-selftest.invalid/other").then(r => r.json())', ctx);
    check('json-prune-fetch-response: propsToMatch に合わない URL は変えない', other.adPlacements !== undefined, JSON.stringify(other));
}

// 3. 別のホストでは動かない（ホストのガード）
{
    const ctx = makeContext('example.com', '{}');
    run(ctx, main, 'main.js');
    const parsed = vm.runInContext('JSON.parse(\'{"adPlacements":[1]}\')', ctx);
    check('example.com: ほかのホストのルールは効かない', parsed.adPlacements !== undefined);
}

// 4. www.youtube.com の本物の行
{
    const ctx = makeContext('www.youtube.com', '{"playerResponse":{"adPlacements":[1]},"x":1}');
    const e1 = run(ctx, main, 'main.js');
    check('www.youtube.com: main.js が例外なく動く', e1 === null, String(e1));
    const parsed = vm.runInContext('JSON.parse(\'{"playerResponse":{"adPlacements":[1],"videoDetails":{}},"adSlots":[1]}\')', ctx);
    check('www.youtube.com: JSON.parse から playerResponse.adPlacements と adSlots が消える',
        parsed.playerResponse && parsed.playerResponse.adPlacements === undefined && parsed.adSlots === undefined, JSON.stringify(parsed));
    const ictx = makeContext('www.youtube.com', '{}');
    const e2 = run(ictx, isolated, 'isolated.js');
    check('www.youtube.com: isolated.js が例外なく動く', e2 === null, String(e2));
    const errs = [...ctx.__errors, ...ictx.__errors];
    // 偽のページでは DOM が足りないので、仕掛ける所の例外は数だけ出す（失敗にしない）
    console.log(`  （www.youtube.com: 道具を仕掛ける所の例外 ${errs.length} 個${errs.length ? ': ' + errs.map(x => x.split('\n')[0]).slice(0, 3).join(' / ') : ''}）`);
}

// 5. 自己テストのページを headless の Chrome で
const chrome = [process.env.CHROME, 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', '/usr/bin/google-chrome', '/usr/bin/chromium-browser', '/usr/bin/chromium']
    .find(p => p && existsSync(p));
const selftest = path.join(out, 'selftest.html');
if (!chrome || !existsSync(selftest)) {
    console.log(`  （Chrome ${chrome ? 'はある' : 'が無い'}・selftest.html ${existsSync(selftest) ? 'はある' : 'が無い'}: 自己テストのページは飛ばします）`);
} else {
    const html = readFileSync(selftest);
    const server = http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(html); });
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    const port = server.address().port;
    let dom = '';
    try {
        dom = await new Promise((resolve) => {
            const { execFile } = require_child();
            execFile(chrome, ['--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--virtual-time-budget=8000',
                `--host-resolver-rules=MAP vela-selftest.invalid 127.0.0.1`, '--dump-dom', `http://vela-selftest.invalid:${port}/`],
                { timeout: 60000, maxBuffer: 16 << 20 }, (err, stdout) => resolve(String(stdout || '')));
        });
    } finally {
        server.close();
    }
    const m = /<pre id="vela-result">([\s\S]*?)<\/pre>/.exec(dom);
    if (!m) {
        check('自己テストのページ（Chrome）が結果を書く', false, dom.slice(0, 300));
    } else {
        const text = m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
        for (const r of JSON.parse(text)) check(`Chrome: ${r.name}`, r.ok, r.detail);
    }
}

console.log(failed === 0 ? '結果: OK' : `結果: NG（${failed} 個）`);
process.exit(failed === 0 ? 0 : 1);
