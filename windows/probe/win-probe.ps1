# 窗口跟踪可行性探针 v2
Add-Type -Namespace NM -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT pv, int cb);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

# 让本进程的坐标与真实像素一致（PER_MONITOR_AWARE_V2 = -4）
[void][NM.W]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$script:found = New-Object System.Collections.ArrayList
$cb = [NM.W+EnumWindowsProc] {
  param([IntPtr]$h, [IntPtr]$l)
  try {
    if ([NM.W]::IsWindowVisible($h)) {
      $p = [uint32]0
      [void][NM.W]::GetWindowThreadProcessId($h, [ref]$p)
      $sb = New-Object System.Text.StringBuilder 512
      [void][NM.W]::GetWindowText($h, $sb, 512)
      $cs = New-Object System.Text.StringBuilder 512
      [void][NM.W]::GetClassName($h, $cs, 512)
      $t = $sb.ToString()
      $c = $cs.ToString()
      if ($t -match 'Qoder' -or $c -eq 'Chrome_WidgetWin_1') {
        $r = New-Object 'NM.W+RECT'
        [void][NM.W]::GetWindowRect($h, [ref]$r)
        $dr = New-Object 'NM.W+RECT'
        $dhr = [NM.W]::DwmGetWindowAttribute($h, 9, [ref]$dr, 16)
        $pname = try { (Get-Process -Id $p -ErrorAction Stop).ProcessName } catch { '?' }
        $path = try { (Get-Process -Id $p -ErrorAction Stop).Path } catch { '?' }
        [void]$script:found.Add([pscustomobject]@{
          Hwnd = [int64]$h; Pid = $p; Proc = $pname; Class = $c; Title = $t
          GW = ($r.Right - $r.Left); GH = ($r.Bottom - $r.Top); GL = $r.Left; GT = $r.Top
          DW = ($dr.Right - $dr.Left); DH = ($dr.Bottom - $dr.Top); DL = $dr.Left; DT = $dr.Top; Dhr = $dhr
          Dpi = [int][NM.W]::GetDpiForWindow($h)
          Exe = (Split-Path $path -Leaf)
        })
      }
    }
  } catch {}
  return $true
}
[void][NM.W]::EnumWindows($cb, [IntPtr]::Zero)

Write-Output "=== 命中窗口数: $($script:found.Count) ==="
foreach ($w in $script:found) {
  Write-Output ("hwnd={0,-8} pid={1,-7} proc={2,-10} exe={3,-12} class={4,-20} dpi={5} | GetWindowRect {6}x{7}@({8},{9}) | DWM {10}x{11}@({12},{13}) hr={14} | title={15}" -f `
    $w.Hwnd, $w.Pid, $w.Proc, $w.Exe, $w.Class, $w.Dpi, $w.GW, $w.GH, $w.GL, $w.GT, $w.DW, $w.DH, $w.DL, $w.DT, $w.Dhr, $w.Title)
}

Write-Output ""
Write-Output "=== 前台窗口 ==="
$fg = [NM.W]::GetForegroundWindow()
$fpid = [uint32]0
[void][NM.W]::GetWindowThreadProcessId($fg, [ref]$fpid)
$fp = try { (Get-Process -Id $fpid -ErrorAction Stop).ProcessName } catch { '?' }
$fsb = New-Object System.Text.StringBuilder 512
[void][NM.W]::GetWindowText($fg, $fsb, 512)
Write-Output ("fg hwnd={0} pid={1} proc={2} title={3}" -f [int64]$fg, $fpid, $fp, $fsb.ToString())

Write-Output ""
Write-Output "=== Qoder 进程 ==="
Get-Process -Name Qoder -ErrorAction SilentlyContinue |
  Group-Object -Property ProcessName | ForEach-Object { Write-Output ("{0}: {1} 个进程" -f $_.Name, $_.Count) }

Write-Output ""
Write-Output "=== 屏幕 ==="
Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  Write-Output ("{0} bounds={1} work={2} primary={3}" -f $s.DeviceName, $s.Bounds, $s.WorkingArea, $s.Primary)
}
