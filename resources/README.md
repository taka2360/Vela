# resources/

アプリが**ネットから落として使う**ファイル。手で直さない（GitHub Actions が作り直す）。

## ubo-scriptlets.json と ubo-scriptlets.json.sig

広告ブロックのスクリプトレット（`##+js(...)` の道具）。YouTube の動画広告などは、これでページの中の JSON から広告の部分を消す。

- **中身**: [uBlock Origin](https://github.com/gorhill/uBlock)（uBO）の `src/js/resources/scriptlets.js` に登録されている関数と、
  `src/web_accessible_resources` の注入できる JS を、**変えずにそのまま**（`fn.toString()`）入れたもの。
  JSON の `ubo`（タグ）・`commit`・`source` に元の場所がある
- **作り方**: `tools/ubo/build_scriptlets.mjs`（node）。uBO のタグの tar.gz を落とし、`builtinScriptlets` を import して書き出す
- **更新**: `.github/workflows/ubo-scriptlets.yml` が毎日、uBO の**最新の安定版**で作り直し、中身が変わったときだけコミットする。
  uBO のリスト（uAssets）は今の安定版の uBO で動くように書かれているので、これで uBO の安定版を使う人と同じ状態になる
- **署名**: Ed25519。署名するのは、Actions の中で uBO のソースから作った中身だけ。アプリ（`Sources/AdBlock/ScriptletVerify.swift`）は、
  埋め込んだ公開鍵で `.sig` を確かめ、前より古いもの（`generated`）は受け取らない
- **アプリが落とす場所**: `https://raw.githubusercontent.com/taka2360/Vela/main/resources/ubo-scriptlets.json`（と `.sig`）

### ライセンス

uBlock Origin — Copyright (C) 2014-present Raymond Hill。GNU General Public License v3 またはそれ以降（GPL-3.0-or-later）。
JSON の中の関数は uBO のものを変えずに入れたもので、JSON そのものがソースの形。Vela も GPLv3（リポジトリの `LICENSE`）。

uBO のフィルターのリスト（[uAssets](https://github.com/uBlockOrigin/uAssets)。これも GPLv3）は、Vela は配らない。利用者の端末が直接落とす。
`tools/ubo/fixtures/youtube.txt` だけは、テストのために uAssets から写した行（GPLv3）。

### 署名の鍵

```powershell
node tools/ubo/keygen.mjs $HOME\.vela-ubo-signing-key.pem    # 秘密鍵（リポジトリに入れない）と公開鍵を出す
```

1. 出た公開鍵を `Sources/AdBlock/ScriptletVerify.swift` の `publicKeyBase64` に入れる
2. 秘密鍵のファイルの中身（`-----BEGIN PRIVATE KEY-----` から）を、GitHub の Settings → Secrets and variables → Actions に
   `UBO_SIGNING_KEY` という名前で入れる
3. 手で作り直すとき: `$env:UBO_SIGNING_KEY_FILE="$HOME\.vela-ubo-signing-key.pem"; node tools/ubo/build_scriptlets.mjs`

鍵を変えると、古いアプリは新しい道具を受け取れなくなる（コードの入れ直しが要る）。

### 確かめる

```powershell
node tools/ubo/verify.mjs          # 署名がアプリの公開鍵と合うか
node tools/ubo/check_lists.mjs     # 今の uBO のリストで使われている名前が、全部道具にあるか
node tools/ubo/test_assembled.mjs  # Vela が組み立てた JS が動くか（先に単体テスト。tools/checkall.ps1 が両方やる）
```
