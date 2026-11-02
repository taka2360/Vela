import Foundation
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
