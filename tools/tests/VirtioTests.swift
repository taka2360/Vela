import Foundation

// MARK: - virtio のキューの置き場所のテスト（今の動きを書き留めたもの）
// カードはレジスタ（guestPageSize・queueAlign・queueNum・queuePFN）で場所を決める。
// 送り出し用のキューに 1 つ並べて通知し、フレームが届くこと（desc・avail が合っている）と、
// used が思った場所に書かれること（used が合っている）を確かめる

final class TxBox: @unchecked Sendable { var frames: [[UInt8]] = [] }

func virtioTests() {
    print("Virtio")
    typealias R = VirtioMMIO.Reg

    /// 今の決まり: desc = pfn × ページ、avail = desc + 16n、used = (avail + 4 + 2n + 2) を align の倍数に切り上げ（絶対アドレス）
    func expectedUsed(pfn: UInt64, page: UInt64, n: UInt64, align: UInt64) -> UInt64 {
        let desc = pfn * page
        let availEnd = desc + 16 * n + 4 + 2 * n + 2
        return (availEnd + align - 1) / align * align
    }

    func check(num: UInt32, align: UInt32, page: UInt32, pfnOffset: UInt64, file: StaticString = #file, line: UInt = #line) {
        let ram = GuestRAM(megabytes: 4)
        let card = VirtioNet(memory: ram)
        let got = TxBox()
        card.onTransmit = { got.frames.append($0) }
        func w(_ r: UInt64, _ v: UInt32) { card.write(r, size: 4, value: UInt64(v)) }
        let n = UInt64(num == 0 ? VirtioNet.queueMax : num)
        let pfn = ram.base / UInt64(page) + pfnOffset
        w(R.status, VirtioMMIO.statusAcknowledge)
        if page != 4096 { w(R.guestPageSize, page) }
        w(R.queueSel, UInt32(VirtioMMIO.txQueue))
        if num != 0 { w(R.queueNum, num) }
        if align != 4096 { w(R.queueAlign, align) }
        w(R.queuePFN, UInt32(pfn))

        let desc = pfn * UInt64(page), avail = desc + 16 * n
        let buf = ram.base + 3 << 20
        let frame: [UInt8] = [UInt8](repeating: 0, count: VirtioMMIO.netHeaderSize) + [1, 2, 3, 4]
        for (i, b) in frame.enumerated() { ram.pointer(buf + UInt64(i)).storeBytes(of: b, as: UInt8.self) }
        ram.store64(desc, buf)
        ram.store32(desc + 8, UInt32(frame.count))
        ram.store16(desc + 12, 0)
        ram.store16(avail + 4, 0)             // 先頭の記述子 0
        ram.store16(avail + 2, 1)             // 1 つ並べた
        w(R.queueNotify, UInt32(VirtioMMIO.txQueue))

        expectEqual(got.frames, [[1, 2, 3, 4]], "num=\(num) align=\(align) page=\(page)", file: file, line: line)
        let used = expectedUsed(pfn: pfn, page: UInt64(page), n: n, align: UInt64(align))
        expectEqual(ram.load16(used + 2), 1, "used.idx num=\(num) align=\(align) page=\(page)", file: file, line: line)
        expectEqual(ram.load32(used + 4), 0, "used[0].id", file: file, line: line)
    }

    test("カード: キューの置き場所（num・align・ページの大きさを変えて）") {
        for num: UInt32 in [0, 8, 256] {
            for align: UInt32 in [4096, 64, 8192] {
                for page: UInt32 in [4096, 8192] {
                    check(num: num, align: align, page: page, pfnOffset: 2)
                }
            }
        }
        // align で割り切れない所から始まる（4096 のページ・8192 の align・奇数のページ番号）
        check(num: 8, align: 8192, page: 4096, pfnOffset: 3)
        check(num: 0, align: 8192, page: 4096, pfnOffset: 1)
    }

    test("VirtioQueueLayout（今の式と同じ値）") {
        for (base, n, align) in [(UInt64(0), UInt64(256), UInt64(4096)), (0x4000_3000, 8, 8192), (0x4000_1000, 256, 64), (0, 1, 1)] {
            let l = VirtioQueueLayout(base: base, num: n, align: align)
            expectEqual(l.desc, base)
            expectEqual(l.avail, base + 16 * n)
            expectEqual(l.used, (base + 16 * n + 4 + 2 * n + 2 + align - 1) / align * align)
            expectEqual(l.usedEnd, l.used + 4 + 8 * n + 2)
        }
        // ドライバの前の式（0 から数えた位置を 4096 で切り上げ）と同じ
        let n: UInt64 = 256
        let old = (16 * n + 4 + 2 * n + 2 + 4095) / 4096 * 4096
        expectEqual(VirtioQueueLayout(base: 0, num: n, align: 4096).used, old)
        expectEqual(VirtioQueueLayout(base: 0, num: n, align: 4096).usedEnd, old + 4 + 8 * n + 2)
    }

    test("ドライバ: カードを準備して、送ったフレームが出てくる") {
        let ram = GuestRAM(megabytes: 4)
        let card = VirtioNet(memory: ram)
        let got = TxBox()
        card.onTransmit = { got.frames.append($0) }
        let drv = VirtioNetDriver(dev: card, ram: ram)
        do { try drv.start() } catch { expect(false, "\(error)"); return }
        expectEqual(drv.mac, Net.guestMAC)
        // 1 つ目のキュー（rx）は RAM の先頭、ページ番号はそこから
        card.write(R.queueSel, size: 4, value: 0)
        expectEqual(card.read(R.queuePFN, size: 4), ram.base / 4096)
        for i in 0..<3 { drv.send([UInt8](repeating: UInt8(i), count: 60)) }
        expectEqual(got.frames.count, 3)
        expectEqual(got.frames.last, [UInt8](repeating: 2, count: 60))
    }
}
