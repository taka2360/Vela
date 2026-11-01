// iOS の Security（SecureTransport）の「形だけ」（Linux で型チェックするためのスタブ）
// 型は iOS SDK の Swift 版の見え方に合わせている
@_exported import Foundation

public typealias OSStatus = Int32
public final class CFAllocator {}
public final class SSLContext {}
/// iOS では CFArray は Swift の配列から `as CFArray` で作れる（ここでは配列の書き方だけ受け付ける）
public final class CFArray: ExpressibleByArrayLiteral { public init(arrayLiteral elements: Any...) {} }
public typealias SSLConnectionRef = UnsafeRawPointer
public typealias SSLReadFunc = @convention(c) (SSLConnectionRef, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> OSStatus
public typealias SSLWriteFunc = @convention(c) (SSLConnectionRef, UnsafeRawPointer, UnsafeMutablePointer<Int>) -> OSStatus

public enum SSLProtocolSide: Int32 { case serverSide = 0, clientSide = 1 }
public enum SSLConnectionType: Int32 { case streamType = 0, datagramType = 1 }
public enum SSLProtocol: Int32 {
    case sslProtocolUnknown = 0, sslProtocol3 = 2, tlsProtocol1 = 4, tlsProtocol11 = 7, tlsProtocol12 = 8, tlsProtocol13 = 10
}
public enum SSLSessionOption: Int32 { case breakOnServerAuth = 0, breakOnCertRequested = 1, breakOnClientAuth = 2 }

@discardableResult public func SSLCreateContext(_ alloc: CFAllocator?, _ protocolSide: SSLProtocolSide, _ connectionType: SSLConnectionType) -> SSLContext? { nil }
@discardableResult public func SSLSetIOFuncs(_ context: SSLContext, _ readFunc: SSLReadFunc, _ writeFunc: SSLWriteFunc) -> OSStatus { 0 }
@discardableResult public func SSLSetConnection(_ context: SSLContext, _ connection: SSLConnectionRef?) -> OSStatus { 0 }
@discardableResult public func SSLSetPeerDomainName(_ context: SSLContext, _ peerName: UnsafePointer<CChar>?, _ peerNameLen: Int) -> OSStatus { 0 }
@discardableResult public func SSLSetProtocolVersionMax(_ context: SSLContext, _ maxVersion: SSLProtocol) -> OSStatus { 0 }
@discardableResult public func SSLSetProtocolVersionMin(_ context: SSLContext, _ minVersion: SSLProtocol) -> OSStatus { 0 }
@discardableResult public func SSLSetSessionOption(_ context: SSLContext, _ option: SSLSessionOption, _ value: Bool) -> OSStatus { 0 }
@discardableResult public func SSLSetPeerID(_ context: SSLContext, _ peerID: UnsafeRawPointer?, _ peerIDLen: Int) -> OSStatus { 0 }
@discardableResult public func SSLSetALPNProtocols(_ context: SSLContext, _ protocols: CFArray) -> OSStatus { 0 }
@discardableResult public func SSLGetNegotiatedProtocolVersion(_ context: SSLContext, _ protocol: UnsafeMutablePointer<SSLProtocol>) -> OSStatus { 0 }
@discardableResult public func SSLHandshake(_ context: SSLContext) -> OSStatus { 0 }
@discardableResult public func SSLRead(_ context: SSLContext, _ data: UnsafeMutableRawPointer, _ dataLength: Int, _ processed: UnsafeMutablePointer<Int>) -> OSStatus { 0 }
@discardableResult public func SSLWrite(_ context: SSLContext, _ data: UnsafeRawPointer?, _ dataLength: Int, _ processed: UnsafeMutablePointer<Int>) -> OSStatus { 0 }
@discardableResult public func SSLClose(_ context: SSLContext) -> OSStatus { 0 }
@discardableResult public func SSLGetBufferedReadSize(_ context: SSLContext, _ bufferSize: UnsafeMutablePointer<Int>) -> OSStatus { 0 }

public var errSecSuccess: OSStatus { 0 }
public var errSSLWouldBlock: OSStatus { -9803 }
public var errSSLClosedGraceful: OSStatus { -9805 }
public var errSSLClosedAbort: OSStatus { -9806 }
public var errSSLXCertChainInvalid: OSStatus { -9807 }
public var errSSLClosedNoNotify: OSStatus { -9816 }
public var errSSLPeerAuthCompleted: OSStatus { -9841 }
