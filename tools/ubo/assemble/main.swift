import Foundation

// Actions 用: Vela の組み立て（Scriptlets.swift）で、tools/ubo/fixtures の行から tools/ubo/.out/{main,isolated}.js を作る。
// ローカルでは Swift の単体テスト（ScriptletTests）が同じものを書くので、これは使わなくてよい。
//   swiftc -O Sources/Policy/SiteUtil.swift Sources/AdBlock/FilterPreparser.swift Sources/AdBlock/ABPFilter.swift \
//          Sources/AdBlock/Scriptlets.swift tools/ubo/assemble/main.swift -o assemble && ./assemble

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ p: String) -> String { try! String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
let lib = try! ScriptletLibrary(json: try! Data(contentsOf: root.appendingPathComponent("resources/ubo-scriptlets.json")))
var idx = ScriptletIndex()
for f in ["tools/ubo/fixtures/youtube.txt", "tools/ubo/fixtures/selftest.txt"] {
    for s in ABPParser.parse(read(f)).scriptlets { idx.add(s, trusted: true, library: lib) }
}
if !idx.unknown.isEmpty { print("道具に無い名前: \(idx.unknown)") }
let out = ScriptletAssembler.assemble([
    ("www.youtube.com", idx.retrieve(url: URL(string: "https://www.youtube.com/watch?v=x")!)),
    ("vela-selftest.invalid", idx.retrieve(url: URL(string: "https://vela-selftest.invalid/")!)),
], library: lib)
let dir = root.appendingPathComponent("tools/ubo/.out", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! Data(out.main.utf8).write(to: dir.appendingPathComponent("main.js"))
try! Data(out.isolated.utf8).write(to: dir.appendingPathComponent("isolated.js"))
print("書きました: tools/ubo/.out（ルール \(out.filters.count) 個・uBO \(lib.ubo)）")
