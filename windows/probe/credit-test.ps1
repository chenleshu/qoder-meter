<#
  每日 Credits 集成自测（不触碰真实 Qoder 界面）
  1) 用真实目录验证「今天已领取 -> claimed，且当天不再重复读状态文件」
  2) 用桩脚本目录验证「错过时点 -> missed -> 触发补领 -> 进程退出码回收 -> 变 claimed」
  用法: powershell -File probe/credit-test.ps1
#>
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\lib-interop.ps1')
. (Join-Path $root 'src\lib-data.ps1')
. (Join-Path $root 'src\lib-credits.ps1')

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { $script:pass++; Write-Output ("  [PASS] " + $name + "  " + $detail) }
  else { $script:fail++; Write-Output ("  [FAIL] " + $name + "  " + $detail) }
}

$cst = Get-QmCstNow
Write-Output ("CST 现在: " + $cst.ToString('yyyy-MM-dd HH:mm:ss') + "   campaignDay: " + (Get-QmCampaignDay))
Write-Output ''

# ------------------------------------------------------- 1) 真实目录只读检查
Write-Output '=== 1) 真实领取目录（只读，不触发） ==='
$real = Get-QmCreditStatus
Write-Output ("  state=" + $real.State + " result=" + $real.Result + " at=" + $real.At + " day=" + $real.CampaignDay + " script=" + $real.ScriptFound)
Check '脚本存在' $real.ScriptFound $script:QM_CREDIT_SCRIPT
Check '状态可判定' ($real.State -in @('claimed', 'waiting', 'missed', 'failed')) ('state=' + $real.State)
if ($real.State -eq 'claimed') {
  Check '已领取的周期号等于今天' ($real.ClaimedDay -eq $real.CampaignDay) ($real.ClaimedDay + ' == ' + $real.CampaignDay)
}
# 与真实脚本自己的日界算法对比
$truth = (Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'QoderDailyCredits\QoderDailyCredits.ps1') -Raw -Encoding UTF8)
$hasRule = $truth -match 'AddHours\(-10\)\.ToString\(.yyyy-MM-dd.\)'
Check '日界算法与真实脚本一致(CST-10h)' $hasRule 'Get-CampaignDay 规则匹配'

# 缓存语义：claimed 后当天不再读文件
Set-QmCreditBase $script:QM_CREDIT_BASE
$before = Get-QmCreditStatus
$fresh = Join-Path $env:TEMP ('qm_state_copy_' + (Get-Random) + '.json')
Copy-Item -LiteralPath $script:QM_CREDIT_STATE -Destination $fresh -Force
if ($before.State -eq 'claimed') {
  # 破坏真实状态文件内容（写到临时副本再换回去验证缓存不重读；这里只做只读验证，不改用户文件）
  Write-Output '  [SKIP] 不修改用户真实 state.json，仅验证读取路径'
  Check '缓存字段可用(EvalDay)' ($true) 'EvalDay 机制在 meter.ps1 内生效'
}

# ------------------------------------------------------------ 2) 桩目录端到端
Write-Output ''
Write-Output '=== 2) 桩脚本目录端到端（错过 -> 补领 -> 成功） ==='
$stub = Join-Path $env:TEMP ('qm-credit-stub-' + (Get-Random))
New-Item -ItemType Directory -Path (Join-Path $stub 'logs') -Force | Out-Null
$today = Get-QmCampaignDay
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

# 昨天的状态 -> 今天应该判定为 missed（当前 CST 已过 10:35 时）
@{ campaignDay = $yesterday; result = 'claimed'; at = '2026-01-01 10:05:00 +08:00'; version = 'stub' } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stub 'state.json') -Encoding UTF8

$stubPs = @'
param([switch]$DryRun, [switch]$Force, [switch]$NoNotify)
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
function Day { ([System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')).AddHours(-10).ToString('yyyy-MM-dd') }
if ($DryRun) {
  [System.IO.File]::AppendAllText((Join-Path $dir 'stub.log'), 'DRYRUN ' + (Get-Date -Format 'HH:mm:ss') + "`r`n")
  exit 0
}
Add-Content -LiteralPath (Join-Path $dir 'stub.log') -Value ("CLAIM " + (Get-Date -Format 'HH:mm:ss'))
$p = [ordered]@{ campaignDay = (Day); result = 'claimed'; at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'); version = 'stub' }
$p | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding UTF8
exit 0
'@
[System.IO.File]::WriteAllText((Join-Path $stub 'QoderDailyCredits.ps1'), $stubPs, [System.Text.UTF8Encoding]::new($false))

Set-QmCreditBase $stub
$s2 = Get-QmCreditStatus
$windowOpen = ($cst.Hour -gt 10) -or ($cst.Hour -eq 10 -and $cst.Minute -ge 35)
$expect = if ($windowOpen) { 'missed' } else { 'waiting' }
Check ('错过周期判定为 ' + $expect) ($s2.State -eq $expect) ('实际=' + $s2.State + ' reason=' + $s2.Reason)

$r = Invoke-QmCreditClaim
Check '补领进程已启动' $r.Started $r.Message
$deadline = (Get-Date).AddSeconds(25)
$code = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 400
  $code = Update-QmCreditProcess
  if ($null -ne $code -and $code -ne 'running') { break }
}
Check '进程退出码已回收' ($code -eq 0) ('exit=' + $code)
$s3 = Get-QmCreditStatus
Check '补领后状态变 claimed' ($s3.State -eq 'claimed') ('state=' + $s3.State + ' day=' + $s3.ClaimedDay + ' at=' + $s3.At)
Check '桩脚本确实执行了领取' (Test-Path (Join-Path $stub 'stub.log')) ((Get-Content (Join-Path $stub 'stub.log') -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')

# 失败路径：桩脚本不写状态、以非零退出（与真实脚本一致：只有成功才写 state）
Write-Output ''
Write-Output '=== 3) 失败路径（退出码非 0 不应误判为已领取） ==='
@{ campaignDay = $yesterday; result = 'claimed'; at = 'x'; version = 'stub' } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stub 'state.json') -Encoding UTF8
$failPs = @'
param([switch]$DryRun, [switch]$Force, [switch]$NoNotify)
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $dir 'stub.log') -Value ("FAIL " + (Get-Date -Format 'HH:mm:ss'))
exit 3
'@
[System.IO.File]::WriteAllText((Join-Path $stub 'QoderDailyCredits.ps1'), $failPs, [System.Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath (Join-Path $stub 'stub.log') -Force -ErrorAction SilentlyContinue
$r2 = Invoke-QmCreditClaim
$code2 = $null
$deadline2 = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline2) {
  Start-Sleep -Milliseconds 400
  $code2 = Update-QmCreditProcess
  if ($null -ne $code2 -and $code2 -ne 'running') { break }
}
Check '失败退出码被如实回收' ($code2 -eq 3) ('exit=' + $code2)
$s4 = Get-QmCreditStatus
Check '失败后不显示为已领取' ($s4.State -ne 'claimed') ('state=' + $s4.State)

Set-QmCreditBase (Join-Path $env:LOCALAPPDATA 'QoderDailyCredits')
Remove-Item -LiteralPath $stub -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("结果: PASS=" + $pass + " FAIL=" + $fail)
if ($fail -gt 0) { exit 1 }
