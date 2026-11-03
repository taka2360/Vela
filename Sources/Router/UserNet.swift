import Foundation

// MARK: - アプリの中の小さなルーター（ユーザーモードの NAT。QEMU の「SLIRP」と同じ考え方）
//
// ゲストの eth0 から出たイーサネットのフレームを受け取り、中身の TCP / UDP を
// iPad の普通の通信（Network.framework）に置き換えて外に出す。返事はフレームに組み立て直してゲストに返す。
//
//   ゲスト 10.0.2.15 ── ルーター 10.0.2.2（＝このクラス）── iPad の通信 ── インターネット
//                        DNS は 10.0.2.3（iPad の名前解決を使う）
//
// ・ARP: 10.0.2.x を聞かれたら、自分の MAC で答える
// ・DHCP: 10.0.2.15 を配る（ルーター 10.0.2.2、DNS 10.0.2.3）
// ・DNS: A レコードは iPad で名前解決して答える。AAAA などは「無し」と答える（IPv4 だけ使う）
// ・TCP: ゲストとの TCP はここで終わらせ、外へは iPad の TCP 接続でつなぐ（中身だけ中継する）
// ・UDP: 宛先ごとに iPad の UDP 接続を作って中継する
// ・ping（ICMP）: 10.0.2.x にだけ答える（iPad のアプリは外へ ping を打てない）
// すべて queue（1 本の直列キュー）の上で動く。

/// 外への接続（TCP か UDP）。受け取りは readMore() を呼ぶたびに 1 回分ずつ届く
protocol UserNetSocket: AnyObject, Sendable {
    func send(_ data: Data)
    /// 送り終わったら閉じる（TCP の FIN）
    func finish()
    func close()
    func readMore()
}

/// 外への接続を作るもの（iPad では Network.framework）。
/// 呼び出し（onReady など）は必ず queue の上で行うこと
protocol UserNetSocketFactory {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (_ error: Bool) -> Void) -> UserNetSocket
    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket
}

final class UserNet: @unchecked Sendable {
    let queue = DispatchQueue(label: "usernet")
    let factory: UserNetSocketFactory
    /// ゲストへ送るフレーム（queue の上で呼ばれる）
    var onFrame: (([UInt8]) -> Void)?
    /// ログ
    var log: ((String) -> Void)?
    /// ゲストの MAC アドレス（届いたフレームから覚える）
    private var guestMAC = Net.guestMAC

    private var ipID: UInt16 = 1
    private var tcps: [TCPKey: TCPConn] = [:]
    private var udps: [UDPKey: UDPFlow] = [:]
    private var timer: DispatchSourceTimer?
    /// 名前を IPv4 にする方法（テストでは偽物に差し替える）。どのスレッドから呼ばれてもよいこと
    var resolver: @Sendable (String) -> [[UInt8]]? = { UserNet.resolveIPv4($0) }
    /// ゲストへの送り直しの回数（queue の上で数える。読むときは queue の上で）
    private(set) var retransmits = 0

