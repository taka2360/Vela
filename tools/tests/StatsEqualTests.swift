import Foundation

// MARK: - VNet の数字の比べ方のテスト（同じ値なら画面に知らせない、のに使う）

func statsEqualTests() {
    print("Stats の比べ方")
    test("同じ数字なら等しい。どれか 1 つでも違えば等しくない（pool の中も見る）") {
        let a = VNetMachine.Stats()
        expect(a == VNetMachine.Stats())
        var b = a; b.framesIn = 1; expect(a != b, "framesIn")
        b = a; b.ready = true; expect(a != b, "ready")
        b = a; b.ip = "10.0.2.15"; expect(a != b, "ip")
        b = a; b.tcpReordered = 1; expect(a != b, "tcpReordered")
        b = a; b.pool.dnsCached = 1; expect(a != b, "pool.dnsCached")
        b = a; b.pool.bufferedBytes = 1; expect(a != b, "pool.bufferedBytes")
        let none: VNetMachine.Stats? = nil
        expect(none != a, "まだ無い（nil）と最初の数字は違う")
    }
}
