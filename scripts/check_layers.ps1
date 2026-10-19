# Checks the C source layering rule documented in src/README.md.
#
# Layer direction (upstream may include downstream only):
#   app / bridge  ->  domain  ->  state  ->  util
#                        \__ platform __/        (platform may only use util)
#
# Why a script and not a target split: the project compiles the core into ONE static
# library (ts_core) shared by the Win32 UI and ts_bridge.dll. The include graph is the
# only place where a wrong dependency shows up before it becomes a cycle, so it is
# checked mechanically on every verification run.
#
# NOTE: ASCII-only on purpose - Windows PowerShell 5.1 reads .ps1 as ANSI.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/check_layers.ps1
# Exit code 0 = no violations, 1 = violations found.

[CmdletBinding()]
param(
    [string]$SrcRoot = 'src'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root $SrcRoot
if (-not (Test-Path $srcDir)) { throw "source dir not found: $srcDir" }

$allowed = @{
    # Documented exception: the process entry point (src/app/main.c) must reference the
    # Win32 window it starts (src/gui_win32.h), and that UI is kept at src/ root by
    # design. Nothing else in app/ may use the 'win32' layer.
    'app'      = @('app', 'win32', 'domain', 'state', 'platform', 'util')
    'bridge'   = @('bridge', 'domain', 'state', 'platform', 'util')
    'domain'   = @('domain', 'state', 'platform', 'util')
    'state'    = @('state', 'platform', 'util')
    'platform' = @('platform', 'util')
    'util'     = @('util')
    # The legacy Win32 UI entry sits at src/ root and is allowed to use the app layer.
    'win32'    = @('win32', 'app', 'bridge', 'domain', 'state', 'platform', 'util')
}

function Get-Layer([string]$relativePath) {
    $p = $relativePath.Replace('\', '/')
    if ($p -match '^app/') { return 'app' }
    if ($p -match '^bridge/') { return 'bridge' }
    if ($p -match '^domain/') { return 'domain' }
    if ($p -match '^state/') { return 'state' }
    if ($p -match '^platform/') { return 'platform' }
    if ($p -match '^util/') { return 'util' }
    return 'win32'
}

$files = Get-ChildItem $srcDir -Recurse -Include *.c,*.h
$owner = @{}
foreach ($f in $files) {
    $rel = $f.FullName.Substring($srcDir.Length + 1).Replace('\', '/')
    if ($owner.ContainsKey($f.Name)) { Write-Host "WARN duplicate header name: $($f.Name)" }
    $owner[$f.Name] = (Get-Layer $rel)
}

$violations = @()
$scanned = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($srcDir.Length + 1).Replace('\', '/')
    $selfLayer = Get-Layer $rel
    foreach ($line in Get-Content -LiteralPath $f.FullName -Encoding UTF8) {
        $m = [regex]::Match($line, '^\s*#\s*include\s+"([^"]+)"')
        if (-not $m.Success) { continue }
        $scanned++
        $name = [IO.Path]::GetFileName($m.Groups[1].Value)
        if (-not $owner.ContainsKey($name)) { continue }   # system / third-party header
        $depLayer = $owner[$name]
        if ($allowed[$selfLayer] -notcontains $depLayer) {
            $violations += [pscustomobject]@{
                File      = "src/$rel"
                Include   = $name
                FromLayer = $selfLayer
                ToLayer   = $depLayer
            }
        }
    }
}

Write-Host "checked $($files.Count) files, $scanned quoted includes"
if ($violations.Count -eq 0) {
    Write-Host 'layer check: OK (no upward dependency)'
    exit 0
}

Write-Host ''
Write-Host "layer check: $($violations.Count) violation(s)"
$violations | ForEach-Object {
    Write-Host ("  {0}  includes {1}  ({2} -> {3})" -f $_.File, $_.Include, $_.FromLayer, $_.ToLayer)
}
exit 1

