// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 9 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - TLSClient.swift
// ======================================================================

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

// ======================================================================
// MARK: - GuestStack.swift
// ======================================================================

// MARK: - ゲスト側の小さな TCP/IP（Linux の代わり）
//
// ・DHCP で IP アドレスをもらう（ルーター UserNet が 10.0.2.15 をくれる）
// ・ARP でルーター（10.0.2.2）の MAC アドレスを調べる
// ・DNS（10.0.2.3）で名前を IP アドレスにする
// ・TCP でつなぐ（GuestTCP。送り直し・順番の確認など最低限）
// すべて queue（VNetMachine.queue）の上で動く

final class GuestStack: @unchecked Sendable {
    let queue: DispatchQueue
    /// フレームを送る（ドライバへ）
    var output: (([UInt8]) -> Void)?
    /// 何が起きたかを知らせる（画面のログ用）
    var trace: ((String) -> Void)?
    /// TCP の送り直しの回数（開発者向け。queue の上で数える）
    var retransmits = 0
    /// 順番を飛ばして届き、取っておいた TCP のセグメントの数（開発者向け）
    var reordered = 0

    var mac = Net.guestMAC
    private(set) var ip = Net.zeroIP
    private(set) var router = Net.gateway
    private(set) var dns = Net.dns
    private(set) var ready = false
    private var routerMAC: [UInt8]?
    /// ルーターの MAC が分かるまで待たせる IP パケット
    private var waitingForARP: [[UInt8]] = []
    private var ipID: UInt16 = 1
    private var nextPort: UInt16 = 40000
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: 受け取り

    func input(_ f: [UInt8]) {
        guard let e = EthernetFrame(f) else { return }
        switch e.type {
        case EtherType.arp: handleARP(e.body)
        case EtherType.ipv4: handleIPv4(e.body)
        default: break
        }
    }

    // MARK: イーサネット・ARP

    private func sendEthernet(_ type: UInt16, to dst: [UInt8], _ payload: [UInt8]) {
        output?(Ethernet.frame(dst: dst, src: mac, type: type, payload))
    }

    private func askRouterMAC() {
        let a = ARP.packet(op: ARP.request, senderMAC: mac, senderIP: ip, targetMAC: Net.zeroMAC, targetIP: router)
        sendEthernet(EtherType.arp, to: Net.broadcastMAC, a)
        trace?("→ ARP \(router.ipString) はどこ？")
    }

    private func handleARP(_ p: [UInt8]) {
        guard let a = ARPPacket(p) else { return }
        let op = a.op, senderMAC = a.senderMAC, senderIP = a.senderIP, target = a.targetIP
        if op == ARP.reply && senderIP == router {
            if routerMAC == nil { trace?("← ARP \(router.ipString) は \(senderMAC.macString)") }
            routerMAC = senderMAC
            let w = waitingForARP
            waitingForARP = []
            for pkt in w { sendEthernet(EtherType.ipv4, to: senderMAC, pkt) }
        } else if op == ARP.request && target == ip && ip != Net.zeroIP {
            let r = ARP.packet(op: ARP.reply, senderMAC: mac, senderIP: ip, targetMAC: senderMAC, targetIP: senderIP)
            sendEthernet(EtherType.arp, to: senderMAC, r)
        }
    }

    // MARK: IPv4

