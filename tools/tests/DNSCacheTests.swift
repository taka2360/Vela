import Foundation

// MARK: - 名前を引いた結果を覚えておく所（HTTPPool の DNS の覚え）のテスト

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ k: String) { lock.lock(); counts[k, default: 0] += 1; lock.unlock() }
    func get(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[k] ?? 0 }
}

final class FakeClock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }

func dnsCacheUnitTests() {
    print("DNSCache")
    test("300 秒より前（<）なら使う・ちょうど 300 秒で使わない・消さない") {
        let clock = FakeClock()
        let c = DNSCache(now: { clock.t })
        expect(c.lookup("a.test") == nil)
        c.store("a.test", [1, 2, 3, 4])
        expectEqual(c.lookup("a.test"), [1, 2, 3, 4])
        clock.t = clock.t.addingTimeInterval(299.9)
        expectEqual(c.lookup("a.test"), [1, 2, 3, 4], "299.9 秒後")
        clock.t = clock.t.addingTimeInterval(0.1)
        expect(c.lookup("a.test") == nil, "ちょうど 300 秒")
        expectEqual(c.count, 1, "古くなっても消さない")
        c.store("a.test", [5, 6, 7, 8])
        expectEqual(c.lookup("a.test"), [5, 6, 7, 8], "覚え直すと、その時刻から 300 秒")
        c.store("1.2.3.4", [1, 2, 3, 4])
        expectEqual(c.count, 2)
        expectEqual(DNSCache.ttl, 300)
    }
}

/// 偽のサーバーで、DNS に何回問い合わせたかを数える（今の動きを書き留めたもの）
func dnsCacheNetTests() {
    print("DNS の覚え（偽のサーバー）")
    let net = FakeNet()
    net.serve("93.184.216.34:80") { _ in httpReply(200, "ok") }
    guard let (m, _, _) = makeMachine(net, names: [:]) else { return }
    let asked = Counter()
    let table: [String: [UInt8]] = ["site.test": [93, 184, 216, 34]]
    m.router.resolver = { name in asked.add(name); return table[name].map { [$0] } }
    test("2 回目は問い合わせない・見つからない名前は覚えない・数字のアドレスも覚える") {
        let before = statsOf(m)?.pool.dnsCached ?? -1
        _ = fetch(m, HTTPRequest(url: url("http://site.test/a")))
        _ = fetch(m, HTTPRequest(url: url("http://site.test/b")))
        expectEqual(asked.get("site.test"), 1, "2 回目は覚えたものを使う")
        expectEqual(statsOf(m)?.pool.dnsCached, before + 1)
        _ = fetch(m, HTTPRequest(url: url("http://nx.test/")))
        _ = fetch(m, HTTPRequest(url: url("http://nx.test/")))
        expectEqual(asked.get("nx.test"), 2, "見つからなかったものは覚えないので、もう一度問い合わせる")
        expectEqual(statsOf(m)?.pool.dnsCached, before + 1)
        _ = fetch(m, HTTPRequest(url: url("http://93.184.216.34/c")))
        expectEqual(asked.get("93.184.216.34"), 0, "数字のアドレスは問い合わせない")
        expectEqual(statsOf(m)?.pool.dnsCached, before + 2, "数字のアドレスも覚える")
    }
}
