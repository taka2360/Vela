#!/usr/bin/env bash
# Swift 5.8.1（Linux 版）を WSL の Ubuntu のホームに入れる。sudo は要らない。何度実行してもよい。
set -euo pipefail

VER=5.8.1
NAME=swift-$VER-RELEASE-ubuntu22.04
ROOT=$HOME/toolchains
TC=$ROOT/$NAME
EXTRA=$ROOT/extra/root/usr/lib/x86_64-linux-gnu

mkdir -p "$ROOT"
if [ ! -x "$TC/usr/bin/swiftc" ]; then
    echo "Swift $VER をダウンロードします（約 500MB）…"
    curl -sSfL -o "$ROOT/swift.tgz" "https://download.swift.org/swift-$VER-release/ubuntu2204/swift-$VER-RELEASE/$NAME.tar.gz"
    tar xzf "$ROOT/swift.tgz" -C "$ROOT"
    rm -f "$ROOT/swift.tgz"
fi

# Ubuntu 24.04 には libncurses.so.6 が無いので、パッケージを取ってきて展開だけする（インストールはしない）
if [ ! -e "$EXTRA/libncurses.so.6" ]; then
    mkdir -p "$ROOT/extra" && cd "$ROOT/extra"
    apt-get download libncurses6 >/dev/null
    for d in libncurses6*.deb; do dpkg-deb -x "$d" root; done
fi

LD_LIBRARY_PATH=$EXTRA "$TC/usr/bin/swiftc" --version
