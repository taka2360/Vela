# Runs every check in one go: merge_swift.py, swiftcheck (Sources / VelaAll.swift / VelaParts), and the unit tests.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\checkall.ps1
# The last line is "ALL OK" (exit code 0) or "SOMETHING FAILED" (exit code 1).
# Note: this file avoids non-ASCII text on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI).
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $ok = $true
    $merge = python (Join-Path $root 'tools\merge_swift.py') 2>&1
    if ($LASTEXITCODE -ne 0) { $ok = $false; $merge | Select-Object -Last 20 }
    $merge | Select-String 'ORDER' | ForEach-Object { "merge: $_" }

    $check = Join-Path $root 'tools\swiftcheck\swiftcheck.ps1'
    foreach ($t in @('', 'Playgrounds\VelaAll.swift', 'Playgrounds\VelaParts')) {
        if ($t) { $out = powershell -NoProfile -ExecutionPolicy Bypass -File $check (Join-Path $root $t) 2>&1 }
        else { $out = powershell -NoProfile -ExecutionPolicy Bypass -File $check 2>&1 }
        $code = $LASTEXITCODE
        "swiftcheck [$t]: exit=$code | " + (($out | Select-Object -Last 1) -as [string])
        if ($code -ne 0) { $ok = $false; $out | Select-Object -Last 40 }
    }

    $out = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\tests\runtests.ps1') 2>&1
    $code = $LASTEXITCODE
    "tests: exit=$code | " + (($out | Select-Object -Last 1) -as [string])
    if ($code -ne 0) { $ok = $false; $out | Select-Object -Last 40 }

    if ($ok) { 'ALL OK'; $final = 0 } else { 'SOMETHING FAILED'; $final = 1 }
} finally {
    Pop-Location
}
exit $final
