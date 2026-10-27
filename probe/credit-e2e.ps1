<#
  端到端验证 Meter 的每日 Credits 看门狗（用桩脚本目录，绝不触碰真实领取脚本与 Qoder 界面）
  场景 A：错过时点且未达上限 -> 应自动补领一次
  场景 B：错过时点但已达上限 -> 应静默不再重试
  用法: powershell -File probe/credit-e2e.ps1
#>
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $env:APPDATA 'QoderMeter\settings.json'
$backup = "$settings.e2e-bak"

function Stop-MeterInstances {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*meter.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function New-StubDir([bool]$succeed) {
  $dir = Join-Path $env:TEMP ('qm-credit-e2e-' + (Get-Random))
  New-Item -ItemType Directory -Path (Join-Path $dir 'logs') -Force | Out-Null
  $yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
  @{ campaignDay = $yesterday; result = 'claimed'; at = 'stub'; version = 'stub' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding UTF8
  $ps = @'
param([switch]$DryRun, [switch]$Force, [switch]$NoNotify)
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $dir 'stub.log') -Value ("RUN " + (Get-Date -Format 'HH:mm:ss'))
if ($env:QM_STUB_FAIL) { exit 3 }
function Day { ([System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')).AddHours(-10).ToString('yyyy-MM-dd') }
[ordered]@{ campaignDay = (Day); result = 'claimed'; at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'); version = 'stub' } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding UTF8
exit 0
'@
  [System.IO.File]::WriteAllText((Join-Path $dir 'QoderDailyCredits.ps1'), $ps, [System.Text.UTF8Encoding]::new($false))
  return $dir
}

function Write-Settings([string]$dir, [int]$attempts) {
  $today = ([System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')).AddHours(-10).ToString('yyyy-MM-dd')
  $o = [ordered]@{
    layout = 'sidebar'; skin = 'auto'; fontSize = 'normal'; paused = $false
    creditAuto = $true; creditDir = $dir; creditAttemptDay = $today; creditAttempts = $attempts
  }
  $o | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settings -Encoding UTF8
}

function Run-Meter([int]$seconds) {
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $root 'src\meter.ps1'), '-AlwaysOn') -PassThru
  Start-Sleep -Seconds $seconds
  Stop-MeterInstances
  try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
}

if (-not (Test-Path (Split-Path $settings -Parent))) { New-Item -ItemType Directory -Path (Split-Path $settings -Parent) -Force | Out-Null }
if (Test-Path $settings) { Copy-Item $settings $backup -Force }
$logFile = Join-Path $env:APPDATA 'QoderMeter\meter.log'
if (Test-Path $logFile) { Remove-Item $logFile -Force }

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
  if ($ok) { $script:pass++; Write-Output ("  [PASS] $n  $d") } else { $script:fail++; Write-Output ("  [FAIL] $n  $d") }
}

try {
  Write-Output '=== 场景 A：错过时点 + 未达上限 -> 应自动补领 ==='
  Stop-MeterInstances
  $dirA = New-StubDir $true
  Write-Settings $dirA 0
  Run-Meter 14
  $ranA = Test-Path (Join-Path $dirA 'stub.log')
  $stateA = $null
  try { $stateA = Get-Content (Join-Path $dirA 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  Check '看门狗触发了补领' $ranA $(if ($ranA) { (Get-Content (Join-Path $dirA 'stub.log') -Raw) -replace '\s+', ' ' } else { 'stub.log 未生成' })
  Check '补领后状态变 claimed' ($stateA.result -eq 'claimed') ('result=' + $stateA.result + ' day=' + $stateA.campaignDay)
  $ml = ''
  if (Test-Path $logFile) { $ml = Get-Content $logFile -Raw -Encoding UTF8 }
  Check 'meter.log 记录了触发原因' ($ml -match '触发每日 Credits 补领') ('日志匹配=' + ($ml -match '触发每日'))
  Check '成功后计数未被误加' ($ml -notmatch '补领未成功') '无失败记录'
  Remove-Item $dirA -Recurse -Force -ErrorAction SilentlyContinue

  Write-Output ''
  Write-Output '=== 场景 B：错过时点 + 已达 3 次上限 -> 应静默 ==='
  Stop-MeterInstances
  $dirB = New-StubDir $true
  Write-Settings $dirB 3
  Run-Meter 12
  $ranB = Test-Path (Join-Path $dirB 'stub.log')
  Check '达上限后不再自动补领' (-not $ranB) $(if ($ranB) { '仍触发了：' + (Get-Content (Join-Path $dirB 'stub.log') -Raw) } else { '未触发，符合预期' })
  Remove-Item $dirB -Recurse -Force -ErrorAction SilentlyContinue

  Write-Output ''
  Write-Output '=== 场景 C：关闭自动补领 -> 应静默 ==='
  Stop-MeterInstances
  $dirC = New-StubDir $true
  Write-Settings $dirC 0
  $s = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
  $s.creditAuto = $false
  $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settings -Encoding UTF8
  Run-Meter 12
  $ranC = Test-Path (Join-Path $dirC 'stub.log')
  Check 'creditAuto=false 时不触发' (-not $ranC) $(if ($ranC) { '仍触发了' } else { '未触发，符合预期' })
  Remove-Item $dirC -Recurse -Force -ErrorAction SilentlyContinue
} finally {
  Stop-MeterInstances
  if (Test-Path $backup) { Copy-Item $backup $settings -Force; Remove-Item $backup -Force }
  else { Remove-Item $settings -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  Write-Output '（已恢复原 settings.json）'
}

Write-Output ("结果: PASS=" + $pass + " FAIL=" + $fail)
if ($fail -gt 0) { exit 1 }
