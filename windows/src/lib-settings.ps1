# Single reusable settings window. All changes use the same command router as tray items.
function New-QmSettingsButton($text,$command,$value=''){
 $b=[Windows.Controls.Button]::new();$b.Content=$text;$b.Tag=@{Command=$command;Value=$value};$b.Padding=[Windows.Thickness]::new(12,6,12,6);$b.Margin=[Windows.Thickness]::new(0,0,8,0);$b.MinHeight=30
 $b.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 return $b
}
function Add-QmSettingsHeading($parent,$title,$skin){
 $h=New-QmText $title 12 $script:QM_SKINS[$skin].text 'SemiBold';$h.Margin=[Windows.Thickness]::new(0,17,0,9);[void]$parent.Children.Add($h)
}
function Add-QmSettingsCheck($parent,$text,$key,[bool]$checked,$skin){
 $c=[Windows.Controls.CheckBox]::new();$c.Content=$text;$c.Tag=$key;$c.IsChecked=$checked;$c.FontSize=12;$c.Margin=[Windows.Thickness]::new(0,4,12,5);$c.Foreground=Get-QmBrush $script:QM_SKINS[$skin].text
 $c.Add_Click({param($sender,$eventArgs) if(!$script:QM_SETTINGS_BUILDING){Invoke-QmCommand 'set' @{Key=$sender.Tag;Value=[bool]$sender.IsChecked}}})
 $script:QM_SETTINGS_CONTROLS[$key]=$c;[void]$parent.Children.Add($c)
}
function Add-QmSettingsChoice($parent,$label,$key,$choices,$selected,$skin){
 $row=[Windows.Controls.Grid]::new();$row.Margin=[Windows.Thickness]::new(0,4,0,4)
 $a=[Windows.Controls.ColumnDefinition]::new();$a.Width=[Windows.GridLength]::new(95);[void]$row.ColumnDefinitions.Add($a);[void]$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
 [void]$row.Children.Add((New-QmText $label 12 $script:QM_SKINS[$skin].soft))
 $c=[Windows.Controls.ComboBox]::new();$c.Tag=$key;$c.MinHeight=30;$c.FontSize=12;$c.Padding=[Windows.Thickness]::new(7,4,7,4)
 foreach($k in $choices.Keys){$it=[Windows.Controls.ComboBoxItem]::new();$it.Content=$choices[$k];$it.Tag=$k;[void]$c.Items.Add($it);if($k -eq $selected){$c.SelectedItem=$it}}
 $c.Add_SelectionChanged({param($sender,$eventArgs) if(!$script:QM_SETTINGS_BUILDING -and $sender.SelectedItem){Invoke-QmCommand 'set' @{Key=$sender.Tag;Value=$sender.SelectedItem.Tag}}})
 [Windows.Controls.Grid]::SetColumn($c,1);[void]$row.Children.Add($c);[void]$parent.Children.Add($row);$script:QM_SETTINGS_CONTROLS[$key]=$c
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
  $w=[Windows.Window]::new();$w.Title='Qoder Meter 设置';$w.Width=450;$w.Height=760;$w.MinWidth=420;$w.MinHeight=540;$w.ResizeMode='CanResize';$w.ShowInTaskbar=$false;$w.WindowStartupLocation='CenterScreen';$w.Background=Get-QmBrush $t.bg;$w.Foreground=Get-QmBrush $t.text
  $w.Resources[[Windows.SystemColors]::WindowBrushKey]=Get-QmBrush $t.bg;$w.Resources[[Windows.SystemColors]::WindowTextBrushKey]=Get-QmBrush $t.text
  $w.Resources['QmResolvedSkin']=$skin
  $outer=[Windows.Controls.DockPanel]::new();$outer.Margin=[Windows.Thickness]::new(22)
  $footer=New-QmPanel $true;$footer.Margin=[Windows.Thickness]::new(0,16,0,0);[Windows.Controls.DockPanel]::SetDock($footer,'Bottom')
  [void]$footer.Children.Add((New-QmSettingsButton '重置当前位置' 'reset'))
  $done=New-QmSettingsButton '完成' 'done';$done.IsDefault=$true;$done.IsCancel=$true;[void]$footer.Children.Add($done);[void]$outer.Children.Add($footer)
  $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$script:QM_SETTINGS_CONTROLS['scroll']=$scroll
  $body=New-QmPanel $false;$body.Margin=[Windows.Thickness]::new(0,0,10,0);$scroll.Content=$body;[void]$outer.Children.Add($scroll);$w.Content=$outer
  $head=[Windows.Controls.DockPanel]::new();$up=New-QmSettingsButton '检查更新' 'update';[Windows.Controls.DockPanel]::SetDock($up,'Right');[void]$head.Children.Add($up);$script:QM_SETTINGS_CONTROLS['update']=$up
  [void]$head.Children.Add((New-QmText 'Qoder Meter' 20 $t.text 'SemiBold'));[void]$body.Children.Add($head)
  $sub=New-QmText ('Windows '+$script:QM_VERSION+' · 设置即时生效') 10.5 $t.faint;$sub.Margin=[Windows.Thickness]::new(0,6,0,0);[void]$body.Children.Add($sub)
  $upText=New-QmText '' 10 $t.soft;$upText.TextWrapping='Wrap';[void]$body.Children.Add($upText);$script:QM_SETTINGS_CONTROLS['updateText']=$upText
  Add-QmSettingsHeading $body '显示位置与外观' $skin
  Add-QmSettingsChoice $body '停靠位置' 'layout' $script:QM_LAYOUT_NAMES $script:CFG.layout $skin
  Add-QmSettingsChoice $body '字号' 'fontSize' $script:QM_FONT_NAMES $script:CFG.fontSize $skin
  $skins=[ordered]@{};for($i=0;$i -lt $script:QM_SKIN_IDS.Count;$i++){$skins[$script:QM_SKIN_IDS[$i]]=$script:QM_SKIN_NAMES[$i]}
  Add-QmSettingsChoice $body '外观' 'skin' $skins $script:CFG.skin $skin
  Add-QmSettingsCheck $body '底部空间不足时收起，悬停展开' 'bottomAutoHide' $script:CFG.bottomAutoHide $skin
  $hint=New-QmText '拖动条形区域可微调水平位置；卡片顶部可自由拖动。窄窗口自动精简，悬停查看完整指标。' 10.5 $t.faint;$hint.TextWrapping='Wrap';$hint.Margin=[Windows.Thickness]::new(0,3,0,1);[void]$body.Children.Add($hint)
  Add-QmSettingsHeading $body '状态条显示内容' $skin
  $fields=[Windows.Controls.Primitives.UniformGrid]::new();$fields.Columns=3
  foreach($key in $script:QM_FIELD_NAMES.Keys){Add-QmSettingsCheck $fields $script:QM_FIELD_NAMES[$key] ('display.'+$key) $script:CFG.display[$key] $skin};[void]$body.Children.Add($fields)
  $hint=New-QmText '完整统计卡片不受字段开关与字号影响。' 10 $t.faint;[void]$body.Children.Add($hint)
  Add-QmSettingsHeading $body '会话与启动' $skin
  Add-QmSettingsCheck $body '自动跟随当前打开的会话' 'follow' (!$script:CFG.pinned) $skin
  Add-QmSettingsChoice $body '固定会话' 'pinned' ([ordered]@{}) '' $skin
  Sync-QmSettingsPinned
  Add-QmSettingsCheck $body '随 Qoder 自动启动' 'autostart' (Get-QmAutoStart) $skin
  Add-QmSettingsCheck $body 'Qoder 退出时关闭' 'closeWithQoder' $script:CFG.closeWithQoder $skin
  Add-QmSettingsHeading $body '账户积分与权益' $skin
  Add-QmSettingsCheck $body '发现可领权益时自动领取（每日积分与活动补给包）' 'creditAuto' $script:CFG.creditAuto $skin
  $status=New-QmText '' 11 $t.soft;$status.TextWrapping='Wrap';$status.Margin=[Windows.Thickness]::new(0,4,0,9);[void]$body.Children.Add($status);$script:QM_SETTINGS_CONTROLS['creditStatus']=$status
  $actions=New-QmPanel $true;$claim=New-QmSettingsButton '立即领取全部' 'claim';[void]$actions.Children.Add($claim);$script:QM_SETTINGS_CONTROLS['claim']=$claim
  [void]$actions.Children.Add((New-QmSettingsButton '领取记录' 'claims'));[void]$actions.Children.Add((New-QmSettingsButton '打开用量页' 'usagePage'));[void]$body.Children.Add($actions)
  $hint=New-QmText '读取本机 Qoder 登录态，不保存密码；令牌仅用于官方接口认证。每天 10:00（UTC+8）换周期，余额与今日领取显示在状态条和悬停提示中。' 10 $t.faint;$hint.TextWrapping='Wrap';$hint.Margin=[Windows.Thickness]::new(0,10,0,0);[void]$body.Children.Add($hint)
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
  $acctLines=New-Object System.Collections.Generic.List[string]
  if($s.State -eq 'noauth'){$acctLines.Add('未登录：'+$s.Message)}
  elseif($s.State -eq 'error'){$acctLines.Add('账号读取失败：'+$s.Message)}
  elseif($s.State -eq 'ok'){
   $acctLines.Add('账户：'+$(if($s.Name){$s.Name+' · '}else{''})+$(if($s.Plan){$s.Plan}else{'—'})+$(if($s.PlanExpiresAt){'（'+(Format-QmExpiry $s.PlanExpiresAt)+' 到期）'}else{''}))
   $acctLines.Add('余额 '+(Format-QmNum $s.Balance)+'（'+(Format-QmBalanceDetail $s)+'）')
   foreach($p in $s.Packages){$acctLines.Add('· '+$p.Title+' '+(Format-QmNum $p.Remaining)+'/'+(Format-QmNum $p.Total)+$(if($p.ExpiresAt){' · '+(Format-QmExpiry $p.ExpiresAt)+' 到期'}else{''}))}
  }else{$acctLines.Add('正在读取账户…')}
  if($s.TodayCount -gt 0){$acctLines.Add('今日领取：+'+(Format-QmNum $s.TodayAmount)+' · '+$s.TodayCount+' 项')}else{$acctLines.Add('今日领取：+0')}
  foreach($e in @($s.TodayItems|Select-Object -Last 3)){$acctLines.Add('· '+$e.title+' +'+(Format-QmNum ([long]$e.amount)))}
  if($s.Claimable.Count -gt 0){$acctLines.Add('待领取：'+$s.Claimable.Count+' 项')}
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
