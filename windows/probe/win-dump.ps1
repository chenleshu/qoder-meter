<#
  诊断：列出所有顶层窗口，标出 Qoder 主窗口与 Qoder Meter 浮窗，并可截图。
  用法: powershell -File probe/win-dump.ps1 [-Shot]
#>
param([switch]$Shot, [string]$Out = '')

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\lib-interop.ps1')
Add-Type -AssemblyName System.Drawing, System.Windows.Forms -ErrorAction SilentlyContinue

$script:Rows = New-Object System.Collections.Generic.List[object]
$cb = [QoderMeter.Native+EnumWindowsProc] {
  param($h, $l)
  try {
    $p = [uint32]0
    [void][QoderMeter.Native]::GetWindowThreadProcessId($h, [ref]$p)
    $procName = (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue).ProcessName
    if ($procName -like '*powershell*' -or $procName -eq 'Qoder') {
      $t = [QoderMeter.Native]::GetTitle($h)
      $c = [QoderMeter.Native]::GetClass($h)
      $vis = [QoderMeter.Native]::IsWindowVisible($h)
      $r = [QoderMeter.Native]::DwmFrame($h)
      [void]$script:Rows.Add([pscustomobject]@{
        Pid = [int]$p; Proc = $procName; Hwnd = [Int64]$h; Vis = $vis; Class = $c; Title = $t
        L = $r.Left; T = $r.Top; R = $r.Right; B = $r.Bottom
      })
    }
  } catch { }
  return $true
}
[void][QoderMeter.Native]::EnumWindows($cb, [IntPtr]::Zero)

Write-Output ("命中窗口: " + $script:Rows.Count)
foreach ($w in $script:Rows) {
  Write-Output ("pid={0,-7} {1,-12} hwnd={2,-9} vis={3,-5} class={4,-22} rect=({5},{6})-({7},{8}) {9}x{10} title='{11}'" -f `
    $w.Pid, $w.Proc, $w.Hwnd, $w.Vis, $w.Class, $w.L, $w.T, $w.R, $w.B, ($w.R - $w.L), ($w.B - $w.T), $w.Title)
}

$q = $script:Rows | Where-Object { $_.Title -eq 'Qoder' -and $_.Class -eq 'Chrome_WidgetWin_1' } | Select-Object -First 1
$m = $script:Rows | Where-Object { $_.Title -eq 'Qoder Meter' } | Select-Object -First 1
Write-Output ""
if ($q) { Write-Output ("Qoder 主窗口: " + ($q.R - $q.L) + "x" + ($q.B - $q.T) + " @(" + $q.L + "," + $q.T + ")") }
if ($m) { Write-Output ("Meter 浮窗  : " + ($m.R - $m.L) + "x" + ($m.B - $m.T) + " @(" + $m.L + "," + $m.T + ") visible=" + $m.Vis) }
else { Write-Output 'Meter 浮窗  : 未创建' }

$log = Join-Path $env:APPDATA 'QoderMeter\meter.log'
if (Test-Path $log) {
  Write-Output ""
  Write-Output "--- meter.log 末尾 ---"
  Get-Content $log -Tail 8 | ForEach-Object { Write-Output $_ }
}

if ($Shot -and $q) {
  $pad = 40
  $x = [Math]::Max(0, $q.L - $pad); $y = [Math]::Max(0, $q.T - $pad)
  $w2 = ($q.R - $q.L) + 2 * $pad; $h2 = ($q.B - $q.T) + 2 * $pad
  $bmp = New-Object System.Drawing.Bitmap($w2, $h2)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w2, $h2)))
  $g.Dispose()
  if (-not $Out) { $Out = Join-Path $PSScriptRoot 'screenshot.png' }
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("截图: " + $Out)
}