    private func sendIPv4(proto: UInt8, dst: [UInt8], _ body: [UInt8], broadcast: Bool = false) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: ip, dst: dst, body)
        ipID &+= 1
        if broadcast { sendEthernet(EtherType.ipv4, to: Net.broadcastMAC, pkt); return }
        // 外へは全部ルーター経由（10.0.2.x もルーターが答える）
        if let m = routerMAC { sendEthernet(EtherType.ipv4, to: m, pkt) } else {
            waitingForARP.append(pkt)
            askRouterMAC()
        }
    }

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p) else { return }
        switch pkt.proto {
        case IPProto.tcp: handleTCP(src: pkt.src, pkt.body)
        case IPProto.udp: handleUDP(pkt.body)
        default: break
        }
    }

    // MARK: UDP（DHCP と DNS）

    private func sendUDP(sport: UInt16, dst: [UInt8], dport: UInt16, _ payload: [UInt8], broadcast: Bool = false) {
        let u = UDPDatagram.build(src: ip, dst: dst, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, dst: dst, u, broadcast: broadcast)
    }

    private func handleUDP(_ b: [UInt8]) {
        guard let u = UDPDatagram(b) else { return }
        if u.sport == 67 && u.dport == 68 { handleDHCP(u.payload) }
        else if u.sport == 53, let q = dnsQueries.removeValue(forKey: u.dport) { q.finish(u.payload) }
    }

    private func allocPort() -> UInt16 {
        nextPort = nextPort >= 60000 ? 40000 : nextPort + 1
        return nextPort
    }

    // MARK: DHCP

    private let dhcpXID = UInt32.random(in: 1...UInt32.max)
    private var dhcpSentAt = Date.distantPast
    private var onReady: [() -> Void] = []

    /// IP アドレスをもらう（もらえたら done が呼ばれる）
    func start(_ done: @escaping () -> Void) {
        onReady.append(done)
        sendDHCP(type: DHCP.discover, requested: nil)
    }

    private func sendDHCP(type: UInt8, requested: [UInt8]?) {
        var m = [UInt8](repeating: 0, count: 236)
        m[0] = 1; m[1] = 1; m[2] = 6                       // 問い合わせ・イーサネット・MAC は 6 バイト
        m.setBE32(dhcpXID, at: 4)
        m[10] = 0x80                                       // ブロードキャストで返してほしい
        m.replaceSubrange(28..<34, with: mac)
        m += DHCP.magicCookie
        m += [53, 1, type]
        if let r = requested {
            // 配列を + でつなぐと型チェックがとても遅いので、1 つずつ足す
            m.append(contentsOf: [50, 4] as [UInt8])
            m.append(contentsOf: r)
            m.append(contentsOf: [54, 4] as [UInt8])
            m.append(contentsOf: router)
        }
        m += [55, 3, 1, 3, 6, 255]                         // ほしいもの: サブネット・ルーター・DNS
        sendUDP(sport: 68, dst: Net.broadcastIP, dport: 67, m, broadcast: true)
        dhcpSentAt = Date()
        trace?(type == DHCP.discover ? "→ DHCP DISCOVER（IP アドレスをください）" : "→ DHCP REQUEST")
    }

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 2, p.be32(at: 4) == dhcpXID else { return }
        let yiaddr = Array(p[16..<20])
        let opts = DHCP.options(p)
        if let r = opts[3], r.count >= 4 { router = Array(r[0..<4]) }
        if let d = opts[6], d.count >= 4 { dns = Array(d[0..<4]) }
        let type = opts[53]?.first ?? 0
        if type == DHCP.offer {
            trace?("← DHCP OFFER \(yiaddr.ipString)")
            sendDHCP(type: DHCP.request, requested: yiaddr)
        } else if type == DHCP.ack && !ready {
            ip = yiaddr
            ready = true
            trace?("← DHCP ACK: IP \(ip.ipString)・ルーター \(router.ipString)・DNS \(dns.ipString)")
            let w = onReady
            onReady = []
            for f in w { f() }
        }
    }

    // MARK: DNS

    private final class DNSQuery {
        let packet: [UInt8]
        let done: ([UInt8]?) -> Void
        var sentAt = Date()
        var tries = 0
        private var finished = false
        init(packet: [UInt8], done: @escaping ([UInt8]?) -> Void) { self.packet = packet; self.done = done }
        func finish(_ reply: [UInt8]?) {
            if finished { return }
            finished = true
            done(reply.flatMap(DNSMessage.firstA))
        }
    }
    private var dnsQueries: [UInt16: DNSQuery] = [:]

    /// 名前を IPv4 アドレスにする（IP アドレスの形ならそのまま）
    func resolve(_ name: String, _ done: @escaping ([UInt8]?) -> Void) {
        let labels = name.split(separator: ".")
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4 && octets.count == 4 { done(octets); return }
        let packet = DNSMessage.query(name: name, id: .random(in: 0...UInt16.max))
        let port = allocPort()
        dnsQueries[port] = DNSQuery(packet: packet) { [weak self] ip in
            self?.trace?("← DNS \(name) = " + (ip?.ipString ?? "見つからない"))
            done(ip)
        }
        trace?("→ DNS \(name) は？")
        sendUDP(sport: port, dst: dns, dport: 53, packet)
    }

    // MARK: TCP

    private struct TCPKey: Hashable { let lport: UInt16; let rip: [UInt8]; let rport: UInt16 }
    private var tcps: [TCPKey: GuestTCP] = [:]

    private static func key(_ c: GuestTCP) -> TCPKey { TCPKey(lport: c.lport, rip: c.rip, rport: c.rport) }

    /// TCP でつなぐ
    func connect(_ rip: [UInt8], _ rport: UInt16, handler: GuestTCP.Handler) -> GuestTCP {
        let c = GuestTCP(stack: self, lport: allocPort(), rip: rip, rport: rport, handler: handler)
        tcps[GuestStack.key(c)] = c
        c.sendSYN()
        trace?("→ TCP SYN \(rip.ipString):\(rport)")
        return c
    }

    /// 終わった接続を忘れる（GuestTCP から呼ぶ）
    func forget(_ c: GuestTCP) {
        tcps[GuestStack.key(c)] = nil
    }

    /// 組み立てた TCP セグメントを送る（GuestTCP から呼ぶ）
    func sendTCP(to dst: [UInt8], _ segment: [UInt8]) {
        sendIPv4(proto: IPProto.tcp, dst: dst, segment)
    }

    private func handleTCP(src: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b), let c = tcps[TCPKey(lport: h.dport, rip: src, rport: h.sport)] else { return }
        c.input(h, payload: b[h.headerLength...])
    }

    // MARK: 時間で見るもの（DHCP・DNS・TCP の送り直し）

    private func tick() {
        let now = Date()
        if !ready && now.timeIntervalSince(dhcpSentAt) > 2 && !onReady.isEmpty { sendDHCP(type: DHCP.discover, requested: nil) }
        for (port, q) in dnsQueries where now.timeIntervalSince(q.sentAt) > 2 {
            q.tries += 1
            if q.tries > 3 { dnsQueries[port] = nil; q.finish(nil); continue }
            q.sentAt = now
            sendUDP(sport: port, dst: dns, dport: 53, q.packet)
        }
        for c in Array(tcps.values) { c.tick(now) }
    }
}

