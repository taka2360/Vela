import Foundation

// MARK: - ゲスト側の virtio-net ドライバ（Linux の virtio_net ドライバの代わり）
//
// 仮想 LAN カード（VirtioNet）のレジスタを、Linux と同じ順番で読み書きして使えるようにする。
// ・キューは 2 つ: 0 = 受け取り用、1 = 送り出し用（古い形 = legacy の virtio-mmio）
// ・受け取り用には、あらかじめ空の入れ物（2KB）を並べておく。カードが届いたフレームを書いてくれる
// ・送るときは、入れ物に [ヘッダ 10 バイト][フレーム] を書いて、avail リングに並べて「通知」する
// すべて 1 本のキュー（VNetMachine.queue）の上で呼ぶこと
final class VirtioNetDriver: @unchecked Sendable {
    let dev: VirtioNet
    let ram: GuestRAM
    let qsize = 256
    let bufSize = 2048
    private(set) var mac: [UInt8] = []

    /// 1 本のキュー（記述子表・avail・used と、入れ物）
    private struct Ring {
        let ram: GuestRAM
        let size: Int
        var desc: UInt64 = 0, avail: UInt64 = 0, used: UInt64 = 0
        var bufs: [UInt64] = []
        var lastUsed: UInt16 = 0
        var availIdx: UInt16 = 0

        func writeDesc(_ i: Int, len: Int, writable: Bool) {
            let d = desc + 16 * UInt64(i)
            ram.store64(d, bufs[i])
            ram.store32(d + 8, UInt32(len))
            ram.store16(d + 12, writable ? VirtioMMIO.descWrite : 0)
            ram.store16(d + 14, 0)
        }

        /// 入れ物 i を avail リングに積む（カードに見せるのは publish で）
        mutating func offer(_ i: Int) {
            ram.store16(avail + 4 + 2 * UInt64(Int(availIdx) % size), UInt16(i))
            availIdx &+= 1
        }

        /// 積んだ分をカードに見せる
        func publish() { ram.store16(avail + 2, availIdx) }

        /// カードが使い終わった入れ物を 1 つ取る（無ければ nil）
        mutating func takeUsed() -> (id: Int, len: Int)? {
            guard lastUsed != ram.load16(used + 2) else { return nil }
            let slot = used + 4 + 8 * UInt64(Int(lastUsed) % size)
            lastUsed &+= 1
            return (Int(ram.load32(slot)), Int(ram.load32(slot + 4)))
        }
    }
    private var rx: Ring
    private var tx: Ring
    private var txFree: [Int] = []
    /// まだ入れ物が空かず送れていないフレーム
    private var txWaiting: [[UInt8]] = []

    /// 届いたフレーム（ヘッダを除いたイーサネットのフレーム）
    var onReceive: (([UInt8]) -> Void)?

    init(dev: VirtioNet, ram: GuestRAM) {
        self.dev = dev
        self.ram = ram
        rx = Ring(ram: ram, size: qsize)
        tx = Ring(ram: ram, size: qsize)
    }

