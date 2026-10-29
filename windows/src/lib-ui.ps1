# WPF views. Geometry is physical pixels; controls use DIP. Values update in place.
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$script:QM_SKINS=[ordered]@{
 paper=@{bg='#FAFFFFFF';border='#DEE3EB';text='#141A21';soft='#475261';gray='#6E7887';faint='#7B8797';green='#089466';greenDim='#298C70';gold='#A86912';red='#D62929';blue='#2461E6';track='#EBEEF2';divider='#EBEEF2';greenTint='#1A089466';goldTint='#1CA86912';grayTint='#126E7887';blueTint='#1A2461E6';highlight='#B3FFFFFF'}
 graphite=@{bg='#F816181D';border='#1AFFFFFF';text='#F5F5F5';soft='#C7C7C7';gray='#999999';faint='#969BA5';green='#57E099';greenDim='#61B88F';gold='#F2C76B';red='#F57066';blue='#85B3FF';track='#21FFFFFF';divider='#13FFFFFF';greenTint='#2457E099';goldTint='#26F2C76B';grayTint='#14FFFFFF';blueTint='#2485B3FF';highlight='#0FFFFFFF'}
 ocean=@{bg='#FAF4F9FE';border='#CCDBEB';text='#0F1C2E';soft='#3D526B';gray='#667A91';faint='#728498';green='#05809E';greenDim='#1A758F';gold='#A36B14';red='#D1333D';blue='#1A5CD1';track='#E0EBF7';divider='#E0EBF7';greenTint='#1C05809E';goldTint='#1CA36B14';grayTint='#134D6B8C';blueTint='#1A1A5CD1';highlight='#CCFFFFFF'}
 dusk=@{bg='#F8131622';border='#1AFFFFFF';text='#F2F2F2';soft='#C2C2C2';gray='#949494';faint='#9297AA';green='#4DC7EB';greenDim='#52A8D1';gold='#F2C27A';red='#F57370';blue='#94A3FF';track='#1FFFFFFF';divider='#13FFFFFF';greenTint='#244DC7EB';goldTint='#26F2C27A';grayTint='#14FFFFFF';blueTint='#2494A3FF';highlight='#0FFFFFFF'}
 sand=@{bg='#FAFEF9F0';border='#E3D9C7';text='#241C14';soft='#574A3B';gray='#786B59';faint='#877A67';green='#478C4D';greenDim='#618752';gold='#A8610A';red='#D1332E';blue='#3861A8';track='#EDE6D6';divider='#EDE6D6';greenTint='#1C478C4D';goldTint='#1CA8610A';grayTint='#13786B59';blueTint='#1A3861A8';highlight='#8CFFFFFF'}
}
$script:QM_SKIN_IDS=@('auto','paper','graphite','ocean','dusk','sand')
$script:QM_SKIN_NAMES=@('自动（Qoder 优先）','纸白','石墨','海盐','暮色','暖砂')
$script:QM_FONT_SIZES=[ordered]@{small=.9;normal=1.0;large=1.12;xlarge=1.24}
$script:QM_FONT_NAMES=[ordered]@{small='小';normal='标准';large='大';xlarge='特大'}
$script:QM_LAYOUT_NAMES=[ordered]@{title='标题栏中部';toolbar='会话工具栏中部';bottom='输入框下方';sidebar='完整统计卡片'}
$script:QM_FIELD_NAMES=[ordered]@{tps='TPS';turn='本轮';age='总计';token='Token';balance='余额';credits='消耗';requests='请求';tools='工具';latency='延迟';status='状态';title='标题';credit='账户积分'}
$script:QM_BRUSH_CACHE=@{}
function Get-QmBrush([string]$hex){
 if(!$hex){throw 'Empty color'}
 if(!$script:QM_BRUSH_CACHE.ContainsKey($hex)){$b=[Windows.Media.BrushConverter]::new().ConvertFromString($hex);$b.Freeze();$script:QM_BRUSH_CACHE[$hex]=$b}
 return $script:QM_BRUSH_CACHE[$hex]
}
function Get-QmSystemDark {try{return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0)}catch{return $false}}
function Resolve-QmSkin([string]$name){
 if($name -eq 'auto'){
  $appearance=$null
  if(Get-Command Get-QmAppAppearance -ErrorAction SilentlyContinue){$appearance=Get-QmAppAppearance}
  if($appearance -eq 'dark'){return 'graphite'};if($appearance -eq 'light'){return 'paper'}
  if(Get-QmSystemDark){return 'graphite'};return 'paper'
 }
 if($script:QM_SKINS.Contains($name)){return $name};return 'paper'
}
function New-QmText([string]$text,[double]$size,[string]$colorHex,[string]$weight='Normal',[bool]$mono=$false){
 $t=[Windows.Controls.TextBlock]::new();$t.Text=$text;$t.FontSize=$size;$t.Foreground=Get-QmBrush $colorHex
 $t.FontFamily=[Windows.Media.FontFamily]::new($(if($mono){'Cascadia Mono, Consolas, Microsoft YaHei UI'}else{'Segoe UI, Microsoft YaHei UI'}))
 $t.FontWeight=[Windows.FontWeightConverter]::new().ConvertFromString($weight)
 $t.VerticalAlignment='Center';$t.TextTrimming='CharacterEllipsis';return $t
}
function New-QmPanel([bool]$horizontal){$p=[Windows.Controls.StackPanel]::new();if($horizontal){$p.Orientation='Horizontal'};return $p}
function New-QmWindow {
 $w=[Windows.Window]::new();$w.WindowStyle='None';$w.AllowsTransparency=$true;$w.Background=[Windows.Media.Brushes]::Transparent
 $w.ResizeMode='NoResize';$w.ShowInTaskbar=$false;$w.ShowActivated=$false;$w.Topmost=$true;$w.SizeToContent='WidthAndHeight'
 $w.SnapsToDevicePixels=$true;$w.UseLayoutRounding=$true;$w.Title='Qoder Meter';return $w
}
function Get-QmHwnd($window){return [Windows.Interop.WindowInteropHelper]::new($window).Handle}
function Set-QmNoActivate($window){$h=Get-QmHwnd $window;if($h -ne [IntPtr]::Zero){$ex=[QoderMeter.Native]::GetWindowLongW($h,-20);[void][QoderMeter.Native]::SetWindowLongW($h,-20,($ex -bor 0x08000080))}}
function New-QmBorder($skin,[double]$radius){$t=$script:QM_SKINS[$skin];$b=[Windows.Controls.Border]::new();$b.Background=Get-QmBrush $t.bg;$b.BorderBrush=Get-QmBrush $t.border;$b.BorderThickness=[Windows.Thickness]::new(1);$b.CornerRadius=[Windows.CornerRadius]::new($radius);return $b}
function Reset-QmViewRefs {
 $script:UI_SEGS=@{};$script:UI_GROUPS=@{};$script:UI_TPS=$null;$script:UI_TITLE=$null;$script:UI_STATUS=$null;$script:UI_SUB=$null;$script:UI_FOOT=$null;$script:UI_CREDIT=$null;$script:UI_CREDIT_DOT=$null;$script:UI_SPARK=$null;$script:UI_DOT=$null;$script:UI_STATE_PILL=$null;$script:UI_BAR=$null;$script:UI_GEAR=$null;$script:UI_HALO=$null;$script:UI_SPARK_RECTS=@()
}
function New-QmGear($skin,[double]$size){
 $b=[Windows.Controls.Button]::new();$b.Content=[string][char]0xE713;$b.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets');$b.FontSize=12
 $b.Width=$size;$b.Height=$size;$b.Padding=[Windows.Thickness]::new(0);$b.BorderThickness=[Windows.Thickness]::new(0)
 $b.Background=[Windows.Media.Brushes]::Transparent;$b.Foreground=Get-QmBrush $script:QM_SKINS[$skin].gray;$b.Cursor='Hand';$b.ToolTip='设置 Qoder Meter'
 [Windows.Automation.AutomationProperties]::SetName($b,'Qoder Meter 设置')
 $b.Add_Click({param($sender,$eventArgs) $eventArgs.Handled=$true;Show-QmSettings})
 $script:UI_GEAR=$b;return $b
}
function New-QmPill($text,$skin,[double]$width,[double]$height){
 $p=[Windows.Controls.Border]::new();$p.CornerRadius=[Windows.CornerRadius]::new($height/2);$p.Background=Get-QmBrush $script:QM_SKINS[$skin].grayTint
 if($width -gt 0){$p.Width=$width}else{$p.Padding=[Windows.Thickness]::new(10,0,10,0);$p.MinWidth=44}
 $p.Height=$height;$p.Margin=[Windows.Thickness]::new(3,0,0,0)
 $tx=New-QmText $text 11 $script:QM_SKINS[$skin].gray 'Medium';$tx.HorizontalAlignment='Center';$p.Child=$tx;return $p
}
function New-QmBarField($skin,[double]$sc){
 # The leading status dot is always present. Keep each divider inside its following
 # field so adaptive hiding removes both, without leaving leading/trailing rules.
 $p=New-QmPanel $true;$p.Tag='QmBarField';$p.Margin=[Windows.Thickness]::new(0,0,4*$sc,0)
 $line=[Windows.Controls.Border]::new();$line.Tag='QmBarSeparator';$line.Width=1;$line.Height=12*$sc
 $line.Background=Get-QmBrush $script:QM_SKINS[$skin].gray;$line.Opacity=.35;$line.VerticalAlignment='Center'
 $line.Margin=[Windows.Thickness]::new(0,0,4*$sc,0);$line.IsHitTestVisible=$false;$line.SnapsToDevicePixels=$true
 [void]$p.Children.Add($line);return $p
}
function Build-QmBar($cfg,$skin,[double]$sc){
 Reset-QmViewRefs;$t=$script:QM_SKINS[$skin]
 $border=New-QmBorder $skin 10;$border.Height=[math]::Min(30,26*$sc);$border.Width=680
 $grid=[Windows.Controls.Grid]::new();$grid.Margin=[Windows.Thickness]::new(7,0,4,0)
 foreach($width in @('Auto','*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($cd)}
 $left=New-QmPanel $true;$middle=New-QmPanel $true;$right=New-QmPanel $true
 [Windows.Controls.Grid]::SetColumn($middle,1);[Windows.Controls.Grid]::SetColumn($right,2)
 [void]$grid.Children.Add($left);[void]$grid.Children.Add($middle);[void]$grid.Children.Add($right);$middle.ClipToBounds=$true
 $halo=[Windows.Controls.Border]::new();$halo.Width=14;$halo.Height=14;$halo.CornerRadius=[Windows.CornerRadius]::new(7);$halo.Background=Get-QmBrush $t.grayTint;$halo.Margin=[Windows.Thickness]::new(0,0,6,0)
 $dot=[Windows.Shapes.Ellipse]::new();$dot.Width=6;$dot.Height=6;$dot.Fill=Get-QmBrush $t.gray;$halo.Child=$dot;[void]$left.Children.Add($halo);$script:UI_DOT=$dot;$script:UI_HALO=$halo
 if($cfg.display.tps){
  $lab=New-QmText 'TPS' (9.5*$sc) $t.faint;$lab.Margin=[Windows.Thickness]::new(0,0,4,0);[void]$left.Children.Add($lab)
  $v=New-QmText '—' (18*$sc) $t.green 'SemiBold' $true;$v.MinWidth=46*$sc;$v.Margin=[Windows.Thickness]::new(0,0,5,0);[void]$left.Children.Add($v);$script:UI_TPS=$v
 }
 $defs=@(@('title','',140),@('turn','本轮 ',100),@('age','总计 ',108),@('token','Token ',108),@('balance','余额 ',94),@('credits','消耗 ',94),@('requests','请求 ',74),@('tools','工具 ',74),@('latency','延迟 ',96))
 foreach($def in $defs){
  $key=$def[0];if(!$cfg.display[$key]){continue};if($key -eq 'title' -and $cfg.layout -in @('title','toolbar')){continue}
  $p=New-QmBarField $skin $sc
  if($def[1]){[void]$p.Children.Add((New-QmText $def[1] (10.5*$sc) $t.soft))}
  $v=New-QmText '—' (12*$sc) $(if($key -eq 'credits'){$t.gold}else{$t.text}) 'Medium' ($key -ne 'title')
  $v.MaxWidth=110*$sc;[void]$p.Children.Add($v);[void]$middle.Children.Add($p)
  $script:UI_GROUPS[$key]=[pscustomobject]@{Element=$p;Need=[double]$def[2]*$sc}
  if($key -eq 'title'){$script:UI_TITLE=$v}else{$script:UI_SEGS[$key]=$v}
 }
 if($cfg.display.status){
  $p=New-QmBarField $skin $sc;$pill=New-QmPill '等待会话' $skin 0 (20*$sc);$pill.Margin=[Windows.Thickness]::new(0)
  [void]$p.Children.Add($pill);[void]$right.Children.Add($p);$script:UI_STATUS=$pill.Child;$script:UI_STATE_PILL=$pill
 }
 if($cfg.display.credit){
  $p=New-QmBarField $skin $sc;$pill=New-QmPill '账户读取中' $skin 0 (20*$sc);$pill.Margin=[Windows.Thickness]::new(0)
  [void]$p.Children.Add($pill);[void]$right.Children.Add($p);$script:UI_CREDIT=$pill.Child
 }
 [void]$right.Children.Add((New-QmGear $skin (22*$sc)))
 $border.Child=$grid;$script:UI_BAR=$border;$script:UI_BAR_LEFT=$left;$script:UI_BAR_RIGHT=$right;$script:UI_BAR_SCALE=$sc;$script:UI_BAR_PAD=15
 return $border
}
function Get-QmPreferredBarWidth {
 $infinite=[Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)
 $script:UI_BAR_LEFT.Measure($infinite);$script:UI_BAR_RIGHT.Measure($infinite)
 $need=$script:UI_BAR_PAD+$script:UI_BAR_LEFT.DesiredSize.Width+$script:UI_BAR_RIGHT.DesiredSize.Width
 foreach($group in $script:UI_GROUPS.Values){
  $was=$group.Element.Visibility;$group.Element.Visibility='Visible';$group.Element.Measure($infinite)
  $need+=$group.Element.DesiredSize.Width;$group.Element.Visibility=$was
 }
 return [math]::Ceiling($need)
}
function Get-QmContentBarWidth {
 if(!$script:UI_BAR){return 0}
 $infinite=[Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)
 $script:UI_BAR_LEFT.Measure($infinite);$script:UI_BAR_RIGHT.Measure($infinite)
 $need=$script:UI_BAR_PAD+$script:UI_BAR_LEFT.DesiredSize.Width+$script:UI_BAR_RIGHT.DesiredSize.Width
 foreach($group in $script:UI_GROUPS.Values){
  if($group.Element.Visibility -eq 'Collapsed'){continue}
  $group.Element.Measure($infinite);$need+=$group.Element.DesiredSize.Width
 }
 return [math]::Ceiling($need)
}
function Set-QmBarWidth([double]$available){
 if(!$script:UI_BAR){return}
 $infinite=[Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)
 $script:UI_BAR_LEFT.Measure($infinite);$script:UI_BAR_RIGHT.Measure($infinite)
 $fixed=$script:UI_BAR_PAD+$script:UI_BAR_LEFT.DesiredSize.Width+$script:UI_BAR_RIGHT.DesiredSize.Width
 $widths=@{}
 foreach($key in $script:UI_GROUPS.Keys){
  $el=$script:UI_GROUPS[$key].Element;$el.Visibility='Visible';$el.Measure($infinite);$widths[$key]=[double]$el.DesiredSize.Width
 }
 $budget=[math]::Max(0.0,$available-$fixed);$used=0.0
 # Keep core accounting before ancillary metrics; all suppressed values remain in the tooltip.
 foreach($key in @('balance','token','credits','turn','age','latency','requests','tools','title')){
  if(!$widths.ContainsKey($key)){continue}
  $w=$widths[$key]
  if($w -le ($budget-$used+0.01)){$script:UI_GROUPS[$key].Element.Visibility='Visible';$used+=$w}
  else{$script:UI_GROUPS[$key].Element.Visibility='Collapsed'}
 }
 $width=[math]::Min($available,[math]::Ceiling($fixed+$used))
 if($width -lt 40){$width=40}
 $script:UI_BAR.Width=$width
}
function Add-QmCanvas($canvas,$element,[double]$x,[double]$y){[Windows.Controls.Canvas]::SetLeft($element,$x);[Windows.Controls.Canvas]::SetTop($element,$y);[void]$canvas.Children.Add($element)}
function Build-QmCard($cfg,$skin,[double]$sc){
 Reset-QmViewRefs;$t=$script:QM_SKINS[$skin];$b=New-QmBorder $skin 14;$b.Width=246;$b.Height=250
 $c=[Windows.Controls.Canvas]::new();$b.Child=$c
 $dot=[Windows.Shapes.Ellipse]::new();$dot.Width=7;$dot.Height=7;$dot.Fill=Get-QmBrush $t.gray;Add-QmCanvas $c $dot 16 20;$script:UI_DOT=$dot
 Add-QmCanvas $c (New-QmText '会话统计' 9.5 $t.faint 'Medium') 32 15
 $pill=New-QmPill '等待会话' $skin 99 20;Add-QmCanvas $c $pill 128 11;$script:UI_STATUS=$pill.Child;$script:UI_STATE_PILL=$pill
 $ttl=New-QmText '等待 Qoder 会话' 14.2 $t.text 'SemiBold';$ttl.Width=218;Add-QmCanvas $c $ttl 14 39;$script:UI_TITLE=$ttl
 Add-QmCanvas $c (New-QmText '本轮 TPS' 9.5 $t.faint) 14 66
 $v=New-QmText '—' 30 $t.green 'SemiBold' $true;$v.Width=112;Add-QmCanvas $c $v 13 83;$script:UI_TPS=$v
 Add-QmCanvas $c (New-QmText 'tok/s' 9.2 $t.faint) 83 117
 $spark=[Windows.Controls.Canvas]::new();$spark.Width=102;$spark.Height=29;Add-QmCanvas $c $spark 128 94;$script:UI_SPARK=$spark
 for($i=0;$i -lt 14;$i++){$rect=[Windows.Shapes.Rectangle]::new();$rect.Width=4.2;$rect.Height=2;$rect.RadiusX=2;$rect.RadiusY=2;$rect.Fill=Get-QmBrush $t.track;[Windows.Controls.Canvas]::SetLeft($rect,($i*7));[Windows.Controls.Canvas]::SetBottom($rect,0);[void]$spark.Children.Add($rect);$script:UI_SPARK_RECTS+=,$rect}
 $line=[Windows.Controls.Border]::new();$line.Width=218;$line.Height=1;$line.Background=Get-QmBrush $t.divider;Add-QmCanvas $c $line 14 136
 $line=[Windows.Controls.Border]::new();$line.Width=1;$line.Height=64;$line.Background=Get-QmBrush $t.divider;Add-QmCanvas $c $line 122 144
 foreach($cell in @(@('turn','本轮',14,145),@('age','总计',130,145),@('token','Token',14,180),@('credits','消耗',130,180))){
  Add-QmCanvas $c (New-QmText $cell[1] 9.2 $t.faint) $cell[2] $cell[3]
  $v=New-QmText '—' 13 $(if($cell[0] -eq 'credits'){$t.gold}else{$t.text}) 'Medium' $true;$v.Width=100
  Add-QmCanvas $c $v $cell[2] ($cell[3]+14);$script:UI_SEGS[$cell[0]]=$v
 }
 $foot=New-QmText '延迟 — · 0 请求 · 0 工具' 9 $t.faint;$foot.Width=218;Add-QmCanvas $c $foot 14 214;$script:UI_FOOT=$foot
 $credit=New-QmText '余 — · 今 —' 9.5 $t.gray 'Medium';$credit.Width=198;Add-QmCanvas $c $credit 14 232;$script:UI_CREDIT=$credit
 Add-QmCanvas $c (New-QmGear $skin 22) 212 225
 return $b
}
function Get-QoderWindowInfo {
 $script:QoderWin=$null
 $cb=[QoderMeter.Native+EnumWindowsProc]{param($h,$l)
  try{
   if(![QoderMeter.Native]::IsWindowVisible($h) -or [QoderMeter.Native]::IsIconic($h)){return $true}
   if([QoderMeter.Native]::GetClass($h) -ne 'Chrome_WidgetWin_1' -or [QoderMeter.Native]::GetTitle($h) -notmatch 'Qoder'){return $true}
   $procId=[uint32]0;[void][QoderMeter.Native]::GetWindowThreadProcessId($h,[ref]$procId)
   if((Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName -notin @('Qoder','QoderCN')){return $true}
   $r=[QoderMeter.Native]::DwmFrame($h);$ww=$r.Right-$r.Left;$hh=$r.Bottom-$r.Top
   if($ww -lt 320 -or $hh -lt 240){return $true}
   if(!$script:QoderWin -or $ww*$hh -gt $script:QoderWin.W*$script:QoderWin.H){
    $dpi=[QoderMeter.Native]::GetDpiForWindow($h);if(!$dpi){$dpi=96};$screen=[Windows.Forms.Screen]::FromHandle($h)
    $script:QoderWin=[pscustomobject]@{Hwnd=[long]$h;Pid=[long]$procId;L=$r.Left;T=$r.Top;R=$r.Right;B=$r.Bottom;W=$ww;H=$hh;Dpi=$dpi;WorkL=$screen.WorkingArea.Left;WorkT=$screen.WorkingArea.Top;WorkR=$screen.WorkingArea.Right;WorkB=$screen.WorkingArea.Bottom;Fullscreen=($r.Top -le $screen.Bounds.Top -and $r.Bottom -ge $screen.Bounds.Bottom -and $ww -ge $screen.Bounds.Width)}
   }
  }catch{};return $true
 }
 [void][QoderMeter.Native]::EnumWindows($cb,[IntPtr]::Zero);return $script:QoderWin
}
function Test-QoderForeground {$id=[uint32]0;[void][QoderMeter.Native]::GetWindowThreadProcessId([QoderMeter.Native]::GetForegroundWindow(),[ref]$id);return [long]$id}
function Get-QmWindowScale($window){$d=[QoderMeter.Native]::GetDpiForWindow((Get-QmHwnd $window));if(!$d){$d=96};return $d/96.0}
function Set-QmWindowPos($window,[int]$xPhys,[int]$yPhys){
 $h=Get-QmHwnd $window
 # SWP_NOSIZE | NOACTIVATE | NOOWNERZORDER: precise placement also works at negative monitor origins.
 [void][QoderMeter.Native]::SetWindowPos($h,[IntPtr]::new(-1),$xPhys,$yPhys,0,0,0x0211)
}
