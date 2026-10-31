#requires -Version 5.1
# Offline regression for lib-account.ps1: no network, no Qoder data, temp claims store only.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path $env:TEMP ('qm-account-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
$script:QM_SETTINGSD=$temp
. (Join-Path $root 'src\lib-account.ps1')
# UI helpers from lib-data/lib-ui are not loaded; only the pill formatter needs this one.
function Format-QmK($n){if([double]$n -ge 1000){return ([math]::Round([double]$n/1000,1)).ToString([Globalization.CultureInfo]::InvariantCulture)+'k'};return ([double]$n).ToString('0',[Globalization.CultureInfo]::InvariantCulture)}
function Show-QmBalloon([string]$title,[string]$text){$script:Balloon=@($title,$text)}
function Read-QmAuth {throw 'Offline probe must not read authentication'}
$script:QM_SHUTDOWN=$true
try{
 Check ((Format-QmScope 'C_S_U_SERIES') -eq 'SOTA 专属' -and (Format-QmScope 'ALL_MODELS') -eq '全模型' -and (Format-QmScope '') -eq '') 'scope labels'
 Check ((Format-QmPlan 'personal_professional') -eq 'Pro' -and (Format-QmPlan 'personal_free') -eq '免费版' -and (Format-QmPlan '') -eq '—') 'plan labels'
 Check ((Format-QmNum 5730) -eq '5,730') 'numbers use invariant grouping'
 Check ((Format-QmExpiry 0) -eq '') 'missing expiry stays blank'
 $far=(Get-QmCstNow).AddDays(3);$farMs=([DateTimeOffset]::new($far,[TimeSpan]::FromHours(8))).ToUnixTimeMilliseconds()
 Check ((Format-QmExpiry $farMs) -eq $far.ToString('MM-dd HH:mm')) 'future expiry is month-day hour:minute'

 # Aggregation: plan + add-on + only available packages with remaining balance.
 $script:QM_CLAIMS=$null
 $script:ACCOUNT=@{Auth=[pscustomobject]@{Name='Tester';Error=''};Error='';At='';Running=$false;UsageAt=1L;CampAt=1L;LastFail=@{}
  Usage=[pscustomobject]@{Plan='personal_professional';ExpiresAt=$farMs;PlanTotal=2000;PlanUsed=1666;PlanRemaining=334;AddOnTotal=3400;AddOnUsed=2100;AddOnRemaining=1300
   Packages=@(
    [pscustomobject]@{Title='SOTA';Name='a';Total=4096;Used=0;Remaining=4096;ExpiresAt=$farMs;Available=$true;Status='active'},
    [pscustomobject]@{Title='Exhausted';Name='b';Total=1024;Used=1024;Remaining=0;ExpiresAt=$farMs;Available=$true;Status='active'},
    [pscustomobject]@{Title='Inactive';Name='c';Total=500;Used=0;Remaining=500;ExpiresAt=$farMs;Available=$false;Status='expired'})}
  Campaigns=@(
   [pscustomobject]@{CampaignId='c1';CampaignKey='k1';Title='SOTA 补给';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=4096;Kind='CREDITS';Scope='C_S_U_SERIES'},
   [pscustomobject]@{CampaignId='c2';CampaignKey='k2';Title='每日';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMED';Amount=100;Kind='CREDITS';Scope='ALL_MODELS'},
   [pscustomobject]@{CampaignId='c3';CampaignKey='k3';Title='转发';ActionType='VISIT';ClaimStatus='CLAIMABLE';Amount=0;Kind='';Scope=''})}
 $s=Get-QmAccountStatus
 Check ($s.State -eq 'ok' -and $s.Plan -eq 'Pro' -and $s.Name -eq 'Tester') 'account summary exposes plan and name'
 Check ($s.Balance -eq (334+1300+4096) -and $s.Packages.Count -eq 1) 'balance includes active package remaining and hides exhausted ones'
 Check ($s.Claimable.Count -eq 1 -and $s.Claimable[0].CampaignId -eq 'c1') 'only CLAIM_BENEFIT entries are claimable'

 # Seed one prior claim today so the pill shows today's gains.
 Add-QmClaimRecord ([pscustomobject]@{CampaignId='old';CampaignKey='old';Title='昨日补给';Amount=100;Kind='CREDITS';Scope='ALL_MODELS'}) ([pscustomobject]@{claimedAt='';expiresAt='';replayed=$false})
 $s=Get-QmAccountStatus
 Check ($s.TodayAmount -eq 100 -and $s.TodayCount -eq 1) 'today aggregates locally recorded claims'
 $pill=Format-QmAccountPill
 Check ($pill.Text -eq '待领 1 项' -and $pill.Tone -eq 'gold') 'unclaimed benefits take priority in the pill'
 $script:ACCOUNT.Campaigns=@($script:ACCOUNT.Campaigns|Where-Object {$_.ClaimStatus -eq 'CLAIMED'})
 Check ((Format-QmAccountPill).Text -eq '余 5,730 · 今 +100' -and (Format-QmAccountPill).Tone -eq 'green') 'claimed day shows balance and gains together'
 $script:ACCOUNT.Running=$true;Check ((Format-QmAccountPill).Text -eq '领取中…') 'running claim is visible';$script:ACCOUNT.Running=$false
 $script:ACCOUNT.Error='boom';Check ((Format-QmAccountPill).Text -eq '账号异常') 'account errors are surfaced';$script:ACCOUNT.Error=''

 # Claim flow with a mocked API: claims every target once and records history.
 $script:ACCOUNT.Campaigns=@(
  [pscustomobject]@{CampaignId='c1';CampaignKey='k1';Title='SOTA 补给';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=4096;Kind='CREDITS';Scope='C_S_U_SERIES'},
  [pscustomobject]@{CampaignId='c2';CampaignKey='k2';Title='每日';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=100;Kind='CREDITS';Scope='ALL_MODELS'})
 $script:ACCOUNT.UsageAt=5L;$script:ACCOUNT.CampAt=5L
 $script:Calls=New-Object System.Collections.Generic.List[object]
 function Invoke-QmApi([string]$method,[string]$path,[string]$body){
  $script:Calls.Add([pscustomobject]@{Method=$method;Path=$path;Body=$body})
  $id=$path.Split('/')[-2]
  return [pscustomobject]@{status='CLAIMED';campaignId=$id;replayed=($id -eq 'c2');expiresAt=$null}
 }
 $r=Invoke-QmAccountClaim
 Check ($r.Claimed.Count -eq 2 -and $r.Failed.Count -eq 0 -and $script:Calls.Count -eq 2) 'claim posts once per claimable campaign'
 Check ($script:Calls[0].Method -eq 'Post' -and $script:Calls[0].Path -match '/me/campaigns/c1/claim$') 'claim uses the campaign claim endpoint'
 Check ($script:Calls[0].Body -eq '{}') 'claim sends an empty JSON body the desktop client expects'
 Check ($script:ACCOUNT.Campaigns[0].ClaimStatus -eq 'CLAIMED' -and $script:ACCOUNT.Campaigns[1].ClaimStatus -eq 'CLAIMED') 'claimed campaigns are marked locally'
 Check ($script:ACCOUNT.UsageAt -eq 0 -and $script:ACCOUNT.CampAt -eq 0) 'a successful claim forces a balance refresh'
 Check ($script:Balloon[0] -eq '已领取 2 项权益' -and $script:Balloon[1] -match 'SOTA 补给 \(\+4,096（SOTA 专属）\)|SOTA 补给 \+4,096（SOTA 专属）') 'balloon names the claimed benefits'
 $entries=(Get-QmClaims).Entries.ToArray()
 Check ($entries.Count -eq 3 -and @($entries|Where-Object {$_.campaignId -eq 'c1'}).Count -eq 1) 'claim history records each campaign once per day'
 $r=Invoke-QmAccountClaim
 Check (!$r.Claimed.Count -and $r.Message -eq '没有可领取的权益' -and $script:Calls.Count -eq 2) 'a second claim is a no-op'

 # Campaigns already recorded today are never claimed twice, even if a fresh
 # list still reports them as CLAIMABLE.
 $script:ACCOUNT.Campaigns=@(
  [pscustomobject]@{CampaignId='c1';CampaignKey='k1';Title='SOTA 补给';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=4096;Kind='CREDITS';Scope='C_S_U_SERIES'},
  [pscustomobject]@{CampaignId='d10';CampaignKey='kd10';Title='新权益';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=75;Kind='CREDITS';Scope='ALL_MODELS'})
 Check ((Get-QmAccountStatus).Claimable.Count -eq 1 -and (Get-QmAccountStatus).Claimable[0].CampaignId -eq 'd10') 'recorded campaigns are not offered again'
 $r=Invoke-QmAccountClaim
 Check ($r.Claimed.Count -eq 1 -and $r.Claimed[0].Title -eq '新权益' -and $script:Calls.Count -eq 3 -and $script:Calls[2].Path -match '/me/campaigns/d10/claim$') 'claim skips the campaign recorded today'

 # Auto claims respect a per-campaign cooldown.
 $script:ACCOUNT.Campaigns=@([pscustomobject]@{CampaignId='c9';CampaignKey='k9';Title='冷却中';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=50;Kind='CREDITS';Scope='ALL_MODELS'})
 $script:ACCOUNT.LastFail=@{c9=(Get-QmCstNow).Ticks}
 $r=Invoke-QmAccountClaim -Auto
 Check (!$r.Claimed.Count -and $script:Calls.Count -eq 3 -and $script:ACCOUNT.LastFail.ContainsKey('c9')) 'auto claim skips a cooling campaign'
 $script:ACCOUNT.LastFail=@{}

 # Network failures back off instead of retrying on every UI tick; success clears the gate.
 $script:CFG=@{creditAuto=$false}
 $script:ACCOUNT=@{Auth=[pscustomobject]@{Token='fixture';ReadAt=(Get-QmCstNow).Ticks;Error=''};Usage=$null;Campaigns=$null;Running=$false;Error='';UsageAt=0L;CampAt=0L;NextTry=0L;LastFail=@{};Notified=$null;At=''}
 $script:Attempts=0
 function Invoke-QmApi([string]$method,[string]$path,[string]$body){$script:Attempts++;throw '离线'}
 Update-QmAccountState
 Check ($script:ACCOUNT.Error -eq '离线' -and [long]$script:ACCOUNT.NextTry -gt 0) 'failed refresh records an error and a backoff gate'
 $failedAttempts=$script:Attempts
 Update-QmAccountState
 Check ($script:Attempts -eq $failedAttempts) 'backoff suppresses immediate network retries'
 $script:ACCOUNT.NextTry=0
 $script:RefreshCalls=New-Object System.Collections.Generic.List[object]
 $script:ClaimStatus='PENDING'
 function Invoke-QmApi([string]$method,[string]$path,[string]$body){
  $script:RefreshCalls.Add([pscustomobject]@{Method=$method;Path=$path})
  if($path -like '*/usage'){return [pscustomobject]@{qoderUsage=[pscustomobject]@{userType='personal_professional';expiresAt=0;userQuota=[pscustomobject]@{total=1;used=0;remaining=1};addOnQuota=$null;dedicatedResourcePackages=@()}}}
  if($path -like '*/claim'){return [pscustomobject]@{status=$script:ClaimStatus;replayed=$false;expiresAt=$null}}
  return [pscustomobject]@{campaigns=@()}
 }
 Update-QmAccountState
 Check ($script:ACCOUNT.Error -eq '' -and $script:ACCOUNT.NextTry -eq 0 -and $script:ACCOUNT.Usage.PlanRemaining -eq 1) 'a successful refresh clears the error and backoff'

 # An empty campaign response is loaded data, not a reason to fetch on every tick.
 Check ($script:ACCOUNT.Campaigns -is [array] -and $script:ACCOUNT.Campaigns.Count -eq 0) 'refresh caches an empty campaign array'
 $reads=$script:RefreshCalls.Count;$campAt=$script:ACCOUNT.CampAt
 Update-QmAccountState
 Check ($script:RefreshCalls.Count -eq $reads -and $script:ACCOUNT.CampAt -eq $campAt) 'empty campaigns are not reread on the next tick'
 $script:ACCOUNT.Campaigns=$null;$script:ACCOUNT.CampAt=0L
 $reads=$script:RefreshCalls.Count
 $r=Invoke-QmAccountClaim
 Check ($script:ACCOUNT.Campaigns -is [array] -and $script:ACCOUNT.Campaigns.Count -eq 0 -and $script:RefreshCalls.Count -eq ($reads+1) -and $r.Message -eq '没有可领取的权益') 'claim entry also caches an empty campaign array'
 $reads=$script:RefreshCalls.Count;$campAt=$script:ACCOUNT.CampAt
 $r=Invoke-QmAccountClaim
 Update-QmAccountState
 Check ($script:RefreshCalls.Count -eq $reads -and $script:ACCOUNT.CampAt -eq $campAt) 'empty claim cache survives a second claim and the next tick'

 # Non-CLAIMED replies back off just like exceptions, without invalidating skipped work.
 $script:ACCOUNT.Campaigns=@([pscustomobject]@{CampaignId='c9';CampaignKey='k9';Title='冷却中';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=50;Kind='CREDITS';Scope='ALL_MODELS'})
 $script:ACCOUNT.LastFail=$null
 $script:ACCOUNT.CampAt=(Get-QmCstNow).Ticks;$script:ACCOUNT.UsageAt=$script:ACCOUNT.CampAt
 $usageAt=$script:ACCOUNT.UsageAt;$reads=$script:RefreshCalls.Count
 $r=Invoke-QmAccountClaim -Auto
 Check ($r.Failed.Count -eq 1 -and !$r.Claimed.Count -and $script:ACCOUNT.LastFail -and $script:ACCOUNT.LastFail.ContainsKey('c9') -and [long]$script:ACCOUNT.LastFail['c9'] -ge $usageAt) 'non-CLAIMED reply records a campaign cooldown'
 Check ($script:RefreshCalls.Count -eq ($reads+1) -and $script:ACCOUNT.CampAt -eq 0 -and $script:ACCOUNT.UsageAt -eq $usageAt) 'an unsuccessful claim attempt still invalidates only the campaign cache'
 # Model a fresh campaign cache while the failed campaign is still cooling.
 $script:ACCOUNT.CampAt=(Get-QmCstNow).Ticks
 $campAt=$script:ACCOUNT.CampAt;$reads=$script:RefreshCalls.Count
 $r=Invoke-QmAccountClaim -Auto
 Check (!$r.Claimed.Count -and !$r.Failed.Count -and $script:RefreshCalls.Count -eq $reads -and $script:ACCOUNT.CampAt -eq $campAt -and !$script:ACCOUNT.Running) 'all cooling targets preserve CampAt without a request'
 $script:CFG.creditAuto=$true
 Update-QmAccountState
 Check ($script:RefreshCalls.Count -eq $reads -and $script:ACCOUNT.CampAt -eq $campAt) 'auto tick preserves a fresh cache when every target is cooling'

 # A mixed batch skips the cooling target but still refreshes after an actual claim.
 $script:ACCOUNT.Campaigns+=@([pscustomobject]@{CampaignId='c10';CampaignKey='k10';Title='可领取';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=75;Kind='CREDITS';Scope='ALL_MODELS'})
 $script:ClaimStatus='CLAIMED'
 $reads=$script:RefreshCalls.Count
 $r=Invoke-QmAccountClaim -Auto
 Check ($r.Claimed.Count -eq 1 -and !$r.Failed.Count -and $script:RefreshCalls.Count -eq ($reads+1) -and $script:RefreshCalls[-1].Method -eq 'Post' -and $script:RefreshCalls[-1].Path -match '/me/campaigns/c10/claim$' -and $script:ACCOUNT.LastFail.ContainsKey('c9')) 'mixed batch posts only the non-cooling campaign'
 Check ($script:ACCOUNT.CampAt -eq 0 -and $script:ACCOUNT.UsageAt -eq 0) 'mixed batch with an actual claim invalidates both caches'
 $reads=$script:RefreshCalls.Count
 Update-QmAccountState
 Check ($script:RefreshCalls.Count -eq ($reads+2) -and $script:RefreshCalls[$reads].Path -like '*/usage' -and $script:RefreshCalls[$reads+1].Path -like '*/campaigns' -and $script:ACCOUNT.CampAt -gt 0) 'next tick refreshes usage and campaigns after the mixed batch'
 $script:CFG.creditAuto=$false

 # Local cache fallback: when the API answers with an empty list, reuse the
 # campaign body Qoder cached so auto-claim still sees today's benefits.
 Check (-not $script:QM_CAMPAIGN_CACHE_FALLBACK) 'cache fallback stays opt-in'
 $fixtureProfile=Join-Path $temp 'profile'
 $cacheDir=Join-Path $fixtureProfile 'Cache\Cache_Data'
 [void][IO.Directory]::CreateDirectory($cacheDir)
 $nowSec=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $fixture=[pscustomobject]@{showCampaign=$true;claimable=$true;campaigns=@(
   [pscustomobject]@{campaignId='cache1';campaignKey='ck1';actionType='CLAIM_BENEFIT';claimStatus='CLAIMABLE';startAt=$nowSec-3600;endAt=$nowSec+7200;benefit=[pscustomobject]@{kind='CREDITS';amount=100;validity=[pscustomobject]@{mode='RELATIVE_DAYS';days=30};modelScope=[pscustomobject]@{modelSeries=[pscustomobject]@{key='ALL_MODELS'}}};placements=@([pscustomobject]@{type='POPUP';content=[pscustomobject]@{zh=[pscustomobject]@{title='每日 100 Credits';description='每日刷新'}}})},
   [pscustomobject]@{campaignId='cache2';campaignKey='ck2';actionType='CLAIM_BENEFIT';claimStatus='CLAIMABLE';startAt=$nowSec-7200;endAt=$nowSec-60;benefit=[pscustomobject]@{kind='CREDITS';amount=50;validity=[pscustomobject]@{mode='RELATIVE_DAYS';days=1};modelScope=[pscustomobject]@{modelSeries=[pscustomobject]@{key='ALL_MODELS'}}};placements=@()},
   [pscustomobject]@{campaignId='cache3';campaignKey='ck3';actionType='VIEW_DETAILS';claimStatus='CLAIMABLE';startAt=$nowSec-3600;endAt=$nowSec+7200;placements=@()})}
 $fixtureText='prefix'+($fixture|ConvertTo-Json -Depth 12)+'suffix'
 $latin=[Text.Encoding]::GetEncoding(28591)
 $bytes=[Text.Encoding]::UTF8.GetBytes($fixtureText)
 [IO.File]::WriteAllBytes((Join-Path $cacheDir 'data_1'),$bytes)
 $parsed=ConvertFrom-QmCampaignCacheText $latin.GetString($bytes)
 Check ($parsed -and @($parsed.campaigns).Count -eq 3) 'cache parser extracts the campaign body'
 $mapped=ConvertTo-QmCampaign (@($parsed.campaigns)[0])
 Check ($mapped.CampaignId -eq 'cache1' -and $mapped.Title -eq '每日 100 Credits' -and $mapped.Amount -eq 100 -and $mapped.Scope -eq 'ALL_MODELS') 'cache campaigns map to the API shape'
 $script:QM_DB=Join-Path $fixtureProfile 'main.sqlite'
 $script:QM_CACHE_CAMPAIGNS=$null
 $cached=@(Get-QmCachedCampaigns)
 Check ($cached.Count -eq 2 -and @($cached|Where-Object {$_.CampaignId -eq 'cache2'}).Count -eq 0) 'expired cache rows are filtered'
 $script:QM_CAMPAIGN_CACHE_FALLBACK=$true
 $script:QM_CACHE_CAMPAIGNS=$null
 $list=@(Get-QmCampaignsNow)
 Check ($list.Count -eq 1 -and $list[0].CampaignId -eq 'cache1') 'empty API list is completed from the Qoder cache'
 Add-QmClaimRecord ([pscustomobject]@{CampaignId='cache1';CampaignKey='ck1';Title='每日 100 Credits';Amount=100;Kind='CREDITS';Scope='ALL_MODELS'}) ([pscustomobject]@{claimedAt='';expiresAt='';replayed=$false})
 $script:QM_CACHE_CAMPAIGNS=$null
 $list=@(Get-QmCampaignsNow)
 Check (!($list|Where-Object {$_.CampaignId -eq 'cache1'})) 'already claimed cache rows are not re-offered'
 # A non-empty live list is authoritative; stale cache rows must not be merged in.
 $script:QM_CACHE_CAMPAIGNS=[pscustomobject]@{ReadAt=(Get-QmCstNow).Ticks;List=@([pscustomobject]@{CampaignId='cache4';CampaignKey='ck4';Title='旧缓存';ActionType='CLAIM_BENEFIT';ClaimStatus='CLAIMABLE';Amount=80;Kind='CREDITS';Scope='ALL_MODELS'})}
 function Invoke-QmApi([string]$method,[string]$path,[string]$body){
  if($path -like '*/campaigns'){return [pscustomobject]@{campaigns=@([pscustomobject]@{campaignId='live1';campaignKey='lk1';actionType='CLAIM_BENEFIT';claimStatus='CLAIMED';benefit=[pscustomobject]@{kind='CREDITS';amount=100};placements=@()})}}
  return [pscustomobject]@{}
 }
 $list=@(Get-QmCampaignsNow)
 Check ($list.Count -eq 1 -and $list[0].CampaignId -eq 'live1') 'a non-empty API list wins over the local cache'
 $script:QM_CACHE_CAMPAIGNS=$null
 $script:QM_CAMPAIGN_CACHE_FALLBACK=$false
 $script:QM_DB=$null
 $script:QM_CACHE_CAMPAIGNS=$null

 # History rotation keeps the newest entries.
 $script:QM_CLAIMS=$null
 for($i=1;$i -le 405;$i++){Add-QmClaimRecord ([pscustomobject]@{CampaignId=('x'+$i);CampaignKey='x';Title='t';Amount=1;Kind='CREDITS';Scope=''}) ([pscustomobject]@{claimedAt='';expiresAt='';replayed=$false})}
 $entries=(Get-QmClaims).Entries.ToArray()
 Check ($entries.Count -eq 400 -and $entries[-1].campaignId -eq 'x405' -and $entries[0].campaignId -eq 'x6') 'claims history is capped at the newest 400 entries'

 # The persisted file must be valid UTF-8 JSON.
 $raw=[IO.File]::ReadAllText($script:QM_CLAIMS_PATH)|ConvertFrom-Json
 Check ($raw.version -eq 1 -and @($raw.entries).Count -eq 400) 'claims store roundtrips through disk'
}finally{
 Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "PASS=$pass FAIL=$fail"
if($fail){exit 1}