// ======================================================================
// MARK: - GuestTCP.swift
// ======================================================================

// MARK: - ゲスト側の TCP の接続 1 本
//
// 作るのは GuestStack.connect。届いたセグメント（input）と時間（tick）も GuestStack から渡される。
// すべて GuestStack と同じ queue の上で動く

final class GuestTCP: @unchecked Sendable {
    struct Handler {
        var connected: () -> Void
        var data: (Data) -> Void
        var closed: (_ error: String?) -> Void
    }

    unowned let stack: GuestStack
    let lport: UInt16, rip: [UInt8], rport: UInt16
    private let handler: Handler
    private enum State { case synSent, established, closed }
    private var state = State.synSent
    private let iss = UInt32.random(in: 0...UInt32.max)
    private var sndUna: UInt32, sndNxt: UInt32
    private var rcvNxt: UInt32 = 0
    /// sndUna から先の、まだ受け取ってもらっていないデータ
    private var sendBuf = Data()
    private var wantFIN = false, finSent = false, gotFIN = false
    private var peerWindow = 65535
    private let mss = 1460
    private var lastProgress = Date()
    private var retries = 0
    /// 順番を飛ばして届いたデータ（番号 → 中身）。間が届いたら続けて渡す（落ちたフレームの分だけ送り直してもらえば済む）
    private var ooo: [UInt32: [UInt8]] = [:]
    private var oooBytes = 0
    static let reorderLimit = 256 * 1024
    /// 相手の窓が 0 になってからの時刻（窓を探る「持続タイマー」用）
    private var zeroWindowSince: Date?
    static let maxZeroWindow: TimeInterval = 60

    init(stack: GuestStack, lport: UInt16, rip: [UInt8], rport: UInt16, handler: Handler) {
        self.stack = stack; self.lport = lport; self.rip = rip; self.rport = rport; self.handler = handler
        sndUna = iss
        sndNxt = iss &+ 1
    }

    // MARK: 使う側から

    /// データを送る
    func write(_ d: Data) {
        guard state != .closed else { return }
        sendBuf.append(d)
        pump()
    }

    /// 送り終わったら閉じる
    func close() {
        wantFIN = true
        pump()
    }

    /// すぐに切る（RST）
    func abort() {
        if state != .closed { send([.rst, .ack]) }
        finish(nil)
    }

    // MARK: 送る

    private func send(_ flags: TCPFlags, mss withMSS: Bool = false, payload: ArraySlice<UInt8> = []) {
        let seq = flags.contains(.syn) ? iss : sndNxt
        let seg = TCPSegment.build(src: stack.ip, dst: rip, sport: lport, dport: rport, seq: seq,
                                   ack: flags.contains(.ack) ? rcvNxt : 0, flags: flags, mss: withMSS, payload: payload)
        stack.sendTCP(to: rip, seg)
    }

    /// 最初の SYN（GuestStack.connect から呼ぶ）
    func sendSYN() { send(.syn, mss: true) }

    private func finish(_ error: String?) {
        if state == .closed { return }
        state = .closed
        stack.forget(self)
        handler.closed(error)
    }

    /// 相手の窓の分だけ送る。全部送って閉じたいなら FIN
    private func pump() {
        guard state == .established else { return }
        while true {
            let inFlight = Int(sndNxt &- sndUna)
            let unsent = sendBuf.count - inFlight
            if unsent <= 0 {
                if wantFIN && !finSent {
                    send([.fin, .ack])
                    sndNxt &+= 1
                    finSent = true
                    lastProgress = Date()
                }
                return
            }
            let room = peerWindow - inFlight
            if room <= 0 { return }
            let n = min(unsent, mss, room)
            let start = sendBuf.startIndex + inFlight
            send([.ack, .psh], payload: ArraySlice(sendBuf[start..<(start + n)]))
            sndNxt &+= UInt32(n)
            lastProgress = Date()
        }
    }

