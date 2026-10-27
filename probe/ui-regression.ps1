param([switch]$Full)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fail=0;$pass=0
function Check($ok,$name) { if($ok){$script:pass++; Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"} }
# Missing merge/geometry behavior is deliberately a failing assertion before implementation.
$lib=Join-Path $root 'src\lib-config-layout.ps1'
if(!(Test-Path $lib)){ Check $false 'configuration and safe docking implementation missing'; exit 1 }
. $lib
$a=New-QmConfig; $b=New-QmConfig
$a.display.token=$false
Check ($b.display.token) 'defaults are independent objects'
$fixture='{"layout":"top","display":{"token":false,"tools":false},"positions":{"title":[77,12]},"panelHidden":true}' | ConvertFrom-Json
$c=Merge-QmConfig $fixture
Check (!$c.display.token -and !$c.display.tools -and $c.display.tps) 'nested display switches survive reload'
Check ($c.positions.title[0] -eq 77 -and $c.panelHidden) 'position and hidden state survive reload'
Check ($c.layout -eq 'toolbar') 'legacy top migrates to conversation toolbar'
$c=Merge-QmConfig ('{"layout":"invalid","fontSize":"huge","skin":"unknown","positions":{"title":["bad",4]}}'|ConvertFrom-Json)
Check ($c.layout -eq 'title' -and $c.fontSize -eq 'normal' -and $c.positions.title[0] -eq 0) 'invalid settings are normalized'
$q=[pscustomobject]@{L=100;T=100;R=1540;B=1180;W=1440;H=1080;Dpi=120;WorkL=0;WorkT=0;WorkR=1920;WorkB=1400;Fullscreen=$false}
foreach($layout in @('title','toolbar','bottom')){
 $r=Get-QmDockRegion $q $layout
 Check ($r.X -ge 100 -and $r.Right -le 1540 -and $r.Y -ge 100 -and $r.Bottom -le 1180) "$layout stays inside Qoder"
 $p=Get-QmDockPlacement $r 400 26 @(9999,9999)
 Check ($p.X -ge $r.X -and ($p.X+400) -le $r.Right -and $p.Y -eq [math]::Round($r.Y+($r.H-26)/2)) "$layout drag cannot cover adjacent controls"
}
$q.L=-1820;$q.R=-380;$q.WorkL=-1920;$q.WorkR=0
$r=Get-QmDockRegion $q 'title'
Check ($r.X -lt 0 -and $r.Right -lt 0) 'negative monitor origin retained'
$r=Get-QmDockRegion $q 'sidebar';$p=Get-QmDockPlacement $r 246 250 @(0,0)
Check ($p.BaseX -eq $r.X -and $p.BaseY -eq $r.Y) 'card drag baseline is its uncentered origin'
$dx=20;$dy=30;$saved=@((($p.X+$dx-$p.BaseX)/$r.K),(($p.Y+$dy-$p.BaseY)/$r.K))
$next=Get-QmDockPlacement $r 246 250 $saved
Check ($next.X -eq $p.X+$dx -and $next.Y -eq $p.Y+$dy) 'card drag offset roundtrips without snapping'
if($Full){
 . (Join-Path $root 'src\lib-interop.ps1'); . (Join-Path $root 'src\lib-ui.ps1')
 $script:QM_S=[pscustomobject]@{tpsHistory=@(20,40,80)}
 function Show-QmSettings {}
 $script:CFG=New-QmConfig
 foreach($layout in @('title','toolbar','bottom','sidebar')){
  $script:CFG.layout=$layout
  $view=if($layout -eq 'sidebar'){Build-QmCard $script:CFG 'paper' 1}else{Build-QmBar $script:CFG 'paper' 1}
  $view.Measure([System.Windows.Size]::new(700,500));$view.Arrange([System.Windows.Rect]::new(0,0,700,500))
  Check ($null -ne $script:UI_GEAR) "$layout exposes settings control"
  if($layout -eq 'sidebar'){Check ($view.Width -eq 246 -and $view.Height -ge 220) 'card fixed width complete metrics'}
  else {
   Set-QmBarWidth 420
   Check ($script:UI_BAR.Width -lt 420 -and $script:UI_BAR.Width -ge 280) "$layout trims a narrow bar to its content"
   Check ($script:UI_GROUPS['token'].Element.Visibility -eq 'Visible') "$layout keeps the token count when space is tight"
   Check ([double]::IsNaN([double]$script:UI_STATE_PILL.Width)) "$layout auto-sizes the status pill"
   Check ($script:UI_SEGS.token.FontSize -ge 12 -and $script:UI_STATUS.FontSize -ge 11) "$layout default metric and status text are readable at 96 DPI"
  }
 }
 $script:CFG.layout='title';$wide=Build-QmBar $script:CFG 'paper' 1;Set-QmBarWidth 900
 if(Get-Command Get-QmContentBarWidth -ErrorAction SilentlyContinue){
  $content=Get-QmContentBarWidth
  Check ($script:UI_BAR.Width -lt 900) 'bar width follows content instead of filling the region'
  Check ([math]::Abs($script:UI_BAR.Width-$content) -le 2) 'bar width equals measured content width'
  Check ($script:UI_GROUPS['token'].Element.Visibility -eq 'Visible' -and $script:UI_GROUPS['requests'].Element.Visibility -eq 'Visible') 'compact fit reveals more metrics in the same space'
 }else{Check $false 'content width measurement missing'}
 Set-QmBarWidth 500
 Check ($script:UI_BAR.Width -lt 500 -and $script:UI_BAR.Width -gt 300) 'reshrinking a wide bar returns to compact content width'
 $script:CFG=New-QmConfig;$script:CFG.layout='title';foreach($key in @($script:CFG.display.Keys)){$script:CFG.display[$key]=$false}
 $minimal=Build-QmBar $script:CFG 'paper' 1
 if(Get-Command Get-QmPreferredBarWidth -ErrorAction SilentlyContinue){Check ((Get-QmPreferredBarWidth) -lt 200) 'disabled fields shrink preferred width'}else{Check $false 'disabled fields shrink preferred width'}
 $settingsLib=Join-Path $root 'src\lib-settings.ps1'
 if(!(Test-Path $settingsLib)){Check $false 'settings window implementation missing'}else{
  . $settingsLib
  $script:QM_VERSION='test';$script:UI=@{settings=$null;skin='paper'};$script:CREDIT=@{Status=$null;Running=$false}
  function Get-QmAutoStart {return $false}
  function Get-QmUpdateStatus {return [pscustomobject]@{State='idle';Text='';Url=''}}
  $sw=New-QmSettingsWindow
  Check ($sw.Title -eq 'Qoder Meter 设置' -and $script:QM_SETTINGS_CONTROLS.ContainsKey('layout')) 'settings exposes dock selection'
  Check ($script:QM_SETTINGS_CONTROLS['layout'].Items.Count -eq 4) 'all four views selectable'
  Check ($script:QM_SETTINGS_CONTROLS.ContainsKey('creditAuto') -and $script:QM_SETTINGS_CONTROLS.ContainsKey('follow')) 'credits and session-follow controls available'
  $sw.Close()
 }
}
Write-Output "PASS=$pass FAIL=$fail"
if($fail){exit 1}
