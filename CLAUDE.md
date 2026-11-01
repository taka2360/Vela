# VNetBrowser

iPad の Swift Playgrounds（App、Swift 5.8）で動かす実験ブラウザ。ルートの `*.swift` 19 本を Playgrounds に入れて使う。
`VNetBrowserAll.swift` は `merge_swift.py` で 19 本を 1 つにまとめたもの（手で直さず、直したら `python merge_swift.py` で作り直す）。

## Swift のコンパイルチェック（.swift を直したら必ず実行する）

Windows には Xcode が無いので、WSL の Ubuntu に入れた Swift 5.8.1（Linux 版）で型チェックする。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1                          # ルートの .swift 全部（*All.swift 以外）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1 VNetBrowserAll.swift     # まとめた版
```

- 最後の行が `結果: OK` ならエラー無し。`結果: NG` なら「==== エラー ====」の所を直す（終了コードも 0 / 1）
- SwiftUI・WebKit・UIKit・Network・Security・Compression・ObjectiveC は Linux に無いので、`tools/swiftcheck/stubs/` の**形だけの定義（スタブ）**で代用している。
  - 「cannot find 'X' in scope」「has no member」などが iOS の本物の API について出たら、まずスタブの不足を疑う。本物の iOS 16 SDK と**同じ名前・ラベル・型**でスタブに足す（コードの方をスタブに合わせて曲げない）
  - スタブは本物よりゆるい所がある。OK でも iPad で 100% 通るとは限らない（特に MainActor・Sendable まわり）
- 「Linux では調べられなかったもの」は iPad では通る想定のもの（Objective-C の `@convention(block)` など、NSObject の `override init` の MainActor）。ふつうは無視してよい
- `#if os(iOS)` は iOS 側として読む（コピーの上で `os(iOS)` → `true` に置き換えてから調べる）
- Swift が入っていなければ自動で `tools/swiftcheck/setup.sh` が入れる（WSL の `~/toolchains`。sudo 不要）
