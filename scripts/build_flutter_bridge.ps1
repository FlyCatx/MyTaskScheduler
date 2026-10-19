# Build the C core, the Flutter bridge DLL and the bridge integration test, then run it.
#
# Why a single script: Flutter/Dart and MSVC both need to spawn child processes and
# read their output through pipes (blocked by the file sandbox), so bundling
# configure + build + test into one invocation keeps the build reproducible.
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 reads .ps1
# files as ANSI, so non-ASCII text here would be garbled and break parsing.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1 -Clean

[CmdletBinding()]
param(
    [string]$BuildDir = 'build-flutter',
    [switch]$Clean,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Find-CMake {
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
        'C:\Program Files\CMake\bin\cmake.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'cmake.exe not found'
}

$cmake = Find-CMake
Write-Host "cmake: $cmake"

if ($Clean -and (Test-Path (Join-Path $root $BuildDir))) {
    Write-Host "clean $BuildDir"
    Remove-Item -Recurse -Force (Join-Path $root $BuildDir)
}

Push-Location $root
try {
    & $cmake -S . -B $BuildDir -G "Visual Studio 18 2026" -A x64
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed (exit $LASTEXITCODE)" }

    & $cmake --build $BuildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed (exit $LASTEXITCODE)" }

    $outDir = Join-Path $root "$BuildDir\Release"
    Write-Host ""
    Write-Host "output: $outDir"
    Get-ChildItem $outDir -Filter '*.exe' | ForEach-Object { Write-Host ("  " + $_.Name) }
    Get-ChildItem $outDir -Filter '*.dll' | ForEach-Object { Write-Host ("  " + $_.Name) }

    if (-not $SkipTests) {
        $bridgeTest = Join-Path $outDir 'ts_test_bridge.exe'
        if (-not (Test-Path $bridgeTest)) { throw "missing $bridgeTest" }
        Write-Host ""
        Write-Host "===== ts_test_bridge ====="
        & $bridgeTest
        $bridgeExit = $LASTEXITCODE
        Write-Host "ts_test_bridge exit=$bridgeExit"
        if ($bridgeExit -ne 0) { throw "bridge integration test failed" }

        # Legacy console regression: make sure the core changes did not break old behaviour.
        # ts_test_settings / ts_test_probe are the 0.0.4 settings + probe suites
        # (offline: profile/credential/settings.json/revision/migration, request
        # capture, snapshot isolation, credential host binding, probe error classes).
        foreach ($name in @('ts_test', 'ts_test3', 'ts_test4', 'ts_test6', 'ts_test_validate',
                            'ts_test_plan', 'ts_test_constraints', 'ts_test_export_json',
                            'ts_test_model', 'ts_test_initonce', 'ts_test_auth_offline',
                            'ts_test_settings', 'ts_test_probe')) {
            $exe = Join-Path $outDir "$name.exe"
            if (Test-Path $exe) {
                Write-Host ""
                Write-Host "===== $name ====="
                & $exe $outDir | Select-Object -Last 6
                Write-Host "$name exit=$LASTEXITCODE"
                if ($LASTEXITCODE -ne 0) { throw "$name failed (exit $LASTEXITCODE)" }
            }
        }
    }
}
finally {
    Pop-Location
}

