# run_http_tests.ps1 — 阶段 2：本地 HTTP 集成测试的一键运行脚本。
#
# 做三件事：
#   1. 在回环地址上启动测试用的模拟 OpenAI 兼容服务（tests/mock_server.py）；
#   2. 运行 ts_test_http（用真实 libcurl 连接本地服务，逐场景断言）；
#   3. 无论成败都关闭模拟服务，并清理临时文件。
#
# 依赖：Python 3（测试期依赖，不进入发布包）与已构建的 build-vs\Release\ts_test_http.exe。
# 用法：
#   pwsh -File tests/run_http_tests.ps1 [-Exe <path>] [-Scenario <name>] [-Python <path>]

param(
    [string]$Exe = "",
    [string]$Scenario = "",
    [string]$Python = "",
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) {
    $Exe = Join-Path $repo "build-vs\Release\ts_test_http.exe"
}
if (-not (Test-Path $Exe)) {
    Write-Error "找不到测试程序：$Exe（请先构建 ts_test_http 目标）"
    exit 2
}
if (-not (Test-Path (Join-Path $PSScriptRoot "mock_server.py"))) {
    Write-Error "找不到 tests/mock_server.py"
    exit 2
}

# 找一个可用的 Python
if ([string]::IsNullOrEmpty($Python)) {
    $candidates = @()
    if ($env:DSH_HOME) {
        $candidates += (Join-Path $env:DSH_HOME "dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe")
    }
    $candidates += "python", "python3", "py"
    foreach ($c in $candidates) {
        try {
            $cmd = Get-Command $c -ErrorAction Stop
            $ver = & $cmd.Source -c "import sys;print(sys.version_info[0])" 2>$null
            if ($ver -eq "3") { $Python = $cmd.Source; break }
        } catch { }
    }
}
if ([string]::IsNullOrEmpty($Python)) {
    Write-Error "找不到 Python 3（仅测试期需要，可用 -Python 指定路径）"
    exit 2
}

$work = Join-Path $repo "build-vs\http-test-work"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$control = Join-Path $work "mock_control.json"
$count = Join-Path $work "mock_count.json"
$portFile = Join-Path $work "mock_port.json"
$serverLog = Join-Path $work "mock_server.log"
$trace = Join-Path $work "mock_last_response.json"
$traceReq = Join-Path $work "mock_last_request.json"

Remove-Item $portFile -Force -ErrorAction SilentlyContinue

$serverArgs = @(
    (Join-Path $PSScriptRoot "mock_server.py"),
    "--host", "127.0.0.1",
    "--port", "$Port",
    "--control", $control,
    "--count", $count,
    "--port-file", $portFile,
    "--trace", $trace,
    "--trace-request", $traceReq
)
$proc = Start-Process -FilePath $Python -ArgumentList $serverArgs -PassThru -NoNewWindow `
    -RedirectStandardError $serverLog -RedirectStandardOutput (Join-Path $work "mock_server.out")

try {
    # 等待端口文件出现
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path $portFile)) {
        if ((Get-Date) -gt $deadline) { throw "模拟服务启动超时" }
        Start-Sleep -Milliseconds 100
    }
    $info = Get-Content $portFile -Raw | ConvertFrom-Json
    $base = "http://$($info.host):$($info.port)"
    Write-Host "模拟服务已启动：$base"

    $fixtures = Join-Path $PSScriptRoot "data\mock_responses"
    $argv = @($base, $work, $fixtures)
    if (-not [string]::IsNullOrEmpty($Scenario)) { $argv += $Scenario }

    & $Exe @argv
    $code = $LASTEXITCODE
} finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "模拟服务已关闭。"
    }
}

exit $code