    // MARK: GuestStack から

    /// 届いたセグメント
    func input(_ h: TCPHeader, payload: ArraySlice<UInt8>) {
        peerWindow = Int(h.window)
        if peerWindow > 0 { zeroWindowSince = nil } else if zeroWindowSince == nil { zeroWindowSince = Date() }
        if h.flags.contains(.rst) {
            stack.trace?("← TCP RST \(rip.ipString):\(rport)")
            finish(state == .synSent ? "つながりませんでした" : "相手に切られました")
            return
        }
        if state == .synSent {
            guard h.flags.contains([.syn, .ack]), h.ack == iss &+ 1 else { return }
            rcvNxt = h.seq &+ 1
            sndUna = h.ack
            state = .established
            retries = 0
            send(.ack)
            stack.trace?("← TCP SYN+ACK \(rip.ipString):\(rport)（つながった）")
            handler.connected()
            pump()
            return
        }
        guard state == .established else { return }
        if h.flags.contains(.ack) {
            let acked = h.ack &- sndUna
            let inFlight = sndNxt &- sndUna
            if acked > 0 && acked <= inFlight {
                var n = Int(acked)
                if finSent && h.ack == sndNxt { n -= 1 }        // FIN の分
                if n > 0 { sendBuf.removeFirst(min(n, sendBuf.count)) }
                sndUna = h.ack
                lastProgress = Date()
                retries = 0
            }
        }
        var needAck = false
        if !payload.isEmpty {
            deliver(seq: h.seq, Array(payload))
            if state == .closed { return }
            needAck = true
        }
        if h.flags.contains(.fin) && h.seq &+ UInt32(payload.count) == rcvNxt && !gotFIN {
            gotFIN = true
            rcvNxt &+= 1
            needAck = true
        }
        if needAck { send(.ack) }
        pump()
        if gotFIN {
            // 相手が閉じた: こちらも閉じて終わり（ブラウザ用なので、半分だけ閉じた状態は使わない）
            if !finSent { wantFIN = true; pump() }
            finish(nil)
        }
    }

    /// 届いた中身を、番号の順に渡す。重なっている所は外し、先の分は取っておく
    private func deliver(seq start: UInt32, _ bytes: [UInt8]) {
        var seq = start
        var data = bytes
        let before = Int32(bitPattern: rcvNxt &- seq)       // > 0: rcvNxt より前から始まる（送り直しの重なり）
        if before > 0 {
            if Int(before) >= data.count { return }         // 全部受け取り済み
            data.removeFirst(Int(before))
            seq = rcvNxt
        }
        if seq != rcvNxt {
            // 先の分: 窓の中で、置き場に余裕があれば取っておく
            let ahead = Int(Int32(bitPattern: seq &- rcvNxt))
            if ahead > 0 && ahead < GuestTCP.reorderLimit && oooBytes + data.count <= GuestTCP.reorderLimit && ooo[seq] == nil {
                ooo[seq] = data
                oooBytes += data.count
                stack.reordered += 1
            }
            return
        }
        rcvNxt &+= UInt32(data.count)
        handler.data(Data(data))
        // 取っておいた先の分が続いていれば渡す
        while state != .closed, let (k, v) = ooo.first(where: { Int32(bitPattern: rcvNxt &- $0.key) >= 0 }) {
            ooo[k] = nil
            oooBytes -= v.count
            let skip = Int(Int32(bitPattern: rcvNxt &- k))
            if skip < v.count {
                let rest = v[skip...]
                rcvNxt &+= UInt32(rest.count)
                handler.data(Data(rest))
            }
        }
    }

    /// 時間で見る（送り直し・窓を探る）
    func tick(_ now: Date) {
        if now.timeIntervalSince(lastProgress) < 1 { return }
        // 相手の窓が 0: 送り直しの回数に数えずに、1 バイトだけ送って窓が開いたかを探る（持続タイマー）。長く開かなければ切る
        if state == .established && peerWindow == 0 && !sendBuf.isEmpty {
            if let z = zeroWindowSince, now.timeIntervalSince(z) > GuestTCP.maxZeroWindow { abort(); return }
            sndNxt = sndUna
            finSent = false
            send([.ack, .psh], payload: ArraySlice(sendBuf.prefix(1)))
            sndNxt = sndUna &+ 1
            lastProgress = now
            return
        }
        if state == .synSent {
            retries += 1
            if retries > 8 { finish("つながりませんでした（時間切れ）"); return }
            sendSYN()
            lastProgress = now
        } else if state == .established && sndNxt != sndUna {
            retries += 1
            if retries > 12 { abort(); return }
            // 受け取りの返事が来ない: 先頭から送り直す
            stack.retransmits += 1
            sndNxt = sndUna
            finSent = false
            lastProgress = now
            pump()
        }
    }
}

