#requires -Version 5.1
<#
.SYNOPSIS
    Builds the offline OCR helper (tools/ocr_host/OcrHost.cs) into a standalone
    .NET Framework 4.8 executable and writes a machine-readable build-info.json.

.DESCRIPTION
    The helper uses two OS components only:
      * Windows.Media.Ocr      - the OCR engine that ships with Windows 10/11
      * Windows.Data.Pdf       - Windows' own PDF rasteriser
    There is no NuGet, no Tesseract data, no Python and no network access at
    build or run time. The compiler is the one that ships with .NET Framework
    4.8 (C# 5, which is why OcrHost.cs avoids newer syntax); if the Visual
    Studio Roslyn csc.exe is present it is used instead, with the same
    references.

    Output:
      <OutDir>\ocr_host.exe
      <OutDir>\build-info.json   (version, SHA256, compile command, SDK/refs)

.PARAMETER OutDir
    Output directory. Default: tools/ocr_host/bin (repo-relative).

.PARAMETER Clean
    Delete the output directory before building.

.EXAMPLE
    pwsh -File scripts/build_ocr_host.ps1
    pwsh -File scripts/build_ocr_host.ps1 -OutDir out/round3/ocr -Clean
#>
[CmdletBinding()]
param(
    [string]$OutDir = 'tools/ocr_host/bin',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$hostVersion = '1.0.0'

function Get-RepoRoot {
    # scripts/build_ocr_host.ps1 -> repo root is the parent of scripts/
    $root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    return (Resolve-Path -LiteralPath $root).Path
}

function Find-FrameworkDir {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319')
    )
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $dir 'csc.exe')) { return $dir }
    }
    throw '找不到 .NET Framework 4.x 编译器目录（csc.exe）。'
}

function Find-RoslynCsc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $roots = @()
    if (Test-Path -LiteralPath $vswhere) {
        try {
            $roots = & $vswhere -latest -products * -property installationPath 2>$null
        } catch { $roots = @() }
    }
    if (-not $roots) {
        $roots = @(
            'C:\Program Files\Microsoft Visual Studio\18\Community',
            'C:\Program Files\Microsoft Visual Studio\2022\Community',
            'C:\Program Files\Microsoft Visual Studio\2022\BuildTools'
        )
    }
    foreach ($root in $roots) {
        $csc = Join-Path $root 'MSBuild\Current\Bin\Roslyn\csc.exe'
        if (Test-Path -LiteralPath $csc) { return $csc }
    }
    return $null
}

function Find-WindowsWinmd {
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\UnionMetadata'
    if (-not (Test-Path -LiteralPath $sdkRoot)) {
        throw "找不到 Windows SDK UnionMetadata 目录：$sdkRoot"
    }
    # Prefer the highest SDK version that actually contains Windows.winmd.
    $candidates = Get-ChildItem -LiteralPath $sdkRoot -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object {
            $winmd = Join-Path $_.FullName 'Windows.winmd'
            if (Test-Path -LiteralPath $winmd) {
                [pscustomobject]@{ Version = $_.Name; Path = $winmd }
            }
        }
    if (-not $candidates) {
        # Older SDK layouts put Windows.winmd directly under UnionMetadata\.
        $direct = Join-Path $sdkRoot 'Windows.winmd'
        if (Test-Path -LiteralPath $direct) {
            return [pscustomobject]@{ Version = 'legacy'; Path = $direct }
        }
        throw "在 $sdkRoot 下找不到 Windows.winmd。请安装 Windows 10/11 SDK。"
    }
    return $candidates | Select-Object -First 1
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileVersion([string]$Path) {
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return "$($info.FileVersion)".Trim()
    } catch {
        return ''
    }
}

$repo = Get-RepoRoot
$out = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repo $OutDir }
$source = Join-Path $repo 'tools\ocr_host\OcrHost.cs'
$manifest = Join-Path $repo 'tools\ocr_host\OcrHost.manifest'
if (-not (Test-Path -LiteralPath $source)) { throw "找不到源码：$source" }
if (-not (Test-Path -LiteralPath $manifest)) { throw "找不到 manifest：$manifest" }

# Keep a single source of truth for the version: read it from the C# source.
$versionMatch = Select-String -LiteralPath $source -Pattern 'public const string Version = "([^"]+)"' |
    Select-Object -First 1
if ($versionMatch) { $hostVersion = $versionMatch.Matches[0].Groups[1].Value }

$frameworkDir = Find-FrameworkDir
$winmd = Find-WindowsWinmd
$roslyn = Find-RoslynCsc

$refs = @(
    $winmd.Path,
    (Join-Path $frameworkDir 'System.Runtime.WindowsRuntime.dll'),
    (Join-Path $frameworkDir 'System.Runtime.dll')
)
foreach ($ref in $refs) {
    if (-not (Test-Path -LiteralPath $ref)) { throw "缺少 WinRT 引用程序集：$ref" }
}

