// uBlock Origin（uBO）のスクリプトレット（##+js の道具）を、uBO のソースからそのまま取り出して JSON にする。
//
//   node tools/ubo/build_scriptlets.mjs [タグ]        （タグが無ければ GitHub の最新の安定版）
//
// 署名の秘密鍵（PKCS#8 PEM）は環境変数 UBO_SIGNING_KEY か UBO_SIGNING_KEY_FILE。
// 署名するのは、この実行の中で uBO のソースから作った中身だけ（置いてあるファイルには署名しない）。
// 鍵が無いと書かない（JSON と署名がずれると、アプリが受け取らないため）。試すだけなら --unsigned
//
// 出力: resources/ubo-scriptlets.json と resources/ubo-scriptlets.json.sig（base64）
//   { format, ubo, commit, generated, license, notice, source, scriptlets: [{ name, aliases, requiresTrust, world, dependencies, priority, js }] }
// js は uBO の関数の fn.toString() そのもの（変えない）。uBO の redirect-engine が作る中身と同じ。
//
// uBO は GPLv3（またはそれ以降）。この JSON も同じライセンス（resources/README.md）。

import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { signBytes, checkSigningKey, appPublicKey } from './sign.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const outFile = path.join(root, 'resources', 'ubo-scriptlets.json');

const UA = { 'User-Agent': 'vela-ubo-build', 'Accept': 'application/vnd.github+json' };
if (process.env.GITHUB_TOKEN) UA.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

async function latestTag() {
    const r = await fetch('https://api.github.com/repos/gorhill/uBlock/releases/latest', { headers: UA });
    if (!r.ok) throw new Error(`latest release: HTTP ${r.status}`);
    const j = await r.json();
    return j.tag_name;
}

async function commitOf(tag) {
    const r = await fetch(`https://api.github.com/repos/gorhill/uBlock/commits/${encodeURIComponent(tag)}`, { headers: UA });
    if (!r.ok) throw new Error(`commit of ${tag}: HTTP ${r.status}`);
    return (await r.json()).sha;
}

async function download(tag, dir) {
    const r = await fetch(`https://codeload.github.com/gorhill/uBlock/tar.gz/refs/tags/${encodeURIComponent(tag)}`);
    if (!r.ok) throw new Error(`tarball ${tag}: HTTP ${r.status}`);
    const tgz = path.join(dir, 'ubo.tgz');
    writeFileSync(tgz, Buffer.from(await r.arrayBuffer()));
    // Windows 10 以降と Ubuntu の tar（どちらも gzip を読める）
    execFileSync('tar', ['-xzf', 'ubo.tgz'], { cwd: dir });
    const top = `uBlock-${tag}`;
    const src = path.join(dir, top, 'src', 'js', 'resources', 'scriptlets.js');
    if (!existsSync(src)) throw new Error(`not found: ${src}`);
    return src;
}

/// uBO の registeredScriptlets を読む（ES モジュールなので import する）
export async function loadScriptlets(scriptletsJs) {
    // トップレベルで self などを触るモジュールへの、最小の代わり
    globalThis.self ??= globalThis;
    const mod = await import(pathToFileURL(scriptletsJs).href);
    const list = mod.builtinScriptlets;
    if (!Array.isArray(list) || list.length === 0) throw new Error('builtinScriptlets is empty');
    return list.map(d => ({
        name: d.name,
        aliases: Array.isArray(d.aliases) ? d.aliases : [],
        requiresTrust: d.requiresTrust === true,
        world: d.world === 'ISOLATED' ? 'ISOLATED' : 'MAIN',
        dependencies: Array.isArray(d.dependencies) ? d.dependencies.map(x => typeof x === 'function' ? x.details.name : x) : [],
        priority: typeof d.priority === 'number' ? d.priority : null,
        js: d.fn.toString(),
    }));
}

