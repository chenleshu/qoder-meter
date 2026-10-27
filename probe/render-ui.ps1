# Render the real WPF controls without opening windows or touching user configuration.
param([string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) '.build'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('lib-interop','lib-data','lib-credits','lib-ui','lib-config-layout','lib-settings')){. (Join-Path $root ('src\'+$name+'.ps1'))}
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
$script:QM_VERSION='1.4.0-win.2';$script:QM_SHUTDOWN=$true
$script:CFG=New-QmConfig;$script:CFG.skin='paper'
$script:CREDIT=@{Running=$false;Status=[pscustomobject]@{State='claimed';CampaignDay='2026-10-27';At='10:05';Reason='测试展示：本周期已领取'}}
$script:QM_S.sessionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$script:QM_S.title='状态条视觉测试（示例数据）';$script:QM_S.model='test-model'
$script:QM_S.recent=@([pscustomobject]@{session_id=$script:QM_S.sessionId;title=$script:QM_S.title})
$script:QM_S.tps=132.6;$script:QM_S.tpsHistory=@(30,40,50,80,50,60,70,95,100,80,110,120,128,132)
$script:QM_S.estOut=207900;$script:QM_S.credits=41.87;$script:QM_S.requestCount=14;$script:QM_S.toolCount=13;$script:QM_S.turnWall=64;$script:QM_S.turnDuration=12.5;$script:QM_S.sessionStartedAt=(QmNowMs)-27180000;$script:QM_S.lastLatency=12
try{
 foreach($skin in @('paper','graphite')){
  foreach($layout in @('title','toolbar','bottom','sidebar')){
   $script:CFG.layout=$layout;$script:UI=@{skin=$skin;border=$null}
   if($layout -eq 'sidebar'){$view=Build-QmCard $script:CFG $skin 1;$width=246;$height=250}
   else{$view=Build-QmBar $script:CFG $skin 1;$width=if($layout -eq 'title'){689}else{480};$height=30;$view.Height=$height}
   $script:UI.border=$view;$view.ToolTip=[Windows.Controls.ToolTip]::new();Update-QmView
   if($layout -ne 'sidebar'){Set-QmBarWidth $width}
   Save-View $view $width $height ($layout+'-'+$skin)
  }
  $script:CFG.skin=$skin;$script:UI=@{skin=$skin;settings=$null};$window=New-QmSettingsWindow;$script:UI.settings=$window;Sync-QmSettings
  $content=$window.Content;$window.Content=$null;$background=[Windows.Controls.Border]::new();$background.Background=Get-QmBrush $script:QM_SKINS[$skin].bg;$background.Child=$content
  Save-View $background 450 720 ('settings-'+$skin)
  $script:QM_SETTINGS_CONTROLS.scroll.ScrollToEnd();$background.UpdateLayout();Save-View $background 450 720 ('settings-bottom-'+$skin)
  $window.Close()
 }
}finally{Close-QmDb}
