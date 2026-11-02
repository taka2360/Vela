# Windows から Swift 5.8 のチェック（WSL の Ubuntu で check.sh）を動かす
# 使い方: powershell -File tools\swiftcheck\swiftcheck.ps1 [フォルダ or ファイル ...] [--keep-warnings]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Targets)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '..\wsl.ps1')   # To-WslPath

$script = To-WslPath (Join-Path $PSScriptRoot 'check.sh')
$wslArgs = @()
foreach ($t in $Targets) { if ($t) { $wslArgs += (To-WslPath $t) } }

& wsl.exe -d Ubuntu -- bash $script @wslArgs
exit $LASTEXITCODE
