#!/usr/bin/env python3
"""swiftc の出力を「本当のエラー」「警告」「Linux では調べられなかったもの」に分けて、見やすく出す（check.sh から呼ぶ）。

使い方: classify.py <swiftc の出力ファイル> <作業フォルダ> <元のファイル>... [--keep-warnings]
終了コード: 0 = エラー無し、1 = エラーあり
"""
import os
import re
import sys

DIAG = re.compile(r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+): (?P<kind>error|warning|note|remark): (?P<msg>.*)$")
BARE = re.compile(r"^(?P<kind>error|warning): (?P<msg>.*)$")

# Linux の Swift には Objective-C の仕組みが無いので調べられないもの（iPad では問題ない想定）
NO_OBJC = re.compile(r"not representable in Objective-C|@convention\(block\)|requires Objective-C interop|Objective-C interoperability|'@objc'|@objc")
# アクター（MainActor）の決まりのエラー
ISOLATION = re.compile(r"(actor-isolated|non-isolated|nonisolated) .*(context|declaration)|from outside of its actor context")
# Linux の Foundation（URL・Data などが Sendable でない）から来る警告（iPad では出ない）
LINUX_WARN = re.compile(
    r"non-sendable type '(URL|Data|Date|URLRequest|URLComponents|UUID|URLResponse|HTTPURLResponse|HTTPCookie)\??'"
    r"|add '@preconcurrency' to suppress 'Sendable'-related warnings from module '(Foundation|FoundationNetworking)'"
)
DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|class|override|convenience|required|nonisolated|mutating)\s+)*(init[?!]?\s*\(|func\s|deinit\b)")
CLASS = re.compile(r"\b(class|struct|enum|actor|extension)\s+\w+")


def to_windows(path):
    if path.startswith("/mnt/") and len(path) > 6 and path[6] == "/":
        return path[5].upper() + ":" + path[6:].replace("/", "\\")
    return path


class Diag:
    def __init__(self, path, line, col, kind, msg, head):
        self.path, self.line, self.col, self.kind, self.msg = path, line, col, kind, msg
        self.lines = [head]
        self.notes = []


def parse(text):
    diags = []
    cur = None
    for raw in text.splitlines():
        m = DIAG.match(raw)
        if m:
            d = Diag(m["path"], int(m["line"]), int(m["col"]), m["kind"], m["msg"], raw)
            if d.kind == "note" and cur is not None:
                cur.notes.append(d)
                cur.lines.append(raw)
                continue
            if d.kind == "remark":
                cur = None
                continue
            diags.append(d)
            cur = d
            continue
        m = BARE.match(raw)
        if m:
            if "emit-module command failed" in raw or "compile command failed" in raw:
                continue
            d = Diag("", 0, 0, m["kind"], m["msg"], raw)
            diags.append(d)
            cur = d
            continue
        if cur is not None:
            cur.lines.append(raw)
    return diags


def in_override_init_of_main_actor_class(src_lines, line_no):
    """その行が「@MainActor のクラスの override init」の中か。
    Linux の NSObject は Swift で書かれていて、override init が @MainActor にならない（iPad ではなる）ので、ここのエラーは Linux だけのもの。"""
    i = line_no - 1
    while i >= 0:
        s = src_lines[i]
        m = DECL.match(s)
        if m:
            if not re.search(r"\boverride\b", s) or not m.group(1).startswith("init"):
                return False
            # 囲んでいる型を探して、@MainActor か見る
            j = i - 1
            while j >= 0:
                if CLASS.search(src_lines[j]) and not src_lines[j].lstrip().startswith("//"):
                    head = src_lines[j] + (src_lines[j - 1] if j > 0 else "")
                    return "@MainActor" in head
                j -= 1
            return False
        i -= 1
    return False


def enclosing_decl(src_lines, line_no):
    """その行を囲んでいる関数・init の始まりの行番号（見つからなければ None）"""
    for i in range(min(line_no, len(src_lines)) - 1, -1, -1):
        if DECL.match(src_lines[i]):
            return i + 1
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    keep_warn = "--keep-warnings" in sys.argv
    out_file, work, originals = args[0], args[1], args[2:]
    text = open(out_file, encoding="utf-8", errors="replace").read()

    by_base = {os.path.basename(p): p for p in originals}
    sources = {}

    def orig_of(path):
        if path.startswith(work + "/"):
            b = os.path.basename(path)
            return by_base.get(b, path)
        return path

    def src_lines(path):
        if path not in sources:
            try:
                sources[path] = open(path, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                sources[path] = []
        return sources[path]

    def fix_paths(s):
        s = s.replace(work + "/", "\x00")
        def rep(m):
            b = m.group(1)
            return to_windows(by_base.get(b, b))
        s = re.sub(r"\x00([^:]+)", rep, s)
        return re.sub(r"/mnt/[a-z]/[^:\s]*", lambda m: to_windows(m.group(0)), s)

    diags = parse(text)
    # Objective-C の仕組みでつまずいた関数（その中の他のエラーは、それの巻き添えのことが多い）
    objc_funcs = set()
    for d in diags:
        if d.kind == "error" and NO_OBJC.search(d.msg):
            p = orig_of(d.path)
            objc_funcs.add((p, enclosing_decl(src_lines(p), d.line)))

    errors, warnings, skipped = [], [], []
    for d in diags:
        path = orig_of(d.path)
        if d.kind == "error":
            if NO_OBJC.search(d.msg):
                skipped.append((d, "Objective-C の仕組み"))
            elif path and (path, enclosing_decl(src_lines(path), d.line)) in objc_funcs:
                skipped.append((d, "Objective-C の仕組みの巻き添え"))
            elif ISOLATION.search(d.msg) and path and in_override_init_of_main_actor_class(src_lines(path), d.line):
                skipped.append((d, "NSObject の override init の MainActor"))
            else:
                errors.append(d)
        elif d.kind == "warning":
            if keep_warn or not LINUX_WARN.search(d.msg):
                warnings.append(d)

    if errors:
        print(f"\n==== エラー（{len(errors)} 件）====")
        for d in errors:
            print(fix_paths("\n".join(d.lines)))
    if warnings:
        print(f"\n==== 警告（{len(warnings)} 件。動きはするが直したほうがよいもの）====")
        for d in warnings:
            print(fix_paths(d.lines[0]))
    if skipped:
        print(f"\n==== Linux では調べられなかったもの（{len(skipped)} 件。iPad では通る想定）====")
        for d, why in skipped:
            print(fix_paths(d.lines[0]) + f"  [{why}]")

    if any(re.search(r"cannot find|has no member|no exact matches|No such module|is unavailable", d.msg) for d in errors):
        print("\n※ 「見つからない・メンバーが無い」系のエラーは、スタブ（tools/swiftcheck/stubs/）に部品が足りないだけのこともあります。")
        print("   iOS の本物の API に同じ名前・同じ形のものがあるなら、スタブに足してからもう一度調べてください。")

    print()
    if errors:
        print(f"結果: NG（エラー {len(errors)}・警告 {len(warnings)}・調べられなかった所 {len(skipped)}）")
        return 1
    print(f"結果: OK（エラー 0・警告 {len(warnings)}・調べられなかった所 {len(skipped)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
