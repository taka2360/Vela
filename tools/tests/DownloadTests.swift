import Foundation

// MARK: - ダウンロードの判定・ファイル名・ファイルに書く部品のテスト

func downloadTests() {
    print("DownloadFiles")
    test("ダウンロードにするか") {
        expect(DownloadFiles.isDownload(status: 200, headers: [("Content-Disposition", "attachment; filename=a.txt"), ("Content-Type", "text/plain")]))
        expect(DownloadFiles.isDownload(status: 200, headers: [("Content-Type", "application/zip")]))
        expect(DownloadFiles.isDownload(status: 200, headers: [("Content-Type", "application/octet-stream")]))
        expect(!DownloadFiles.isDownload(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")]))
        expect(!DownloadFiles.isDownload(status: 200, headers: [("Content-Type", "application/pdf")]), "PDF は表示する")
        expect(!DownloadFiles.isDownload(status: 200, headers: [("Content-Type", "video/mp4")]))
        expect(!DownloadFiles.isDownload(status: 200, headers: []), "種類が無ければ WebKit に任せる")
        expect(!DownloadFiles.isDownload(status: 404, headers: [("Content-Type", "application/zip")]), "エラーの返事はページとして見せる")
        expect(!DownloadFiles.isDownload(status: 200, headers: [("Content-Disposition", "inline"), ("Content-Type", "image/png")]))
    }
    test("ファイル名（filename*・filename・URL・種類から拡張子）") {
        expectEqual(DownloadFiles.filename(contentDisposition: "attachment; filename=\"report 1.pdf\"", url: nil, mime: nil), "report 1.pdf")
        expectEqual(DownloadFiles.filename(contentDisposition: "attachment; filename=\"a.zip\"; filename*=UTF-8''%E8%B3%87%E6%96%99.zip", url: nil, mime: nil), "資料.zip")
        expectEqual(DownloadFiles.filename(contentDisposition: "attachment; filename=plain.bin", url: nil, mime: nil), "plain.bin")
        expectEqual(DownloadFiles.filename(contentDisposition: nil, url: url("https://e.test/files/%E3%81%82.txt?x=1"), mime: nil), "あ.txt")
        expectEqual(DownloadFiles.filename(contentDisposition: nil, url: url("https://e.test/get"), mime: "application/pdf"), "get.pdf")
        expectEqual(DownloadFiles.filename(contentDisposition: nil, url: url("https://e.test/"), mime: nil), "download")
        expectEqual(DownloadFiles.filename(contentDisposition: "attachment; filename=\"../../etc/passwd\"", url: nil, mime: nil), "passwd", "パスを外す")
        expectEqual(DownloadFiles.sanitize(".hidden"), "hidden")
        expectEqual(DownloadFiles.sanitize("a:b/c"), "a_b_c")
    }
    test("同じ名前があれば番号を付ける") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        expectEqual(DownloadFiles.uniqueURL(for: "a.zip", in: dir).lastPathComponent, "a (2).zip")
        expectEqual(DownloadFiles.uniqueURL(for: "b.zip", in: dir).lastPathComponent, "b.zip")
    }
    test("ファイルに書く・完了・失敗と取り消しでは消す") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vela-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let d = VNetDownload(source: url("https://e.test/x.bin"), suggestedName: "x.bin", expected: 6, in: dir) else { expect(false); return }
        d.write(Data("abc".utf8)); d.write(Data("def".utf8)); d.finish(); d.waitUntilIdle()
        expectEqual(d.state, .finished); expectEqual(d.received, 6)
        expectEqual(try? Data(contentsOf: d.fileURL), Data("abcdef".utf8))
        d.write(Data("zzz".utf8)); d.waitUntilIdle()
        expectEqual(d.received, 6, "終わった後は書かない")
        guard let f = VNetDownload(source: url("https://e.test/y.bin"), suggestedName: "y.bin", expected: -1, in: dir) else { expect(false); return }
        f.write(Data("ab".utf8)); f.fail("切れた"); f.waitUntilIdle()
        expectEqual(f.state, .failed("切れた")); expect(!FileManager.default.fileExists(atPath: f.fileURL.path))
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        guard let c = VNetDownload(source: url("https://e.test/z.bin"), suggestedName: "z.bin", expected: -1, in: dir) else { expect(false); return }
        c.cancelAction = { flag.cancelled = true }
        c.cancel(); c.waitUntilIdle()
        expect(flag.cancelled); expectEqual(c.state, .cancelled); expect(!FileManager.default.fileExists(atPath: c.fileURL.path))
    }
}

// MARK: - 落ちたときの記録

func crashLogTests() {
    print("CrashLog")
    test("start が止まらない（lock を 2 回取って固まらない）") {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            CrashLog.start()
            CrashLog.writeLine("テストの行")
            done.signal()
        }
        expect(done.wait(timeout: .now() + 3) == .success, "CrashLog.start が 3 秒で終わらない（起動で固まる）")
    }
}
