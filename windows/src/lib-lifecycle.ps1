# Windows PowerShell 5.1. Dot-sourcing performs no I/O, registration or network request.
$script:QM_LC_SCRIPT_DIR = $PSScriptRoot
$script:QM_LC_STATE_DIR = Join-Path $env:APPDATA 'QoderMeter'
$script:QM_LC_OWN_INSTANCE = $null
$script:QM_LC_UPDATE_REQUEST = $null
$script:QM_LC_UPDATE_STATUS = [pscustomobject]@{ State = 'idle'; Text = '检查更新'; Url = '' }

function Get-QmLifecycleMutexName([string]$Kind) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:QM_LC_STATE_DIR.ToLowerInvariant()))).Replace('-', '') }
  finally { $sha.Dispose() }
  return ('Local\QoderMeterWin_' + $Kind + '_' + $hash.Substring(0, 24))
}

function Invoke-QmLifecycleLock([scriptblock]$Action) {
  $mutex = [Threading.Mutex]::new($false, (Get-QmLifecycleMutexName 'State'))
  $held = $false
  try {
    try { $held = $mutex.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Qoder Meter lifecycle state is busy.' }
    & $Action
  } finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function New-QmWatchMutex {
  $mutex = [Threading.Mutex]::new($false, (Get-QmLifecycleMutexName 'Watch'))
  $held = $false
  try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
  if ($held) { return $mutex }
  $mutex.Dispose()
  return $null
}

function Read-QmLifecycleState([string]$Name) {
  try { return ([IO.File]::ReadAllText((Join-Path $script:QM_LC_STATE_DIR $Name), [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
  catch { return $null }
}

# Callers hold the state mutex. Replace prevents readers observing partial JSON.
function Write-QmLifecycleState([string]$Name, $Value) {
  [void][IO.Directory]::CreateDirectory($script:QM_LC_STATE_DIR)
  $path = Join-Path $script:QM_LC_STATE_DIR $Name
  $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
    # PS5.1 coerces $null to an empty string for this .NET string parameter.
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $path) }
  } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Get-QmProcessInfo([int]$ProcessId) {
  if ($ProcessId -le 0) { return $null }
  return (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction SilentlyContinue)
}

function Get-QmProcessStamp($Time) {
  if ($null -eq $Time) { return '' }
  try {
    $utc = ([datetime]$Time).ToUniversalTime()
    # CIM CreationDate has microsecond precision; use that same precision for a live handle.
    return ([datetime]::new(($utc.Ticks - ($utc.Ticks % 10)), [DateTimeKind]::Utc).ToString('o'))
  } catch { return '' }
}

function Test-QmExactPath([string]$Left, [string]$Right) {
  if (-not $Left -or -not $Right -or -not [IO.Path]::IsPathRooted($Left) -or -not [IO.Path]::IsPathRooted($Right)) { return $false }
  try { return [string]::Equals([IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right), [StringComparison]::OrdinalIgnoreCase) }
  catch { return $false }
}

function Get-QmPowerShellPath { return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }

function Get-QmFileArgument([string]$CommandLine) {
  # Deliberately conservative: only real -File invocations, never a substring inside -Command.
  # These are the options used by this app's launchers; extra script arguments follow -File.
  $pattern = '^\s*(?:"(?<exe>[^"\r\n]+)"|(?<exe>[^\s"]+))(?:\s+-(?:NoProfile|NonInteractive|NoLogo|STA|MTA)|\s+-ExecutionPolicy\s+(?:Bypass|RemoteSigned|Unrestricted|AllSigned|Restricted)|\s+-WindowStyle\s+(?:Hidden|Normal|Minimized|Maximized))*\s+-File\s+(?:"(?<file>[^"\r\n]+)"|(?<file>[^\s"]+))(?:\s+.*)?$'
  $match = [regex]::Match($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success) {
    $exe = $match.Groups['exe'].Value
    if ($exe -ieq 'powershell.exe' -or (Test-QmExactPath $exe (Get-QmPowerShellPath))) { return $match.Groups['file'].Value }
  }
  return ''
}

function New-QmInstanceRecord($Process, [string]$ScriptPath) {
  if (-not $Process -or -not [IO.Path]::IsPathRooted($ScriptPath)) { throw 'Missing process identity or absolute script path.' }
  $record = [pscustomobject]@{ Pid = [int]$Process.ProcessId; StartTime = (Get-QmProcessStamp $Process.CreationDate);
    ScriptPath = [IO.Path]::GetFullPath($ScriptPath); ExecutablePath = [string]$Process.ExecutablePath }
  if (-not (Test-QmInstanceIdentity $record $Process $ScriptPath)) { throw 'Process is not the exact Qoder Meter script invocation.' }
  return $record
}

function Test-QmInstanceIdentity($Record, $Process, [string]$ScriptPath) {
  if (-not $Record -or -not $Process -or [int]$Record.Pid -le 0) { return $false }
  if ([int]$Record.Pid -ne [int]$Process.ProcessId -or -not $Record.StartTime -or
      [string]$Record.StartTime -cne (Get-QmProcessStamp $Process.CreationDate)) { return $false }
  if (-not (Test-QmExactPath $Record.ScriptPath $ScriptPath)) { return $false }
  if (-not (Test-QmExactPath $Record.ExecutablePath $Process.ExecutablePath)) { return $false }
  if (-not (Test-QmExactPath $Process.ExecutablePath (Get-QmPowerShellPath))) { return $false }
  return (Test-QmExactPath (Get-QmFileArgument $Process.CommandLine) $ScriptPath)
}

function Get-QmQoderExecutablePaths {
  # Exact installed executable paths, not process-name or command-line substring matches.
  foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) {
      Join-Path $base 'Qoder\Qoder.exe'
      if ($base -eq $env:LOCALAPPDATA) { Join-Path $base 'Programs\Qoder\Qoder.exe' }
    }
  }
  # Desktop updater runs the executable inside .qoder-versions/<version>/, not its bootstrap launcher.
  foreach ($installRoot in @((Join-Path $env:LOCALAPPDATA 'Programs\Qoder'), (Join-Path $env:ProgramFiles 'Qoder'))) {
    $versions = Join-Path $installRoot '.qoder-versions'
    if (Test-Path -LiteralPath $versions) {
      foreach ($directory in @(Get-ChildItem -LiteralPath $versions -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $directory.FullName 'Qoder.exe'
        if ([IO.File]::Exists($exe)) { $exe }
      }
    }
  }
  # Also support portable/custom installs exposed on PATH.
  $command = Get-Command Qoder.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { $command.Source }
}

function Select-QmQoderProcesses($Processes, [string[]]$ExecutablePaths, [int]$SessionId) {
  foreach ($p in $Processes) {
    if (-not $p -or [int]$p.SessionId -ne $SessionId -or -not $p.CreationDate -or -not $p.CommandLine) { continue }
    $exact = $false
    foreach ($path in $ExecutablePaths) { if (Test-QmExactPath $p.ExecutablePath $path) { $exact = $true; break } }
    if (-not $exact) { continue }
    $m = [regex]::Match([string]$p.CommandLine, '^\s*(?:"(?<exe>[^"\r\n]+)"|(?<exe>[^\s"]+))(?<args>.*)$')
    if (-not $m.Success -or -not (Test-QmExactPath $m.Groups['exe'].Value $p.ExecutablePath)) { continue }
    if ($m.Groups['args'].Value -match '(?i)(?:^|\s)"?--(?:type(?:=|\s)|(?:ms-enable-electron-run-as-node|run-as-node)(?:\s|"|$))') { continue }
    # Electron CLI/helper descendants are not independent Qoder lifecycles.
    $parent = @($Processes | Where-Object { $_.ProcessId -eq $p.ParentProcessId -and
      (Test-QmExactPath $_.ExecutablePath $p.ExecutablePath) -and $_.CreationDate -le $p.CreationDate })
    if ($parent.Count) { continue }
    $p
  }
}

function Get-QmQoderProcesses {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='Qoder.exe'" -ErrorAction SilentlyContinue)
  return (Select-QmQoderProcesses $all @(Get-QmQoderExecutablePaths) ([Diagnostics.Process]::GetCurrentProcess().SessionId))
}

function Set-QmManualExit {
  Invoke-QmLifecycleLock {
    $identities = @(Get-QmQoderProcesses | ForEach-Object {
      [pscustomobject]@{ Pid = [int]$_.ProcessId; StartTime = (Get-QmProcessStamp $_.CreationDate); ExecutablePath = [string]$_.ExecutablePath }
    })
    Write-QmLifecycleState 'manual-exit.json' ([pscustomobject]@{ Qoder = $identities })
  }
}

function Test-QmManualExit($QoderProcess) {
  if (-not $QoderProcess) { return $false }
  $state = Read-QmLifecycleState 'manual-exit.json'
  if (-not $state) { return $false }
  foreach ($q in $state.Qoder) {
    if ([int]$q.Pid -eq [int]$QoderProcess.ProcessId -and $q.StartTime -and
        [string]$q.StartTime -ceq (Get-QmProcessStamp $QoderProcess.CreationDate) -and
        (Test-QmExactPath $q.ExecutablePath $QoderProcess.ExecutablePath)) { return $true }
  }
  return $false
}

function Register-QmInstance([string]$ScriptPath) {
  $record = New-QmInstanceRecord (Get-QmProcessInfo $PID) $ScriptPath
  Invoke-QmLifecycleLock {
    Write-QmLifecycleState 'instance.json' $record
    $script:QM_LC_OWN_INSTANCE = $record
  }
}

function Test-QmSameRecord($Left, $Right) {
  return [bool]($Left -and $Right -and $Left.Pid -eq $Right.Pid -and $Left.StartTime -ceq $Right.StartTime -and
    (Test-QmExactPath $Left.ScriptPath $Right.ScriptPath) -and (Test-QmExactPath $Left.ExecutablePath $Right.ExecutablePath))
}

function Unregister-QmInstance {
  Stop-QmUpdateCheck
  Invoke-QmLifecycleLock {
    if (Test-QmSameRecord (Read-QmLifecycleState 'instance.json') $script:QM_LC_OWN_INSTANCE) {
      [IO.File]::Delete((Join-Path $script:QM_LC_STATE_DIR 'instance.json'))
    }
    $script:QM_LC_OWN_INSTANCE = $null
  }
}

function Get-QmRunValue {
  $key = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
  if ($key) { return $key.GetValue('QoderMeter', $null, 'DoNotExpandEnvironmentNames') }
  return $null
}

function Set-QmRunValue([AllowNull()][string]$Value) {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  if ($Value) {
    if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
    Set-ItemProperty -LiteralPath $key -Name 'QoderMeter' -Value $Value -Type String -ErrorAction Stop
  } elseif (Test-Path -LiteralPath $key) {
    Remove-ItemProperty -LiteralPath $key -Name 'QoderMeter' -ErrorAction SilentlyContinue
  }
}

function Get-QmWatchLauncherPath { return (Join-Path $script:QM_LC_STATE_DIR 'watch-hidden.vbs') }
function Get-QmAutoStartCommand { return ('"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + (Get-QmWatchLauncherPath) + '"') }
function Get-QmAutoStart { return [bool]([string](Get-QmRunValue) -eq (Get-QmAutoStartCommand)) }

function Write-QmHiddenLauncher([string]$ScriptPath, [string]$LauncherPath) {
  $command = '"' + (Get-QmPowerShellPath) + '" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + [IO.Path]::GetFullPath($ScriptPath) + '"'
  $body = 'Set shell = CreateObject("WScript.Shell")' + "`r`n" + 'cmd = "' + $command.Replace('"', '""') + '"' + "`r`n" + 'shell.Run cmd, 0, False' + "`r`n"
  [void][IO.Directory]::CreateDirectory((Split-Path $LauncherPath -Parent))
  # WSH supports UTF-16 BOM; unlike ANSI this preserves non-ACP user/install paths.
  [IO.File]::WriteAllText($LauncherPath, $body, [Text.Encoding]::Unicode)
}

# Only call from an explicit option change (or the installer without -NoAutoStart).
function Set-QmAutoStart([bool]$Enabled) {
  if ($Enabled) {
    $watch = Join-Path $script:QM_LC_SCRIPT_DIR 'watch.ps1'
    if (-not [IO.File]::Exists($watch)) { throw 'Qoder Meter watcher is missing.' }
    Invoke-QmLifecycleLock {
      Write-QmHiddenLauncher $watch (Get-QmWatchLauncherPath)
      Set-QmRunValue (Get-QmAutoStartCommand)
    }
    Start-QmWatch
  } else {
    Set-QmRunValue $null
    # The watcher notices on its next 3-second tick; never kill by process name.
  }
}

function Start-QmHiddenScript([string]$ScriptPath) {
  if (-not [IO.File]::Exists($ScriptPath)) { throw ('Missing script: ' + $ScriptPath) }
  $p = Start-Process -FilePath (Get-QmPowerShellPath) -ArgumentList ('-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"') -WindowStyle Hidden -PassThru -ErrorAction Stop
  try { return (Get-QmProcessInfo $p.Id) } finally { $p.Dispose() }
}

function Start-QmWatch {
  if (-not (Get-QmAutoStart)) { return }
  Invoke-QmLifecycleLock {
    if (-not (Get-QmAutoStart)) { return }
    $path = Join-Path $script:QM_LC_SCRIPT_DIR 'watch.ps1'
    $record = Read-QmLifecycleState 'watch-instance.json'
    if ($record -and [IO.Path]::GetFileName($record.ScriptPath) -eq 'watch.ps1' -and
        (Test-QmInstanceIdentity $record (Get-QmProcessInfo $record.Pid) $record.ScriptPath)) { return }
    $p = Start-QmHiddenScript $path
    if ($p) { Write-QmLifecycleState 'watch-instance.json' (New-QmInstanceRecord $p $path) }
  }
}

function Invoke-QmWatchTick {
  if (-not (Get-QmAutoStart)) { return }
  Invoke-QmLifecycleLock {
    if (-not (Get-QmAutoStart)) { return }
    $qoder = @(Get-QmQoderProcesses | Where-Object { -not (Test-QmManualExit $_) })
    if (-not $qoder.Count) { return }
    $path = Join-Path $script:QM_LC_SCRIPT_DIR 'meter.ps1'
    foreach ($name in @('instance.json', 'pending-instance.json')) {
      $record = Read-QmLifecycleState $name
      # Source and installed copies share the main singleton: respect either exact live record.
      if ($record -and [IO.Path]::GetFileName($record.ScriptPath) -eq 'meter.ps1' -and
          (Test-QmInstanceIdentity $record (Get-QmProcessInfo $record.Pid) $record.ScriptPath)) { return }
    }
    $p = Start-QmHiddenScript $path
    # Track the exact process while meter loads and acquires its own singleton mutex.
    if ($p) { Write-QmLifecycleState 'pending-instance.json' (New-QmInstanceRecord $p $path) }
  }
}

function Close-QmRecordedProcess($Record) {
  # Called only for explicit Stop/Uninstall. Pin a handle before verifying to avoid PID reuse.
  $p = $null
  try {
    if ([int]$Record.Pid -eq $PID) { return $false }
    $p = [Diagnostics.Process]::GetProcessById([int]$Record.Pid)
    $null = $p.Handle
    if ((Get-QmProcessStamp $p.StartTime) -cne [string]$Record.StartTime) { return $false }
    if (-not (Test-QmInstanceIdentity $Record (Get-QmProcessInfo $Record.Pid) $Record.ScriptPath)) { return $false }
    if ($p.CloseMainWindow() -and $p.WaitForExit(1500)) { return $true }
    if (-not $p.HasExited) { $p.Kill() }
    return $p.WaitForExit(1500)
  } catch { return $false }
  finally { if ($p) { $p.Dispose() } }
}

function Stop-QmInstance([switch]$IncludeWatcher) {
  Set-QmManualExit
  $names = @('instance.json', 'pending-instance.json')
  if ($IncludeWatcher) { $names += 'watch-instance.json' }
  $stopped = $false
  foreach ($name in $names) {
    $record = Invoke-QmLifecycleLock {
      $r = Read-QmLifecycleState $name
      if (-not $r) { return }
      $file = if ($name -eq 'watch-instance.json') { 'watch.ps1' } else { 'meter.ps1' }
      $allowed = @((Join-Path $script:QM_LC_SCRIPT_DIR $file), (Join-Path $env:LOCALAPPDATA ('QoderMeter\app\src\' + $file)))
      foreach ($path in $allowed) {
        if (Test-QmInstanceIdentity $r (Get-QmProcessInfo $r.Pid) $path) { return $r }
      }
    }
    if (-not $record) { continue }
    # Release state lock before asking the app to close: its finally unregisters under that lock.
    if (Close-QmRecordedProcess $record) {
      $stopped = $true
      Invoke-QmLifecycleLock {
        if (Test-QmSameRecord (Read-QmLifecycleState $name) $record) { [IO.File]::Delete((Join-Path $script:QM_LC_STATE_DIR $name)) }
      }
    }
  }
  return $stopped
}

function Get-QmWindowsVersion {
  $v = Get-Variable QM_VERSION -Scope Script -ErrorAction SilentlyContinue
  if ($v -and $v.Value) { return [string]$v.Value }
  return '1.4.0-win.2'
}

function Get-QmWindowsArchitecture {
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
  return 'x64'
}

function ConvertTo-QmReleaseVersion([string]$Version) {
  $m = [regex]::Match($Version, '^v?(\d+)\.(\d+)\.(\d+)(?:-win\.(\d+))?$')
  if (-not $m.Success) { return $null }
  try {
    $revision = 0
    if ($m.Groups[4].Success) { $revision = [int]$m.Groups[4].Value }
    return [version]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, $revision)
  } catch { return $null }
}

function Resolve-QmUpdateRelease($Release, [string]$CurrentVersion, [string]$Architecture) {
  $windows = @($Release.assets | Where-Object {
    $name = [string]$_.name
    $name -match '(?i)\.(zip|exe|msi)$' -and
    $name -match '(?i)(?:^|[-_.])(?:windows|win-(?:x64|arm64))(?:[-_.]|$)' -and
    $name -notmatch '(?i)(?:^|[-_.])(?:mac|macos|darwin|osx)(?:[-_.]|$)' -and
    [string]$_.browser_download_url -match '^https://github\.com/chenleshu/qoder-meter/releases/download/' -and
    -not ($Architecture -eq 'x64' -and $name -match '(?i)(?:^|[-_.])arm64(?:[-_.]|$)') -and
    -not ($Architecture -eq 'arm64' -and $name -match '(?i)(?:^|[-_.])x64(?:[-_.]|$)')
  })
  if (-not $windows.Count) { return [pscustomobject]@{ State = 'no-windows'; Text = '尚无 Windows 发布包'; Url = '' } }
  $latest = ConvertTo-QmReleaseVersion ([string]$Release.tag_name)
  $current = ConvertTo-QmReleaseVersion $CurrentVersion
  if (-not $latest -or -not $current) { throw '无法识别 Windows 发布版本' }
  if ($Release.draft -or $Release.prerelease -or $latest -le $current) {
    return [pscustomobject]@{ State = 'current'; Text = ('当前已是最新 Windows 版本（' + $CurrentVersion + '）'); Url = '' }
  }
  $url = [string]$Release.html_url
  if ($url -notmatch '^https://github\.com/chenleshu/qoder-meter/releases/tag/[^\s?#]+$') { throw '无效的发布页面地址' }
  return [pscustomobject]@{ State = 'available'; Text = ('发现 Windows 新版本 ' + $Release.tag_name); Url = $url }
}

function New-QmUpdateRequest {
  Add-Type -AssemblyName System.Net.Http
  $client = [Net.Http.HttpClient]::new()
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $client.MaxResponseContentBufferSize = 1048576
    $client.DefaultRequestHeaders.UserAgent.ParseAdd(('QoderMeter-Windows/' + (Get-QmWindowsVersion)))
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    # No scriptblock callbacks on a foreign thread/runspace. Task<string> includes body buffering.
    $task = $client.GetStringAsync('https://api.github.com/repos/chenleshu/qoder-meter/releases/latest')
    return [pscustomobject]@{ Client = $client; Task = $task }
  } catch { $client.Dispose(); throw }
}

function Stop-QmUpdateCheck {
  $request = $script:QM_LC_UPDATE_REQUEST
  if ($request -and $request.Client) { $request.Client.CancelPendingRequests(); $request.Client.Dispose() }
  $script:QM_LC_UPDATE_REQUEST = $null
  if ($script:QM_LC_UPDATE_STATUS.State -eq 'checking') {
    $script:QM_LC_UPDATE_STATUS = [pscustomobject]@{ State = 'idle'; Text = '检查更新'; Url = '' }
  }
}

# Manual action only. Returns immediately; UI polls Get-QmUpdateStatus on its timer.
function Start-QmUpdateCheck {
  if ($script:QM_LC_UPDATE_REQUEST) { return (Get-QmUpdateStatus) }
  $script:QM_LC_UPDATE_STATUS = [pscustomobject]@{ State = 'checking'; Text = '正在检查更新…'; Url = '' }
  try { $script:QM_LC_UPDATE_REQUEST = New-QmUpdateRequest }
  catch { $script:QM_LC_UPDATE_STATUS = [pscustomobject]@{ State = 'error'; Text = ('检查更新失败：' + $_.Exception.Message); Url = '' } }
  return $script:QM_LC_UPDATE_STATUS
}

function Get-QmUpdateStatus {
  $request = $script:QM_LC_UPDATE_REQUEST
  if ($request -and $request.Task.IsCompleted) {
    try {
      $json = $request.Task.GetAwaiter().GetResult()
      $release = $json | ConvertFrom-Json -ErrorAction Stop
      if (-not $release -or -not $release.PSObject.Properties['assets'] -or -not $release.tag_name) { throw '无效的发布信息' }
      $script:QM_LC_UPDATE_STATUS = Resolve-QmUpdateRelease $release (Get-QmWindowsVersion) (Get-QmWindowsArchitecture)
    } catch { $script:QM_LC_UPDATE_STATUS = [pscustomobject]@{ State = 'error'; Text = ('检查更新失败：' + $_.Exception.Message); Url = '' } }
    finally {
      if ($request.Client) { $request.Client.Dispose() }
      $script:QM_LC_UPDATE_REQUEST = $null
    }
  }
  return $script:QM_LC_UPDATE_STATUS
}
