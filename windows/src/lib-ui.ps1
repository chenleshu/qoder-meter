# WPF views. Geometry is physical pixels; controls use DIP. Values update in place.
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
. (Join-Path $PSScriptRoot 'lib-menu.ps1')
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
$script:QM_FIELD_NAMES=[ordered]@{tps='TPS';turn='本轮';age='总计';token='Token';credits='消耗';requests='请求';tools='工具';latency='延迟';status='状态';title='标题';credit='账户积分'}
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
 $script:UI_SEGS=@{};$script:UI_GROUPS=@{};$script:UI_TPS=$null;$script:UI_TITLE=$null;$script:UI_STATUS=$null;$script:UI_SUB=$null;$script:UI_FOOT=$null;$script:UI_CREDIT=$null;$script:UI_CREDIT_DOT=$null;$script:UI_SPARK=$null;$script:UI_DOT=$null;$script:UI_STATE_PILL=$null;$script:UI_BAR=$null;$script:UI_GEAR=$null;$script:UI_HALO=$null;$script:UI_SPARK_RECTS=@();$script:UI_TIP=$null
 $script:UI_BAR_PILLS=@{};$script:UI_BAR_TPS=$null;$script:UI_BAR_METRICS_SIG=''
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
 if($width -gt 0){$p.Width=$width}else{$p.Padding=[Windows.Thickness]::new(8,0,8,0);$p.MinWidth=40}
 $p.Height=$height;$p.Margin=[Windows.Thickness]::new(3,0,0,0)
 $tx=New-QmText $text 11 $script:QM_SKINS[$skin].gray 'Medium';$tx.HorizontalAlignment='Center';$p.Child=$tx;return $p
}
function New-QmTipPill($skin,[double]$sc){
 $p=[Windows.Controls.Border]::new();$p.CornerRadius=[Windows.CornerRadius]::new(9*$sc);$p.Height=18*$sc
 $p.Padding=[Windows.Thickness]::new(8*$sc,0,8*$sc,0);$p.VerticalAlignment='Center';$p.Background=Get-QmBrush $script:QM_SKINS[$skin].grayTint
 $tx=New-QmText '等待会话' (10.5*$sc) $script:QM_SKINS[$skin].gray 'Medium';$tx.HorizontalAlignment='Center'
 $p.Child=$tx;return $p
}
function New-QmTipCard($skin,[double]$sc){
 # A themed floating card replaces the stock plain-text tooltip. Controls keep fixed
 # slots so a tick only changes text/color and never re-creates the popup surface.
 $t=$script:QM_SKINS[$skin]
 $card=[Windows.Controls.Border]::new();$card.Background=Get-QmBrush $t.bg;$card.BorderBrush=Get-QmBrush $t.border
 $card.BorderThickness=[Windows.Thickness]::new(1);$card.CornerRadius=[Windows.CornerRadius]::new(12*$sc)
 $card.Padding=[Windows.Thickness]::new(14*$sc,12*$sc,14*$sc,12*$sc);$card.Width=[math]::Round(384*$sc)
 $card.Margin=[Windows.Thickness]::new(9)
 $shadow=[Windows.Media.Effects.DropShadowEffect]::new();$shadow.Color=[Windows.Media.Color]::FromArgb(255,0,0,0);$shadow.BlurRadius=20;$shadow.ShadowDepth=4;$shadow.Direction=270
 $shadow.Opacity=$(if($skin -eq 'graphite' -or $skin -eq 'dusk'){.55}else{.16});$card.Effect=$shadow
 $stack=[Windows.Controls.StackPanel]::new();$card.Child=$stack
 $head=[Windows.Controls.Grid]::new()
 foreach($w in @('Auto','*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($w);[void]$head.ColumnDefinitions.Add($cd)}
 $dot=[Windows.Shapes.Ellipse]::new();$dot.Width=8*$sc;$dot.Height=8*$sc;$dot.Fill=Get-QmBrush $t.gray;$dot.VerticalAlignment='Center';$dot.Margin=[Windows.Thickness]::new(0,0,8*$sc,0)
 [Windows.Controls.Grid]::SetColumn($dot,0);[void]$head.Children.Add($dot)
 $title=New-QmText '等待 Qoder 会话' (13.5*$sc) $t.text 'SemiBold';$title.TextTrimming='CharacterEllipsis';$title.Margin=[Windows.Thickness]::new(0,0,10*$sc,0)
 [Windows.Controls.Grid]::SetColumn($title,1);[void]$head.Children.Add($title)
 $statePill=New-QmTipPill $skin $sc;[Windows.Controls.Grid]::SetColumn($statePill,2);[void]$head.Children.Add($statePill)
 [void]$stack.Children.Add($head)
 $model=New-QmText '模型 —' (10.5*$sc) $t.faint;$model.Margin=[Windows.Thickness]::new(0,4*$sc,0,0);[void]$stack.Children.Add($model)
 $rule1=[Windows.Controls.Border]::new();$rule1.Height=1;$rule1.Background=Get-QmBrush $t.divider;$rule1.Margin=[Windows.Thickness]::new(0,10*$sc,0,9*$sc);[void]$stack.Children.Add($rule1)
 $grid=[Windows.Controls.Grid]::new()
 for($c=0;$c -lt 3;$c++){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);[void]$grid.ColumnDefinitions.Add($cd)}
 for($r=0;$r -lt 2;$r++){$rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLength]::Auto;[void]$grid.RowDefinitions.Add($rd)}
 $refs=@{}
 foreach($def in @(@('tps','本轮 TPS','—',$t.green,0,0),@('turn','本轮用时','—',$t.text,1,0),@('age','会话总时长','—',$t.text,2,0),@('token','输出 Token','—',$t.blue,0,1),@('credits','本会话消耗','—',$t.gold,1,1),@('latency','请求耗时','—',$t.faint,2,1))){
  $cell=[Windows.Controls.StackPanel]::new();$cell.Margin=[Windows.Thickness]::new(0,$(if($def[5]){9*$sc}else{0}),8*$sc,0)
  [void]$cell.Children.Add((New-QmText $def[1] (9.5*$sc) $t.faint))
  $v=New-QmText $def[2] (14.5*$sc) $def[3] 'SemiBold' $true
  [void]$cell.Children.Add($v)
  [Windows.Controls.Grid]::SetColumn($cell,$def[4]);[Windows.Controls.Grid]::SetRow($cell,$def[5]);[void]$grid.Children.Add($cell);$refs[$def[0]]=$v
 }
 [void]$stack.Children.Add($grid)
 $meta=New-QmText '请求 — · 工具 — · 积分/请求 —' (9.5*$sc) $t.faint;$meta.Margin=[Windows.Thickness]::new(0,10*$sc,0,0);[void]$stack.Children.Add($meta)
 $rule2=[Windows.Controls.Border]::new();$rule2.Height=1;$rule2.Background=Get-QmBrush $t.divider;$rule2.Margin=[Windows.Thickness]::new(0,10*$sc,0,10*$sc);[void]$stack.Children.Add($rule2)
 $box=[Windows.Controls.Border]::new();$box.Background=Get-QmBrush $t.grayTint;$box.CornerRadius=[Windows.CornerRadius]::new(9*$sc)
 $box.Padding=[Windows.Thickness]::new(10*$sc,8*$sc,10*$sc,8*$sc);[void]$stack.Children.Add($box)
 $inner=[Windows.Controls.StackPanel]::new();$box.Child=$inner
 $row=[Windows.Controls.DockPanel]::new();$row.LastChildFill=$false
 $cap=New-QmText '账户与权益' (9.5*$sc) $t.faint 'Medium';[Windows.Controls.DockPanel]::SetDock($cap,'Left');[void]$row.Children.Add($cap)
 $claim=New-QmTipPill $skin $sc;[Windows.Controls.DockPanel]::SetDock($claim,'Right');[void]$row.Children.Add($claim)
 [void]$inner.Children.Add($row)
 $balRow=[Windows.Controls.StackPanel]::new();$balRow.Orientation='Horizontal';$balRow.Margin=[Windows.Thickness]::new(0,5*$sc,0,0)
 $balance=New-QmText '—' (19*$sc) $t.gold 'SemiBold' $true;[void]$balRow.Children.Add($balance)
 $plan=New-QmText '' (10*$sc) $t.soft;$plan.Margin=[Windows.Thickness]::new(9*$sc,0,0,0);[void]$balRow.Children.Add($plan)
 [void]$inner.Children.Add($balRow)
 $break=New-QmText '—' (9.2*$sc) $t.faint;$break.TextWrapping='Wrap';$break.TextTrimming='None';$break.Margin=[Windows.Thickness]::new(0,2*$sc,0,0);[void]$inner.Children.Add($break)
 $packages=New-QmText '' (9.2*$sc) $t.gray;$packages.TextWrapping='Wrap';$packages.TextTrimming='None';$packages.Margin=[Windows.Thickness]::new(0,2*$sc,0,0);[void]$inner.Children.Add($packages)
 $today=New-QmText '今日已领 +0' (10.2*$sc) $t.green 'Medium';$today.Margin=[Windows.Thickness]::new(0,6*$sc,0,0);[void]$inner.Children.Add($today)
 $items=New-QmText '' (9.2*$sc) $t.faint;$items.TextWrapping='Wrap';$items.TextTrimming='None';$items.Margin=[Windows.Thickness]::new(0,2*$sc,0,0);[void]$inner.Children.Add($items)
 $msg=New-QmText '' (9.5*$sc) $t.gray;$msg.TextWrapping='Wrap';$msg.TextTrimming='None';$msg.Margin=[Windows.Thickness]::new(0,3*$sc,0,0);$msg.Visibility='Collapsed';[void]$inner.Children.Add($msg)
 $foot=New-QmText '≈ 表示按字符估算 · 余额、套餐与权益来自 Qoder 账号' (8.8*$sc) $t.faint;$foot.TextWrapping='Wrap';$foot.TextTrimming='None';$foot.Margin=[Windows.Thickness]::new(0,9*$sc,0,0);[void]$stack.Children.Add($foot)
 $diag=New-QmText '' (9*$sc) $t.red;$diag.TextWrapping='Wrap';$diag.TextTrimming='None';$diag.Margin=[Windows.Thickness]::new(0,4*$sc,0,0);$diag.Visibility='Collapsed';[void]$stack.Children.Add($diag)
 return [pscustomobject]@{
  Root=$card;Title=$title;Dot=$dot;State=$statePill.Child;StatePill=$statePill;Model=$model
  Tps=$refs.tps;Turn=$refs.turn;Age=$refs.age;Token=$refs.token;Credits=$refs.credits;Latency=$refs.latency;Meta=$meta
  Claim=$claim.Child;ClaimPill=$claim;BalanceRow=$balRow;Balance=$balance;Plan=$plan;Break=$break;Packages=$packages
  Today=$today;TodayItems=$items;Msg=$msg;Foot=$foot;Diag=$diag;Account=$box
 }
}
function New-QmTipHost($card){
 # Stock ToolTip chrome is a system-colored border; the card supplies its own surface.
 $tmpl=[Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type ToolTip}"><ContentPresenter/></ControlTemplate>')
 $tip=[Windows.Controls.ToolTip]::new();$tip.Template=$tmpl;$tip.Content=$card.Root
 $tip.Padding=[Windows.Thickness]::new(0);$tip.Background=[Windows.Media.Brushes]::Transparent;$tip.BorderThickness=[Windows.Thickness]::new(0)
 $tip.HasDropShadow=$false;return $tip
}
function New-QmBarField($skin,[double]$sc){
 # The leading status dot is always present. Keep each divider inside its following
 # field so adaptive hiding removes both, without leaving leading/trailing rules.
 $p=New-QmPanel $true;$p.Tag='QmBarField';$p.Margin=[Windows.Thickness]::new(0,0,2.5*$sc,0)
 $line=[Windows.Controls.Border]::new();$line.Tag='QmBarSeparator';$line.Width=1;$line.Height=12*$sc
 $line.Background=Get-QmBrush $script:QM_SKINS[$skin].gray;$line.Opacity=.35;$line.VerticalAlignment='Center'
 $line.Margin=[Windows.Thickness]::new(0,0,3*$sc,0);$line.IsHitTestVisible=$false;$line.SnapsToDevicePixels=$true
 [void]$p.Children.Add($line);return $p
}
function Set-QmBarTextSlot($text,[string]$sample,[double]$minimum=0){
 # Measure a representative capacity only while building, never the live value.
 # Fixed TextBlock widths retain ellipsis while numbers/status/title change.
 $original=$text.Text;$text.Text=$sample
 $text.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
 $width=[math]::Max($minimum,[math]::Ceiling($text.DesiredSize.Width))
 $text.Text=$original;$text.Width=$width
}
function Build-QmBar($cfg,$skin,[double]$sc){
 Reset-QmViewRefs;$t=$script:QM_SKINS[$skin]
 $border=New-QmBorder $skin 10;$border.Height=26*$sc;$border.Width=680;$border.ClipToBounds=$true
 $grid=[Windows.Controls.Grid]::new();$grid.Margin=[Windows.Thickness]::new(6,0,3,0)
 foreach($width in @('Auto','*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($cd)}
 $left=New-QmPanel $true;$middle=New-QmPanel $true;$right=New-QmPanel $true
 [Windows.Controls.Grid]::SetColumn($middle,1);[Windows.Controls.Grid]::SetColumn($right,2)
 [void]$grid.Children.Add($left);[void]$grid.Children.Add($middle);[void]$grid.Children.Add($right);$middle.ClipToBounds=$true
 $halo=[Windows.Controls.Border]::new();$halo.Width=12;$halo.Height=12;$halo.CornerRadius=[Windows.CornerRadius]::new(6);$halo.Background=Get-QmBrush $t.grayTint;$halo.Margin=[Windows.Thickness]::new(0,0,5,0)
 $dot=[Windows.Shapes.Ellipse]::new();$dot.Width=6;$dot.Height=6;$dot.Fill=Get-QmBrush $t.gray;$halo.Child=$dot;[void]$left.Children.Add($halo);$script:UI_DOT=$dot;$script:UI_HALO=$halo
 if($cfg.display.tps){
  $tps=New-QmPanel $true;[void]$left.Children.Add($tps);$script:UI_BAR_TPS=$tps
  $lab=New-QmText 'TPS' (9.5*$sc) $t.faint;$lab.Margin=[Windows.Thickness]::new(0,0,3,0);[void]$tps.Children.Add($lab)
  $v=New-QmText '—' (18*$sc) $t.green 'SemiBold' $true;Set-QmBarTextSlot $v '9999' (44*$sc)
  $v.Margin=[Windows.Thickness]::new(0,0,4,0);[void]$tps.Children.Add($v);$script:UI_TPS=$v
 }
 $defs=@(@('title','',''),@('turn','本轮 ','9h 59m'),@('age','总计 ','99h 59m'),@('token','Token ','≈999.9k'),@('credits','消耗 ','9999.99'),@('requests','请求 ','999.9k'),@('tools','工具 ','999.9k'),@('latency','延迟 ','9m 59s'))
 foreach($def in $defs){
  $key=$def[0];if(!$cfg.display[$key]){continue};if($key -eq 'title' -and $cfg.layout -in @('title','toolbar')){continue}
  $p=New-QmBarField $skin $sc
  if($def[1]){[void]$p.Children.Add((New-QmText $def[1] (10.5*$sc) $t.soft))}
  $vc=switch($key){'token'{$t.blue};'credits'{$t.gold};'latency'{$t.faint};default{$t.text}}
  $weight=if($key -in @('token','credits')){'SemiBold'}else{'Medium'}
  $v=New-QmText '—' (12*$sc) $vc $weight ($key -ne 'title')
  if($key -eq 'title'){$v.Width=110*$sc}else{Set-QmBarTextSlot $v $def[2]}
  [void]$p.Children.Add($v);[void]$middle.Children.Add($p)
  $p.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $script:UI_GROUPS[$key]=[pscustomobject]@{Element=$p;Need=[double]$p.DesiredSize.Width}
  if($key -eq 'title'){$script:UI_TITLE=$v}else{$script:UI_SEGS[$key]=$v}
 }
 if($cfg.display.status){
  $p=New-QmBarField $skin $sc;$pill=New-QmPill '等待会话' $skin 0 (19*$sc);$pill.Margin=[Windows.Thickness]::new(0)
  Set-QmBarTextSlot $pill.Child '等待会话';$pill.Width=$pill.Child.Width+16
  [void]$p.Children.Add($pill);[void]$right.Children.Add($p);$script:UI_STATUS=$pill.Child;$script:UI_STATE_PILL=$pill;$script:UI_BAR_PILLS.status=$p
 }
 if($cfg.display.credit){
  $p=New-QmBarField $skin $sc;$pill=New-QmPill '账户读取中' $skin 0 (19*$sc);$pill.Margin=[Windows.Thickness]::new(0)
  Set-QmBarTextSlot $pill.Child '余 999,999 · 今 +99,999';$pill.Width=$pill.Child.Width+16
  [void]$p.Children.Add($pill);[void]$right.Children.Add($p);$script:UI_CREDIT=$pill.Child;$script:UI_BAR_PILLS.credit=$p
 }
 [void]$right.Children.Add((New-QmGear $skin (20*$sc)))
 $border.Child=$grid;$script:UI_BAR=$border;$script:UI_BAR_LEFT=$left;$script:UI_BAR_RIGHT=$right;$script:UI_BAR_SCALE=$sc;$script:UI_BAR_PAD=11
 Set-QmBarWidth 680
 return $border
}
function Sync-QmBarMeasurementContext {
 # A newly attached host or a DPI transition can leave collapsed descendants with
 # measurements from the previous context. Invalidate the whole tree once, so a
 # later text update cannot be the event that finally corrects their slot widths.
 $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($script:UI_BAR)
 $signature="$($dpi.DpiScaleX)|$($dpi.DpiScaleY)|$($script:UI_BAR.UseLayoutRounding)"
 if($signature -eq $script:UI_BAR_METRICS_SIG){return}
 $pending=[Collections.Generic.Stack[Windows.DependencyObject]]::new();$pending.Push($script:UI_BAR)
 while($pending.Count){
  $element=$pending.Pop()
  if($element -is [Windows.UIElement]){$element.InvalidateMeasure()}
  for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($element);$i++){$pending.Push([Windows.Media.VisualTreeHelper]::GetChild($element,$i))}
 }
 $script:UI_BAR_METRICS_SIG=$signature
}
function Get-QmPreferredBarWidth {
 # Measure fixed capacities with the current host's DPI/layout rounding, never
 # cache pre-host measurements. Restore the fit without changing visible fields.
 if(!$script:UI_BAR){return 0}
 Sync-QmBarMeasurementContext
 $states=@();$gearWidth=$script:UI_GEAR.Width
 $elements=@($script:UI_HALO,$script:UI_BAR_TPS)+@($script:UI_BAR_PILLS.Values)+@($script:UI_GROUPS.Values|ForEach-Object{$_.Element})
 try{
  $script:UI_GEAR.Width=20*$script:UI_BAR_SCALE
  foreach($el in $elements){if($el){$states+=@{Element=$el;Visibility=$el.Visibility};$el.Visibility='Visible'}}
  return Get-QmContentBarWidth
 }finally{$script:UI_GEAR.Width=$gearWidth;foreach($state in $states){$state.Element.Visibility=$state.Visibility}}
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
function Get-QmBarFixedWidth {
 $infinite=[Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)
 $script:UI_BAR_LEFT.Measure($infinite);$script:UI_BAR_RIGHT.Measure($infinite)
 return $script:UI_BAR_PAD+$script:UI_BAR_LEFT.DesiredSize.Width+$script:UI_BAR_RIGHT.DesiredSize.Width
}
function Set-QmBarWidth([double]$available){
 if(!$script:UI_BAR){return}
 Sync-QmBarMeasurementContext
 $available=[math]::Max(0,$available)
 $script:UI_GEAR.Width=[math]::Min(20*$script:UI_BAR_SCALE,[math]::Max(0,$available-$script:UI_BAR_PAD))
 foreach($pill in $script:UI_BAR_PILLS.Values){$pill.Visibility='Visible'}
 if($script:UI_BAR_TPS){$script:UI_BAR_TPS.Visibility='Visible'}
 $script:UI_HALO.Visibility='Visible'
 $fixed=Get-QmBarFixedWidth
 $infinite=[Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)
 foreach($group in $script:UI_GROUPS.Values){
  $group.Element.Visibility='Visible';$group.Element.Measure($infinite)
  $group.Need=[double]$group.Element.DesiredSize.Width
 }
 # Reserve core metrics before the redundant status pill in narrow regions.
 # Visibility decisions use only slot capacities; status/amount updates cannot toggle them.
 $core=0.0
 foreach($key in @('token')){if($script:UI_GROUPS.ContainsKey($key)){$core+=$script:UI_GROUPS[$key].Need}}
 if($script:UI_BAR_PILLS.status -and $fixed+$core -gt $available){
  $script:UI_BAR_PILLS.status.Visibility='Collapsed';$fixed=Get-QmBarFixedWidth
 }
 # The account pill is the only balance display; collapse it only when the fixed
 # endpoints themselves cannot fit. Full account details remain in the tooltip.
 if($script:UI_BAR_PILLS.credit -and $fixed -gt $available){
  $script:UI_BAR_PILLS.credit.Visibility='Collapsed';$fixed=Get-QmBarFixedWidth
 }
 # At very narrow widths retain settings instead of allowing fixed endpoints to overlap.
 if($script:UI_BAR_TPS -and $fixed -gt $available){
  $script:UI_BAR_TPS.Visibility='Collapsed';$fixed=Get-QmBarFixedWidth
 }
 if($fixed -gt $available){$script:UI_HALO.Visibility='Collapsed';$fixed=Get-QmBarFixedWidth}
 $budget=[math]::Max(0.0,$available-$fixed);$used=0.0
 # Keep core accounting before ancillary metrics; all suppressed values remain in the tooltip.
 foreach($key in @('token','credits','turn','age','latency','requests','tools','title')){
  if(!$script:UI_GROUPS.ContainsKey($key)){continue}
  $w=$script:UI_GROUPS[$key].Need
  if($w -le ($budget-$used+0.01)){$script:UI_GROUPS[$key].Element.Visibility='Visible';$used+=$w}
  else{$script:UI_GROUPS[$key].Element.Visibility='Collapsed'}
 }
 $width=[math]::Min($available,[math]::Max(40,[math]::Ceiling($fixed+$used)))
 if($script:UI_BAR.Width -ne $width){$script:UI_BAR.Width=$width}
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
