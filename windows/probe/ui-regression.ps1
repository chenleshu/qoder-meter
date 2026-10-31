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
   Check ($script:UI_BAR.Width -le 420 -and $script:UI_BAR.Width -ge 280) "$layout fits reserved field slots in a narrow region"
   Check ($script:UI_GROUPS['token'].Element.Visibility -eq 'Visible' -and -not $script:UI_GROUPS.ContainsKey('balance') -and $script:UI_BAR_PILLS.credit.Visibility -eq 'Visible') "$layout keeps token and the single balance pill when space is tight"
   Check (![double]::IsNaN([double]$script:UI_STATE_PILL.Width) -and $script:UI_STATE_PILL.Width -gt 0) "$layout reserves a fixed status pill capacity"
   Check ($script:UI_SEGS.token.FontSize -ge 12 -and $script:UI_STATUS.FontSize -ge 11) "$layout default metric and status text are readable at 96 DPI"
  }
 }
 $script:CFG.layout='title';$wide=Build-QmBar $script:CFG 'paper' 1;Set-QmBarWidth 900
 if(Get-Command Get-QmContentBarWidth -ErrorAction SilentlyContinue){
  $content=Get-QmContentBarWidth
  Check ($script:UI_BAR.Width -le 900) 'reserved slots do not exceed the available region'
  Check ([math]::Abs($script:UI_BAR.Width-$content) -le 2) 'bar width equals the visible reserved slots'
  Check ($script:UI_GROUPS['token'].Element.Visibility -eq 'Visible' -and $script:UI_GROUPS['turn'].Element.Visibility -eq 'Visible' -and $script:UI_BAR_PILLS.status.Visibility -eq 'Visible') 'wider space restores metrics and status without changing capacities'
 }else{Check $false 'content width measurement missing'}
 Set-QmBarWidth 500
 Check ($script:UI_BAR.Width -le 500 -and $script:UI_BAR.Width -gt 300) 'reshrinking a wide bar refits the same reserved slots'
 $script:CFG=New-QmConfig;$script:CFG.layout='title';foreach($key in @($script:CFG.display.Keys)){$script:CFG.display[$key]=$false}
 $minimal=Build-QmBar $script:CFG 'paper' 1
 if(Get-Command Get-QmPreferredBarWidth -ErrorAction SilentlyContinue){Check ((Get-QmPreferredBarWidth) -lt 200) 'disabled fields shrink preferred width'}else{Check $false 'disabled fields shrink preferred width'}
 Check ($script:UI_GROUPS.Count -eq 0 -and $script:UI_BAR_RIGHT.Children.Count -eq 1) 'all fields disabled leave no orphan separators'
 $script:CFG.display.token=$true;$single=Build-QmBar $script:CFG 'paper' 1
 Check ($script:UI_GROUPS.Count -eq 1 -and $script:UI_GROUPS.token.Element.Children[0].Tag -eq 'QmBarSeparator' -and $script:UI_BAR_RIGHT.Children.Count -eq 1) 'single metric owns one divider after the persistent status dot'
 foreach($skin in $script:QM_SKINS.Keys){
  foreach($scale in $script:QM_FONT_SIZES.Values){
   $script:CFG=New-QmConfig;$bar=Build-QmBar $script:CFG $skin $scale
   $fields=@($script:UI_GROUPS.Values|ForEach-Object{$_.Element})+@($script:UI_BAR_RIGHT.Children|Where-Object{$_.Tag -eq 'QmBarField'})
   $valid=$true
   foreach($field in $fields){
    $lines=@($field.Children|Where-Object{$_.Tag -eq 'QmBarSeparator'})
    if($lines.Count -ne 1){$valid=$false;continue}
    $line=$lines[0]
    if($field.Children[0] -ne $line -or $line.Width -ne 1 -or [math]::Abs($line.Height-12*$scale) -gt .001 -or $line.Opacity -ne .35 -or $line.IsHitTestVisible -or $line.Background.Color -ne (Get-QmBrush $script:QM_SKINS[$skin].gray).Color){$valid=$false}
   }
   Check $valid "$skin scale=$scale fields own subtle theme-aware noninteractive dividers"
   Check ($script:UI_BAR_RIGHT.Children[$script:UI_BAR_RIGHT.Children.Count-1] -eq $script:UI_GEAR) "$skin scale=$scale ends with settings rather than a divider"
   $script:UI_TPS.Text='133';$script:UI_SEGS.token.Text='207.9k';$script:UI_CREDIT.Text='5,730 / +4,096'
   $fits=$true;$narrowCount=0
   foreach($available in @(420,900,420)){
    Set-QmBarWidth $available
    $content=Get-QmContentBarWidth
    if($content -gt $available+1 -or [math]::Abs($script:UI_BAR.Width-$content) -gt 2){$fits=$false}
    $visibleCount=@($script:UI_GROUPS.Values|Where-Object{$_.Element.Visibility -eq 'Visible'}).Count
    if($available -eq 420){if($narrowCount -and $narrowCount -ne $visibleCount){$fits=$false};$narrowCount=$visibleCount}
   }
   Check $fits "$skin scale=$scale measures dividers and remains stable across narrow-wide-narrow layout"
  }
 }
 # Live values must not alter width, chosen fields, separators or endpoint positions.
 # Measure/arrange the actual hidden controls, not just the capacity arithmetic.
 function Get-BarGeometry([double]$available){
  # Production windows pass layout rounding down to all controls.
  $script:UI_BAR.UseLayoutRounding=$true;$script:UI_BAR.SnapsToDevicePixels=$true
  Set-QmBarWidth $available
  $bar=$script:UI_BAR;$bar.Measure([Windows.Size]::new($bar.Width,$bar.Height))
  $bar.Arrange([Windows.Rect]::new(0,0,$bar.Width,$bar.Height));$bar.UpdateLayout()
  $parts=@($bar.Width,$bar.ActualWidth,(Get-QmPreferredBarWidth));$fits=$bar.Width -le $available -and $bar.ActualWidth -le $available+.01
  $reason=if($fits){''}else{"outer=$($bar.Width)/$($bar.ActualWidth) available=$available"}
  $elements=@($script:UI_HALO,$script:UI_BAR_TPS,$script:UI_GEAR)+@($script:UI_GROUPS.GetEnumerator()|Sort-Object Key|ForEach-Object{$_.Value.Element})+@($script:UI_BAR_PILLS.GetEnumerator()|Sort-Object Key|ForEach-Object{$_.Value})
  $ranges=@()
  foreach($el in $elements){
   if(!$el){continue};$parts+=[string]$el.Visibility
   if($el.Visibility -ne 'Visible'){continue}
   $point=$el.TransformToAncestor($bar).Transform([Windows.Point]::new(0,0))
   $parts+=('{0:F3},{1:F3}' -f $point.X,$el.ActualWidth)
   if($point.X -lt -.01 -or $point.X+$el.ActualWidth -gt $bar.Width+.01){$fits=$false;$reason+=" element=$($point.X)+$($el.ActualWidth)>$($bar.Width)"}
   $ranges+=,[pscustomobject]@{Left=$point.X;Right=$point.X+$el.ActualWidth}
  }
  $edge=0.0
  foreach($range in @($ranges|Sort-Object Left)){if($range.Left -lt $edge-.01){$fits=$false;$reason+=" overlap=$($range.Left)<$edge"};$edge=$range.Right}
  $content=Get-QmContentBarWidth
  if($content -gt $bar.Width+1){$fits=$false;$reason+=" content=$content width=$($bar.Width)"}
  return [pscustomobject]@{Signature=($parts -join '|');Fits=$fits;Reason=$reason}
 }
 $states=@(
  @{Number='—';Status='空闲';Credit='未登录';Title='短标题'},
  @{Number='207.9k';Status='生成中 12s';Credit='余 5,730 · 今 +4,096';Title='状态条宽度示例'},
  @{Number='999999999999999.99';Status='生成中 999h 59m';Credit='余 999,999,999 · 今 +999,999,999';Title=('超长会话标题 A&B ' * 40)},
  @{Number='—';Status='空闲';Credit='未登录';Title='短标题'}
 )
 foreach($skin in $script:QM_SKINS.Keys){
  foreach($scale in $script:QM_FONT_SIZES.Values){
   foreach($layout in @('title','toolbar','bottom')){
    $script:CFG=New-QmConfig;$script:CFG.layout=$layout;$bar=Build-QmBar $script:CFG $skin $scale
    $stable=$true;$fits=$true;$restored=$true;$first=$null
    foreach($available in @(80,180,285,420,689,900,1800,420)){
     $baseline=$null
     foreach($state in $states){
      $script:UI_TPS.Text=$state.Number
      foreach($text in $script:UI_SEGS.Values){$text.Text=$state.Number}
      if($script:UI_TITLE){$script:UI_TITLE.Text=$state.Title}
      $script:UI_STATUS.Text=$state.Status;$script:UI_CREDIT.Text=$state.Credit
      $geometry=Get-BarGeometry $available
      if(!$geometry.Fits){$fits=$false}
      if($null -eq $baseline){$baseline=$geometry.Signature}elseif($baseline -cne $geometry.Signature){$stable=$false}
     }
     if($available -eq 420){if($null -eq $first){$first=$baseline}elseif($first -cne $baseline){$restored=$false}}
    }
    Check $stable "$layout $skin scale=$scale keeps width and columns stable through short-long-short content"
    Check $fits "$layout $skin scale=$scale keeps fields and settings in bounds without overlap"
    Check $restored "$layout $skin scale=$scale restores identical geometry after host resize"
   }
  }
 }
 # Simulate inherited per-monitor layout DPI on the same visual tree. This does
 # not replace a real multi-monitor placement test, but exercises WPF rounding.
 foreach($scale in $script:QM_FONT_SIZES.Values){
  foreach($layout in @('title','toolbar','bottom')){
   $script:CFG=New-QmConfig;$script:CFG.layout=$layout;$bar=Build-QmBar $script:CFG 'paper' $scale
   foreach($dpi in @(1,1.25,1.5,2,1)){
    [Windows.Media.VisualTreeHelper]::SetRootDpi($bar,[Windows.DpiScale]::new($dpi,$dpi))
    $valid=[math]::Abs([Windows.Media.VisualTreeHelper]::GetDpi($bar).DpiScaleX-$dpi) -lt .001;$issue=''
    foreach($region in @(40,56,80,285,420,689,900,1800)){
     $available=[math]::Floor($region*$dpi)/$dpi;$baseline=$null
     foreach($state in $states){
      $script:UI_TPS.Text=$state.Number;foreach($text in $script:UI_SEGS.Values){$text.Text=$state.Number}
      if($script:UI_TITLE){$script:UI_TITLE.Text=$state.Title}
      $script:UI_STATUS.Text=$state.Status;$script:UI_CREDIT.Text=$state.Credit
      $geometry=Get-BarGeometry $available
      if(!$geometry.Fits){$valid=$false;if(!$issue){$issue=" at $available : $($geometry.Reason)"}}
      if($null -eq $baseline){$baseline=$geometry.Signature}elseif($baseline -cne $geometry.Signature){$valid=$false;if(!$issue){$issue=" at $available : geometry changed [$baseline] -> [$($geometry.Signature)]"}}
     }
    }
    Check $valid "$layout scale=$scale dpi=$dpi preserves rounded bounds and content-independent widths$issue"
   }
  }
 }
 # Sparse configurations do not inherit widths from the previous view.
 $script:CFG=New-QmConfig;foreach($key in @($script:CFG.display.Keys)){$script:CFG.display[$key]=$false}
 $bar=Build-QmBar $script:CFG 'paper' 1;$minimalWidth=Get-QmPreferredBarWidth
 $script:CFG.display.token=$true;$bar=Build-QmBar $script:CFG 'paper' 1;$tokenWidth=Get-QmPreferredBarWidth
 $script:UI_SEGS.token.Text='99999999999999999999999999999';Set-QmBarWidth 1800
 Check ($tokenWidth -gt $minimalWidth -and $script:UI_BAR.Width -eq $tokenWidth) 'field switches change capacity but a growing value never expands it'
 $bar=Build-QmBar $script:CFG 'paper' 1.24
 Check ((Get-QmPreferredBarWidth) -gt $tokenWidth) 'font changes intentionally recalculate reserved capacity'
 Set-QmBarWidth 0
 Check ($script:UI_BAR.Width -eq 0) 'zero available width never forces the bar over host controls'
 $script:CFG=New-QmConfig;$script:CFG.layout='sidebar';$card=Build-QmCard $script:CFG 'paper' 1
 Set-QmBarWidth 900
 Check ($card.Width -eq 246 -and (Get-QmPreferredBarWidth) -eq 0) 'card retains fixed width and clears stale bar capacity'
 $settingsLib=Join-Path $root 'src\lib-settings.ps1'
 if(!(Test-Path $settingsLib)){Check $false 'settings window implementation missing'}else{
  . $settingsLib
  $script:QM_VERSION='test';$script:UI=@{settings=$null;skin='paper'};$script:ACCOUNT=@{Running=$false;Auth=$null;Usage=$null;Campaigns=$null;Error='';UsageAt=0L;CampAt=0L;NextTry=0L;LastFail=@{};Notified=$null;At=''}
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
