# Single reusable settings window. All changes use the same command router as tray items.
function New-QmSettingsButton($text,$command,$value='',[bool]$primary=$false){
 $b=New-QmThemedButton $text (Resolve-QmSkin $script:CFG.skin) $primary
 $b.Tag=@{Command=$command;Value=$value}
 $b.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 return $b
}
# A tinted surface keeps related controls together without the flat, undivided list
# the window used before. The accent bar and right-side note aid quick scanning.
function New-QmSettingsSection($parent,$title,$skin,[string]$tone='green',[string]$detail=''){
 $t=$script:QM_SKINS[$skin]
 $card=[Windows.Controls.Border]::new();$card.Background=Get-QmBrush $t.track;$card.BorderBrush=Get-QmBrush $t.divider
 $card.BorderThickness=[Windows.Thickness]::new(1);$card.CornerRadius=[Windows.CornerRadius]::new(12)
 $card.Padding=[Windows.Thickness]::new(14,12,14,14);$card.Margin=[Windows.Thickness]::new(0,0,0,12)
 $body=[Windows.Controls.StackPanel]::new();$card.Child=$body
 $head=[Windows.Controls.DockPanel]::new();$head.Margin=[Windows.Thickness]::new(0,0,0,8)
 $flag=[Windows.Controls.Border]::new();$flag.Width=3;$flag.Height=13;$flag.CornerRadius=[Windows.CornerRadius]::new(1.5)
 $flag.Background=Get-QmBrush $t[$tone];$flag.VerticalAlignment='Center';$flag.Margin=[Windows.Thickness]::new(0,0,8,0)
 [Windows.Controls.DockPanel]::SetDock($flag,'Left');[void]$head.Children.Add($flag)
 if($detail){$d=New-QmText $detail 9.5 $t.faint;[Windows.Controls.DockPanel]::SetDock($d,'Right');[void]$head.Children.Add($d)}
 [void]$head.Children.Add((New-QmText $title 12.5 $t.text 'SemiBold'))
 [void]$body.Children.Add($head);[void]$parent.Children.Add($card)
 return $body
}
function New-QmSettingsChoice($label,$key,$choices,$selected,$skin){
 $box=[Windows.Controls.StackPanel]::new()
 $lab=New-QmText $label 10.5 $script:QM_SKINS[$skin].faint;$lab.Margin=[Windows.Thickness]::new(0,0,0,5)
 [void]$box.Children.Add($lab)
 $c=[Windows.Controls.ComboBox]::new();$c.Tag=$key;$c.MinHeight=34;$c.FontSize=12;$c.Padding=[Windows.Thickness]::new(9,4,9,4)
 $c.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'QmCombo')
 foreach($k in $choices.Keys){$it=[Windows.Controls.ComboBoxItem]::new();$it.Content=$choices[$k];$it.Tag=$k;[void]$c.Items.Add($it);if($k -eq $selected){$c.SelectedItem=$it}}
 $c.Add_SelectionChanged({param($sender,$eventArgs) if(!$script:QM_SETTINGS_BUILDING -and $sender.SelectedItem){Invoke-QmCommand 'set' @{Key=$sender.Tag;Value=$sender.SelectedItem.Tag}}})
 [void]$box.Children.Add($c);$script:QM_SETTINGS_CONTROLS[$key]=$c
 return $box
}
function Add-QmSettingsCheck($parent,$text,$key,[bool]$checked,$skin,[string]$variant='row'){
 $c=[Windows.Controls.CheckBox]::new();$c.Content=$text;$c.Tag=$key;$c.IsChecked=$checked;$c.FontSize=11.5
 $c.Foreground=Get-QmBrush $script:QM_SKINS[$skin].text
 if($variant -eq 'chip'){
  $c.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'QmChip');$c.Margin=[Windows.Thickness]::new(0,0,6,6)
  $tips=@{tps='每秒输出 Token';turn='本轮用时';age='会话总时长';token='累计输出 Token';credits='本会话消耗';requests='请求次数';tools='工具调用次数';latency='最近请求耗时';status='会话状态';title='会话标题';credit='余额与今日领取'}
  if($key.StartsWith('display.') -and $tips.ContainsKey($key.Substring(8))){$c.ToolTip=$tips[$key.Substring(8)]}
 }else{
  $c.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'QmCheck');$c.Margin=[Windows.Thickness]::new(0,0,0,2)
 }
 $c.Add_Click({param($sender,$eventArgs) if(!$script:QM_SETTINGS_BUILDING){Invoke-QmCommand 'set' @{Key=$sender.Tag;Value=[bool]$sender.IsChecked}}})
 $script:QM_SETTINGS_CONTROLS[$key]=$c;[void]$parent.Children.Add($c)
}
# Called only while QM_SETTINGS_BUILDING suppresses selection events.
function Sync-QmSettingsPinned {
 $control=$script:QM_SETTINGS_CONTROLS['pinned'];if(!$control){return}
 $recent=[ordered]@{}
 foreach($r in $script:QM_S.recent){if($r.session_id){$recent[[string]$r.session_id]=Cut-QmText ([string]$r.title) 34}}
 $pin=[string]$script:CFG.pinned
 if($pin -and !$recent.Contains($pin) -and $script:QM_S.sessionId -eq $pin){$recent[$pin]=Cut-QmText ([string]$script:QM_S.title) 34}
 # JSON preserves order and avoids delimiter collisions in IDs/titles; compare case-sensitively.
 $signature=ConvertTo-Json -InputObject $recent -Compress
 if($control.Resources['QmRecentSignature'] -cne $signature){
  $control.Items.Clear()
  foreach($key in $recent.Keys){$it=[Windows.Controls.ComboBoxItem]::new();$it.Tag=$key;$it.Content=$recent[$key];[void]$control.Items.Add($it)}
  $control.Resources['QmRecentSignature']=$signature
 }
 $control.IsEnabled=($control.Items.Count -gt 0)
 $selected=$null
 if($pin){foreach($it in $control.Items){if($it.Tag -eq $pin){$selected=$it;break}}}
 if($selected){$control.SelectedItem=$selected}else{$control.SelectedIndex=-1}
}
function New-QmSettingsWindow {
 $building=$script:QM_SETTINGS_BUILDING;$script:QM_SETTINGS_BUILDING=$true;$script:QM_SETTINGS_CONTROLS=@{}
 try{
  $skin=Resolve-QmSkin $script:CFG.skin;$t=$script:QM_SKINS[$skin]
  $w=[Windows.Window]::new();$w.Title='Qoder Meter 设置';$w.Width=450;$w.Height=760;$w.MinWidth=420;$w.MinHeight=540;$w.ResizeMode='CanResize';$w.ShowInTaskbar=$false;$w.WindowStartupLocation='CenterScreen'
  Initialize-QmThemedWindow $w $skin
  $outer=[Windows.Controls.DockPanel]::new();$outer.Margin=[Windows.Thickness]::new(22)
  $footer=[Windows.Controls.Border]::new();$footer.BorderBrush=Get-QmBrush $t.divider;$footer.BorderThickness=[Windows.Thickness]::new(0,1,0,0);$footer.Padding=[Windows.Thickness]::new(0,12,0,0);$footer.Margin=[Windows.Thickness]::new(0,6,0,0)
  [Windows.Controls.DockPanel]::SetDock($footer,'Bottom')
  $fg=[Windows.Controls.Grid]::new()
  foreach($width in @('*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$fg.ColumnDefinitions.Add($cd)}
  $left=[Windows.Controls.StackPanel]::new();$left.Orientation='Horizontal'
  [void]$left.Children.Add((New-QmSettingsButton '重置当前位置' 'reset'))
  $fhint=New-QmText '设置即时保存' 9.5 $t.faint;$fhint.Margin=[Windows.Thickness]::new(10,0,0,0);[void]$left.Children.Add($fhint)
  [void]$fg.Children.Add($left)
  $done=New-QmSettingsButton '完成' 'done' '' $true;$done.IsDefault=$true;$done.IsCancel=$true;$done.MinWidth=82
  [Windows.Controls.Grid]::SetColumn($done,1);[void]$fg.Children.Add($done)
  $footer.Child=$fg;[void]$outer.Children.Add($footer)
  $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$script:QM_SETTINGS_CONTROLS['scroll']=$scroll
  $body=[Windows.Controls.StackPanel]::new();$body.Margin=[Windows.Thickness]::new(0,0,10,6);$scroll.Content=$body;[void]$outer.Children.Add($scroll);$w.Content=$outer
  # Header -------------------------------------------------------------
  $head=[Windows.Controls.Grid]::new()
  foreach($width in @('Auto','*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$head.ColumnDefinitions.Add($cd)}
  $logo=[Windows.Controls.Border]::new();$logo.Width=38;$logo.Height=38;$logo.CornerRadius=[Windows.CornerRadius]::new(11);$logo.Background=Get-QmBrush $t.greenTint
  $mark=New-QmText ([string][char]0xE9D9) 16 $t.green 'SemiBold';$mark.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets');$mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center'
  $logo.Child=$mark;[void]$head.Children.Add($logo)
  $titleBox=[Windows.Controls.StackPanel]::new();$titleBox.Margin=[Windows.Thickness]::new(11,0,8,0);$titleBox.VerticalAlignment='Center'
  [void]$titleBox.Children.Add((New-QmText 'Qoder Meter' 18 $t.text 'SemiBold'))
  $sub=New-QmText ('Windows '+$script:QM_VERSION+' · 设置即时生效') 10 $t.faint;$sub.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$titleBox.Children.Add($sub)
  [Windows.Controls.Grid]::SetColumn($titleBox,1);[void]$head.Children.Add($titleBox)
  $up=New-QmSettingsButton '检查更新' 'update';$up.FontSize=10.5;$up.Padding=[Windows.Thickness]::new(10,4,10,4);$up.MinHeight=28;$up.VerticalAlignment='Center'
  [Windows.Controls.Grid]::SetColumn($up,2);[void]$head.Children.Add($up);$script:QM_SETTINGS_CONTROLS['update']=$up
  [void]$body.Children.Add($head)
  $upText=New-QmText '' 10 $t.soft;$upText.TextWrapping='Wrap';$upText.Margin=[Windows.Thickness]::new(0,8,0,0);[void]$body.Children.Add($upText);$script:QM_SETTINGS_CONTROLS['updateText']=$upText
  # Account summary ----------------------------------------------------
  $acct=New-QmSettingsSection $body '账户与权益' $skin 'gold' '自动读取'
  $acctTop=[Windows.Controls.Grid]::new()
  foreach($width in @('*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$acctTop.ColumnDefinitions.Add($cd)}
  $who=[Windows.Controls.StackPanel]::new();$who.Orientation='Horizontal';$who.VerticalAlignment='Center'
  $acctName=New-QmText 'Qoder 账户' 13 $t.text 'SemiBold';$script:QM_SETTINGS_CONTROLS['accountName']=$acctName;[void]$who.Children.Add($acctName)
  $plan=[Windows.Controls.Border]::new();$plan.Background=Get-QmBrush $t.grayTint;$plan.CornerRadius=[Windows.CornerRadius]::new(7);$plan.Padding=[Windows.Thickness]::new(7,2,7,2);$plan.Margin=[Windows.Thickness]::new(8,0,0,0);$plan.VerticalAlignment='Center'
  $planText=New-QmText '—' 9.5 $t.soft 'Medium';$plan.Child=$planText;$script:QM_SETTINGS_CONTROLS['accountPlan']=$plan;$script:QM_SETTINGS_CONTROLS['accountPlanText']=$planText
  [void]$who.Children.Add($plan);[void]$acctTop.Children.Add($who)
  $statePill=[Windows.Controls.Border]::new();$statePill.Background=Get-QmBrush $t.grayTint;$statePill.CornerRadius=[Windows.CornerRadius]::new(8);$statePill.Padding=[Windows.Thickness]::new(8,2,8,2);$statePill.VerticalAlignment='Center'
  $stateText=New-QmText '读取中' 9.5 $t.gray 'Medium';$statePill.Child=$stateText;$script:QM_SETTINGS_CONTROLS['accountStatePill']=$statePill;$script:QM_SETTINGS_CONTROLS['accountState']=$stateText
  [Windows.Controls.Grid]::SetColumn($statePill,1);[void]$acctTop.Children.Add($statePill);[void]$acct.Children.Add($acctTop)
  $balRow=[Windows.Controls.Grid]::new();$balRow.Margin=[Windows.Thickness]::new(0,10,0,0)
  foreach($width in @('*','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$balRow.ColumnDefinitions.Add($cd)}
  $balLine=[Windows.Controls.StackPanel]::new();$balLine.Orientation='Horizontal'
  $balance=New-QmText '—' 24 $t.gold 'SemiBold' $true;$script:QM_SETTINGS_CONTROLS['accountBalance']=$balance;[void]$balLine.Children.Add($balance)
  $balCap=New-QmText '可用积分' 9.5 $t.faint;$balCap.Margin=[Windows.Thickness]::new(8,0,0,3);$balCap.VerticalAlignment='Bottom';[void]$balLine.Children.Add($balCap)
  [void]$balRow.Children.Add($balLine)
  $todayBox=[Windows.Controls.StackPanel]::new();$todayBox.HorizontalAlignment='Right';$todayBox.VerticalAlignment='Center'
  $today=New-QmText '+0' 14 $t.faint 'SemiBold' $true;$today.HorizontalAlignment='Right';$script:QM_SETTINGS_CONTROLS['accountToday']=$today;[void]$todayBox.Children.Add($today)
  $todaySub=New-QmText '今日暂无领取' 9.5 $t.faint;$todaySub.HorizontalAlignment='Right';$todaySub.Margin=[Windows.Thickness]::new(0,2,0,0);$script:QM_SETTINGS_CONTROLS['accountTodaySub']=$todaySub;[void]$todayBox.Children.Add($todaySub)
  [Windows.Controls.Grid]::SetColumn($todayBox,1);[void]$balRow.Children.Add($todayBox);[void]$acct.Children.Add($balRow)
  $status=New-QmText '' 10.5 $t.soft;$status.TextWrapping='Wrap';$status.TextTrimming='None';$status.Margin=[Windows.Thickness]::new(0,9,0,0);[void]$acct.Children.Add($status);$script:QM_SETTINGS_CONTROLS['creditStatus']=$status
  $actions=[Windows.Controls.StackPanel]::new();$actions.Orientation='Horizontal';$actions.Margin=[Windows.Thickness]::new(0,11,0,0)
  $claim=New-QmSettingsButton '立即领取全部' 'claim' '' $true;[void]$actions.Children.Add($claim);$script:QM_SETTINGS_CONTROLS['claim']=$claim
  $history=New-QmSettingsButton '领取记录' 'claims';$history.Margin=[Windows.Thickness]::new(8,0,0,0);[void]$actions.Children.Add($history)
  $usage=New-QmSettingsButton '打开用量页' 'usagePage';$usage.Margin=[Windows.Thickness]::new(8,0,0,0);[void]$actions.Children.Add($usage)
  [void]$acct.Children.Add($actions)
  $rule=[Windows.Controls.Border]::new();$rule.Height=1;$rule.Background=Get-QmBrush $t.divider;$rule.Margin=[Windows.Thickness]::new(0,12,0,4);[void]$acct.Children.Add($rule)
  Add-QmSettingsCheck $acct '发现可领权益时自动领取' 'creditAuto' $script:CFG.creditAuto $skin
  $autoHint=New-QmText '每日 10:00（UTC+8）换周期；由刷新循环触发，失败 15 分钟后重试。' 9.5 $t.faint;$autoHint.TextWrapping='Wrap';$autoHint.Margin=[Windows.Thickness]::new(9,0,0,0);[void]$acct.Children.Add($autoHint)
  # Local usage stats ---------------------------------------------------
  $usage=New-QmSettingsSection $body '本地用量统计' $skin 'blue' '不联网'
  $usageRow=[Windows.Controls.Grid]::new()
  foreach($width in @('*','Auto','Auto')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$usageRow.ColumnDefinitions.Add($cd)}
  $usageCopy=[Windows.Controls.StackPanel]::new();$usageCopy.VerticalAlignment='Center'
  [void]$usageCopy.Children.Add((New-QmText '积分与 Token 趋势' 12 $t.text 'SemiBold'))
  $usageHint=New-QmText '按日 / 周 / 月汇总本机会话日志，估算 Token 以 ≈ 标记。' 9.5 $t.faint
  $usageHint.TextWrapping='Wrap';$usageHint.TextTrimming='None';$usageHint.Margin=[Windows.Thickness]::new(0,3,10,0);[void]$usageCopy.Children.Add($usageHint)
  [void]$usageRow.Children.Add($usageCopy)
  $statsPreview=[Windows.Controls.Border]::new();$statsPreview.Width=92;$statsPreview.Height=52
  $statsPreview.CornerRadius=[Windows.CornerRadius]::new(10);$statsPreview.Background=Get-QmBrush $t.grayTint
  $statsPreview.BorderBrush=Get-QmBrush $t.divider;$statsPreview.BorderThickness=[Windows.Thickness]::new(1)
  $statsPreview.VerticalAlignment='Center';$statsPreview.Margin=[Windows.Thickness]::new(0,0,10,0)
  $statsPreview.IsHitTestVisible=$false;$statsPreview.Tag='QmStatsSettingsPreview'
  [Windows.Automation.AutomationProperties]::SetName($statsPreview,'用量统计界面预览')
  $previewCanvas=[Windows.Controls.Canvas]::new();$statsPreview.Child=$previewCanvas
  $previewTitle=New-QmText '趋势' 8 $t.faint 'Medium';[Windows.Controls.Canvas]::SetLeft($previewTitle,8);[Windows.Controls.Canvas]::SetTop($previewTitle,5);[void]$previewCanvas.Children.Add($previewTitle)
  $previewBars=@(@{X=10;H=16;C=$t.blue},@{X=27;H=26;C=$t.green},@{X=44;H=20;C=$t.gold},@{X=61;H=30;C=$t.green},@{X=78;H=23;C=$t.blue})
  foreach($bar in $previewBars){
    $rect=[Windows.Shapes.Rectangle]::new();$rect.Width=7;$rect.Height=$bar.H;$rect.RadiusX=3.5;$rect.RadiusY=3.5
    $rect.Fill=Get-QmBrush $bar.C;$rect.Opacity=.88
    [Windows.Controls.Canvas]::SetLeft($rect,$bar.X);[Windows.Controls.Canvas]::SetTop($rect,(44-$bar.H));[void]$previewCanvas.Children.Add($rect)
  }
  $previewBase=[Windows.Controls.Border]::new();$previewBase.Width=78;$previewBase.Height=1;$previewBase.Background=Get-QmBrush $t.divider
  [Windows.Controls.Canvas]::SetLeft($previewBase,8);[Windows.Controls.Canvas]::SetTop($previewBase,44);[void]$previewCanvas.Children.Add($previewBase)
  [Windows.Controls.Grid]::SetColumn($statsPreview,1);[void]$usageRow.Children.Add($statsPreview);$script:QM_SETTINGS_CONTROLS['statsPreview']=$statsPreview
  $stats=New-QmSettingsButton '打开统计' 'stats';$stats.MinHeight=32;$stats.VerticalAlignment='Center'
  [Windows.Controls.Grid]::SetColumn($stats,2);[void]$usageRow.Children.Add($stats);$script:QM_SETTINGS_CONTROLS['stats']=$stats
  [void]$usage.Children.Add($usageRow)
  # Appearance ---------------------------------------------------------
  $look=New-QmSettingsSection $body '显示位置与外观' $skin 'blue' '实时生效'
  $lookGrid=[Windows.Controls.Grid]::new()
  foreach($width in @('*','*')){$cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$lookGrid.ColumnDefinitions.Add($cd)}
  $layoutBox=New-QmSettingsChoice '停靠位置' 'layout' $script:QM_LAYOUT_NAMES $script:CFG.layout $skin
  $fontBox=New-QmSettingsChoice '字号' 'fontSize' $script:QM_FONT_NAMES $script:CFG.fontSize $skin;$fontBox.Margin=[Windows.Thickness]::new(10,0,0,0)
  [Windows.Controls.Grid]::SetColumn($fontBox,1);[void]$lookGrid.Children.Add($layoutBox);[void]$lookGrid.Children.Add($fontBox);[void]$look.Children.Add($lookGrid)
  $skins=[ordered]@{};for($i=0;$i -lt $script:QM_SKIN_IDS.Count;$i++){$skins[$script:QM_SKIN_IDS[$i]]=$script:QM_SKIN_NAMES[$i]}
  $skinBox=New-QmSettingsChoice '外观' 'skin' $skins $script:CFG.skin $skin;$skinBox.Margin=[Windows.Thickness]::new(0,10,0,0);[void]$look.Children.Add($skinBox)
  Add-QmSettingsCheck $look '底部空间不足时收起，悬停展开' 'bottomAutoHide' $script:CFG.bottomAutoHide $skin
  $dragHint=New-QmText '拖动条形区域可微调水平位置，卡片顶部可自由拖动；窄窗口自动精简，悬停查看完整指标。' 9.5 $t.faint;$dragHint.TextWrapping='Wrap';$dragHint.Margin=[Windows.Thickness]::new(9,0,0,0);[void]$look.Children.Add($dragHint)
  # Display fields -----------------------------------------------------
  $fieldsBody=New-QmSettingsSection $body '状态条显示内容' $skin 'green' '卡片不受影响'
  $fields=[Windows.Controls.Primitives.UniformGrid]::new();$fields.Columns=3
  foreach($key in $script:QM_FIELD_NAMES.Keys){Add-QmSettingsCheck $fields $script:QM_FIELD_NAMES[$key] ('display.'+$key) $script:CFG.display[$key] $skin 'chip'}
  [void]$fieldsBody.Children.Add($fields)
  # Sessions -----------------------------------------------------------
  $session=New-QmSettingsSection $body '会话与启动' $skin 'gray'
  Add-QmSettingsCheck $session '自动跟随当前打开的会话' 'follow' (!$script:CFG.pinned) $skin
  $pinBox=New-QmSettingsChoice '固定会话' 'pinned' ([ordered]@{}) '' $skin;$pinBox.Margin=[Windows.Thickness]::new(0,8,0,0);[void]$session.Children.Add($pinBox)
  $rule=[Windows.Controls.Border]::new();$rule.Height=1;$rule.Background=Get-QmBrush $t.divider;$rule.Margin=[Windows.Thickness]::new(0,10,0,4);[void]$session.Children.Add($rule)
  Add-QmSettingsCheck $session '随 Qoder 自动启动' 'autostart' (Get-QmAutoStart) $skin
  Add-QmSettingsCheck $session 'Qoder 退出时关闭' 'closeWithQoder' $script:CFG.closeWithQoder $skin
  Sync-QmSettingsPinned
  $privacy=New-QmText '读取本机 Qoder 登录态，不保存密码；令牌只用于官方接口认证。领取记录保存在本机，最多 400 条。' 9.5 $t.faint
  $privacy.TextWrapping='Wrap';$privacy.Margin=[Windows.Thickness]::new(3,0,4,4);[void]$body.Children.Add($privacy)
  $w.Add_Closing({param($sender,$eventArgs) if(!$script:QM_SHUTDOWN -and $sender.Tag -ne 'dispose'){$eventArgs.Cancel=$true;$sender.Hide()}})
  return $w
 }finally{$script:QM_SETTINGS_BUILDING=$building}
}
function Show-QmSettings {
 if(!$script:UI.settings){$script:UI.settings=New-QmSettingsWindow}
 Sync-QmSettings
 $script:UI.settings.Show();[void]$script:UI.settings.Activate()
}
function Sync-QmSettings {
 if(!$script:QM_SETTINGS_CONTROLS){return}
 $building=$script:QM_SETTINGS_BUILDING;$script:QM_SETTINGS_BUILDING=$true
 try{
  $window=$script:UI.settings
  if($window -and $window.Resources['QmResolvedSkin'] -ne (Resolve-QmSkin $script:CFG.skin)){
   $visible=$window.IsVisible;$active=$window.IsActive;$showActivated=$window.ShowActivated
   $offset=$script:QM_SETTINGS_CONTROLS['scroll'].VerticalOffset
   $replacement=New-QmSettingsWindow
   $replacement.Width=$window.Width;$replacement.Height=$window.Height
   $left=$window.Left;$top=$window.Top
   if($window.WindowState -ne 'Normal' -and !$window.RestoreBounds.IsEmpty){
    $left=$window.RestoreBounds.Left;$top=$window.RestoreBounds.Top
    $replacement.Width=$window.RestoreBounds.Width;$replacement.Height=$window.RestoreBounds.Height
   }
   $replacement.WindowStartupLocation=$window.WindowStartupLocation
   if(![double]::IsNaN($left) -and ![double]::IsNaN($top)){$replacement.WindowStartupLocation='Manual';$replacement.Left=$left;$replacement.Top=$top}
   $replacement.WindowState=$window.WindowState
   $script:QM_SETTINGS_CONTROLS['scroll'].ScrollToVerticalOffset($offset)
   $window.Tag='dispose';$window.Close();$script:UI.settings=$replacement
   # A timer refresh must not open a hidden settings window or steal foreground focus.
   if($visible){$replacement.ShowActivated=$active;$replacement.Show()}
   $replacement.ShowActivated=$showActivated
  }
  Sync-QmSettingsPinned
  foreach($key in @('layout','skin','fontSize')){
   $control=$script:QM_SETTINGS_CONTROLS[$key];if(!$control){continue}
   foreach($it in $control.Items){if($it.Tag -eq $script:CFG.$key){$control.SelectedItem=$it;break}}
  }
  foreach($key in @('follow','autostart','bottomAutoHide','closeWithQoder','creditAuto')){
   $control=$script:QM_SETTINGS_CONTROLS[$key];if(!$control){continue}
   $control.IsChecked=switch($key){'follow'{!$script:CFG.pinned};'autostart'{Get-QmAutoStart};default{[bool]$script:CFG.$key}}
  }
  foreach($key in $script:CFG.display.Keys){if($script:QM_SETTINGS_CONTROLS['display.'+$key]){$script:QM_SETTINGS_CONTROLS['display.'+$key].IsChecked=$script:CFG.display[$key]}}
  $s=Get-QmAccountStatus
  $t=$script:QM_SKINS[(Resolve-QmSkin $script:CFG.skin)]
  # Account hero: one glanceable row for identity/state, one for balance/today.
  $running=[bool]$script:ACCOUNT.Running
  $pillText='读取中';$pillInk=$t.gray;$pillTint=$t.grayTint
  if($running){$pillText='领取中';$pillInk=$t.gold;$pillTint=$t.goldTint}
  elseif($s.State -eq 'ok' -and $s.Claimable.Count -gt 0){$pillText='可领 '+$s.Claimable.Count+' 项';$pillInk=$t.gold;$pillTint=$t.goldTint}
  elseif($s.State -eq 'ok'){$pillText='已连接';$pillInk=$t.green;$pillTint=$t.greenTint}
  elseif($s.State -eq 'noauth'){$pillText='未登录';$pillInk=$t.gray;$pillTint=$t.grayTint}
  elseif($s.State -eq 'error'){$pillText='读取失败';$pillInk=$t.red;$pillTint=$t.grayTint}
  $script:QM_SETTINGS_CONTROLS['accountState'].Text=$pillText
  $script:QM_SETTINGS_CONTROLS['accountState'].Foreground=Get-QmBrush $pillInk
  $script:QM_SETTINGS_CONTROLS['accountStatePill'].Background=Get-QmBrush $pillTint
  $script:QM_SETTINGS_CONTROLS['accountName'].Text=$(if($s.Name){$s.Name}else{'Qoder 账户'})
  $plan=$script:QM_SETTINGS_CONTROLS['accountPlan']
  if($s.Plan){$script:QM_SETTINGS_CONTROLS['accountPlanText'].Text=$s.Plan;$plan.Visibility='Visible'}else{$plan.Visibility='Collapsed'}
  $script:QM_SETTINGS_CONTROLS['accountBalance'].Text=$(if($s.State -eq 'ok'){Format-QmNum $s.Balance}else{'—'})
  $script:QM_SETTINGS_CONTROLS['accountToday'].Text='+'+ (Format-QmNum $s.TodayAmount)
  $script:QM_SETTINGS_CONTROLS['accountToday'].Foreground=Get-QmBrush $(if($s.TodayAmount -gt 0){$t.green}else{$t.faint})
  $script:QM_SETTINGS_CONTROLS['accountTodaySub'].Text=$(if($s.TodayCount -gt 0){'今日已领 · '+$s.TodayCount+' 项'}else{'今日暂无领取'})
  $acctLines=New-Object System.Collections.Generic.List[string]
  if($s.State -eq 'noauth'){$acctLines.Add('未登录：'+$s.Message);$acctLines.Add('在 Qoder 客户端登录后会自动读取余额。')}
  elseif($s.State -eq 'error'){$acctLines.Add('账号读取失败：'+$s.Message)}
  elseif($s.State -eq 'ok'){
   $acctLines.Add('余额构成：'+(Format-QmBalanceDetail $s))
   foreach($p in $s.Packages){$acctLines.Add($p.Title+'：'+(Format-QmNum $p.Remaining)+' / '+(Format-QmNum $p.Total)+$(if($p.ExpiresAt){' · '+(Format-QmExpiry $p.ExpiresAt)+' 到期'}else{''}))}
   if($s.Claimable.Count -gt 0){$acctLines.Add('待领取 '+$s.Claimable.Count+' 项，可立即领取。')}else{$acctLines.Add('当前没有可领取权益。')}
  }else{$acctLines.Add('正在读取账户余额与可领权益…')}
  if($s.Message -and $s.State -notin @('noauth','error')){$acctLines.Add('状态：'+$s.Message)}
  $script:QM_SETTINGS_CONTROLS['creditStatus'].Text=$acctLines -join "`n"
  $claimBtn=$script:QM_SETTINGS_CONTROLS['claim'];$claimBtn.IsEnabled=(-not $script:ACCOUNT.Running);$claimBtn.Content=$(if($script:ACCOUNT.Running){'领取中…'}else{'立即领取全部'})
  $up=$null;if(Get-Command Get-QmUpdateStatus -ErrorAction SilentlyContinue){$up=Get-QmUpdateStatus}
  $button=$script:QM_SETTINGS_CONTROLS['update'];$button.Content='检查更新';$button.Tag=@{Command='update';Value=''};$button.IsEnabled=($up.State -ne 'checking')
  $script:QM_SETTINGS_CONTROLS['updateText'].Text=[string]$up.Text
  if($up.State -eq 'available' -and [string]$up.Url -match '^https://github\.com/chenleshu/qoder-meter/releases/tag/[^\s?#]+$'){
   $button.Content='打开 Windows 发布页';$button.Tag=@{Command='release';Value=$up.Url}
  }
 }finally{$script:QM_SETTINGS_BUILDING=$building}
}
