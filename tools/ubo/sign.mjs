// 署名と確認（Ed25519。署名するのは JSON のファイルのバイト列そのもの）
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';

export function signBytes(bytes, privatePem) {
    let pem = privatePem.trim();
    if (pem.includes('\\n')) pem = pem.replace(/\\n/g, '\n');
    return sign(null, bytes, createPrivateKey(pem)).toString('base64');
}

export function verifyBytes(bytes, sigBase64, publicKeyBase64) {
    const x = Buffer.from(publicKeyBase64, 'base64').toString('base64url');
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x }, format: 'jwk' });
    return verify(null, bytes, key, Buffer.from(sigBase64.trim(), 'base64'));
}
