# Builds the shippable Windows package for the Flutter UI.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files as ANSI, so
# non-ASCII text here would be garbled. Chinese user-facing text lives in
# flutter_app/packaging/README-package.txt (copied as README.txt).
#
# What it does:
#   1. (optional) rebuild the C bridge + Flutter app;
#   2. assemble dist\TaskScheduler-<version>-win64-x64\ with the Flutter runtime,
#      the native DLLs, cacert.pem and a config.json that embeds the API key;
#   3. write VERSION.txt + MANIFEST.sha256 and zip the folder.
#
# The key is only ever written into the packaged config.json. It is never printed
# to the console, never written to logs, and never put in VERSION.txt / README.txt.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/make_flutter_release.ps1 `
#     -Version 0.0.4 -ApiKey "sk-..." 
#   (or set $env:TS_RELEASE_API_KEY instead of passing -ApiKey)

[CmdletBinding()]
param(
    [string]$Version = '0.1.2',
    [string]$ApiKey = '',
    [string]$Model = 'deepseek-flash',
    [string]$Endpoint = 'https://api.deepseek.com/chat/completions',
    [string]$OutRoot = 'dist',
    [switch]$SkipBuild,
    [switch]$KeepUnzipped,
    # 0.0.4: the settings window owns the API key. A key-free package is the safe
    # default for sharing; pass -ApiKey (or TS_RELEASE_API_KEY) only for a private
    # single-machine build that must work before the first settings save.
    [switch]$NoApiKey
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'flutter_app'
$runnerDir = Join-Path $appDir 'build\windows\x64\runner\Release'

if ([string]::IsNullOrWhiteSpace($ApiKey)) { $ApiKey = $env:TS_RELEASE_API_KEY }
if ([string]::IsNullOrWhiteSpace($ApiKey) -and -not $NoApiKey) {
    throw 'API key is required: pass -ApiKey, set $env:TS_RELEASE_API_KEY, or use -NoApiKey for a key-free package'
}
# Product version and pubspec/build version must agree: 0.05 == 0.0.5, 0.06 == 0.0.6, 0.07 == 0.0.7, 0.08 == 0.0.8, 0.09 == 0.0.9, 0.1.0 == 0.1.0, 0.1.1 == 0.1.1, 0.1.2 == 0.1.2.
$pubVersion = (Select-String -Path (Join-Path $appDir 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' |
    Select-Object -First 1).Matches.Groups[1].Value
$versionAliases = @{ '0.05' = '0.0.5'; '0.06' = '0.0.6'; '0.07' = '0.0.7'; '0.08' = '0.0.8'; '0.09' = '0.0.9'; '0.1.0' = '0.1.0'; '0.1.1' = '0.1.1'; '0.1.2' = '0.1.2' }
if ($versionAliases.ContainsKey($Version) -and $pubVersion -ne $versionAliases[$Version]) {
    throw "version mismatch: product $Version requires pubspec $($versionAliases[$Version]) (found $pubVersion)"
}
if ($Version -match '^\d+\.\d+\.\d+$' -and $Version -ne $pubVersion) {
    throw "version mismatch: -Version $Version != pubspec $pubVersion"
}
if (-not [string]::IsNullOrWhiteSpace($ApiKey) -and $ApiKey -notmatch '^sk-[A-Za-z0-9_\-]{16,}$') {
    throw 'API key does not look like a DeepSeek key (expected sk-...); refusing to package.'
}
if (-not [string]::IsNullOrWhiteSpace($ApiKey) -and $NoApiKey) {
    throw 'Choose one of -ApiKey and -NoApiKey, not both.'
}

# --- 1. build --------------------------------------------------------------
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_flutter_app.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}
if (-not (Test-Path (Join-Path $runnerDir 'taskscheduler.exe'))) {
    throw "runner not found: $runnerDir"
}

# --- 2. assemble -----------------------------------------------------------
$name = "TaskScheduler-$Version-win64-x64"
$outRootPath = Join-Path $root $OutRoot
$stage = Join-Path $outRootPath $name
$zipPath = Join-Path $outRootPath "$name.zip"

New-Item -ItemType Directory -Force -Path $outRootPath | Out-Null
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

Write-Host "staging $name"
Copy-Item -Recurse $runnerDir $stage
# Drop build-time leftovers that must not ship. TaskSchedulerData is user state (it can
# contain sessions/settings from a local run) and must never be packaged.
foreach ($junk in @('config.json', 'config.example.json', 'native_assets.json', 'TaskSchedulerData')) {
    $p = Join-Path $stage $junk
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}

# --- 3. config -------------------------------------------------------------
function New-ReleaseConfig([bool]$WithKey, [bool]$Mock, [bool]$WithEnv) {
    $cfg = [ordered]@{
        endpoint_url        = $Endpoint
        model               = $Model
        ca_bundle_path      = 'cacert.pem'
        reasoning_effort    = 'none'
        connect_timeout_ms  = 15000
        wait_prompt_ms      = 120000
        request_timeout_ms  = 0
        max_output_tokens   = 0
        max_input_bytes     = 262144
        max_response_bytes  = 2097152
        json_mode           = $true
        temperature         = 0.2
        reference_hours     = 2.0
        max_retry_attempts  = 1
        mock_mode           = $Mock
    }
    if ($WithKey) {
        # Inline key wins over api_key_env in the C config layer; keep env empty so
        # the shipped build cannot be broken by a stale machine-level variable.
        $cfg['api_key'] = $ApiKey
        $cfg['api_key_env'] = ''
    } elseif ($WithEnv) {
        $cfg['api_key_env'] = 'DEEPSEEK_API_KEY'
    } else {
        # Key-free package: no inline secret and no environment requirement. The user
        # adds the key in Settings -> Model (Windows Credential Manager) on first run.
        $cfg['api_key_env'] = ''
    }
    return $cfg
}

$hasEmbeddedKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
$config = if ($hasEmbeddedKey) {
    New-ReleaseConfig -WithKey $true -Mock $false -WithEnv $false
} else {
    New-ReleaseConfig -WithKey $false -Mock $false -WithEnv $false
}
$configJson = $config | ConvertTo-Json -Depth 4
# Write UTF-8 without BOM: the C JSON parser accepts a BOM, but keeping the file
# BOM-free avoids surprises with other tools.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $stage 'config.json'), $configJson, $utf8NoBom)

# Key-free template for sharing / offline demo.
$template = New-ReleaseConfig -WithKey $false -Mock $true -WithEnv $false
[System.IO.File]::WriteAllText(
    (Join-Path $stage 'config.example.json'),
    ($template | ConvertTo-Json -Depth 4),
    $utf8NoBom)

# --- 4. docs ---------------------------------------------------------------
$readmeSrc = Join-Path $appDir 'packaging\README-package.txt'
if (-not (Test-Path $readmeSrc)) { throw "missing $readmeSrc" }
Copy-Item $readmeSrc (Join-Path $stage 'README.txt') -Force

$exeItem = Get-Item (Join-Path $stage 'taskscheduler.exe')
$bridgeItem = Get-Item (Join-Path $stage 'ts_bridge.dll')
$keyState = if ($hasEmbeddedKey) {
    'EMBEDDED in config.json (inline api_key) -- do not redistribute'
} else {
    'not embedded; add it in Settings -> Model (Windows Credential Manager)'
}
$verification = if ($SkipBuild) {
    'build/tests were SKIPPED for this package (-SkipBuild); see the acceptance report'
} else {
    'scripts/build_flutter_app.ps1 ran in this packaging run (flutter analyze, flutter test, C tests)'
}
$versionText = @"
TaskScheduler $Version (Windows x64, Flutter UI)
================================================

Build date      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Product version : $Version
Build version   : $pubVersion (pubspec; $Version and $pubVersion are the same release)
UI              : Flutter (Windows desktop)
Core            : existing C core, called through ts_bridge.dll (ABI 2)
Model           : $Model
Endpoint        : $Endpoint
API key         : $keyState
Bundled runtime : flutter_windows.dll, data\, ts_bridge.dll, libcurl-x64.dll, cacert.pem
Executable size : $($exeItem.Length) bytes (taskscheduler.exe)
Bridge size     : $($bridgeItem.Length) bytes (ts_bridge.dll)

Verification of this build:
  - $verification
  - Detailed commands, exit codes and screenshots: TASKSCHEDULER_0_1_2_ACCEPTANCE_REPORT.md (next to this package)

Data location (default): <program folder>\TaskSchedulerData
  (falls back to %LOCALAPPDATA%\TaskSchedulerFlutter etc. when the program folder is
   read-only; Settings -> Storage shows the actual directory)
Settings files: <data dir>\settings.json (connections, no secret) and
                <data dir>\settings\app_prefs.json (UI preferences)
API keys       : Windows Credential Manager, scoped to the data directory
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'VERSION.txt'), $versionText, $utf8NoBom)

# --- 5. manifest + zip -----------------------------------------------------
$files = Get-ChildItem $stage -Recurse -File | Where-Object { $_.Name -ne 'MANIFEST.sha256' } | Sort-Object FullName
$lines = foreach ($f in $files) {
    $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
    $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $rel"
}
[System.IO.File]::WriteAllLines((Join-Path $stage 'MANIFEST.sha256'), $lines, $utf8NoBom)

Write-Host 'compressing...'
# Zip the folder itself (not its contents): extracting then yields one
# TaskScheduler-<version>-win64-x64\ directory instead of scattering the runtime files
# into whatever folder the user happened to be in.
Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal
$zipItem = Get-Item $zipPath

Write-Host ''
Write-Host "package : $stage"
Write-Host ("zip     : {0} ({1:N1} MB)" -f $zipPath, ($zipItem.Length / 1MB))
Write-Host "files   : $($files.Count)"
Write-Host "version : $Version"
Write-Host ("api key : " + $(if ($hasEmbeddedKey) { 'embedded in config.json (not printed)' } else { 'not embedded; configure in Settings -> Model' }))

if (-not $KeepUnzipped) {
    # Keep the folder so the user can run it without unzipping; only report.
}

