# Build the C bridge DLL and the Flutter Windows application, then stage the
# runtime files next to the app executable.
#
# NOTE: ASCII-only on purpose - Windows PowerShell 5.1 reads .ps1 as ANSI.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1 -Clean
#   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1 -Mode debug

[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$Mode = 'release',
    [switch]$Clean,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'flutter_app'
$buildDir = Join-Path $root 'build-flutter'

# --- 1. C core + bridge DLL -------------------------------------------------
# Splat a hashtable (not an array): an array element like '-SkipTests' would be
# bound positionally and silently land in -BuildDir.
$bridgeArgs = @{}
if ($Clean) { $bridgeArgs['Clean'] = $true }
if ($SkipTests) { $bridgeArgs['SkipTests'] = $true }
& (Join-Path $PSScriptRoot 'build_flutter_bridge.ps1') @bridgeArgs
if ($LASTEXITCODE -ne 0) { throw "bridge build failed" }

# --- 2. Flutter Windows app -------------------------------------------------
$flutterBin = 'C:\Users\' + $env:USERNAME + '\develop\flutter\bin'
if (Test-Path (Join-Path $flutterBin 'flutter.bat')) {
    $env:Path = "$flutterBin;" + $env:Path
}
$gitCmd = 'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd'
if (Test-Path $gitCmd) { $env:Path = "$gitCmd;" + $env:Path }
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'

Push-Location $appDir
try {
    if ($Clean -and (Test-Path (Join-Path $appDir 'build'))) {
        Remove-Item -Recurse -Force (Join-Path $appDir 'build')
    }
    & flutter.bat --no-version-check pub get --offline
    if ($LASTEXITCODE -ne 0) { throw "pub get failed" }

    & flutter.bat --no-version-check analyze
    if ($LASTEXITCODE -ne 0) { throw "analyze reported issues" }

    & flutter.bat --no-version-check test
    if ($LASTEXITCODE -ne 0) { throw "dart tests failed" }

    if ($Mode -eq 'release') {
        # --no-tree-shake-icons: icon tree-shaking dropped glyphs that the settings rail
        # and a few other widgets use (they rendered as blank space in the packaged exe,
        # while the same codepoints worked elsewhere). The extra ~1.6 MB is a fair price
        # for not shipping invisible icons.
        & flutter.bat --no-version-check build windows --release --no-tree-shake-icons
    } else {
        & flutter.bat --no-version-check build windows --debug
    }
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
}
finally {
    Pop-Location
}

# --- 3. Stage native runtime next to the app exe ----------------------------
$runnerDir = Join-Path $appDir ("build\windows\x64\runner\" + $(if ($Mode -eq 'release') { 'Release' } else { 'Debug' }))
if (-not (Test-Path $runnerDir)) { throw "runner dir not found: $runnerDir" }

Copy-Item (Join-Path $buildDir 'Release\ts_bridge.dll') $runnerDir -Force
$curlDll = Join-Path $root 'third_party\curl\bin\libcurl-x64.dll'
if (Test-Path $curlDll) { Copy-Item $curlDll $runnerDir -Force }
$cacert = Join-Path $root 'third_party\curl\bin\cacert.pem'
if (Test-Path $cacert) { Copy-Item $cacert $runnerDir -Force }
# A sample config only; NO key is copied anywhere.
$cfgExample = Join-Path $root 'config.example.json'
if (Test-Path $cfgExample) { Copy-Item $cfgExample (Join-Path $runnerDir 'config.example.json') -Force }

# --- 4. local OCR host (0.2.3, R3-O) ---------------------------------------
# The offline OCR helper is an app-owned executable, not a Flutter asset: it is
# staged next to the runtime so the packaged folder is self-contained. It is only
# copied when it was built (scripts/build_ocr_host.ps1); a missing helper must not
# break the rest of the build, the app then reports "OCR unavailable" explicitly.
$ocrSrc = Join-Path $root 'tools\ocr_host\bin\ocr_host.exe'
if (Test-Path $ocrSrc) {
    $ocrDir = Join-Path $runnerDir 'data\ocr'
    New-Item -ItemType Directory -Force -Path $ocrDir | Out-Null
    Copy-Item $ocrSrc (Join-Path $ocrDir 'ocr_host.exe') -Force
    $ocrInfo = Join-Path $root 'tools\ocr_host\bin\build-info.json'
    if (Test-Path $ocrInfo) { Copy-Item $ocrInfo (Join-Path $ocrDir 'build-info.json') -Force }
    $ocrReadme = Join-Path $root 'docs\r3\ocr\README.md'
    if (Test-Path $ocrReadme) { Copy-Item $ocrReadme (Join-Path $ocrDir 'OCR-README.md') -Force }
    Write-Host ("staged OCR host: {0}" -f $ocrSrc)
} else {
    Write-Host 'OCR host not built (optional): run scripts/build_ocr_host.ps1'
}

Write-Host ""
Write-Host "staged into: $runnerDir"
Get-ChildItem $runnerDir | Where-Object { $_.Name -match '\.(exe|dll|pem|json)$' } |
    ForEach-Object { Write-Host ("  " + $_.Name) }
Write-Host ""
Write-Host "run: " (Join-Path $runnerDir 'taskscheduler.exe')
