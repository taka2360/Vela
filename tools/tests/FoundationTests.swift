import Foundation

// MARK: - DevLog・JSONFile のテスト

struct SampleData: Codable, Equatable {
    var names: [String]
    var count: Int
}

func foundationTests() {
    print("DevLog")
    test("種類と重さの判定・差分の取り出し・上限") {
        let log = DevLog()
        log.add("🍪 送らない（a）")
        log.add("✕ https://x/：時間切れ")
        log.add("🛡 LAN の保護: 止めました")
        log.add("→ DNS example.com は？")
        let all = log.all()
        expectEqual(all.map { $0.category }, [.cookie, .net, .security, .vnet])
        expectEqual(all[1].level, .error)
        expectEqual(log.entries(after: all[1].id).count, 2)
        expect(log.take() != nil); expect(log.take() == nil, "変わっていなければ nil")
        for i in 0..<(DevLog.maxEntries + 10) { log.add("n\(i)", level: .debug, category: .app) }
        let after = log.all()
        expectEqual(after.count, DevLog.maxEntries)
        expectEqual(after.last?.message, "n\(DevLog.maxEntries + 9)")
        expect(after.first!.id < after.last!.id, "古い順")
        expect(log.export(minLevel: .error).isEmpty, "error はもう押し出された")
    }
    test("開発者パネルの日時（DevDate）") {
        let d = Date(timeIntervalSince1970: 1_793_700_000)   // 2026-11-03 10:00:00 UTC
        expectEqual(DevDate.dateTime(d, timeZone: TimeZone(identifier: "UTC")!), "2026-11-03 10:00")
        expectEqual(DevDate.dateTime(d, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-11-03 19:00")
        expectEqual(DevDate.dateTime(d, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "2026-11-03 02:00")
        expectEqual(DevDate.dateTime(d, timeZone: TimeZone(identifier: "UTC")!), "2026-11-03 10:00")   // 前の時間帯が残らない
    }
    test("消すと、重さごとの数も 0 に戻る") {
        let log = DevLog()
        log.add("w", level: .warning, category: .app)
        log.add("e", level: .error, category: .app)
        expectEqual(log.count(.warning), 1)
        log.clear()
        expectEqual(log.all().count, 0)
        expectEqual(log.count(.warning), 0)
        expectEqual(log.count(.error), 0)
        log.add("e2", level: .error, category: .app)
        expectEqual(log.count(.error), 1)
    }
    test("どのスレッドから書いても壊れない") {
        let log = DevLog()
        DispatchQueue.concurrentPerform(iterations: 8) { t in for i in 0..<500 { log.add("t\(t)-\(i)") } }
        expectEqual(log.all().count, 4000)
        expectEqual(Set(log.all().map { $0.id }).count, 4000)
    }

    print("JSONFile")
    test("保存（まとめて書く）・すぐ書く・読む・壊れたファイル") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = JSONFile<SampleData>(name: "s.json", directory: dir, delay: 0.1)
        expect(f.load() == nil)
        f.save(SampleData(names: ["a"], count: 1))
        f.save(SampleData(names: ["a", "b"], count: 2))
        Thread.sleep(forTimeInterval: 0.4)
        expectEqual(JSONFile<SampleData>(name: "s.json", directory: dir).load(), SampleData(names: ["a", "b"], count: 2))
        f.saveNow(SampleData(names: [], count: 3))
        expectEqual(f.load()?.count, 3)
        try? Data("{broken".utf8).write(to: f.url)
        expect(f.load() == nil)
        expect(FileManager.default.fileExists(atPath: f.url.path + ".broken"), "壊れたものは .broken に残す")
    }
}