// ======================================================================
// MARK: - DNSMessage.swift
// ======================================================================

// MARK: - DNS のメッセージ（A レコードだけ）
//
// ゲスト側: query で問い合わせを作り、firstA で返事から IPv4 アドレスを取り出す
// ルーター側: question で問い合わせを読み、reply で返事を作る

enum DNSMessage {
    /// A レコードの問い合わせ（再帰あり）
    static func query(name: String, id: UInt16) -> [UInt8] {
        var q: [UInt8] = []
        q.appendBE16(id)
        q += [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]      // RD=1・質問 1 つ
        for label in name.split(separator: ".") {
            let b = Array(label.utf8.prefix(63))
            q.append(UInt8(b.count))
            q += b
        }
        q += [0, 0, 1, 0, 1]                           // 名前の終わり・A・IN
        return q
    }

    /// 返事から最初の A レコード（IPv4 アドレス）を取り出す
    static func firstA(_ r: [UInt8]) -> [UInt8]? {
        guard r.count >= 12, r[3] & 0x0F == 0 else { return nil }
        let qd = Int(r.be16(at: 4)), an = Int(r.be16(at: 6))
        var i = 12
        func skipName() {
            while i < r.count {
                let l = Int(r[i])
                if l == 0 { i += 1; return }
                if l & 0xC0 == 0xC0 { i += 2; return }
                i += 1 + l
            }
        }
        for _ in 0..<qd { skipName(); i += 4 }
        for _ in 0..<an {
            skipName()
            guard i + 10 <= r.count else { return nil }
            let type = r.be16(at: i)
            let rdlen = Int(r.be16(at: i + 8))
            i += 10
            if type == 1 && rdlen == 4 && i + 4 <= r.count { return Array(r[i..<(i + 4)]) }
            i += rdlen
        }
        return nil
    }

    struct Question {
        let name: String
        let type: UInt16
        /// 質問の終わり（返事はここまでを写して作る）
        let end: Int
    }

    /// 問い合わせの最初の質問を読む（形が変なら nil）
    static func question(_ q: [UInt8]) -> Question? {
        var i = 12
        var labels: [String] = []
        while i < q.count {
            let l = Int(q[i])
            if l == 0 { i += 1; break }
            guard l < 64, i + 1 + l <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + l)], as: UTF8.self))
            i += 1 + l
        }
        guard i + 4 <= q.count else { return nil }
        return Question(name: labels.joined(separator: "."), type: q.be16(at: i), end: i + 4)
    }

    /// 返事を作る（問い合わせの先頭 questionEnd バイトを写し、A レコードを並べる）
    static func reply(to q: [UInt8], questionEnd: Int, rcode: UInt8, answers: [[UInt8]]) -> [UInt8] {
        var r = Array(q[0..<min(questionEnd, q.count)])
        r[2] = 0x81                                    // QR=1・RD=1
        r[3] = 0x80 | rcode                            // RA=1
        r.setBE16(UInt16(answers.count), at: 6)
        for k in 8..<12 { r[k] = 0 }
        for a in answers {
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + a   // 名前は質問を指す・A・IN・60 秒・4 バイト
        }
        return r
    }
}

// ======================================================================
// MARK: - Packet.swift
// ======================================================================

// MARK: - パケットを組み立てる・読むための共通の部品
//
// ゲスト側（GuestStack・GuestTCP）とルーター側（UserNet）の両方が使う。
// 数はすべてネットワークの順（ビッグエンディアン）。IP アドレスは 4 バイト、MAC アドレスは 6 バイトの [UInt8]

/// この小さなネットワークの決まった値（QEMU の SLIRP と同じ）
enum Net {
    static let guestIP: [UInt8] = [10, 0, 2, 15]
    static let gateway: [UInt8] = [10, 0, 2, 2]
    static let dns: [UInt8] = [10, 0, 2, 3]
    static let zeroIP: [UInt8] = [0, 0, 0, 0]
    static let broadcastIP: [UInt8] = [255, 255, 255, 255]
    /// ゲスト（仮想 LAN カード）の MAC アドレス（QEMU と同じ）
    static let guestMAC: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
    /// ルーターの MAC アドレス
    static let routerMAC: [UInt8] = [0x52, 0x55, 0x0A, 0x00, 0x02, 0x02]
    static let zeroMAC: [UInt8] = [0, 0, 0, 0, 0, 0]
    static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    /// 10.0.2.x（ルーターが自分で答える範囲）
    static func isLocal(_ ip: [UInt8]) -> Bool { ip.count == 4 && ip[0] == 10 && ip[1] == 0 && ip[2] == 2 }
}

enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
}

enum IPProto {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

// MARK: バイト列の読み書き

extension Array where Element == UInt8 {
    func be16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(at i: Int) -> UInt32 { UInt32(be16(at: i)) << 16 | UInt32(be16(at: i + 2)) }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) { appendBE16(UInt16(v >> 16)); appendBE16(UInt16(v & 0xFFFF)) }
    mutating func setBE16(_ v: UInt16, at i: Int) { self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF) }
    mutating func setBE32(_ v: UInt32, at i: Int) { setBE16(UInt16(v >> 16), at: i); setBE16(UInt16(v & 0xFFFF), at: i + 2) }

    /// 10.0.2.15 の形
    var ipString: String { map { String($0) }.joined(separator: ".") }
    /// 52:54:00:12:34:56 の形
    var macString: String { map { String(format: "%02x", $0) }.joined(separator: ":") }
}

// MARK: 確認用の値（チェックサム）

enum Checksum {
    /// IP などで使う 16 ビットの 1 の補数の和
    static func internet(_ b: [UInt8], initial: UInt32 = 0) -> UInt16 {
        var s = initial
        var i = 0
        while i + 1 < b.count { s &+= UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { s &+= UInt32(b[i]) << 8 }
        while s >> 16 != 0 { s = (s & 0xFFFF) &+ (s >> 16) }
        return ~UInt16(s)
    }

    /// TCP / UDP 用（疑似ヘッダ込み）
    static func l4(proto: UInt8, src: [UInt8], dst: [UInt8], _ seg: [UInt8]) -> UInt16 {
        var s = UInt32(src.be16(at: 0)) &+ UInt32(src.be16(at: 2))
        s &+= UInt32(dst.be16(at: 0)) &+ UInt32(dst.be16(at: 2))
        s &+= UInt32(proto) &+ UInt32(seg.count)
        return internet(seg, initial: s)
    }
}

// MARK: イーサネット・ARP

enum Ethernet {
    static let headerSize = 14
    static func frame(dst: [UInt8], src: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var f = dst + src
        f.appendBE16(type)
        return f + payload
    }
}

/// 届いたイーサネットのフレームを読む（短すぎれば nil）
struct EthernetFrame {
    let raw: [UInt8]
    init?(_ f: [UInt8]) {
        guard f.count >= Ethernet.headerSize else { return nil }
        raw = f
    }
    var type: UInt16 { raw.be16(at: 12) }
    var src: [UInt8] { Array(raw[6..<12]) }
    /// ブロードキャスト・マルチキャストでない送り元か（送り元の先頭のバイトの一番下のビットが 0）
    var srcIsUnicast: Bool { raw[6] & 1 == 0 }
    var body: [UInt8] { Array(raw[Ethernet.headerSize...]) }
}

/// 届いた ARP を読む（イーサネット・IPv4 用。短すぎれば nil）
struct ARPPacket {
    let op: UInt16
    let senderMAC: [UInt8]
    let senderIP: [UInt8]
    let targetIP: [UInt8]
    init?(_ p: [UInt8]) {
        guard p.count >= 28 else { return nil }
        op = p.be16(at: 6)
        senderMAC = Array(p[8..<14])
        senderIP = Array(p[14..<18])
        targetIP = Array(p[24..<28])
    }
}

enum ARP {
    static let request: UInt16 = 1
    static let reply: UInt16 = 2
    /// ARP の中身（イーサネット・IPv4 用）
    static func packet(op: UInt16, senderMAC: [UInt8], senderIP: [UInt8], targetMAC: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        var a: [UInt8] = [0, 1, 8, 0, 6, 4]
        a.appendBE16(op)
        return a + senderMAC + senderIP + targetMAC + targetIP
    }
}

// MARK: IPv4

struct IPv4Packet {
    let proto: UInt8
    let src: [UInt8]
    let dst: [UInt8]
    let body: [UInt8]
    /// 分割されたもの（フラグメント）か
    let isFragment: Bool

    /// 読む（形が変なら nil）
    init?(_ p: [UInt8]) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 15) * 4
        let total = min(Int(p.be16(at: 2)), p.count)
        guard ihl >= 20, total >= ihl else { return nil }
        proto = p[9]
        src = Array(p[12..<16])
        dst = Array(p[16..<20])
        body = Array(p[ihl..<total])
        isFragment = p.be16(at: 6) & 0x3FFF != 0
    }

    /// 組み立てる（オプション無し・TTL 64）
    static func build(proto: UInt8, id: UInt16, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8]) -> [UInt8] {
        var h: [UInt8] = [0x45, 0]
        h.appendBE16(UInt16(20 + body.count))
        h.appendBE16(id)
        h += [dontFragment ? 0x40 : 0, 0, 64, proto, 0, 0]
        h += src + dst
        h.setBE16(Checksum.internet(h), at: 10)
        return h + body
    }
}

