# Offline WinForms menu regression. Run with Windows PowerShell -NoProfile -STA -File.
$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path $PSScriptRoot -Parent
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this probe in an STA PowerShell process.'}

# Import only pure functions, never lib-data's filesystem discovery or meter's startup.
$imports=[ordered]@{
 'lib-config-layout.ps1'=@('New-QmConfig')
 'lib-data.ps1'=@('Format-QmTps','Cut-QmText')
 'lib-account.ps1'=@('Format-QmNum','Format-QmPlan','Get-QmCstNow','Get-QmCampaignDay','Get-QmClaims','Get-QmAccountStatus')
 'meter.ps1'=@('Add-QmMenu','New-QmTrayMenu')
}
foreach($file in $imports.Keys){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\'+$file)),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($file+': '+(($errors|ForEach-Object Message)-join '; '))}
 if($file -eq 'lib-data.ps1' -and -not ('QoderMeter.JsonEstimate' -as [type])){
  $compile=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and $n.Extent.Text.Contains('public static class JsonEstimate')},$true))
  if($compile.Count -ne 1){throw 'Cannot isolate the pure JsonEstimate type.'}
  . ([scriptblock]::Create($compile[0].Extent.Text))
 }
 foreach($name in $imports[$file]){
  $found=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false))
  if($found.Count -ne 1){throw ('Missing or ambiguous function: '+$name)}
  . ([scriptblock]::Create($found[0].Extent.Text))
 }
}
# Match meter startup before WinForms/GDI caches a screen DC or creates a handle.
# Otherwise a late DPI-awareness switch can mix 96-DPI fonts with a high-DPI DC.
. (Join-Path $root 'src\lib-interop.ps1')
try{if(![QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))){[void][QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-1))}}catch{}
. (Join-Path $root 'src\lib-ui.ps1') # Also imports the actual native lib-menu renderer.
function Get-QmAutoStart {return $script:fixtureAutoStart}
function Get-QmAppAppearance {return $script:fixtureAppearance}
function Get-QmSystemDark {throw 'Offline probe must not read system appearance settings.'}
# The actual Click handler remains intact. No real command, claim, window or network work runs.
$script:dispatch=New-Object 'System.Collections.Generic.List[object]'
function Invoke-QmCommand([string]$command,$value){$script:dispatch.Add([pscustomobject]@{Command=$command;Value=$value})}