    struct DriverError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    private func r32(_ off: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: dev.read(off, size: 4)) }
    private func w32(_ off: UInt64, _ v: UInt32) { dev.write(off, size: 4, value: UInt64(v)) }

    /// Linux の virtio_mmio + virtio_net と同じ手順でカードを準備する
    func start() throws {
        typealias R = VirtioMMIO.Reg
        guard r32(R.magic) == VirtioMMIO.magicValue else { throw DriverError("virtio の目印がありません") }
        guard r32(R.deviceID) == VirtioMMIO.deviceNet else { throw DriverError("ネットワークのカードではありません") }
        let ackDriver = VirtioMMIO.statusAcknowledge | VirtioMMIO.statusDriver
        w32(R.status, 0)                                   // リセット
        w32(R.status, VirtioMMIO.statusAcknowledge)        // 見つけた
        w32(R.status, ackDriver)                           // 使い方が分かる
        w32(R.deviceFeaturesSel, 0)
        let features = r32(R.deviceFeatures)
        w32(R.driverFeaturesSel, 0)
        w32(R.driverFeatures, features & UInt32(VirtioMMIO.featureNetMAC))   // MAC アドレスだけ使う
        w32(R.guestPageSize, 4096)
        mac = (0..<6).map { UInt8(truncatingIfNeeded: dev.read(R.config + UInt64($0), size: 1)) }
        rx = setupQueue(VirtioMMIO.rxQueue)
        tx = setupQueue(VirtioMMIO.txQueue)
        // 受け取り用: 空の入れ物を全部並べる
        for i in 0..<qsize {
            rx.writeDesc(i, len: bufSize, writable: true)
            rx.offer(i)
        }
        rx.publish()
        txFree = Array(0..<qsize)
        w32(R.status, ackDriver | VirtioMMIO.statusDriverOK)   // 使い始める
        w32(R.queueNotify, UInt32(VirtioMMIO.rxQueue))
    }

    /// キューを 1 つ用意する（古い形: ページ番号 = PFN で場所を伝える）
    private func setupQueue(_ q: Int) -> Ring {
        typealias R = VirtioMMIO.Reg
        w32(R.queueSel, UInt32(q))
        precondition(Int(r32(R.queueNumMax)) >= qsize)
        w32(R.queueNum, UInt32(qsize))
        w32(R.queueAlign, 4096)
        // 記述子表 (16 × n) + avail (4 + 2n + 2)、used は 4096 の倍数から (4 + 8n + 2)
        let n = UInt64(qsize)
        let availEnd = 16 * n + 4 + 2 * n + 2
        let usedOff = (availEnd + 4095) / 4096 * 4096
        let total = Int(usedOff + 4 + 8 * n + 2)
        let area = ram.alloc(total, align: 4096)
        var r = Ring(ram: ram, size: qsize)
        r.desc = area
        r.avail = area + 16 * n
        r.used = area + usedOff
        r.bufs = (0..<qsize).map { _ in ram.alloc(bufSize, align: 64) }
        w32(R.queuePFN, UInt32(area / 4096))
        return r
    }

    /// フレームを送る（入れ物が無ければ、空くまで待たせる）
    func send(_ frame: [UInt8]) {
        txWaiting.append(frame)
        reclaimTX()
        flushTX()
    }

    private func flushTX() {
        let hdr = VirtioMMIO.netHeaderSize
        var did = false
        while !txWaiting.isEmpty, let i = txFree.popLast() {
            let frame = txWaiting.removeFirst()
            let p = ram.pointer(tx.bufs[i])
            p.initializeMemory(as: UInt8.self, repeating: 0, count: hdr)
            let n = min(frame.count, bufSize - hdr)
            frame.withUnsafeBytes { (p + hdr).copyMemory(from: $0.baseAddress!, byteCount: n) }
            tx.writeDesc(i, len: hdr + n, writable: false)
            tx.offer(i)
            did = true
        }
        if did {
            tx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.txQueue))   // → カードが onTransmit に渡す
        }
    }

    /// 送り終わった入れ物を回収する
    private func reclaimTX() {
        while let u = tx.takeUsed() {
            if u.id < qsize { txFree.append(u.id) }
        }
    }

    /// 割り込みが来ていれば、届いたフレームを取り出す（カードから知らせがあったときに呼ぶ）
    func poll() {
        guard dev.interruptLine else { return }
        w32(VirtioMMIO.Reg.interruptACK, r32(VirtioMMIO.Reg.interruptStatus))   // 割り込みを受け取った
        reclaimTX()
        flushTX()
        let hdr = VirtioMMIO.netHeaderSize
        var reposted = false
        while let u = rx.takeUsed() {
            guard u.id < qsize else { continue }
            if u.len > hdr {
                let p = ram.pointer(rx.bufs[u.id]) + hdr
                onReceive?([UInt8](UnsafeRawBufferPointer(start: p, count: min(u.len, bufSize) - hdr)))
            }
            rx.offer(u.id)                                 // 入れ物を戻す
            reposted = true
        }
        if reposted {
            rx.publish()
            w32(VirtioMMIO.Reg.queueNotify, UInt32(VirtioMMIO.rxQueue))
        }
    }
}
