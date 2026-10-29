# Qoder Meter Windows. 本机数据只读；账户余额与权益领取内置，无需外部脚本。
param([switch]$NoTray,[string]$Pin='',[string]$Layout='',[switch]$AlwaysOn)
$ErrorActionPreference='Stop'
$script:QM_VERSION='1.4.0-win.3'
$root=Split-Path $PSScriptRoot -Parent
trap {
 try{$d=Join-Path $env:APPDATA 'QoderMeter';[void][IO.Directory]::CreateDirectory($d);[IO.File]::AppendAllText((Join-Path $d 'meter.log'),(Get-Date -Format s)+' fatal '+$_.Exception.Message+' '+$_.ScriptStackTrace+"`r`n")}catch{}
 break
}
. (Join-Path $PSScriptRoot 'lib-interop.ps1')
try{if(![QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))){[void][QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-1))}}catch{}
foreach($lib in @('lib-data.ps1','lib-ui.ps1','lib-account.ps1','lib-config-layout.ps1','lib-lifecycle.ps1','lib-settings.ps1')){. (Join-Path $PSScriptRoot $lib)}
$script:QM_MUTEX=[Threading.Mutex]::new($false,'Local\QoderMeterWin_SingleInstance')
try{$owned=$script:QM_MUTEX.WaitOne(0,$false)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(!$owned){exit 0}
$script:CFG_PATH=Join-Path $script:QM_SETTINGSD 'settings.json'
$script:CFG=Read-QmConfig
if($Pin){$script:CFG.pinned=$Pin};if($script:QM_LAYOUT_NAMES.Contains($Layout)){$script:CFG.layout=$Layout}
$script:QM_S.pinned=$script:CFG.pinned
$script:QM_AUTH=$null
$script:ACCOUNT=@{Auth=$null;Usage=$null;Campaigns=$null;Running=$false;Error='';UsageAt=0L;CampAt=0L;NextTry=0L;LastFail=@{};Notified=$null;At=''}
$script:UI=@{app=$null;win=$null;indicator=$null;settings=$null;tray=$null;sig='';skin='paper';visible=$false;dragging=$false;hoverAt=0L;tickNo=0;tick=$null;border=$null;region=$null;placement=$null;trayTip='';builds=0;manualExit=$false}
$script:QM_SHUTDOWN=$false
function Get-QmScale {return [double]$script:QM_FONT_SIZES[$script:CFG.fontSize]}
function Get-QmVisualSig {return $script:CFG.layout+'|'+(Resolve-QmSkin $script:CFG.skin)+'|'+$script:CFG.fontSize+'|'+(($script:CFG.display.Keys|ForEach-Object{"$_=$($script:CFG.display[$_])"}) -join ',')}
function Reset-QmVisual {
 $skin=Resolve-QmSkin $script:CFG.skin;$script:UI.skin=$skin
 if($script:CFG.layout -eq 'sidebar'){$el=Build-QmCard $script:CFG $skin 1}else{$el=Build-QmBar $script:CFG $skin (Get-QmScale)}
 if(!$script:UI.win){
  $w=New-QmWindow;$script:UI.win=$w;$w.Left=-8000;$w.Top=-8000
  $w.Add_MouseLeftButtonDown({param($sender,$eventArgs)
   if($eventArgs.Handled){return};if($script:CFG.layout -eq 'sidebar' -and $eventArgs.GetPosition($sender).Y -gt 64){return}
   try{$script:UI.dragging=$true;$sender.DragMove();Save-QmOffsetFromDrag}finally{$script:UI.dragging=$false}
  })
  $w.Add_MouseRightButtonUp({param($sender,$eventArgs) Show-QmContextMenu;$eventArgs.Handled=$true})
  $w.Show();Set-QmNoActivate $w;$script:UI.visible=$true
 }else{$script:UI.win.Content=$null}
 $tip=[Windows.Controls.ToolTip]::new();$tip.MaxWidth=540;$tip.Content='等待 Qoder 会话';$el.ToolTip=$tip
 [Windows.Controls.ToolTipService]::SetInitialShowDelay($el,500);[Windows.Controls.ToolTipService]::SetShowDuration($el,60000)
 $script:UI.win.Content=$el;$script:UI.border=$el;$script:UI.sig=Get-QmVisualSig;$script:UI.builds++
}
function Set-QmTextValue($obj,[string]$text){if($obj -and $obj.Text -ne $text){$obj.Text=$text}}
function Update-QmView {
 $s=$script:QM_S;$t=$script:QM_SKINS[$script:UI.skin];$now=QmNowMs
 $active=$s.lastEventAt -and ($now-$s.lastEventAt -lt 20000)
 $state=if($s.inFlight){'生成中 '+(Format-QmElapsed $s.inFlightElapsed)}elseif($active){'本轮中'}elseif($s.sessionId){'空闲'}else{'等待会话'}
 $color=if($s.inFlight){$t.green}elseif($active){$t.gold}else{$t.gray};$tint=if($s.inFlight){$t.greenTint}elseif($active){$t.goldTint}else{$t.grayTint}
 if($s.turnStartedAt -and ($s.inFlight -or $active)){$s.turnWall=[math]::Max(0,($now-$s.turnStartedAt)/1000.0)}
 $age=if($s.sessionStartedAt){Format-QmDuration ([math]::Max(0,($now-$s.sessionStartedAt)/1000.0))}else{'—'}
 $out=if($s.exactOut -gt 0){Format-QmK $s.exactOut}elseif($s.estOut -gt 0){'≈'+(Format-QmK $s.estOut)}else{'—'}
 $turn=if($s.turnWall){Format-QmDuration $s.turnWall}else{'—'}
 $latency=if($s.lastLatency){Format-QmElapsed $s.lastLatency}else{'—'}
 $acct=Get-QmAccountStatus
 $bal=if($acct.State -eq 'ok'){if($acct.Balance -gt 0){Format-QmK $acct.Balance}else{'0'}}else{'—'}
 $values=@{turn=$turn;age=$age;token=$out;balance=$bal;credits=(Format-QmCredits $s.credits);requests=(Format-QmCount $s.requestCount);tools=(Format-QmCount $s.toolCount);latency=$latency}
 Set-QmTextValue $script:UI_TITLE $(if($s.sessionId){$s.title}else{'等待 Qoder 会话'})
 Set-QmTextValue $script:UI_TPS (Format-QmTps $s.tps)
 if($script:UI_TPS){$script:UI_TPS.Foreground=Get-QmBrush $(if($s.inFlight){$t.green}elseif($s.tps){$t.greenDim}else{$t.faint})}
 foreach($k in $values.Keys){Set-QmTextValue $script:UI_SEGS[$k] $values[$k]}
 Set-QmTextValue $script:UI_STATUS $state
 if($script:UI_STATE_PILL){$script:UI_STATE_PILL.Background=Get-QmBrush $tint;$script:UI_STATUS.Foreground=Get-QmBrush $color}
 if($script:UI_DOT){$script:UI_DOT.Fill=Get-QmBrush $color};if($script:UI_HALO){$script:UI_HALO.Background=Get-QmBrush $tint}
 Set-QmTextValue $script:UI_FOOT ('延迟 '+$latency+' · '+$s.requestCount+' 请求 · '+$s.toolCount+' 工具')
 $pill=Format-QmAccountPill;$claim=$pill.Text
 $cc=switch($pill.Tone){'green'{$t.green};'gold'{$t.gold};'red'{$t.red};default{$t.gray}}
 Set-QmTextValue $script:UI_CREDIT $claim
 if($script:UI_CREDIT){$script:UI_CREDIT.Foreground=Get-QmBrush $cc}
 if($script:UI_SPARK){
  $hist=@($s.tpsHistory|Select-Object -Last 14);$max=80.0;foreach($v in $hist){$max=[math]::Max($max,[double]$v)};$max=[math]::Min(300,$max)
  for($i=0;$i -lt 14;$i++){$rect=$script:UI_SPARK_RECTS[$i];$j=$i-(14-$hist.Count);$v=if($j -ge 0){[double]$hist[$j]}else{0};$rect.Height=if($v -gt 0){[math]::Min(26,[math]::Max(3,4+$v/$max*22))}else{1};$rect.Fill=Get-QmBrush $(if($j -eq $hist.Count-1 -and $hist.Count){$t.green}elseif($v){$t.greenDim}else{$t.track})}
 }
 $exact=if($s.exactOut -gt 0){'精确 '+([long]$s.exactOut)}elseif($s.estOut -gt 0){'估算 '+([QoderMeter.JsonEstimate]::Round($s.estOut)).ToString([Globalization.CultureInfo]::InvariantCulture)}else{''}
 $tip=@(
  ('会话：'+$s.title)
  ('模型：'+$s.model+' · '+$state)
  ('本轮 TPS：'+(Format-QmTps $s.tps)+' tok/s')
  ('本轮：'+$turn+' · 模型耗时：'+(Format-QmDuration $s.turnDuration))
  ('总计：'+$age+' · '+$s.promptCount+' 轮')
  ('输出 Token：'+$out+$(if($exact){'（'+$exact+'）'}else{''})+' · 积分：'+(Format-QmCredits $s.credits))
  ('请求：'+$s.requestCount+' · 工具：'+$s.toolCount+' · 延迟：'+$latency)
  ('积分/请求：'+$(if($s.requestCount -gt 0){Format-QmCredits ($s.credits/$s.requestCount)}else{'—'}))
 )
 if($acct.State -eq 'ok'){
  $tip+=('账户：'+$(if($acct.Name){$acct.Name+' · '}else{''})+$acct.Plan+$(if($acct.PlanExpiresAt){'（'+(Format-QmExpiry $acct.PlanExpiresAt)+' 到期）'}else{''}))
  $tip+=('积分余额：'+(Format-QmNum $acct.Balance)+'（'+(Format-QmBalanceDetail $acct)+'）')
  foreach($p in $acct.Packages){$tip+=('活动积分：'+$p.Title+' '+(Format-QmNum $p.Remaining)+'/'+(Format-QmNum $p.Total)+$(if($p.ExpiresAt){' · '+(Format-QmExpiry $p.ExpiresAt)+' 到期'}else{''}))}
 }elseif($acct.State -eq 'noauth'){$tip+='账户：未登录 Qoder'}
 elseif($acct.State -eq 'error'){$tip+='账户：读取失败'}
 else{$tip+='账户：正在读取…'}
 if($acct.TodayCount -gt 0){$tip+=('今日领取：+'+(Format-QmNum $acct.TodayAmount)+' · '+$acct.TodayCount+' 项')}else{$tip+='今日领取：+0'}
 foreach($e in @($acct.TodayItems|Select-Object -Last 3)){$tip+=('  · '+$e.title+' +'+(Format-QmNum ([long]$e.amount)))}
 if($acct.Claimable.Count -gt 0){$tip+=('待领取：'+$acct.Claimable.Count+' 项')}
 if($acct.Message){$tip+=('账户状态：'+$acct.Message)}
 $tip+='≈ 表示按字符估算；本会话积分来自本地账单，余额来自 Qoder 账号。'
 if($s.error){$tip+=('诊断：'+$s.error)}
 $script:UI.border.ToolTip.Content=$tip -join "`n"
}
function Save-QmOffsetFromDrag {
 $r=$script:UI.region;$p=$script:UI.placement;if(!$r -or !$p){return}
 $actual=[QoderMeter.Native]::DwmFrame((Get-QmHwnd $script:UI.win))
 $dx=($actual.Left-$p.BaseX)/$r.K;$dy=if($script:CFG.layout -eq 'sidebar'){($actual.Top-$p.BaseY)/$r.K}else{0}
 $script:CFG.positions[$script:CFG.layout]=@($dx,$dy);Save-QmConfig
}
function Get-QmIndicator {
 if(!$script:UI.indicator){
  $w=New-QmWindow;$w.Title='Qoder Meter 悬停展开';$line=[Windows.Controls.Border]::new();$line.Width=160;$line.Height=4;$line.CornerRadius=[Windows.CornerRadius]::new(2);$line.Background=Get-QmBrush $script:QM_SKINS[$script:UI.skin].greenDim;$w.Content=$line;$w.Left=-8000;$w.Top=-8000;$w.Show();Set-QmNoActivate $w;$w.Hide();$script:UI.indicator=$w
 }
 return $script:UI.indicator
}
function Update-QmPlacement {
 if($script:UI.dragging){return}
 $q=Get-QoderWindowInfo;$fg=Test-QoderForeground
 $want=$q -and ($AlwaysOn -or $fg -eq $q.Pid -or $fg -eq $PID) -and !$script:CFG.paused -and !$script:CFG.panelHidden
 if(!$want){$script:UI.win.Hide();if($script:UI.indicator){$script:UI.indicator.Hide()};$script:UI.visible=$false;return}
 $region=Get-QmDockRegion $q $script:CFG.layout;$script:UI.region=$region;$k=Get-QmWindowScale $script:UI.win
 if($script:CFG.layout -ne 'sidebar'){
  $available=$region.W/$k
  if($available -lt 40){$script:UI.win.Hide();if($script:UI.indicator){$script:UI.indicator.Hide()};$script:UI.visible=$false;return}
  Set-QmBarWidth $available;$script:UI_BAR.Height=[math]::Min(30*(Get-QmScale),$region.H/$k)
 }
 $script:UI.win.UpdateLayout();$ww=$script:UI.win.ActualWidth*$k;$hh=$script:UI.win.ActualHeight*$k
 $p=Get-QmDockPlacement $region $ww $hh $script:CFG.positions[$script:CFG.layout]
 if($script:CFG.layout -eq 'sidebar'){$p.X=[math]::Max($q.WorkL+4,[math]::Min($q.WorkR-$ww-4,$p.X));$p.Y=[math]::Max($q.WorkT+4,[math]::Min($q.WorkB-$hh-4,$p.Y))}
 $collapse=$script:CFG.layout -ne 'sidebar' -and (($region.W/$k -lt 285*(Get-QmScale)) -or ($q.Fullscreen -and $script:CFG.layout -eq 'title') -or ($script:CFG.layout -eq 'bottom' -and $script:CFG.bottomAutoHide -and $region.W/$k -lt 420*(Get-QmScale)))
 if($collapse){
  $pt=[QoderMeter.Native+POINT]::new();[void][QoderMeter.Native]::GetCursorPos([ref]$pt)
  $near=$pt.X -ge $region.X-12 -and $pt.X -le $region.Right+12 -and $pt.Y -ge $region.Y-6 -and $pt.Y -le $region.Bottom+6
  $rect=[QoderMeter.Native]::DwmFrame((Get-QmHwnd $script:UI.win))
  $over=$script:UI.win.IsVisible -and $pt.X -ge $rect.Left-8 -and $pt.X -le $rect.Right+8 -and $pt.Y -ge $rect.Top-8 -and $pt.Y -le $rect.Bottom+8
  if($near -or $over){$script:UI.hoverAt=QmNowMs}
  if((QmNowMs)-$script:UI.hoverAt -gt 1500){
   $line=Get-QmIndicator;$line.Content.Width=[math]::Min(160,$region.W/$k);$line.Show();Set-QmNoActivate $line
   Set-QmWindowPos $line ([int]($region.X+($region.W-$line.Content.Width*$k)/2)) ([int]($region.Bottom-4*$k))
   $script:UI.win.Hide();$script:UI.visible=$false;return
  }
  Set-QmBarWidth ([math]::Min(700,$available));$script:UI.win.UpdateLayout();$ww=$script:UI.win.ActualWidth*$k;$hh=$script:UI.win.ActualHeight*$k
  $p.X=[math]::Max($q.WorkL+8,[math]::Min($q.WorkR-$ww-8,$region.X));$p.Y=if($script:CFG.layout -eq 'bottom'){$region.Y-$hh-5*$k}else{$region.Bottom+5*$k}
 }
 if($script:UI.indicator){$script:UI.indicator.Hide()}
 $script:UI.placement=$p
 if(!$script:UI.win.IsVisible){$script:UI.win.Show();Set-QmNoActivate $script:UI.win}
 Set-QmWindowPos $script:UI.win $p.X $p.Y;$script:UI.visible=$true
}
function Show-QmBalloon([string]$title,[string]$text='') {if(!$text){$text=$title;$title='Qoder Meter'};if($script:UI.tray){$script:UI.tray.ShowBalloonTip(3500,$title,$text,[Windows.Forms.ToolTipIcon]::Info)}}
function Invoke-QmCommand([string]$command,$value){
 try{
  switch($command){
   'settings'{Show-QmSettings;return}
   'done'{if($script:UI.settings){$script:UI.settings.Hide()};return}
   'set'{
    $key=[string]$value.Key;$v=$value.Value
    if($key.StartsWith('display.')){$script:CFG.display[$key.Substring(8)]=[bool]$v}
    elseif($key -eq 'autostart'){Set-QmAutoStart ([bool]$v)}
    elseif($key -eq 'follow'){$script:CFG.pinned=if($v){''}else{[string]$script:QM_S.sessionId};$script:QM_S.pinned=$script:CFG.pinned}
    else{$script:CFG.$key=$v;if($key -eq 'pinned'){$script:QM_S.pinned=$v}}
    Save-QmConfig
   }
   'toggleHidden'{$script:CFG.panelHidden=!$script:CFG.panelHidden;$script:CFG.paused=$false;Save-QmConfig}
   'reset'{$script:CFG.positions[$script:CFG.layout]=@(0,0);Save-QmConfig}
   'refresh'{Refresh-QmData}
   'claim'{$r=Invoke-QmAccountClaim;if(!$r.Claimed.Count -and $r.Message){Show-QmBalloon '账户权益' $r.Message}}
   'claims'{Show-QmClaimHistory;return}
   'usagePage'{Start-Process 'https://qoder.com/account/usage';return}
   'settingsDir'{Start-Process explorer.exe -ArgumentList ('"'+$script:QM_SETTINGSD+'"');return}
   'update'{[void](Start-QmUpdateCheck);Sync-QmSettings;return}
   'release'{
    $up=Get-QmUpdateStatus
    if($up.State -eq 'available' -and [string]$value -ceq [string]$up.Url -and [string]$value -match '^https://github\.com/chenleshu/qoder-meter/releases/tag/[^\s?#]+$'){Start-Process -FilePath ([string]$value)}
    return
   }
   'exit'{$script:UI.manualExit=$true;Set-QmManualExit;$script:QM_SHUTDOWN=$true;$script:UI.app.Shutdown();return}
  }
  if((Get-QmVisualSig) -ne $script:UI.sig -and !$script:UI.dragging){Reset-QmVisual}
  Update-QmView;Update-QmPlacement;Sync-QmSettings
 }catch{Write-QmLog ('command '+$command+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Show-QmBalloon '操作未完成' $_.Exception.Message}
}
function Add-QmMenu($parent,$text,$command,$value,$checked=$false,[string]$icon='', [string]$detail='', [string]$tone=''){
 if($parent -is [Windows.Forms.ContextMenuStrip]){$menu=$parent}else{
  $menu=$parent.DropDown
  $menu.Renderer=$parent.Owner.Renderer;$menu.Font=$parent.Owner.Font;$menu.BackColor=$parent.Owner.BackColor;$menu.ForeColor=$parent.Owner.ForeColor
  $menu.ShowImageMargin=$false;$menu.ShowCheckMargin=$false;$menu.Padding=[Windows.Forms.Padding]::new(5);$menu.Tag=$parent.Owner.Tag
 }
 $mi=[QoderMeter.MenuEntry]::new($text);$mi.Checked=$checked;$mi.Tag=@{Command=$command;Value=$value};$mi.UiScale=$menu.Tag.Scale
 Set-QmMenuEntryStyle $mi $icon $detail $tone
 if($command){$mi.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})}
 [void]$menu.Items.Add($mi)
 # ToolStripDropDownMenu otherwise computes its width from stock text margins,
 # ignoring the custom icon, check and arrow columns drawn by our renderer.
 $width=$mi.GetPreferredSize([Drawing.Size]::Empty).Width+$menu.Padding.Horizontal+2
 $menu.MinimumSize=[Drawing.Size]::new([math]::Max($menu.MinimumSize.Width,$width),0)
 return $mi
}
function New-QmTrayMenu([double]$scale=1) {
 $skin=Resolve-QmSkin $script:CFG.skin;$m=New-QmPopup $skin $scale
 $status=if($script:QM_S.inFlight){'生成中'}elseif($script:QM_S.sessionId){'空闲'}else{'等待会话'}
 $summary='TPS '+(Format-QmTps $script:QM_S.tps)+'  ·  '+$status
 [void](Add-QmMenuHeading $m 'Qoder Meter' $summary)
 [void](Add-QmMenuHeading $m '快捷与会话')
 [void](Add-QmMenu $m '设置…' 'settings' $null $false 'settings')
 [void](Add-QmMenu $m $(if($script:CFG.panelHidden){'显示状态条'}else{'隐藏状态条'}) 'toggleHidden' $null $false $(if($script:CFG.panelHidden){'show'}else{'hide'}))
 [void](Add-QmMenu $m '自动跟随当前会话' 'set' @{Key='follow';Value=[bool]$script:CFG.pinned} (!$script:CFG.pinned) 'follow')
 $sessions=Add-QmMenu $m '选择并固定会话' '' $null $false 'session'
 $recent=@($script:QM_S.recent|Where-Object {$_.session_id})
 if($recent.Count){
  foreach($r in $recent){$name=if($r.title){[string]$r.title}else{'未命名会话'};$item=Add-QmMenu $sessions (Cut-QmText $name 30) 'set' @{Key='pinned';Value=[string]$r.session_id} ($r.session_id -eq $script:CFG.pinned) 'session';$item.ToolTipText=$name;$item.AccessibleName=$name}
 }else{$empty=Add-QmMenu $sessions '暂无最近会话' '' $null $false 'session';$empty.Enabled=$false}
 [void](Add-QmMenuHeading $m '外观与布局')
 $sub=Add-QmMenu $m '停靠位置' '' $null $false 'layout'
 foreach($k in $script:QM_LAYOUT_NAMES.Keys){$item=Add-QmMenu $sub $script:QM_LAYOUT_NAMES[$k] 'set' @{Key='layout';Value=$k} ($script:CFG.layout -eq $k);$item.LayoutIcon=$k}
 $sub=Add-QmMenu $m '字号' '' $null $false 'font'
 foreach($k in $script:QM_FONT_NAMES.Keys){[void](Add-QmMenu $sub $script:QM_FONT_NAMES[$k] 'set' @{Key='fontSize';Value=$k} ($script:CFG.fontSize -eq $k) 'font')}
 $sub=Add-QmMenu $m '外观' '' $null $false 'palette'
 for($i=0;$i -lt $script:QM_SKIN_IDS.Count;$i++){
  $key=$script:QM_SKIN_IDS[$i];$item=Add-QmMenu $sub $script:QM_SKIN_NAMES[$i] 'set' @{Key='skin';Value=$key} ($script:CFG.skin -eq $key) 'auto'
  if($key -ne 'auto'){$item.Swatch=Convert-QmMenuColor $script:QM_SKINS[$key].green}
 }
 $sub=Add-QmMenu $m '显示内容' '' $null $false 'fields'
 $fieldGroups=@(
  @{Title='速度与时间';Keys=@('tps','turn','age','latency');Icons=@('speed','clock','clock','clock')},
  @{Title='用量与账户';Keys=@('token','credits','balance','credit');Icons=@('token','credit','account','gift')},
  @{Title='会话与活动';Keys=@('requests','tools','status','title');Icons=@('session','tools','status','session')}
 )
 if($script:CFG.layout -eq 'sidebar'){[void](Add-QmMenuHeading $sub '卡片固定显示全部指标' '以下开关仅作用于条形布局')}
 foreach($group in $fieldGroups){[void](Add-QmMenuHeading $sub $group.Title);for($i=0;$i -lt $group.Keys.Count;$i++){$k=$group.Keys[$i];[void](Add-QmMenu $sub $script:QM_FIELD_NAMES[$k] 'set' @{Key=('display.'+$k);Value=(!$script:CFG.display[$k])} $script:CFG.display[$k] $group.Icons[$i])}}
 [void](Add-QmMenuHeading $m '账户与应用')
 $acct=Get-QmAccountStatus
 $detail=switch($acct.State){'ok'{'余 '+(Format-QmNum $acct.Balance)+'  ·  今 +'+(Format-QmNum $acct.TodayAmount)};'noauth'{'未登录 Qoder'};'error'{'账户读取失败，请稍后重试'};default{'正在读取账户…'}}
 $sub=Add-QmMenu $m '账户积分与领取' '' $null $false 'account' $detail
 $stateText=if($script:ACCOUNT.Running){'正在领取，请稍候'}elseif($acct.Claimable.Count){'待领取 '+$acct.Claimable.Count+' 项权益'}elseif($acct.State -eq 'ok'){'当前没有待领权益'}else{$detail}
 [void](Add-QmMenuHeading $sub $stateText $(if($acct.State -eq 'ok'){$detail}else{'账户信息仅使用本地缓存'}))
 $claim=Add-QmMenu $sub '立即领取全部' 'claim' $null $false 'gift' '' 'green';$claim.Enabled=(-not $script:ACCOUNT.Running)
 [void](Add-QmMenu $sub '自动领取全部权益' 'set' @{Key='creditAuto';Value=(!$script:CFG.creditAuto)} $script:CFG.creditAuto 'auto')
 [void]$sub.DropDownItems.Add([Windows.Forms.ToolStripSeparator]::new())
 [void](Add-QmMenu $sub '领取记录' 'claims' $null $false 'history')
 [void](Add-QmMenu $sub '打开 Qoder 用量页' 'usagePage' $null $false 'link')
 $sub=Add-QmMenu $m '启动与退出行为' '' $null $false 'power'
 $autoStart=Get-QmAutoStart
 [void](Add-QmMenu $sub '随 Qoder 自动启动' 'set' @{Key='autostart';Value=(!$autoStart)} $autoStart 'power')
 [void](Add-QmMenu $sub 'Qoder 退出时关闭' 'set' @{Key='closeWithQoder';Value=(!$script:CFG.closeWithQoder)} $script:CFG.closeWithQoder 'exit')
 $sub=Add-QmMenu $m '更多操作' '' $null $false 'more'
 [void](Add-QmMenu $sub '立即刷新' 'refresh' $null $false 'refresh')
 [void](Add-QmMenu $sub '重置当前位置' 'reset' $null $false 'reset')
 [void](Add-QmMenu $sub '打开设置目录' 'settingsDir' $null $false 'folder')
 [void](Add-QmMenu $m '退出 Qoder Meter' 'exit' $null $false 'exit' '' 'red')
 return $m
}
function Show-QmContextMenu {
 if($script:QM_MENU){$script:QM_MENU.Dispose()}
 $point=[Windows.Forms.Cursor]::Position
 $scale=[QoderMeter.MenuDisplay]::ScaleAt($point)
 $script:QM_MENU=New-QmTrayMenu $scale;$script:QM_MENU.Show($point)
}
function Install-QmTray {
 $bmp=[Drawing.Bitmap]::new(20,20);$g=[Drawing.Graphics]::FromImage($bmp);$g.SmoothingMode='AntiAlias';$g.Clear([Drawing.Color]::Transparent)
 $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(8,148,102));$g.FillEllipse($brush,2,2,16,16);$g.FillEllipse([Drawing.Brushes]::White,7,7,6,6);$g.Dispose();$brush.Dispose()
 $handle=$bmp.GetHicon();$icon=[Drawing.Icon]::FromHandle($handle).Clone();[void][QoderMeter.Native]::DestroyIcon($handle);$bmp.Dispose()
 $tray=[Windows.Forms.NotifyIcon]::new();$tray.Icon=$icon;$tray.Text='Qoder Meter';$tray.Visible=$true
 $tray.Add_MouseClick({param($sender,$eventArgs) if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left){Show-QmSettings}else{Show-QmContextMenu}})
 $script:UI.tray=$tray
}
try{
 Register-QmInstance $PSCommandPath
 Save-QmConfig
 if(Get-QmAutoStart){Start-QmWatch}
 $script:UI.app=[Windows.Application]::new();$script:UI.app.ShutdownMode='OnExplicitShutdown'
 Refresh-QmData;Reset-QmVisual;Update-QmPlacement
 if(!$NoTray){Install-QmTray}
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(300);$script:UI.tick=$timer
 $timer.Add_Tick({
  try{
   $script:UI.tickNo++
   if($script:UI.tickNo % 6 -eq 1){Refresh-QmData;Update-QmAccountState;Sync-QmSettings}
   if(!$script:UI.dragging -and (Get-QmVisualSig) -ne $script:UI.sig){Reset-QmVisual}
   Update-QmView;Update-QmPlacement
   if($script:UI.tickNo % 10 -eq 0 -and $script:CFG.closeWithQoder){
    if(!(Get-Process -Name Qoder,QoderCN -ErrorAction SilentlyContinue)){$script:QM_SHUTDOWN=$true;$script:UI.app.Shutdown()}
   }
   if($script:UI.tray){$text='Qoder Meter · TPS '+(Format-QmTps $script:QM_S.tps);if($text -ne $script:UI.trayTip){$script:UI.tray.Text=$text;$script:UI.trayTip=$text}}
  }catch{Write-QmLog ('tick: '+$_.Exception.Message+' '+$_.ScriptStackTrace)}
 })
 $timer.Start();Write-QmLog ('启动 '+$script:QM_VERSION+' pid='+$PID+' layout='+$script:CFG.layout);[void]$script:UI.app.Run()
}finally{
 $script:QM_SHUTDOWN=$true
 if($script:UI.tick){$script:UI.tick.Stop()};if($script:UI.tray){$script:UI.tray.Visible=$false;$script:UI.tray.Icon.Dispose();$script:UI.tray.Dispose()}
 if($script:QM_MENU){$script:QM_MENU.Dispose()};Close-QmDb;Unregister-QmInstance
 try{$script:QM_MUTEX.ReleaseMutex();$script:QM_MUTEX.Dispose()}catch{}
}