function Reset-MenuFixture([string]$state='ok'){
 $script:fixtureAutoStart=$false;$script:fixtureAppearance='light'
 $script:CFG=New-QmConfig;$script:CFG.skin='paper'
 $script:longTitle=('示例会话 A&B：检查图文菜单、键盘操作与完整无障碍名称。'*5)
 $script:QM_S=@{sessionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';title=$script:longTitle;tps=132.6;inFlight=$false;recent=@(
  [pscustomobject]@{session_id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';title=$script:longTitle},
  [pscustomobject]@{session_id='11111111-2222-3333-4444-555555555555';title=''}
 )}
 # Get-QmClaims returns this cache; there is deliberately no real claims/config path.
 $script:QM_CLAIMS_PATH=$null;$script:CFG_PATH=$null
 $script:QM_CLAIMS=[pscustomobject]@{Version=1;Entries=@(
  [pscustomobject]@{campaignId='fixture-daily';day=(Get-QmCampaignDay);title='每日积分（示例）';amount=100L},
  [pscustomobject]@{campaignId='fixture-sota';day=(Get-QmCampaignDay);title='SOTA 补给包（示例）';amount=4096L}
 )}
 $script:ACCOUNT=@{
  Auth=[pscustomobject]@{Name='示例账户';Email='demo@example.invalid';Error=''}
  Usage=[pscustomobject]@{Plan='personal_professional';ExpiresAt=0L;PlanTotal=2000L;PlanRemaining=334L;AddOnTotal=3400L;AddOnRemaining=1300L;Packages=@([pscustomobject]@{Title='SOTA 算力补给包';Remaining=4096L;Total=4096L;Available=$true;ExpiresAt=0L})}
  Campaigns=@([pscustomobject]@{ClaimStatus='CLAIMABLE';ActionType='CLAIM_BENEFIT'},[pscustomobject]@{ClaimStatus='CLAIMABLE';ActionType='CLAIM_BENEFIT'})
  Running=$false;Error='';At='';UsageAt=1L;CampAt=1L;NextTry=0L;LastFail=@{};Notified=$null
 }
 switch($state){
  'noauth'{$script:ACCOUNT.Auth.Error='fixture: no login';$script:ACCOUNT.Error='fixture: no login';$script:ACCOUNT.Usage=$null}
  'error'{$script:ACCOUNT.Error='fixture: cached request failed';$script:ACCOUNT.Usage=$null}
  'loading'{$script:ACCOUNT.Usage=$null;$script:ACCOUNT.Campaigns=@()}
  'running'{$script:ACCOUNT.Running=$true}
 }
}
$script:pass=0;$script:fail=0
function Check($value,[string]$name){if($value){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
function Find-MenuItem($menu,[string]$text){
 $items=@($menu.Items|Where-Object Text -eq $text)
 if($items.Count -ne 1){throw ('Expected one menu item: '+$text)}
 return $items[0]
}
function Get-MenuEntries($menu){
 foreach($item in $menu.Items){
  if($item -is [QoderMeter.MenuEntry]){
   $item
   if($item.HasDropDownItems){Get-MenuEntries $item.DropDown}
  }
 }
}
function Get-CommandKey([string]$command,$value){
 if($command -eq 'set'){return ('set|'+$value.Key+'|'+[string]$value.Value)}
 return $command
}
function Layout-Menu($menu){
 # A hidden native handle is needed by TextRenderer/DrawToBitmap, not Show().
 $menu.AutoSize=$false;$menu.Size=$menu.GetPreferredSize([Drawing.Size]::Empty)
 $null=$menu.Handle;$menu.PerformLayout()
}
function Get-MenuBitmap($menu){
 Layout-Menu $menu
 $bitmap=[Drawing.Bitmap]::new($menu.Width,$menu.Height)
 try{$menu.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height));return $bitmap}catch{$bitmap.Dispose();throw}
}
function Get-PixelDifference($a,$b,[Drawing.Rectangle]$rect){
 $count=0
 for($y=$rect.Top;$y -lt $rect.Bottom;$y++){for($x=$rect.Left;$x -lt $rect.Right;$x++){if($a.GetPixel($x,$y).ToArgb() -ne $b.GetPixel($x,$y).ToArgb()){$count++}}}
 return $count
}
function Test-MenuGeometry($menu,[double]$scale,[string]$skin){
 Layout-Menu $menu
 $issues=New-Object 'System.Collections.Generic.List[string]'
 $previousBottom=0
 if($menu.Font.Unit -ne [Drawing.GraphicsUnit]::Pixel){$issues.Add('font must use pixels to avoid double DPI scaling')}
 foreach($item in $menu.Items){
  if($item.Bounds.Top -lt $previousBottom -or $item.Bounds.Bottom -gt $menu.ClientSize.Height){$issues.Add('clipped/overlapping row: '+$item.Text)}
  if($item.Bounds.Left -lt 0 -or $item.Bounds.Right -gt $menu.ClientSize.Width){$issues.Add('clipped icon/check/arrow columns: '+$item.Text)}
  $previousBottom=$item.Bounds.Bottom
  if($item -isnot [QoderMeter.MenuEntry]){continue}
  if([math]::Abs($item.UiScale-$scale) -gt .001){$issues.Add('item scale: '+$item.Text)}
  $preferred=$item.GetPreferredSize([Drawing.Size]::Empty)
  if($preferred.Width -lt [math]::Floor(294*$scale) -or $preferred.Width -gt [math]::Ceiling(360*$scale)){$issues.Add('unbounded preferred width: '+$item.Text)}
  $minHeight=if($item.Kind -eq 'section'){26}elseif($item.Kind -eq 'summary'){62}elseif($item.Detail){48}else{34}
  if($item.Height -lt [math]::Floor($minHeight*$scale)){$issues.Add('row height: '+$item.Text)}
  $left=if($item.Kind -eq 'section'){12}elseif($item.Kind -eq 'summary'){50}else{43}
  $right=if($item.Kind -eq 'section' -or $item.Kind -eq 'summary'){12}else{38}
  $budget=$item.Width-[math]::Round($left*$scale)-[math]::Round($right*$scale)
  if($budget -lt 180*$scale){$issues.Add('text budget <180 DIP: '+$item.Text)}
  $font=$item.Font;$owned=$null
  try{
   if($item.Kind -eq 'section'){$owned=[Drawing.Font]::new($font.FontFamily,[single]($font.Size*.86),[Drawing.FontStyle]::Regular,$font.Unit);$font=$owned}
   elseif($item.Kind -eq 'summary'){$owned=[Drawing.Font]::new($font,[Drawing.FontStyle]::Bold);$font=$owned}
   $size=[Windows.Forms.TextRenderer]::MeasureText($item.Text,$font,[Drawing.Size]::Empty,[Windows.Forms.TextFormatFlags]::NoPrefix)
   # Session labels are intentionally ellipsized; their full names must remain discoverable.
   $session=($item.Tag.Command -eq 'set' -and $item.Tag.Value.Key -eq 'pinned')
   if(!$session -and $size.Width -gt $budget){$issues.Add('title exceeds text column: '+$item.Text)}
   if($session -and (!$item.ToolTipText -or $item.AccessibleName -ne $item.ToolTipText)){$issues.Add('missing full session name')}
   $lineHeight=if($item.Detail){24*$scale}else{$item.Height}
   if($size.Height -gt $lineHeight){$issues.Add('title height exceeds text row: '+$item.Text+' measured='+$size.Height+' row='+$lineHeight+' font='+$font.Size+' '+$font.Unit)}
  }finally{if($owned){$owned.Dispose()}}
  if($item.Detail){
   $detailFont=[Drawing.Font]::new($item.Font.FontFamily,[single]($item.Font.Size*.84),[Drawing.FontStyle]::Regular,$item.Font.Unit)
   try{
    $size=[Windows.Forms.TextRenderer]::MeasureText($item.Detail,$detailFont,[Drawing.Size]::Empty,[Windows.Forms.TextFormatFlags]::NoPrefix)
    if($size.Width -gt $budget -or $size.Height -gt [math]::Ceiling(18*$scale)){$issues.Add('detail exceeds text column: '+$item.Text)}
   }finally{$detailFont.Dispose()}
  }
  if($item.HasDropDownItems){
   $child=$item.DropDown
   if(![object]::ReferenceEquals($child.Renderer,$menu.Renderer) -or !$child.Font.Equals($menu.Font) -or $child.BackColor.ToArgb() -ne $menu.BackColor.ToArgb() -or $child.ForeColor.ToArgb() -ne $menu.ForeColor.ToArgb() -or $child.Tag.Skin -ne $skin -or $child.Tag.Scale -ne $scale){$issues.Add('submenu theme inheritance: '+$item.Text)}
   Test-MenuGeometry $child $scale $skin
  }
 }
 Check ($issues.Count -eq 0) ("geometry/theme $skin scale=$scale items=$($menu.Items.Count) "+($issues -join '; '))
}

