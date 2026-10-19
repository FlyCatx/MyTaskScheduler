# build.ps1 — 可复现的构建脚本（真实依赖 + 独立构建目录）。
#
# 特征：
#   * 使用**独立构建目录**（默认 build-vs），绝不沿用旧对象文件或旧 EXE；
#     -Clean 会先整目录删除再重建。
#   * 使用真实 cJSON（third_party/cJSON.c）与真实 libcurl（third_party/curl）。
#   * 明确记录编译器、架构、CMake 与构建命令。
#   * 构建后可选运行全部控制台测试（-Test）与 Python 静态校验（-StaticChecks）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/build.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Clean -Test
#   powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -BuildDir build-debug -Config Debug
#
# 说明：本仓库开发环境里 CMake 的 Ninja 生成器会卡在 try_compile（沙箱下子进程管道受限），
# 因此默认使用 Visual Studio 生成器。若你的环境 Ninja 正常，可用 -Generator Ninja。

param(
    [string]$BuildDir = "build-vs",
    [ValidateSet("Release", "Debug", "RelWithDebInfo")]
    [string]$Config = "Release",
    [string]$Generator = "Visual Studio 18 2026",
    [string]$Arch = "x64",
    [switch]$Clean,
    [switch]$Test,
    [switch]$StaticChecks,
    [switch]$NoTests
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Find-CMake {
    $cands = @()
    if ($env:DSH_HOME) { }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -property installationPath
        if ($vs) {
            $cands += (Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
        }
    }
    try { $cands += (Get-Command cmake -ErrorAction Stop).Source } catch { }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return ""
}

$cmake = Find-CMake
if ([string]::IsNullOrEmpty($cmake)) {
    Write-Error "找不到 CMake。请安装 CMake ≥ 3.16（或使用带 CMake 组件的 Visual Studio）。"
    exit 2
}

# ---- 依赖检查（真实依赖，不用桩） ----
$missing = @()
foreach ($f in @("third_party\cJSON.c", "third_party\cJSON.h")) {
    if (-not (Test-Path $f)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Write-Error ("缺少 cJSON：{0}`n请先运行 powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1" -f ($missing -join ", "))
    exit 2
}
$haveCurl = (Test-Path "third_party\curl\include\curl\curl.h") -and (Test-Path "third_party\curl\lib\libcurl.lib")
if (-not $haveCurl) {
    Write-Warning "未找到 third_party/curl：将构建不含真实 HTTP 的版本（仅 mock 模式）。"
    Write-Warning "如需真实 HTTP，请运行 scripts/fetch_deps.ps1 -Curl"
}

$absBuild = Join-Path $repo $BuildDir
if ($Clean -and (Test-Path $absBuild)) {
    Write-Host "清理构建目录：$absBuild"
    Remove-Item $absBuild -Recurse -Force
}

Write-Host ""
Write-Host "== 配置 =="
$cfgArgs = @("-S", $repo, "-B", $absBuild, "-G", $Generator)
if ($Generator -like "Visual Studio*") { $cfgArgs += @("-A", $Arch) }
if ($Generator -eq "Ninja") { $cfgArgs += "-DCMAKE_BUILD_TYPE=$Config" }
& $cmake @cfgArgs
if ($LASTEXITCODE -ne 0) { Write-Error "CMake 配置失败"; exit 1 }

Write-Host ""
Write-Host "== 构建（$Config） =="
& $cmake --build $absBuild --config $Config
if ($LASTEXITCODE -ne 0) { Write-Error "构建失败"; exit 1 }

$outDir = if ($Generator -like "Visual Studio*") { Join-Path $absBuild $Config } else { $absBuild }
Write-Host ""
Write-Host "== 产物（$outDir） =="
Get-ChildItem $outDir -File -Include *.exe, *.dll | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-26} {1,10} 字节" -f $_.Name, $_.Length) }

# ---- 编译器与依赖版本记录 ----
$compiler = "未知"
$cl = Get-ChildItem "${env:ProgramFiles}\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | Select-Object -First 1
if ($cl) { $compiler = $cl.FullName }

$record = @()
$record += "构建时间：" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$record += "CMake：" + ((& $cmake --version | Select-Object -First 1))
$record += "生成器：$Generator $Arch"
$record += "配置：$Config"
$record += "编译器：$compiler"
$record += "构建目录：$absBuild"
$record += "真实 HTTP（libcurl）：" + ($(if ($haveCurl) { "已启用" } else { "未启用（仅 mock）" }))
$record += ""
$record += "构建命令："
$record += ("  " + $cmake + " " + ($cfgArgs -join " "))
$record += ("  " + $cmake + " --build `"$absBuild`" --config $Config")
$recordFile = Join-Path $outDir "BUILD-INFO.txt"
[System.IO.File]::WriteAllLines($recordFile, $record, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "构建信息写入 $recordFile"

# ---- 测试 ----
if ($Test -and -not $NoTests) {
    Write-Host ""
    Write-Host "== 运行控制台测试 =="
    $tests = @("ts_test_initonce", "ts_test_validate", "ts_test3", "ts_test4",
               "ts_test6", "ts_test", "ts_test_model", "ts_test_plan", "ts_test_export_json",
               "ts_test_gui", "ts_test_auth_offline",
               "ts_test_settings", "ts_test_probe")
    $failed = @()
    foreach ($t in $tests) {
        $exe = Join-Path $outDir "$t.exe"
        if (-not (Test-Path $exe)) { Write-Host "  [跳过] $t（未构建）"; continue }
        # ts_test_auth_offline / ts_test_settings / ts_test_probe 需要一个可写工作目录
        & $exe $outDir | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0) { $failed += $t }
    }
    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Warning ("以下测试失败：{0}" -f ($failed -join ", "))
        exit 1
    }
    Write-Host "全部控制台/GUI 测试通过。"
    Write-Host "鉴权相关的本地 HTTP 集成测试：powershell -ExecutionPolicy Bypass -File tests/run_auth_http_tests.ps1"
    Write-Host "本地 HTTP 集成测试：powershell -ExecutionPolicy Bypass -File tests/run_http_tests.ps1"
    Write-Host "TLS 传输层测试（需联网）：ts_test_model_tls.exe cacert.pem"
}

if ($StaticChecks) {
    Write-Host ""
    Write-Host "== Python 静态校验 =="
    $py = ""
    $pyCands = @()
    if ($env:DSH_HOME) {
        $pyCands += (Join-Path $env:DSH_HOME "dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe")
    }
    $pyCands += @("python", "python3", "py")
    foreach ($c in $pyCands) {
        try {
            $src = $c
            if ($c -notmatch '\\') { $src = (Get-Command $c -ErrorAction Stop).Source }
            if (-not (Test-Path $src)) { continue }
            $v = & $src -c "import sys;print(sys.version_info[0])" 2>$null
            if ($v -eq "3") { $py = $src; break }
        } catch { }
    }
    if ([string]::IsNullOrEmpty($py)) {
        Write-Warning "找不到 Python 3，跳过静态校验（不影响构建结果）"
    } else {
        $failed = @()
        foreach ($s in @("tests\validate_mock.py", "tests\validate_prompt.py", "tests\validate_export.py")) {
            Write-Host "  -- $s"
            & $py $s
            if ($LASTEXITCODE -ne 0) { $failed += $s }
        }
        if ($failed.Count -gt 0) {
            Write-Warning ("静态校验失败：{0}" -f ($failed -join ", "))
            exit 1
        }
        Write-Host "静态校验全部通过。"
    }
}

Write-Host ""
Write-Host "完成。可执行文件：$(Join-Path $outDir 'TaskScheduler.exe')"

