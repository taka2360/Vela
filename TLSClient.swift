import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - https の暗号（TLS）を、自作の TCP の上で動かす
//
// iPad の普通の通信の部品（Network.framework）は、自分で作った TCP の上では TLS を使えない。
// そこで、古いけれど今も使える Apple の「SecureTransport」（SSLCreateContext など）を使う。
// これは「読む・書く」を自分で用意できるので、GuestTCP の上で TLS 1.2 を話せる。
// 証明書は iPad と同じ仕組みで確かめる（相手の名前も確かめる）。
// ブラウザらしく見えるよう: ALPN（http/1.1）を名乗る・前の暗号の約束を使い回す（セッション再開。握手が速くなる）
//
// 注意（技術的負債）: SecureTransport は 2019 年から非推奨で、TLS 1.3 には対応しない（Apple TN3151）。
// なので VNet の TLS は 1.2 まで。TLS 1.3 だけのサーバーは版が合わずに失敗する（versionMismatch）。そのときは標準の通信で開く。
// 自作の TCP の上では Network.framework の TLS を使えないので、TLS エンジンの移行は別の課題にしている
//
// 使い方: TLSStream(host:) を作る → TCP がつながったら attach → onReady で write → onData で中身が届く → onClosed
// SecureTransport が無い環境では TLSStream(host:) が nil を返す（https は使えない）

#if canImport(Security) && os(iOS)
final class TLSStream: @unchecked Sendable {
    static let isSupported = true
    let host: String
    private let ctx: SSLContext
    private var tcp: GuestTCP?
    /// TCP から届いて、まだ TLS に渡していないもの（inbox[inboxPos...]）。先頭を消すと遅いので、位置で覚える
    private var inbox = [UInt8]()
    private var inboxPos = 0
    private var tcpEnded = false
    private var handshaking = true
    private var pendingWrite = Data()
    private var done = false
    /// 握手に失敗したときの番号（0 なら握手の失敗ではない）
    private(set) var handshakeError: OSStatus = 0
    /// 決まった版（"TLS 1.2" など）
    private(set) var version = ""
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    init?(host: String, port: UInt16 = 443) {
        self.host = host
        guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
        ctx = c
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetProtocolVersionMax(ctx, .tlsProtocol12)      // SecureTransport は 1.3 を話せない
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
        SSLSetALPNProtocols(ctx, ["http/1.1"] as CFArray)
        let peer = Array("\(host):\(port)".utf8)
        _ = peer.withUnsafeBytes { SSLSetPeerID(ctx, $0.baseAddress, $0.count) }
    }

    /// 証明書の問題での失敗か
    var failedOnCertificate: Bool { handshakeError <= -9807 && handshakeError >= -9815 }

    /// 版や暗号の組み合わせが合わずに失敗したか（相手が TLS 1.3 だけなど）
    /// -9836: errSSLPeerProtocolVersion（相手が版を断った）、-9831: errSSLPeerHandshakeFail、-9801: errSSLNegotiation、-9830: errSSLIllegalParam
    var versionMismatch: Bool { [-9836, -9831, -9801].contains(handshakeError) }

    /// TCP がつながったら呼ぶ
    func attach(_ t: GuestTCP) {
        tcp = t
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        drive()
    }

    /// TCP から届いたもの
    func tcpData(_ d: Data) {
        if inboxPos > 65536 && inboxPos * 2 > inbox.count { inbox.removeFirst(inboxPos); inboxPos = 0 }
        inbox.append(contentsOf: d)
        drive()
    }

    func tcpClosed(_ error: String?) {
        tcpEnded = true
        // まだ attach していない（TCP がつながる前に閉じた・取り消した）: SecureTransport には触らない。
        // SSLSetConnection の前に SSLHandshake を呼ぶと、tlsWrite に null が来て落ちた（実機の記録: TLSStream.writeFrom で 0x28）
        if tcp != nil { drive() }
        if !done { finish(error ?? (handshaking ? "TLS の途中で切れました" : nil)) }
    }

