import Foundation

// MARK: - HSTS の記録のファイル（hsts.json）のテスト

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vela-hstsfile-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func hstsFileTests() {
    print("HSTS のファイル")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let top = RequestContext(topURL: url("https://a.test/"), isTopLevel: true)

    test("往復・読むとき期限切れを捨てる・形は [HSTSEntry] の JSON") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hsts.json")
        let st = HSTSStore(fileURL: f, now: now)
        st.record(header: "max-age=1000", url: url("https://a.test/"), ctx: top, now: now)
        st.record(header: "max-age=10; includeSubDomains", url: url("https://b.test/"), ctx: RequestContext(topURL: url("https://b.test/"), isTopLevel: true), now: now)
        st.saveNow()
        let list = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode([HSTSEntry].self, from: $0) } ?? []
        expectEqual(Set(list.map { $0.host }), ["a.test", "b.test"])
        let later = HSTSStore(fileURL: f, now: now.addingTimeInterval(100))
        expect(later.shouldUpgrade("a.test", now: now.addingTimeInterval(100)))
        expectEqual(later.all().map { $0.host }, ["a.test"], "期限切れの b.test は読むときに捨てる")
    }
    test("fileURL が nil なら何も書かない") {
        let st = HSTSStore(fileURL: nil, now: now)
        st.record(header: "max-age=1000", url: url("https://a.test/"), ctx: top, now: now)
        st.saveNow()
        expect(st.shouldUpgrade("a.test", now: now))
    }
    test("【変わる】壊れた hsts.json は .broken として残す（中身は元のまま・記録は 0 件）。前の .broken は置き換わる") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hsts.json"), broken = dir.appendingPathComponent("hsts.json.broken")
        let bad1 = Data("[{\"host\": 1".utf8)
        try? bad1.write(to: f)
        let st = HSTSStore(fileURL: f, now: now)
        expectEqual(st.all().count, 0, "記録（メモリの中）は 0 件")
        expect(!FileManager.default.fileExists(atPath: f.path), "hsts.json は無くなる")
        expectEqual(try? Data(contentsOf: broken), bad1, ".broken の中身は元の壊れたファイルとバイト単位で同じ")
        let bad2 = Data("not json".utf8)
        try? bad2.write(to: f)
        _ = HSTSStore(fileURL: f, now: now)
        expectEqual(try? Data(contentsOf: broken), bad2, "前の .broken は今回の壊れたファイルで置き換わる")
    }
    test("まとめて書く間に 2 回変える → 両方入る・【変わる】saveNow の後に予約の書き込みがもう一度書かない") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hsts.json")
        let st = HSTSStore(fileURL: f, now: now, saveDelay: 0.1)
        st.record(header: "max-age=1000", url: url("https://a.test/"), ctx: top, now: now)
        st.record(header: "max-age=1000", url: url("https://c.test/"), ctx: RequestContext(topURL: url("https://c.test/"), isTopLevel: true), now: now)
        Thread.sleep(forTimeInterval: 0.3)
        let list = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode([HSTSEntry].self, from: $0) } ?? []
        expectEqual(Set(list.map { $0.host }), ["a.test", "c.test"])
        // 変えてすぐ saveNow → 予約していた書き込みは済んだことになる（ファイルを消しても作り直されない）
        st.remove("c.test")
        st.saveNow()
        try? FileManager.default.removeItem(at: f)
        Thread.sleep(forTimeInterval: 0.3)
        expect(!FileManager.default.fileExists(atPath: f.path), "予約の書き込みが、もう一度書いた")
    }
    test("【変わる】書けないときはログに出す") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hsts.json")
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)     // 同じ名前のフォルダがあると書けない
        let st = HSTSStore(fileURL: f, now: now)
        final class Lines: @unchecked Sendable { let lock = NSLock(); var v: [String] = []; func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() } }
        let lines = Lines()
        st.log = { lines.add($0) }
        st.saveNow()
        expect(lines.v.contains { $0.hasPrefix("⚠️ hsts.json を書けません") }, "ログ: \(lines.v)")
    }
    test("saveNow は、何も変わっていなくても今の中身を書く") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hsts.json")
        let st = HSTSStore(fileURL: f, now: now)
        st.saveNow()
        expectEqual((try? Data(contentsOf: f)).map { String(decoding: $0, as: UTF8.self) }, "[]", "空でも書く")
        try? FileManager.default.removeItem(at: f)
        st.saveNow()
        expect(FileManager.default.fileExists(atPath: f.path), "もう一度書く")
    }
}
