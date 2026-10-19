# make_release.ps1 — 生成 Windows x64 便携 ZIP 发布包（含清单与 SHA-256）。
#
# 只做“打包”，不做“验收”。正式发布前请先确认 VERIFICATION.md 中的准入条件全部满足。
# 默认标注为预发布（--pre-release），包内 README 会说明云端验收状态，避免误当成正式版。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/make_release.ps1
#   ... -Version 1.0.0 -PreRelease:$false      # 正式版（仅在云端验收通过后使用）
#   ... -OutDir dist

param(
    [string]$BuildDir = "build-vs",
    [string]$Config = "Release",
    [string]$Version = "1.0.0",
    [string]$OutDir = "dist",
    [switch]$PreRelease = $true,
    [string]$PreReleaseNote = "",
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$rel = Join-Path $repo (Join-Path $BuildDir $Config)
$exe = Join-Path $rel "TaskScheduler.exe"
if (-not (Test-Path $exe)) { Write-Error "找不到 $exe（请先运行 scripts/build.ps1）"; exit 2 }

$suffix = if ($PreRelease) { "-prerelease" } else { "" }
$pkgName = "TaskScheduler-$Version-win64-x64$suffix"
$stage = Join-Path $repo (Join-Path $OutDir $pkgName)
$zip = Join-Path $repo (Join-Path $OutDir "$pkgName.zip")

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Write-Host "== 打包 $pkgName =="

# ------------------------------------------------------------------ 主程序
Copy-Item $exe $stage -Force

# ------------------------------------------------------------------ 非系统 DLL
# 只复制“实际被依赖且不是 Windows 系统组件”的 DLL：用 dumpbin /dependents 核实。
$vcvars = ""
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -property installationPath
    if ($vs) {
        $cand = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $cand) { $vcvars = $cand }
    }
}

$copied = @()
$systemDlls = @(
    'kernel32','user32','gdi32','advapi32','shell32','ole32','oleaut32','comdlg32',
    'comctl32','ws2_32','wldap32','normaliz','bcrypt','crypt32','secur32','iphlpapi',
    'winspool','uuid','shlwapi','version','mswsock','dnsapi','netapi32','userenv',
    'ntdll','api-ms-win-crt','ucrtbase','vcruntime','msvcp','ucrtbased','vcruntimed'
)

# 候选 DLL：libcurl（真实 HTTP 必需）+ 运行库（若为动态链接则一并带上）
$candidates = @()
$curlDll = Join-Path $repo "third_party\curl\bin\libcurl-x64.dll"
if (Test-Path $curlDll) { $candidates += $curlDll }