// MARK: UDP

struct UDPDatagram {
    let sport: UInt16
    let dport: UInt16
    let payload: [UInt8]

    init?(_ b: [UInt8]) {
        guard b.count >= 8 else { return nil }
        let len = min(Int(b.be16(at: 4)), b.count)
        guard len >= 8 else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        payload = Array(b[8..<len])
    }

    /// 組み立てる（チェックサム込み。0 になったら 0xFFFF にする決まり）
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var u: [UInt8] = []
        u.appendBE16(sport)
        u.appendBE16(dport)
        u.appendBE16(UInt16(8 + payload.count))
        u += [0, 0]
        u += payload
        let c = Checksum.l4(proto: IPProto.udp, src: src, dst: dst, u)
        u.setBE16(c == 0 ? 0xFFFF : c, at: 6)
        return u
    }
}

// MARK: TCP

struct TCPFlags: OptionSet {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 1)
    static let syn = TCPFlags(rawValue: 2)
    static let rst = TCPFlags(rawValue: 4)
    static let psh = TCPFlags(rawValue: 8)
    static let ack = TCPFlags(rawValue: 16)
}

struct TCPHeader {
    let sport: UInt16
    let dport: UInt16
    let seq: UInt32
    let ack: UInt32
    /// ヘッダの長さ（オプション込み）。中身はここから
    let headerLength: Int
    let flags: TCPFlags
    let window: UInt16

    init?(_ b: [UInt8]) {
        guard b.count >= 20 else { return nil }
        let off = Int(b[12] >> 4) * 4
        guard off >= 20, off <= b.count else { return nil }
        sport = b.be16(at: 0)
        dport = b.be16(at: 2)
        seq = b.be32(at: 4)
        ack = b.be32(at: 8)
        headerLength = off
        flags = TCPFlags(rawValue: b[13])
        window = b.be16(at: 14)
    }

    /// オプションの MSS（無ければ nil）
    static func mss(_ b: [UInt8], headerLength off: Int) -> Int? {
        var i = 20
        while i < off {
            let kind = b[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < off else { break }
            let l = Int(b[i + 1])
            if kind == 2, l == 4, i + 3 < off { return Int(b.be16(at: i + 2)) }
            i += max(2, l)
        }
        return nil
    }
}

enum TCPSegment {
    /// TCP のセグメントを組み立てる（チェックサム込み）。mss = true なら MSS 1460 のオプションを付ける
    static func build(src: [UInt8], dst: [UInt8], sport: UInt16, dport: UInt16, seq: UInt32, ack: UInt32,
                      flags: TCPFlags, window: UInt16 = 0xFFFF, mss: Bool = false,
                      payload: ArraySlice<UInt8> = []) -> [UInt8] {
        let hlen = mss ? 24 : 20
        var t: [UInt8] = []
        t.appendBE16(sport)
        t.appendBE16(dport)
        t.appendBE32(seq)
        t.appendBE32(ack)
        t += [UInt8(hlen / 4) << 4, flags.rawValue]
        t.appendBE16(window)
        t += [0, 0, 0, 0]                              // チェックサム・緊急ポインタ
        if mss { t += [2, 4, 0x05, 0xB4] }
        t += payload
        t.setBE16(Checksum.l4(proto: IPProto.tcp, src: src, dst: dst, t), at: 16)
        return t
    }
}

// MARK: DHCP

enum DHCP {
    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let ack: UInt8 = 5

    /// オプション（番号 → 中身）。240 バイト目から読む
    static func options(_ p: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 240
        while i + 1 < p.count {
            let code = p[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            let l = Int(p[i + 1])
            guard i + 2 + l <= p.count else { break }
            out[code] = Array(p[(i + 2)..<(i + 2 + l)])
            i += 2 + l
        }
        return out
    }
}

// ======================================================================
// MARK: - VNetMachine.swift
// ======================================================================

// MARK: - 全部をつなぐ
//
//  [ゲスト側]  HTTPPool（http・https）→ GuestStack → VirtioNetDriver
//                                         ↓ ↑（RAM の中のキューと、レジスタ）
//  [カード]                             VirtioNet
//                                         ↓ onTransmit      ↑ receive
//  [ルーター]                           UserNet（小さなルーター）→ iPad の通信 → インターネット
//
// ゲスト側とカードは queue の上で動く。ルーターは自分のキューで動き、フレームを渡すときだけ行き来する

final class VNetMachine: @unchecked Sendable {
    let queue = DispatchQueue(label: "vnet-guest")
    let ram = GuestRAM(megabytes: 4)
    let card: VirtioNet
    let driver: VirtioNetDriver
    let stack: GuestStack
    let router: UserNet
    let pool: HTTPPool
    /// ログ（どのスレッドからも呼ばれる）
    var log: (@Sendable (String) -> Void)?
    private var ready = false
    private var waiting: [() -> Void] = []
    /// 統計: カードを通ったフレームの数とバイト数
    private var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0

