// uBO のリスト（include 込み）で使われている +js の名前のうち、resources/ubo-scriptlets.json に無いものを出す。
//   node tools/ubo/check_lists.mjs
// リストと道具の版のずれに気づくため。失敗（終了コード 1）にはしない。
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const lib = JSON.parse(readFileSync(path.join(root, 'resources', 'ubo-scriptlets.json'), 'utf8'));
const LISTS = [
    'https://ublockorigin.github.io/uAssets/filters/filters.txt',
    'https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt',
];

const known = new Map();
for (const s of lib.scriptlets) {
    known.set(s.name, s.name);
    for (const a of s.aliases) known.set(a, s.name);
}

async function fetchWithIncludes(url, seen = new Set()) {
    if (seen.has(url)) return '';
    seen.add(url);
    const r = await fetch(url);
    if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
    let text = await r.text();
    const base = url.slice(0, url.lastIndexOf('/') + 1);
    const parts = [text];
    for (const m of text.matchAll(/^!#include +(\S+)/gm)) {
        if (m[1].includes('..') || /^[a-z]+:/i.test(m[1])) continue;
        parts.push(await fetchWithIncludes(base + m[1], seen));
    }
    return parts.join('\n');
}

const counts = new Map();
let total = 0;
for (const url of LISTS) {
    const text = await fetchWithIncludes(url);
    for (const m of text.matchAll(/#@?#\+js\(([^,)]*)/g)) {
        const raw = m[1].trim();
        if (raw === '') continue;
        total += 1;
        const token = raw.endsWith('.js') ? raw : raw + '.js';
        if (!known.has(token)) counts.set(raw, (counts.get(raw) ?? 0) + 1);
    }
}
console.log(`uBO ${lib.ubo}: リストの +js ${total} 行`);
if (counts.size === 0) {
    console.log('知らない名前はありません');
} else {
    console.log('道具に無い名前（リストの方が新しい uBO を前提にしている）:');
    for (const [n, c] of [...counts].sort((a, b) => b[1] - a[1])) console.log(`  ${n}（${c}）`);
}
