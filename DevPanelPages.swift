import SwiftUI

// MARK: - 開発者パネルのページ（通信・Cookie・HSTS・広告ブロック・VNet・システム・範囲とリスク）

// MARK: 通信

@MainActor
struct DevNetworkPage: View {
    @ObservedObject var store: BrowserStore
    @State private var onlyProblems = false
    @State private var onlyThisTab = false
    @State private var query = ""
    @State private var opened: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("失敗・ブロックだけ", isOn: $onlyProblems).fixedSize()
                Toggle("このタブだけ", isOn: $onlyThisTab).fixedSize()
                TextField("URL を探す", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("消す") { store.netLog.clear() }
            }
            .font(.system(size: 13))
            Text("VNet が引き受けた要求だけを記録します（標準の通信のタブ・WebSocket は入りません）。行を押すと、途中で決めたことが出ます")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(records) { r in
                        DevNetRow(record: r, opened: opened == r.id) { opened = opened == r.id ? nil : r.id }
                    }
                }
            }
        }
    }

    private var records: [NetRecord] {
        let tab = onlyThisTab ? store.selectedID : nil
        let q = query.lowercased()
        return store.netLog.recent(limit: 300) { r in
            (!onlyProblems || r.isProblem) && (tab == nil || r.tab == tab) && (q.isEmpty || r.url.lowercased().contains(q))
        }
    }
}

@MainActor
struct DevNetRow: View {
    let record: NetRecord
    let opened: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(DevTime.format(record.started)) \(record.tab.map { "#\($0) " } ?? "")\(record.line)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(opened ? nil : 1)
                .foregroundColor(color)
            if opened {
                ForEach(Array(record.notes.enumerated()), id: \.offset) { _, n in
                    Text("    " + n).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                if record.notes.isEmpty {
                    Text("    （メモなし）").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var color: Color {
        switch record.outcome {
        case .blocked: return .purple
        case .failed: return .red
        case .pending: return .secondary
        default: return (record.status ?? 0) >= 400 ? .orange : .primary
        }
    }
}

// MARK: Cookie

@MainActor
struct DevCookiePage: View {
    @ObservedObject var store: BrowserStore
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("ドメイン・名前で探す", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("\(cookies.count) / \(store.cookieJar.count) 個").font(.system(size: 13))
            }
            Text("VNet が使う Cookie の写し（正本は WebKit の置き場）。値は先頭だけ出します。消すのは 設定 → データ からできます")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(cookies.prefix(500).enumerated()), id: \.offset) { _, c in
                        DevLine(describe(c))
                    }
                }
            }
        }
    }

    private var cookies: [CookieRecord] {
        let q = query.lowercased()
        return store.cookieJar.snapshot()
            .filter { q.isEmpty || $0.domain.contains(q) || $0.name.lowercased().contains(q) }
            .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }

    private func describe(_ c: CookieRecord) -> String {
        var flags: [String] = []
        if c.hostOnly { flags.append("host-only") }
        if c.secure { flags.append("Secure") }
        if c.httpOnly { flags.append("HttpOnly") }
        flags.append("SameSite=\(c.sameSite.rawValue)")
        let exp = c.expires.map { "期限 \(DevTime.format($0)) \(Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0)日後" } ?? "セッション"
        let v = c.value.count > 16 ? String(c.value.prefix(16)) + "…" : c.value
        return "\(c.domain)\(c.path)  \(c.name)=\(v)  [\(flags.joined(separator: " "))・\(exp)]"
    }
}

// MARK: HSTS

