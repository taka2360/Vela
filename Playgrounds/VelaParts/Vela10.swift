// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 10 / 10。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

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

// ======================================================================
// MARK: - VNetCore.swift
// ======================================================================

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

// ======================================================================
// MARK: - VNetDriver.swift
// ======================================================================

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
        w32(R.guestPageSize, VirtioMMIO.defaultPageSize)
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
        let page = UInt64(VirtioMMIO.defaultPageSize)
        w32(R.queueAlign, VirtioMMIO.defaultPageSize)
        // 置き場所はカードと同じ決まりで、0 から数えた位置を出す（area はページの倍数なので、そのまま足せる）
        let l = VirtioQueueLayout(base: 0, num: UInt64(qsize), align: page)
        let area = ram.alloc(Int(l.usedEnd), align: page)
        var r = Ring(ram: ram, size: qsize)
        r.desc = area + l.desc
        r.avail = area + l.avail
        r.used = area + l.used
        r.bufs = (0..<qsize).map { _ in ram.alloc(bufSize, align: 64) }
        w32(R.queuePFN, UInt32(area / page))
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

// ======================================================================
// MARK: - UserNet.swift
// ======================================================================

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
        // xid・flags・chaddr は問い合わせのものをそのまま返す（p.count >= 240 は上で確かめた）
        let options: [(UInt8, [UInt8])] = [
            (DHCP.Opt.messageType, [reply]),
            (DHCP.Opt.serverID, Net.gateway),
            (DHCP.Opt.leaseTime, [0, 1, 0x51, 0x80]),           // 86400 秒
            (DHCP.Opt.subnetMask, [255, 255, 255, 0]),
            (DHCP.Opt.router, Net.gateway),
            (DHCP.Opt.dnsServer, Net.dns),
            (DHCP.Opt.mtu, [0x05, 0xDC]),                       // MTU 1500
        ]
        let r = DHCP.message(op: 2, xid: Array(p[4..<8]), flags: Array(p[10..<12]), yiaddr: Net.guestIP, siaddr: Net.gateway,
                             chaddr: Array(p[28..<44]), options: options)
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

// ======================================================================
// MARK: - UserNetApple.swift
// ======================================================================

#if canImport(Network)
import Foundation
import Network

// MARK: - UserNet の外への接続を、iPad の Network.framework で作る

final class NWUserNetFactory: UserNetSocketFactory, @unchecked Sendable {
    func tcp(host: String, port: UInt16, queue: DispatchQueue,
             onReady: @escaping @Sendable () -> Void, onData: @escaping @Sendable (Data) -> Void,
             onClose: @escaping @Sendable (Bool) -> Void) -> UserNetSocket {
        let opts = NWProtocolTCP.Options()
        opts.noDelay = true
        opts.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: opts)
        // iPad の「プロキシ」（iCloud プライベートリレーなど）を通さず、相手に直接つなぐ。
        // プロキシを通ると、暗号化していない http の要求がプロキシに読まれて「400 Bad Request」で断られることがある
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: params)
        let s = NWUserNetSocket(c, datagram: false, onData: onData, onClose: onClose)
        c.stateUpdateHandler = { [weak s] st in
            guard let s else { return }
            switch st {
            case .ready:
                if !s.readyCalled { s.readyCalled = true; onReady() }
            case .failed, .cancelled:
                s.closed(error: true)
            default:
                // .waiting（つながらない・ネットが無いなど）は、iPad が自分でやり直すので切らない
                // （connectionTimeout を過ぎると failed になる）
                break
            }
        }
        c.start(queue: queue)
        return s
    }

    func udp(host: String, port: UInt16, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) -> UserNetSocket {
        let params = NWParameters.udp
        params.preferNoProxies = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 53, using: params)
        let s = NWUserNetSocket(c, datagram: true, onData: onData, onClose: { _ in onClose() })
        c.stateUpdateHandler = { [weak s] st in
            switch st {
            case .failed, .cancelled: s?.closed(error: true)
            default: break
            }
        }
        c.start(queue: queue)
        return s
    }
}

final class NWUserNetSocket: UserNetSocket, @unchecked Sendable {
    let conn: NWConnection
    let datagram: Bool
    let onData: @Sendable (Data) -> Void
    let onClose: @Sendable (Bool) -> Void
    var readyCalled = false
    private var done = false

    init(_ c: NWConnection, datagram: Bool, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        conn = c; self.datagram = datagram; self.onData = onData; self.onClose = onClose
    }

    func closed(error: Bool) {
        if done { return }
        done = true
        conn.cancel()
        onClose(error)
    }

    func send(_ data: Data) {
        if done { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func finish() {
        if done || datagram { return }
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        if done { return }
        done = true
        conn.cancel()
    }

    func readMore() {
        if done { return }
        if datagram {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.done else { return }
                if let d = data, !d.isEmpty { self.onData(d) }
                if error != nil { self.closed(error: true); return }
                self.readMore()          // UDP は続けて受け取る
            }
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let d = data, !d.isEmpty {
                self.onData(d)
                if isComplete { self.closed(error: false) }
                return
            }
            if isComplete || error != nil { self.closed(error: error != nil) }
            else { self.readMore() }
        }
    }
}
#endif
