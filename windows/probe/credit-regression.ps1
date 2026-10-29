#requires -Version 5.1
# Isolated regression suite: no claimant, user settings, state files or UI are used.
[CmdletBinding()]
param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { [IO.Path]::GetFullPath($RepositoryRoot) } else { Split-Path $PSScriptRoot -Parent }
$probeDir = Join-Path $root 'probe'
# Loading source in memory also permits PS5.1 expression-based testing without changing policy.
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'src\lib-credits.ps1'))))
$script:RawReader = ${function:Read-QmCreditState}
$script:ProcessFactory = ${function:Start-QmCreditProcess}
$script:BusyChecker = ${function:Test-QmCreditClaimBusy}
$script:Pass = 0
$script:Fail = 0

function Assert-Equal($actual, $expected, [string]$because) {
  if ($actual -ne $expected) { throw "$because : expected [$expected], got [$actual]" }
}
function Assert-True($actual, [string]$because) {
  if (-not $actual) { throw $because }
}
function At([string]$time) { $script:Clock = [datetime]::ParseExact($time, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) }
function Get-QmCstNow { return $script:Clock }
function QmNowMs { return ([DateTimeOffset]::new($script:Clock, [TimeSpan]::FromHours(8))).ToUnixTimeMilliseconds() }
function Write-QmLog([string]$text) { }
function Show-QmBalloon([string]$title, [string]$text) { $script:Notices += $title }
function Save-QmConfig {
  if ($script:SaveFails) { throw 'simulated persistence failure' }
  if ($script:SaveReturnsFalse) { return $false }
  $script:Saved = $script:CFG | ConvertTo-Json | ConvertFrom-Json
  $script:Events += 'save'
}
# Mock only external boundaries. Keep policy, cache and process lifecycle code real.
function Read-QmCreditState { $script:Reads++; return $script:ExternalState }
function Test-QmCreditClaimBusy { return $script:ExternalBusy }
function Get-CimInstance { return $script:Processes }
function Start-QmCreditProcess($StartInfo) {
  $script:Events += 'launch'
  $script:Launches++
  if ($script:RequireSaved) {
    Assert-True ($script:Saved -and $script:Saved.creditAttempts -eq $script:CFG.creditAttempts) 'attempt must be persisted before launch'
    Assert-Equal $script:Saved.creditLastAttempt (QmNowMs) 'backoff must be persisted before launch'
  }
  if ($script:LaunchFails) { throw 'simulated launch failure' }
  if ($script:UseRealFactory) {
    # A harmless command-only child, never a script/claimant or UI automation.
    $StartInfo.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
    $script:SmokeProcess = & $script:ProcessFactory $StartInfo
    return $script:SmokeProcess
  }
  return $script:FakeProcess
}
function New-FakeProcess {
  $p = [pscustomobject]@{ Id = 2147483000; Handle = [IntPtr]123; HasExited = $false; ExitCode = 0; Kills = 0; Disposed = $false; KillFails = $false }
  $p | Add-Member ScriptMethod Kill { $this.Kills++; if ($this.KillFails) { throw 'simulated kill failure' }; $this.HasExited = $true }
  $p | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
  return $p
}
function Reset-Case {
  $script:CREDIT = @{ Status = $null; EvalDay = ''; Running = $false; LastAttempt = 0L; LastRead = 0L }
  $script:QM_CREDIT_CACHE = $null
  $script:QM_CREDIT_PROC = $null
  $script:QM_CREDIT_LAUNCHING = $false
  $script:CFG = [pscustomobject]@{ creditAuto = $false; creditDir = $probeDir; creditAttemptDay = ''; creditAttempts = 0; creditLastAttempt = 0L }
  $script:QM_S = @{ inFlight = $false; lastEventAt = 0L }
  $script:QoderWin = [pscustomobject]@{ Hwnd = 1L; Pid = 123L; L = 0; T = 0; R = 100; B = 100; W = 100; H = 100; Dpi = 96; WorkL = 0; WorkT = 0; WorkR = 100; WorkB = 100; Fullscreen = $false }
  Set-QmCreditBase $probeDir
  # Existing inert file for ScriptFound; the process factory above never executes it.
  $script:QM_CREDIT_SCRIPT = Join-Path $root 'src\lib-credits.ps1'
  $script:ExternalState = $null
  $script:Reads = 0; $script:Launches = 0; $script:Events = @(); $script:Notices = @()
  $script:Saved = $null; $script:SaveFails = $false; $script:LaunchFails = $false
  $script:SaveReturnsFalse = $false
  $script:RequireSaved = $true; $script:ExternalBusy = $false
  $script:UseRealFactory = $false; $script:SmokeProcess = $null; $script:Processes = @()
  $script:FakeProcess = New-FakeProcess
  At '2026-10-25 10:35:00'
}
function Claimed([string]$day, [string]$result = 'claimed') {
  $script:ExternalState = [pscustomobject]@{ campaignDay = $day; result = $result; at = 'fixture'; version = 'test' }
}
function Test-Case([string]$name, [scriptblock]$body) {
  try { Reset-Case; & $body; $script:Pass++; Write-Output "PASS $name" }
  catch { $script:Fail++; Write-Output "FAIL $name -- $($_.Exception.Message)" }
}