@MainActor
struct DevHSTSPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HSTS の記録 \(store.hsts.all().count) 件（このホストは http でも https で開く）").font(.system(size: 13))
                Spacer()
                Button("全部消す") { store.clearHSTS() }
            }
            List {
                ForEach(store.hsts.all().sorted { $0.host < $1.host }, id: \.host) { e in
                    DevLine("\(e.host)\(e.includeSubDomains ? "（サブドメインも）" : "")  期限 \(e.expires)")
                }
                .onDelete { idx in
                    let hosts = store.hsts.all().sorted { $0.host < $1.host }.map { $0.host }
                    for i in idx { store.hsts.remove(hosts[i]) }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: 広告ブロック

@MainActor
struct DevAdBlockPage: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var adblock: AdBlocker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine("状態: \(adblock.enabled ? "使う" : "止めている")・\(adblock.status)")
                DevLine("VNet 用のルール \(adblock.ruleCount) 個・起動してから止めた数 \(adblock.totalBlocked)")
                DevLine("止めているサイト: \(adblock.disabledSites.isEmpty ? "なし" : adblock.disabledSites.sorted().joined(separator: ", "))")
                ForEach(adblock.lists) { l in
                    DevLine("\(l.enabled ? "●" : "○") \(l.name): 通信 \(l.networkRules)・隠す \(l.cosmeticRules)・対応外 \(l.unsupported)"
                            + "・WebKit \(l.netID == nil ? "なし" : "通信あり")/\(l.cosID == nil ? "なし" : "隠すあり")\(l.lastError.map { "・⚠️ \($0)" } ?? "")")
                }
                Divider().padding(.vertical, 6)
                Text("最近止めたもの").font(.subheadline)
                ForEach(store.netLog.recent(limit: 100) { if case .blocked = $0.outcome { return true } else { return false } }) { r in
                    DevLine("\(DevTime.format(r.started)) \(r.tab.map { "#\($0) " } ?? "")\(r.url)")
                    if case .blocked(let rule) = r.outcome { DevLine("    \(rule)").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: VNet

@MainActor
struct DevVNetPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                DevLine(store.takeover.description)
                DevLine("新しいタブの通信: \(store.defaultMode.rawValue)")
                if let s = store.vnetStats {
                    DevLine("IP: \(s.ready ? s.ip : "（まだ）")")
                    DevLine("フレーム: 送 \(s.framesOut)（\(s.bytesOut / 1024)KB）・受 \(s.framesIn)（\(s.bytesIn / 1024)KB）・捨てた \(s.droppedRx)")
                    DevLine("TCP: 送り直し \(s.tcpRetransmits)・順番を直した \(s.tcpReordered)")
                    DevLine("接続: 新しく \(s.pool.opened)・使い回し \(s.pool.reused)・使用中 \(s.pool.busy)・空き \(s.pool.idle)・待ち \(s.pool.waiting)")
                    DevLine("読み途中の中身: \(s.pool.bufferedBytes / 1024)KB・DNS の覚え \(s.pool.dnsCached) 件")
                } else {
                    DevLine("（数字を集めています…）")
                }
                let limits = PoolLimits()
                DevLine("上限: 1 要求 \(limits.maxBodyPerRequest >> 20)MB・全体の読み途中 \(limits.maxBufferedTotal >> 20)MB・接続 ホストごと \(limits.maxPerHost)・全体 \(limits.maxTotalConnections)・待ち \(limits.maxWaiting)")
                Divider().padding(.vertical, 6)
                Text("最近の VNet・通信のログ").font(.subheadline)
                ForEach(store.logs.all().filter { $0.category == .vnet || $0.category == .net }.suffix(60).reversed()) { e in
                    DevLine(e.line)
                }
            }
        }
    }
}

// MARK: システム

@MainActor
struct DevSystemPage: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let p = ProcessInfo.processInfo
                DevLine("OS: \(p.operatingSystemVersionString)")
                DevLine("メモリ（端末）: \(p.physicalMemory >> 20)MB・CPU \(p.activeProcessorCount) 個")
                DevLine("起動してから: \(Int(Date().timeIntervalSince(store.launchedAt)) / 60) 分")
                DevLine("動いている WebView: \(store.liveWebViewCount) 枚（上限 \(BrowserStore.maxLiveWebViews)）")
                DevLine("ブックマーク \(store.library.bookmarks.items.count) 件・履歴 \(store.library.history.entries.count) 件")
                Divider().padding(.vertical, 6)
                Text("データのファイル（Application Support/Vela）").font(.subheadline)
                ForEach(DevFiles.list(), id: \.0) { f in DevLine("\(f.0)  \(f.1 / 1024)KB") }
            }
        }
    }
}

enum DevFiles {
    /// Vela のデータのフォルダの中身（名前, 大きさ）。filters の中も数える
    static func list() -> [(String, Int)] {
        let fm = FileManager.default
        let dir = JSONFile<SessionData>.defaultDirectory()
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var out: [(String, Int)] = []
        for case let u as URL in e {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 { out.append((u.path.replacingOccurrences(of: dir.path + "/", with: ""), size)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

// MARK: 範囲とリスク

@MainActor
struct DevScopePage: View {
    var body: some View {
        ScrollView {
            Text(DevScopePage.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    static let text = """
    【VNet が処理するもの】
    ・ページ本体とサブリソースの http / https（HTTP/1.1）、fetch・XHR、リダイレクト
    ・Vela 独自の守り（Cookie の判定・LAN の保護・HSTS・広告ブロックの判定と数）は、VNet を通る通信にだけ効く

    【VNet が処理しないもの・未対応】
    ・WebSocket（ws / wss）は VNet を通らない（WebKit が直接つなぐ）。LAN の保護は WebKit のルールとスクリプトで補うが、名前で LAN に向くものは防げない
    ・HTTP/2・HTTP/3・TLS 1.3・IPv6 は未対応（TLS 1.3 だけのサーバーは「標準の通信で開く」）
    ・標準の通信のタブは、全部 WebKit が処理する（通信の記録・広告ブロックの数は出ない）

    【受け入れたリスク】
    ・https の横取りに非公開の API を使う（WKWebView.handlesURLScheme の差し替え、_willPerformRedirection）。iOS が変わると動かなくなることがある。確かめていない iOS の版では使わず、失敗したら元に戻して標準の通信にする。設定の「VNet を使わない」で止められる
    ・TLS は SecureTransport（2019 年から非推奨・TLS 1.2 まで）を使っている
    ・サードパーティ Cookie は既定でブロックする。Safari の ITP や Storage Access API の例外は再現していない
    ・広告ブロックは、スクリプトを使う書き方・正規表現・$redirect などに対応しない
    ・Cookie の正本は WebKit の置き場。VNet は写しを使うので、ページの JavaScript が変えた直後は少し遅れることがある
    """
}