    /// 暗号にして送る（つながる前なら、つながってから送る）
    func write(_ d: Data) {
        if done { return }
        if handshaking { pendingWrite.append(d); return }
        // 書き込みの関数（tlsWrite）は全部を TCP に渡すので、普通は 1 回で全部書ける。
        // それでも、書けた分を確かめて残りを書く。エラーなら閉じる（黙って捨てない）
        var offset = 0
        while offset < d.count {
            var processed = 0
            let st = d.withUnsafeBytes { buf -> OSStatus in
                SSLWrite(ctx, buf.baseAddress! + offset, d.count - offset, &processed)
            }
            offset += processed
            if st == errSSLWouldBlock && processed > 0 { continue }
            if st != errSecSuccess {
                finish("TLS の書き込みに失敗（\(st)）")
                return
            }
            if processed == 0 { finish("TLS の書き込みが進みません"); return }
        }
    }

    private func finish(_ error: String?) {
        if done { return }
        done = true
        tcp?.abort()
        onClosed?(error)
    }

    /// 進められるところまで進める（握手 → 読む）
    private func drive() {
        if done || tcp == nil { return }
        if handshaking {
            let st = SSLHandshake(ctx)
            if st == errSSLWouldBlock { return }
            if st != errSecSuccess {
                handshakeError = st
                finish("TLS の握手に失敗（\(st)）" + (failedOnCertificate ? "：証明書を確かめられません"
                                                   : versionMismatch ? "：TLS の版が合いません（VNet は TLS 1.2 まで）" : ""))
                return
            }
            handshaking = false
            var p = SSLProtocol.sslProtocolUnknown
            SSLGetNegotiatedProtocolVersion(ctx, &p)
            version = p == .tlsProtocol13 ? "TLS 1.3" : p == .tlsProtocol12 ? "TLS 1.2" : "TLS（\(p.rawValue)）"
            onReady?()
            if !pendingWrite.isEmpty { let w = pendingWrite; pendingWrite = Data(); write(w) }
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var n = 0
            let st = buf.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress!, $0.count, &n) }
            if n > 0 { onData?(Data(buf[0..<n])) }
            if st == errSSLWouldBlock { if tcpEnded && inboxPos >= inbox.count { finish(nil) }; return }
            if st == errSSLClosedGraceful || st == errSSLClosedNoNotify || st == errSSLClosedAbort { finish(nil); return }
            if st != errSecSuccess { finish("TLS の読み込みに失敗（\(st)）"); return }
        }
    }

    // SecureTransport から呼ばれる「読む・書く」
    fileprivate func readInto(_ p: UnsafeMutableRawPointer, _ want: Int) -> (Int, OSStatus) {
        let avail = inbox.count - inboxPos
        if avail <= 0 { return (0, tcpEnded ? errSSLClosedNoNotify : errSSLWouldBlock) }
        let n = min(want, avail)
        inbox.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + inboxPos, byteCount: n) }
        inboxPos += n
        return (n, n < want ? errSSLWouldBlock : errSecSuccess)
    }

    fileprivate func writeFrom(_ p: UnsafeRawPointer, _ n: Int) -> OSStatus {
        guard let t = tcp else { return errSSLClosedAbort }
        t.write(Data(bytes: p, count: n))
        return errSecSuccess
    }
}

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    // 念のため: 接続の印が無ければ（SSLSetConnection の前）何も読まない
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    let (n, st) = s.readInto(data, length.pointee)
    length.pointee = n
    return st
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    if Int(bitPattern: conn) == 0 { length.pointee = 0; return errSSLClosedAbort }
    let s = Unmanaged<TLSStream>.fromOpaque(conn).takeUnretainedValue()
    return s.writeFrom(data, length.pointee)
}
#else
/// SecureTransport が無い環境用の代わり（作れない）
final class TLSStream: @unchecked Sendable {
    static let isSupported = false
    let handshakeError: Int32 = 0
    let version = ""
    var failedOnCertificate: Bool { false }
    var versionMismatch: Bool { false }
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?
    init?(host: String, port: UInt16 = 443) { return nil }
    func attach(_ t: GuestTCP) {}
    func tcpData(_ d: Data) {}
    func tcpClosed(_ error: String?) {}
    func write(_ d: Data) {}
}
#endif
