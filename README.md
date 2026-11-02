# Vela

**iPad の Swift Playgrounds だけで動く、自前の TCP/IP スタックを積んだ実験ブラウザ**

Android エミュレータと同じ「仮想 LAN カード（virtio-net）」と「小さなルーター（UserNet）」を使って、ページを読み込んで表示するブラウザです。
Android の代わりに、Swift で書いた小さな「ドライバ」と「TCP/IP」がカードを動かします。

> [!WARNING]
> 開発者向けの実験です。WebKit の内部の仕組みや非推奨の SecureTransport に頼っている所があります（[受け入れたリスク](#受け入れたリスク)）。普段使いのブラウザとしては使わないでください。

## しくみ

```text
ブラウザ（WKWebView）
  ↓ https://…（読み込みは全部 VNetScheme が引き受ける。だめなときは vnets://…）
VNetScheme → HTTPPool（http を話す。接続の使い回し・gzip・クッキー）→ TLSStream（https の暗号。SecureTransport）
  ↓
GuestStack（自作の TCP/IP：DHCP・ARP・DNS・TCP）
  ↓
VirtioNetDriver（自作のドライバ）
  ↓ RAM の中のキュー と レジスタ
VirtioNet（仮想 LAN カード。エミュレータと同じもの）
  ↓
UserNet（小さなルーター）→ Network.framework → インターネット
```

## 主な機能

- **タブ・ブックマーク・履歴・ページ内検索**（Safari 風の画面。キーボードショートカット対応）
- **HTTPS-First** と **HSTS**
- **ストリーミング読み込み**（ヘッダが来たらすぐ渡し、中身は届いた分ずつ。大きいファイル・動画でもメモリにためない）
- **ダウンロード**（進み具合・取り消し・共有）
- **広告・トラッカーのブロック**（EasyList・EasyPrivacy・AdGuard Japanese）
- **Cookie の決まり・LAN の保護**などの独自の守り
- **開発者パネル**（ログ・通信・タブ・Cookie・HSTS・VNet の中身・落ちたときの記録）

## 動かし方（Swift Playgrounds）

1. iPad の Swift Playgrounds で、新しい「App」を作る
2. 最初からある `ContentView.swift` と `MyApp.swift` を消す
3. [`Playgrounds/VelaParts/`](Playgrounds/VelaParts) の `Vela1.swift`〜`Vela10.swift` を**全部**入れる
4. 実行して、アドレスに `https://example.com/` などを入れて「開く」

> [!NOTE]
> 1 つにまとめた `Playgrounds/VelaAll.swift` もありますが、大きすぎて Playgrounds が
> 「Timed out waiting for a thunk to build after 30.0 seconds」で止まることがあります。ふつうは `VelaParts` の 10 個を使ってください。
> `VelaAll.swift` と `VelaParts` を一緒に入れてはいけません。`Sources/` の 50 ファイルをそのまま入れても動きます。

## フォルダの構成

```text
Sources/              アプリのソース（ここを直す）
  App/                画面: MyApp / BrowserView / BrowserControls / TabViews / LibraryView /
                            DevPanel / DevPanelPages / SettingsView / AdBlockView / Downloads
  Browser/            ブラウザの中身: BrowserModels / BrowserStore / BrowserTab / TabWebDelegate / Library /
                            LibraryModel / AddressInput / ErrorPages / DownloadFiles / NetLog / Persistence /
                            DevLog / CrashLog
  WebKitBridge/       VNet と WebKit: VNetScheme / HTTPSTakeover / PageScripts
  Policy/             守り: NetPolicy / SiteUtil / Cookies / RedirectPolicy / LocalNetworkPolicy /
                            CookieJar / HSTSStore
  AdBlock/            広告ブロック: FilterLists / ABPFilter / BlockEngine / ContentBlocker
  HTTP/               http: HTTPClient / HTTPResponseParser / HTTPSupport / TLSClient
  TCPIP/              TCP/IP: GuestStack / GuestTCP / DNSMessage / Packet
  VirtioNet/          カード: VNetMachine / VNetCore / VNetDriver
  Router/             ルーター: UserNet / UserNetApple
Playgrounds/          Playgrounds に入れる、まとめたもの（自動生成。手で直さない）
  VelaAll.swift
  VelaParts/Vela1〜10.swift
tools/
  merge_swift.py      Sources → Playgrounds を作る
  swiftcheck/         Windows（WSL）で Swift 5.8 の型チェック
  tests/              単体テスト
```

## 開発（Windows + WSL）

Xcode が無くても、WSL の Ubuntu に入れた Swift 5.8.1（Linux 版）で型チェックとテストができます。
Swift が入っていなければ、最初の実行で `tools/swiftcheck/setup.sh` が自動で入れます（`~/toolchains`。sudo 不要）。

```powershell
# Sources を直したら、まとめ直す
python tools/merge_swift.py

# 型チェック（最後の行が「結果: OK」なら OK）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1                        # Sources 全部
powershell -NoProfile -ExecutionPolicy Bypass -File tools\swiftcheck\swiftcheck.ps1 Playgrounds\VelaParts  # まとめた版

# 単体テスト（UI・WebKit に頼らない部品）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests\runtests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests\runtests.ps1 Cookie   # 名前に「Cookie」を含むテストだけ
```

SwiftUI・WebKit・UIKit などは Linux に無いので、`tools/swiftcheck/stubs/` の形だけの定義（スタブ）で代わりにしています。
チェックが OK でも、iPad での最終確認は必要です。

## 使い方のメモ

- **ブックマークと履歴**: ツールバーの本のボタン・「…」メニュー・⌘⌥B / ⌘Y。新しいタブにはブックマークとよく見るサイトが出ます。アドレス欄に打つと候補が出ます
- **アドレス欄の左の「ぁあ」**: 文字の大きさ（サイトごとに覚える）・ページ内を検索・ブックマーク・共有・通信の切り替え
- **広告ブロック**: EasyList・EasyPrivacy・AdGuard Japanese（4 日ごとに自動で更新。URL で足せる）。VNet のタブは Vela が通信を 1 つずつ調べて止め、数を出します。標準の通信のタブは WebKit のルールで止めます。「ぁあ」でサイトごとに止められます。設定は「…」→ 広告ブロック
- **設定**（「…」→ 設定）: 検索エンジン・HTTPS-First・Cookie の決まり・LAN の保護・VNet の切り替え・開発者向けのもの・データを消す（履歴・Cookie とサイトのデータ・HSTS）
- **開発者パネル**（「…」→ 開発者パネル・⌘⌥I）: 概要・ログ（重さ・種類・タブ・文字で絞り込み）・通信（VNet の要求 1 つずつ。結果・時間・大きさ・途中で決めたこと）・タブ（状態と移動の出来事）・Cookie・HSTS・広告ブロック・VNet（フレーム・TCP・接続）・システム（データのファイル）・範囲とリスク。右上の「コピー」で、ログ・通信の記録・前回落ちたときの記録をコピーできます
- **ダウンロード**: `Documents/Downloads` に保存します。ツールバーのボタンから、進み具合・取り消し・共有（「ファイル」に保存など）ができます。
  VNet のタブでは、WebKit のダウンロード（WKDownload）を使わずに VNet が自分でファイルに書きます（VNet が引き受けた読み込みを WebKit がダウンロードに変えると、アプリが落ちたため）。途中からの再開はできず、やり直しは最初からです
- **読めなかったとき**は、原因と「再試行」「標準の通信で開く」のボタンを出します。設定で、標準の通信へ自動で切り替えることもできます

### キーボード

| キー | 動き |
| --- | --- |
| ⌘L | アドレス欄 |
| ⌘T / ⌘W | タブを開く / 閉じる |
| ⌘⇧T | 閉じたタブを開き直す |
| ⌘⇧[ ⌘⇧] / ⌃Tab | タブの移動 |
| ⌘1〜9 | n 番目のタブ |
| ⌘F | ページ内を検索 |
| ⌘D | ブックマーク |
| ⌘+ / ⌘- / ⌘0 | 文字の大きさ |
| ⌘R / ⌘. | 再読み込み / 中止 |
| ⌘[ / ⌘] | 戻る / 進む |
| ⌘⌥B / ⌘Y | ブックマーク / 履歴 |
| ⌘⌥I | 開発者パネル |

## 通信のメモ

- https は SecureTransport の **TLS 1.2** です（SecureTransport は TLS 1.3 に対応しません）。TLS 1.3 だけのサーバーは開けないので、標準の通信で開いてください
- ロボット扱いされにくいよう、User-Agent・Accept-Language・Sec-Fetch-*・ヘッダの順番・圧縮（gzip / deflate / br）を iPad の Safari に揃えています
- リダイレクトは WebKit に本当の移動として伝えます（アドレス欄も移動先になります）
- http（80 番）は、今の iPad の環境では途中で 400 にされます（エミュレータのときと同じ）。HSTS の記録があるサイトは https に上げて読みます
- **HTTPS-First**: ページを開く `http://` は、まず https で試します。だめなら「http のまま開く」を出します（設定で切れます）
- 壊れた返事（負の Content-Length・Transfer-Encoding と Content-Length の両方 など）は読まずに失敗にします。返事 1 つは 32MB まで、読んでいる途中の合計が 128MB を超えたら新しい要求を待たせます。接続は同じ相手に 6 本・全部で 32 本まで
- ページの読み込みをやめたら（WebKit が止めたら）、裏の通信も止めます
- TCP は、順番を飛ばして届いた分を取っておき、送り直しで重なった分は外して受け取ります

## VNet の対応範囲

| | |
| --- | --- |
| **VNet が読むもの** | ページ本体と部品の http / https（HTTP/1.1）、fetch・XMLHttpRequest、リダイレクト |
| **VNet を通らないもの** | WebSocket（ws / wss）は WebKit が直接つなぐ。標準の通信のときは全部 WebKit が読む |
| **対応しないもの** | HTTP/2・HTTP/3（VNet は HTTP/1.1 だけ）、TLS 1.3、IPv6（AAAA） |

Vela 独自の守り（Cookie の判定・LAN の保護）は、VNet を通る通信にしか効きません。
WebSocket と標準の通信には、WebKit のルールとページのスクリプトで、できる所まで LAN の保護をかけています
（ホスト名で LAN に解決されるものは防げません。スクリプトの守りは回避される可能性があります）。

## 守り（[`Sources/Policy/`](Sources/Policy/)）

- **CORS**: サーバーの `Access-Control-*` をそのまま渡します（Vela が許可を足すことはしません。OPTIONS もサーバーに送ります）
- **CSP・X-Frame-Options** はそのまま渡します（予備の `vnets://` の作りだけは外します。この作りは開発者向けの実験で、安全ではありません）
- **Cookie** の正本は WebKit の置き場（`WKHTTPCookieStore`）です。VNet はその写し（`CookieJar`）から、決まり（`CookiePolicy`）で許されたものだけを送ります
  - サードパーティ Cookie は既定でブロック（Safari の ITP や Storage Access API の例外までは再現しません）
  - SameSite が無い Cookie は Lax として扱います（作られてから 2 分以内は、クロスサイトのトップレベルの POST にも付けます）
  - リダイレクトの途中で一度クロスサイトになったら、その後はクロスサイトとして扱います
  - ページの JavaScript から届く Cookie の文字列は使いません（「変わった」という合図だけ受けて、WebKit の置き場を読み直します）
- **リダイレクト**: 別のオリジンへ移るときは `Authorization`・`Proxy-Authorization`・`Cookie` を外します。`Origin` は null、`Referer` はオリジンだけにします
- **LAN の保護**（Vela 独自。Chrome の PNA / LNA とは別物）: 公開のサイトから LAN の機器へは届かせません（部品の読み込み・リダイレクト・DNS が LAN のアドレスを返したとき）。
  ページが LAN へ移動させるときは確認のページを出します。アドレス欄に自分で入れたときは開きます
- **HSTS**: VNet が受け取った https の応答（トップレベルかファーストパーティ）から記録し、http を https に上げます

## 受け入れたリスク

- https の横取り（`HTTPSTakeover`）は、WebKit の中の作り（`handlesURLScheme` の差し替えと `_willPerformRedirection:`）に頼っています。
  WebKit が変われば動かなくなる・落ちる可能性があります。確かめた iOS の版（16〜26）だけで使い、確認に失敗したら元に戻して標準の通信にします
- SecureTransport は 2019 年から非推奨です（技術的負債）。将来 TLS エンジンを移すかは、別の課題です
