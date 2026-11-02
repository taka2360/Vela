# Swift 5.8.1（WSL の ~/toolchains）の場所を決める。無ければ入れる。
# check.sh と run.sh が source して使う（そのあと $SWIFTC で swiftc を呼ぶ）。入れられなければ終了コード 2 で止める
TC=$HOME/toolchains/swift-5.8.1-RELEASE-ubuntu22.04
export LD_LIBRARY_PATH=$HOME/toolchains/extra/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
SWIFTC=$TC/usr/bin/swiftc

if [ ! -x "$SWIFTC" ]; then
    echo "Swift 5.8.1 が入っていないので入れます…"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftcheck/setup.sh" || exit 2
fi
