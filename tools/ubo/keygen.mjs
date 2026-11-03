// 道具の JSON に署名する鍵（Ed25519）を作る。
//   node tools/ubo/keygen.mjs <秘密鍵を書くファイル>
// 秘密鍵（PKCS#8 PEM）は GitHub の Secrets「UBO_SIGNING_KEY」に入れ、リポジトリには入れない。
// 公開鍵（32 バイトの base64）は Sources/AdBlock/ScriptletVerify.swift の publicKeyBase64 に入れる。
import { generateKeyPairSync } from 'node:crypto';
import { writeFileSync, existsSync } from 'node:fs';

const file = process.argv[2];
if (!file) { console.error('使い方: node tools/ubo/keygen.mjs <秘密鍵を書くファイル>'); process.exit(2); }
if (existsSync(file)) { console.error(`もうあります（上書きしません）: ${file}`); process.exit(1); }
const { publicKey, privateKey } = generateKeyPairSync('ed25519');
writeFileSync(file, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
const raw = publicKey.export({ format: 'jwk' }).x;          // base64url の 32 バイト
const b64 = Buffer.from(raw, 'base64url').toString('base64');
console.log(`秘密鍵: ${file}`);
console.log(`公開鍵（ScriptletVerify.publicKeyBase64）: ${b64}`);