    init(factory: UserNetSocketFactory) {
        self.factory = factory
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// ゲストから出たフレーム（どのスレッドからでもよい）
    func input(_ frame: [UInt8]) {
        queue.async { self.handleFrame(frame) }
    }

    // MARK: イーサネット

    private func handleFrame(_ f: [UInt8]) {
        guard let e = EthernetFrame(f) else { return }
        if e.srcIsUnicast { guestMAC = e.src }
        switch e.type {
        case EtherType.arp: handleARP(e.body)
        case EtherType.ipv4: handleIPv4(e.body)
        default: break        // IPv6 などは使わない
        }
    }

    private func sendEthernet(_ type: UInt16, _ payload: [UInt8], to dst: [UInt8]? = nil) {
        onFrame?(Ethernet.frame(dst: dst ?? guestMAC, src: Net.routerMAC, type: type, payload))
    }

    // MARK: ARP

    private func handleARP(_ p: [UInt8]) {
        guard let a = ARPPacket(p), a.op == ARP.request else { return }      // 問い合わせだけ
        let target = a.targetIP
        guard Net.isLocal(target), target != Net.guestIP else { return }
        let senderMAC = a.senderMAC, senderIP = a.senderIP
        let r = ARP.packet(op: ARP.reply, senderMAC: Net.routerMAC, senderIP: target, targetMAC: senderMAC, targetIP: senderIP)
        sendEthernet(EtherType.arp, r, to: senderMAC)
    }

    // MARK: IPv4

    private func handleIPv4(_ p: [UInt8]) {
        guard let pkt = IPv4Packet(p), !pkt.isFragment else { return }   // 分割されたものは扱わない（MTU 1500 なので普通は来ない）
        switch pkt.proto {
        case IPProto.icmp: handleICMP(src: pkt.src, dst: pkt.dst, pkt.body)
        case IPProto.tcp: handleTCP(dst: pkt.dst, pkt.body)
        case IPProto.udp: handleUDP(dst: pkt.dst, pkt.body)
        default: break
        }
    }

    private func sendIPv4(proto: UInt8, src: [UInt8], dst: [UInt8], dontFragment: Bool = true, _ body: [UInt8], to mac: [UInt8]? = nil) {
        let pkt = IPv4Packet.build(proto: proto, id: ipID, src: src, dst: dst, dontFragment: dontFragment, body)
        ipID &+= 1
        sendEthernet(EtherType.ipv4, pkt, to: mac)
    }

    /// ゲストが指定した宛先 IP を、iPad 側でつなぐ相手の名前にする（10.0.2.x・ループバック・マルチキャストはつながない）
    private func hostFor(_ ip: [UInt8]) -> String? {
        if Net.isLocal(ip) || ip[0] == 127 || ip[0] == 0 || ip[0] >= 224 { return nil }
        return ip.ipString
    }

    // MARK: ICMP（ping）

    private func handleICMP(src: [UInt8], dst: [UInt8], _ b: [UInt8]) {
        guard b.count >= 8, b[0] == 8, Net.isLocal(dst) else { return }    // echo request だけ
        var r = b
        r[0] = 0; r[2] = 0; r[3] = 0                                        // echo reply
        r.setBE16(Checksum.internet(r), at: 2)
        sendIPv4(proto: IPProto.icmp, src: dst, dst: src, r)
    }

    // MARK: UDP

    private struct UDPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }
    private final class UDPFlow: @unchecked Sendable {
        var sock: UserNetSocket?
        var last = Date()
    }

    private func sendUDP(src: [UInt8], sport: UInt16, dport: UInt16, _ payload: [UInt8]) {
        let u = UDPDatagram.build(src: src, dst: Net.guestIP, sport: sport, dport: dport, payload)
        sendIPv4(proto: IPProto.udp, src: src, dst: Net.guestIP, u)
    }

    private func handleUDP(dst: [UInt8], _ b: [UInt8]) {
        guard let d = UDPDatagram(b) else { return }
        if d.dport == Port.dhcpServer { handleDHCP(d.payload); return }
        if dst == Net.dns && d.dport == Port.dns { handleDNS(d.payload, sport: d.sport); return }
        guard let host = hostFor(dst) else { return }
        let sport = d.sport, dport = d.dport
        let key = UDPKey(sport: sport, dst: dst, dport: dport)
        let flow: UDPFlow
        if let f = udps[key] { flow = f } else {
            let f = UDPFlow()
            let sock = factory.udp(host: host, port: dport, queue: queue, onData: { [weak self, weak f] data in
                guard let self else { return }
                f?.last = Date()
                self.sendUDP(src: dst, sport: dport, dport: sport, Array(data))
            }, onClose: { [weak self] in self?.udps[key] = nil })
            f.sock = sock
            flow = f
            udps[key] = f
            sock.readMore()
        }
        flow.last = Date()
        flow.sock?.send(Data(d.payload))
    }

    // MARK: DHCP

