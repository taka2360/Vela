import Foundation

// MARK: - 実験用の「機械」の部品
//
// Android エミュレータと同じ virtio-net（仮想 LAN カード）を使う。
// 本物のエミュレータでは Linux（ゲスト）がこのカードを動かすが、この実験アプリでは
// ゲストの代わりに、Swift で書いた小さな「ドライバ」と「TCP/IP」（GuestStack）が動かす。
//
//   ブラウザ（WKWebView）→ HTTPPool → GuestStack（TCP/IP）→ VirtioNetDriver
//     → VirtioNet（仮想 LAN カード）→ UserNet（小さなルーター）→ iPad の通信

/// ゲストの RAM（virtio のキューと、フレームの入れ物を置く）。アドレスは 0x4000_0000 から
final class GuestRAM: @unchecked Sendable {
    let base: UInt64 = 0x4000_0000
    let size: UInt64
    private let words: UnsafeMutablePointer<UInt64>
    private var next: UInt64 = 0

    init(megabytes: Int) {
        size = UInt64(megabytes) << 20
        words = .allocate(capacity: Int(size / 8))
        words.initialize(repeating: 0, count: Int(size / 8))
    }
    deinit { words.deallocate() }

    /// 置き場所をもらう（align の倍数に揃える）。戻り値はゲストの物理アドレス
    func alloc(_ count: Int, align: UInt64 = 16) -> UInt64 {
        next = (next + align - 1) / align * align
        let a = base + next
        next += UInt64(count)
        precondition(next <= size, "GuestRAM が足りません")
        return a
    }

    /// ドライバ用（自分で置いた場所なので確かめない）
    func pointer(_ pa: UInt64) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(words) + Int(pa - base) }
    /// カード用（ゲストが書いたアドレスなので、RAM の中に収まるか確かめる）
    func pointer(_ pa: UInt64, count: Int) -> UnsafeMutableRawPointer? {
        let off = pa &- base
        guard pa >= base, off <= size, UInt64(count) <= size - off else { return nil }
        return UnsafeMutableRawPointer(words) + Int(off)
    }

    func load16(_ pa: UInt64) -> UInt16 { pointer(pa).loadUnaligned(as: UInt16.self) }
    func load32(_ pa: UInt64) -> UInt32 { pointer(pa).loadUnaligned(as: UInt32.self) }
    func store16(_ pa: UInt64, _ v: UInt16) { pointer(pa).storeBytes(of: v, as: UInt16.self) }
    func store32(_ pa: UInt64, _ v: UInt32) { pointer(pa).storeBytes(of: v, as: UInt32.self) }
    func store64(_ pa: UInt64, _ v: UInt64) { pointer(pa).storeBytes(of: v, as: UInt64.self) }
}

// MARK: - virtio-mmio の決まり（カードとドライバの両方が使う）

enum VirtioMMIO {
    /// レジスタの位置
    enum Reg {
        static let magic: UInt64 = 0x000
        static let version: UInt64 = 0x004
        static let deviceID: UInt64 = 0x008
        static let vendorID: UInt64 = 0x00C
        static let deviceFeatures: UInt64 = 0x010
        static let deviceFeaturesSel: UInt64 = 0x014
        static let driverFeatures: UInt64 = 0x020
        static let driverFeaturesSel: UInt64 = 0x024
        static let guestPageSize: UInt64 = 0x028          // legacy
        static let queueSel: UInt64 = 0x030
        static let queueNumMax: UInt64 = 0x034
        static let queueNum: UInt64 = 0x038
        static let queueAlign: UInt64 = 0x03C             // legacy
        static let queuePFN: UInt64 = 0x040               // legacy
        static let queueReady: UInt64 = 0x044
        static let queueNotify: UInt64 = 0x050
        static let interruptStatus: UInt64 = 0x060
        static let interruptACK: UInt64 = 0x064
        static let status: UInt64 = 0x070
        static let queueDescLow: UInt64 = 0x080
        static let queueDescHigh: UInt64 = 0x084
        static let queueAvailLow: UInt64 = 0x090
        static let queueAvailHigh: UInt64 = 0x094
        static let queueUsedLow: UInt64 = 0x0A0
        static let queueUsedHigh: UInt64 = 0x0A4
        static let config: UInt64 = 0x100                 // ここから先がカードごとの設定（ネットワークなら MAC アドレス）
    }
    static let magicValue: UInt32 = 0x7472_6976           // "virt"
    static let vendorQEMU: UInt32 = 0x554D_4551           // "QEMU"
    static let deviceNet: UInt32 = 1

