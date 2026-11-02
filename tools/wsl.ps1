# Windows のパスを WSL のパス（/mnt/c/...）にする。swiftcheck.ps1 と runtests.ps1 が . で読み込んで使う
# 「--」で始まるもの（オプション）は、そのまま返す
function To-WslPath([string]$p) {
    if ($p -like '--*') { return $p }
    $full = (Resolve-Path -LiteralPath $p).Path
    $drive = $full.Substring(0, 1).ToLower()
    return "/mnt/$drive" + ($full.Substring(2) -replace '\\', '/')
}