if ($Clean -and (Test-Path -LiteralPath $out)) {
    Remove-Item -LiteralPath $out -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

$exePath = Join-Path $out 'ocr_host.exe'
if (Test-Path -LiteralPath $exePath) { Remove-Item -LiteralPath $exePath -Force }

function Invoke-Csc([string]$Compiler, [string]$CompilerKind) {
    # Arguments are passed as separate process arguments (no embedded quotes):
    # the exact same element order is recorded in build-info.json.
    $arguments = @(
        '/nologo',
        '/target:exe',
        '/optimize+'
    )
    if ($CompilerKind -eq 'roslyn') {
        # /deterministic is a Roslyn-only switch; the .NET Framework csc rejects it.
        $arguments += '/deterministic+'
    }
    $arguments += ('/win32manifest:{0}' -f $manifest)
    $arguments += ('/out:{0}' -f $exePath)
    foreach ($ref in $refs) {
        $arguments += ('/r:{0}' -f $ref)
    }
    $arguments += $source
    Write-Host ("[{0}] {1}" -f $CompilerKind, $Compiler)
    Write-Host ('       ' + ($arguments -join ' '))
    $output = & $Compiler @arguments 2>&1
    $script:lastCscArgs = $arguments
    $exit = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    return $exit
}

$compiler = $null
$compilerKind = ''
if ($roslyn) {
    $compiler = $roslyn
    $compilerKind = 'roslyn'
}
if (-not $compiler) {
    $compiler = Join-Path $frameworkDir 'csc.exe'
    $compilerKind = 'framework'
}

$exitCode = Invoke-Csc -Compiler $compiler -CompilerKind $compilerKind
if ($exitCode -ne 0 -and $compilerKind -eq 'roslyn') {
    Write-Warning 'Roslyn 编译失败，改用 .NET Framework 自带 csc.exe 重试。'
    $compiler = Join-Path $frameworkDir 'csc.exe'
    $compilerKind = 'framework'
    $exitCode = Invoke-Csc -Compiler $compiler -CompilerKind $compilerKind
}
if ($exitCode -ne 0) {
    throw "OCR helper 编译失败（csc 退出码 $exitCode）。"
}
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "编译成功但找不到输出：$exePath"
}

$sourceHash = Get-Sha256 $source
$manifestHash = Get-Sha256 $manifest
$exeHash = Get-Sha256 $exePath
$exeBytes = (Get-Item -LiteralPath $exePath).Length
$compileCommand = $compiler + ' ' + ($script:lastCscArgs -join ' ')

$buildInfo = [ordered]@{
    schemaVersion    = 1
    hostName         = 'taskscheduler-ocr-host'
    hostVersion      = $hostVersion
    engine           = 'Windows.Media.Ocr'
    engineVersion    = 'Windows.Media.Ocr/' + [System.Environment]::OSVersion.Version.ToString()
    builtAtUtc       = [DateTime]::UtcNow.ToString('o')
    machine          = $env:COMPUTERNAME
    compiler         = [ordered]@{
        kind    = $compilerKind
        path    = $compiler
        version = Get-FileVersion $compiler
        # C# 5 is the language level of the .NET Framework csc; the source is
        # written to stay compatible with it.
        language = 'C# 5'
    }
    framework        = [ordered]@{
        directory = $frameworkDir
        version   = '4.8'
        release   = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    }
    windowsSdk       = [ordered]@{
        unionMetadata = $winmd.Version
        windowsWinmd  = $winmd.Path
        winmdSha256   = Get-Sha256 $winmd.Path
    }
    references       = @($refs)
    commandLine      = $compileCommand
    sources          = @(
        [ordered]@{ path = 'tools/ocr_host/OcrHost.cs'; sha256 = $sourceHash },
        [ordered]@{ path = 'tools/ocr_host/OcrHost.manifest'; sha256 = $manifestHash }
    )
    output           = [ordered]@{
        path   = 'ocr_host.exe'
        sha256 = $exeHash
        bytes  = $exeBytes
    }
    offline          = $true
    thirdPartyBinaries = @()
    notes            = @(
        'Windows.Media.Ocr and Windows.Data.Pdf are OS components; this repository ships no OCR binary or language data.',
        'Language packs must be installed in Windows (Settings > Time & Language > Language); the host reports missing languages explicitly.',
        'The build is deterministic: same sources + same compiler + same refs => same binary hash.'
    )
}

$buildInfoPath = Join-Path $out 'build-info.json'
$json = $buildInfo | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($buildInfoPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'OCR helper built:'
Write-Host ("  exe          : {0}" -f $exePath)
Write-Host ("  bytes        : {0}" -f $exeBytes)
Write-Host ("  sha256       : {0}" -f $exeHash)
Write-Host ("  build info   : {0}" -f $buildInfoPath)
Write-Host ("  compiler     : {0} ({1})" -f $compiler, $compilerKind)
Write-Host ("  windows sdk  : {0}" -f $winmd.Version)
Write-Host ("  source sha256: {0}" -f $sourceHash)
