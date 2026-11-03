import Foundation

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
    private var sendBuf = ByteQueue()
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
        sendBuf.append(contentsOf: d)
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
            send([.ack, .psh], payload: sendBuf.slice(at: inFlight, count: n))
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
            if let acked = TCPSeq.acked(ack: h.ack, una: sndUna, nxt: sndNxt) {
                var n = Int(acked)
                if finSent && h.ack == sndNxt { n -= 1 }        // FIN の分
                if n > 0 {
                    sendBuf.consume(min(n, sendBuf.count))
                    sendBuf.compact(above: 65536, resetWhenEmpty: true)
                }
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
        if h.flags.contains(.fin) && TCPSeq.endsAt(seq: h.seq, count: payload.count, rcvNxt: rcvNxt) && !gotFIN {
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
        let before = TCPSeq.offset(rcvNxt, from: seq)       // > 0: rcvNxt より前から始まる（送り直しの重なり）
        if before > 0 {
            if Int(before) >= data.count { return }         // 全部受け取り済み
            data.removeFirst(Int(before))
            seq = rcvNxt
        }
        if seq != rcvNxt {
            // 先の分: 窓の中で、置き場に余裕があれば取っておく
            let ahead = Int(TCPSeq.offset(seq, from: rcvNxt))
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
        while state != .closed, let (k, v) = ooo.first(where: { TCPSeq.offset(rcvNxt, from: $0.key) >= 0 }) {
            ooo[k] = nil
            oooBytes -= v.count
            let skip = Int(TCPSeq.offset(rcvNxt, from: k))
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
            send([.ack, .psh], payload: sendBuf.prefix(1))
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