try{
 Reset-MenuFixture
 $menu=New-QmTrayMenu
 try{
  Check ($menu -is [QoderMeter.MeterMenu] -and $menu.Renderer -is [QoderMeter.MenuRenderer]) 'real native menu and renderer'
  $sections=@($menu.Items|Where-Object Kind -eq 'section')
  Check (($sections.Text -join '|') -eq '快捷与会话|外观与布局|账户与应用') 'three ordered main groups'
  Check (@($sections|Where-Object Enabled).Count -eq 0) 'group headings are disabled'
  Check ($menu.Items[0].Kind -eq 'summary' -and !$menu.Items[0].Enabled -and $menu.Items[0].Detail -match 'TPS 133.*空闲') 'disabled summary keeps TPS and session status'
  $expectedGroups=@{
   '快捷与会话'='设置…|隐藏状态条|自动跟随当前会话|选择并固定会话'
   '外观与布局'='停靠位置|字号|外观|显示内容'
   '账户与应用'='账户积分与领取|启动与退出行为|更多操作|退出 Qoder Meter'
  }
  foreach($heading in $sections){
   $names=@();for($i=$menu.Items.IndexOf($heading)+1;$i -lt $menu.Items.Count;$i++){if($menu.Items[$i].Kind -eq 'section'){break};$names+=$menu.Items[$i].Text}
   Check (($names -join '|') -eq $expectedGroups[$heading.Text]) ('main group membership: '+$heading.Text)
  }
  $layout=(Find-MenuItem $menu '停靠位置').DropDown
  Check (($layout.Items.LayoutIcon -join '|') -eq 'title|toolbar|bottom|sidebar') 'four distinct docking mini-diagrams'
  Check (@($layout.Items|Where-Object Checked).Count -eq 1 -and $layout.Items[0].Checked) 'current docking position checked'
  $skins=(Find-MenuItem $menu '外观').DropDown
  Check ($skins.Items.Count -eq 6 -and ($skins.Items.Tag.Value.Value -join '|') -eq 'auto|paper|graphite|ocean|dusk|sand') 'five themes plus auto retained'
  Check ($skins.Items[0].Swatch.IsEmpty -and !!$skins.Items[0].Glyph) 'auto theme uses an icon rather than a color swatch'
  for($i=1;$i -lt $skins.Items.Count;$i++){
   $entry=$skins.Items[$i];$expected=Convert-QmMenuColor $script:QM_SKINS[$entry.Tag.Value.Value].green
   Check (!$entry.Swatch.IsEmpty -and $entry.Swatch.ToArgb() -eq $expected.ToArgb()) ('theme swatch: '+$entry.Tag.Value.Value)
  }
  $fields=(Find-MenuItem $menu '显示内容').DropDown
  $fieldSections=@($fields.Items|Where-Object Kind -eq 'section')
  Check (($fieldSections.Text -join '|') -eq '速度与时间|用量与账户|会话与活动') 'three display-field groups'
  $fieldKeys=@('tps','turn','age','latency','token','credits','balance','credit','requests','tools','status','title')
  $fieldEntries=@($fields.Items|Where-Object {$_.Tag.Command -eq 'set'})
  Check ($fieldEntries.Count -eq 12 -and (($fieldEntries|ForEach-Object {$_.Tag.Value.Key}) -join '|') -eq (($fieldKeys|ForEach-Object {'display.'+$_}) -join '|')) 'all twelve display fields in the intended group order'
  for($i=0;$i -lt 3;$i++){Check ($fields.Items.IndexOf($fieldSections[$i]) -eq $i*5) ('four fields per group: '+$fieldSections[$i].Text)}
  Check (@($fieldEntries|Where-Object {$_.Checked -and $_.Glyph -and $_.Tag.Value.Value -eq $false}).Count -eq 12) 'field icons and checks coexist; toggle values are inverse'
  $sessions=(Find-MenuItem $menu '选择并固定会话').DropDown
  Check ($sessions.Items[0].Text.Length -le 30 -and $sessions.Items[0].Text.EndsWith('…') -and $sessions.Items[0].ToolTipText -ceq $script:longTitle -and $sessions.Items[0].AccessibleName -ceq $script:longTitle -and $sessions.Items[0].AccessibilityObject.Name -ceq $script:longTitle) 'long session is abbreviated visually, full tooltip/accessibility preserved'
  Check ($sessions.Items[1].Text -eq '未命名会话') 'unnamed session fallback'
  $account=Find-MenuItem $menu '账户积分与领取'
  Check ($account.Detail -eq '余 5,730  ·  今 +4,196' -and $account.AccessibleDescription -eq $account.Detail -and $account.DropDownItems[0].Text -eq '待领取 2 项权益') 'cached account balance and claimable summary'
  $expected=@('settings','toggleHidden','set|follow|False','set|pinned|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','set|pinned|11111111-2222-3333-4444-555555555555','claim','set|creditAuto|False','claims','usagePage','set|autostart|True','set|closeWithQoder|False','refresh','reset','settingsDir','exit')
  foreach($key in @('title','toolbar','bottom','sidebar')){$expected+='set|layout|'+$key}
  foreach($key in @('small','normal','large','xlarge')){$expected+='set|fontSize|'+$key}
  foreach($key in @('auto','paper','graphite','ocean','dusk','sand')){$expected+='set|skin|'+$key}
  foreach($key in $fieldKeys){$expected+='set|display.'+$key+'|False'}
  $actions=@(Get-MenuEntries $menu|Where-Object {$_.Tag.Command})
  $actual=@($actions|ForEach-Object {Get-CommandKey $_.Tag.Command $_.Tag.Value})
  Check ((($actual|Sort-Object) -join "`n") -ceq (($expected|Sort-Object) -join "`n")) 'all legacy operations retained with exact command payloads'
  foreach($entry in $actions){
   $before=$script:dispatch.Count;$entry.PerformClick()
   $record=if($script:dispatch.Count -gt $before){$script:dispatch[$before]}else{$null}
   Check ($script:dispatch.Count -eq $before+1 -and (Get-CommandKey $record.Command $record.Value) -ceq (Get-CommandKey $entry.Tag.Command $entry.Tag.Value)) ('PerformClick dispatch: '+$entry.Text)
  }
  $before=$script:dispatch.Count;foreach($entry in @(Get-MenuEntries $menu|Where-Object {!$_.Tag.Command})){$entry.PerformClick()}
  Check ($script:dispatch.Count -eq $before) 'headings and submenu parents do not dispatch commands'
 }finally{$menu.Dispose()}

 Reset-MenuFixture;$script:QM_S.recent=@();$script:QM_S.sessionId='';$script:QM_S.tps=0
 $menu=New-QmTrayMenu
 try{
  $sessions=(Find-MenuItem $menu '选择并固定会话').DropDown
  $before=$script:dispatch.Count;$sessions.Items[0].PerformClick()
  Check ($sessions.Items.Count -eq 1 -and $sessions.Items[0].Text -eq '暂无最近会话' -and !$sessions.Items[0].Enabled -and !$sessions.Items[0].Tag.Command -and $script:dispatch.Count -eq $before) 'empty session hint is disabled and inert'
  Check ($menu.Items[0].Detail -match '等待会话') 'empty session summary'
 }finally{$menu.Dispose()}

 Reset-MenuFixture;$script:CFG.pinned=$script:QM_S.sessionId;$script:CFG.panelHidden=$true;$script:CFG.layout='sidebar';$script:CFG.display.token=$false;$script:CFG.creditAuto=$false;$script:CFG.closeWithQoder=$false;$script:fixtureAutoStart=$true;$script:QM_S.inFlight=$true
 $menu=New-QmTrayMenu
 try{
  Check ((Find-MenuItem $menu '显示状态条').Tag.Command -eq 'toggleHidden' -and $menu.Items[0].Detail -match '生成中') 'hidden panel and generating session labels'
  $follow=Find-MenuItem $menu '自动跟随当前会话'
  Check (!$follow.Checked -and $follow.Tag.Value.Value -eq $true -and (Find-MenuItem $menu '选择并固定会话').DropDownItems[0].Checked) 'pinned session check and follow reversal'
  $fields=(Find-MenuItem $menu '显示内容').DropDown;$token=Find-MenuItem $fields 'Token'
  Check ($fields.Items[0].Text -eq '卡片固定显示全部指标' -and !$fields.Items[0].Enabled -and $fields.Items[0].Detail -match '仅作用于条形布局') 'sidebar display switches explain their bar-only scope'
  Check (!$token.Checked -and $token.Tag.Value.Value -eq $true) 'disabled display field toggles back on'
  foreach($key in @('creditAuto','closeWithQoder','autostart')){
   $entry=@(Get-MenuEntries $menu|Where-Object {$_.Tag.Command -eq 'set' -and $_.Tag.Value.Key -eq $key})[0]
   $wantChecked=($key -eq 'autostart')
   Check ($entry.Checked -eq $wantChecked -and $entry.Tag.Value.Value -eq !$wantChecked) ('reverse toggle payload: '+$key)
  }
 }finally{$menu.Dispose()}

 foreach($state in @('noauth','error','loading','running')){
  Reset-MenuFixture $state;$menu=New-QmTrayMenu
  try{
   $account=Find-MenuItem $menu '账户积分与领取';$claim=Find-MenuItem $account.DropDown '立即领取全部'
   $pattern=switch($state){'noauth'{'未登录 Qoder'};'error'{'读取失败'};'loading'{'正在读取账户'};'running'{'正在领取，请稍候'}}
   $text=if($state -eq 'running'){$account.DropDownItems[0].Text}else{$account.Detail}
   Check ($text -match $pattern -and !$account.DropDownItems[0].Enabled) ('account hint: '+$state)
   if($state -ne 'running'){Check ($account.DropDownItems[0].Detail -eq '账户信息仅使用本地缓存') ('cache-only account hint: '+$state)}
   if($state -eq 'running'){$before=$script:dispatch.Count;$claim.PerformClick();Check (!$claim.Enabled -and $script:dispatch.Count -eq $before) 'running claim is disabled and cannot dispatch again'}
  }finally{$menu.Dispose()}
 }
 Reset-MenuFixture;$script:ACCOUNT.Campaigns=@();$menu=New-QmTrayMenu
 try{Check ((Find-MenuItem $menu '账户积分与领取').DropDownItems[0].Text -eq '当前没有待领权益') 'no claimable benefits hint'}finally{$menu.Dispose()}
 foreach($appearance in @('light','dark')){
  Reset-MenuFixture;$script:CFG.skin='auto';$script:fixtureAppearance=$appearance;$menu=New-QmTrayMenu
  try{$want=if($appearance -eq 'light'){'paper'}else{'graphite'};Check ($menu.Tag.Skin -eq $want -and (Find-MenuItem $menu '外观').DropDownItems[0].Checked) ('auto theme uses fixture appearance: '+$appearance)}finally{$menu.Dispose()}
 }

 foreach($skin in @('paper','graphite','ocean','dusk','sand')){
  foreach($scale in @(.9,1,1.12,1.24,1.5,2)){
   Reset-MenuFixture;$script:CFG.skin=$skin;$menu=New-QmTrayMenu $scale
   try{Test-MenuGeometry $menu $scale $skin}finally{$menu.Dispose()}
  }
 }

 # Compare real DrawToBitmap pixels, not just metadata, for separate icon/check columns.
 Reset-MenuFixture;$menu=New-QmPopup 'paper' 1;$images=New-Object 'System.Collections.Generic.List[object]'
 try{
  $item=Add-QmMenu $menu '图标与勾选' '' $null $true 'font'
  $both=Get-MenuBitmap $menu;$images.Add($both)
  $item.Checked=$false;$iconOnly=Get-MenuBitmap $menu;$images.Add($iconOnly)
  $item.Checked=$true;$item.Glyph='';$checkOnly=Get-MenuBitmap $menu;$images.Add($checkOnly)
  $left=[Drawing.Rectangle]::new($item.Bounds.X+8,$item.Bounds.Y,30,$item.Height)
  $right=[Drawing.Rectangle]::new($item.Bounds.Right-34,$item.Bounds.Y,28,$item.Height)
  Check ((Get-PixelDifference $both $checkOnly $left) -gt 5 -and (Get-PixelDifference $both $iconOnly $left) -eq 0) 'DrawToBitmap paints glyph independently of check'
  Check ((Get-PixelDifference $both $iconOnly $right) -gt 5 -and (Get-PixelDifference $both $checkOnly $right) -eq 0) 'DrawToBitmap paints check independently of glyph'
  Check (!$menu.Visible) 'bitmap probe never shows the popup'
 }finally{foreach($image in $images){$image.Dispose()};$menu.Dispose()}
}catch{
 $script:fail++;Write-Output ('FAIL exception: '+$_.Exception.Message);Write-Output $_.ScriptStackTrace
}
Write-Output "PASS=$script:pass FAIL=$script:fail"
if($script:fail){exit 1}
