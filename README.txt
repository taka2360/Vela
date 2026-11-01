Vela（実験アプリ）

Android エミュレータと同じ「仮想 LAN カード（virtio-net）」と「小さなルーター（UserNet）」を使って、
ページを読み込んで表示するだけのブラウザです。Android の代わりに、Swift で書いた小さな
「ドライバ」と「TCP/IP」が、カードを動かします。

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

作り方（Swift Playgrounds）
1. 新しい「App」を作る
2. 最初からある ContentView.swift と MyApp.swift を消す（または中身をこのフォルダのものに入れ替える）
3. このフォルダの .swift ファイルを全部入れる
   画面: MyApp / BrowserView / BrowserModel / Persistence / VNetScheme / HTTPSTakeover / PageScripts
   守り: NetPolicy / CookieJar / HSTSStore
   http: HTTPClient / HTTPResponseParser / HTTPSupport / TLSClient
   TCP/IP: GuestStack / GuestTCP / DNSMessage / Packet
   カード: VNetMachine / VNetCore / VNetDriver
   ルーター: UserNet / UserNetApple
   （全部で 23 ファイル。1 つにまとめた VelaAll.swift だけを入れてもよい）
4. 実行して、アドレスに https://example.com/ などを入れて「開く」

メモ
・https は SecureTransport の TLS 1.2 です（SecureTransport は TLS 1.3 に対応しません）。TLS 1.3 だけのサーバーは開けないので、標準の通信で開いてください
・ロボット扱いされにくいよう、User-Agent・Accept-Language・Sec-Fetch-*・ヘッダの順番・圧縮（gzip/deflate/br）を iPad の Safari に揃えています
・リダイレクトは WebKit に本当の移動として伝えます（アドレス欄も移動先になります）
・http（80 番）は、今の iPad の環境では途中で 400 にされます（エミュレータのときと同じ）。HSTS の記録があるサイトは https に上げて読みます

VNet の対応範囲
  VNet が読むもの: ページ本体と部品の http / https（HTTP/1.1）、fetch・XMLHttpRequest、リダイレクト
  VNet を通らない・対応しないもの:
   ・WebSocket（ws / wss）は WebKit が直接つなぐ（VNet を通らない）
   ・HTTP/2・HTTP/3（VNet は HTTP/1.1 だけ）、TLS 1.3、IPv6（AAAA）
   ・標準の通信のときは、全部 WebKit が読む
  Vela 独自の守り（Cookie の判定・LAN の保護）は、VNet を通る通信にしか効きません。
  WebSocket と標準の通信には、WebKit のルールとページのスクリプトで、できる所まで LAN の保護をかけています
  （ホスト名で LAN に解決されるものは防げません。スクリプトの守りは回避される可能性があります）

守り（NetPolicy.swift）
・CORS: サーバーの Access-Control-* をそのまま渡します（Vela が許可を足すことはしません。OPTIONS もサーバーに送ります）
・CSP・X-Frame-Options はそのまま渡します（予備の vnets:// の作りだけは外します。この作りは開発者向けの実験で、安全ではありません）
・Cookie の正本は WebKit の置き場（WKHTTPCookieStore）です。VNet はその写し（CookieJar）から、決まり（CookiePolicy）で許されたものだけを送ります
  - サードパーティ Cookie は既定でブロック（Safari の ITP や Storage Access API の例外までは再現しません）
  - SameSite が無い Cookie は Lax として扱います（作られてから 2 分以内は、クロスサイトのトップレベルの POST にも付けます）
  - リダイレクトの途中で一度クロスサイトになったら、その後はクロスサイトとして扱います
  - ページの JavaScript から届く Cookie の文字列は使いません（「変わった」という合図だけ受けて、WebKit の置き場を読み直します）
・リダイレクト: 別のオリジンへ移るときは Authorization・Proxy-Authorization・Cookie を外します。Origin は null、Referer はオリジンだけにします
・LAN の保護（Vela 独自。Chrome の PNA / LNA とは別物）: 公開のサイトから LAN の機器へは届かせません
  （部品の読み込み・リダイレクト・DNS が LAN のアドレスを返したとき）。ページが LAN へ移動させるときは確認のページを出します。
  アドレス欄に自分で入れたときは開きます
・HSTS: VNet が受け取った https の応答（トップレベルかファーストパーティ）から記録し、http を https に上げます

受け入れたリスク
・https の横取り（HTTPSTakeover）は、WebKit の中の作り（handlesURLScheme の差し替えと _willPerformRedirection:）に頼っています。
  WebKit が変われば動かなくなる・落ちる可能性があります。確かめた iOS の版（16〜26）だけで使い、確認に失敗したら元に戻して標準の通信にします
・SecureTransport は 2019 年から非推奨です（技術的負債）。将来 TLS エンジンを移すかは、別の課題です

テスト（Windows から）
  powershell -NoProfile -ExecutionPolicy Bypass -File tools	estsuntests.ps1
