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
   画面: MyApp / BrowserView / BrowserModel / VNetScheme / HTTPSTakeover / PageScripts
   http: HTTPClient / HTTPResponseParser / HTTPSupport / TLSClient
   TCP/IP: GuestStack / GuestTCP / DNSMessage / Packet
   カード: VNetMachine / VNetCore / VNetDriver
   ルーター: UserNet / UserNetApple
   （全部で 19 ファイル）
4. 実行して、アドレスに https://example.com/ などを入れて「開く」

メモ
・https は SecureTransport。TLS 1.3 を試し、だめな相手は 1.2 でやり直します（どちらになったかはログの「TLS つながった」に出ます）
・ロボット扱いされにくいよう、User-Agent・Accept-Language・Sec-Fetch-*・ヘッダの順番・圧縮（gzip/deflate/br）を iPad の Safari に揃えています
・リダイレクトは WebKit に本当の移動として伝えます（アドレス欄も移動先になります）
・http（80 番）は、今の iPad の環境では途中で 400 にされます（エミュレータのときと同じ）
・ページの中の画像や CSS も、HTML と CSS を書き換えて自作の通信で読みます。JavaScript の fetch・XMLHttpRequest・img.src なども、ページに入れたスクリプトで書き換えます。
  それでも直接読もうとするものは止めています。https のページでしか使えない機能（ログインなど）は動かないことがあります
