---
name: swift-check
description: Vela の .swift が iPad の Swift Playgrounds（Swift 5.8）でコンパイルエラーにならないか、WSL の Swift 5.8.1 とスタブで型チェックする。"swift-check"、"swiftチェック"、"コンパイルできるか"、"エラーが出ないか"、.swift を直した後の確認に使う。
---

# swift-check

1. 実行する（プロジェクトのルートで）:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1 $ARGUMENTS
   ```
   引数なし = ルートの .swift 全部（*All.swift 以外）。ファイルやフォルダを渡すとそれだけ。
   `VelaAll.swift` を直した・作り直したときは、それも別に調べる。
2. 最後の行の `結果: OK / NG` を見る。
3. NG のとき:
   - 「==== エラー ====」を 1 件ずつ読み、ソースを直して、もう一度実行する
   - iOS の API が「見つからない・メンバーが無い」と言われたら、`tools/swiftcheck/stubs/*.swift` に本物の iOS 16 SDK と同じ形で足す（コードをスタブに合わせない）。スタブを変えると次の実行で自動で作り直される
   - スタブが原因か、コードが原因か迷うときは、ユーザーに伝えて判断してもらう
4. 「Linux では調べられなかったもの」は報告だけでよい（iPad では通る想定）。
5. ユーザーには、エラーの件数・直した所・スタブを足したかを短く伝える。スタブは本物よりゆるいので、OK でも「iPad での最終確認は必要」と添える。
