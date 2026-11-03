import Foundation

// MARK: - ARP・DHCP・チェックサム・DNS の形のテスト（今の動きを書き留めたもの）
// GuestStack と UserNet は役割が違うので、それぞれの決まりどおりの返事かを別々に調べる

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [[UInt8]] = []
    func add(_ f: [UInt8]) { lock.lock(); _frames.append(f); lock.unlock() }
    func take() -> [[UInt8]] { lock.lock(); defer { _frames = []; lock.unlock() }; return _frames }
}

/// フレームから UDP の中身（DHCP など）を取り出す
private func udpPayload(_ f: [UInt8]) -> (sport: UInt16, dport: UInt16, ipSrc: [UInt8], ipDst: [UInt8], payload: [UInt8])? {
    guard f.count >= Ethernet.headerSize, f.be16(at: 12) == EtherType.ipv4,
          let ip = IPv4Packet(Array(f[Ethernet.headerSize...])), ip.proto == IPProto.udp,
          let u = UDPDatagram(ip.body) else { return nil }
    return (u.sport, u.dport, ip.src, ip.dst, u.payload)
}

/// 配列を + でつなぐと型チェックがとても遅いので、これでつなぐ
private func bytes(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

private func arpFrame(op: UInt16, srcMAC: [UInt8], senderIP: [UInt8], targetIP: [UInt8], dst: [UInt8] = Net.broadcastMAC) -> [UInt8] {
    Ethernet.frame(dst: dst, src: srcMAC, type: EtherType.arp,
                   ARP.packet(op: op, senderMAC: srcMAC, senderIP: senderIP, targetMAC: Net.zeroMAC, targetIP: targetIP))
}

func packetTests() {
    print("Packet")

    test("チェックサム（RFC 1071 の例・奇数の長さ）") {
        // RFC 1071 の例: 00 01 f2 03 f4 f5 f6 f7 → 和 0xddf2 → 補数 0x220d
        expectEqual(Checksum.internet([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]), 0x220d)
        expectEqual(Checksum.internet([0xff]), 0x00ff)
        expectEqual(Checksum.internet([]), 0xffff)
        let ip = IPv4Packet.build(proto: IPProto.udp, id: 7, src: Net.guestIP, dst: Net.dns, [1, 2, 3])
        expectEqual(Checksum.internet(Array(ip[0..<20])), 0)       // 正しいヘッダーは 0 になる
    }

    test("TCPSeq: acked（符号なしで比べる・一周をまたぐ）") {
        // una=0xFFFFFFF0, nxt=0x10 → 送った分 0x20
        expect(TCPSeq.acked(ack: 0xFFFF_FFF0, una: 0xFFFF_FFF0, nxt: 0x10) == nil, "0 は進んでいない")
        expectEqual(TCPSeq.acked(ack: 0xFFFF_FFF1, una: 0xFFFF_FFF0, nxt: 0x10), 1)
        expectEqual(TCPSeq.acked(ack: 0x10, una: 0xFFFF_FFF0, nxt: 0x10), 0x20)
        expect(TCPSeq.acked(ack: 0x11, una: 0xFFFF_FFF0, nxt: 0x10) == nil, "送った分より先")
        expect(TCPSeq.acked(ack: 0xFFFF_FFEF, una: 0xFFFF_FFF0, nxt: 0x10) == nil, "前の番号")
        expect(TCPSeq.acked(ack: 5, una: 5, nxt: 5) == nil, "送った分が 0")
        expect(TCPSeq.acked(ack: 6, una: 5, nxt: 5) == nil, "送った分が 0 なら何も進まない")
        // 送った分が 2^31 以上でも、符号なしのまま比べる
        expectEqual(TCPSeq.acked(ack: 0x8000_0000, una: 0, nxt: 0x9000_0000), 0x8000_0000)
        expectEqual(TCPSeq.acked(ack: 0x9000_0000, una: 0, nxt: 0x9000_0000), 0x9000_0000)
        expect(TCPSeq.acked(ack: 0x9000_0001, una: 0, nxt: 0x9000_0000) == nil)
    }
    test("TCPSeq: offset（Int32 の符号。差が 2^31 なら負）・endsAt") {
        expectEqual(TCPSeq.offset(10, from: 9), 1)
        expectEqual(TCPSeq.offset(9, from: 10), -1)
        expectEqual(TCPSeq.offset(7, from: 7), 0)
        expectEqual(TCPSeq.offset(0x7FFF_FFFF, from: 0), Int32.max)
        expectEqual(TCPSeq.offset(0x8000_0000, from: 0), Int32.min)
        expectEqual(TCPSeq.offset(0, from: 0x8000_0000), Int32.min)
        expectEqual(TCPSeq.offset(0x8000_0001, from: 0), Int32.min + 1)
        expectEqual(TCPSeq.offset(2, from: 0xFFFF_FFFE), 4)       // 一周をまたぐ
        expectEqual(TCPSeq.offset(0xFFFF_FFFE, from: 2), -4)
        expect(TCPSeq.endsAt(seq: 0xFFFF_FFFE, count: 4, rcvNxt: 2))
        expect(!TCPSeq.endsAt(seq: 0xFFFF_FFFE, count: 3, rcvNxt: 2))
        expect(TCPSeq.endsAt(seq: 9, count: 0, rcvNxt: 9), "データが無い FIN")
    }
    test("EthernetFrame・ARPPacket を読む") {
        let mac: [UInt8] = [2, 0, 0, 0, 0, 9]
        let f = arpFrame(op: ARP.request, srcMAC: mac, senderIP: [10, 0, 2, 9], targetIP: Net.dns)
        guard let e = EthernetFrame(f) else { expect(false, "nil"); return }
        expectEqual(e.type, EtherType.arp)
        expectEqual(e.src, mac)
        expect(e.srcIsUnicast)
        expectEqual(e.body.count, 28)
        guard let a = ARPPacket(e.body) else { expect(false, "nil"); return }
        expectEqual(a.op, ARP.request)
        expectEqual(a.senderMAC, mac)
        expectEqual(a.senderIP, [10, 0, 2, 9])
        expectEqual(a.targetIP, Net.dns)
        expect(EthernetFrame(Array(f.prefix(13))) == nil)
        expect(EthernetFrame(Array(f.prefix(14)))?.body == [])
        expect(ARPPacket(Array(e.body.prefix(27))) == nil)
        let multi = Ethernet.frame(dst: Net.broadcastMAC, src: [1, 0, 0, 0, 0, 1], type: EtherType.ipv4, [])
        expect(EthernetFrame(multi)?.srcIsUnicast == false)
    }

    test("DNS の問い合わせと返事") {
        let q = DNSMessage.query(name: "a.example.com", id: 0x1234)
        expectEqual(Array(q[0..<12]), [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        expectEqual(Array(q[12...]), [1, 97, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1])
        guard let qq = DNSMessage.question(q) else { expect(false, "question が nil"); return }
        expectEqual(qq.name, "a.example.com")
        expectEqual(qq.type, 1)
        let r = DNSMessage.reply(to: q, questionEnd: qq.end, rcode: 0, answers: [[93, 184, 216, 34]])
        expectEqual(DNSMessage.firstA(r), [93, 184, 216, 34])
        let nx = DNSMessage.reply(to: q, questionEnd: qq.end, rcode: 3, answers: [])
        expect(DNSMessage.firstA(nx) == nil)
    }

    test("GuestStack: DHCP で IP をもらい、自分宛ての ARP に答える") {
        let q = DispatchQueue(label: "test-guest")
        let g = GuestStack(queue: q)
        let out = FrameBox()
        var ready = false
        q.sync {
            g.output = { out.add($0) }
            g.start { ready = true }
        }
        // DISCOVER
        let d = out.take()
        expectEqual(d.count, 1)
        guard let disc = d.first, let u = udpPayload(disc) else { expect(false, "DISCOVER が無い"); return }
        expectEqual(Array(disc[0..<6]), Net.broadcastMAC)
        expectEqual(Array(disc[6..<12]), Net.guestMAC)
        expectEqual([u.sport, u.dport], [68, 67])
        expectEqual(u.ipSrc, Net.zeroIP)
        expectEqual(u.ipDst, Net.broadcastIP)
        let p = u.payload
        let xid = p.be32(at: 4)
        expect(xid != 0)
        var want = [UInt8](repeating: 0, count: 236)
        want[0] = 1; want[1] = 1; want[2] = 6
        want.setBE32(xid, at: 4)
        want[10] = 0x80
        want.replaceSubrange(28..<34, with: Net.guestMAC)
        want += bytes(DHCP.magicCookie, [53, 1, DHCP.discover, 55, 3, 1, 3, 6, 255])
        expectEqual(p, want)

        // OFFER（ルーターの形で作る）→ REQUEST
        func serverReply(_ type: UInt8) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 236)
            r[0] = 2; r[1] = 1; r[2] = 6
            r.setBE32(xid, at: 4)
            r.replaceSubrange(16..<20, with: Net.guestIP)
            r.replaceSubrange(28..<34, with: Net.guestMAC)
            r += bytes(DHCP.magicCookie, [53, 1, type, 54, 4], Net.gateway, [1, 4, 255, 255, 255, 0, 3, 4], Net.gateway)
            r += bytes([6, 4], Net.dns, [255])
            let udp = UDPDatagram.build(src: Net.gateway, dst: Net.broadcastIP, sport: 67, dport: 68, r)
            let ip = IPv4Packet.build(proto: IPProto.udp, id: 1, src: Net.gateway, dst: Net.broadcastIP, dontFragment: false, udp)
            return Ethernet.frame(dst: Net.broadcastMAC, src: Net.routerMAC, type: EtherType.ipv4, ip)
        }
        q.sync { g.input(serverReply(DHCP.offer)) }
        let rq = out.take()
        expectEqual(rq.count, 1)
        guard let req = rq.first, let ru = udpPayload(req) else { expect(false, "REQUEST が無い"); return }
        expectEqual(ru.payload.be32(at: 4), xid)
        expectEqual(Array(ru.payload[236...]),
                    bytes(DHCP.magicCookie, [53, 1, DHCP.request, 50, 4], Net.guestIP, [54, 4], Net.gateway, [55, 3, 1, 3, 6, 255]))
        // 違う xid の返事は無視する
        var other = serverReply(DHCP.ack)
        other[Ethernet.headerSize + 28 + 4] ^= 0xFF
        q.sync { g.input(other) }
        expect(!q.sync { g.ready })
        // ACK → 使えるようになる
        q.sync { g.input(serverReply(DHCP.ack)) }
        expect(q.sync { g.ready })
        expect(ready)
        expectEqual(q.sync { g.ip }, Net.guestIP)
        _ = out.take()

        // 自分宛ての ARP には答える
        let asker: [UInt8] = [2, 0, 0, 0, 0, 9], askerIP: [UInt8] = [10, 0, 2, 9]
        q.sync { g.input(arpFrame(op: ARP.request, srcMAC: asker, senderIP: askerIP, targetIP: Net.guestIP)) }
        let a = out.take()
        expectEqual(a, [Ethernet.frame(dst: asker, src: Net.guestMAC, type: EtherType.arp,
                                       ARP.packet(op: ARP.reply, senderMAC: Net.guestMAC, senderIP: Net.guestIP,
                                                  targetMAC: asker, targetIP: askerIP))])
        // ほかのアドレス宛て・短すぎるものには答えない
        q.sync { g.input(arpFrame(op: ARP.request, srcMAC: asker, senderIP: askerIP, targetIP: [10, 0, 2, 99])) }
        q.sync { g.input(Array(arpFrame(op: ARP.request, srcMAC: asker, senderIP: askerIP, targetIP: Net.guestIP).prefix(40))) }
        q.sync { g.input([1, 2, 3]) }
        expectEqual(out.take().count, 0)
    }

    test("UserNet: DHCP の OFFER・ACK と、LAN の代理 ARP") {
        let n = UserNet(factory: FakeNet())
        let out = FrameBox()
        n.queue.sync { n.onFrame = { out.add($0) } }
        func send(_ f: [UInt8]) { n.input(f); n.queue.sync {} }

        func clientMsg(_ type: UInt8, xid: UInt32) -> [UInt8] {
            var m = [UInt8](repeating: 0, count: 236)
            m[0] = 1; m[1] = 1; m[2] = 6
            m.setBE32(xid, at: 4)
            m[10] = 0x80
            m.replaceSubrange(28..<34, with: Net.guestMAC)
            m += bytes(DHCP.magicCookie, [53, 1, type, 255])
            let udp = UDPDatagram.build(src: Net.zeroIP, dst: Net.broadcastIP, sport: 68, dport: 67, m)
            let ip = IPv4Packet.build(proto: IPProto.udp, id: 1, src: Net.zeroIP, dst: Net.broadcastIP, udp)
            return Ethernet.frame(dst: Net.broadcastMAC, src: Net.guestMAC, type: EtherType.ipv4, ip)
        }
        func wantReply(_ type: UInt8, xid: UInt32) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 236)
            r[0] = 2; r[1] = 1; r[2] = 6
            r.setBE32(xid, at: 4)
            r[10] = 0x80
            r.replaceSubrange(16..<20, with: Net.guestIP)
            r.replaceSubrange(20..<24, with: Net.gateway)
            r.replaceSubrange(28..<34, with: Net.guestMAC)
            r += bytes(DHCP.magicCookie, [53, 1, type, 54, 4], Net.gateway, [51, 4, 0, 1, 0x51, 0x80, 1, 4, 255, 255, 255, 0, 3, 4], Net.gateway)
            r += bytes([6, 4], Net.dns, [26, 2, 0x05, 0xDC, 255])
            return r
        }
        for (ask, reply) in [(DHCP.discover, DHCP.offer), (DHCP.request, DHCP.ack)] {
            send(clientMsg(ask, xid: 0xA1B2C3D4))
            let f = out.take()
            expectEqual(f.count, 1)
            guard let fr = f.first, let u = udpPayload(fr) else { expect(false, "返事が無い"); continue }
            expectEqual(Array(fr[0..<6]), Net.broadcastMAC)
            expectEqual(Array(fr[6..<12]), Net.routerMAC)
            expectEqual([u.sport, u.dport], [67, 68])
            expectEqual(u.ipSrc, Net.gateway)
            expectEqual(u.ipDst, Net.broadcastIP)
            expectEqual(u.payload, wantReply(reply, xid: 0xA1B2C3D4))
        }
        // それ以外の種類（RELEASE = 7）には答えない
        send(clientMsg(7, xid: 1))
        expectEqual(out.take().count, 0)

        // 代理 ARP: LAN の中（ゲスト自身以外）なら、ルーターの MAC で答える
        send(arpFrame(op: ARP.request, srcMAC: Net.guestMAC, senderIP: Net.guestIP, targetIP: Net.dns))
        expectEqual(out.take(), [Ethernet.frame(dst: Net.guestMAC, src: Net.routerMAC, type: EtherType.arp,
                                                ARP.packet(op: ARP.reply, senderMAC: Net.routerMAC, senderIP: Net.dns,
                                                           targetMAC: Net.guestMAC, targetIP: Net.guestIP))])
        send(arpFrame(op: ARP.request, srcMAC: Net.guestMAC, senderIP: Net.guestIP, targetIP: Net.guestIP))
        send(arpFrame(op: ARP.request, srcMAC: Net.guestMAC, senderIP: Net.guestIP, targetIP: [8, 8, 8, 8]))
        send(arpFrame(op: ARP.reply, srcMAC: Net.guestMAC, senderIP: Net.guestIP, targetIP: Net.dns))
        send(Array(arpFrame(op: ARP.request, srcMAC: Net.guestMAC, senderIP: Net.guestIP, targetIP: Net.dns).prefix(41)))
        expectEqual(out.take().count, 0)
    }
}
