#!/usr/bin/env bash
# Swift 5.8 で、iPad の Swift Playgrounds（App）に入れる .swift がコンパイルエラーにならないか調べる（WSL 上で動かす）
#
# 使い方:
#   check.sh                    # Sources/ の .swift を全部（サブフォルダも。*All.swift は除く）、1 つの App としてまとめて調べる
#   check.sh <フォルダ>          # そのフォルダの .swift を全部（サブフォルダも。*All.swift は除く）
#   check.sh a.swift b.swift    # 指定したファイルだけ（例: check.sh Playgrounds/VelaAll.swift でまとめた版を調べる）
#   オプション: --keep-warnings  Linux の Foundation 由来の Sendable 警告も隠さずに出す
#               --timing         型チェックに時間のかかる関数・式を警告で出す（既定 150ms。環境変数 TIMING_MS で変更）
#
#
# しくみ:
#   Linux には SwiftUI・WebKit・UIKit・Network・Security・Compression・CryptoKit・ObjectiveC が無いので、
#   stubs/ の「形だけの定義」（スタブ）を先にモジュールにして、それを import させて型チェック（-typecheck）する。
#   さらに #if os(iOS) を「iOS として」読むように、コピーした上で os(iOS) → true に置き換えてから調べる。
#   Linux の Swift は @objc を受け付けないので、@objc / @objc(セレクタ) も消してから調べる。
#
# 終了コード: 0 = エラー無し、1 = エラーあり、2 = 使い方・環境の問題
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROJECT=$(cd "$HERE/../.." && pwd)
CACHE=$HOME/.cache/vnet-swiftcheck
MODS=$CACHE/modules

KEEP_WARN=0
TIMING=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --keep-warnings) KEEP_WARN=1 ;;
        --timing) TIMING=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done

# Swift 5.8.1 の場所（$SWIFTC）。無ければ入れる
source "$PROJECT/tools/swiftenv.sh"

# ---- 調べるファイルを集める ----
FILES=()
if [ ${#ARGS[@]} -eq 0 ]; then ARGS=("$PROJECT/Sources"); fi
for a in "${ARGS[@]}"; do
    if [ -d "$a" ]; then
        while IFS= read -r f; do FILES+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"); done \
            < <(find "$a" -name '*.swift' ! -name '*All.swift' | sort)
    elif [ -f "$a" ]; then
        FILES+=("$(cd "$(dirname "$a")" && pwd)/$(basename "$a")")
    else
        echo "見つかりません: $a"; exit 2
    fi
done
if [ ${#FILES[@]} -eq 0 ]; then echo ".swift ファイルがありません"; exit 2; fi

# ---- スタブをモジュールにする（stubs/ が変わったときだけ作り直す） ----
mkdir -p "$MODS"
STAMP=$MODS/.stamp
if [ ! -f "$STAMP" ] || [ -n "$(find "$HERE/stubs" -newer "$STAMP" -name '*.swift')" ]; then
    echo "スタブ（SwiftUI・WebKit など iOS の部品の形だけ）を用意しています…"
    rm -rf "$MODS"; mkdir -p "$MODS"
    for m in UIKit ObjectiveC Compression Security CryptoKit Network WebKit SwiftUI; do
        # エラーが 1 つでもあれば止める（古いモジュールのまま調べて「OK」と出さないように、作りかけも消す）
        if "$SWIFTC" -swift-version 5 -parse-as-library -emit-module -module-name "$m" -I "$MODS" \
                -emit-module-path "$MODS/$m.swiftmodule" "$HERE/stubs/$m.swift" 2>&1 | grep -E "error"; then
            rm -rf "$MODS"
            echo "スタブ $m を作れませんでした（stubs/$m.swift を直してください）"; exit 2
        fi
        [ -f "$MODS/$m.swiftmodule" ] || { rm -rf "$MODS"; echo "スタブ $m を作れませんでした（stubs/$m.swift を直してください）"; exit 2; }
    done
    touch "$STAMP"
fi

# ---- コピーして #if os(iOS) を iOS として読ませる（行番号は変えない） ----
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
COPIES=()
MAIN=0
for f in "${FILES[@]}"; do
    b=$(basename "$f")
    if [ -e "$WORK/$b" ]; then echo "同じ名前のファイルが 2 つあります: $b"; exit 2; fi
    sed -E 's/\bos\(iOS\)/true/g; s/\bos\((macOS|watchOS|tvOS|Linux|Windows)\)/false/g; s/@objc(\([A-Za-z0-9_:]*\))?//g' "$f" > "$WORK/$b"
    COPIES+=("$WORK/$b")
    grep -qE '^\s*@main\b' "$f" && MAIN=1
done

FLAGS=(-typecheck -swift-version 5 -module-name App -I "$MODS" -continue-building-after-errors)
# --timing: 型チェックに時間のかかる関数・式を警告で出す（Playgrounds の「thunk の作成が 30 秒で時間切れ」の原因探し）
if [ $TIMING -eq 1 ]; then FLAGS+=(-Xfrontend -warn-long-function-bodies=${TIMING_MS:-150} -Xfrontend -warn-long-expression-type-checking=${TIMING_MS:-150}); fi
# @main があるなら「App」の作り（トップレベルのコードを許さない）。無いなら 1 ファイル目をメインとして読む
if [ $MAIN -eq 1 ] || [ ${#COPIES[@]} -gt 1 ]; then FLAGS+=(-parse-as-library); fi

echo "Swift 5.8.1 で ${#COPIES[@]} ファイルを調べています…"
"$SWIFTC" "${FLAGS[@]}" "${COPIES[@]}" > "$WORK/out.txt" 2>&1
KW=(); [ $KEEP_WARN -eq 1 ] && KW=(--keep-warnings)
python3 "$HERE/classify.py" "$WORK/out.txt" "$WORK" "${FILES[@]}" "${KW[@]}"
