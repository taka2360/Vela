import Foundation

// MARK: - 名前を引いた結果を覚えておく所（HTTPPool の DNS の覚え）のテスト

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ k: String) { lock.lock(); counts[k, default: 0] += 1; lock.unlock() }
    func get(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[k] ?? 0 }
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
