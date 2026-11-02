# Windows から Vela の単体テスト（WSL の Ubuntu で run.sh）を動かす
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests\runtests.ps1 [テストの名前の一部 ...]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Filters)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '..\wsl.ps1')   # To-WslPath
$script = To-WslPath (Join-Path $PSScriptRoot 'run.sh')
$wslArgs = @()
foreach ($f in $Filters) { if ($f) { $wslArgs += $f } }

& wsl.exe -d Ubuntu -- bash $script @wslArgs
exit $LASTEXITCODE
