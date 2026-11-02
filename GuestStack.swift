import Foundation

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
        guard f.count >= Ethernet.headerSize else { return }
        let body = Array(f[Ethernet.headerSize...])
        switch f.be16(at: 12) {
        case EtherType.arp: handleARP(body)
        case EtherType.ipv4: handleIPv4(body)
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
        guard p.count >= 28 else { return }
        let op = p.be16(at: 6)
        let senderMAC = Array(p[8..<14]), senderIP = Array(p[14..<18]), target = Array(p[24..<28])
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
        if let r = requested { m += [50, 4] + r + [54, 4] + router }
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
