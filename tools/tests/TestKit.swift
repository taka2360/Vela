import Foundation

// MARK: - 小さなテストの道具（XCTest を使わない。Linux でそのまま動く）

final class TestRun {
    static let shared = TestRun()
    var passed = 0
    var failed: [String] = []
    var current = ""
    var filters: [String] = Array(CommandLine.arguments.dropFirst())
}

func test(_ name: String, _ body: () throws -> Void) {
    let r = TestRun.shared
    if !r.filters.isEmpty && !r.filters.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return }
    r.current = name
    let before = r.failed.count
    do { try body() } catch { r.failed.append("\(name): 例外 \(error)") }
    if r.failed.count == before { r.passed += 1; print("  ✓ \(name)") } else { print("  ✕ \(name)") }
}

func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if !cond() {
        let f = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        TestRun.shared.failed.append("\(TestRun.shared.current): \(f):\(line) \(msg())")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    expect(a == b, "\(a) != \(b) \(msg())", file: file, line: line)
}

func url(_ s: String) -> URL { URL(string: s)! }

func finishTests() -> Never {
    let r = TestRun.shared
    print("")
    for f in r.failed { print("✕ " + f) }
    print("")
    print(r.failed.isEmpty ? "結果: OK（\(r.passed) 件）" : "結果: NG（失敗 \(r.failed.count) 件・成功 \(r.passed) 件）")
    exit(r.failed.isEmpty ? 0 : 1)
}
