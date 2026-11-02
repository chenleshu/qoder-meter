#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run with Windows PowerShell 5.1.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with -STA.'}
Write-Output ('PowerShell '+$PSVersionTable.PSVersion+' STA')
$script:QM_SETTINGSD=Join-Path ([IO.Path]::GetTempPath()) ('qm-claims-dir-'+[guid]::NewGuid().ToString('N'))
foreach($name in @('lib-config-layout','lib-ui','lib-account')){. (Join-Path $root ('src\'+$name+'.ps1'))}
function Get-QmScale {return 1.0}
$script:CFG=New-QmConfig;$script:CFG.skin='paper'
$script:QM_CLAIMS_PATH=Join-Path $script:QM_SETTINGSD 'claims.json';$script:QM_CLAIMS=$null
$script:QM_VERSION='2.1.0';$script:QM_SHUTDOWN=$false
$script:UI=@{claimsWin=$null}
$script:ACCOUNT=$null
$script:QM_CLAIMS_MAX=400
function New-ClaimsData {
 $now=Get-QmCstNow;$today=Get-QmCampaignDay
 $yesterday=$now.AddDays(-1).AddHours(-10).ToString('yyyy-MM-dd')
 $older=$now.AddDays(-2).AddHours(-10).ToString('yyyy-MM-dd')
 $list=New-Object System.Collections.Generic.List[object]
 $list.Add([pscustomobject]@{campaignId='daily-today';campaignKey='daily';day=$today;title='每日 100 Credits';amount=100;kind='CREDITS';scope='';claimedAt=$now.AddMinutes(-9).ToString('s');expiresAt='';replayed=$false})
 $list.Add([pscustomobject]@{campaignId='sota-today';campaignKey='sota';day=$today;title='SOTA 算力补给包';amount=4096;kind='CREDITS';scope='C_S_U_SERIES';claimedAt=$now.AddMinutes(-4).ToString('s');expiresAt=$now.AddDays(1).ToString('s');replayed=$false})
 $list.Add([pscustomobject]@{campaignId='daily-yesterday';campaignKey='daily';day=$yesterday;title='每日 100 Credits';amount=100;kind='CREDITS';scope='';claimedAt=$now.AddDays(-1).AddHours(-10).ToString('s');expiresAt='';replayed=$false})
 $list.Add([pscustomobject]@{campaignId='all-older';campaignKey='all';day=$older;title='全模型试用补给包';amount=500;kind='CREDITS';scope='ALL_MODELS';claimedAt=$now.AddDays(-2).AddHours(-10).ToString('s');expiresAt='';replayed=$true})
 return [pscustomobject]@{Version=1;Entries=$list}
}
function New-AccountFixture([bool]$running=$false,[string]$errorText='',[bool]$authError=$false){
 $now=[DateTimeOffset]::new((Get-QmCstNow),[TimeSpan]::FromHours(8))
 return @{
  Auth=[pscustomobject]@{Name='示例账户';Email='demo@example.com';UserId='demo';Error=$(if($authError){$errorText}else{''})}
  Usage=[pscustomobject]@{Plan='personal_professional';ExpiresAt=$now.AddDays(20).ToUnixTimeMilliseconds();PlanTotal=2000;PlanUsed=1666;PlanRemaining=334;AddOnTotal=3400;AddOnUsed=2100;AddOnRemaining=1300
   Packages=@([pscustomobject]@{Name='act-demo';Title='SOTA 算力补给包';Description='SOTA 专属';Total=4096;Used=0;Remaining=4096;ExpiresAt=$now.AddDays(1).ToUnixTimeMilliseconds();Available=$true;Status='active'})}
  Campaigns=@([pscustomobject]@{CampaignId='new-campaign';CampaignKey='new';Title='每日 100 Credits';Amount=100;Kind='CREDITS';Scope='';ClaimStatus='CLAIMABLE';ActionType='CLAIM_BENEFIT'})
  Running=$running;Error=$errorText;UsageAt=0L;CampAt=0L;NextTry=0L;LastFail=@{};Notified=$null;At=''
 }
}
function New-ClaimsFixture([string]$skin='paper'){
 if($script:UI.claimsWin){$script:UI.claimsWin.Tag='dispose';$script:UI.claimsWin.Close()}
 $script:CFG=New-QmConfig;$script:CFG.skin=$skin
 $script:QM_CLAIMS=New-ClaimsData
 $script:ACCOUNT=New-AccountFixture
 $script:UI=@{claimsWin=$null}
 $script:UI.claimsWin=New-QmClaimHistoryWindow
}
function Get-DayLabels {
 $labels=@()
 foreach($child in $script:QM_CLAIMS_REFS.List.Children){
  if($child -is [Windows.Controls.Grid]){
   $text=$child.Children[0]
   if($text -is [Windows.Controls.TextBlock]){$labels+=$text.Text}
  }
 }
 return $labels
}
try{
 New-ClaimsFixture 'paper'
 $window=$script:UI.claimsWin
 Check ($window.Title -eq 'Qoder Meter 领取记录' -and $window.Width -eq 500 -and $window.Height -eq 620) 'claim window keeps the 500x620 document size'
 Check ($window.MinWidth -eq 430 -and $window.MinHeight -eq 420 -and $window.ResizeMode -eq 'CanResize' -and !$window.ShowInTaskbar) 'claim window stays resizable and out of the taskbar'
 Check ($window.Resources['QmResolvedSkin'] -eq 'paper' -and $window.Resources.MergedDictionaries.Count -eq 1) 'claim window installs the shared themed resource dictionary'
 Check ($window.Background.Color -eq (Get-QmBrush $script:QM_SKINS['paper'].bg).Color) 'claim window paints the resolved skin background'
 $refs=$script:QM_CLAIMS_REFS
 Check ($refs.List.Parent -is [Windows.Controls.ScrollViewer] -and $refs.List.Parent.VerticalScrollBarVisibility -eq 'Auto') 'records live in a vertically scrollable list'
 Check ($window.Content.Children[0].Children.Count -eq 2) 'header contains the gold claim glyph and titles'

 Sync-QmClaimHistory
 Check ($refs.Name.Text -eq '示例账户' -and $refs.PlanText.Text -eq 'Pro' -and $refs.Plan.Visibility -eq 'Visible') 'summary shows the account name and plan'
 Check ($refs.Balance.Text -eq '5,730' -and $refs.Today.Text -eq '+4,196' -and $refs.TodaySub.Text -eq '今日已领 · 2 项') 'summary adds packages into the balance and today total'
 Check ($refs.State.Text -eq '可领 1 项' -and $refs.StatePill.Background.Color -eq (Get-QmBrush $script:QM_SKINS['paper'].goldTint).Color) 'claimable campaigns use the gold state pill'
 Check ($refs.Detail.Text -match '余额构成：套餐 334 · 加赠 1,300 · 活动包 4,096' -and $refs.Detail.Text -match 'SOTA 算力补给包：4,096 / 4,096') 'summary detail itemizes the balance and package expiry'
 Check ($refs.Count.Text -eq '共 4 条记录 · 累计 +4,796 · 最多保留 400 条') 'footer totals the whole local ledger'
 Check ($refs.ListNote.Text -eq '最近 4 条') 'list note counts the rendered records'
 $labels=Get-DayLabels
 $older=(Get-QmCstNow).AddDays(-2).AddHours(-10)
 Check ($labels.Count -eq 3 -and $labels[0] -eq '今天' -and $labels[1] -eq '昨天' -and $labels[2] -eq $older.ToString('MM-dd')) 'day groups render newest first'
 Check ($refs.List.Children.Count -eq 7) 'every day head and record row is rendered'
 Check (-not (Test-Path -LiteralPath $script:QM_CLAIMS_PATH)) 'opening the history writes no ledger file'
 $firstHead=$refs.List.Children[0]
 Sync-QmClaimHistory
 Check ([object]::ReferenceEquals($firstHead,$refs.List.Children[0])) 'an unchanged ledger does not rebuild row controls'
 $script:QM_CLAIMS.Entries.Add([pscustomobject]@{campaignId='extra-today';campaignKey='extra';day=(Get-QmCampaignDay);title='限时补给包';amount=100;kind='CREDITS';scope='';claimedAt=(Get-QmCstNow).AddMinutes(-1).ToString('s');expiresAt='';replayed=$false})
 Sync-QmClaimHistory
 Check ($refs.List.Children.Count -eq 8 -and $refs.ListNote.Text -eq '最近 5 条') 'a new claim while the window is open adds its row'
 Check ($refs.Today.Text -eq '+4,296' -and $refs.Count.Text -eq '共 5 条记录 · 累计 +4,896 · 最多保留 400 条') 'a live claim updates today and lifetime totals'

 $script:ACCOUNT=New-AccountFixture $true
 Sync-QmClaimHistory
 Check ($refs.State.Text -eq '领取中' -and $refs.StatePill.Background.Color -eq (Get-QmBrush $script:QM_SKINS['paper'].goldTint).Color) 'an in-flight claim switches the pill to the running state'

 $script:ACCOUNT=New-AccountFixture $false '登录已过期' $true
 Sync-QmClaimHistory
 Check ($refs.State.Text -eq '未登录' -and $refs.Balance.Text -eq '—') 'a missing login hides the balance and explains the state'
 Check ($refs.Detail.Text -match '在 Qoder 客户端登录后自动读取余额与权益') 'unauthenticated detail explains how to reconnect'

 $script:ACCOUNT=New-AccountFixture $false '网络错误' $false
 Sync-QmClaimHistory
 Check ($refs.State.Text -eq '读取失败' -and $refs.Detail.Text -match '网络错误') 'a read failure surfaces the error instead of a stale balance'

 $script:ACCOUNT=New-AccountFixture
 $script:QM_CLAIMS=[pscustomobject]@{Version=1;Entries=(New-Object System.Collections.Generic.List[object])}
 Sync-QmClaimHistory
 Check ($refs.List.Children.Count -eq 1 -and $refs.List.Children[0] -is [Windows.Controls.StackPanel]) 'an empty ledger renders a single empty-state block'
 Check ($refs.ListNote.Text -eq '按天分组' -and $refs.Count.Text -eq '记录保存在本机 · 最多保留 400 条') 'the empty state explains grouping and local storage'
 Check ($refs.List.Children[0].Children[1].Text -eq '暂无领取记录') 'the empty state names the missing records'
 Check ($refs.Today.Text -eq '+0' -and $refs.TodaySub.Text -eq '今日暂无领取') 'an empty ledger also clears today totals'

 New-ClaimsFixture 'graphite'
 $window=$script:UI.claimsWin
 Check ($window.Resources['QmResolvedSkin'] -eq 'graphite' -and $window.Background.Color -eq (Get-QmBrush $script:QM_SKINS['graphite'].bg).Color) 'a graphite fixture uses the graphite window palette'
 Sync-QmClaimHistory
 Check ($script:QM_CLAIMS_REFS.Balance.Foreground.Color -eq (Get-QmBrush $script:QM_SKINS['graphite'].gold).Color) 'the rebuilt summary uses graphite accent colors'
 Check ($script:QM_CLAIMS_REFS.List.Children.Count -eq 7) 'the graphite window renders the grouped ledger'
}finally{
 if($script:UI.claimsWin){$script:UI.claimsWin.Tag='dispose';$script:UI.claimsWin.Close()}
 if([IO.Directory]::Exists($script:QM_SETTINGSD)){[IO.Directory]::Delete($script:QM_SETTINGSD,$true)}
}
Write-Output "PASS=$pass FAIL=$fail"
if($fail){exit 1}
