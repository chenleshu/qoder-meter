<#
  Qoder Meter for Windows - 安装脚本
  把 src 下的模块复制到 %LOCALAPPDATA%\QoderMeter\app，并（可选）注册登录自启动。

  用法:
    powershell -File install.ps1                安装 + 自启动
    powershell -File install.ps1 -NoAutoStart   只安装，不注册自启动
    powershell -File install.ps1 -StartNow      安装后立即启动
#>
[CmdletBinding()]
param(
  [switch]$NoAutoStart,
  [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$appDir = Join-Path $env:LOCALAPPDATA 'QoderMeter\app'
$srcDir = Join-Path $appDir 'src'

Write-Output '安装 Qoder Meter for Windows'
Write-Output ("  源目录: " + $root)
Write-Output ("  目标:   " + $appDir)

New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
$copied = 0
foreach ($f in Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.ps1' -File) {
  Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $srcDir $f.Name) -Force
  $copied++
  Write-Output ("  + src\" + $f.Name)
}
if (Test-Path (Join-Path $root 'README.md')) {
  Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $appDir 'README.md') -Force
}
foreach ($name in @('启动 Qoder 状态条.cmd', '停止 Qoder 状态条.cmd', 'uninstall.ps1')) {
  Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $appDir $name) -Force
}

# 保持 app/src 布局；手动启动打开 Meter，登录自启动只打开隐藏 watcher。
. (Join-Path $srcDir 'lib-lifecycle.ps1')
$vbs = Join-Path $appDir 'launch-hidden.vbs'
Write-QmHiddenLauncher (Join-Path $srcDir 'meter.ps1') $vbs
Write-Output ('  + launch-hidden.vbs')

if (-not $NoAutoStart) {
  Set-QmAutoStart $true
  Write-Output ('  已启用随 Qoder 启动（隐藏 watcher）: ' + (Get-QmAutoStartCommand))
} else {
  # 不读取/写入 Run，不改已有 watcher 包装与设置，不启动任何进程。
  Write-Output '  保持现有自启动设置不变（-NoAutoStart）'
}

if ($StartNow) {
  Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
  Write-Output '  已启动。'
}

Write-Output ''
Write-Output ('完成。手动启动：双击 "启动 Qoder 状态条.cmd"，或运行 wscript "' + $vbs + '"')