    private func handleDHCP(_ p: [UInt8]) {
        guard p.count >= 240, p[0] == 1, Array(p[236..<240]) == DHCP.magicCookie else { return }
        let reply: UInt8
        switch DHCP.options(p)[DHCP.Opt.messageType]?.first ?? 0 {
        case DHCP.discover: reply = DHCP.offer
        case DHCP.request: reply = DHCP.ack
        default: return
        }
        var r = [UInt8](repeating: 0, count: 236)
        r[0] = 2; r[1] = 1; r[2] = 6
        r.replaceSubrange(4..<8, with: p[4..<8])           // xid
        r[10] = p[10]; r[11] = p[11]                       // flags
        r.replaceSubrange(16..<20, with: Net.guestIP)      // yiaddr
        r.replaceSubrange(20..<24, with: Net.gateway)      // siaddr
        r.replaceSubrange(28..<44, with: p[28..<44])       // chaddr
        r += DHCP.magicCookie
        r += [DHCP.Opt.messageType, 1, reply]
        r += [DHCP.Opt.serverID, 4] + Net.gateway
        r += [DHCP.Opt.leaseTime, 4, 0, 1, 0x51, 0x80]                     // 86400 秒
        r += [DHCP.Opt.subnetMask, 4, 255, 255, 255, 0]
        r += [DHCP.Opt.router, 4] + Net.gateway
        r += [DHCP.Opt.dnsServer, 4] + Net.dns
        r += [DHCP.Opt.mtu, 2, 0x05, 0xDC]                           // MTU 1500
        r += [DHCP.Opt.end]
        // ブロードキャストで返す（ゲストはまだ IP を持っていないので）
        let u = UDPDatagram.build(src: Net.gateway, dst: Net.broadcastIP, sport: Port.dhcpServer, dport: Port.dhcpClient, r)
        sendIPv4(proto: IPProto.udp, src: Net.gateway, dst: Net.broadcastIP, dontFragment: false, u, to: Net.broadcastMAC)
        log?("[ネット] DHCP \(reply == DHCP.offer ? "OFFER" : "ACK") \(Net.guestIP.ipString)")
    }

    // MARK: DNS

    private func handleDNS(_ q: [UInt8], sport: UInt16) {
        guard q.count >= 12 else { return }
        guard q.be16(at: 4) == 1 else {                    // 質問が 1 つでなければ「できません」
            sendDNS(DNSMessage.reply(to: q, questionEnd: 12, rcode: 4, answers: []), sport: sport)
            return
        }
        guard let question = DNSMessage.question(q) else { return }
        if question.type != 1 || question.name.isEmpty {   // A 以外は「無し」
            sendDNS(DNSMessage.reply(to: q, questionEnd: question.end, rcode: 0, answers: []), sport: sport)
            return
        }
        let queue = self.queue
        let resolver = self.resolver
        DispatchQueue.global(qos: .userInitiated).async {
            let addrs = resolver(question.name)
            let r = DNSMessage.reply(to: q, questionEnd: question.end, rcode: addrs == nil ? 3 : 0, answers: addrs ?? [])
            queue.async { [weak self] in self?.sendDNS(r, sport: sport) }
        }
    }

    private func sendDNS(_ r: [UInt8], sport: UInt16) {
        sendUDP(src: Net.dns, sport: Port.dns, dport: sport, r)
    }

