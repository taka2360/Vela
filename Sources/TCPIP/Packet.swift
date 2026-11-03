import Foundation

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

// MARK: 読み位置付きのバイトの列

/// 前から読んでいくバイトの列（UserNet の TCP の送り待ち・GuestTCP の送り待ち・TLS の受け取り待ちで使う）。
/// 先頭を消すと毎回全部ずらすことになって遅いので、読み位置（pos）で覚えて、ときどき詰める。
/// いつも 0 <= pos <= buf.count。読める並びは buf[pos...]。詰めるのは compact を呼んだときだけ（呼ぶ時点は使う側が決める）
struct ByteQueue {
    private(set) var buf: [UInt8] = []
    private(set) var pos = 0

    var count: Int { buf.count - pos }
    var isEmpty: Bool { pos >= buf.count }

    mutating func append<S: Sequence>(contentsOf s: S) where S.Element == UInt8 { buf.append(contentsOf: s) }

    /// 読める並びの at から count バイト（コピーしない）。0 <= at、0 <= count、at + count <= self.count であること
    func slice(at: Int, count n: Int) -> ArraySlice<UInt8> {
        precondition(at >= 0 && n >= 0 && at <= count && n <= count - at, "ByteQueue.slice の範囲外")
        return buf[(pos + at)..<(pos + at + n)]
    }

    /// 先頭の n バイト（足りなければある分だけ）
    func prefix(_ n: Int) -> ArraySlice<UInt8> { buf[pos..<(pos + min(max(n, 0), count))] }

    /// 先頭の n バイトを p に写す（読み位置は動かさない）。0 <= n <= count。p に n バイトの場所があるのは呼ぶ側の責任
    func copy(into p: UnsafeMutableRawPointer, count n: Int) {
        precondition(n >= 0 && n <= count, "ByteQueue.copy の範囲外")
        if n == 0 { return }
        buf.withUnsafeBytes { p.copyMemory(from: $0.baseAddress! + pos, byteCount: n) }
    }

    /// 先頭の n バイトを読んだことにする（n <= 0 なら何もしない。n <= count であること）。詰めはしない
    mutating func consume(_ n: Int) {
        guard n > 0 else { return }
        precondition(n <= count, "ByteQueue.consume の範囲外")
        pos += n
    }

    /// 詰める。空で resetWhenEmpty なら中身を消す（場所は取っておく）。そうでなく pos > above かつ pos * 2 > buf.count なら、読んだ所を消す
    mutating func compact(above: Int, resetWhenEmpty: Bool) {
        if resetWhenEmpty && pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        else if pos > above && pos * 2 > buf.count { buf.removeFirst(pos); pos = 0 }
    }
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

/// TCP の番号（32 ビットで一周する）の計算。GuestTCP と UserNet の同じ式
enum TCPSeq {
    /// ACK で新しく受け取ってもらえた量。`ack &- una` と `nxt &- una` を UInt32 のまま（符号なしで）比べ、
    /// 0 より大きく、送った分（inFlight）以下ならその量。そうでなければ nil
    static func acked(ack: UInt32, una: UInt32, nxt: UInt32) -> UInt32? {
        let a = ack &- una
        let inFlight = nxt &- una
        return a > 0 && a <= inFlight ? a : nil
    }

    /// x が y からいくつ先か（負なら前）。差がちょうど 2^31 のときは Int32.min（負）
    static func offset(_ x: UInt32, from y: UInt32) -> Int32 { Int32(bitPattern: x &- y) }

    /// seq から count バイト（データだけ。FIN の 1 は入れない）が、ちょうど rcvNxt で終わるか
    static func endsAt(seq: UInt32, count: Int, rcvNxt: UInt32) -> Bool { seq &+ UInt32(count) == rcvNxt }
}

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

/// よく使うポート番号
enum Port {
    static let dns: UInt16 = 53
    static let dhcpServer: UInt16 = 67
    static let dhcpClient: UInt16 = 68
}

enum DHCP {
    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    /// オプションの番号（RFC 2132）
    enum Opt {
        static let subnetMask: UInt8 = 1
        static let router: UInt8 = 3
        static let dnsServer: UInt8 = 6
        static let mtu: UInt8 = 26
        static let requestedIP: UInt8 = 50
        static let leaseTime: UInt8 = 51
        static let messageType: UInt8 = 53
        static let serverID: UInt8 = 54
        static let paramList: UInt8 = 55
        static let end: UInt8 = 255
    }
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
