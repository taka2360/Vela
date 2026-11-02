#!/usr/bin/env bash
# Vela の「判定だけ」の部品（UI・WebKit に頼らないもの）を、WSL の Swift 5.8.1 でビルドしてテストする
#
# 使い方: run.sh [テストの名前の一部 ...]   （何も付けなければ全部）
# 入れるアプリ側のファイルは sources.txt、テストは このフォルダの *.swift（main.swift が入口）
# 終了コード: 0 = 全部通った、1 = 失敗あり、2 = ビルドできない・環境の問題
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROJECT=$(cd "$HERE/../.." && pwd)
# Swift 5.8.1 の場所（$SWIFTC）。無ければ入れる
source "$PROJECT/tools/swiftenv.sh"

FILES=()
while IFS= read -r line; do
    line=${line%%#*}; line=$(echo "$line" | tr -d '\r' | xargs)
    [ -z "$line" ] && continue
    [ -f "$PROJECT/$line" ] || { echo "見つかりません: $line（sources.txt）"; exit 2; }
    FILES+=("$PROJECT/$line")
done < "$HERE/sources.txt"
while IFS= read -r f; do FILES+=("$f"); done < <(find "$HERE" -maxdepth 1 -name '*.swift' | sort)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
echo "Swift 5.8.1 でテストをビルドしています（${#FILES[@]} ファイル）…"
if ! "$SWIFTC" -swift-version 5 -module-name VelaTests -Onone -g "${FILES[@]}" -o "$OUT/tests" > "$OUT/build.txt" 2>&1; then
    grep -E "error|warning: unre" "$OUT/build.txt" | sed "s#$PROJECT/##g" | head -60
    echo
    echo "結果: ビルドできません"
    exit 2
fi
"$OUT/tests" "$@"
