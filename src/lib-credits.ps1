# Qoder Meter Credits integration. Campaign day is UTC+8 minus ten hours.
# Only local state confirms success; an exit code (including DryRun=0) never does.
$script:QM_CREDIT_BASE = Join-Path $env:LOCALAPPDATA 'QoderDailyCredits'

function Set-QmCreditBase([string]$dir) {
  if ($dir) {
    $dir = [IO.Path]::GetFullPath($dir).TrimEnd([char[]]@('\', '/'))
    if ($dir -ne $script:QM_CREDIT_BASE) { $script:QM_CREDIT_CACHE = $null }
    $script:QM_CREDIT_BASE = $dir
  }
  $script:QM_CREDIT_DIR = $script:QM_CREDIT_BASE
  $script:QM_CREDIT_SCRIPT = Join-Path $script:QM_CREDIT_BASE 'QoderDailyCredits.ps1'
  $script:QM_CREDIT_STATE = Join-Path $script:QM_CREDIT_BASE 'state.json'
  $script:QM_CREDIT_LOGDIR = Join-Path $script:QM_CREDIT_BASE 'logs'
}
Set-QmCreditBase ''

$script:QM_CREDIT_GRACE_MIN = 35
$script:QM_CREDIT_MAX_ATTEMPTS = 3
$script:QM_CREDIT_RETRY_MS = 1800000
$script:QM_CREDIT_READ_MS = 30000
$script:QM_CREDIT_TIMEOUT_MS = 180000

function Get-QmCstNow {
  try {
    return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
  } catch {
    return [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).DateTime
  }
}
function Get-QmCampaignDay { return (Get-QmCstNow).AddHours(-10).ToString('yyyy-MM-dd') }

# Persist Unix milliseconds, not process uptime. All credit clocks use this injectable clock.
function Get-QmCreditNowMs {
  $cst = [DateTime]::SpecifyKind((Get-QmCstNow), [DateTimeKind]::Unspecified)
  return ([DateTimeOffset]::new($cst, [TimeSpan]::FromHours(8))).ToUnixTimeMilliseconds()
}

# Idempotent; never clears a claimed cache or resets a running process.
function Initialize-QmCreditRuntime {
  if (-not $script:CREDIT) { $script:CREDIT = @{} }
  $defaults = @{ Status = $null; EvalDay = ''; Running = $false; LastAttempt = 0L; LastRead = 0L; AttemptStarting = $false }
  foreach ($key in $defaults.Keys) {
    if (-not $script:CREDIT.ContainsKey($key)) { $script:CREDIT[$key] = $defaults[$key] }
  }
  if (-not $script:QM_CREDIT_CACHE) {
    # Private cache deliberately survives generic UI resets of CREDIT.Status/EvalDay/LastRead.
    $script:QM_CREDIT_CACHE = @{ Raw = $null; HasRead = $false; LastRead = 0L; ClaimedStatus = $null }
  }
}

# Public local reader shares the throttle, even if called directly by a menu action.
function Read-QmCreditState {
  Initialize-QmCreditRuntime
  $cache = $script:QM_CREDIT_CACHE
  $day = Get-QmCampaignDay
  $now = Get-QmCreditNowMs
  if ($cache.Raw -and $cache.Raw.campaignDay -eq $day -and $cache.Raw.result -in @('claimed', 'already_claimed')) {
    return $cache.Raw
  }
  if ($cache.HasRead -and ($now - $cache.LastRead) -lt $script:QM_CREDIT_READ_MS) { return $cache.Raw }
  $raw = $null
  try {
    if (Test-Path -LiteralPath $script:QM_CREDIT_STATE) {
      $text = [IO.File]::ReadAllText($script:QM_CREDIT_STATE)
      if ($text) { $raw = $text | ConvertFrom-Json -ErrorAction Stop }
    }
  } catch { }
  $cache.Raw = $raw
  $cache.LastRead = $now
  $cache.HasRead = $true
  $script:CREDIT.LastRead = $now
  return $raw
}

# Reevaluate the clock on every call, but read unclaimed local state at most every 30s.
function Get-QmCreditStatus {
  Initialize-QmCreditRuntime
  $cache = $script:QM_CREDIT_CACHE
  $cst = Get-QmCstNow
  $day = $cst.AddHours(-10).ToString('yyyy-MM-dd')
  if ($cache.ClaimedStatus -and $cache.ClaimedStatus.CampaignDay -eq $day) { return $cache.ClaimedStatus }
  $now = Get-QmCreditNowMs
  if (-not $cache.HasRead -or ($now - $cache.LastRead) -ge $script:QM_CREDIT_READ_MS) {
    $cache.Raw = Read-QmCreditState
    $cache.LastRead = $now
    $cache.HasRead = $true
  }
  $script:CREDIT.LastRead = $cache.LastRead
  $st = $cache.Raw
  $out = [pscustomobject][ordered]@{
    State = 'unknown'; CampaignDay = $day; ClaimedDay = ''; At = ''; Result = ''
    Version = ''; ScriptFound = (Test-Path -LiteralPath $script:QM_CREDIT_SCRIPT); Reason = ''
  }
  if ($st) {
    $out.Result = [string]$st.result; $out.At = [string]$st.at
    $out.Version = [string]$st.version; $out.ClaimedDay = [string]$st.campaignDay
  }
  if ($st -and $st.campaignDay -eq $day -and $st.result -in @('claimed', 'already_claimed')) {
    $out.State = 'claimed'
    $cache.ClaimedStatus = $out
  } elseif (-not $out.ScriptFound) {
    $out.State = 'missing'; $out.Reason = '未找到 ' + $script:QM_CREDIT_SCRIPT
  } elseif ($cst.Hour -eq 10 -and $cst.Minute -lt $script:QM_CREDIT_GRACE_MIN) {
    # 00:00-09:59 belongs to yesterday's campaign; its grace period has already elapsed.
    $out.State = 'waiting'; $out.Reason = '等计划任务 10:05/10:30 触发'
  } elseif ($st -and $st.campaignDay -eq $day) {
    $out.State = 'failed'; $out.Reason = '本周期已尝试但未成功：' + [string]$st.result
  } else {
    $out.State = 'missed'; $out.Reason = '本周期尚未领取，计划任务可能因关机/睡眠错过'
  }
  return $out
}

function Format-QmCreditLabel([string]$state) {
  switch ($state) {
    'claimed' { return '已领取' }
    'waiting' { return '待领取' }
    'missed'  { return '需补领' }
    'failed'  { return '领取失败' }
    'missing' { return '未安装领取脚本' }
    default  { return '状态未知' }
  }
}

# The installed claimant has no mutex. This is a conservative preflight, not an
# atomic lock with Task Scheduler: a non-cooperating external launch can still race.
# Never terminate or attach ownership to any process found here.
function Test-QmCreditClaimBusy {
  $target = [IO.Path]::GetFullPath($script:QM_CREDIT_SCRIPT)
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
    if ($process.ProcessId -eq $PID) { continue }
    if (-not $process.CommandLine) { throw '无法检查现有 PowerShell 进程命令行，取消补领' }
    $match = [regex]::Match([string]$process.CommandLine, '(?i)(?:^|\s)-(?:File|f)\s+(?:"([^"]+)"|(\S+))')
    if (-not $match.Success) { continue }
    $file = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
    try { if ([IO.Path]::GetFullPath($file) -eq $target) { return $true } } catch { }
  }
  return $false
}

# Narrow process-creation boundary; the caller owns the returned Process object.
function Start-QmCreditProcess($StartInfo) {
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $StartInfo
  try {
    if (-not $p.Start()) { throw '无法启动领取进程' }
    return $p
  } catch { $p.Dispose(); throw }
}

# Legacy low-level API; real UI callers should use Start-QmCreditAttempt for policy/persistence.
# DryRun is intentionally now a LOCAL read, never a claimant/UI launch.
function Invoke-QmCreditClaim([switch]$DryRun) {
  Initialize-QmCreditRuntime
  $res = [pscustomobject][ordered]@{ Started = $false; ExitCode = -1; Message = ''; DryRun = [bool]$DryRun; Status = $null }
  if ($DryRun) {
    $res.Status = Get-QmCreditStatus; $res.Message = '仅读取本地领取状态，未执行领取'
    return $res
  }
  if ($script:QM_CREDIT_PROC -or $script:QM_CREDIT_LAUNCHING) { $res.Message = '上一次领取还没结束'; return $res }
  $res.Status = Get-QmCreditStatus
  if ($res.Status.State -eq 'claimed') { $res.Message = '本周期已领取'; return $res }
  $script:QM_CREDIT_LAUNCHING = $true
  try {
    if (-not (Test-Path -LiteralPath $script:QM_CREDIT_SCRIPT)) { $res.Message = '领取脚本不存在'; return $res }
    if (Test-QmCreditClaimBusy) { $res.Message = '已有领取脚本正在运行，未重复启动'; return $res }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:QM_CREDIT_SCRIPT + '" -NoNotify'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = Start-QmCreditProcess $psi
    if (-not $p) { throw '未返回领取进程' }
    $script:QM_CREDIT_PROC = $p
    $script:QM_CREDIT_PROC_AT = Get-QmCreditNowMs
    $script:QM_CREDIT_PROC_TIMEOUT = $false
    $script:QM_CREDIT_PROC_CAN_KILL = $false
    # Pin its OS handle while it is ours. No PID/name lookup is ever used for cleanup.
    try { $script:QM_CREDIT_PROC_CAN_KILL = ($p.Handle -ne [IntPtr]::Zero -and $p.Id -ne $PID) } catch { }
    $script:CREDIT.Running = $true
    $res.Started = $true; $res.Message = '已启动领取进程 PID ' + $p.Id
  } catch { $res.Message = '启动失败: ' + $_.Exception.Message }
  finally { $script:QM_CREDIT_LAUNCHING = $false }
  return $res
}

# Returns null, 'running', an exit code, or 'timedout'. Fail closed if ownership
# cannot be inspected or a kill fails: never discard a possibly running child.
function Update-QmCreditProcess {
  $p = $script:QM_CREDIT_PROC
  if (-not $p) { return $null }
  try {
    if (-not $p.HasExited) {
      if ($script:QM_CREDIT_PROC_CAN_KILL -and -not $script:QM_CREDIT_PROC_TIMEOUT -and
          ((Get-QmCreditNowMs) - $script:QM_CREDIT_PROC_AT) -ge $script:QM_CREDIT_TIMEOUT_MS) {
        $p.Kill()
        $script:QM_CREDIT_PROC_TIMEOUT = $true
      }
      if (-not $p.HasExited) { return 'running' }
    }
    $code = $p.ExitCode
    if ($script:QM_CREDIT_PROC_TIMEOUT) { $code = 'timedout' }
    $script:QM_CREDIT_PROC = $null
    $script:CREDIT.Running = $false
    try { $p.Dispose() } catch { }
    return $code
  } catch { return 'running' }
}

# Public policy API. -Manual bypasses auto-enable/grace/activity gates, but shares
# the 3/campaign budget and persisted 30-minute backoff. -DryRun is local-only.
# Result: Started, ExitCode (-1 until polled), Message, DryRun, Status.
function Start-QmCreditAttempt([switch]$Manual, [switch]$DryRun) {
  Initialize-QmCreditRuntime
  $c = $script:CREDIT
  $status = Get-QmCreditStatus
  $c.Status = $status; $c.EvalDay = $status.CampaignDay
  $res = [pscustomobject][ordered]@{ Started = $false; ExitCode = -1; Message = ''; DryRun = [bool]$DryRun; Status = $status }
  if ($DryRun) { $res.Message = '仅读取本地领取状态，未执行领取'; return $res }
  if ($script:QM_CREDIT_PROC -or $script:QM_CREDIT_LAUNCHING -or $c.AttemptStarting) {
    $res.Message = '上一次领取还没结束'; return $res
  }
  if ($status.State -eq 'claimed') { $res.Message = '本周期已领取'; return $res }
  if (-not $Manual) {
    if (-not $script:CFG.creditAuto -or $status.State -notin @('missed', 'failed')) { $res.Message = '当前不需要自动补领'; return $res }
    $now = Get-QmCreditNowMs
    if ($script:QM_S.inFlight -or ($script:QM_S.lastEventAt -and ($now - $script:QM_S.lastEventAt) -lt 20000) -or -not $script:QoderWin) {
      $res.Message = '等待 Qoder 空闲且窗口可用'; return $res
    }
  }
  $day = $status.CampaignDay
  $attempts = 0
  if ([string]$script:CFG.creditAttemptDay -eq $day) { $attempts = [int]$script:CFG.creditAttempts }
  if ($attempts -ge $script:QM_CREDIT_MAX_ATTEMPTS) {
    $res.Message = '本周期已达补领尝试上限（3 次）'; $status.Reason = $res.Message; return $res
  }
  $now = Get-QmCreditNowMs
  $last = [long]$script:CFG.creditLastAttempt
  if ($last -and ($now - $last) -lt $script:QM_CREDIT_RETRY_MS) {
    $res.Message = '距离上次尝试不足 30 分钟'; return $res
  }
  $oldDay = $script:CFG.creditAttemptDay; $oldCount = $script:CFG.creditAttempts
  $c.AttemptStarting = $true
  try {
    $script:CFG.creditAttemptDay = $day
    $script:CFG.creditAttempts = $attempts + 1
    $script:CFG.creditLastAttempt = $now
    try {
      # Save-QmConfig must throw or return false on failure; void/true means durable.
      $saved = Save-QmConfig
      if ($saved -is [bool] -and -not $saved) { throw 'Save-QmConfig returned false' }
    } catch {
      $script:CFG.creditAttemptDay = $oldDay; $script:CFG.creditAttempts = $oldCount; $script:CFG.creditLastAttempt = $last
      $res.Message = '无法保存补领尝试，未启动: ' + $_.Exception.Message
      return $res
    }
    $c.LastAttempt = $now
    # Failed process creation still consumes this durable attempt and backoff.
    $res = Invoke-QmCreditClaim
    $res.Status = $status
    if ($res.Started) { Show-QmBalloon '正在补领今日 Credits' 'Qoder 会短暂打开权益中心。' }
    return $res
  } finally { $c.AttemptStarting = $false }
}

# Timer entry point: process maintenance, throttled observation, then bounded auto policy.
function Update-QmCreditState {
  Initialize-QmCreditRuntime
  $c = $script:CREDIT
  $code = Update-QmCreditProcess
  $c.Running = [bool]$script:QM_CREDIT_PROC
  $previous = $c.Status
  $c.Status = Get-QmCreditStatus
  $c.EvalDay = $c.Status.CampaignDay
  if ($c.Status.State -eq 'claimed') {
    if ($null -ne $code -and $code -ne 'running' -and (-not $previous -or $previous.State -ne 'claimed')) {
      Show-QmBalloon '今日 Credits 已领取' '本地状态已确认领取成功。'
    }
    return
  }
  if ($c.Running -or $c.AttemptStarting) { return }
  $null = Start-QmCreditAttempt
}
