#!/usr/bin/env python3
"""このフォルダの .swift ファイルを 1 つにまとめる（Swift Playgrounds 用）。

使い方:
  python merge_swift.py                  # → VelaAll.swift（@main 付き。Playgrounds の「App」用）
                                         #   と VelaParts/Vela1〜4.swift（同じ中身を 4 つに分けたもの）
  python merge_swift.py --parts 6        # 分ける数を変える（0 なら分けたものは作らない）
  python merge_swift.py -o out.swift     # 出力先を変える
  python merge_swift.py --playground     # @main を外し、PlaygroundSupport のライブビューで動かす版
                                         # （Xcode / Playgrounds の「.playground」ページ用）

やること:
  - 各ファイル先頭の import（と import だけを囲む #if canImport ... #endif）を集めて、重複を除いて先頭に置く
  - 残りの本体を、README の順番でつなげる（ファイル名の区切りコメント付き）
  - private / fileprivate のトップレベル名が別ファイル同士でぶつかっていないか確認する
"""
import argparse
import re
import sys
from pathlib import Path

# README の順（ここに無いファイルは最後に名前順で足す）
ORDER = [
    "MyApp", "BrowserView", "BrowserModel", "Persistence", "DevLog", "VNetScheme", "HTTPSTakeover", "PageScripts",
    "NetPolicy", "CookieJar", "HSTSStore",
    "HTTPClient", "HTTPResponseParser", "HTTPSupport", "TLSClient",
    "GuestStack", "GuestTCP", "DNSMessage", "Packet",
    "VNetMachine", "VNetCore", "VNetDriver",
    "UserNet", "UserNetApple",
]

IMPORT_RE = re.compile(r"^\s*(@testable\s+)?import\s+\S+")
IF_RE = re.compile(r"^\s*#if\b")
ENDIF_RE = re.compile(r"^\s*#endif\b")
PRIVATE_TOP_RE = re.compile(
    r"^(?:private|fileprivate)\s+(?:final\s+)?(?:func|let|var|class|struct|enum|actor|typealias|protocol)\s+([A-Za-z_]\w*)"
)


def split_header(lines):
    """先頭の import 部分（header）と本体（body）に分ける。
    header は「行のまとまり」のリストで返す（#if ブロックは 1 まとまり）。"""
    header = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.strip() == "":
            i += 1
            continue
        if IMPORT_RE.match(line):
            header.append(line.strip())
            i += 1
            continue
        if IF_RE.match(line):
            # #if ... #endif の中が import と空行だけなら header に入れる
            j = i + 1
            ok = False
            while j < n:
                s = lines[j]
                if ENDIF_RE.match(s):
                    ok = True
                    break
                if s.strip() == "" or IMPORT_RE.match(s):
                    j += 1
                    continue
                break
            if ok:
                block = "\n".join(l.strip() for l in lines[i:j + 1] if l.strip())
                header.append(block)
                i = j + 1
                continue
        break
    return header, lines[i:]


GENERATED_MARK = "// このファイルは merge_swift.py で自動生成したものです"


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-d", "--dir", default=Path(__file__).resolve().parent, type=Path, help="入力フォルダ")
    ap.add_argument("-o", "--output", default="VelaAll.swift", help="出力ファイル名")
    ap.add_argument("--parts", type=int, default=4,
                    help="VelaParts/ に、同じ中身をこの数のファイルに分けたものも作る（0 で作らない）。"
                         "Playgrounds は 1 つのファイルが大きいと、作るのが 30 秒を超えて止まる（thunk の時間切れ）ため")
    ap.add_argument("--playground", action="store_true",
                    help="@main を外して PlaygroundSupport のライブビューで BrowserView を出す")
    args = ap.parse_args()

    src_dir: Path = args.dir
    out_path = Path(args.output)
    if not out_path.is_absolute():
        out_path = src_dir / out_path

    files = {}
    for p in src_dir.glob("*.swift"):
        if p.resolve() == out_path.resolve():
            continue
        if p.read_text(encoding="utf-8-sig").startswith(GENERATED_MARK):
            continue  # 前にまとめたファイルは入れない
        files[p.stem] = p
    if not files:
        sys.exit(f"{src_dir} に .swift ファイルがありません")
    names = [n for n in ORDER if n in files] + sorted(n for n in files if n not in ORDER)

    headers = []          # 順序を保って重複を除く
    bodies = []
    private_names = {}    # 名前 → ファイル

    for name in names:
        text = files[name].read_text(encoding="utf-8-sig").replace("\r\n", "\n")
        lines = text.split("\n")
        header, body = split_header(lines)

        if args.playground and name == "MyApp":
            print(f"  skip {name}.swift（--playground なので @main の App は入れない）")
            for h in header:
                if h not in headers:
                    headers.append(h)
            continue

        for h in header:
            if h not in headers:
                headers.append(h)

        for line in body:
            m = PRIVATE_TOP_RE.match(line)
            if m:
                pn = m.group(1)
                if pn in private_names and private_names[pn] != name:
                    print(f"  警告: private な名前 '{pn}' が {private_names[pn]}.swift と {name}.swift の両方にあります",
                          file=sys.stderr)
                private_names[pn] = name

        body_text = "\n".join(body).strip("\n")
        bodies.append(f"// {'=' * 70}\n// MARK: - {name}.swift\n// {'=' * 70}\n\n{body_text}\n")
        print(f"  add  {name}.swift")

    if args.playground:
        for h in ("import SwiftUI", "import PlaygroundSupport"):
            if h not in headers:
                headers.append(h)
        bodies.append(
            f"// {'=' * 70}\n// MARK: - Playground で表示\n// {'=' * 70}\n\n"
            "PlaygroundPage.current.setLiveView(BrowserView())\n"
        )

    out = (
        "// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）\n"
        f"// 元ファイル: {', '.join(n + '.swift' for n in names if not (args.playground and n == 'MyApp'))}\n\n"
        + "\n".join(headers)
        + "\n\n"
        + "\n".join(bodies)
    )
    out_path.write_text(out, encoding="utf-8", newline="\n")
    print(f"→ {out_path}（{len(bodies)} ブロック, {out.count(chr(10))} 行）")

    if args.parts > 0 and not args.playground:
        write_parts(src_dir / "VelaParts", headers, bodies, names, args.parts)


def write_parts(folder: Path, headers, bodies, names, n):
    """同じ中身を n 個のファイルに分ける（元のファイルの区切りで分けるので、private な名前は 1 つのファイルの中に収まる）"""
    folder.mkdir(exist_ok=True)
    for old in folder.glob("Vela*.swift"):
        old.unlink()
    total = sum(b.count("\n") for b in bodies)
    target = total / n
    groups, cur, cur_lines = [], [], 0
    for b in bodies:
        lines = b.count("\n")
        # 目安を超えるなら、ここで区切る（最後のグループは残りを全部）
        if cur and cur_lines + lines / 2 > target and len(groups) < n - 1:
            groups.append(cur)
            cur, cur_lines = [], 0
        cur.append(b)
        cur_lines += lines
    if cur:
        groups.append(cur)
    head = "\n".join(headers)
    for i, g in enumerate(groups, 1):
        text = (
            f"// このファイルは merge_swift.py で自動生成したものです（直接編集しないでください）\n"
            f"// VelaParts の {i} / {len(groups)}。全部まとめて Playgrounds に入れる（VelaAll.swift とは一緒に入れない）\n\n"
            + head + "\n\n" + "\n".join(g)
        )
        path = folder / f"Vela{i}.swift"
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"→ {path}（{text.count(chr(10))} 行）")


if __name__ == "__main__":
    main()
