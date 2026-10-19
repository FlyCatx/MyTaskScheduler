# run_with_key_env.ps1 — 从命令行启动 GUI，并让本进程继承 DEEPSEEK_API_KEY。
#
# 为什么需要它：
#   本程序**故意不从配置文件读取密钥**，只从环境变量读取（避免密钥落到磁盘文件里）。
#   而通过 `setx` / 系统属性设置的“用户环境变量”，只会被**之后新启动**的进程继承；
#   已经打开的 cmd / PowerShell / 资源管理器有时候不会更新，导致双击 exe 时读不到密钥。
#   本脚本显式把密钥读进**当前进程**再启动 exe，可绕开这个“父进程没有新变量”的坑。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/run_with_key_env.ps1
#   ... -KeyEnv MY_DEEPSEEK_KEY          # 换一个环境变量名
#   ... -Exe "dist\...\TaskScheduler.exe" -Config "dist\...\config.json"
#   ... -Mock                            # 离线演示，不需要密钥
#
# 安全约定：
#   * 本脚本**不打印**密钥内容，只报告“是否存在 / 长度”；
#   * 密钥通过**继承**传给子进程，不作为命令参数（避免被任务管理器/进程列表看到）；
#   * 本脚本不把密钥写入任何文件。

param(
    [string]$KeyEnv = "DEEPSEEK_API_KEY",
    [string]$Exe    = "",
    [string]$Config = "",
    [switch]$Mock
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrEmpty($Exe)) {
    # 优先用最新发布包，其次用构建产物
    $cands = @(
        (Join-Path $repo "dist\TaskScheduler-1.0.1-win64-x64-prerelease\TaskScheduler.exe"),
        (Join-Path $repo "build-vs\Release\TaskScheduler.exe")
    )
    foreach ($c in $cands) { if (Test-Path $c) { $Exe = $c; break } }
}
if (-not (Test-Path $Exe)) {
    Write-Error "找不到程序：$Exe（请先运行 scripts/build.ps1 或 scripts/make_release.ps1）"
    exit 2
}
$Exe = (Resolve-Path $Exe).Path

if ([string]::IsNullOrEmpty($Config)) {
    $same = Join-Path (Split-Path -Parent $Exe) "config.json"
    if (Test-Path $same) { $Config = $same }
}
if (-not [string]::IsNullOrEmpty($Config)) { $Config = (Resolve-Path $Config).Path }

# ---- 读取密钥（User 作用域 → 当前进程），只在内存中传递 ----
$val = [Environment]::GetEnvironmentVariable($KeyEnv, 'User')
if ([string]::IsNullOrEmpty($val)) {
    $val = [Environment]::GetEnvironmentVariable($KeyEnv, 'Process')
}

Write-Host "程序    : $Exe"
if (-not [string]::IsNullOrEmpty($Config)) { Write-Host "配置    : $Config" }
Write-Host "密钥变量: $KeyEnv"

if ($Mock) {
    Write-Host "模式    : mock（离线演示，不需要密钥）" -ForegroundColor Yellow
    $args = @("--mock")
    if (-not [string]::IsNullOrEmpty($Config)) { $args = @("--config", $Config) + $args }
    & $Exe @args
    exit $LASTEXITCODE
}

if ([string]::IsNullOrEmpty($val)) {
    Write-Host ""
    Write-Warning "环境变量 $KeyEnv 不存在或为空，程序会在发出请求前明确报错（不会发无鉴权请求）。"
    Write-Host "请先设置（新开一个窗口执行一次即可，之后重启本脚本）："
    Write-Host ""
    Write-Host "  [Environment]::SetEnvironmentVariable('$KeyEnv','<你的密钥>','User')" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "或者用系统界面：Win+R → sysdm.cpl → 高级 → 环境变量 → 新建用户变量。"
    Write-Host "（提醒：改完必须重新启动本程序，运行中的进程不会自动继承新变量。）"
    exit 3
}

# 关键：写进**本进程**环境，子进程通过继承拿到，不作为命令行参数
[Environment]::SetEnvironmentVariable($KeyEnv, $val, 'Process')

# 只报告长度与“格式是否可疑”，绝不打印密钥内容
$ctrlCount = ($val.ToCharArray() | Where-Object { [int]$_ -lt 32 -or [int]$_ -eq 127 } | Measure-Object).Count
$fmtNote = "正常"
if ($val.Length -eq 0) {
    $fmtNote = "空"
} elseif ([char]::IsWhiteSpace($val[0]) -or [char]::IsWhiteSpace($val[-1])) {
    $fmtNote = "首尾有空白 —— 程序会拒绝，请重新设置"
} elseif ($ctrlCount -gt 0) {
    $fmtNote = "含控制字符 —— 程序会拒绝，请重新设置"
}
Write-Host ("密钥    : 已读取（长度 {0}，格式检查: {1}）" -f $val.Length, $fmtNote)

$launchArgs = @()
if (-not [string]::IsNullOrEmpty($Config)) { $launchArgs += @("--config", $Config) }

Write-Host "启动中…" -ForegroundColor Green
& $Exe @launchArgs
exit $LASTEXITCODE

