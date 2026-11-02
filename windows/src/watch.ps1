# Started hidden by the Run launcher or Start-QmWatch. Never starts network requests.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-lifecycle.ps1')
if (-not (Get-QmAutoStart)) { exit 0 }
$watchMutex = New-QmWatchMutex
if (-not $watchMutex) { exit 0 }
$ownRecord = $null
try {
  $ownRecord = New-QmInstanceRecord (Get-QmProcessInfo $PID) $PSCommandPath
  Invoke-QmLifecycleLock { Write-QmLifecycleState 'watch-instance.json' $ownRecord }
  while (Get-QmAutoStart) {
    try { Invoke-QmWatchTick } catch {
      # Fail closed for this tick (e.g. CIM unavailable/state mutex busy); retry without killing anything.
    }
    Start-Sleep -Seconds 3
  }
} finally {
  try {
    Invoke-QmLifecycleLock {
      if (Test-QmSameRecord (Read-QmLifecycleState 'watch-instance.json') $ownRecord) {
        [IO.File]::Delete((Join-Path $script:QM_LC_STATE_DIR 'watch-instance.json'))
      }
    }
  } finally {
    $watchMutex.ReleaseMutex()
    $watchMutex.Dispose()
  }
}