# Mutations caught: calendar-day/grace comparisons, never-expiring waiting cache.
Test-Case '09:59 belongs to yesterday and permits catchup' {
  At '2026-10-25 09:59:00'
  $s = Get-QmCreditStatus
  Assert-Equal $s.CampaignDay '2026-10-24' 'campaign boundary'
  Assert-Equal $s.State 'missed' 'yesterday grace has elapsed'
}
Test-Case '10:00 and 10:34 wait; 10:35 reevaluates without extra read' {
  At '2026-10-25 10:00:00'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'waiting' 'new cycle'
  At '2026-10-25 10:34:50'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'waiting' 'grace interval'
  $before = $script:Reads
  At '2026-10-25 10:35:00'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'missed' 'grace expired'
  Assert-Equal $script:Reads $before 'clock transition does not force IO'
}
Test-Case 'early catchup automatically starts for previous campaign' {
  At '2026-10-25 09:59:00'; $script:CFG.creditAuto = $true
  Update-QmCreditState
  Assert-Equal $script:Launches 1 'catchup launches'
  Assert-Equal $script:CFG.creditAttemptDay '2026-10-24' 'budget follows campaign'
}
Test-Case 'external success appears after 30 seconds and then never rereads' {
  Update-QmCreditState
  Assert-Equal $script:Reads 1 'initial read'
  Claimed '2026-10-25' 'already_claimed'
  At '2026-10-25 10:35:29'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'missed' 'poll is throttled'
  Assert-Equal $script:Reads 1 'no early read'
  At '2026-10-25 10:35:30'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'claimed' 'scheduled success observed'
  $before = $script:Reads
  $script:ExternalState = $null
  foreach ($time in @('2026-10-25 11:00:00', '2026-10-26 00:00:00', '2026-10-26 09:59:00')) {
    At $time
    $script:CREDIT.EvalDay = ''; $script:CREDIT.Status = $null; $script:CREDIT.LastRead = 0L
    $null = Get-QmCreditStatus
    Update-QmCreditState
    Assert-Equal $script:CREDIT.Status.State 'claimed' 'refresh cannot invalidate claimed cache'
  }
  Assert-Equal $script:Reads $before 'zero reads after claimed, including midnight'
  At '2026-10-26 10:00:00'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'waiting' 'new campaign invalidates claimed cache'
  Assert-Equal $script:Reads ($before + 1) 'new cycle reads again'
}
Test-Case 'generic local reads obey the same 30-second throttle' {
  $null = Get-QmCreditStatus
  1..5 | ForEach-Object { $null = Get-QmCreditStatus; Update-QmCreditState }
  Assert-Equal $script:Reads 1 'one central cache for all callers'
}
Test-Case 'reapplying the same base preserves claimed cache' {
  Claimed '2026-10-25'; $null = Get-QmCreditStatus
  $before = $script:Reads
  Set-QmCreditBase $probeDir
  Assert-Equal (Get-QmCreditStatus).State 'claimed' 'same directory keeps success'
  Assert-Equal $script:Reads $before 'same-base refresh cannot force a read'
}
Test-Case 'new base invalidates old account status' {
  Claimed '2026-10-25'; $null = Get-QmCreditStatus
  Set-QmCreditBase $root
  $script:QM_CREDIT_SCRIPT = Join-Path $root 'src\lib-credits.ps1'; $script:ExternalState = $null
  Assert-Equal (Get-QmCreditStatus).State 'missed' 'different directory must not inherit success'
}
# Mutations caught: save-after-launch, failure-free budget, lost restart backoff.
Test-Case 'launch failures count, back off, and stop at three across restarts' {
  $script:CFG.creditAuto = $true; $script:LaunchFails = $true
  Update-QmCreditState
  Assert-Equal $script:Launches 1 'first launch attempted'
  Assert-Equal $script:CFG.creditAttempts 1 'failed launch counted'
  Assert-Equal ($script:Events -join ',') 'save,launch' 'persist before starting'
  $script:CFG = $script:Saved
  $script:CREDIT = @{ Status = $null; EvalDay = ''; Running = $false; LastAttempt = 0L; LastRead = 0L }
  At '2026-10-25 11:04:59'; Update-QmCreditState
  Assert-Equal $script:Launches 1 'restart retains 30-minute backoff'
  At '2026-10-25 11:05:00'; Update-QmCreditState
  At '2026-10-25 11:35:00'; Update-QmCreditState
  Assert-Equal $script:Launches 3 'third attempt allowed'
  Assert-Equal $script:Saved.creditAttempts 3 'budget persisted'
  $script:CFG = $script:Saved
  $script:CREDIT = @{ Status = $null; EvalDay = ''; Running = $false; LastAttempt = 0L; LastRead = 0L }
  At '2026-10-26 00:00:00'; Update-QmCreditState
  Assert-Equal $script:Launches 3 'midnight does not reset campaign budget'
  At '2026-10-26 10:35:00'; Update-QmCreditState
  Assert-Equal $script:Launches 4 'next campaign may retry'
  Assert-Equal $script:Saved.creditAttempts 1 'next campaign starts a new budget'
}
Test-Case 'failed persistence prevents launch and later retries persistence' {
  $script:CFG.creditAuto = $true; $script:SaveFails = $true
  $r = Start-QmCreditAttempt
  Assert-True (-not $r.Started) 'unsaved attempt cannot start'
  Assert-Equal $script:Launches 0 'fail closed on persistence error'
  $script:SaveFails = $false
  $r = Start-QmCreditAttempt
  Assert-True $r.Started 'saving later succeeds without consuming failed-save budget'
  Assert-Equal $script:Saved.creditAttempts 1 'only durable attempt counts'
}
Test-Case 'manual real attempt ignores auto toggle but shares bounded budget' {
  $r = Start-QmCreditAttempt -Manual
  Assert-True $r.Started 'explicit manual request launches'
  Assert-Equal $script:Saved.creditAttempts 1 'manual real attempt is recorded'
  $script:FakeProcess.HasExited = $true; Update-QmCreditState
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'manual cannot defeat backoff'
  Assert-Equal $script:Launches 1 'no rapid parallel or repeated UI'
}
Test-Case 'manual dryrun is local-only, not counted or relabeled success' {
  $r = Start-QmCreditAttempt -Manual -DryRun
  Assert-True (-not $r.Started) 'dryrun never launches claimant'
  $legacy = Invoke-QmCreditClaim -DryRun
  Assert-True (-not $legacy.Started) 'legacy dryrun is also local-only'
  Update-QmCreditState
  Assert-Equal $script:CFG.creditAttempts 0 'dryrun is not a claim attempt'
  Assert-Equal $script:Launches 0 'no UI subprocess'
  Assert-Equal $script:Events.Count 0 'dryrun does not persist changes'
  Assert-Equal $script:CREDIT.Status.State 'missed' 'dryrun cannot claim success'
  Assert-Equal $script:Notices.Count 0 'dryrun never announces success'
}
Test-Case 'claimed blocks manual and automatic attempts without reads' {
  Claimed '2026-10-25'; Update-QmCreditState
  $before = $script:Reads; $script:CFG.creditAuto = $true
  At '2026-10-25 12:00:00'; Update-QmCreditState
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'claimed manual is a no-op'
  Assert-Equal $script:Launches 0 'claimed never launches'
  Assert-Equal $script:Reads $before 'claimed never rereads'
}
Test-Case 'automatic claim respects generation, recent activity and window gates' {
  $script:CFG.creditAuto = $true; $script:QM_S.inFlight = $true
  Update-QmCreditState
  $script:QM_S.inFlight = $false; $script:QM_S.lastEventAt = QmNowMs
  Update-QmCreditState
  $script:QM_S.lastEventAt = 0L; $script:QoderWin = $null
  Update-QmCreditState
  Assert-Equal $script:Launches 0 'do not interrupt Qoder'
  Assert-Equal $script:CFG.creditAttempts 0 'gates do not spend attempts'
}
# Mutations caught: losing exact process ownership, duplicate launches, exit=0 => claimed.
Test-Case 'parallel own process blocked and exit zero does not imply success' {
  $r = Start-QmCreditAttempt -Manual
  Assert-True $r.Started 'first process starts'
  $owned = $script:QM_CREDIT_PROC
  $r2 = Start-QmCreditAttempt -Manual
  $r3 = Invoke-QmCreditClaim
  Assert-True (-not $r2.Started -and -not $r3.Started) 'all launch APIs guard ownership'
  Assert-True ([object]::ReferenceEquals($owned, $script:QM_CREDIT_PROC)) 'owned object retained'
  Assert-Equal $script:Launches 1 'only one subprocess'
  $owned.HasExited = $true; Update-QmCreditState
  Assert-True (-not $script:CREDIT.Running) 'completion clears running'
  Assert-Equal $script:CREDIT.Status.State 'missed' 'exit zero alone is not claimed'
  Assert-Equal $script:CFG.creditAttempts 1 'completion does not double count'
  Assert-True $owned.Disposed 'completed process disposed'
}
Test-Case 'completion respects poll throttle and external confirmation' {
  $null = Start-QmCreditAttempt -Manual
  Claimed '2026-10-25'; $script:FakeProcess.HasExited = $true
  At '2026-10-25 10:35:01'; Update-QmCreditState
  Assert-Equal $script:Reads 1 'completion does not force an extra read'
  At '2026-10-25 10:35:30'; Update-QmCreditState
  Assert-Equal $script:CREDIT.Status.State 'claimed' 'subsequent poll confirms actual success'
}
Test-Case 'external claimant prevents Meter UI launch' {
  $script:ExternalBusy = $true
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'existing claimant blocks launch'
  Assert-Equal $script:Launches 0 'external process is never replaced'
}
Test-Case '180-second timeout kills only owned object and releases after exit' {
  $null = Start-QmCreditAttempt -Manual
  $owned = $script:FakeProcess; $unrelated = New-FakeProcess
  At '2026-10-25 10:37:59'; Update-QmCreditState
  Assert-Equal $owned.Kills 0 'no premature timeout'
  At '2026-10-25 10:38:00'; Update-QmCreditState
  Update-QmCreditState
  Assert-Equal $owned.Kills 1 'exact child killed once'
  Assert-Equal $unrelated.Kills 0 'unrelated process untouched'
  Assert-True (-not $script:CREDIT.Running) 'timeout reaped'
  Assert-Equal $script:CFG.creditAttempts 1 'timeout is not another attempt'
}
Test-Case 'failed timeout kill retains ownership and blocks replacement' {
  $null = Start-QmCreditAttempt -Manual
  $script:FakeProcess.KillFails = $true
  At '2026-10-25 11:35:00'; Update-QmCreditState
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'unreaped child blocks new launch'
  Assert-True $script:CREDIT.Running 'running remains true until exit observed'
  Assert-Equal $script:Launches 1 'failed cleanup cannot create parallel child'
}
Test-Case 'explicit false save result prevents launch' {
  $script:SaveReturnsFalse = $true
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'false save result must fail closed'
  Assert-Equal $script:Launches 0 'not durable, not launched'
  Assert-Equal $script:CFG.creditAttempts 0 'restore unpersisted counter'
}
Test-Case 'legacy invoke also refuses a cached claimed campaign' {
  Claimed '2026-10-25'; $null = Get-QmCreditStatus
  $script:RequireSaved = $false
  $r = Invoke-QmCreditClaim
  Assert-True (-not $r.Started) 'legacy callers cannot relaunch an already claimed campaign'
  Assert-Equal $script:Reads 1 'claimed legacy call never reads again'
  Assert-Equal $script:Launches 0 'no duplicate UI'
}
Test-Case 'backoff remains active across campaign rollover' {
  At '2026-10-25 09:59:00'; $null = Start-QmCreditAttempt -Manual
  $script:FakeProcess.HasExited = $true; $null = Update-QmCreditProcess
  At '2026-10-25 10:00:00'
  $r = Start-QmCreditAttempt -Manual
  Assert-True (-not $r.Started) 'new budget cannot defeat recent-attempt timestamp'
  Assert-Equal $script:Launches 1 'no rollover burst'
}
Test-Case 'public raw reader also retains claimed snapshot until next campaign' {
  Claimed '2026-10-25'; $null = Get-QmCreditStatus
  $script:QM_CREDIT_STATE = Join-Path $root 'src\lib-credits.ps1' # invalid JSON, not user state
  At '2026-10-26 09:59:00'
  Assert-Equal (& $script:RawReader).result 'claimed' 'direct reader cannot invalidate claimed cache'
  At '2026-10-26 10:00:00'
  Assert-Equal (& $script:RawReader) $null 'malformed local state handled safely after rollover'
}
Test-Case 'public raw reader throttles unsuccessful snapshots too' {
  Claimed '2026-10-25' 'failed'; $null = Get-QmCreditStatus
  $script:QM_CREDIT_STATE = Join-Path $root 'src\lib-credits.ps1'
  At '2026-10-25 10:35:29'
  Assert-Equal (& $script:RawReader).result 'failed' 'raw read uses existing snapshot inside throttle'
  At '2026-10-25 10:35:30'
  Assert-Equal (& $script:RawReader) $null 'read resumes at throttle deadline'
}
Test-Case 'preflight matches only exact claimant file arguments' {
  $script:QM_CREDIT_SCRIPT = 'C:\isolated fixture\QoderDailyCredits.ps1'
  $script:Processes = @([pscustomobject]@{ ProcessId = 100; CommandLine = 'powershell.exe -NoProfile -File "C:\isolated fixture\QoderDailyCredits.ps1" -NoNotify' })
  Assert-True (& $script:BusyChecker) 'quoted exact file detected'
  $script:Processes[0].CommandLine = 'pwsh.exe -f "c:\isolated fixture\QoderDailyCredits.ps1"'
  Assert-True (& $script:BusyChecker) 'case-insensitive path and file alias detected'
  $script:Processes[0].CommandLine = 'powershell.exe -File "C:\other\QoderDailyCredits.ps1"'
  Assert-True (-not (& $script:BusyChecker)) 'same basename elsewhere is not our claimant'
  $script:Processes[0].CommandLine = 'powershell.exe -Command "Write-Output QoderDailyCredits.ps1"'
  Assert-True (-not (& $script:BusyChecker)) 'incidental text is not a file invocation'
}
Test-Case 'uninspectable external command line fails closed' {
  $script:Processes = @([pscustomobject]@{ ProcessId = 100; CommandLine = $null })
  $blocked = $false
  try { $null = & $script:BusyChecker } catch { $blocked = $true }
  Assert-True $blocked 'cannot safely launch when preflight is unavailable'
}
Test-Case 'real harmless process is pinned, timed out, and reaped by exact object' {
  $script:UseRealFactory = $true
  try {
    $r = Start-QmCreditAttempt -Manual
    Assert-True $r.Started 'real factory launches harmless command-only child'
    Assert-True $script:QM_CREDIT_PROC_CAN_KILL 'OS handle is pinned'
    Assert-True ([object]::ReferenceEquals($script:SmokeProcess, $script:QM_CREDIT_PROC)) 'exact factory object retained'
    At '2026-10-25 10:38:00'
    $code = Update-QmCreditProcess
    if ($code -eq 'running') {
      Assert-True ($script:SmokeProcess.WaitForExit(5000)) 'killed child exits promptly'
      $code = Update-QmCreditProcess
    }
    Assert-Equal $code 'timedout' 'real lifecycle reports timeout'
    Assert-Equal $script:QM_CREDIT_PROC $null 'owned process reference released after confirmed exit'
  } finally {
    if ($script:SmokeProcess) {
      try { if (-not $script:SmokeProcess.HasExited) { $script:SmokeProcess.Kill(); $null = $script:SmokeProcess.WaitForExit(5000) } } catch { }
      try { $script:SmokeProcess.Dispose() } catch { }
    }
  }
}
Write-Output ("RESULT: {0} passed; {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail) { exit 1 }
