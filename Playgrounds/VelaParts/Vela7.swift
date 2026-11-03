// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）
// VelaParts の 7 / 11。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）

import SwiftUI
import WebKit
import PhotosUI
import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit
import ObjectiveC
#if canImport(Compression)
import Compression
#endif
#if canImport(Security)
import Security
#endif

// ======================================================================
// MARK: - Persistence.swift
// ======================================================================

// MARK: - データのファイル（Application Support/Vela/ の JSON）
//
// タブ・ブックマーク・履歴などを Codable の JSON で置く。書き込みはまとめて（delay 秒後に 1 回）、裏のキューで、
// いったん別の名前に書いてから置き換える（.atomic。書いている途中で落ちても前のものが残る）

enum AppPaths {
    /// Application Support/Vela（取れなければ一時フォルダの Vela）。フォルダは作らない（作るのは使う側）
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
    }
}

final class JSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    /// 読み書きの失敗（開発者向けのログに出す）
    var log: (@Sendable (String) -> Void)?

    /// name: ファイルの名前（例: "tabs.json"）。directory を省くと Application Support/Vela/
    init(name: String, directory: URL? = nil, delay: TimeInterval = 1.0) {
        let dir = directory ?? JSONFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.delay = delay
        queue = DispatchQueue(label: "vela-json-\(name)")
    }

    static func defaultDirectory() -> URL { AppPaths.support }

    /// 読む（無い・壊れているなら nil。壊れていたファイルは .broken に名前を変えて残す）
    func load() -> Value? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: d)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を読めません（\(error)）。.broken として残します")
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return nil
        }
    }

    /// 保存する（delay 秒の間に何度呼んでも、書くのは最後の 1 回）
    func save(_ v: Value) {
        lock.lock()
        pending = v
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// 待っている分をすぐ書く（アプリが裏に回るときなど）。書き終わるまで待つ
    func saveNow(_ v: Value? = nil) {
        if let v { lock.lock(); pending = v; lock.unlock() }
        queue.sync { self.flush() }
    }

    private func flush() {
        lock.lock()
        let v = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let v else { return }
        do {
            let d = try JSONEncoder().encode(v)
            try d.write(to: url, options: .atomic)
        } catch {
            log?("⚠️ \(url.lastPathComponent) を書けません（\(error)）")
        }
    }
}

// MARK: - 設定（UserDefaults に置く）
//
// 通信まわりの設定は、アプリを起動し直したときに効く（WebView や通信の作りを、起動のときに決めるため）

enum VelaSettings {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: 通信（VNet）

    /// VNet を使わず、標準の通信（WebKit 内蔵）だけで読む
    static var vnetDisabled: Bool {
        get { bool("vnet.disabled", false) } set { d.set(newValue, forKey: "vnet.disabled") }
    }
    /// 確かめていない iOS の版でも、https の横取り（非公開 API）を試す
    static var allowUntestedOS: Bool {
        get { bool("vnet.allowUntestedOS", false) } set { d.set(newValue, forKey: "vnet.allowUntestedOS") }
    }
    /// 開発者向け: 横取りできないとき、標準の通信ではなく予備の vnets:// の作りを使う（安全ではない。CSP などを外すため）
    static var legacyVNetsFallback: Bool {
        get { bool("vnet.legacyVNets", false) } set { d.set(newValue, forKey: "vnet.legacyVNets") }
    }

    // MARK: 使い勝手

    /// 検索エンジン
    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "search.engine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "search.engine") }
    }
    /// HTTPS-First: ページを開く http:// を、まず https で試す（だめなら「http のまま開く」を出す）
    static var httpsFirst: Bool {
        get { bool("nav.httpsFirst", true) } set { d.set(newValue, forKey: "nav.httpsFirst") }
    }
    /// VNet でページを読めなかったら（TLS・つながらない など）、標準の通信に自動で切り替える
    static var autoFallbackToNative: Bool {
        get { bool("vnet.autoFallback", false) } set { d.set(newValue, forKey: "vnet.autoFallback") }
    }
    /// Mac の Safari の Web インスペクタからつなげるようにする（iOS 16.4 から）
    static var webInspector: Bool {
        get { bool("dev.webInspector", false) } set { d.set(newValue, forKey: "dev.webInspector") }
    }

    /// サイト（ホスト）ごとの文字の大きさ（100% のものは持たない）
    static func zoom(for host: String?) -> Double {
        guard let h = host?.lowercased(), let z = (d.dictionary(forKey: "zoom.sites") as? [String: Double])?[h] else { return 1.0 }
        return z
    }
    static func setZoom(_ z: Double, for host: String?) {
        guard let h = host?.lowercased(), !h.isEmpty else { return }
        var m = (d.dictionary(forKey: "zoom.sites") as? [String: Double]) ?? [:]
        m[h] = abs(z - 1.0) < 0.001 ? nil : z
        if m.count > 500 { m = [h: z] }      // 増えすぎたら覚え直す（めったに起きない）
        d.set(m, forKey: "zoom.sites")
    }

    // MARK: プライバシー・守り

    /// サードパーティ Cookie をブロックする
    static var blockThirdPartyCookies: Bool {
        get { bool("cookies.blockThirdParty", true) } set { d.set(newValue, forKey: "cookies.blockThirdParty") }
    }
    /// SameSite が無い Cookie を Lax として扱う
    static var cookiesLaxByDefault: Bool {
        get { bool("cookies.laxByDefault", true) } set { d.set(newValue, forKey: "cookies.laxByDefault") }
    }
    /// LAN の保護（公開のサイトから LAN の機器へ届かせない）
    static var localNetworkProtection: Bool {
        get { bool("lan.protection", true) } set { d.set(newValue, forKey: "lan.protection") }
    }

    /// 今の設定から作る Cookie の決まり
    static var cookiePolicy: CookiePolicy.Settings {
        var s = CookiePolicy.Settings()
        s.blockThirdParty = blockThirdPartyCookies
        s.laxByDefault = cookiesLaxByDefault
        return s
    }
}

// ======================================================================
// MARK: - DevLog.swift
// ======================================================================

// MARK: - 開発者向けのログ（どのスレッドからでも書ける）
//
// 1 行ずつ「時刻・重さ・種類・タブ・本文」を持って、最新 maxEntries 件まで覚える（古いものから消す）。
// 今までの log?("…") の文字列も、そのまま add で入れられる（先頭の記号から種類と重さを決める）。
// 画面へは、必要なときに entries(after:) で差分だけ取り出す（毎回全部を作り直すと重い）

enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug, info, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var mark: String {
        switch self { case .debug: return "·"; case .info: return " "; case .warning: return "⚠"; case .error: return "✕" }
    }
}

enum LogCategory: String, Sendable, CaseIterable {
    case app = "アプリ"
    case vnet = "VNet"
    case net = "通信"
    case nav = "移動"
    case cookie = "Cookie"
    case security = "守り"
    case block = "ブロック"
    case download = "ダウンロード"
    case js = "JS"
}

struct LogEntry: Sendable, Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let category: LogCategory
    /// どのタブのものか（タブに関係ないものは nil）
    let tab: Int?
    let message: String

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var line: String {
        "\(LogEntry.timeFormat.string(from: time)) \(level.mark) [\(category.rawValue)\(tab.map { "#\($0)" } ?? "")] \(message)"
    }
}

/// 開発者パネルの日時（端末の時刻で「2026-11-03 14:05」）。Cookie や HSTS の期限など、日付も要るもの用
enum DevDate {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func dateTime(_ d: Date, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        formatter.timeZone = timeZone
        return formatter.string(from: d)
    }
}

final class DevLog: @unchecked Sendable {
    static let maxEntries = 5000
    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var start = 0           // ring の中で一番古いものの位置（いっぱいになってから使う）
    private var nextID = 1
    private var dirty = false
    /// ログを書いた回数（重さごと。開発者パネル用。clear で 0 に戻す）
    private var counts: [LogLevel: Int] = [:]