/// redirect 用のリソース（src/web_accessible_resources）のうち、+js で注入できる JS（uBO の redirect-engine の loadBuiltinResources と同じ）
export async function loadResources(jsDir) {
    const mod = await import(pathToFileURL(path.join(jsDir, 'redirect-resources.js')).href);
    const war = path.join(jsDir, '..', 'web_accessible_resources');
    const out = [];
    for (const [name, details] of mod.default) {
        if (details.data !== 'text' || !name.endsWith('.js')) continue;
        const file = path.join(war, name);
        if (!existsSync(file)) continue;
        // removeTopCommentBlock と同じ
        const js = readFileSync(file, 'utf8').replace(/^\/\*[\S\s]+?\*\/\s*/g, '');
        const alias = details.alias === undefined ? [] : Array.isArray(details.alias) ? details.alias : [details.alias];
        out.push({
            name,
            aliases: alias,
            requiresTrust: details.requiresTrust === true,
            world: 'MAIN',
            dependencies: [],
            priority: null,
            js,
        });
    }
    return out;
}

export async function build(tag) {
    tag ??= await latestTag();
    const dir = mkdtempSync(path.join(tmpdir(), 'vela-ubo-'));
    try {
        const src = await download(tag, dir);
        const scriptlets = await loadScriptlets(src);
        const names = new Set(scriptlets.map(s => s.name));
        for (const r of await loadResources(path.join(path.dirname(src), '..'))) {
            if (!names.has(r.name)) scriptlets.push(r);
        }
        const commit = await commitOf(tag).catch(() => null);
        return {
            format: 1,
            ubo: tag,
            commit,
            generated: null,      // main で入れる（中身が変わったときだけ時刻を変えるため）
            license: 'GPL-3.0-or-later',
            notice: 'uBlock Origin - Copyright (C) 2014-present Raymond Hill. Functions are taken unmodified from https://github.com/gorhill/uBlock (src/js/resources) under the GNU General Public License v3 or later.',
            source: `https://github.com/gorhill/uBlock/tree/${tag}/src/js/resources`,
            scriptlets,
        };
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
}

function signingKey() {
    if (process.env.UBO_SIGNING_KEY) return process.env.UBO_SIGNING_KEY;
    if (process.env.UBO_SIGNING_KEY_FILE) return readFileSync(process.env.UBO_SIGNING_KEY_FILE, 'utf8');
    return null;
}

async function main() {
    const args = process.argv.slice(2);
    const unsigned = args.includes('--unsigned');
    const tag = args.find(a => !a.startsWith('--'));
    const key = signingKey();
    if (!key && !unsigned) throw new Error('署名の鍵がありません（UBO_SIGNING_KEY / UBO_SIGNING_KEY_FILE。試すだけなら --unsigned）');
    if (key) checkSigningKey(key, appPublicKey(root));
    const out = await build(tag);
    let prev = null;
    if (existsSync(outFile)) { try { prev = JSON.parse(readFileSync(outFile, 'utf8')); } catch { } }
    const same = prev && prev.ubo === out.ubo && JSON.stringify(prev.scriptlets) === JSON.stringify(out.scriptlets);
    if (same) {
        console.log(`変わっていません: uBO ${out.ubo}（${out.scriptlets.length} 個）`);
        process.exitCode = 0;
        return;
    }
    out.generated = new Date().toISOString();
    const bytes = Buffer.from(JSON.stringify(out, null, 1) + '\n', 'utf8');
    writeFileSync(outFile, bytes);
    if (key) {
        writeFileSync(outFile + '.sig', signBytes(bytes, key) + '\n');
        console.log(`書きました（署名つき）: ${path.relative(root, outFile)}  uBO ${out.ubo}（${out.scriptlets.length} 個）`);
    } else {
        console.log(`書きました（署名なし。アプリは受け取りません）: ${path.relative(root, outFile)}`);
    }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch(e => { console.error(e); process.exit(1); });
}
