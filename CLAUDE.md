# Vela

iPad の Swift Playgrounds（App、Swift 5.8）で動かす実験ブラウザ。ソースは `Sources/<役割>/*.swift`（App・Browser・WebKitBridge・Policy・AdBlock・HTTP・TCPIP・VirtioNet・Router）。
`Playgrounds/VelaAll.swift` は `tools/merge_swift.py` でそれらを 1 つにまとめたもの（手で直さず、直したら `python tools/merge_swift.py` で作り直す）。
新しい .swift を足したら、合うフォルダに置き、`tools/merge_swift.py` の ORDER と README.md のファイル一覧にも足す（ファイル名は Sources 全体で重ならないこと）。
`merge_swift.py` は同じ中身を 11 個に分けた `Playgrounds/VelaParts/Vela1〜11.swift` も作る（1 つ 1,500 行くらいまでが目安）。ユーザーは Playgrounds にこちらを入れる
（VelaAll.swift 1 つ（今は 1 万行を超える）だと「Timed out waiting for a thunk to build after 30.0 seconds」で止まる）。
1 つの部品が大きくなってきたら `--parts` を増やす。チェックは `swiftcheck.ps1 Playgrounds\VelaParts`。

## Swift のコンパイルチェック（.swift を直したら必ず実行する）

Windows には Xcode が無いので、WSL の Ubuntu に入れた Swift 5.8.1（Linux 版）で型チェックする。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1                                  # Sources の .swift 全部（*All.swift 以外）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1 Playgrounds\VelaParts     # まとめた版（ユーザーが入れる方）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1 Playgrounds\VelaAll.swift # 1 つにまとめた版
```

- 最後の行が `結果: OK` ならエラー無し。`結果: NG` なら「==== エラー ====」の所を直す（終了コードも 0 / 1）
- SwiftUI・WebKit・UIKit・Network・Security・Compression・CryptoKit・ObjectiveC は Linux に無いので、`tools/swiftcheck/stubs/` の**形だけの定義（スタブ）**で代用している。
  - 「cannot find 'X' in scope」「has no member」などが iOS の本物の API について出たら、まずスタブの不足を疑う。本物の iOS 16 SDK と**同じ名前・ラベル・型**でスタブに足す（コードの方をスタブに合わせて曲げない）
  - スタブは本物よりゆるい所がある。OK でも iPad で 100% 通るとは限らない（特に MainActor・Sendable まわり）
- 「Linux では調べられなかったもの」は iPad では通る想定のもの（Objective-C の `@convention(block)` など、NSObject の `override init` から iOS の API（WKWebView など）を触る所）。ふつうは無視してよい
- ただし `@MainActor` のクラスの `override init` から、**自分で書いた** `@MainActor` のメソッド・init・プロパティを呼ぶのは iPad でもエラーになる（実際に出た）。チェックもエラーとして出す。そういう準備は init の中でせず、`Task { @MainActor in self.setUp() }` のように後に回す
- `#if os(iOS)` は iOS 側として読む（コピーの上で `os(iOS)` → `true` に置き換えてから調べる）
- Swift が入っていなければ自動で `tools/swiftcheck/setup.sh` が入れる（WSL の `~/toolchains`。sudo 不要）

## まとめて確かめる

`powershell -NoProfile -ExecutionPolicy Bypass -File tools\checkall.ps1` で merge・swiftcheck（Sources・VelaAll・VelaParts）・単体テストを全部動かす。最後の行が `ALL OK` なら全部通った（終了コード 0）。

## 単体テスト（UI・WebKit に頼らない部品）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests\runtests.ps1            # 全部
powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests\runtests.ps1 Cookie     # 名前に「Cookie」を含むテストだけ
```

- テストに入れるアプリ側のファイルは `tools/tests/sources.txt`、テストは `tools/tests/*.swift`（入口は `main.swift`）
- 最後の行が `結果: OK（n 件）` なら全部通った