    init() {}

    /// 今までの文字列のログ。先頭の記号などから種類と重さを決める
    func add(_ message: String, tab: Int? = nil) {
        let (level, category) = DevLog.classify(message)
        add(message, level: level, category: category, tab: tab)
    }

    func add(_ message: String, level: LogLevel, category: LogCategory, tab: Int? = nil) {
        lock.lock()
        let e = LogEntry(id: nextID, time: Date(), level: level, category: category, tab: tab, message: message)
        nextID += 1
        if ring.count < DevLog.maxEntries {
            ring.append(e)
        } else {
            ring[start] = e
            start = (start + 1) % DevLog.maxEntries
        }
        counts[level, default: 0] += 1
        dirty = true
        lock.unlock()
        // 落ちたときのために、すぐファイルにも書く（CrashLog.start の前は何もしない）
        CrashLog.writeLine(e.line)
    }

    /// 古い順に全部
    func all() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[start...] + ring[..<start])
    }

    /// id より新しいもの（古い順）。画面は最後に見た id を覚えておいて、差分だけもらう
    func entries(after id: Int) -> [LogEntry] {
        all().filter { $0.id > id }
    }

    func count(_ level: LogLevel) -> Int { lock.lock(); defer { lock.unlock() }; return counts[level] ?? 0 }

    /// 変わっていれば、最新 lines 行を 1 つの文字列にして返す（今の簡易のログ表示用）
    func take(lines: Int = 200) -> String? {
        lock.lock()
        if !dirty { lock.unlock(); return nil }
        dirty = false
        lock.unlock()
        return all().suffix(lines).map { $0.message }.joined(separator: "\n")
    }

    /// 書き出し用（共有・コピー）
    func export(minLevel: LogLevel = .debug) -> String {
        all().filter { $0.level >= minLevel }.map { $0.line }.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); ring = []; start = 0; counts = [:]; dirty = true; lock.unlock()
    }

    /// 文字列から種類と重さを決める（今までのログの書き方に合わせる）
    static func classify(_ m: String) -> (LogLevel, LogCategory) {
        let level: LogLevel = m.hasPrefix("✕") || m.contains("失敗") ? .error
            : m.hasPrefix("⚠") ? .warning : .info
        let category: LogCategory
        if m.hasPrefix("🍪") { category = .cookie }
        else if m.hasPrefix("🚫") { category = .block }
        else if m.hasPrefix("🛡") || m.hasPrefix("🔒") || m.contains("HSTS") || m.contains("横取り") { category = .security }
        else if m.hasPrefix("✓") || m.hasPrefix("✕") || m.hasPrefix("↪") || m.hasPrefix("――") { category = .net }
        else if m.hasPrefix("→") || m.hasPrefix("←") || m.contains("TLS") || m.contains("DHCP") || m.contains("カード")
                    || m.contains("[ネット]") || m.contains("TCP") { category = .vnet }
        else { category = .app }
        return (level, category)
    }
}

/// 開発者パネルのログ・通信のページの絞り込み（「このタブだけ」と「探す」）。Cookie のページは決まりが違うので使わない
struct DevQuery {
    let onlyThisTab: Bool
    /// 小文字にした「探す」の文字
    private let q: String

    init(onlyThisTab: Bool, query: String) {
        self.onlyThisTab = onlyThisTab
        q = query.lowercased()
    }

    /// 調べるときに選ばれているタブ（「このタブだけ」でなければ nil = 全部のタブ）
    func tab(selected: Int?) -> Int? { onlyThisTab ? selected : nil }

    /// 「探す」が空か、text（小文字にして）に含まれるか
    func matches(_ text: String) -> Bool { q.isEmpty || text.lowercased().contains(q) }
}

// ======================================================================
// MARK: - CrashLog.swift
// ======================================================================

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 落ちたときの記録（次に起動したときに、開発者パネルで見る）
//
// ・ログを 1 行ずつ、すぐファイルに書く（落ちる直前まで残るように。メモリのログは落ちると消える）
// ・Objective-C の例外（WebKit などが投げる）は、名前・理由・呼び出しの順をファイルに書く
// ・致命的なシグナル（Swift の強制終了・不正なメモリアクセスなど）は、番号・落ちたスレッド・呼び出しの順を書く
//   （シグナルの中ではほとんど何もできないので、用意しておいた文字と backtrace_symbols_fd で、ファイルに直接書くだけ）
// ・起動するたびに、前回の記録を crash-previous.txt に移す。前回が落ちて終わっていたら、ログに知らせる

/// シグナルの中から使うので、ファイルの番号は global に置く（Swift の static は初めて触るときに準備が走るので、シグナルの中では使わない）
private var crashFD: Int32 = -1
private let signalMessages: [Int32: [UInt8]] = {
    var m: [Int32: [UInt8]] = [:]
    for (s, name) in [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")] {
        m[s] = Array("\n【シグナル】\(name)（\(s)）でアプリが止まりました\n".utf8)
    }
    return m
}()
/// 呼び出しの順を入れる場所（シグナルの中では作れないので、先に用意する）
private let backtraceCapacity: Int32 = 64
private let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private let mainThreadText = Array("落ちたスレッド: 画面のスレッド（main）\n呼び出しの順:\n".utf8)
private let otherThreadText = Array("落ちたスレッド: 裏のスレッド（main 以外）\n呼び出しの順:\n".utf8)

