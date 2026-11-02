import Foundation

// MARK: - ブックマーク・履歴・候補・文字の大きさのテスト

func libraryTests() {
    print("Library")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    test("同じページの判定") {
        expectEqual(LibraryKey.normalize("HTTPS://Example.COM/"), "https://example.com")
        expectEqual(LibraryKey.normalize("https://example.com/a#top"), "https://example.com/a")
        expect(LibraryKey.normalize("https://example.com/a") != LibraryKey.normalize("https://example.com/b"))
        expect(LibraryKey.isRecordable(URL(string: "https://a.com/x")!))
        expect(!LibraryKey.isRecordable(URL(string: "about:blank")!))
        expect(!LibraryKey.isRecordable(URL(string: "vnets://a.com/")!))
        expectEqual(LibraryKey.bare("https://www.Example.com/a"), "example.com/a")
    }
    test("ブックマーク: 足す・重ならない・外す・名前・並べ替え") {
        var b = BookmarkList()
        expect(b.add(title: " A ", url: "https://a.com/", now: t0))
        expect(!b.add(title: "A2", url: "https://A.com", now: t0))
        expect(b.add(title: "", url: "https://b.com/", now: t0))
        expectEqual(b.items.map { $0.title }, ["A", "https://b.com/"])
        let idB = b.items[1].id
        b.rename(id: idB, title: "B")
        b.rename(id: idB, title: "   ")
        expectEqual(b.items[1].title, "B")
        b.move(id: idB, by: -1)
        expectEqual(b.items.map { $0.title }, ["B", "A"])
        b.move(id: idB, by: -5)
        expectEqual(b.items.map { $0.title }, ["B", "A"])
        b.remove(url: "https://a.com#x")
        expectEqual(b.items.map { $0.title }, ["B"])
        expect(b.contains("https://b.com"))
    }
    test("履歴: 同じ URL は 1 つ・回数・新しい順・タイトル") {
        var h = HistoryLog()
        expect(h.record(url: URL(string: "https://a.com/")!, title: "A", at: t0))
        expect(h.record(url: URL(string: "https://b.com/")!, title: "B", at: t0 + 10))
        expect(h.record(url: URL(string: "https://a.com/#x")!, title: "", at: t0 + 20))
        expect(!h.record(url: URL(string: "about:blank")!, title: "", at: t0 + 30))
        expectEqual(h.entries.map { $0.title }, ["A", "B"])
        expectEqual(h.entries[0].visits, 2)
        h.updateTitle(url: URL(string: "https://b.com")!, title: "B2")
        expectEqual(h.entries[1].title, "B2")
        expectEqual(h.search("b2").count, 1)
        expectEqual(h.search("").count, 2)
        h.clear(since: t0 + 15)
        expectEqual(h.entries.map { $0.title }, ["B2"])
        h.clear(since: nil)
        expect(h.entries.isEmpty)
    }
    test("履歴: 上限") {
        var h = HistoryLog()
        for i in 0..<(HistoryLog.maxEntries + 5) {
            h.entries.insert(HistoryEntry(url: "https://s\(i).com/", title: "", lastVisit: t0, visits: 1), at: 0)
        }
        h.record(url: URL(string: "https://new.com/")!, title: "N", at: t0)
        expectEqual(h.entries.count, HistoryLog.maxEntries)
        expectEqual(h.entries[0].title, "N")
    }
    test("よく見るサイトと日ごとの見出し") {
        var h = HistoryLog()
        h.record(url: URL(string: "https://a.com/1")!, title: "a1", at: t0)
        h.record(url: URL(string: "https://a.com/2")!, title: "a2", at: t0)
        h.record(url: URL(string: "https://a.com/2")!, title: "a2", at: t0)
        h.record(url: URL(string: "https://b.com/")!, title: "b", at: t0 + 5)
        expectEqual(h.topSites().map { $0.title }, ["a2", "b"])
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = t0 + 86_400
        let g = HistoryLog.groupByDay(h.entries + [HistoryEntry(url: "https://c.com/", title: "c", lastVisit: now, visits: 1)].reversed(),
                                      now: now, calendar: cal)
        expectEqual(g.map { $0.title }.first, "昨日")
        let g2 = HistoryLog.groupByDay([HistoryEntry(url: "https://c.com/", title: "c", lastVisit: now, visits: 1)], now: now, calendar: cal)
        expectEqual(g2.map { $0.title }, ["今日"])
    }
    test("候補: 入れた文字で始まるサイトが上・重ならない") {
        let bm = [Bookmark(id: UUID(), title: "Swift フォーラム", url: "https://forums.swift.org/", added: t0)]
        var h = HistoryLog()
        h.record(url: URL(string: "https://www.apple.com/")!, title: "Apple", at: t0)
        h.record(url: URL(string: "https://developer.apple.com/swift/")!, title: "Swift - Apple Developer", at: t0)
        h.record(url: URL(string: "https://forums.swift.org/")!, title: "Swift Forums", at: t0)
        let s = Suggestions.rank(query: "app", bookmarks: bm, history: h.entries, now: t0)
        expectEqual(s.first?.url, "https://www.apple.com/")
        let s2 = Suggestions.rank(query: "swift", bookmarks: bm, history: h.entries, now: t0)
        expectEqual(s2.filter { $0.url == "https://forums.swift.org/" }.count, 1)
        expectEqual(s2.first?.kind, .bookmark)
        expect(Suggestions.rank(query: "  ", bookmarks: bm, history: h.entries).isEmpty)
        expect(Suggestions.rank(query: "zzz", bookmarks: bm, history: h.entries).isEmpty)
    }
    test("文字の大きさの段") {
        expectEqual(PageZoom.step(from: 1.0, by: 1), 1.15)
        expectEqual(PageZoom.step(from: 1.0, by: -1), 0.85)
        expectEqual(PageZoom.step(from: 3.0, by: 1), 3.0)
        expectEqual(PageZoom.step(from: 0.5, by: -1), 0.5)
        expectEqual(PageZoom.step(from: 1.2, by: 1), 1.25)
        expectEqual(PageZoom.step(from: 2.0, by: 0), 1.0)
        expectEqual(PageZoom.percent(1.15), "115%")
    }
}
