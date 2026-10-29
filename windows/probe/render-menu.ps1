# Render actual, hidden WinForms ToolStrips; never show a popup or capture the screen.
param([string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) '.build'))
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this probe with Windows PowerShell -NoProfile -STA -File.'}
if(!(Test-Path -LiteralPath $OutputDirectory -PathType Container)){throw 'Output directory must already exist.'}
$OutputDirectory=(Get-Item -LiteralPath $OutputDirectory).FullName
$root=Split-Path $PSScriptRoot -Parent

# Unlike dot-sourcing meter/lib-data, this cannot start timers or discover real account files.
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
. (Join-Path $root 'src\lib-ui.ps1')
function Get-QmAutoStart {return $false}
function Get-QmAppAppearance {return 'light'}
function Get-QmSystemDark {throw 'Offline probe must not read system appearance settings.'}
function Invoke-QmCommand {throw 'Render probe must not dispatch commands.'}

# All account/session data is synthetic and in memory. No settings or claim files exist.
$script:CFG=New-QmConfig;$script:CFG.layout='title';$script:CFG.display.latency=$false
$script:CFG_PATH=$null;$script:QM_CLAIMS_PATH=$null
$script:QM_S=@{
 sessionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';title='原生图文菜单视觉测试（示例数据）';tps=132.6;inFlight=$true
 recent=@(
  [pscustomobject]@{session_id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';title='原生图文菜单视觉测试（示例数据）'},
  [pscustomobject]@{session_id='11111111-2222-3333-4444-555555555555';title=('较长示例会话标题：检查省略号与完整提示文本。'*4)}
 )
}
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
function Save-MenuBitmap([Windows.Forms.ToolStrip]$menu,[string]$name){
 if($menu.Visible){throw 'Unexpected visible popup before rendering.'}
 $menu.AutoSize=$false;$menu.Size=$menu.GetPreferredSize([Drawing.Size]::Empty)
 $null=$menu.Handle;$menu.PerformLayout()
 if($menu.Width -lt 1 -or $menu.Height -lt 1){throw ('Invalid native menu size: '+$name)}
 foreach($item in $menu.Items){
  if($item.Available -and ($item.Bounds.Top -lt 0 -or $item.Bounds.Bottom -gt $menu.ClientSize.Height -or $item.Bounds.Left -lt 0 -or $item.Bounds.Right -gt $menu.ClientSize.Width)){throw ('Native menu contains clipped content: '+$name+' / '+$item.Text)}
 }
 $bitmap=[Drawing.Bitmap]::new($menu.Width,$menu.Height)
 try{
  $menu.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height))
  # Fail rather than silently accepting blank DrawToBitmap output on an unsupported host.
  $colors=New-Object 'System.Collections.Generic.HashSet[int]'
  for($y=0;$y -lt $bitmap.Height;$y+=2){for($x=0;$x -lt $bitmap.Width;$x+=2){[void]$colors.Add($bitmap.GetPixel($x,$y).ToArgb())}}
  if($colors.Count -lt 12){throw ('DrawToBitmap returned a blank/low-detail surface: '+$name)}
  if($menu.Visible){throw 'Rendering must not show a popup.'}
  $path=Join-Path $OutputDirectory ($name+'.png')
  $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
  Write-Output ("{0} ({1}x{2}, native DrawToBitmap)" -f $path,$bitmap.Width,$bitmap.Height)
 }finally{$bitmap.Dispose()}
}
foreach($skin in @('paper','graphite')){
 $script:CFG.skin=$skin;$menu=$null
 try{
  $menu=New-QmTrayMenu 1
  Save-MenuBitmap $menu ('menu-'+$skin)
  foreach($spec in @(@('停靠位置','layout'),@('显示内容','fields'),@('账户积分与领取','account'))){
   $items=@($menu.Items|Where-Object Text -eq $spec[0])
   if($items.Count -ne 1 -or !$items[0].HasDropDownItems){throw ('Missing native submenu: '+$spec[0])}
   Save-MenuBitmap $items[0].DropDown ('menu-'+$spec[1]+'-'+$skin)
  }
 }finally{if($menu){$menu.Dispose()}}
}
Write-Output 'Eight native PNGs rendered offline. Hidden DrawToBitmap excludes OS popup shadows, placement, tooltip windows, focus/keyboard interaction and monitor-DPI transitions.'
