# 语法自检：解析 src 和 probe/tools 下所有 .ps1，报告错误
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'probe'), (Join-Path $root 'tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue)
$files += @(Get-ChildItem -Path $root -Filter *.ps1 -File -ErrorAction SilentlyContinue)
$fail = 0
foreach ($f in $files) {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    $fail++
    Write-Output ("[FAIL] " + $f.Name)
    $errs | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 3 | ForEach-Object {
      Write-Output ("       line " + $_.Extent.StartScriptPosition.LineNumber + " col " + $_.Extent.StartScriptPosition.ColumnNumber + " :: " + $_.Message)
    }
  } else {
    Write-Output ("[OK]   " + $f.Name)
  }
}
Write-Output ("共 " + $files.Count + " 个文件，失败 " + $fail + " 个")
if ($fail -gt 0) { exit 1 }