    init(factory: UserNetSocketFactory) {
        card = VirtioNet(memory: ram)
        driver = VirtioNetDriver(dev: card, ram: ram)
        stack = GuestStack(queue: queue)
        router = UserNet(factory: factory)
        pool = HTTPPool(stack: stack)
        // ゲスト → カード → ルーター
        stack.output = { [unowned self] f in self.driver.send(f) }
        card.onTransmit = { [unowned self] f in
            self.framesOut += 1; self.bytesOut += f.count
            self.router.input(f)
        }
        // ルーター → カード → ゲスト（カードとゲストは queue の上で触る）
        router.onFrame = { [weak self] f in
            guard let self else { return }
            self.queue.async {
                self.framesIn += 1; self.bytesIn += f.count
                self.card.receive(f)
                self.driver.poll()          // 割り込みを見て、届いたフレームを取り出す
            }
        }
        driver.onReceive = { [unowned self] f in self.stack.input(f) }
        stack.trace = { [weak self] s in self?.log?(s) }
        router.log = { [weak self] s in self?.log?(s) }
    }

    /// カードを準備して DHCP で IP アドレスをもらう
    func boot() {
        queue.async {
            do {
                try self.driver.start()
                self.stack.mac = self.driver.mac
                self.log?("カードの準備ができました（MAC \(self.driver.mac.macString)）")
            } catch {
                self.log?("カードを準備できません: \(error)")
                return
            }
            self.stack.start {
                self.ready = true
                let w = self.waiting
                self.waiting = []
                for f in w { f() }
            }
        }
    }

    /// 送って返事を受け取る（結果は done に、queue の上で返る）
    /// followRedirects: false なら 3xx もそのまま返す（移動はブラウザに任せる）
    func send(_ req: HTTPRequest, followRedirects: Bool = true, _ done: @escaping @Sendable (Result<HTTPResult, FetchError>) -> Void) {
        queue.async {
            let go = { self.pool.send(req, followRedirects: followRedirects) { r in done(r) } }
            if self.ready { go() } else { self.waiting.append(go) }
        }
    }

    /// ブラウザの User-Agent を使う
    func setUserAgent(_ ua: String) { queue.async { self.pool.userAgent = ua } }

    /// 守りの決まり（Cookie の写し・HSTS・LAN の保護）を渡す。pool は queue の上でしか触らない
    func configurePolicies(cookieJar: CookieJar, hsts: HSTSStore, localNetworkProtection: Bool) {
        queue.async {
            self.pool.cookieJar = cookieJar
            self.pool.hsts = hsts
            self.pool.localNetworkProtection = localNetworkProtection
            self.pool.policyLog = { [weak self] s in self?.log?(s) }
        }
    }

    /// 開発者向けの数字のスナップショット
    struct Stats: Sendable {
        var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0
        var pool = PoolStats()
        var droppedRx = 0
        var tcpRetransmits = 0
        /// 順番を飛ばして届き、取っておいたセグメント
        var tcpReordered = 0
        /// IP アドレスをもらえたか・もらった IP
        var ready = false
        var ip = ""

        var summary: String {
            "フレーム 送 \(framesOut)（\(bytesOut / 1024)KB）・受 \(framesIn)（\(bytesIn / 1024)KB）・接続 新 \(pool.opened) 使い回し \(pool.reused)"
                + "・使用中 \(pool.busy) 待ち \(pool.waiting)" + (pool.bufferedBytes > 0 ? "・読み途中 \(pool.bufferedBytes / 1024)KB" : "")
                + (droppedRx > 0 ? "・捨てたフレーム \(droppedRx)" : "") + (tcpRetransmits > 0 ? "・TCP 送り直し \(tcpRetransmits)" : "")
        }
    }

    /// 数字を queue の上で集めて、done に渡す（画面のスレッドから直接読むと、値を書き換えている途中とぶつかるため）
    func stats(_ done: @escaping @Sendable (Stats) -> Void) {
        queue.async {
            let s = Stats(framesOut: self.framesOut, framesIn: self.framesIn, bytesOut: self.bytesOut, bytesIn: self.bytesIn,
                          pool: self.pool.stats(), droppedRx: self.card.droppedRx, tcpRetransmits: self.stack.retransmits,
                          tcpReordered: self.stack.reordered,
                          ready: self.stack.ready, ip: self.stack.ready ? self.stack.ip.ipString : "")
            done(s)
        }
    }
}
