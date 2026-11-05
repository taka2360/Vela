// resources/ubo-scriptlets.json の署名を、アプリと同じ公開鍵で確かめる（終了コード 0 / 1）
//   node tools/ubo/verify.mjs
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyBytes, appPublicKey } from './sign.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
let publicKey;
try { publicKey = appPublicKey(root); } catch (e) { console.error(e.message); process.exit(1); }
const json = readFileSync(path.join(root, 'resources', 'ubo-scriptlets.json'));
const sig = readFileSync(path.join(root, 'resources', 'ubo-scriptlets.json.sig'), 'utf8');
if (!verifyBytes(json, sig, publicKey)) { console.error('署名が合いません'); process.exit(1); }
console.log('署名 OK');
