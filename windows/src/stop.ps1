# Explicit user stop: suppress only the current Qoder lifecycle, then close recorded identities.
param([switch]$IncludeWatcher)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-lifecycle.ps1')
if (Stop-QmInstance -IncludeWatcher:$IncludeWatcher) {
  Write-Output '已停止 Qoder Meter；本次 Qoder 生命周期内不会自动重启。'
} else {
  Write-Output '没有可安全停止的已记录实例；未结束任何其他进程。'
}
