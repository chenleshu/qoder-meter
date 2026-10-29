$ErrorActionPreference='Stop'
$r=Split-Path $PSScriptRoot -Parent
foreach($f in @('lib-interop','lib-data','lib-account','lib-ui','lib-config-layout','lib-settings')){. (Join-Path $r ('src\'+$f+'.ps1'))}
# Load actual command/view functions without executing the application's main loop or touching real settings.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $r 'src\meter.ps1'),[ref]$tokens,[ref]$errors)
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
$temp=Join-Path $env:TEMP ('qm-ui-'+[guid]::NewGuid());[void][IO.Directory]::CreateDirectory($temp)
$script:CFG_PATH=Join-Path $temp 'settings.json';$script:CFG=New-QmConfig
$script:QM_CLAIMS_PATH=Join-Path $temp 'claims.json';$script:QM_CLAIMS=$null
$script:ACCOUNT=@{Auth=$null;Usage=$null;Campaigns=$null;Running=$false;Error='';UsageAt=0L;CampAt=0L;NextTry=0L;LastFail=@{};Notified=$null;At=''}
$script:UI=@{win=(New-QmWindow);sig='';skin='paper';settings=$null;builds=0;tray=$null;dragging=$false}
$script:QM_SETTINGS_CONTROLS=$null
function Get-QmAppAppearance {return 'light'}
function Get-QmAutoStart {return $false}
function Update-QmPlacement {} # Pure menu/view tests must not move desktop windows.
$pass=0;$fail=0
function Check($value,$name){if($value){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
try{
 Reset-QmVisual
 Check ($script:UI.sig -eq (Get-QmVisualSig)) 'render signature is recorded, idle ticks do not rebuild'
 $script:QM_S.title='fixture';$script:QM_S.model='test';$script:QM_S.sessionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';$script:QM_S.toolCount=0;$script:QM_S.ctxStats=[pscustomobject]@{toolCalls=[pscustomobject]@{total=9000}};$script:QM_S.estOut=1234;$script:QM_S.exactOut=1240;$script:QM_S.credits=12.3
 Update-QmView
 Check ($script:UI_SEGS.tools.Text -eq '0') 'zero local tools never inherits another session snapshot'
 $tipLines=@($script:UI.border.ToolTip.Content -split "`n")
 Check ($tipLines.Count -ge 9 -and $tipLines[0] -eq '会话：fixture' -and $tipLines[1].StartsWith('模型：') -and $tipLines[6].StartsWith('请求：')) 'tooltip retains separate metric lines'
 Check ($script:UI.border.ToolTip.Content -match '输出 Token：1\.2k（精确 1240）') 'tooltip exposes the exact token count behind an abbreviated value'
 Check ($script:UI.border.ToolTip.Content -match '积分/请求：') 'tooltip includes per-request credits'
 $script:openedUrl='';$script:checksStarted=0
 function Start-Process {param($FilePath) $script:openedUrl=$FilePath}
 function Start-QmUpdateCheck {$script:checksStarted++}
 function Get-QmUpdateStatus {return [pscustomobject]@{State='available';Text='fixture';Url='https://github.com/chenleshu/qoder-meter/releases/tag/v1.4.1-win.1'}}
 Invoke-QmCommand 'release' 'https://github.com/chenleshu/qoder-meter/releases/tag/v1.4.1-win.1'
 Check ($script:openedUrl -eq 'https://github.com/chenleshu/qoder-meter/releases/tag/v1.4.1-win.1' -and $script:checksStarted -eq 0) 'explicit release action opens validated release without another check'
 $script:openedUrl='';Invoke-QmCommand 'release' 'https://example.com/invalid'
 Check (!$script:openedUrl) 'release action refuses a foreign URL'
 $menu=New-QmTrayMenu
 $position=@($menu.Items|Where-Object Text -eq '停靠位置')[0]
 $position.DropDownItems[1].PerformClick()
 Check ($script:CFG.layout -eq 'toolbar') 'actual menu handler changes layout without closure scope loss'
 $font=@($menu.Items|Where-Object Text -eq '字号')[0];$font.DropDownItems[2].PerformClick()
 Check ($script:CFG.fontSize -eq 'large') 'actual menu handler changes font'
 $fields=@($menu.Items|Where-Object Text -eq '显示内容')[0]
 @($fields.DropDownItems|Where-Object Text -eq 'Token')[0].PerformClick()
 Check (!$script:CFG.display.token) 'actual checkbox menu toggles token'
 $restored=Read-QmConfig
 if($restored.display.token -or $restored.layout -ne 'toolbar' -or $restored.fontSize -ne 'large'){Write-Output ($restored|ConvertTo-Json -Depth 5);Write-Output ([IO.File]::ReadAllText($script:CFG_PATH))}
 Check (!$restored.display.token -and $restored.layout -eq 'toolbar' -and $restored.fontSize -eq 'large') 'menu changes survive disk roundtrip'
 Invoke-QmCommand 'set' @{Key='follow';Value=$false}
 Check ($script:CFG.pinned -eq $script:QM_S.sessionId -and $script:QM_S.pinned -eq $script:QM_S.sessionId) 'uncheck follow pins current session'
 Invoke-QmCommand 'set' @{Key='follow';Value=$true}
 Check (!$script:CFG.pinned -and !$script:QM_S.pinned) 'restore follow clears pin immediately'
 $script:CFG.positions.toolbar=@(44,0);Invoke-QmCommand 'reset' $null
 Check ($script:CFG.positions.toolbar[0] -eq 0) 'reset clears current view offset'
 $menu.Dispose()
 # Execute the real narrow-region branch with window test doubles, never moving desktop windows.
 $realWindow=$script:UI.win
 $fake=[pscustomobject]@{Hidden=$false};$fake|Add-Member ScriptMethod Hide {$this.Hidden=$true}
 $indicator=[pscustomobject]@{Hidden=$false};$indicator|Add-Member ScriptMethod Hide {$this.Hidden=$true}
 $script:UI.win=$fake;$script:UI.indicator=$indicator;$script:UI.visible=$true;$script:CFG.layout='title'
 function Get-QoderWindowInfo {return [pscustomobject]@{Pid=$PID;Dpi=96;W=490;H=600;L=0;T=0;R=490;B=600}}
 function Test-QoderForeground {return $PID}
 function Get-QmWindowScale {return 1}
 $placementFn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-QmPlacement'},$false)[0]
 . ([scriptblock]::Create($placementFn.Extent.Text))
 try{Update-QmPlacement;Check ($fake.Hidden -and $indicator.Hidden -and !$script:UI.visible) 'zero-space docking hides both panel and old hover indicator'}finally{$script:UI.win=$realWindow;$script:UI.indicator=$null}
}finally{$script:UI.win.Close();Close-QmDb;Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Output "PASS=$pass FAIL=$fail";if($fail){exit 1}
