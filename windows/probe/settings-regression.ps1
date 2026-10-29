#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run with Windows PowerShell 5.1.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with -STA.'}
Write-Output ('PowerShell '+$PSVersionTable.PSVersion+' STA')
foreach($name in @('lib-config-layout','lib-ui','lib-lifecycle','lib-settings')){. (Join-Path $root ('src\'+$name+'.ps1'))}
# Load the real text formatter without initializing the database/data layer.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\lib-data.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Cannot parse lib-data.ps1.'}
$formatter=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Cut-QmText'},$false)
. ([scriptblock]::Create($formatter.Extent.Text))
$script:CFG_PATH=Join-Path ([IO.Path]::GetTempPath()) ('qm-settings-'+[guid]::NewGuid().ToString('N')+'.json')
$script:QM_LC_STATE_DIR=Split-Path $script:CFG_PATH -Parent
$script:QM_VERSION='1.4.0-win.2';$script:QM_SHUTDOWN=$false
$script:UI=@{settings=$null;skin='paper'};$script:CREDIT=@{Status=$null;Running=$false}
$script:Commands=[Collections.Generic.List[object]]::new()
# Only the command router is mocked. Real WPF events still dispatch their actual payloads.
# Never load meter.ps1 or start an update/credit request. All saves target this temporary file.
function Invoke-QmCommand([string]$command,$value){
 $script:Commands.Add([pscustomobject]@{Command=$command;Value=$value})
 if($command -eq 'set'){
  switch($value.Key){
   'pinned' {$script:CFG.pinned=[string]$value.Value}
   'follow' {if($value.Value){$script:CFG.pinned=''}else{$script:CFG.pinned=$script:QM_S.sessionId}}
   default {throw ('Unexpected settings command: '+$value.Key)}
  }
  Save-QmConfig
  Sync-QmSettings
 }elseif($command -notin @('update','release')){throw ('Unexpected command: '+$command)}
}
function Close-SettingsFixture {
 if($script:UI.settings){$script:UI.settings.Tag='dispose';$script:UI.settings.Close();$script:UI.settings=$null}
}
function New-SettingsFixture($recent=@(),[string]$pinned='',[string]$skin='paper'){
 Close-SettingsFixture
 $script:CFG=New-QmConfig;$script:CFG.skin=$skin;$script:CFG.pinned=$pinned
 $script:QM_S=[pscustomobject]@{recent=@($recent);sessionId=$pinned;title='Current session'}
 $script:QM_LC_UPDATE_STATUS=[pscustomobject]@{State='idle';Text='';Url=''}
 $script:Commands.Clear()
 $script:UI.settings=New-QmSettingsWindow
}
function Get-SettingsScroll($window){return @($window.Content.Children|Where-Object {$_ -is [Windows.Controls.ScrollViewer]})[0]}
function Measure-SettingsContent($window){
 $width=$window.Width-44;$height=$window.Height-44
 $window.Content.Measure([Windows.Size]::new($width,$height))
 $window.Content.Arrange([Windows.Rect]::new(0,0,$width,$height))
 $window.Content.UpdateLayout()
}
$id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$other='11111111-2222-3333-4444-555555555555'
$url='https://github.com/chenleshu/qoder-meter/releases/tag/v1.4.0-win.2'
try{
 New-SettingsFixture
 $window=$script:UI.settings;$pin=$script:QM_SETTINGS_CONTROLS['pinned']
 Check ($pin -is [Windows.Controls.ComboBox]) 'empty recents still create the pinned ComboBox'
 Check ($pin -and $pin.Items.Count -eq 0 -and !$pin.IsEnabled) 'empty pinned choices are disabled'
 Check ($window.Width -eq 450 -and $window.Height -eq 760 -and (Get-SettingsScroll $window)) 'settings retain the 450x760 scrollable window'
 $script:QM_S.recent=@([pscustomobject]@{session_id=$id;title='First session'})
 Sync-QmSettings
 $pin=$script:QM_SETTINGS_CONTROLS['pinned']
 Check ($pin -and $pin.Items.Count -eq 1 -and $pin.IsEnabled -and $pin.Items[0].Tag -eq $id) 'a newly discovered session appears without reopening settings'
 Check ([object]::ReferenceEquals($window,$script:UI.settings)) 'recent changes reuse the existing window'
 Check ($script:Commands.Count -eq 0) 'recent synchronization emits no commands'

 # Start populated so missing initial controls cannot mask the remaining regressions.
 New-SettingsFixture @([pscustomobject]@{session_id=$id;title='First session'}) $id
 Sync-QmSettings
 $pin=$script:QM_SETTINGS_CONTROLS['pinned'];$item=$pin.Items[0]
 Sync-QmSettings
 Check ([object]::ReferenceEquals($item,$pin.Items[0])) 'unchanged recent signature preserves ComboBoxItem identity'
 $script:QM_S.recent[0].title='Renamed session';Sync-QmSettings
 Check ($pin.Items[0].Content -ceq 'Renamed session') 'recent title changes refresh the displayed choice'
 $script:QM_S.recent[0].title='renamed session';Sync-QmSettings
 Check ($pin.Items[0].Content -ceq 'renamed session') 'case-only title changes refresh the displayed choice'
 Check ($pin.SelectedItem.Tag -eq $id -and $script:Commands.Count -eq 0) 'title refresh preserves the pin without command feedback'
 $follow=$script:QM_SETTINGS_CONTROLS['follow'];$follow.IsChecked=$true
 $follow.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
 Check (!$script:CFG.pinned -and $pin.SelectedIndex -eq -1) 'follow clears the existing pinned selection'
 $script:Commands.Clear();$pin.SelectedIndex=0
 Check ($script:Commands.Count -eq 1 -and $script:Commands[0].Command -eq 'set' -and $script:Commands[0].Value.Key -eq 'pinned' -and $script:Commands[0].Value.Value -eq $id) 'same-item reselect dispatches the real selection event'
 Check ((Read-QmConfig).pinned -eq $id) 'same-item reselect persists only to the temporary config'
 $script:Commands.Clear()
 $script:CFG.pinned=$id;$script:QM_S.sessionId=$id;$script:QM_S.title='Pinned outside recents'
 $script:QM_S.recent=@([pscustomobject]@{session_id=$other;title='Other session'});Sync-QmSettings
 Check ($pin.Items.Count -eq 2 -and $pin.SelectedItem.Tag -eq $id -and $pin.SelectedItem.Content -eq 'Pinned outside recents') 'current pinned session remains selectable outside recents'
 $script:QM_S.title='Pinned title changed';Sync-QmSettings
 Check ($pin.SelectedItem.Content -eq 'Pinned title changed') 'outside-recent pinned title also refreshes'
 $script:QM_S.recent=@();Sync-QmSettings
 Check ($pin.Items.Count -eq 1 -and $pin.IsEnabled -and $pin.SelectedItem.Tag -eq $id) 'available current pin survives an empty recent list'
 $script:CFG.pinned='';Sync-QmSettings
 Check ($pin.Items.Count -eq 0 -and !$pin.IsEnabled -and $pin.SelectedIndex -eq -1) 'follow removes the supplemental pin and disables empty choices'
 Check ($script:Commands.Count -eq 0) 'all programmatic pin changes remain suppressed'

 # Real release validation and status reader; no HTTP request is created.
 $release=[pscustomobject]@{tag_name='v1.4.0-win.2';html_url=$url;draft=$false;prerelease=$false;assets=@([pscustomobject]@{name='qoder-meter-windows-x64.zip';browser_download_url='https://github.com/chenleshu/qoder-meter/releases/download/v1.4.0-win.2/qoder-meter-windows-x64.zip'})}
 $script:QM_LC_UPDATE_STATUS=Resolve-QmUpdateRelease $release '1.4.0-win.1' 'x64';Sync-QmSettings
 $button=$script:QM_SETTINGS_CONTROLS['update']
 Check ($button.Content -eq '打开 Windows 发布页' -and $button.IsEnabled) 'available Windows release changes the update action label'
 Check ($button.Tag.Command -eq 'release' -and $button.Tag.Value -eq $url) 'available update carries the explicit validated release URL'
 $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
 Check ($script:Commands.Count -eq 1 -and $script:Commands[0].Command -eq 'release' -and $script:Commands[0].Value -eq $url) 'release button dispatches its explicit URL to the router'
 $script:QM_LC_UPDATE_STATUS=[pscustomobject]@{State='checking';Text='Checking again';Url=$url};Sync-QmSettings
 Check ($button.Content -eq '检查更新' -and !$button.IsEnabled -and $button.Tag.Command -eq 'update' -and $button.Tag.Value -eq '') 'rechecking disables update and clears a stale release route'
 Check ($script:QM_SETTINGS_CONTROLS['updateText'].Text -eq 'Checking again') 'update status text refreshes during recheck'
 foreach($state in @('idle','current','no-windows','error')){
  $script:QM_LC_UPDATE_STATUS=[pscustomobject]@{State=$state;Text=$state;Url=$url};Sync-QmSettings
  Check ($button.Content -eq '检查更新' -and $button.IsEnabled -and $button.Tag.Command -eq 'update' -and $button.Tag.Value -eq '') ("$state uses check-update rather than a stale release route")
 }
 foreach($badUrl in @('', ' ', 'http://github.com/chenleshu/qoder-meter/releases/tag/v2', 'https://example.com/release', 'https://github.com.evil.example/chenleshu/qoder-meter/releases/tag/v2', 'https://github.com/chenleshu/qoder-meter/releases/tag/v2?redirect=elsewhere')){
  $script:QM_LC_UPDATE_STATUS=[pscustomobject]@{State='available';Text='Invalid URL fixture';Url=$badUrl};Sync-QmSettings
  Check ($button.Content -eq '检查更新' -and $button.Tag.Command -eq 'update' -and $button.Tag.Value -eq '') ('invalid or empty release URL falls back to update: ['+$badUrl+']')
 }

 # The real resolver may read the system theme, but never changes it.
 $resolved=Resolve-QmSkin 'auto'
 New-SettingsFixture @([pscustomobject]@{session_id=$id;title='Session'}) $id $resolved
 Sync-QmSettings
 $window=$script:UI.settings;$window.Left=140;$window.Top=90;$window.Width=510;$window.Height=610
 Measure-SettingsContent $window
 $scroll=Get-SettingsScroll $window;$scroll.ScrollToVerticalOffset(140);$scroll.UpdateLayout()
 $offset=$scroll.VerticalOffset
 Check ($offset -gt 0) 'hidden WPF content can exercise a nonzero scroll offset'
 $script:CFG.skin='auto';Sync-QmSettings
 Check ([object]::ReferenceEquals($window,$script:UI.settings)) 'different skin option with the same resolved palette does not rebuild'
 Check ($script:QM_SETTINGS_CONTROLS['skin'].SelectedItem.Tag -eq 'auto') 'same-palette skin choice still synchronizes'
 $script:ClosedCount=0;$window.Add_Closed({$script:ClosedCount++})
 $nextSkin=if($resolved -eq 'paper'){'graphite'}else{'paper'}
 $script:CFG.skin=$nextSkin;Sync-QmSettings
 $replacement=$script:UI.settings
 Check (![object]::ReferenceEquals($window,$replacement) -and $script:ClosedCount -eq 1 -and $window.Tag -eq 'dispose') 'resolved palette change disposes and rebuilds the old window'
 Check ($replacement.Background.Color -eq (Get-QmBrush $script:QM_SKINS[$nextSkin].bg).Color -and $script:QM_SETTINGS_CONTROLS['follow'].Foreground.Color -eq (Get-QmBrush $script:QM_SKINS[$nextSkin].text).Color) 'rebuilt background and existing controls use the new palette'
 Check (!$replacement.IsVisible -and !$replacement.IsActive -and [Windows.Interop.WindowInteropHelper]::new($replacement).Handle -eq [IntPtr]::Zero) 'hidden skin refresh never shows or activates a native window'
 Check ($replacement.Left -eq 140 -and $replacement.Top -eq 90 -and $replacement.Width -eq 510 -and $replacement.Height -eq 610) 'hidden rebuild preserves window position and dimensions'
 Measure-SettingsContent $replacement
 Check ([math]::Abs((Get-SettingsScroll $replacement).VerticalOffset-$offset) -lt 1) 'hidden rebuild preserves the content scroll offset'
 Sync-QmSettings
 Check ([object]::ReferenceEquals($replacement,$script:UI.settings)) 'unchanged resolved palette does not rebuild on the next sync'
 $keys=@('layout','fontSize','skin','pinned','follow','autostart','bottomAutoHide','closeWithQoder','creditAuto','creditStatus','claim','update','updateText')+@($script:CFG.display.Keys|ForEach-Object {'display.'+$_})
 Check (@($keys|Where-Object {!$script:QM_SETTINGS_CONTROLS.ContainsKey($_)}).Count -eq 0) 'palette rebuild retains all existing settings controls'
 Check ($script:QM_SETTINGS_CONTROLS['pinned'].SelectedItem.Tag -eq $id -and $script:Commands.Count -eq 0 -and !$script:QM_SETTINGS_BUILDING) 'palette rebuild restores selection with event suppression released'
 Check ($null -eq $script:QM_LC_UPDATE_REQUEST) 'probe created no network update request'
}finally{
 Close-SettingsFixture
 foreach($path in @($script:CFG_PATH,($script:CFG_PATH+'.tmp'))){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
}
Write-Output "PASS=$pass FAIL=$fail"
if($fail){exit 1}
