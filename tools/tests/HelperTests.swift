import Foundation

// MARK: - 共通にした小さな部品のテスト（まとめる前の動きをそのまま書き留めたもの）

func helperTests() {
    print("Helpers")
    test("ドメインが合うか（BlockEngine.domainMatches）") {
        expect(BlockEngine.domainMatches("example.com", "example.com"))
        expect(BlockEngine.domainMatches("a.example.com", "example.com"))
        expect(BlockEngine.domainMatches("a.b.example.com", "example.com"))
        expect(!BlockEngine.domainMatches("badexample.com", "example.com"))
        expect(!BlockEngine.domainMatches("example.com", "a.example.com"))
        expect(!BlockEngine.domainMatches("example.com.evil", "example.com"))
        expect(!BlockEngine.domainMatches("Example.com", "example.com"))   // 小文字にはしない（呼ぶ側でする）
        expect(BlockEngine.domainMatches("", ""))
    }
    test("www. を外す（候補・アドレス欄）") {
        expectEqual(LibraryKey.bare("http://www.a.com"), "a.com")
        expectEqual(LibraryKey.bare("WWW.A.COM/x"), "a.com/x")
        expectEqual(LibraryKey.bare("www."), "")
        expectEqual(LibraryKey.bare("wwwa.com"), "wwwa.com")
        expectEqual(LibraryKey.bare("www.www.a.com"), "www.a.com")   // 1 回だけ外す
        expectEqual(AddressInput.shortDisplay(url("https://www.www.a.com/")), "www.a.com")
        expectEqual(AddressInput.shortDisplay(url("https://wwwa.com/")), "wwwa.com")
        expectEqual(AddressInput.shortDisplay(url("https://sub.www.a.com/")), "sub.www.a.com")
    }
    test("SiteUtil.hostMatches / stripWWW") {
        expect(SiteUtil.hostMatches("a.example.com", domain: "example.com"))
        expect(!SiteUtil.hostMatches("badexample.com", domain: "example.com"))
        expect(!SiteUtil.hostMatches("Example.com", domain: "example.com"))
        expectEqual(SiteUtil.stripWWW("www.a.com"), "a.com")
        expectEqual(SiteUtil.stripWWW("WWW.a.com"), "WWW.a.com")
        expectEqual(SiteUtil.stripWWW("www.www.a"), "www.a")
        expectEqual(SiteUtil.stripWWW("www"), "www")
    }
    test("保存先のフォルダ（AppPaths）") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let old = base.appendingPathComponent("Vela", isDirectory: true)
        expectEqual(AppPaths.support, old)
        expectEqual(JSONFile<Int>.defaultDirectory(), old)
        expectEqual(CrashLog.folder, old)
        expectEqual(CrashLog.currentURL, old.appendingPathComponent("crash-current.txt"))
    }
    test("MIME の種類（DownloadFiles）") {
        expectEqual(DownloadFiles.mimeEssence(" Text/HTML ; charset=utf-8"), "text/html")
        expectEqual(DownloadFiles.mimeEssence(";a"), "a")
        expect(DownloadFiles.isDisplayable(mime: ""))
        expect(DownloadFiles.isDisplayable(mime: "  "))
        expect(DownloadFiles.isDisplayable(mime: "Text/HTML; charset=utf-8"))
        expect(DownloadFiles.isDisplayable(mime: " application/pdf ;x=1"))
        expect(!DownloadFiles.isDisplayable(mime: ";charset=utf-8"))        // 空の部分は飛ばすので「charset=utf-8」で判断される（今の動き）
        expect(DownloadFiles.isDisplayable(mime: ";"))
        expect(!DownloadFiles.isDisplayable(mime: "application/zip"))
        expect(!DownloadFiles.isDisplayable(mime: "application/octet-stream; name=a"))
        expectEqual(DownloadFiles.extensionFor(mime: "Application/PDF; q=1"), "pdf")
        expectEqual(DownloadFiles.extensionFor(mime: " image/jpeg"), "jpg")
        expectEqual(DownloadFiles.extensionFor(mime: ""), nil)
        expectEqual(DownloadFiles.extensionFor(mime: ";"), nil)
        expectEqual(DownloadFiles.extensionFor(mime: "application/x-unknown"), nil)
    }
}
