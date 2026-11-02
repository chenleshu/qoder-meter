# Render the real WPF controls without opening windows or touching user configuration.
param([string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) '.build'),[switch]$StableWidthOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('lib-interop','lib-data','lib-account','lib-ui','lib-config-layout','lib-stats','lib-settings')){. (Join-Path $root ('src\'+$name+'.ps1'))}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\meter.ps1'),[ref]$tokens,[ref]$errors)
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
function Get-QmAutoStart {return $false}
function Get-QmAppAppearance {return 'light'}
function Get-QmUpdateStatus {return [pscustomobject]@{State='no-windows';Text='尚无 Windows 发布包';Url=''}}
function Save-View($element,[double]$width,[double]$height,[string]$name){
 $element.Measure([Windows.Size]::new($width,$height));$element.Arrange([Windows.Rect]::new(0,0,$width,$height));$element.UpdateLayout()
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($width*2),[int]($height*2),192,192,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($element)
 $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $path=Join-Path $OutputDirectory ($name+'.png');$stream=[IO.File]::Create($path)
 try{$encoder.Save($stream)}finally{$stream.Dispose()};Write-Output $path
}
if(!(Test-Path -LiteralPath $OutputDirectory)){throw 'Output directory must already exist.'}
# Keep every scratch file inside this process: the statistics renderer must never
# read or write the real Meter settings directory where a live cache lives.
$statsScratch=Join-Path ([IO.Path]::GetTempPath()) ('qm-render-stats-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($statsScratch)
$script:QM_VERSION='1.4.0-win.3';$script:QM_SHUTDOWN=$true
$script:CFG=New-QmConfig;$script:CFG.skin='paper'
$script:QM_CLAIMS_PATH=Join-Path $OutputDirectory 'claims-fixture.json';$script:QM_CLAIMS=$null
$script:ACCOUNT=@{
 Auth=[pscustomobject]@{Name='示例账户';Email='demo@example.com';UserId='demo';Error=''}
 Usage=[pscustomobject]@{Plan='personal_professional';ExpiresAt=[DateTimeOffset]::UtcNow.AddDays(20).ToUnixTimeMilliseconds();PlanTotal=2000;PlanUsed=1666;PlanRemaining=334;AddOnTotal=3400;AddOnUsed=2100;AddOnRemaining=1300
  Packages=@([pscustomobject]@{Name='act-demo';Title='SOTA 算力补给包';Description='SOTA 专属';Total=4096;Used=0;Remaining=4096;ExpiresAt=[DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds();Available=$true;Status='active'})}
 Campaigns=@([pscustomobject]@{CampaignId='demo-campaign';CampaignKey='demo';Title='每日 100 Credits';Amount=100;Kind='CREDITS';Scope='';ClaimStatus='CLAIMABLE';ActionType='CLAIM_BENEFIT';StartAt=0;EndAt=0});Running=$false;Error='';UsageAt=1L;CampAt=1L;NextTry=0L;LastFail=@{};Notified=$null;At=''
}
$script:QM_CLAIMS=[pscustomobject]@{Version=1;Entries=(New-Object System.Collections.Generic.List[object])}
$now=Get-QmCstNow;$today=Get-QmCampaignDay;$yesterday=$now.AddDays(-1).AddHours(-10).ToString('yyyy-MM-dd');$older=$now.AddDays(-2).AddHours(-10).ToString('yyyy-MM-dd')
$script:QM_CLAIMS.Entries.Add([pscustomobject]@{campaignId='demo-daily';campaignKey='daily';day=$today;title='每日 100 Credits';amount=100;kind='CREDITS';scope='';claimedAt=$now.AddMinutes(-9).ToString('s');expiresAt='';replayed=$false})
$script:QM_CLAIMS.Entries.Add([pscustomobject]@{campaignId='demo-sota';campaignKey='demo';day=$today;title='SOTA 算力补给包';amount=4096;kind='CREDITS';scope='C_S_U_SERIES';claimedAt=$now.AddMinutes(-4).ToString('s');expiresAt=$now.AddHours(8).ToString('s');replayed=$false})
$script:QM_CLAIMS.Entries.Add([pscustomobject]@{campaignId='demo-daily-y';campaignKey='daily';day=$yesterday;title='每日 100 Credits';amount=100;kind='CREDITS';scope='';claimedAt=$now.AddDays(-1).AddHours(-10).ToString('s');expiresAt='';replayed=$false})
$script:QM_CLAIMS.Entries.Add([pscustomobject]@{campaignId='demo-all';campaignKey='all';day=$older;title='全模型试用补给包';amount=500;kind='CREDITS';scope='ALL_MODELS';claimedAt=$now.AddDays(-2).AddHours(-10).ToString('s');expiresAt='';replayed=$true})
$script:QM_S.sessionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$script:QM_S.title='状态条视觉测试（示例数据）';$script:QM_S.model='test-model'
$script:QM_S.recent=@([pscustomobject]@{session_id=$script:QM_S.sessionId;title=$script:QM_S.title})
$script:QM_S.tps=132.6;$script:QM_S.tpsHistory=@(30,40,50,80,50,60,70,95,100,80,110,120,128,132)
$script:QM_S.estOut=207900;$script:QM_S.credits=41.87;$script:QM_S.requestCount=14;$script:QM_S.toolCount=13;$script:QM_S.turnWall=64;$script:QM_S.turnDuration=12.5;$script:QM_S.sessionStartedAt=(QmNowMs)-27180000;$script:QM_S.lastLatency=12
try{
 if($StableWidthOnly){
  foreach($skin in @('paper','graphite')){
   $script:CFG.layout='title';$script:UI=@{skin=$skin;border=$null}
   $view=Build-QmBar $script:CFG $skin 1;$view.UseLayoutRounding=$true
   $script:UI.border=$view;$view.ToolTip=[Windows.Controls.ToolTip]::new();$short=$null
   foreach($state in @('short','normal','long')){
    Update-QmView
    if($state -eq 'short'){
     $script:UI_TPS.Text='—';foreach($text in $script:UI_SEGS.Values){$text.Text='—'}
     $script:UI_CREDIT.Text='未登录'
    }elseif($state -eq 'long'){
     $script:UI_TPS.Text='999999';foreach($text in $script:UI_SEGS.Values){$text.Text='999999999.99'}
     $script:UI_CREDIT.Text='余 999,999,999 · 今 +999,999,999'
    }
    Set-QmBarWidth 689
    if($view.Width -gt 689){throw 'Compact content exceeded the rendered bar.'}
    if($state -eq 'short'){$short=$view.Width}elseif($state -eq 'long' -and $view.Width -lt $short){throw 'Long content must not make the bar narrower.'}
    Save-View $view $view.Width $view.Height ('compact-width-'+$skin+'-'+$state)
   }
   Write-Output ($skin+' compact width: '+$short+' -> '+$view.Width+' DIP')
  }
  return
 }
 foreach($skin in @('paper','graphite')){
  foreach($layout in @('title','toolbar','bottom','sidebar')){
   $script:CFG.layout=$layout;$script:UI=@{skin=$skin;border=$null}
   if($layout -eq 'sidebar'){$view=Build-QmCard $script:CFG $skin 1;$width=246;$height=250}
   else{$view=Build-QmBar $script:CFG $skin 1;$width=if($layout -eq 'title'){689}else{480};$height=26;$view.Height=$height}
   $script:UI.border=$view;$view.ToolTip=[Windows.Controls.ToolTip]::new();Update-QmView
   if($layout -ne 'sidebar'){Set-QmBarWidth $width;$width=$view.Width}
   Save-View $view $width $height ($layout+'-'+$skin)
  }
  $script:CFG.skin=$skin;$script:UI=@{skin=$skin;settings=$null};$window=New-QmSettingsWindow;$script:UI.settings=$window;Sync-QmSettings
  $content=$window.Content;$window.Content=$null;$background=[Windows.Controls.Border]::new();$background.Background=Get-QmBrush $script:QM_SKINS[$skin].bg;$background.Child=$content
  # Detaching from the window also drops its resource scope; re-attach the theme
  # dictionary so the captured surface shows the same control styles as the app.
  [void]$background.Resources.MergedDictionaries.Add((Get-QmThemeResources $skin))
  Save-View $background 450 720 ('settings-'+$skin)
  $script:QM_SETTINGS_CONTROLS.scroll.ScrollToEnd();$background.UpdateLayout();Save-View $background 450 720 ('settings-bottom-'+$skin)
  $window.Close()
  # Claim history uses the same themed-window stack, including its empty state.
  $script:UI=@{claimsWin=$null};$window=New-QmClaimHistoryWindow;$script:UI.claimsWin=$window;Sync-QmClaimHistory
  $content=$window.Content;$window.Content=$null;$background=[Windows.Controls.Border]::new();$background.Background=Get-QmBrush $script:QM_SKINS[$skin].bg;$background.Child=$content
  [void]$background.Resources.MergedDictionaries.Add((Get-QmThemeResources $skin))
  Save-View $background 500 620 ('claims-'+$skin)
  if($skin -eq 'paper'){
   $ledger=Get-QmClaims;$savedEntries=$ledger.Entries
   $ledger.Entries=New-Object System.Collections.Generic.List[object]
   Sync-QmClaimHistory
   Save-View $background 500 620 'claims-paper-empty'
   $ledger.Entries=$savedEntries
  }
  $window.Close()
  # Local usage statistics uses a prebuilt cache so rendering never scans
  # Qoder logs, reads accounts or opens a network connection.
  $script:CFG.statsRange='30d';$script:CFG.statsGroup='day';$script:CFG.statsTab='overview';$script:QM_STATS_PAGE=0
  $script:QM_SETTINGSD=$statsScratch
  $script:QM_STATS_CACHE=@{at=(QmNowMs);rows=44;days=@{}}
  $today=[datetime]::Today
  $fixtureModels=@('qmodel','dfmodel','kmodel_latest','mmodel','lite')
  for($i=0;$i -lt 22;$i++){
   $key=$today.AddDays(-$i).ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
   $credits=[double](3.5+[math]::Round([math]::Abs([math]::Sin($i/2.4))*26.0,2))
   $tokens=[double](1400+$i*260)
   $requests=[long](2+($i%5))
   $estimated=($i%4 -eq 1)
   $primary=$fixtureModels[$i%$fixtureModels.Count]
   $secondary=$fixtureModels[($i+2)%$fixtureModels.Count]
   $day=@{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated;models=@{
    $primary=@{credits=[math]::Round($credits*0.68,2);tokens=[double]($tokens*0.7);$requests=[long]($requests-1);estimated=$estimated}
    $secondary=@{credits=[math]::Round($credits*0.32,2);tokens=[double]($tokens*0.3);$requests=[long]1;estimated=$false}}}
   if($i -eq 20){$day=@{credits=0.0;tokens=$tokens;requests=$requests;estimated=$true;models=@{$primary=@{credits=0.0;tokens=[double]$tokens;requests=[long]$requests;estimated=$true}}}}
   $script:QM_STATS_CACHE.days[$key]=$day
  }
  $script:QM_STATS_CACHE_LOADED=$true;$script:QM_STATS_CACHE_PATH_LOADED=Get-QmStatsCachePath;$script:QM_STATS_ERROR=''
  $script:UI=@{statsWin=$null};$window=New-QmStatsWindow;$script:UI.statsWin=$window;Sync-QmStatsWindow
  $content=$window.Content;$window.Content=$null;$background=[Windows.Controls.Border]::new();$background.Background=Get-QmBrush $script:QM_SKINS[$skin].bg;$background.Child=$content
  [void]$background.Resources.MergedDictionaries.Add((Get-QmThemeResources $skin))
  Save-View $background 640 760 ('stats-'+$skin)
  # The overview scrolls; capture the auto summary block as its own fixture.
  $script:QM_STATS_REFS.Overview.ScrollToEnd();$background.UpdateLayout()
  Save-View $background 640 760 ('stats-summary-'+$skin)
  $script:QM_STATS_REFS.Overview.ScrollToVerticalOffset(0)
  $script:CFG.statsTab='detail';Sync-QmStatsWindow
  Save-View $background 640 760 ('stats-detail-'+$skin)
  $script:CFG.statsTab='overview';$script:CFG.statsGroup='week';Sync-QmStatsWindow
  Save-View $background 640 760 ('stats-week-'+$skin)
  $script:CFG.statsGroup='day';$script:QM_STATS_CACHE.days=@{};Sync-QmStatsWindow
  Save-View $background 640 760 ('stats-empty-'+$skin)
  $window.Close()
  # Themed hover card, rendered from the same fixture without opening a popup.
  $script:CFG.layout='title';$script:UI=@{skin=$skin;border=$null}
  $bar=Build-QmBar $script:CFG $skin 1;$script:UI.border=$bar
  $script:UI_TIP=New-QmTipCard $skin 1
  Update-QmView
  $card=$script:UI_TIP.Root
  $card.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $surface=[Windows.Controls.Border]::new();$surface.Background=Get-QmBrush $(if($skin -eq 'graphite'){'#FF15171C'}else{'#FFF2F4F8'});$surface.Child=$card
  Save-View $surface ($card.Width+18) ([math]::Ceiling($card.DesiredSize.Height)) ('hover-'+$skin)
 }
}finally{
 Close-QmDb
 if(Test-Path -LiteralPath $statsScratch){Remove-Item -LiteralPath $statsScratch -Recurse -Force -ErrorAction SilentlyContinue}
}
