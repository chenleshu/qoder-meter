<#
  Qoder Meter for Windows - 卸载
  结束进程、删除自启动项与安装目录。默认保留 %APPDATA%\QoderMeter（设置与日志）。

  用法:
    powershell -File uninstall.ps1              卸载（保留设置）
    powershell -File uninstall.ps1 -Purge       连设置目录一起删
#>
param([switch]$Purge)

$ErrorActionPreference = 'Continue'
$appDir = Join-Path $env:LOCALAPPDATA 'QoderMeter'
$settingsDir = Join-Path $env:APPDATA 'QoderMeter'

Write-Output '卸载 Qoder Meter for Windows'

$library = Join-Path $PSScriptRoot 'src\lib-lifecycle.ps1'
if (-not (Test-Path -LiteralPath $library)) { throw '缺少生命周期模块；为避免误结束进程，取消卸载。' }
. $library
# 显式卸载才禁用自启动；只关闭 PID/创建时间/精确脚本路径均匹配的记录。
Set-QmAutoStart $false
[void](Stop-QmInstance -IncludeWatcher)
Write-Output '  已移除登录自启动项；未记录或身份不符的进程不会被结束。'

if (Test-Path $appDir) {
  Remove-Item -LiteralPath $appDir -Recurse -Force
  Write-Output ('  已删除安装目录: ' + $appDir)
}

if ($Purge -and (Test-Path $settingsDir)) {
  Remove-Item -LiteralPath $settingsDir -Recurse -Force
  Write-Output ('  已删除设置目录: ' + $settingsDir)
} elseif (Test-Path $settingsDir) {
  Write-Output ('  保留设置目录: ' + $settingsDir + '（加 -Purge 可删除）')
}

Write-Output '完成。'
