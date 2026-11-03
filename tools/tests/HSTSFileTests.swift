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
