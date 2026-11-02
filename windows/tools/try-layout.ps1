<#
  切换形态并截图：tools/try-layout.ps1 -Layout title|top|bottom|sidebar
  只结束本工具自己启动的 meter.ps1 实例，不碰其它进程。
#>
param(
  [string]$Layout = 'sidebar',
  [string]$Out = '',
  [int]$WaitSec = 4
)
$root = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = Join-Path $root ("probe\shot-" + $Layout + ".png") }

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*meter.ps1*' -and $_.CommandLine -notlike '*try-layout*' } |
  ForEach-Object {
    Write-Output ("结束旧实例 PID " + $_.ProcessId)
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
Start-Sleep -Milliseconds 700

$argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
             '-File', (Join-Path $root 'src\meter.ps1'), '-AlwaysOn', '-Layout', $Layout)
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru
Write-Output ("启动 layout=" + $Layout + " PID=" + $p.Id)
Start-Sleep -Seconds $WaitSec
& (Join-Path $root 'probe\win-dump.ps1') -Shot -Out $Out
Write-Output ("截图输出: " + $Out)