if (-not [string]::IsNullOrEmpty($vcvars)) {
    $bat = Join-Path $env:TEMP ("ts_dep_" + [guid]::NewGuid().ToString("N") + ".bat")
    $outFile = Join-Path $env:TEMP ("ts_dep_" + [guid]::NewGuid().ToString("N") + ".txt")
    $targets = @($exe) + $candidates
    $cmd = "@echo off`r`ncall `"$vcvars`" >nul 2>&1`r`n"
    foreach ($t in $targets) {
        $cmd += "echo === $t === >> `"$outFile`"`r`n"
        $cmd += "dumpbin /nologo /dependents `"$t`" >> `"$outFile`" 2>&1`r`n"
    }
    Set-Content -Path $bat -Value $cmd -Encoding ASCII
    & cmd.exe /c "`"$bat`""
    Remove-Item $bat -Force -ErrorAction SilentlyContinue

    if (Test-Path $outFile) {
        $deps = @()
        foreach ($line in Get-Content $outFile) {
            if ($line -match '^\s+([A-Za-z0-9_\-\.]+\.dll)\s*$') { $deps += $Matches[1] }
        }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        $nonSystem = $deps | Sort-Object -Unique | Where-Object {
            $n = $_.ToLower() -replace '\.dll$',''
            -not ($systemDlls | Where-Object { $n -like "$_*" })
        }
        if ($nonSystem.Count -gt 0) {
            Write-Host "  检测到非系统 DLL 依赖：$($nonSystem -join ', ')"
            foreach ($d in $nonSystem) {
                # 优先从 exe 目录找（libcurl 会由构建复制到这里）
                $p = Join-Path $rel $d
                if (Test-Path $p) { $candidates += $p }
                else { Write-Warning "  未在构建目录找到 $d，请手工确认并补充到发布包" }
            }
        }
    }
}

$seenDll = @{}
foreach ($c in ($candidates | Sort-Object -Unique)) {
    $name = Split-Path -Leaf $c
    if ($seenDll.ContainsKey($name.ToLower())) { continue }   # 同一 DLL 只复制一次
    $seenDll[$name.ToLower()] = $true
    Copy-Item $c (Join-Path $stage $name) -Force
    $copied += $name
}
Write-Host "  已复制 DLL：$(if ($copied.Count) { $copied -join ', ' } else { '（无）' })"

# TLS 根证书包（HTTPS 必需；程序不会关闭证书校验）
$ca = Join-Path $repo "third_party\curl\bin\cacert.pem"
if (Test-Path $ca) {
    Copy-Item $ca (Join-Path $stage "cacert.pem") -Force
    Write-Host "  已复制 cacert.pem（TLS 根证书包）"
} else {
    Write-Warning "  缺少 cacert.pem：发布包将无法通过 HTTPS 调用云端"
}

# ------------------------------------------------------------------ 配置模板
Copy-Item (Join-Path $repo "config.example.json") (Join-Path $stage "config.example.json") -Force

# 本地兼容模型配置模板（不联网、无鉴权）
$localCfg = @'
{
  "endpoint_url": "http://127.0.0.1:11434/v1/chat/completions",
  "model": "把这里换成你本地服务的模型名",
  "api_key_env": "",
  "ca_bundle_path": "cacert.pem",
  "reasoning_effort": null,
  "connect_timeout_ms": 15000,
  "wait_prompt_ms": 120000,
  "request_timeout_ms": 0,
  "max_output_tokens": 8000,
  "max_input_bytes": 262144,
  "max_response_bytes": 2097152,
  "json_mode": true,
  "temperature": 0.2,
  "reference_hours": 2.0,
  "weights": { "urgency": 0.35, "impact": 0.30, "blocking": 0.20, "quick_win": 0.10, "depth": 0.05 },
  "max_tasks": 200,
  "max_steps_per_task": 50,
  "max_retry_attempts": 1,
  "mock_mode": false
}
'@
[System.IO.File]::WriteAllText((Join-Path $stage "config.local.example.json"), $localCfg,
                               (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ 文档
$docs = @{
    "README.md"       = (Join-Path $repo "README.md")
    "DESIGN.md"       = (Join-Path $repo "DESIGN.md")
    "VERIFICATION.md" = (Join-Path $repo "VERIFICATION.md")
    "CHANGELOG.md"    = (Join-Path $repo "CHANGELOG.md")
}
foreach ($k in $docs.Keys) {
    if (Test-Path $docs[$k]) { Copy-Item $docs[$k] $stage -Force }
}

# 第三方许可证
$lic = Join-Path $stage "licenses"
New-Item -ItemType Directory -Force -Path $lic | Out-Null
$licFiles = @{
    "cJSON-LICENSE.txt"   = (Join-Path $repo "third_party\LICENSE")
}
$curlLic = Join-Path $repo "third_party\curl\licenses"
if (Test-Path $curlLic) {
    Get-ChildItem $curlLic -File | ForEach-Object { Copy-Item $_.FullName $lic -Force }
}
foreach ($k in $licFiles.Keys) {
    if (Test-Path $licFiles[$k]) { Copy-Item $licFiles[$k] (Join-Path $lic $k) -Force }
}

# cJSON 说明（版权与来源）
$cjsonNote = @"
cJSON
=====
来源：https://github.com/DaveGamble/cJSON （tag v1.7.18）
许可证：MIT（见 licenses/cJSON-LICENSE.txt）
用途：配置文件解析、模型输出解析、JSON 导出。
未做任何修改（逐字节使用上游文件）。
"@
[System.IO.File]::WriteAllText((Join-Path $lic "cJSON-NOTICE.txt"), $cjsonNote,
                               (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ 版本与包内说明
$verInfo = @()
$verInfo += "TaskScheduler 版本：$Version"
$verInfo += ("打包时间：" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$verInfo += ("发布类型：" + $(if ($PreRelease) { "预发布（PRE-RELEASE）" } else { "正式版" }))
if ($PreRelease) {
    $verInfo += ""
    $verInfo += "!! 本包为预发布版本，不能称为正式验收版本。"
    $verInfo += "!! 原因：$(if ($PreReleaseNote) { $PreReleaseNote } else { '云端（真实 DeepSeek API）端到端验收状态见 VERIFICATION.md' })"
}
$verInfo += ""
$verInfo += "运行环境要求："
$verInfo += "  * Windows 10 1809 或更高（x64）"
$verInfo += "  * 需要 Universal C Runtime（Windows 10 及以上系统自带）"
$verInfo += "  * 不需要安装 Visual Studio；不需要单独安装 libcurl"
$verInfo += ""
$verInfo += "包内文件："
$verInfo += "  TaskScheduler.exe            主程序（Win32 Unicode GUI）"
$verInfo += "  libcurl-x64.dll              真实 HTTP 所需的 libcurl"
$verInfo += "  cacert.pem                   TLS 根证书包（HTTPS 证书校验，必需）"
$verInfo += "  config.example.json          云端（DeepSeek）配置模板"
$verInfo += "  config.local.example.json    本地兼容模型配置模板"
$verInfo += "  README.md / DESIGN.md        使用与设计说明"
$verInfo += "  VERIFICATION.md              验证矩阵（哪些实测通过、哪些未执行）"
$verInfo += "  CHANGELOG.md                 变更记录"
$verInfo += "  licenses/                    第三方许可证与来源说明"
$verInfo += "  MANIFEST.sha256              包内每个文件的 SHA-256"
[System.IO.File]::WriteAllText((Join-Path $stage "VERSION.txt"),
                               ($verInfo -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ SHA-256 清单
$manifest = @()
foreach ($f in (Get-ChildItem $stage -Recurse -File | Sort-Object FullName)) {
    $relPath = $f.FullName.Substring($stage.Length + 1) -replace '\\','/'
    $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
    $manifest += ("{0}  {1}" -f $h, $relPath)
}
[System.IO.File]::WriteAllLines((Join-Path $stage "MANIFEST.sha256"), $manifest,
                                (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  已生成 MANIFEST.sha256（$($manifest.Count) 个文件）"

# ------------------------------------------------------------------ 打包前自检
$problems = @()
if (-not (Test-Path (Join-Path $stage "libcurl-x64.dll"))) { $problems += "缺少 libcurl-x64.dll" }
if (-not (Test-Path (Join-Path $stage "cacert.pem"))) { $problems += "缺少 cacert.pem" }

# 不得包含密钥/用户材料/测试工具/构建中间产物
$forbidden = @('mock_server.py','run_http_tests.ps1','ts_test*.exe','ts_core.lib','cjson.lib',
               '*.pdb','*.obj','*.exp','*.lib','mock_control.json','mock_count.json',
               'mock_last_response.json','mock_last_request.json')
foreach ($pat in $forbidden) {
    $hit = Get-ChildItem $stage -Recurse -File -Filter $pat -ErrorAction SilentlyContinue
    if ($hit) { $problems += ("不应包含：" + ($hit | ForEach-Object { $_.Name }) -join ', ') }
}
$skFiles = Get-ChildItem $stage -Recurse -File | Where-Object {
    (Select-String -Path $_.FullName -Pattern 'sk-[A-Za-z0-9]{20,}' -Quiet -ErrorAction SilentlyContinue)
}
if ($skFiles) { $problems += ("疑似包含密钥的文件：" + ($skFiles | ForEach-Object { $_.Name }) -join ', ') }

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Warning "发布包自检发现问题："
    $problems | ForEach-Object { Write-Warning "  * $_" }
    if (-not $SkipVerify) { exit 1 }
}

# ------------------------------------------------------------------ ZIP
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()

Write-Host ""
Write-Host "== 发布包 =="
Write-Host "  ZIP      : $zip"
Write-Host "  大小     : $([math]::Round((Get-Item $zip).Length / 1MB, 2)) MiB"
Write-Host "  SHA-256  : $zipHash"
Write-Host ""
Get-ChildItem $stage -Recurse -File | ForEach-Object {
    Write-Host ("  {0,-34} {1,10} 字节" -f ($_.FullName.Substring($stage.Length + 1)), $_.Length)
}

