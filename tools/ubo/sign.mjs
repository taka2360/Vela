// 署名と確認（Ed25519。署名するのは JSON のファイルのバイト列そのもの）
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';

export function signBytes(bytes, privatePem) {
    let pem = privatePem.trim();
    if (pem.includes('\\n')) pem = pem.replace(/\\n/g, '\n');
    return sign(null, bytes, createPrivateKey(pem)).toString('base64');
}

// アプリが持っている公開鍵（Sources/AdBlock/ScriptletVerify.swift の publicKeyBase64）
export function appPublicKey(root) {
    const swift = readFileSync(`${root}/Sources/AdBlock/ScriptletVerify.swift`, 'utf8');
    const m = /publicKeyBase64\s*=\s*"([^"]+)"/.exec(swift);
    if (!m) throw new Error('ScriptletVerify.swift に publicKeyBase64 がありません');
    return m[1];
}

// 秘密鍵で実際に署名して、アプリの公開鍵で確かめる。だめなら例外（メッセージに鍵の中身は出さない）。
// uBO の中身が変わらない日は署名まで進まないので、壊れた鍵に気づけるよう毎回最初に呼ぶ。
export function checkSigningKey(privatePem, publicKeyBase64) {
    const probe = Buffer.from('vela-ubo-signing-key-check');
    let sig;
    try {
        sig = signBytes(probe, privatePem);
    } catch (e) {
        throw new Error(`署名の鍵が読めません（${e.code ?? e.message}）。resources/README.md の手順で入れ直してください`);
    }
    if (!verifyBytes(probe, sig, publicKeyBase64)) {
        throw new Error('署名の鍵がアプリの公開鍵（ScriptletVerify.publicKeyBase64）と合いません');
    }
}

export function verifyBytes(bytes, sigBase64, publicKeyBase64) {
    const x = Buffer.from(publicKeyBase64, 'base64').toString('base64url');
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x }, format: 'jwk' });
    return verify(null, bytes, key, Buffer.from(sigBase64.trim(), 'base64'));
}