// backtrace・backtrace_symbols_fd（C の execinfo.h）。iPad の Swift Playgrounds では Darwin から見えなかった
// （「cannot find 'backtrace' in scope」）ので、C の関数の名前で直接つなぐ。iOS・Linux の libc のどちらにもある
@_silgen_name("backtrace")
private func cBacktrace(_ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd")
private func cBacktraceSymbolsFD(_ buffer: UnsafePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)

/// 致命的なシグナルの受け口。シグナルの中なので、用意しておいたものを write で書くだけにする
private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        if let m = signalMessages[sig] { _ = m.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) } }
        #if canImport(Darwin)
        let isMain = pthread_main_np() != 0
        #else
        let isMain = false
        #endif
        let t = isMain ? mainThreadText : otherThreadText
        _ = t.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        let n = cBacktrace(backtraceBuffer, backtraceCapacity)
        cBacktraceSymbolsFD(backtraceBuffer, n, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashLog {
    private static let lock = NSLock()
    private static var written = 0
    static let maxBytes = 2 << 20
    static let exceptionMark = "【例外】"
    static let signalMark = "【シグナル】"

    static var folder: URL {
        let dir = AppPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var currentURL: URL { folder.appendingPathComponent("crash-current.txt") }
    static var previousURL: URL { folder.appendingPathComponent("crash-previous.txt") }

    /// 起動したときに 1 回。前回の記録を移して、新しいファイルを開き、例外とシグナルの受け口を入れる
    static func start() {
        lock.lock(); defer { lock.unlock() }
        if crashFD >= 0 { return }
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        if fm.fileExists(atPath: currentURL.path) { try? fm.moveItem(at: currentURL, to: previousURL) }
        crashFD = open(currentURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = (signalMessages, mainThreadText, otherThreadText, backtraceBuffer)     // シグナルの中で準備が走らないよう、先に作っておく
        #if canImport(Darwin)
        NSSetUncaughtExceptionHandler { e in CrashLog.recordException(e) }
        #endif
        _ = cBacktrace(backtraceBuffer, 1)     // 初めて呼ぶときの準備を、シグナルの中ではなくここで済ませておく
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(s, crashSignalHandler)
        }
        // ここはもう lock を持っているので、writeLine ではなく writeLineLocked（NSLock は 2 回取ると止まる）
        writeLineLocked("―― 起動 \(Date()) ――")
    }

    /// 1 行書く（DevLog から全部の行が来る）
    static func writeLine(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        writeLineLocked(s)
    }

    /// lock を持っているときに呼ぶ
    private static func writeLineLocked(_ s: String) {
        guard crashFD >= 0 else { return }
        let bytes = Array((s + "\n").utf8)
        if written + bytes.count > maxBytes {
            // 大きくなりすぎたら最初から（落ちる直前の分があればよい）
            _ = ftruncate(crashFD, 0)
            _ = lseek(crashFD, 0, SEEK_SET)
            written = 0
        }
        _ = bytes.withUnsafeBytes { write(crashFD, $0.baseAddress, $0.count) }
        written += bytes.count
    }

    #if canImport(Darwin)
    static func recordException(_ e: NSException) {
        var s = "\n\(exceptionMark)\(e.name.rawValue): \(e.reason ?? "（理由なし）")\n"
        s += e.callStackSymbols.prefix(40).joined(separator: "\n")
        writeLine(s)
    }
    #endif

    /// 前回の記録（最後の lines 行）。無ければ nil
    static func previous(lines: Int = 300) -> String? {
        guard let d = try? Data(contentsOf: previousURL), !d.isEmpty else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// 前回は落ちて終わったか（例外かシグナルの記録がある）。あれば、その行
    static func previousCrashSummary() -> String? {
        guard let p = previous(lines: 2000) else { return nil }
        let lines = p.split(separator: "\n")
        return lines.last { $0.contains(exceptionMark) || $0.contains(signalMark) }.map(String.init)
    }
}

// ======================================================================
// MARK: - VNetScheme.swift
// ======================================================================

// MARK: - WKWebView の読み込みを引き受けて、自作の通信（VNetMachine）で取ってくる
//
// https:// と http://（予備の作りでは vnets:// と vnet://）の読み込みが全部ここに来る。
// WebKit は画面のスレッドから呼ぶ。こちらも pending は画面のスレッドの上でだけ触る
//
// 守っていること（Sources/Policy/ の決まりを使う）:
// ・CORS はサーバーの答えをそのまま渡す（OPTIONS もサーバーに送る）。Vela が許可を作ることはしない
// ・CSP・X-Frame-Options などの守りのヘッダは消さない（予備の vnets:// の作りだけは、書き換えと合わないので外す）
// ・リダイレクトの次の要求は RedirectPolicy だけで作る（Authorization を別のオリジンへ持ち越さない・POST を二重に送らない）
// ・Cookie は CookieJar（WebKit の置き場の写し）と CookiePolicy。届いた Cookie は WebKit の置き場に入れてから、ページに返事を渡す
// ・HSTS: 記録があれば http を https に上げる。https の応答から記録する（HSTSPolicy の条件のときだけ）
// ・LAN の保護で「確認が必要」になった移動は、確認のページを出す（ユーザーが押したら、ユーザーの操作として開き直す）
// ・直接の作り（https をそのまま引き受ける）では、返事を流す形で渡す: ヘッダが来たら WebKit に返事を渡し、中身は届いた分ずつ渡す
//   （大きいファイル・動画でもメモリにためない。3xx は貯めて移動として渡す。vnets:// の作りは中身を書き換えるので貯める）

final class VNetScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var machine: VNetMachine?
    /// ログ（どのスレッドからでもよい）
    var log: (@Sendable (String) -> Void)?
    /// 届いた Cookie の変更をブラウザ（WebKit）の置き場に入れる。入れ終わったら done を呼ぶこと
    var pushCookies: (([CookieChange], _ done: @escaping @Sendable () -> Void) -> Void)?
    /// HSTS の記録（nil なら使わない）
    var hsts: HSTSStore?
    /// エラーページ・確認のページのボタンの合言葉（nonce）→ してほしいこと。
    /// ページは失敗した URL のオリジンで出すので、元の公開のページからは合言葉を読めない
    let actions = PageActions()
    /// HTTPS-First: ページを開く http:// を、まず https で試す（公開のホストだけ）
    var httpsFirst = true
    /// HTTPS-First で https がだめで、ユーザーが「http のまま開く」を選んだホスト
    var httpAllowedHosts = Set<String>()
    /// ページ本体の読み込みに失敗したとき（標準の通信へ自動で切り替えるかを、タブが決める）
    var onTopLevelFailure: ((URL, FetchError) -> Void)?
    /// VNet が自分でファイルに書くダウンロードを始めたとき（画面のスレッドで呼ぶ）。
    /// WebKit の WKDownload は使わない（VNetScheme が引き受けた読み込みを WebKit がダウンロードに変えると、アプリが落ちたため）
    var onDownloadStarted: ((VNetDownload) -> Void)?
    /// 通信の記録（開発者パネル）と、このタブの番号
    var netLog: NetLog?
    var tabID: Int?
    /// 広告ブロックの判定（nil なら調べない）。ページ本体は止めず、サブリソースだけを調べる
    var blocker: BlockEngineBox?
    /// 広告ブロックで止めたとき（画面のスレッドで呼ぶ）
    var onBlocked: ((URL, String) -> Void)?
    /// ダウンロードに変えた要求（WebKit の要求は 204 で終わらせ、中身はファイルに書く）
    private var downloadsInFlight: [Int: VNetDownload] = [:]

    /// 読み込み中の要求
    private struct Pending {
        let task: WKURLSchemeTask
        /// WebKit が頼んできたアドレス（vnets://… か https://…）。移動（リダイレクト）すると変わる
        var shownURL: URL
        /// 本当に読みに行くアドレス（https://…）
        var realURL: URL
        let started: Date
        /// WebKit からの要求（移動のときに、次の要求を作るのに使う）
        var request: URLRequest
        var body: Data?
        var redirects = 0
        /// 移動（3xx）を WebKit に伝えられるか。できないときは、自分で追いかけて最後の返事だけ渡す
        var webKitRedirects: Bool
        /// 要求の文脈（Cookie・LAN・HSTS の判定）
        var context: RequestContext
        /// 取り消しの印（WebKit がやめたら、裏の通信も止める）
        let token = RequestToken()
        /// 予備の vnets:// の作りの要求か
        var vnetsMode: Bool { VNetURL.isVNet(shownURL) }
        /// 流す形の様子: none（まだ・貯める形）→ pushing（Cookie を WebKit に入れている）→ sending（中身を渡している）
        var streamPhase = StreamPhase.none
        /// sending になる前に届いた中身
        var streamQueue: [Data] = []
        /// sending になる前に読み終わった（失敗した）
        var streamDone: Result<HTTPResult, FetchError>?
        var streamBytes = 0
        /// HTTPS-First で https に上げた元の http の URL（https で失敗したら「http のまま開く」を出す）
        var httpsFirstFrom: URL?
        /// 自分で作った移動（HSTS・HTTPS-First）を WebKit に伝えている途中
        var syntheticRedirect = false
        /// 通信の記録の番号（0 なら記録していない）
        var logID = 0
    }
    private enum StreamPhase { case none, pushing, sending }
    /// 読み込み中の要求（番号 → 要求）。番号は要求ごとに 1 つずつ増やす（使い回さない）。
    /// WebKit の要求のアドレス（ObjectIdentifier）で引くと、止めた要求のアドレスを次の要求が使い回したときに、
    /// 前の要求の遅れて届いた返事が新しい要求に渡ってしまい、WebKit が例外を出して落ちた
    private var pending: [Int: Pending] = [:]
    /// WebKit の要求 → 番号（stop で引く。使い回されたアドレスかどうかは task が同じものかで確かめる）
    private var taskIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    /// ユーザーがアドレス欄などから開いた URL（1 回だけ使える印。ページのリンクや JavaScript の移動と見分ける）
    private var userNavigation: (url: URL, at: Date)?

    /// アプリが load() する直前に呼ぶ（画面のスレッドから）
    func noteUserNavigation(_ url: URL) {
        userNavigation = (VNetURL.toReal(url) ?? url, Date())
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        start(task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 裏の通信も止める（待ち行列から外す・読んでいる途中の接続は切る）
        let key = ObjectIdentifier(task)
        guard let id = taskIDs[key], let p = pending[id], (p.task as AnyObject) === (task as AnyObject) else { return }
        taskIDs[key] = nil
        pending[id] = nil
        p.token.cancel()
        netLog?.finish(p.logID, outcome: .cancelled)
    }

    private func start(_ task: WKURLSchemeTask) {
        guard let shown = task.request.url, let real = VNetURL.toReal(shown), let machine else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let body = VNetScheme.body(of: task.request)
        let ctx = context(for: task.request, real: real)
        let types = BlockEngine.guessTypes(url: real, accept: task.request.value(forHTTPHeaderField: "Accept"), isTopLevel: ctx.isTopLevel)
        let logID = netLog?.begin(tab: tabID, method: task.request.httpMethod ?? "GET", url: real.absoluteString,
                                  kind: VNetScheme.kindLabel(types), topLevel: ctx.isTopLevel) ?? 0
        // 広告ブロック（サブリソースだけ）。止めたものは通信しない
        if !ctx.isTopLevel, let blocker {
            if let d = blocker.match(url: real, types: types, sourceHost: ctx.initiator?.host ?? ctx.topURL?.host, topHost: ctx.topURL?.host) {
                log?("🚫 広告ブロック: \(real.absoluteString)（\(d.rule)）")
                netLog?.finish(logID, outcome: .blocked(d.rule))
                onBlocked?(real, d.rule)
                task.didFailWithError(NSError(domain: "VelaAdBlock", code: 1, userInfo: [NSLocalizedDescriptionKey: "広告ブロックで止めました"]))
                return
            }
        }
        let id = nextID
        nextID += 1
        // 終わった要求の分は、ときどきまとめて消す（増え続けないように）
        if taskIDs.count > 256 { taskIDs = taskIDs.filter { pending[$0.value] != nil || downloadsInFlight[$0.value] != nil } }
        taskIDs[ObjectIdentifier(task)] = id
        let webKitRedirects = SchemeTaskRedirect.isAvailable(task)
        var p = Pending(task: task, shownURL: shown, realURL: real, started: Date(), request: task.request, body: body,
                        webKitRedirects: webKitRedirects, context: ctx)
        p.logID = logID
        if ctx.userInitiated { netLog?.note(logID, "ユーザーの操作で開いた") }
        if let i = ctx.initiator, !ctx.isTopLevel, let top = ctx.topURL,
           SiteUtil.registrableDomain(i.host ?? "") != SiteUtil.registrableDomain(top.host ?? "") {
            netLog?.note(logID, "読み込んだのは別のサイト: \(i.host ?? "")")
        }
        pending[id] = p
        // HSTS・HTTPS-First: http を https に上げてから読む（WebKit にも移動として伝える）
        if let (up, reason) = upgradeTarget(real, ctx: ctx) {
            log?("🔒 \(reason): \(real.absoluteString) → https")
            netLog?.note(logID, "🔒 \(reason): https に上げた")
            if reason == "HTTPS-First" { p.httpsFirstFrom = real }
            if webKitRedirects {
                p.syntheticRedirect = true
                pending[id] = p
                let next = RedirectPolicy.Next(url: up, method: task.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(task.request),
                                               body: body, crossOrigin: true, upgradedByHSTS: true, dropped: [])
                redirect(id, p, status: 307, serverHeaders: [("Non-Authoritative-Reason", reason)], type: "text/plain", next: next)
                return
            }
            p.realURL = up
            p.context = ctx.redirected(from: real, to: up)
            pending[id] = p
            fetch(id, makeRequest(task.request, url: up, body: body, ctx: p.context), followRedirects: true, machine: machine)
            return
        }
        fetch(id, makeRequest(task.request, url: real, body: body, ctx: ctx), followRedirects: !webKitRedirects, machine: machine)
    }

    /// http を https に上げるか（HSTS の記録がある・HTTPS-First）。上げるなら (https の URL, 理由)
    private func upgradeTarget(_ real: URL, ctx: RequestContext) -> (URL, String)? {
        guard real.scheme?.lowercased() == "http", let h = SiteUtil.host(of: real),
              var c = URLComponents(url: real, resolvingAgainstBaseURL: false) else { return nil }
        let reason: String
        if hsts?.shouldUpgrade(h) == true {
            reason = "HSTS"
        } else if httpsFirst && ctx.isTopLevel && HTTPSFirst.eligible(host: h, port: c.port, allowed: httpAllowedHosts) {
            // 公開の名前のホストだけ（LAN・数字のアドレス・ポート指定は、https が無いことが多いので上げない）
            reason = "HTTPS-First"
        } else {
            return nil
        }
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        guard let up = c.url else { return nil }
        return (up, reason)
    }

    private func fetch(_ id: Int, _ req: HTTPRequest, followRedirects: Bool, machine: VNetMachine) {
        var req = req
        req.token = pending[id]?.token
        // 直接の作りでは、流す形で受け取る（3xx は貯めて、移動として渡す・追いかける）
        if let p = pending[id], !p.vnetsMode {
            req.sink = StreamSink(shouldStream: { status, _ in !RedirectPolicy.statuses.contains(status) },
                                  onHead: { [weak self] h in
                                      let me = self
                                      DispatchQueue.main.async { me?.streamHead(id, h) }
                                  },
                                  onData: { [weak self] d in
                                      let me = self
                                      DispatchQueue.main.async { me?.streamData(id, d) }
                                  })
        }
        machine.send(req, followRedirects: followRedirects) { [weak self] result in
            let me = self   // weak の self は var なので、並行で動く閉包からは直接さわれない。let に受け直す
            DispatchQueue.main.async { me?.finish(id, result) }
        }
    }

    private func finish(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        if let dl = downloadsInFlight.removeValue(forKey: id) {
            switch result {
            case .success: dl.finish()
            case .failure(let e): if e.kind != .cancelled { dl.fail(e.description) }
            }
            return
        }
        guard var p = pending[id] else { return }
        // 流す形で返事をもう渡し始めている: 終わりを伝える（まだ Cookie を入れている途中なら、渡し始めてから）
        if p.streamPhase != .none {
            if p.streamPhase == .sending { endStream(id, result) } else { p.streamDone = result; pending[id] = p }
            return
        }
        // Cookie が届いていたら、先にブラウザの置き場に入れてから返事を渡す（ページがすぐ document.cookie を読んでも間に合うように）
        if case .success(let r) = result, !r.cookieChanges.isEmpty, let pushCookies {
            pushCookies(r.cookieChanges) { [weak self] in
                let me = self
                DispatchQueue.main.async { me?.complete(id, result) }
            }
            return
        }
        complete(id, result)
    }

    /// 返事を WebKit に渡す（途中で止められていたら何もしない）
    private func complete(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        guard let p = pending[id] else { return }
        if case .success(let r) = result, let sts = r.header("Strict-Transport-Security") {
            hsts?.record(header: sts, url: r.url, ctx: p.context)
            netLog?.note(p.logID, "HSTS の指定: \(sts)")
        }
        if case .success(let r) = result, !r.cookieChanges.isEmpty {
            netLog?.note(p.logID, "🍪 Cookie を \(r.cookieChanges.count) 個保存・変更")
        }
        // 移動（3xx）: WebKit に「移動した」と伝える（アドレス・相対リンク・オリジン・クッキーが移動先のものになる）
        if case .success(let r) = result, p.webKitRedirects, RedirectPolicy.statuses.contains(r.status) {
            let hsts = self.hsts
            switch RedirectPolicy.next(from: p.realURL, method: p.request.httpMethod ?? "GET", headers: VNetScheme.headerPairs(p.request),
                                       body: p.body, status: r.status, location: r.header("Location"), redirectCount: p.redirects,
                                       hsts: { hsts?.shouldUpgrade($0) ?? false }) {
            case .success(let next):
                redirect(id, p, status: r.status, serverHeaders: r.headers, type: VNetScheme.contentType(r, real: p.realURL), next: next)
                return
            case .failure(.tooMany):
                pending[id] = nil
                fail(p, FetchError("リダイレクトが多すぎます", kind: .redirect))
                return
            case .failure(let f):
                log?("↪ \(r.status) を追いかけません（\(f)）。そのまま渡します")
            }
        }
        pending[id] = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        let real = p.realURL
        switch result {
        case .failure(let e):
            fail(p, e)
        case .success(let r):
            let range = r.header("Content-Range").map { "・\($0)" } ?? ""
            log?("✓ \(r.status) \(r.url.absoluteString)（\(r.body.count / 1024)KB・\(ms)ms\(range)）")
            netLog?.finish(p.logID, outcome: .ok, status: r.status, bytes: r.body.count)
            var type = VNetScheme.contentType(r, real: real)
            var body = r.body
            // vnets:// の作りのときだけ: HTML と CSS の中の https:// を vnets:// に書き換える（部品も自作の通信で読むため）
            // （https をそのまま引き受けているときは、書き換えなくても全部ここに来る）
            let lower = type.lowercased()
            if p.vnetsMode && (lower.contains("text/html") || lower.contains("text/css")) {
                body = VNetScheme.rewriteLinks(body)
                if !lower.contains("charset") { type += "; charset=utf-8" }
            }
            // 自分で追いかけた移動の先のアドレスで表示する（相対アドレスがずれないように）
            let shownReal = VNetURL.toReal(p.shownURL) ?? p.shownURL
            let shown = r.url == shownReal ? p.shownURL : (p.vnetsMode ? (VNetURL.toVNet(r.url) ?? p.shownURL) : r.url)
            respond(p.task, url: shown, status: r.status, type: type, body: body, vnetsMode: p.vnetsMode, extra: r.headers)
        }
    }

    // MARK: 流す形

    /// 流す形の返事のヘッダが来た: Cookie を WebKit の置き場に入れてから、返事を渡す
    private func streamHead(_ id: Int, _ h: HTTPHead) {
        guard var p = pending[id] else { return }
        // ページ本体の返事がダウンロード（添付ファイル・表示できない種類）なら、WebKit には渡さずにファイルに書く
        if p.context.isTopLevel, onDownloadStarted != nil, DownloadFiles.isDownload(status: h.status, headers: h.headers),
           let dl = makeDownload(h) {
            let token = p.token
            dl.cancelAction = { token.cancel() }
            downloadsInFlight[id] = dl
            pending[id] = nil
            if !h.cookieChanges.isEmpty { pushCookies?(h.cookieChanges) {} }
            // ページはそのまま（204 No Content は「移動しない」）
            if let resp = VNetScheme.response(url: p.shownURL, status: 204, headers: ["Content-Type": "text/plain", "Content-Length": "0"]) {
                p.task.didReceive(resp)
                p.task.didFinish()
            }
            log?("⬇︎ ダウンロードにします: \(h.url.absoluteString) → \(dl.fileURL.lastPathComponent)")
            netLog?.finish(p.logID, outcome: .download, status: h.status)
            onDownloadStarted?(dl)
            return
        }
        p.streamPhase = .pushing
        pending[id] = p
        netLog?.update(p.logID) { $0.status = h.status }
        if !h.cookieChanges.isEmpty { netLog?.note(p.logID, "🍪 Cookie を \(h.cookieChanges.count) 個保存・変更") }
        if let sts = h.header("Strict-Transport-Security") {
            hsts?.record(header: sts, url: h.url, ctx: p.context)
            netLog?.note(p.logID, "HSTS の指定: \(sts)")
        }
        if !h.cookieChanges.isEmpty, let pushCookies {
            pushCookies(h.cookieChanges) { [weak self] in
                let me = self
                DispatchQueue.main.async { me?.startSending(id, h) }
            }
        } else {
            startSending(id, h)
        }
    }

    /// ダウンロードのファイルを作る
    private static func download(for h: HTTPHead) -> VNetDownload? {
        let name = DownloadFiles.filename(contentDisposition: h.header("Content-Disposition"), url: h.url, mime: h.header("Content-Type"))
        let expected = h.header("Content-Length").flatMap { Int64($0) } ?? -1
        return VNetDownload(source: h.url, suggestedName: name, expected: expected)
    }

    private func makeDownload(_ h: HTTPHead) -> VNetDownload? { VNetScheme.download(for: h) }

    /// URL をダウンロードする（<a download> のリンク・やり直しなど。WebKit を通さずに VNet で読んでファイルに書く）
    func startDownload(url: URL, referer: URL?) {
        guard let machine else { return }
        var r = URLRequest(url: url)
        if let referer { r.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        var ctx = RequestContext(topURL: url, isTopLevel: true, initiator: referer)
        ctx.userInitiated = true
        var req = makeRequest(r, url: url, body: nil, ctx: ctx)
        let token = RequestToken()
        req.token = token
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var download: VNetDownload?
            var status = 0
        }
        let box = Box()
        let started: (VNetDownload, [CookieChange]) -> Void = { [weak self] dl, changes in
            let me = self
            DispatchQueue.main.async {
                if !changes.isEmpty { me?.pushCookies?(changes) {} }
                me?.onDownloadStarted?(dl)
            }
        }
        req.sink = StreamSink(shouldStream: { status, _ in !RedirectPolicy.statuses.contains(status) },
                              onHead: { h in
                                  guard let dl = VNetScheme.download(for: h) else { return }
                                  dl.cancelAction = { token.cancel() }
                                  box.lock.lock(); box.download = dl; box.status = h.status; box.lock.unlock()
                                  started(dl, h.cookieChanges)
                              },
                              onData: { d in
                                  box.lock.lock(); let dl = box.download; box.lock.unlock()
                                  dl?.write(d)
                              })
        let lg = log
        lg?("⬇︎ VNet でダウンロードします: \(url.absoluteString)")
        machine.send(req, followRedirects: true) { result in
            box.lock.lock(); var dl = box.download; let status = box.status; box.lock.unlock()
            switch result {
            case .success(let r):
                // 流す形にならなかった（縮め方が流せないなど）: 貯めた中身をまとめて書く
                if dl == nil, let made = VNetScheme.download(for: HTTPHead(status: r.status, headers: r.headers, url: r.url, cookieChanges: r.cookieChanges)) {
                    made.cancelAction = { token.cancel() }
                    made.write(r.body)
                    dl = made
                    started(made, r.cookieChanges)
                }
                let code = r.streamed ? status : r.status
                if (200...299).contains(code) { dl?.finish() } else { dl?.fail("サーバーの返事 \(code)") }
            case .failure(let e):
                if e.kind != .cancelled { dl?.fail(e.description) }
                lg?("⬇︎✕ ダウンロード失敗: \(url.absoluteString)：\(e.description)")
            }
        }
    }

    private func startSending(_ id: Int, _ h: HTTPHead) {
        guard var p = pending[id] else { return }
        let shownReal = VNetURL.toReal(p.shownURL) ?? p.shownURL
        let shown = h.url == shownReal ? p.shownURL : h.url
        let type = VNetScheme.contentType(headers: h.headers, real: h.url)
        let length = h.header("Content-Length").flatMap { Int($0) }
        let headers = VNetScheme.responseHeaders(type: type, length: length, vnetsMode: false, extra: h.headers)
        guard let resp = VNetScheme.response(url: shown, status: h.status, headers: headers) else {
            pending[id] = nil
            p.task.didFailWithError(URLError(.badServerResponse))
            return
        }
        p.task.didReceive(resp)
        p.streamPhase = .sending
        let queued = p.streamQueue
        p.streamQueue = []
        for d in queued { p.task.didReceive(d); p.streamBytes += d.count }
        let done = p.streamDone
        pending[id] = p
        if let done { endStream(id, done) }
    }

    private func streamData(_ id: Int, _ d: Data) {
        if let dl = downloadsInFlight[id] { dl.write(d); return }
        guard var p = pending[id] else { return }
        if p.streamPhase == .sending {
            p.task.didReceive(d)
            p.streamBytes += d.count
        } else {
            p.streamQueue.append(d)
        }
        pending[id] = p
    }

    private func endStream(_ id: Int, _ result: Result<HTTPResult, FetchError>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        switch result {
        case .success(let r):
            log?("✓ \(r.status) \(r.url.absoluteString)（\(p.streamBytes / 1024)KB・\(ms)ms・流す形）")
            netLog?.finish(p.logID, outcome: .ok, status: r.status, bytes: p.streamBytes)
            // リダイレクトの途中で届いた Cookie もあれば、WebKit の置き場に入れておく（同じものを入れ直しても害は無い）
            if !r.cookieChanges.isEmpty { pushCookies?(r.cookieChanges) {} }
            p.task.didFinish()
        case .failure(let e):
            log?("✕ \(p.realURL.absoluteString)：途中で失敗（\(p.streamBytes / 1024)KB まで）：\(e.description)")
            netLog?.finish(p.logID, outcome: .failed("途中で失敗: \(e.description)"), bytes: p.streamBytes)
            p.task.didFailWithError(URLError(e.kind == .timeout ? .timedOut : .networkConnectionLost))
        }
    }

    /// 失敗をページにする（説明と、できることのボタン。LAN への移動なら確認のページ）
    private func fail(_ p: Pending, _ e: FetchError) {
        let real = p.realURL
        log?("✕ \(real.absoluteString)：\(e.description)")
        netLog?.finish(p.logID, outcome: e.kind == .cancelled ? .cancelled : .failed("\(e.kind.rawValue): \(e.description)"))
        let html: String
        if e.kind == .localNetworkConsent && p.context.isTopLevel {
            html = ErrorPage.html(title: "LAN の機器を開きますか？", lines: [
                "ページが、LAN（家や会社の中のネットワーク）にある次のアドレスへ移動しようとしています。",
                real.absoluteString, "心当たりがなければ開かないでください。"],
                detail: e.description,
                buttons: [ErrorPage.Button(label: "開く", nonce: actions.make("allowLocalNetwork", url: real), primary: false)],
                kind: e.kind.rawValue)
        } else if let http = p.httpsFirstFrom, p.context.isTopLevel, e.kind != .blocked {
            html = ErrorPage.httpsFirst(http: http, failing: real, message: e.description, actions: actions)
        } else {
            let d = ErrorPage.describe(e)
            var buttons = [ErrorPage.Button(label: "再試行", nonce: actions.make("retry", url: real), primary: true)]
            if d.offerNative && p.context.isTopLevel {
                buttons.append(ErrorPage.Button(label: "標準の通信で開く", nonce: actions.make("openNative", url: real), primary: false))
            }
            html = ErrorPage.html(title: d.title, lines: [d.hint, real.absoluteString], detail: e.description, buttons: buttons, kind: e.kind.rawValue)
        }
        respond(p.task, url: p.shownURL, status: 502, type: "text/html; charset=utf-8", body: Data(html.utf8), vnetsMode: p.vnetsMode)
        if p.context.isTopLevel, let cb = onTopLevelFailure {
            let u = p.httpsFirstFrom ?? real
            DispatchQueue.main.async { cb(u, e) }
        }
    }

    // MARK: 移動（リダイレクト）

    /// 3xx を WebKit に伝える。WebKit が次の要求を返してきたら、それを読みに行く
    private func redirect(_ id: Int, _ p: Pending, status: Int, serverHeaders: [(String, String)], type: String, next: RedirectPolicy.Next) {
        let nextShown = p.vnetsMode ? (VNetURL.toVNet(next.url) ?? next.url) : next.url
        let dropped = next.dropped.isEmpty ? "" : "（外したヘッダ: \(next.dropped.joined(separator: ", "))）"
        log?("↪ \(status) \(p.realURL.absoluteString) → \(next.url.absoluteString)\(dropped)")
        netLog?.note(p.logID, "↪ \(status) → \(next.url.absoluteString)\(dropped)")
        var h = VNetScheme.responseHeaders(type: type, length: 0, vnetsMode: p.vnetsMode, extra: serverHeaders)
        h["Location"] = nextShown.absoluteString
        let nr = NSMutableURLRequest(url: nextShown)
        nr.httpMethod = next.method
        var fields: [String: String] = [:]
        for (k, v) in next.headers { fields[k] = v }
        nr.allHTTPHeaderFields = fields
        nr.httpBody = next.body
        nr.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? nextShown : p.request.mainDocumentURL
        let body = next.body
        guard let resp = VNetScheme.response(url: p.shownURL, status: status, headers: h),
              SchemeTaskRedirect.perform(p.task, response: resp, request: nr, done: { [weak self] newReq in
                  let me = self
                  DispatchQueue.main.async { me?.afterRedirect(id, newReq, body: body) }
              }) else {
            // 伝えられなかった: 受け取った 3xx から作った次の要求を、自分で追いかける（元の要求は送り直さない。POST を二重に送らないため）
            guard var q = pending[id], let machine else { return }
            q.webKitRedirects = false
            q.context = q.context.redirected(from: q.realURL, to: next.url)
            q.realURL = next.url
            q.redirects += 1
            pending[id] = q
            var r = URLRequest(url: next.url)
            r.httpMethod = next.method
            r.allHTTPHeaderFields = fields
            r.mainDocumentURL = p.request.mainDocumentURL == p.shownURL ? next.url : p.request.mainDocumentURL.flatMap { VNetURL.toReal($0) }
            r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
            fetch(id, makeRequest(r, url: next.url, body: next.body, ctx: q.context), followRedirects: true, machine: machine)
            return
        }
    }

    /// WebKit が移動を受け入れた（newReq が次の要求）。nil なら WebKit がやめた（このあと stop が来る）
    private func afterRedirect(_ id: Int, _ newReq: NSURLRequest?, body: Data?) {
        guard var p = pending[id] else { return }
        guard let newReq, let u = newReq.url, let real = VNetURL.toReal(u), let machine else {
            pending[id] = nil
            return
        }
        var r = URLRequest(url: u)
        r.httpMethod = newReq.httpMethod
        r.allHTTPHeaderFields = newReq.allHTTPHeaderFields
        r.mainDocumentURL = newReq.mainDocumentURL
        r.httpShouldHandleCookies = p.request.httpShouldHandleCookies
        let b = newReq.httpBody ?? body
        // サーバーの移動なら、HTTPS-First の「http のまま開く」は出さない（自分で作った移動のときだけ残す）
        if p.syntheticRedirect { p.syntheticRedirect = false } else { p.httpsFirstFrom = nil }
        p.context = p.context.redirected(from: p.realURL, to: real)
        p.shownURL = u
        p.realURL = real
        p.request = r
        p.body = b
        p.redirects += 1
        pending[id] = p
        fetch(id, makeRequest(r, url: real, body: b, ctx: p.context), followRedirects: false, machine: machine)
    }

    // MARK: 要求を作る

    /// WebKit の要求から、文脈（トップのページ・トップレベルの移動か・どこから来たか・ユーザーの操作か）を作る
    private func context(for r: URLRequest, real: URL) -> RequestContext {
        let top = r.mainDocumentURL.flatMap { VNetURL.toReal($0) }
        let isTop = r.mainDocumentURL != nil && r.mainDocumentURL == r.url
        // どこから来たか: Referer。無ければ Origin（Referrer-Policy: no-referrer でも、POST には Origin が付く。"null" は分からない扱い）
        let referer = r.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) }
        let originHeader = r.value(forHTTPHeaderField: "Origin").flatMap { $0 == "null" ? nil : URL(string: $0) }
        let initiator = (referer ?? originHeader).flatMap { VNetURL.toReal($0) }
        var ctx = RequestContext(topURL: top, isTopLevel: isTop, initiator: initiator)
        ctx.cookiesAllowed = r.httpShouldHandleCookies
        // 実機で確かめること: WebKit がスキームハンダの要求に httpShouldHandleCookies を正しく入れてくるか（ページ本体で false なら怪しい）
        if isTop && !r.httpShouldHandleCookies { log?("🍪 ページ本体の要求が httpShouldHandleCookies=false です（\(real.absoluteString)）") }
        if isTop, let u = userNavigation, Date().timeIntervalSince(u.at) < 15, VNetScheme.sameIgnoringFragment(u.url, real) {
            ctx.userInitiated = true
            userNavigation = nil
        }
        return ctx
    }

    static func sameIgnoringFragment(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false), cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil; cb?.fragment = nil
        return ca?.url?.absoluteString == cb?.url?.absoluteString
    }

    /// URLRequest のヘッダを（名前, 値）の並びにする
    static func headerPairs(_ r: URLRequest) -> [(String, String)] {
        (r.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) }
    }

    /// WebKit の要求を、自作の通信の要求にする
    func makeRequest(_ r: URLRequest, url: URL, body: Data?, ctx: RequestContext) -> HTTPRequest {
        var req = VNetScheme.makeRequest(r, url: url, body: body)
        req.context = ctx
        return req
    }

    /// WebKit の要求を、自作の通信の要求にする（ヘッダの変換だけ。文脈は makeRequest(_:url:body:ctx:) で付ける）
    static func makeRequest(_ r: URLRequest, url: URL, body: Data?) -> HTTPRequest {
        var req = HTTPRequest(url: url)
        req.method = r.httpMethod ?? "GET"
        for (k, v) in r.allHTTPHeaderFields ?? [:] {
            switch k.lowercased() {
            case "origin", "referer":
                // vnets://… なら https://… に戻して送る（https://… ならそのまま）
                if v.lowercased().hasPrefix("vnet"), let u = URL(string: v), let real = VNetURL.toReal(u) {
                    let s = real.absoluteString
                    req.headers.append((k, k.lowercased() == "origin" ? s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : s))
                } else if v.lowercased().hasPrefix("http") {
                    req.headers.append((k, v))
                }
            case "range":
                // 「最後まで全部」は、少しずつ（2MB ずつ）にする。動画を丸ごと読み終わるまで待たないように
                req.headers.append((k, clampRange(v) ?? v))
            default:
                req.headers.append((k, v))
            }
        }
        req.body = body
        // ページを開く要求（ページ本体）に Sec-Fetch-* が無ければ付ける（Safari は必ず付ける。無いとロボットだと思われやすい）
        if req.headers.value(for: "Sec-Fetch-Dest") == nil, let main = r.mainDocumentURL, main == r.url {
            var site = "none"
            if let ref = req.headers.value(for: "Referer").flatMap({ URL(string: $0) }), let rh = ref.host?.lowercased(),
               let h = url.host?.lowercased() {
                if ref.scheme?.lowercased() == url.scheme?.lowercased() && rh == h && ref.port == url.port { site = "same-origin" }
                else { site = siteOf(rh) == siteOf(h) ? "same-site" : "cross-site" }
            }
            req.headers += [("Sec-Fetch-Site", site), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")]
            if req.headers.value(for: "Upgrade-Insecure-Requests") == nil { req.headers.append(("Upgrade-Insecure-Requests", "1")) }
        }
        return req
    }

    /// 「サイト」（example.co.jp → example.co.jp、www.example.com → example.com）
    static func siteOf(_ host: String) -> String { SiteUtil.registrableDomain(host) }

    static func body(of r: URLRequest) -> Data? {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return nil }
        var d = Data()
        s.open()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        s.close()
        return d
    }

    /// 1 回に読む大きさ（動画の Range）
    static let rangeChunk = 2 << 20

    /// "bytes=a-"（最後まで）や、大きすぎる "bytes=a-b" を "bytes=a-(a+2MB-1)" に直す。直さなくて良いときは nil
    static func clampRange(_ v: String) -> String? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("bytes="), !s.contains(",") else { return nil }
        let parts = s.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let maxEnd = a + rangeChunk - 1
        if let b = Int(parts[1].trimmingCharacters(in: .whitespaces)), b <= maxEnd { return nil }
        return "bytes=\(a)-\(maxEnd)"
    }

    // MARK: 返事を作る

    /// 拡張子から動画・音声の種類を決める
    static let mediaTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
                                               "webm": "video/webm", "mp3": "audio/mpeg", "m4a": "audio/mp4",
                                               "aac": "audio/aac", "wav": "audio/wav", "m3u8": "application/vnd.apple.mpegurl",
                                               "ts": "video/mp2t"]

    /// Content-Type。種類が書いていない動画・音声は、拡張子から決める（でないと再生できない）
    /// 記録に出す種類の名前
    static func kindLabel(_ t: Set<ResourceType>) -> String {
        if t.count > 1 { return "その他" }
        switch t.first {
        case .document?: return "ページ"
        case .subdocument?: return "フレーム"
        case .script?: return "スクリプト"
        case .image?: return "画像"
        case .stylesheet?: return "CSS"
        case .font?: return "フォント"
        case .media?: return "動画・音声"
        case .xhr?: return "XHR"
        default: return "その他"
        }
    }

    static func contentType(_ r: HTTPResult, real: URL) -> String {
        contentType(headers: r.headers, real: real)
    }

    static func contentType(headers: [(String, String)], real: URL) -> String {
        let type = headers.value(for: "Content-Type") ?? "application/octet-stream"
        let lower = type.lowercased()
        if lower.hasPrefix("application/octet-stream") || lower.hasPrefix("binary/"),
           let guess = mediaTypes[real.pathExtension.lowercased()] {
            return guess
        }
        return type
    }

    /// HTML・CSS の中の https:// を vnets://（http:// を vnet://）に書き換える
    static func rewriteLinks(_ body: Data) -> Data {
        var s = String(decoding: body, as: UTF8.self)
        for (from, to) in [("https://", "vnets://"), ("http://", "vnet://"), ("https:\\/\\/", "vnets:\\/\\/")] {
            for q in ["\"", "'", "(", "=", " "] { s = s.replacingOccurrences(of: q + from, with: q + to) }
        }
        return Data(s.utf8)
    }

    /// 相手の返事のヘッダのうち、WebKit にそのまま渡さないもの（長さ・縮め方は自分で決め直す。Cookie は CookieJar 経由で WebKit の置き場に入れる）
    static let dropHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "content-type", "connection",
                                           "keep-alive", "set-cookie", "set-cookie2", "alt-svc", "location"]
    /// 予備の vnets:// の作りのときだけ外すもの（アドレスを書き換えるので、ページの守りの決まりと合わない。この作りは開発者向けの実験で、安全ではない）
    static let vnetsOnlyDropHeaders: Set<String> = ["content-security-policy", "content-security-policy-report-only", "x-frame-options"]

    /// 返事のヘッダ: 相手のヘッダ（CSP・X-Frame-Options・動画に要る Content-Range など）＋ 長さ・種類。
    /// CORS（Access-Control-*）はサーバーの答えをそのまま渡す（CORSPassthrough）。Vela が許可を足すことはしない
    /// length が nil なら Content-Length を付けない（流す形で、長さが分からないとき）
    static func responseHeaders(type: String, length: Int?, vnetsMode: Bool, extra: [(String, String)]) -> [String: String] {
        var h: [String: String] = [:]
        var names: [String: String] = [:]      // 小文字の名前 → h での名前（同じ名前が何行もあれば「, 」でつなぐ）
        func add(_ k: String, _ v: String) {
            let lk = k.lowercased()
            if let ek = names[lk], let old = h[ek] { h[ek] = old + ", " + v } else { names[lk] = k; h[k] = v }
        }
        for (k, v) in extra {
            let lk = k.lowercased()
            if dropHeaders.contains(lk) || lk.hasPrefix("access-control-") { continue }
            if vnetsMode && vnetsOnlyDropHeaders.contains(lk) { continue }
            add(k, v)
        }
        for (k, v) in CORSPassthrough.headers(extra, vnetsMode: vnetsMode) { add(k, v) }
        h["Content-Type"] = type
        if let length { h["Content-Length"] = String(length) }
        return h
    }

    /// WebKit に渡す返事の見出し（いつも HTTP/1.1 として渡す）
    static func response(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data, vnetsMode: Bool, extra: [(String, String)] = []) {
        let h = VNetScheme.responseHeaders(type: type, length: body.count, vnetsMode: vnetsMode, extra: extra)
        let resp = VNetScheme.response(url: url, status: status, headers: h)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

// ======================================================================
// MARK: - HTTPSTakeover.swift
// ======================================================================

// MARK: - WKWebView の https・http の読み込みを、アプリが引き受けるための仕掛け

/// WKWebView に「https・http も自分で引き受けます」と言えるようにする
///
/// 普通は https を setURLSchemeHandler に渡すと「それは WebKit が自分でやる」と止められる（アプリが落ちる）。
/// WebKit はそれを WKWebView.handlesURLScheme で確かめているので、そこだけ「http・https は扱わない」と答えさせる。
/// こうすると、ページのアドレスは本物の https://… のまま、読み込みは全部 VNetScheme（自作の通信）に来る。
/// YouTube やログインのように「アドレスが https か」を確かめるページも、そのまま動く。
///
/// 受け入れたリスク（README と開発者パネルにも書く）:
/// ・WebKit の中の作り（handlesURLScheme の差し替え・_willPerformRedirection:）に頼っている。実行時に確かめても、
///   WebKit が変われば動かなくなる・落ちる可能性は消せない。App Store に出すアプリには使えない
/// ・守り: 確かめた iOS の版（testedMajorVersions）だけで使う。差し替えた後の確認に失敗したら、元の実装に戻して標準の通信にする。
///   設定の「VNet を使わない」で、差し替え自体をしないようにできる
enum HTTPSTakeover {
    enum Outcome: Equatable {
        /// https・http を VNetScheme が引き受けられる
        case installed
        /// 設定で VNet を使わない
        case disabledBySetting
        /// 確かめていない iOS の版（設定で許せば試す）
        case untestedOS(Int)
        /// 差し替えられなかった・確認に失敗した（元に戻した）
        case failed(String)

        var description: String {
            switch self {
            case .installed: return "https の横取り: 成功"
            case .disabledBySetting: return "https の横取り: 設定で使わない"
            case .untestedOS(let v): return "https の横取り: 確かめていない iOS \(v) なので使わない（設定で試せます）"
            case .failed(let why): return "https の横取り: 失敗（\(why)）。元に戻しました"
            }
        }
    }

    /// 動くことを確かめた iOS の版（大きい番号）
    static let testedMajorVersions = 16...26

    // 1 回目の結果。@MainActor にはしない（NSObject の override init など、隔離の扱いが iPad の Swift で揺れる所から呼ぶため）。
    // 代わりにロックで守る。WKWebView.handlesURLScheme は Objective-C の API なので、どのスレッドから呼んでもコンパイルは通る
    private static let lock = NSLock()
    private static var result: Outcome?

    /// 1 回だけ行う（2 回目からは 1 回目の結果）。画面のスレッドから呼ぶこと
    static func install() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        let r = tryInstall()
        result = r
        return r
    }

    private static func tryInstall() -> Outcome {
        if VelaSettings.vnetDisabled { return .disabledBySetting }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if !testedMajorVersions.contains(major) && !VelaSettings.allowUntestedOS { return .untestedOS(major) }
        let sel = NSSelectorFromString("handlesURLScheme:")
        guard let m = class_getClassMethod(WKWebView.self, sel) else { return .failed("handlesURLScheme: が見つかりません") }
        let original = method_getImplementation(m)
        let others = ["data", "blob", "about", "vnets"]
        let before = others.map { WKWebView.handlesURLScheme($0) }
        swap(m, sel: sel, original: original)
        // 差し替えが効いているか・ほかのスキームの答えが変わっていないかを確かめる。だめなら元に戻す
        let ok = !WKWebView.handlesURLScheme("https") && !WKWebView.handlesURLScheme("http")
            && others.map({ WKWebView.handlesURLScheme($0) }) == before
        if !ok {
            _ = method_setImplementation(m, original)
            return .failed("差し替えた後の確認に失敗")
        }
        return .installed
    }

    private static func swap(_ m: Method, sel: Selector, original: IMP) {
        // scheme は nil のこともありうる（Objective-C は nil を止めない）。nil を NSString として受けて触ると、
        // 不正なメモリアクセスで落ちるので、Optional で受けて、nil は元の実装に任せる
        typealias Orig = @convention(c) (AnyObject, Selector, NSString?) -> Bool
        let orig = unsafeBitCast(original, to: Orig.self)
        let block: @convention(block) (AnyObject, NSString?) -> Bool = { cls, scheme in
            guard let scheme else { return orig(cls, sel, nil) }
            let s = (scheme as String).lowercased()
            if s == "http" || s == "https" { return false }
            return orig(cls, sel, scheme)
        }
        _ = method_setImplementation(m, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
    }
}

/// 読み込みの途中の「移動（リダイレクト）」を WebKit に伝える
///
/// WKURLSchemeTask の公開の作りには移動を伝える方法が無い。そのままだと、移動先の中身を元のアドレスのまま見せることになり、
/// 相対リンク・オリジン・クッキーがずれて、ページが壊れたりログインできなかったりする。
/// WebKit の中にある _willPerformRedirection:newRequest:completionHandler:（iOS 13 から）を使って、本当の移動として伝える。
/// 無ければ false（そのときは前のやり方: 自分で追いかけて、最後の返事だけ渡す）
enum SchemeTaskRedirect {
    private static let selector = NSSelectorFromString("_willPerformRedirection:newRequest:completionHandler:")

    static func isAvailable(_ task: WKURLSchemeTask) -> Bool {
        class_getInstanceMethod(object_getClass(task), selector) != nil
    }

    /// 移動を伝える。WebKit が受け入れたら done(次の要求)、やめたら done(nil)
    static func perform(_ task: WKURLSchemeTask, response: URLResponse, request: NSURLRequest,
                        done: @escaping (NSURLRequest?) -> Void) -> Bool {
        guard let m = class_getInstanceMethod(object_getClass(task), selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, URLResponse, NSURLRequest, @escaping @convention(block) (NSURLRequest?) -> Void) -> Void
        let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (NSURLRequest?) -> Void = { done($0) }
        f(task as AnyObject, selector, response, request, block)
        return true
    }
}

/// 予備の作りで使う自分用のアドレス: https://… ⇄ vnets://…、http://… ⇄ vnet://…
enum VNetURL {
    /// https://… → vnets://…、http://… → vnet://…（vnets・vnet はそのまま）
    static func toVNet(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "vnets"
        case "http": c.scheme = "vnet"
        case "vnet", "vnets": break
        default: return nil
        }
        return c.url
    }

    /// vnets://… → https://…、vnet://… → http://…（https・http はそのまま）
    static func toReal(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
        switch c.scheme?.lowercased() {
        case "vnets": c.scheme = "https"
        case "vnet": c.scheme = "http"
        case "https", "http": return u
        default: return nil
        }
        return c.url
    }

    /// 自分用のアドレス（vnet://・vnets://）か
    static func isVNet(_ u: URL) -> Bool { u.scheme?.lowercased().hasPrefix("vnet") ?? false }
}
