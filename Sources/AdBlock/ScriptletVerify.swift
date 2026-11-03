import Foundation
import CryptoKit

// MARK: - 落とした道具（resources/ubo-scriptlets.json）が本物かを確かめる
//
// GitHub Actions が uBO のソースから作って Ed25519 で署名したものだけを受け取る（tools/ubo/build_scriptlets.mjs）。
// 秘密鍵は Actions の Secrets にだけある。公開鍵はここに埋め込む（tools/ubo/keygen.mjs が出したもの）。
// 署名の後に、形式・大きさ・前より古くないか（ScriptletLibrary.acceptUpdate）も確かめる

enum ScriptletVerify {
    /// Ed25519 の公開鍵（32 バイトの base64）。tools/ubo/verify.mjs もここを読む
    static let publicKeyBase64 = "4z7T7t38qr+xB8738lQD+r2cStOVyyumyj8Txk0MPwk="

    /// 署名が合えば true。sig は base64（前後の空白・改行は無視）
    static func isValidSignature(_ data: Data, signature sig: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: sig.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sigData, for: data)
    }

    /// 署名と中身を確かめて、使える道具を返す。だめなら理由
    static func verify(_ data: Data, signature sig: String, current: ScriptletLibrary?) -> Result<ScriptletLibrary, ScriptletLibrary.UpdateError> {
        if data.count > ScriptletLibrary.maxBytes { return .failure(.tooLarge(data.count)) }
        guard isValidSignature(data, signature: sig) else { return .failure(.badSignature) }
        return ScriptletLibrary.acceptUpdate(data, current: current)
    }
}
