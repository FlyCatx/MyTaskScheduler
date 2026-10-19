# fetch_deps.ps1 — 获取**真实**第三方依赖到 third_party/
#
#   * cJSON v1.7.18（必需）：单文件库，配置文件/JSON 解析/JSON 导出使用。
#   * libcurl 8.23.0（真实 HTTP 需要）：使用 curl.se 官方 Windows x64 预编译包，
#     包含头文件、libcurl-x64.dll 与 libcurl-x64.def；本脚本用 MSVC 的 lib.exe
#     由 .def 生成 MSVC 可用的导入库 libcurl.lib（官方包里只有 MinGW 的 .a）。
#
# 下载器策略：本仓库的开发环境里，系统 TLS（schannel）出口被拦截，
# 因此按顺序尝试 内置 Python → 内置 Node.js → curl.exe。
# 这三个都只是**获取依赖的工具**，不是正式软件的运行依赖。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1          # 取全部
#   powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1 -Cjson  # 只取 cJSON
#   powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1 -Curl   # 只取 libcurl
#   powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1 -Force  # 忽略已有文件

param(
    [switch]$Cjson,
    [switch]$Curl,
    [switch]$Force,
    [string]$Python = "",
    [string]$Node = ""
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$tp = Join-Path $repo "third_party"
New-Item -ItemType Directory -Force -Path $tp | Out-Null

if (-not $Cjson -and -not $Curl) { $Cjson = $true; $Curl = $true }

# 记录到控制台的校验值（同时写入 third_party/DEPENDENCIES.txt）
$script:records = @()

function Get-Hash([string]$path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

# ---------------------------------------------------------------- 下载器

function Resolve-Python {
    if (-not [string]::IsNullOrEmpty($Python)) { return $Python }
    $cands = @()
    if ($env:DSH_HOME) {
        $cands += (Join-Path $env:DSH_HOME "dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe")
    }
    foreach ($c in @("python", "python3", "py")) {
        try { $cands += (Get-Command $c -ErrorAction Stop).Source } catch { }
    }
    foreach ($c in $cands) {
        if (Test-Path $c) {
            try {
                $v = & $c -c "import sys;print(sys.version_info[0])" 2>$null
                if ($v -eq "3") { return $c }
            } catch { }
        }
    }
    return ""
}

function Resolve-Node {
    if (-not [string]::IsNullOrEmpty($Node)) { return $Node }
    $cands = @()
    if ($env:DSH_HOME) {
        $cands += (Join-Path $env:DSH_HOME "dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe")
    }
    foreach ($c in @("node", "nodejs")) {
        try { $cands += (Get-Command $c -ErrorAction Stop).Source } catch { }
    }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return ""
}

function Download-WithPython([string]$py, [string]$url, [string]$out) {
    $script = @'
import sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "TaskScheduler-fetch-deps/1.0"})
with urllib.request.urlopen(req, timeout=180) as r, open(out, "wb") as f:
    f.write(r.read())
print("ok")
'@
    $tmp = Join-Path $env:TEMP ("ts_dl_" + [guid]::NewGuid().ToString("N") + ".py")
    Set-Content -Path $tmp -Value $script -Encoding UTF8
    try {
        & $py $tmp $url $out | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Python 下载失败：$url" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Download-WithNode([string]$node, [string]$url, [string]$out) {
    $script = @'
const https = require("https"), fs = require("fs");
const url = process.argv[2], out = process.argv[3];
function get(u, redirects) {
  https.get(u, { timeout: 180000 }, r => {
    if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location && redirects > 0) {
      r.resume(); return get(r.headers.location, redirects - 1);
    }
    if (r.statusCode !== 200) { console.error("HTTP " + r.statusCode); process.exit(1); }
    const chunks = [];
    r.on("data", d => chunks.push(d));
    r.on("end", () => { fs.writeFileSync(out, Buffer.concat(chunks)); console.log("ok"); });
  }).on("error", e => { console.error(e.message); process.exit(1); });
}
get(url, 5);
'@
    $tmp = Join-Path $env:TEMP ("ts_dl_" + [guid]::NewGuid().ToString("N") + ".js")
    Set-Content -Path $tmp -Value $script -Encoding UTF8
    try {
        & $node $tmp $url $out | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Node 下载失败：$url" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Download-WithCurl([string]$url, [string]$out) {
    & curl.exe -sSL --fail --max-time 180 -o $out $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl 下载失败：$url" }
}

$script:downloader = $null

function Get-Downloader {
    if ($null -ne $script:downloader) { return $script:downloader }
    $py = Resolve-Python
    if (-not [string]::IsNullOrEmpty($py)) {
        $script:downloader = @{ kind = "python"; exe = $py }
        Write-Host "下载器：Python（$py）"
        return $script:downloader
    }
    $node = Resolve-Node
    if (-not [string]::IsNullOrEmpty($node)) {
        $script:downloader = @{ kind = "node"; exe = $node }
        Write-Host "下载器：Node.js（$node）"
        return $script:downloader
    }
    $script:downloader = @{ kind = "curl"; exe = "curl.exe" }
    Write-Host "下载器：curl.exe"
    return $script:downloader
}

function Download([string]$url, [string]$out) {
    $d = Get-Downloader
    switch ($d.kind) {
        "python" { Download-WithPython $d.exe $url $out }
        "node"   { Download-WithNode   $d.exe $url $out }
        "curl"   { Download-WithCurl   $url $out }
    }
}

function Fetch([string]$url, [string]$out, [string]$label, [string]$expectHash = "") {
    if ((Test-Path $out) -and -not $Force) {
        $h = Get-Hash $out
        if ([string]::IsNullOrEmpty($expectHash) -or $h -eq $expectHash) {
            Write-Host ("  [已有] {0}  sha256={1}" -f $label, $h)
            $script:records += ("{0,-46} {1,10}  {2}" -f $label, (Get-Item $out).Length, $h)
            return
        }
        Write-Host ("  [重取] {0} 现有哈希与预期不符" -f $label)
    }
    Write-Host ("  [下载] {0}" -f $url)
    Download $url $out
    $h = Get-Hash $out
    if (-not [string]::IsNullOrEmpty($expectHash) -and $h -ne $expectHash) {
        throw ("SHA-256 校验失败：{0}`n  期望 {1}`n  实际 {2}" -f $label, $expectHash, $h)
    }
    Write-Host ("  [完成] {0}  sha256={1}" -f $label, $h)
    $script:records += ("{0,-46} {1,10}  {2}" -f $label, (Get-Item $out).Length, $h)
}

# ---------------------------------------------------------------- cJSON

if ($Cjson) {
    Write-Host ""
    Write-Host "== cJSON v1.7.18（必需）=="
    $base = "https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18"
    Fetch "$base/cJSON.h" (Join-Path $tp "cJSON.h") "third_party/cJSON.h"
    Fetch "$base/cJSON.c" (Join-Path $tp "cJSON.c") "third_party/cJSON.c"
    Fetch "$base/LICENSE" (Join-Path $tp "LICENSE") "third_party/LICENSE"
}

# ---------------------------------------------------------------- libcurl

if ($Curl) {
    Write-Host ""
    Write-Host "== libcurl 8.23.0（官方 Windows x64 预编译包）=="
    $zipUrl = "https://curl.se/windows/dl-8.23.0_1/curl-8.23.0_1-win64-mingw.zip"
    $zip = Join-Path $env:TEMP "curl-8.23.0_1-win64-mingw.zip"
    Fetch $zipUrl $zip "curl-8.23.0_1-win64-mingw.zip"

    $stage = Join-Path $env:TEMP "ts_curl_stage"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    $root = Join-Path $stage "curl-8.23.0_1-win64-mingw"
    if (-not (Test-Path $root)) { throw "解压后的目录结构不符合预期：$root" }

    $ct = Join-Path $tp "curl"
    New-Item -ItemType Directory -Force -Path "$ct\include", "$ct\lib", "$ct\bin", "$ct\licenses" | Out-Null
    Copy-Item (Join-Path $root "include\curl") "$ct\include\curl" -Recurse -Force
    Copy-Item (Join-Path $root "bin\libcurl-x64.dll") "$ct\bin\" -Force
    Copy-Item (Join-Path $root "bin\libcurl-x64.def") "$ct\lib\" -Force
    # TLS 根证书包（curl.se 官方随包提供，源自 Mozilla CA 列表）。
    # 放在 bin/ 下，构建时会被复制到 exe 同目录；程序只用它做证书校验，
    # 缺少时明确报错，绝不关闭校验。
    $caSrc = Join-Path $root "bin\curl-ca-bundle.crt"
    if (Test-Path $caSrc) {
        Copy-Item $caSrc "$ct\bin\cacert.pem" -Force
        Write-Host "  已复制 TLS 根证书包 -> $ct\bin\cacert.pem"
    } else {
        Write-Warning "随包未找到 curl-ca-bundle.crt：HTTPS 会因缺少 CA 包而失败（不会关闭校验）"
    }
    Copy-Item (Join-Path $root "COPYING.txt") "$ct\licenses\curl-COPYING.txt" -Force
    foreach ($dep in @(
            @("libressl", "COPYING.txt", "libressl-COPYING.txt"),
            @("nghttp2", "COPYING.txt", "nghttp2-COPYING.txt"),
            @("nghttp3", "COPYING.txt", "nghttp3-COPYING.txt"),
            @("ngtcp2", "COPYING.txt", "ngtcp2-COPYING.txt"),
            @("brotli", "LICENSE.txt", "brotli-LICENSE.txt"),
            @("zstd", "LICENSE.txt", "zstd-LICENSE.txt"),
            @("libssh2", "COPYING.txt", "libssh2-COPYING.txt"),
            @("libpsl", "COPYING.txt", "libpsl-COPYING.txt"))) {
        $src = Join-Path $root ("dep\" + $dep[0] + "\" + $dep[1])
        if (Test-Path $src) { Copy-Item $src (Join-Path "$ct\licenses" $dep[2]) -Force }
    }
    $zlib = Join-Path $root "dep\zlibng\LICENSE.md"
    if (Test-Path $zlib) { Copy-Item $zlib "$ct\licenses\zlibng-LICENSE.md" -Force }

    # 由 .def 生成 MSVC 导入库（官方包只带 MinGW 的 .a）
    Write-Host "  生成 MSVC 导入库 libcurl.lib ..."
    $vcvars = ""
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -property installationPath
        if ($vsPath) {
            $cand = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $cand) { $vcvars = $cand }
        }
    }
    if ([string]::IsNullOrEmpty($vcvars)) {
        throw "找不到 vcvars64.bat（需要 Visual Studio 的 C++ 生成工具来生成导入库）"
    }
    $bat = Join-Path $env:TEMP ("ts_mklib_" + [guid]::NewGuid().ToString("N") + ".bat")
    @"
@echo off
call "$vcvars" >nul 2>&1
cd /d "$ct\lib"
lib.exe /nologo /def:libcurl-x64.def /machine:x64 /out:libcurl.lib
exit /b %ERRORLEVEL%
"@ | Set-Content -Path $bat -Encoding ASCII
    try {
        & cmd.exe /c "`"$bat`""
        if ($LASTEXITCODE -ne 0) { throw "lib.exe 生成 libcurl.lib 失败" }
    } finally {
        Remove-Item $bat -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  已生成 $ct\lib\libcurl.lib"

    foreach ($f in @("curl\include\curl\curl.h", "curl\bin\libcurl-x64.dll",
                     "curl\lib\libcurl-x64.def", "curl\lib\libcurl.lib")) {
        $p = Join-Path $tp $f
        if (Test-Path $p) {
            $h = Get-Hash $p
            $script:records += ("{0,-46} {1,10}  {2}" -f ("third_party/" + ($f -replace '\\', '/')),
                                (Get-Item $p).Length, $h)
        }
    }
}

# ---------------------------------------------------------------- 记录

$depFile = Join-Path $tp "DEPENDENCIES.txt"
$lines = @()
$lines += "TaskScheduler 第三方依赖清单（由 scripts/fetch_deps.ps1 生成）"
$lines += ("生成时间：" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$lines += ""
$lines += ("{0,-46} {1,10}  {2}" -f "文件", "字节", "SHA-256")
$lines += ("-" * 120)
$lines += $script:records
[System.IO.File]::WriteAllLines($depFile, $lines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "依赖已就绪，清单写入 $depFile"
Write-Host "下一步：powershell -ExecutionPolicy Bypass -File scripts/build.ps1"