    /// 状態（status）のビット
    static let statusAcknowledge: UInt32 = 1
    static let statusDriver: UInt32 = 2
    static let statusDriverOK: UInt32 = 4

    /// 機能のビット
    static let featureNetMAC: UInt64 = 1 << 5
    static let featureVersion1: UInt64 = 1 << 32

    /// 記述子の flags
    static let descNext: UInt16 = 1
    static let descWrite: UInt16 = 2

    /// キューの番号（ネットワーク）
    static let rxQueue = 0
    static let txQueue = 1

    /// virtio_net_hdr の大きさ（古い形 = legacy、MRG_RXBUF なし）
    static let netHeaderSize = 10

    /// ページの大きさ・キューの揃え方の既定値（古い形）
    static let defaultPageSize: UInt32 = 4096
}

/// 古い形（legacy）のキューの置き場所: 記述子表 (16 × n) → avail (4 + 2n + 2) → used (4 + 8n + 2)。
/// used は align の倍数（絶対アドレスで）に切り上げる。カードとドライバの両方が使う
struct VirtioQueueLayout {
    let desc: UInt64
    let avail: UInt64
    let used: UInt64
    /// used リングの終わり（ここまでが 1 本のキュー）
    let usedEnd: UInt64
    init(base: UInt64, num: UInt64, align: UInt64) {
        desc = base
        avail = base + 16 * num
        let availEnd = avail + 4 + 2 * num + 2
        used = (availEnd + align - 1) / align * align
        usedEnd = used + 4 + 8 * num + 2
    }
}

// MARK: - virtio-mmio のネットワーク（Linux では eth0 になる）
//
// キューは 2 つ: 0 = 受け取り用（OS が空の入れ物を並べておく）、1 = 送り出し用。
// 1 つの入れ物 = [virtio_net_hdr 10 バイト] [イーサネットのフレーム]
// 送り出されたフレームは onTransmit に渡す。外から届いたフレームは receive(_:) で受け取り、
// OS が並べた入れ物に書き込む（入れ物が無ければ、来るまで取っておく）。
// receive はほかのスレッドから呼んでもよい（鍵で守る）。入れ物に書くのは CPU の側（interruptLine を見るとき）
final class VirtioNet: @unchecked Sendable {
    let legacy: Bool
    let mac = Net.guestMAC
    /// OS が送り出したフレーム（ヘッダを除いたイーサネットのフレーム）
    var onTransmit: (([UInt8]) -> Void)?

    static let queueMax: UInt32 = 256
    static let maxPending = 512

    private let ram: GuestRAM

    private struct Queue {
        var num: UInt32 = 0
        var ready: UInt32 = 0
        var desc: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var lastAvail: UInt16 = 0
        var align: UInt32 = VirtioMMIO.defaultPageSize
        var pfn: UInt32 = 0
        /// 入れ物の数（ドライバが決めていなければ最大）
        var size: UInt16 { UInt16(num == 0 ? VirtioNet.queueMax : num) }
    }
    private var queues = [Queue(), Queue()]
    private var status: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var queueSel: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var guestPageSize: UInt32 = VirtioMMIO.defaultPageSize

    /// まだ OS に渡していない受け取ったフレーム
    private var pending: [[UInt8]] = []
    /// RX キューがいっぱいで捨てたフレームの数（lock で守る）
    private var dropped = 0
    var droppedRx: Int { lock.lock(); defer { lock.unlock() }; return dropped }
    private let lock = NSLock()
    private var hasPending = false

    init(memory: GuestRAM, legacy: Bool = true) {
        ram = memory
        self.legacy = legacy
    }

    var interruptLine: Bool {
        if hasPending { deliverPending() }
        return interruptStatus != 0
    }

    /// 外から届いたフレームを受け取る（どのスレッドからでもよい）
    func receive(_ frame: [UInt8]) {
        lock.lock()
        if pending.count >= VirtioNet.maxPending { pending.removeFirst(); dropped += 1 }
        pending.append(frame)
        hasPending = true
        lock.unlock()
    }

    /// 持っている機能: MAC。バージョン 2 なら VERSION_1 も
    private var deviceFeatures: UInt64 { (legacy ? 0 : VirtioMMIO.featureVersion1) | VirtioMMIO.featureNetMAC }

    private func reset() {
        status = 0
        deviceFeaturesSel = 0
        driverFeaturesSel = 0
        driverFeatures = 0
        queueSel = 0
        interruptStatus = 0
        guestPageSize = VirtioMMIO.defaultPageSize
        queues = [Queue(), Queue()]
    }

