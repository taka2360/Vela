# Windows から Swift 5.8 のチェック（WSL の Ubuntu で check.sh）を動かす
# 使い方: powershell -File tools\swiftcheck\swiftcheck.ps1 [フォルダ or ファイル ...] [--keep-warnings]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Targets)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function To-WslPath([string]$p) {
    if ($p -like '--*') { return $p }
    $full = (Resolve-Path -LiteralPath $p).Path
    $drive = $full.Substring(0, 1).ToLower()
    return "/mnt/$drive" + ($full.Substring(2) -replace '\\', '/')
}

$script = To-WslPath (Join-Path $PSScriptRoot 'check.sh')
$wslArgs = @()
foreach ($t in $Targets) { if ($t) { $wslArgs += (To-WslPath $t) } }

& wsl.exe -d Ubuntu -- bash $script @wslArgs
exit $LASTEXITCODE
