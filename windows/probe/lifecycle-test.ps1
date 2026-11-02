# Fixture-only tests: no registry, real Qoder, UI, network or installed files.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lib = Join-Path $root 'src\lib-lifecycle.ps1'
$script:passed = 0
$script:failed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
  catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Test-Case 'lifecycle library exists' { Assert (Test-Path -LiteralPath $lib) 'Missing lifecycle implementation' }
if (-not (Test-Path -LiteralPath $lib)) { exit 1 }
. $lib
$oldAppData = $env:APPDATA
$oldLocalData = $env:LOCALAPPDATA
$temp = Join-Path ([IO.Path]::GetTempPath()) ('qm-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$script:QM_LC_STATE_DIR = Join-Path $temp 'state'
$script:QM_LC_SCRIPT_DIR = Join-Path $temp 'app with spaces\src'
[void][IO.Directory]::CreateDirectory($script:QM_LC_SCRIPT_DIR)
$script:meterPath = Join-Path $script:QM_LC_SCRIPT_DIR 'meter.ps1'
$script:watchPath = Join-Path $script:QM_LC_SCRIPT_DIR 'watch.ps1'
[IO.File]::WriteAllText($script:meterPath, '# fixture')
[IO.File]::WriteAllText($script:watchPath, '# fixture')
$script:psExe = Join-Path $PSHOME 'powershell.exe'
$script:qoderExe = 'C:\Fixture Apps\Qoder\Qoder.exe'
$script:fixtureProcesses = @{}
$script:fixtureQoder = @()
$script:launches = @()
$script:closed = @()
$script:runValue = $null
$script:runWrites = 0
$script:requests = 0
$script:realCloseProcess = ${function:Close-QmRecordedProcess}
function New-ProcessFixture([int]$Id, [string]$ScriptPath, [string]$Time = '2026-10-25T01:00:00.0000000Z') {
  [pscustomobject]@{ ProcessId = $Id; CreationDate = [datetime]::Parse($Time).ToUniversalTime(); ExecutablePath = $script:psExe;
    CommandLine = ('"' + $script:psExe + '" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'); SessionId = 1; ParentProcessId = 2 }
}
function New-QoderFixture([int]$Id, [string]$Time = '2026-10-25T01:00:00.0000000Z') {
  [pscustomobject]@{ ProcessId = $Id; CreationDate = [datetime]::Parse($Time).ToUniversalTime(); ExecutablePath = $script:qoderExe;
    CommandLine = ('"' + $script:qoderExe + '"'); SessionId = 1; ParentProcessId = 2 }
}
# Replace OS boundaries only. State serialization, locking, decisions and polling remain real.
function Get-QmProcessInfo([int]$ProcessId) { return $script:fixtureProcesses[$ProcessId] }
function Get-QmQoderProcesses { return $script:fixtureQoder }
function Get-QmRunValue { return $script:runValue }
function Set-QmRunValue([AllowNull()][string]$Value) { $script:runWrites++; $script:runValue = $Value }
function Start-QmHiddenScript([string]$ScriptPath) {
  $script:launches += $ScriptPath
  $id = 7100 + $script:launches.Count
  $script:fixtureProcesses[$id] = New-ProcessFixture $id $ScriptPath
  return $script:fixtureProcesses[$id]
}
function Close-QmRecordedProcess($Record) {
  # Models the already-validated OS handle operation; production validates again on its handle.
  $script:closed += $Record.Pid
  return $true
}
function New-QmUpdateRequest {
  $script:requests++
  $script:completion = [Threading.Tasks.TaskCompletionSource[string]]::new()
  return [pscustomobject]@{ Task = $script:completion.Task; Client = $null }
}
function Reset-Fixtures {
  if (Test-Path -LiteralPath $script:QM_LC_STATE_DIR) { Remove-Item -LiteralPath $script:QM_LC_STATE_DIR -Recurse -Force }
  $script:fixtureProcesses = @{}
  $script:fixtureQoder = @()
  $script:launches = @()
  $script:closed = @()
  $script:runValue = $null
  $script:QM_LC_OWN_INSTANCE = $null
}
function Release-Fixture([string]$Name, [string]$Tag = 'v1.5.0') {
  [pscustomobject]@{ tag_name = $Tag; draft = $false; prerelease = $false;
    html_url = ('https://github.com/chenleshu/qoder-meter/releases/tag/' + $Tag);
    assets = @([pscustomobject]@{ name = $Name; browser_download_url = ('https://github.com/chenleshu/qoder-meter/releases/download/' + $Tag + '/' + $Name) }) }
}
try {
  Test-Case 'watch and stop entry points exist' {
    Assert (Test-Path -LiteralPath (Join-Path $root 'src\watch.ps1')) 'Watcher entry point missing'
    Assert (Test-Path -LiteralPath (Join-Path $root 'src\stop.ps1')) 'Safe stop entry point missing'
  }
  Test-Case 'NoAutoStart installer preserves existing startup and settings in a temp install' {
    $env:LOCALAPPDATA = Join-Path $temp 'local'
    $env:APPDATA = Join-Path $temp 'roaming'
    $state = Join-Path $env:APPDATA 'QoderMeter'
    [void][IO.Directory]::CreateDirectory($state)
    [IO.File]::WriteAllText((Join-Path $state 'settings.json'), '{"layout":"bottom","creditAuto":false}')
    [IO.File]::WriteAllText((Join-Path $state 'watch-hidden.vbs'), 'existing startup sentinel')
    # Any attempted registry write is a test failure, never a real mutation.
    function Set-ItemProperty { throw 'Installer attempted registry modification under -NoAutoStart' }
    function Remove-ItemProperty { throw 'Installer attempted registry removal under -NoAutoStart' }
    function Start-Process { throw 'Installer attempted to start runtime under -NoAutoStart' }
    & (Join-Path $root 'install.ps1') -NoAutoStart | Out-Null
    Assert ([IO.File]::ReadAllText((Join-Path $state 'settings.json')) -eq '{"layout":"bottom","creditAuto":false}') 'Settings changed'
    Assert ([IO.File]::ReadAllText((Join-Path $state 'watch-hidden.vbs')) -eq 'existing startup sentinel') 'Startup target changed'
    $app = Join-Path $env:LOCALAPPDATA 'QoderMeter\app'
    Assert (Test-Path -LiteralPath (Join-Path $app '停止 Qoder 状态条.cmd')) 'Installed safe stop launcher missing'
    Assert (Test-Path -LiteralPath (Join-Path $app 'src\watch.ps1')) 'Watcher not installed under app/src'
    $env:LOCALAPPDATA = $oldLocalData
    $env:APPDATA = $oldAppData
  }
  Test-Case 'loading and polling do not start network or enable startup' {
    $s = Get-QmUpdateStatus
    Assert ($s.State -eq 'idle' -and $script:requests -eq 0 -and $script:runWrites -eq 0) 'Unexpected side effects'
  }
  Test-Case 'exact file identity accepts spaces, rejects reused PID, command payload and other script' {
    Reset-Fixtures
    $p = New-ProcessFixture 7101 $script:meterPath
    $r = New-QmInstanceRecord $p $script:meterPath
    Assert (Test-QmInstanceIdentity $r $p $script:meterPath) 'Valid exact identity rejected'
    Assert (-not (Test-QmInstanceIdentity $r (New-ProcessFixture 7101 $script:meterPath '2026-10-25T02:00:00Z') $script:meterPath)) 'Reused PID accepted'
    Assert (-not (Test-QmInstanceIdentity $r (New-ProcessFixture 7101 ($script:meterPath + '.other')) $script:meterPath)) 'Other script accepted'
    $p.CommandLine = ('powershell.exe -Command "Write-Output ''-File ' + $script:meterPath + '''"')
    Assert (-not (Test-QmInstanceIdentity $r $p $script:meterPath)) 'Command text confused with -File'
    $p = New-ProcessFixture 7101 $script:meterPath
    $p.ExecutablePath = 'C:\unrelated\powershell.exe'
    Assert (-not (Test-QmInstanceIdentity $r $p $script:meterPath)) 'Different executable accepted'
    $p = New-ProcessFixture 7101 $script:meterPath
    $p.CommandLine = 'cmd.exe -File "' + $script:meterPath + '"'
    Assert (-not (Test-QmInstanceIdentity $r $p $script:meterPath)) 'Mismatched executable argument accepted'
  }
  Test-Case 'watcher mutex excludes a second runspace and releases cleanly' {
    $mutex = New-QmWatchMutex
    Assert ($null -ne $mutex) 'First watcher could not acquire mutex'
    $worker = [PowerShell]::Create()
    try {
      [void]$worker.AddScript('param($lib,$state); . $lib; $script:QM_LC_STATE_DIR=$state; $m=New-QmWatchMutex; if($m){$m.ReleaseMutex();$m.Dispose();"acquired"}else{"busy"}').AddArgument($lib).AddArgument($script:QM_LC_STATE_DIR)
      $result = $worker.Invoke()
      Assert ($result.Count -eq 1 -and $result[0] -eq 'busy') 'Concurrent watcher acquired mutex'
      $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null
      $result = $worker.Invoke()
      Assert ($result.Count -eq 1 -and $result[0] -eq 'acquired') 'Watcher mutex leaked'
    } finally {
      if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
      $worker.Dispose()
    }
  }
  Test-Case 'safe close pins and verifies a disposable actual process handle' {
    Reset-Fixtures
    $suffix = [guid]::NewGuid().ToString('N')
    $releaseName = 'Local\QmTestRelease_' + $suffix
    $readyName = 'Local\QmTestReady_' + $suffix
    $release = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $releaseName)
    $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $readyName)
    $child = $null
    try {
      $body = '$r=[Threading.EventWaitHandle]::OpenExisting(''' + $releaseName + ''');$ready=[Threading.EventWaitHandle]::OpenExisting(''' + $readyName + ''');[void]$ready.Set();[void]$r.WaitOne(15000);$ready.Dispose();$r.Dispose()'
      [IO.File]::WriteAllText($script:meterPath, $body, [Text.UTF8Encoding]::new($true))
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.FileName = $script:psExe
      $info.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:meterPath + '"'
      $info.UseShellExecute = $false; $info.CreateNoWindow = $true
      $child = [Diagnostics.Process]::Start($info)
      Assert ($ready.WaitOne(5000)) 'Disposable process did not become ready'
      $actual = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $child.Id)
      $script:fixtureProcesses[$child.Id] = $actual
      $r = New-QmInstanceRecord $actual $script:meterPath
      $wrong = New-QmInstanceRecord $actual $script:meterPath
      $wrong.StartTime = '2020-01-01T00:00:00.0000000Z'
      Assert (-not (& $script:realCloseProcess $wrong)) 'Mismatched handle identity closed'
      Assert (-not $child.HasExited) 'Disposable process exited before valid close'
      Assert (& $script:realCloseProcess $r) 'Exact disposable process could not be closed'
      Assert ($child.WaitForExit(1000)) 'Disposable process remains alive'
    } finally {
      [void]$release.Set()
      if ($child) { [void]$child.WaitForExit(5000); $child.Dispose() }
      $ready.Dispose(); $release.Dispose()
    }
  }
  Test-Case 'Qoder detection requires exact executable, session and main-process arguments' {
    $main = New-QoderFixture 81
    $child = New-QoderFixture 82
    $child.CommandLine += ' --type=renderer'
    $other = New-QoderFixture 83
    $other.ExecutablePath = 'C:\unrelated\Qoder.exe'
    $other.CommandLine = '"C:\unrelated\Qoder.exe"'
    $foreign = New-QoderFixture 84
    $foreign.SessionId = 2
    $found = @(Select-QmQoderProcesses @($main, $child, $other, $foreign) @($script:qoderExe) 1)
    Assert ($found.Count -eq 1 -and $found[0].ProcessId -eq 81) 'False Qoder lifecycle detected'
  }
  Test-Case 'register serializes own identity; unregister cannot delete a replacement' {
    Reset-Fixtures
    $script:fixtureProcesses[$PID] = New-ProcessFixture $PID $script:meterPath
    Register-QmInstance $script:meterPath
    $r = Read-QmLifecycleState 'instance.json'
    Assert ($r.Pid -eq $PID -and $r.ScriptPath -eq $script:meterPath -and $r.StartTime) 'Incomplete instance record'
    $other = New-QmInstanceRecord (New-ProcessFixture 7300 $script:meterPath) $script:meterPath
    Write-QmLifecycleState 'instance.json' $other
    Unregister-QmInstance
    Assert ((Read-QmLifecycleState 'instance.json').Pid -eq 7300) 'Removed another instance'
    Register-QmInstance $script:meterPath
    Unregister-QmInstance
    Assert ($null -eq (Read-QmLifecycleState 'instance.json')) 'Own record was not removed'
  }
  Test-Case 'manual exit suppresses all current Qoder lifecycles but not a reused PID' {
    Reset-Fixtures
    $script:fixtureQoder = @((New-QoderFixture 81), (New-QoderFixture 82))
    Set-QmManualExit
    Assert (Test-QmManualExit $script:fixtureQoder[0]) 'Current lifecycle not suppressed'
    Assert (Test-QmManualExit $script:fixtureQoder[1]) 'Second lifecycle not suppressed'
    Assert (-not (Test-QmManualExit (New-QoderFixture 81 '2026-10-25T02:00:00Z'))) 'Restart still suppressed'
    Assert (-not (Test-QmManualExit (New-QoderFixture 83))) 'New process suppressed'
  }
  Test-Case 'watcher launches only when enabled, Qoder running and not suppressed; tracks pending PID' {
    Reset-Fixtures
    Invoke-QmWatchTick
    Assert ($script:launches.Count -eq 0) 'Disabled watcher launched'
    Set-QmAutoStart $true
    $script:launches = @()
    Invoke-QmWatchTick
    Assert ($script:launches.Count -eq 0) 'Launched without Qoder'
    $script:fixtureQoder = @((New-QoderFixture 81))
    Set-QmManualExit
    Invoke-QmWatchTick
    Assert ($script:launches.Count -eq 0) 'Manual exit ignored'
    $script:fixtureQoder = @((New-QoderFixture 81 '2026-10-25T02:00:00Z'))
    Invoke-QmWatchTick
    Invoke-QmWatchTick
    Assert ($script:launches.Count -eq 1 -and $script:launches[0] -eq $script:meterPath) 'Duplicate or wrong launch'
    $script:fixtureQoder = @()
    Invoke-QmWatchTick
    Assert ($script:closed.Count -eq 0) 'Watcher tried to close processes'
  }
  Test-Case 'watcher respects a recorded running copy across install locations' {
    Reset-Fixtures
    Set-QmAutoStart $true
    $script:launches = @()
    $script:fixtureQoder = @((New-QoderFixture 81))
    $otherPath = Join-Path $temp 'other installation\src\meter.ps1'
    $script:fixtureProcesses[7350] = New-ProcessFixture 7350 $otherPath
    Write-QmLifecycleState 'instance.json' (New-QmInstanceRecord $script:fixtureProcesses[7350] $otherPath)
    Invoke-QmWatchTick
    Assert ($script:launches.Count -eq 0) 'Spawned duplicate while another recorded copy owns main mutex'
    $otherWatch = Join-Path $temp 'other installation\src\watch.ps1'
    $script:fixtureProcesses[7351] = New-ProcessFixture 7351 $otherWatch
    Write-QmLifecycleState 'watch-instance.json' (New-QmInstanceRecord $script:fixtureProcesses[7351] $otherWatch)
    Start-QmWatch
    Assert ($script:launches.Count -eq 0) 'Spawned duplicate watcher and replaced its live record'
  }
  Test-Case 'autostart targets hidden watcher and disable does not erase settings' {
    Reset-Fixtures
    Write-QmLifecycleState 'settings.json' ([pscustomobject]@{ layout = 'bottom'; creditAuto = $false })
    Assert (-not (Get-QmAutoStart)) 'Startup enabled by default'
    Start-QmWatch
    Assert ($script:launches.Count -eq 0) 'Start-QmWatch ignored disabled option'
    Set-QmAutoStart $true
    Assert (Get-QmAutoStart) 'Enable did not roundtrip'
    Assert ($script:runValue -match 'wscript.exe.+watch-hidden.vbs' -and $script:runValue -notmatch 'meter.ps1') 'Run launches meter directly'
    $launcher = [IO.File]::ReadAllText((Get-QmWatchLauncherPath), [Text.Encoding]::Default)
    Assert ($launcher.Contains($script:watchPath) -and $launcher.Contains('shell.Run cmd, 0, False')) 'Launcher not hidden or wrong target'
    Set-QmAutoStart $false
    Assert (-not (Get-QmAutoStart)) 'Disable did not roundtrip'
    Assert ((Read-QmLifecycleState 'settings.json').layout -eq 'bottom') 'Settings overwritten'
  }
  Test-Case 'explicit stop refuses unknown/reused processes and closes only recorded identity' {
    Reset-Fixtures
    $p = New-ProcessFixture 7101 $script:meterPath
    $r = New-QmInstanceRecord $p $script:meterPath
    Write-QmLifecycleState 'instance.json' $r
    $script:fixtureProcesses[7101] = New-ProcessFixture 7101 $script:meterPath '2026-10-25T02:00:00Z'
    [void](Stop-QmInstance)
    Assert ($script:closed.Count -eq 0) 'Stopped a reused PID'
    $script:fixtureProcesses[7101] = $p
    Write-QmLifecycleState 'instance.json' $r
    [void](Stop-QmInstance)
    Assert ($script:closed.Count -eq 1 -and $script:closed[0] -eq 7101) 'Recorded process not closed'
    Write-QmLifecycleState 'instance.json' (New-QmInstanceRecord (New-ProcessFixture 7102 $script:watchPath) $script:watchPath)
    $script:fixtureProcesses[7102] = New-ProcessFixture 7102 $script:watchPath
    [void](Stop-QmInstance)
    Assert ($script:closed.Count -eq 1) 'Record for wrong script authorized stop'
  }
  Test-Case 'release filtering never offers the observed mac-only release as Windows' {
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-1.4.1.zip' 'v1.4.1') '1.4.0-win.1' 'x64'
    Assert ($s.State -eq 'no-windows' -and $s.Text -eq '尚无 Windows 发布包' -and -not $s.Url) 'Mac asset offered'
    foreach ($name in @('QoderMeter-windows-x64.zip','QoderMeter-win-x64.exe','QoderMeter-windows.msi')) {
      $s = Resolve-QmUpdateRelease (Release-Fixture $name) '1.4.0-win.1' 'x64'
      Assert ($s.State -eq 'available' -and $s.Url -eq 'https://github.com/chenleshu/qoder-meter/releases/tag/v1.5.0') ('Windows asset rejected: ' + $name)
    }
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-win-arm64.zip') '1.4.0-win.1' 'x64'
    Assert ($s.State -eq 'no-windows') 'Wrong architecture offered'
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-win-arm64.zip') '1.4.0-win.1' 'arm64'
    Assert ($s.State -eq 'available') 'ARM64 asset rejected'
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-win-x64.zip' 'v1.4.0-win.1') '1.4.0-win.1' 'x64'
    Assert ($s.State -eq 'current') 'Same version offered'
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-win-x64.zip' 'v1.4.0-win.2') '1.4.0-win.1' 'x64'
    Assert ($s.State -eq 'available') 'Windows revision ignored'
    $s = Resolve-QmUpdateRelease (Release-Fixture 'QoderMeter-win-x64.zip' 'v1.3.9') '1.4.0-win.1' 'x64'
    Assert ($s.State -eq 'current') 'Downgrade offered'
  }
  Test-Case 'async manual update stays nonblocking, deduplicates and handles success/error' {
    $script:QM_VERSION = '1.4.0-win.1'
    $before = $script:requests
    [void](Start-QmUpdateCheck)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    1..20 | ForEach-Object { $s = Get-QmUpdateStatus }
    $timer.Stop()
    Assert ($s.State -eq 'checking' -and $timer.ElapsedMilliseconds -lt 1000) 'Polling blocked'
    [void](Start-QmUpdateCheck)
    Assert ($script:requests -eq ($before + 1)) 'Concurrent request started'
    $script:completion.SetResult(((Release-Fixture 'QoderMeter-1.4.1.zip' 'v1.4.1') | ConvertTo-Json -Depth 5))
    $s = Get-QmUpdateStatus
    Assert ($s.State -eq 'no-windows') 'Completed response not consumed'
    [void](Start-QmUpdateCheck)
    $script:completion.SetException([Exception]::new('fixture timeout'))
    $s = Get-QmUpdateStatus
    Assert ($s.State -eq 'error' -and -not $s.Url) 'Fault not surfaced safely'
    [void](Start-QmUpdateCheck)
    $script:completion.SetResult('not json')
    Assert ((Get-QmUpdateStatus).State -eq 'error') 'Malformed JSON accepted'
  }
} finally {
  $env:APPDATA = $oldAppData
  $env:LOCALAPPDATA = $oldLocalData
  Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output ('RESULT passed=' + $script:passed + ' failed=' + $script:failed)
if ($script:failed) { exit 1 }