    // MARK: レジスタ

    func read(_ offset: UInt64, size width: Int) -> UInt64 {
        typealias R = VirtioMMIO.Reg
        if offset >= R.config {
            // 設定領域: 先頭 6 バイトが MAC アドレス
            var r: UInt64 = 0
            for k in 0..<width {
                let i = Int(offset - R.config) + k
                if i < mac.count { r |= UInt64(mac[i]) << UInt64(8 * k) }
            }
            return r
        }
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.magic: return UInt64(VirtioMMIO.magicValue)
        case R.version: return legacy ? 1 : 2
        case R.deviceID: return UInt64(VirtioMMIO.deviceNet)
        case R.vendorID: return UInt64(VirtioMMIO.vendorQEMU)
        case R.deviceFeatures: return deviceFeaturesSel < 2 ? (deviceFeatures >> UInt64(32 * deviceFeaturesSel)) & 0xFFFF_FFFF : 0
        case R.queueNumMax: return ok ? UInt64(VirtioNet.queueMax) : 0
        case R.queuePFN: return legacy && ok ? UInt64(queues[qs].pfn) : 0
        case R.queueReady: return ok ? UInt64(queues[qs].ready) : 0
        case R.interruptStatus: return UInt64(interruptStatus)
        case R.status: return UInt64(status)
        default: return 0
        }
    }

    func write(_ offset: UInt64, size width: Int, value: UInt64) {
        typealias R = VirtioMMIO.Reg
        let v = UInt32(truncatingIfNeeded: value)
        let qs = Int(queueSel)
        let ok = qs < queues.count
        switch offset {
        case R.deviceFeaturesSel: deviceFeaturesSel = v
        case R.driverFeatures:
            if driverFeaturesSel < 2 {
                let shift = UInt64(32 * driverFeaturesSel)
                driverFeatures = (driverFeatures & ~(0xFFFF_FFFF << shift)) | (UInt64(v) << shift)
            }
        case R.driverFeaturesSel: driverFeaturesSel = v
        case R.guestPageSize: if legacy { guestPageSize = v == 0 ? VirtioMMIO.defaultPageSize : v }
        case R.queueSel: queueSel = v
        case R.queueNum: if ok { queues[qs].num = min(v, VirtioNet.queueMax) }
        case R.queueAlign: if legacy && ok { queues[qs].align = v == 0 ? VirtioMMIO.defaultPageSize : v }
        case R.queuePFN: if legacy && ok { setLegacyQueue(qs, pfn: v) }
        case R.queueReady: if ok { queues[qs].ready = v & 1 }
        case R.queueNotify:
            if v == UInt32(VirtioMMIO.txQueue) { transmit() } else if v == UInt32(VirtioMMIO.rxQueue) { deliverPending() }
        case R.interruptACK: interruptStatus &= ~v
        case R.status: if v == 0 { reset() } else { status = v }
        case R.queueDescLow: if ok { queues[qs].desc = setLow(queues[qs].desc, v) }
        case R.queueDescHigh: if ok { queues[qs].desc = setHigh(queues[qs].desc, v) }
        case R.queueAvailLow: if ok { queues[qs].avail = setLow(queues[qs].avail, v) }
        case R.queueAvailHigh: if ok { queues[qs].avail = setHigh(queues[qs].avail, v) }
        case R.queueUsedLow: if ok { queues[qs].used = setLow(queues[qs].used, v) }
        case R.queueUsedHigh: if ok { queues[qs].used = setHigh(queues[qs].used, v) }
        default: break
        }
    }

    /// 古い形: ページ番号（PFN）から、記述子表・avail・used の場所を決める
    private func setLegacyQueue(_ i: Int, pfn: UInt32) {
        queues[i].pfn = pfn
        if pfn == 0 { queues[i].ready = 0; queues[i].lastAvail = 0; return }
        let l = VirtioQueueLayout(base: UInt64(pfn) * UInt64(guestPageSize), num: UInt64(queues[i].size),
                                  align: UInt64(queues[i].align))
        queues[i].desc = l.desc
        queues[i].avail = l.avail
        queues[i].used = l.used
        queues[i].lastAvail = 0
        queues[i].ready = 1
    }

    private func setLow(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF_0000_0000) | UInt64(v) }
    private func setHigh(_ x: UInt64, _ v: UInt32) -> UInt64 { (x & 0xFFFF_FFFF) | (UInt64(v) << 32) }

    // MARK: キュー（RAM はゲストが書いた場所なので、確かめながら読み書きする）

    private func load16(_ pa: UInt64) -> UInt16 { ram.pointer(pa, count: 2)?.loadUnaligned(as: UInt16.self) ?? 0 }
    private func load32(_ pa: UInt64) -> UInt32 { ram.pointer(pa, count: 4)?.loadUnaligned(as: UInt32.self) ?? 0 }
    private func load64(_ pa: UInt64) -> UInt64 { ram.pointer(pa, count: 8)?.loadUnaligned(as: UInt64.self) ?? 0 }
    private func store16(_ pa: UInt64, _ v: UInt16) { ram.pointer(pa, count: 2)?.storeBytes(of: v, as: UInt16.self) }
    private func store32(_ pa: UInt64, _ v: UInt32) { ram.pointer(pa, count: 4)?.storeBytes(of: v, as: UInt32.self) }

    /// ドライバが並べた番号（avail.idx）
    private func availIdx(_ q: Queue) -> UInt16 { load16(q.avail + 2) }
    /// 次に取り出す入れ物の先頭の記述子
    private func nextAvailHead(_ q: Queue) -> UInt16 { load16(q.avail + 4 + 2 * UInt64(q.lastAvail % q.size)) }

    /// 記述子のつながり: (アドレス, 長さ, 書き込み用か)
    private func chain(_ q: Queue, head: UInt16) -> [(addr: UInt64, len: Int, writable: Bool)] {
        var out: [(addr: UInt64, len: Int, writable: Bool)] = []
        var i = head
        let num = q.size
        for _ in 0..<Int(num) {
            let d = q.desc + 16 * UInt64(i % num)
            let flags = load16(d + 12)
            out.append((load64(d), Int(load32(d + 8)), flags & VirtioMMIO.descWrite != 0))
            if flags & VirtioMMIO.descNext == 0 { break }
            i = load16(d + 14)
        }
        return out
    }

    /// 使い終わった入れ物を used リングに返す
    private func pushUsed(_ q: Queue, head: UInt16, len: Int) {
        let usedIdx = load16(q.used + 2)
        let slot = q.used + 4 + 8 * UInt64(usedIdx % q.size)
        store32(slot, UInt32(head))
        store32(slot + 4, UInt32(len))
        store16(q.used + 2, usedIdx &+ 1)
    }

    /// 送り出し用のキューに並んだフレームを取り出して onTransmit に渡す
    private func transmit() {
        let qi = VirtioMMIO.txQueue
        guard queues[qi].ready != 0 else { return }
        let end = availIdx(queues[qi])
        var did = false
        var guardCount = 0
        while queues[qi].lastAvail != end && guardCount < Int(queues[qi].size) * 2 {
            guardCount += 1
            let head = nextAvailHead(queues[qi])
            var bytes: [UInt8] = []
            for d in chain(queues[qi], head: head) where !d.writable {
                guard d.len > 0, d.len <= 65536, let p = ram.pointer(d.addr, count: d.len) else { continue }
                bytes.append(contentsOf: UnsafeRawBufferPointer(start: p, count: d.len))
            }
            if bytes.count > VirtioMMIO.netHeaderSize {
                onTransmit?(Array(bytes[VirtioMMIO.netHeaderSize...]))
            }
            pushUsed(queues[qi], head: head, len: 0)
            queues[qi].lastAvail &+= 1
            did = true
        }
        if did { interruptStatus |= 1 }
    }

    /// 取っておいたフレームを、OS が並べた受け取り用の入れ物に書く
    private func deliverPending() {
        let qi = VirtioMMIO.rxQueue
        guard queues[qi].ready != 0 else { return }
        var did = false
        lock.lock()
        while !pending.isEmpty {
            if queues[qi].lastAvail == availIdx(queues[qi]) { break }       // 入れ物が無い: あとで
            let head = nextAvailHead(queues[qi])
            // ヘッダ（10 バイトの 0）+ フレームを、入れ物の記述子に順に詰める
            let full = [UInt8](repeating: 0, count: VirtioMMIO.netHeaderSize) + pending.removeFirst()
            var written = 0
            for d in chain(queues[qi], head: head) where d.writable {
                if written >= full.count { break }
                let n = min(d.len, full.count - written)
                guard n > 0, let p = ram.pointer(d.addr, count: n) else { continue }
                full.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress! + written, byteCount: n) }
                written += n
            }
            pushUsed(queues[qi], head: head, len: written)
            queues[qi].lastAvail &+= 1
            did = true
        }
        hasPending = !pending.isEmpty
        lock.unlock()
        if did { interruptStatus |= 1 }
    }
}
