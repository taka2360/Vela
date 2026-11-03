// CryptoKit の形だけ（iOS 16 SDK と同じ名前・ラベル・型）。Vela が使う所だけ
import Foundation

public enum CryptoKitError: Error {
    case incorrectKeySize
    case incorrectParameterSize
    case authenticationFailure
    case underlyingCoreCryptoError(error: Int32)
}

public enum Curve25519 {
    public enum Signing {
        public struct PublicKey {
            public init<D>(rawRepresentation data: D) throws where D: ContiguousBytes { }
            public var rawRepresentation: Data { Data() }
            public func isValidSignature<S, D>(_ signature: S, for data: D) -> Bool where S: DataProtocol, D: DataProtocol { false }
        }
    }
}