    /// 名前を IPv4 アドレスにする（nil = 見つからない）
    static func resolveIPv4(_ name: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if a.pointee.ai_family == AF_INET, let sa = a.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    let v = sin.pointee.sin_addr.s_addr       // ネットワークの順（ビッグエンディアン）のまま
                    let b: [UInt8] = [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                                      UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
                    if !out.contains(b) { out.append(b) }
                }
            }
            p = a.pointee.ai_next
        }
        return out.isEmpty ? nil : Array(out.prefix(8))
    }

    // MARK: TCP

    private struct TCPKey: Hashable, Sendable { let sport: UInt16; let dst: [UInt8]; let dport: UInt16 }

    private final class TCPConn: @unchecked Sendable {
        let key: TCPKey
        var sock: UserNetSocket?
        var state = State.connecting
        enum State { case connecting, synSent, established, closed }
        var rcvNxt: UInt32 = 0            // ゲストから次に来るはずの番号
        let iss: UInt32                   // こちらの最初の番号
        var sndUna: UInt32                // ゲストがまだ受け取ったと言っていない最初の番号
        var sndNxt: UInt32                // 次に送る番号
        /// 外から来た（まだ受け取りの返事が無い）データ。読める並びの先頭が sndUna
        var buf = ByteQueue()
        var pending: Int { buf.count }
        var window: UInt32 = 65535
        var mss = 536
        var remoteEOF = false             // 外の相手が閉じた
        var finSent = false
        var guestFIN = false
        var lastProgress = Date()
        var retries = 0
        var reading = false
        var lastActivity = Date()
        init(key: TCPKey) {
            self.key = key
            iss = UInt32.random(in: 0...UInt32.max)
            sndUna = iss
            sndNxt = iss
        }

        /// ゲストが受け取ったと言った分を buf から外す
        func dropAcked(_ n: Int) {
            guard n > 0 else { return }
            buf.consume(n)
            buf.compact(above: 131072, resetWhenEmpty: true)
        }
    }

    static let maxBuffered = 512 * 1024

    /// 外の相手のふりをして、ゲストへセグメントを送る
    private func sendTCP(_ c: TCPConn, _ flags: TCPFlags, seq: UInt32, payload: ArraySlice<UInt8> = [], mss: Bool = false) {
        // こちらの受け取り窓は 65535 のまま: 外へ送り切れていない分は気にしない（iPad の接続が受け取る）
        let seg = TCPSegment.build(src: c.key.dst, dst: Net.guestIP, sport: c.key.dport, dport: c.key.sport,
                                   seq: seq, ack: c.rcvNxt, flags: flags, mss: mss, payload: payload)
        sendIPv4(proto: IPProto.tcp, src: c.key.dst, dst: Net.guestIP, seg)
    }

    private func sendSYNACK(_ c: TCPConn) { sendTCP(c, [.syn, .ack], seq: c.iss, mss: true) }

    /// 外の相手のふりをして、ゲストへ RST を送る
    private func sendRST(remote: [UInt8], remotePort: UInt16, guestPort: UInt16, seq: UInt32, ack: UInt32) {
        let seg = TCPSegment.build(src: remote, dst: Net.guestIP, sport: remotePort, dport: guestPort,
                                   seq: seq, ack: ack, flags: [.rst, .ack], window: 0)
        sendIPv4(proto: IPProto.tcp, src: remote, dst: Net.guestIP, seg)
    }

    private func sendRST(_ c: TCPConn, seq: UInt32) {
        sendRST(remote: c.key.dst, remotePort: c.key.dport, guestPort: c.key.sport, seq: seq, ack: c.rcvNxt)
    }

    private func handleTCP(dst: [UInt8], _ b: [UInt8]) {
        guard let h = TCPHeader(b) else { return }
        let payload = b[h.headerLength...]
        let key = TCPKey(sport: h.sport, dst: dst, dport: h.dport)
        guard let c = tcps[key] else {
            open(key, h, b)
            return
        }

        c.lastActivity = Date()
        if h.flags.contains(.rst) { remove(c); return }
        if h.flags.contains(.syn) {
            // SYN の送り直し: SYN+ACK を送り直す
            if c.state == .synSent { sendSYNACK(c) }
            return
        }
        if h.flags.contains(.ack) {
            if let acked = TCPSeq.acked(ack: h.ack, una: c.sndUna, nxt: c.sndNxt) {
                var n = Int(acked)
                if c.state == .synSent { c.state = .established; n -= 1 }     // SYN の分
                c.dropAcked(min(n, c.pending))
                c.sndUna = h.ack
                c.lastProgress = Date()
                c.retries = 0
                readIfRoom(c)
            }
            c.window = UInt32(h.window)
        }
        if c.state == .synSent || c.state == .connecting { return }
        // データ
        var needAck = false
        if !payload.isEmpty {
            // 送り直しで前の分と重なっていたら、新しい所だけ外へ送る（先の分は捨てて、送り直してもらう）
            let before = TCPSeq.offset(c.rcvNxt, from: h.seq)
            if before >= 0 && Int(before) < payload.count {
                let rest = payload.dropFirst(Int(before))
                c.sock?.send(Data(rest))
                c.rcvNxt &+= UInt32(rest.count)
            }
            needAck = true
        }
        if h.flags.contains(.fin) && TCPSeq.endsAt(seq: h.seq, count: payload.count, rcvNxt: c.rcvNxt) && !c.guestFIN {
            c.guestFIN = true
            c.rcvNxt &+= 1
            c.sock?.finish()
            needAck = true
        }
        let before = c.sndNxt
        pump(c)
        if needAck && c.sndNxt == before { sendTCP(c, .ack, seq: c.sndNxt) }
        checkDone(c)
    }

    /// 知らない接続のセグメント: SYN なら外へつなぎに行く（つながったら SYN+ACK を返す）。ほかは RST で終わらせてもらう
    private func open(_ key: TCPKey, _ h: TCPHeader, _ b: [UInt8]) {
        if h.flags.contains(.rst) { return }
        guard h.flags.contains(.syn), !h.flags.contains(.ack), let host = hostFor(key.dst) else {
            let payloadCount = UInt32(b.count - h.headerLength)
            let extra: UInt32 = h.flags.isDisjoint(with: [.syn, .fin]) ? 0 : 1
            sendRST(remote: key.dst, remotePort: key.dport, guestPort: key.sport,
                    seq: h.flags.contains(.ack) ? h.ack : 0, ack: h.seq &+ payloadCount &+ extra)
            return
        }
        let c = TCPConn(key: key)
        c.rcvNxt = h.seq &+ 1
        c.window = UInt32(h.window)
        if let m = TCPHeader.mss(b, headerLength: h.headerLength) { c.mss = min(1460, m) }
        tcps[key] = c
        c.sock = factory.tcp(host: host, port: key.dport, queue: queue, onReady: { [weak self, weak c] in
            guard let self, let c, c.state == .connecting else { return }
            c.state = .synSent
            self.sendSYNACK(c)
            c.sndNxt = c.iss &+ 1
            c.lastProgress = Date()
            self.readIfRoom(c)
        }, onData: { [weak self, weak c] d in
            guard let self, let c else { return }
            c.reading = false
            c.buf.append(contentsOf: d)
            c.lastActivity = Date()
            self.pump(c)
            self.readIfRoom(c)
        }, onClose: { [weak self, weak c] error in
            guard let self, let c else { return }
            c.reading = false
            if c.state == .connecting || (error && c.state != .established) {
                // つながらなかった
                self.sendRST(c, seq: c.iss &+ 1)
                self.remove(c)
                return
            }
            c.remoteEOF = true
            self.pump(c)
        })
    }

    /// 外から来たデータを、ゲストの窓の分だけ送る。外が閉じていて全部送ったら FIN
    private func pump(_ c: TCPConn) {
        guard c.state == .established else { return }
        while !c.finSent {
            let sent = Int(c.sndNxt &- c.sndUna)
            let unsent = c.pending - sent
            if unsent <= 0 {
                if c.remoteEOF {
                    sendTCP(c, [.fin, .ack], seq: c.sndNxt)
                    c.sndNxt &+= 1
                    c.finSent = true
                    c.lastProgress = Date()
                }
                break
            }
            let room = Int(c.window) - sent
            if room <= 0 { break }
            let n = min(unsent, c.mss, room)
            sendTCP(c, [.ack, .psh], seq: c.sndNxt, payload: c.buf.slice(at: sent, count: n))
            c.sndNxt &+= UInt32(n)
        }
        checkDone(c)
    }

    private func readIfRoom(_ c: TCPConn) {
        guard !c.reading, !c.remoteEOF, c.state == .established || c.state == .synSent,
              c.pending < UserNet.maxBuffered, let s = c.sock else { return }
        c.reading = true
        s.readMore()
    }

    private func checkDone(_ c: TCPConn) {
        // 両方が閉じて、こちらの FIN も受け取ってもらえたら終わり
        if c.guestFIN && c.finSent && c.sndUna == c.sndNxt { remove(c) }
    }

    private func remove(_ c: TCPConn) {
        if c.state == .closed { return }
        c.state = .closed
        c.sock?.close()
        c.sock = nil
        if tcps[c.key] === c { tcps[c.key] = nil }
    }

    // MARK: 時間で見るもの（送り直しと、古い接続の片付け）

    private func tick() {
        let now = Date()
        for c in Array(tcps.values) {
            if c.state == .synSent && now.timeIntervalSince(c.lastProgress) > 1 {
                c.retries += 1
                if c.retries > 6 { remove(c); continue }
                sendSYNACK(c)
                c.lastProgress = now
            } else if c.state == .established && c.sndNxt == c.sndUna && c.window == 0 && c.pending > 0
                        && now.timeIntervalSince(c.lastProgress) > 1 {
                // ゲストの窓が 0 のまま（送っている途中のものは無い）: 1 バイトだけ送って、窓が開いたかを探る（持続タイマー）
                c.window = 1
                c.lastProgress = now
                pump(c)
            } else if c.state == .established && c.sndNxt != c.sndUna && now.timeIntervalSince(c.lastProgress) > 1 {
                // 受け取りの返事が来ない: 先頭から送り直す（窓が 0 で探っているだけのときは、回数に数えない）
                if c.window > 1 { c.retries += 1 }
                retransmits += 1
                if c.retries > 10 {
                    sendRST(c, seq: c.sndNxt)
                    remove(c); continue
                }
                c.sndNxt = c.sndUna
                c.finSent = false
                c.lastProgress = now
                if c.window == 0 { c.window = 1 }       // 窓が 0 のままなら 1 バイトだけ送って様子を見る
                pump(c)
            } else if now.timeIntervalSince(c.lastActivity) > 600 {
                remove(c)
            }
        }
        for (k, u) in udps where now.timeIntervalSince(u.last) > 60 {
            u.sock?.close()
            udps[k] = nil
        }
    }
}
