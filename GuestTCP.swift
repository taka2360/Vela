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
    private var sendBuf = Data()
    private var wantFIN = false, finSent = false, gotFIN = false
    private var peerWindow = 65535
    private let mss = 1460
    private var lastProgress = Date()
    private var retries = 0

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
            if h.seq == rcvNxt {
                rcvNxt &+= UInt32(payload.count)
                handler.data(Data(payload))
            }
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

    /// 時間で見る（送り直し）
    func tick(_ now: Date) {
        if now.timeIntervalSince(lastProgress) < 1 { return }
        if state == .synSent {
            retries += 1
            if retries > 8 { finish("つながりませんでした（時間切れ）"); return }
            sendSYN()
            lastProgress = now
        } else if state == .established && sndNxt != sndUna {
            retries += 1
            if retries > 12 { abort(); return }
            // 受け取りの返事が来ない: 先頭から送り直す
            sndNxt = sndUna
            finSent = false
            lastProgress = now
            pump()
        }
    }
}
