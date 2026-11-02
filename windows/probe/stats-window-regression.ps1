#requires -Version 5.1
# Offline Windows statistics-window regression. No network, account API, or real claim.
$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path $PSScriptRoot -Parent
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run with Windows PowerShell 5.1.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this probe in an STA PowerShell process.'}
$inv=[Globalization.CultureInfo]::InvariantCulture
$script:pass=0;$script:fail=0
function Check($ok,[string]$name){if($ok){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
function Near([double]$a,[double]$b){return [math]::Abs($a-$b) -lt 0.000001}
function Click-Control($control){$control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
function Reset-CacheState {$script:QM_STATS_CACHE=$null;$script:QM_STATS_CACHE_LOADED=$false;$script:QM_STATS_CACHE_PATH_LOADED='';$script:QM_STATS_ERROR=''}
function Ts([datetime]$local){return ([DateTimeOffset]::new($local)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
function Day-Key([int]$offset){return [datetime]::Today.AddDays(-$offset).ToString('yyyy-MM-dd',$inv)}
function Expected-RangeText([datetime]$start,[datetime]$end,[int]$active){
 $left=$(if($start.Year -eq $end.Year){$start.ToString('MM-dd',$inv)}else{$start.ToString('yyyy-MM-dd',$inv)})
 $right=$(if($start.Year -eq $end.Year){$end.ToString('MM-dd',$inv)}else{$end.ToString('yyyy-MM-dd',$inv)})
 return $left+' ~ '+$right+' · 活跃 '+$active+' 天'
}
# Stable lookups by Name/Tag instead of fragile Children indexes.
function Get-QmChildren($node){
 if($node -is [Windows.Controls.Panel]){return @($node.Children)}
 if($node -is [Windows.Controls.Decorator]){return @($node.Child)}
 if($node -is [Windows.Controls.ScrollViewer]){return @($node.Content)}
 if($node -is [Windows.Controls.ContentControl]){return @($node.Content)}
 return @()
}
function Get-QmNamed($root,[string]$name){
 if($null -eq $root){return $null}
 if($root -is [Windows.FrameworkElement] -and [string]$root.Name -eq $name){return $root}
 foreach($kid in @(Get-QmChildren $root)){
  if($null -eq $kid){continue}
  $found=Get-QmNamed $kid $name
  if($found){return $found}
 }
 return $null
}
function Get-QmTagged($root,[string]$tag){
 $list=New-Object System.Collections.Generic.List[object]
 $walk={
  param($node)
  if($null -eq $node){return}
  if($node -is [Windows.FrameworkElement] -and [string]$node.Tag -eq $tag){[void]$list.Add($node)}
  foreach($kid in @(Get-QmChildren $node)){if($kid){& $walk $kid}}
 }
 & $walk $root
 return ,$list
}
function First-Tagged($root,[string]$tag){$found=@(Get-QmTagged $root $tag);if($found.Count){return $found[0]};return $null}
function Row-Text($row,[string]$tag){$found=First-Tagged $row $tag;if($found){return [string]$found.Text};return ''}
function Share-Of($share){return [double]$share.Child.ColumnDefinitions[0].Width.Value}
function Bar-Of($slot){return First-Tagged $slot 'QmStatsTrendBar'}
function Write-Cache([string]$dir,[hashtable]$days,[long]$rows){
 $document=[ordered]@{version=1;at=(QmNowMs);rows=$rows;days=[ordered]@{}}
 foreach($key in $days.Keys){
  $day=$days[$key]
  $models=[ordered]@{}
  foreach($name in @($day.models.Keys)){
   $model=$day.models[$name]
   $models[$name]=[ordered]@{credits=[double]$model.credits;tokens=[double]$model.tokens;requests=[long]$model.requests;estimated=[bool]$model.estimated}
  }
  $document.days[$key]=[ordered]@{credits=[double]$day.credits;tokens=[double]$day.tokens;requests=[long]$day.requests;estimated=[bool]$day.estimated;models=$models}
 }
 [void][IO.Directory]::CreateDirectory($dir)
 [IO.File]::WriteAllText((Join-Path $dir 'stats-cache.json'),(ConvertTo-Json -InputObject $document -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
}
function New-DayBucket([double]$credits,[double]$tokens,[long]$requests,[bool]$estimated,[string]$model){
 return @{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated;models=@{$model=@{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated}}}
}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('qm-stats-win-'+[guid]::NewGuid().ToString('N'))
$projects=Join-Path $tempRoot 'projects'
$settingsDir=Join-Path $tempRoot 'settings'
$emptyProjects=Join-Path $tempRoot 'empty-projects'
$emptySettings=Join-Path $tempRoot 'empty-settings'
$utf8=[Text.UTF8Encoding]::new($false)
try{
 . (Join-Path $root 'src\lib-interop.ps1')
 try{if(![QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))){[void][QoderMeter.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-1))}}catch{}
 . (Join-Path $root 'src\lib-data.ps1')
 foreach($dir in @($projects,$settingsDir,$emptyProjects,$emptySettings)){[void][IO.Directory]::CreateDirectory($dir)}
 $script:QM_PROJECTS=$projects
 $script:QM_SETTINGSD=$settingsDir
 . (Join-Path $root 'src\lib-config-layout.ps1')
 . (Join-Path $root 'src\lib-ui.ps1')
 . (Join-Path $root 'src\lib-stats.ps1')
 function Get-QmScale {return 1.0}
 $script:Commands=[Collections.Generic.List[object]]::new()
 function Invoke-QmCommand([string]$command,$value){
  $script:Commands.Add([pscustomobject]@{Command=$command;Value=$value})
  switch($command){
   'statsRange'{Set-QmStatsRange ([string]$value)}
   'statsGroup'{Set-QmStatsGroup ([string]$value)}
   'statsTab'{Set-QmStatsTab ([string]$value)}
   'statsPage'{Move-QmStatsPage ([int]$value)}
   'statsRefresh'{Refresh-QmStatsWindow}
   default{throw ('Unexpected statistics command: '+$command)}
  }
 }
 $script:CFG=New-QmConfig
 $script:CFG.skin='paper'
 $script:CFG_PATH=Join-Path $tempRoot 'config\settings.json'
 $script:UI=@{statsWin=$null}
 $script:QM_SHUTDOWN=$false
 $today=[datetime]::Today
 $records=@()
 for($i=0;$i -lt 7;$i++){
  $records+=@{type='assistant';timestamp=(Ts $today.AddDays(-$i).AddHours(12));message=@{model=$(if($i%2){'dfmodel'}else{'qmodel'});usage=@{input_tokens=(100+$i);output_tokens=20;credits=(1.25+$i);request_id=('r'+$i)};content=@(@{type='text';text='中文记录'})}}
 }
 $lines=@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 12 -Compress})
 [IO.File]::WriteAllText((Join-Path $projects 'chat.jsonl'),($lines -join "`n"),$utf8)
 [void](Get-QmStatsCache -Force)

 $window=New-QmStatsWindow
 $script:UI.statsWin=$window
 Sync-QmStatsWindow
 $refs=$script:QM_STATS_REFS
 $paper=$script:QM_SKINS['paper']
 Check ($window.Title -eq 'Qoder Meter 用量统计' -and $window.Width -eq 640 -and $window.Height -eq 760 -and $window.MinWidth -eq 520 -and $window.MinHeight -eq 600) 'statistics window opens as a 640x760 dashboard with a 520x600 floor'
 Check ($window.ResizeMode -eq 'CanResize' -and !$window.ShowInTaskbar -and $window.WindowStartupLocation -eq 'CenterScreen') 'statistics window stays out of the taskbar and centers itself'
 Check ($window.Resources['QmResolvedSkin'] -eq 'paper' -and $window.Background.Color -eq (Get-QmBrush $paper.bg).Color -and $null -ne $window.FindResource('QmGhostButton') -and $null -ne $window.FindResource('QmPrimaryButton')) 'paper theme and button styles apply to the window'
 Check (!$window.IsVisible -and [Windows.Interop.WindowInteropHelper]::new($window).Handle -eq [IntPtr]::Zero) 'window is fully constructed without being shown'
 Check ($refs.Titles.Children[0].Text -eq '用量统计' -and $refs.Titles.Children[1].Text -eq '本地日志 · 趋势图与自动摘要') 'header shows the localized title and the dashboard subtitle'
 $logo=Get-QmNamed $window 'QmStatsLogo'
 Check ($logo -and $logo.Child.Text -eq ([string][char]0xE9D9) -and $logo.Child.FontFamily.Source -eq 'Segoe MDL2 Assets') 'header pairs the chart glyph with the title block'
 Check ($refs.HeaderHint.Text -eq '只读本机') 'header states the local-only scope'

 Check (($refs.RangeButtons.Keys -join '|') -eq '7d|30d|month|year' -and ($refs.RangeButtons.Values.Content -join '|') -eq '7 天|近 30 天|本月|近一年') 'four range choices keep their intended labels and order'
 Check (($refs.GroupButtons.Keys -join '|') -eq 'day|week|month' -and ($refs.GroupButtons.Values.Content -join '|') -eq '按日|按周|按月') 'three grouping choices keep their intended labels and order'
 Check (($refs.TabButtons.Keys -join '|') -eq 'overview|detail' -and ($refs.TabButtons.Values.Content -join '|') -eq '总览|明细') 'overview and detail tabs are exposed in order'
 $tabRoutes=@($refs.TabButtons.Values|Where-Object {[string]$_.Tag.Command -eq 'statsTab'})
 Check ($tabRoutes.Count -eq 2 -and ($tabRoutes|ForEach-Object {[string]$_.Tag.Value}) -join '|' -eq 'overview|detail') 'both tabs route through the statsTab command'
 Check ($refs.TabButtons['overview'].Background.Color -eq (Get-QmBrush $paper.greenTint).Color -and $refs.TabButtons['overview'].Foreground.Color -eq (Get-QmBrush $paper.green).Color -and $refs.TabButtons['detail'].Background.Color -eq (Get-QmBrush $paper.grayTint).Color) 'the overview tab starts selected'
 Check ($refs.RangeButtons['7d'].Background.Color -eq (Get-QmBrush $paper.greenTint).Color -and $refs.RangeButtons['30d'].Background.Color -eq (Get-QmBrush $paper.grayTint).Color) 'selected range is tinted and unselected ranges stay quiet'
 Check ($refs.GroupButtons['day'].Background.Color -eq (Get-QmBrush $paper.greenTint).Color -and $refs.GroupButtons['week'].Background.Color -eq (Get-QmBrush $paper.grayTint).Color) 'group chips mirror the selected range state'

 # Summary cards --------------------------------------------------------
 $cardNames=@('积分','Token','请求','活跃天')
 $cardKeys=@('credits','tokens','requests','days')
 $cardColors=@($paper.gold,$paper.blue,$paper.green,$paper.text)
 $okCards=$true;$okGlyph=$true
 for($i=0;$i -lt 4;$i++){
  $card=$refs.Summary[$cardKeys[$i]]
  if(-not $card -or $card.Label.Text -ne $cardNames[$i] -or $card.Value.FontSize -lt 20 -or $card.Value.Foreground.Color -ne (Get-QmBrush $cardColors[$i]).Color){$okCards=$false}
  if(-not (First-Tagged $card.Root 'QmStatsBadge')){$okGlyph=$false}
 }
 Check $okCards 'four summary cards carry their label, colour and large value'
 Check $okGlyph 'every summary card owns a Segoe MDL2 glyph badge'
 Check ($refs.Summary['credits'].Value.Text -eq '29.75' -and $refs.Summary['tokens'].Value.Text -eq '861' -and $refs.Summary['requests'].Value.Text -eq '7' -and $refs.Summary['days'].Value.Text -eq '7') 'summary cards total the seven-day fixture exactly'
 Check ($refs.RangeText.Text -eq (Expected-RangeText $today.AddDays(-6) $today 7) -and $refs.Updated.Text -match '^更新 \d{2}:\d{2}$') 'range text and refresh clock describe the current scan'

 # Trend chart ----------------------------------------------------------
 $chart=Get-QmStatsChartData (Get-QmStatsData '7d') 'day'
 Check ($refs.TrendBars.Children.Count -eq 7 -and $refs.TrendLabels.Children.Count -eq 7 -and @($chart.Bars).Count -eq 7) 'trend shows one bar per active day with a matching label'
 $keys=@($chart.Bars|ForEach-Object {[string]$_.Key})
 Check ($keys[0] -eq (Day-Key 6) -and $keys[-1] -eq (Day-Key 0)) 'trend bars are ordered oldest to newest'
 $heights=@($refs.TrendBars.Children|ForEach-Object{[double](Bar-Of $_).Height})
 $expected=@(foreach($bar in @($chart.Bars)){[math]::Max(2.0,[math]::Round(([double]$bar.Ratio*$script:QM_STATS_CHART_HEIGHT),1))})
 Check ($heights[0] -eq 104.0 -and (Near $heights[-1] 17.9) -and (@(Compare-Object -ReferenceObject $expected -DifferenceObject $heights).Count -eq 0)) 'bar heights equal the credits-normalized geometry with the peak filling the plot'
 Check ($refs.TrendCaption.Text -eq '展示最近 7 天 · 峰值 7.25 积分 · 合计 29.75 积分') 'trend caption names the span, peak and total'
 Check ($refs.TrendEmpty.Visibility -eq 'Collapsed' -and $refs.TrendPlot.Visibility -eq 'Visible' -and $refs.TrendLabels.Visibility -eq 'Visible') 'a populated trend hides the empty state'
 $barTips=@($refs.TrendBars.Children|ForEach-Object {[string](Bar-Of $_).ToolTip})
 Check ($barTips[-1] -eq ((Day-Key 0)+'（今天）'+"`n1.25 积分 · 120 Token · 1 请求 · 1 天有记录`nQwen3.7-Plus 1.25分/120")) 'bar tooltips carry the full period, metrics, active days and models'
 $todayBar=Bar-Of $refs.TrendBars.Children[-1]
 Check ([Windows.Controls.ToolTipService]::GetInitialShowDelay($todayBar) -eq 450) 'bar tooltips reuse the compact reveal delay'

 # Model mix ------------------------------------------------------------
 Check ($refs.ModelCount.Text -eq '共 2 个模型 · 按积分占比' -and $refs.ModelRows.Children.Count -eq 2 -and $refs.ModelEmpty.Visibility -eq 'Collapsed') 'model card ranks two models and states the share basis'
 $modelNames=@($refs.ModelRows.Children|ForEach-Object {Row-Text $_ 'QmStatsModelName'})
 Check ($modelNames[0] -eq 'Qwen3.7-Plus' -and $modelNames[1] -eq 'DeepSeek-V4-Flash') 'model rows keep the credit-ranked order'
 $modelCredits=@($refs.ModelRows.Children|ForEach-Object {Row-Text $_ 'QmStatsModelCredits'})
 $modelTokens=@($refs.ModelRows.Children|ForEach-Object {Row-Text $_ 'QmStatsModelTokens'})
 Check ($modelCredits[0] -eq '17.00' -and $modelTokens[0] -eq '492' -and $modelCredits[1] -eq '12.75' -and $modelTokens[1] -eq '369') 'model rows show credits and tokens alongside the share'
 $shares=@($refs.ModelRows.Children|ForEach-Object {Share-Of (First-Tagged $_ 'QmStatsShare')})
 Check ((Near $shares[0] (17.0/29.75)) -and (Near $shares[1] (12.75/29.75)) -and (Near ($shares[0]+$shares[1]) 1.0)) 'share plates are proportional to credits'
 $percentTexts=@($refs.ModelRows.Children|ForEach-Object {Row-Text $_ 'QmStatsModelPercent'})
 Check ($percentTexts[0] -eq '  57%' -and $percentTexts[1] -eq '  43%') 'share percentages render beside each model'
 Check (-not (First-Tagged $refs.ModelRows.Children[0] 'QmStatsModelApprox')) 'exact models are not marked as estimated'

 # Auto summary ---------------------------------------------------------
 $insightTitles=@($refs.InsightRows.Children|ForEach-Object {Row-Text $_ 'QmStatsInsightTitle'})
 Check (($insightTitles -join '|') -eq '今天|近 7 天|本月|全部') 'auto summary always analyses today, seven days, month and all'
 Check ((Row-Text $refs.InsightRows.Children[0] 'QmStatsInsightMetrics') -eq '1.25 积分 · 120 Token · 1 请求') 'today insight reports credits, tokens and requests'
 Check ((Row-Text $refs.InsightRows.Children[0] 'QmStatsInsightSummary') -eq '活跃 1 天 · 较昨日 -44% · 主力 Qwen3.7-Plus') 'today insight compares against the previous equal-length window'
 Check ((Row-Text $refs.InsightRows.Children[1] 'QmStatsInsightSummary') -eq '活跃 7 天 · 较上 7 天 新增 · 主力 Qwen3.7-Plus') 'a zero previous window reports growth without dividing by zero'
 Check ((Row-Text $refs.InsightRows.Children[3] 'QmStatsInsightSummary') -eq '活跃 7 天 · 较上一周期 新增 · 主力 Qwen3.7-Plus · 日均 4.25 积分') 'the all-time row adds the daily average when days exist'
 $delta0=First-Tagged $refs.InsightRows.Children[0] 'QmStatsInsightDelta'
 $delta1=First-Tagged $refs.InsightRows.Children[1] 'QmStatsInsightDelta'
 Check ($delta0.Text -eq '-44%' -and $delta1.Text -eq '新增') 'delta badges summarise the period comparison'
 Check ($delta0.Foreground.Color -eq (Get-QmBrush $paper.red).Color) 'a declining period uses the warning colour'
 Check ($refs.InsightNote.Text -eq '对比上一同长周期 · 不使用 AI') 'auto summary states that it never calls a model'

 # Tabs, detail list and pagination -------------------------------------
 Check ($refs.Overview.Visibility -eq 'Visible' -and $refs.Detail.Visibility -eq 'Collapsed') 'overview is the default view'
 Check ($refs.PeriodTitle.Text -eq '按日明细' -and $refs.PeriodNote.Text -eq '共 7 天') 'detail heading counts the grouped periods'
 Check ($refs.PeriodList.Children.Count -eq 6 -and $refs.Nav.Visibility -eq 'Visible' -and $refs.PageText.Text -eq '第 1 / 2 页' -and !$refs.Prev.IsEnabled -and $refs.Next.IsEnabled) 'seven periods paginate six rows at a time'
 $first=$refs.PeriodList.Children[0]
 Check ((Row-Text $first 'QmStatsPeriodLabel') -eq '今天' -and (Row-Text $first 'QmStatsPeriodCredits') -eq '1.25 积分' -and (Row-Text $first 'QmStatsPeriodTokens') -eq ' · 120 tok' -and (Row-Text $first 'QmStatsPeriodTail') -eq ' · 1 请求') 'detail rows format label, credits, tokens and requests'
 Check ((Row-Text $first 'QmStatsPeriodModels') -eq 'Qwen3.7-Plus 1.25分/120') 'detail rows preview their top model'
 Check (Near (Share-Of (First-Tagged $first 'QmStatsPeriodBar')) (1.25/7.25)) 'detail mini bars normalize against the busiest period'
 Check ($first.ToolTip -eq ((Day-Key 0)+"`n1.25 积分 · 120 Token · 1 请求") -and [Windows.Controls.ToolTipService]::GetInitialShowDelay($first) -eq 450) 'period tooltip keeps the full day and metric line'
 Check ($first.Background.Color -eq (Get-QmBrush $paper.track).Color) 'period rows use the quiet track surface'
 Check ($refs.Refresh.Content -eq '刷新' -and $refs.Refresh.Tag.Command -eq 'statsRefresh' -and $refs.RangeButtons['7d'].Height -eq 26) 'refresh and range chips keep the compact control height'

 Click-Control $refs.Next
 Check ($refs.PageText.Text -eq '第 2 / 2 页' -and $refs.PeriodList.Children.Count -eq 1 -and $refs.Prev.IsEnabled -and !$refs.Next.IsEnabled) 'next page shows the remaining day'
 Click-Control $refs.TabButtons['detail']
 Check ($refs.Overview.Visibility -eq 'Collapsed' -and $refs.Detail.Visibility -eq 'Visible' -and $refs.PageText.Text -eq '第 2 / 2 页' -and (Read-QmConfig).statsTab -eq 'detail') 'switching to detail reveals the list and persists the tab'
 Check ($script:Commands[$script:Commands.Count-1].Command -eq 'statsTab' -and $script:Commands[$script:Commands.Count-1].Value -eq 'detail') 'the tab click routes through Invoke-QmCommand'
 Click-Control $refs.TabButtons['overview']
 Check ($refs.Overview.Visibility -eq 'Visible' -and $refs.Detail.Visibility -eq 'Collapsed' -and $refs.PageText.Text -eq '第 2 / 2 页' -and $refs.PeriodList.Children.Count -eq 1) 'returning to overview keeps pagination untouched'
 Click-Control $refs.TabButtons['detail']
 Click-Control $refs.Prev
 Check ($refs.PageText.Text -eq '第 1 / 2 页' -and $refs.PeriodList.Children.Count -eq 6) 'previous page returns to six rows'
 Click-Control $refs.TabButtons['overview']

 # Range, grouping and refresh -----------------------------------------
 Click-Control $refs.RangeButtons['30d']
 Check ($refs.RangeButtons['30d'].Background.Color -eq (Get-QmBrush $paper.greenTint).Color -and $refs.RangeButtons['7d'].Background.Color -eq (Get-QmBrush $paper.grayTint).Color) 'range click moves the selected tint'
 Check ($refs.RangeText.Text -eq (Expected-RangeText $today.AddDays(-29) $today 7) -and (Read-QmConfig).statsRange -eq '30d' -and $script:Commands[$script:Commands.Count-1].Command -eq 'statsRange') 'range click updates the window and persists the preference'
 Check ($refs.Summary['credits'].Value.Text -eq '29.75' -and $refs.Summary['tokens'].Value.Text -eq '861' -and $refs.Summary['requests'].Value.Text -eq '7') 'wider range keeps the same fixture totals'
 Check ((Row-Text $refs.InsightRows.Children[1] 'QmStatsInsightMetrics') -eq '29.75 积分 · 861 Token · 7 请求') 'auto summary ignores the selected range'
 $data30=Get-QmStatsData '30d'
 $weeks=@(Get-QmStatsPeriods $data30 'week')
 Click-Control $refs.GroupButtons['week']
 Check ($refs.PeriodTitle.Text -eq '按周明细' -and $refs.PeriodNote.Text -eq ('共 '+$weeks.Count+' 周') -and $refs.PeriodList.Children.Count -eq $weeks.Count -and $refs.Nav.Visibility -eq 'Collapsed') 'weekly grouping collapses a short list without pagination'
 Check ($refs.GroupButtons['week'].Background.Color -eq (Get-QmBrush $paper.greenTint).Color -and (Read-QmConfig).statsGroup -eq 'week') 'weekly click persists and restyles the grouping chips'
 Check ($refs.TrendBars.Children.Count -eq $weeks.Count) 'weekly trend aggregates the same periods'
 $weekTip=[string](Bar-Of $refs.TrendBars.Children[-1]).ToolTip
 $weekLines=@($weekTip -split "`n")
 $curWeek=Get-QmStatsWeekKey (Day-Key 0)
 $weekStart=Get-QmStatsDayDate $curWeek
 $weekHead=$weekStart.ToString('yyyy-MM-dd',$inv)+' ~ '+$weekStart.AddDays(6).ToString('yyyy-MM-dd',$inv)
 Check ($weekLines.Count -eq 3 -and $weekLines[0].StartsWith($weekHead) -and $weekLines[0].Length -gt $weekHead.Length -and $weekLines[1] -match '天有记录' -and $weekLines[2] -match '/') 'weekly bars label their fixed date span and active days'
 Check (First-Tagged $refs.PeriodList 'QmStatsPeriodRow') 'weekly rows keep their stable tag'
 Check ((Row-Text $refs.PeriodList.Children[0] 'QmStatsPeriodLabel') -match '^(本周|上周|\d{2}-\d{2} ~ \d{2}-\d{2})$' -and (Row-Text $refs.PeriodList.Children[0] 'QmStatsPeriodTail') -match '^ · \d+ 天$' -and $refs.PeriodList.Children[0].ToolTip -match '天有记录') 'weekly rows use week labels, active-day tails, and full tooltips'
 $months=@(Get-QmStatsPeriods $data30 'month')
 Click-Control $refs.GroupButtons['month']
 Check ($refs.PeriodTitle.Text -eq '按月明细' -and $refs.PeriodNote.Text -eq ('共 '+$months.Count+' 个月') -and $refs.PeriodList.Children.Count -eq $months.Count -and (Read-QmConfig).statsGroup -eq 'month') 'monthly grouping aggregates the same fixture'
 $monthLabel=Row-Text $refs.PeriodList.Children[0] 'QmStatsPeriodLabel'
 Check ($monthLabel -match '^(本月|上月|\d{1,2} 月|\d{4}年\d{1,2}月)$' -and $refs.TrendLabels.Children[0].Text -match '^(本月|上月|\d{1,2} 月|\d{4}年\d{1,2}月)$') 'monthly rows and bars reuse the month wording'
 Click-Control $refs.GroupButtons['day']
 Click-Control $refs.RangeButtons['7d']
 Check ((Read-QmConfig).statsRange -eq '7d' -and $refs.TrendBars.Children.Count -eq 7 -and $refs.PeriodNote.Text -eq '共 7 天') 'returning to seven days restores the default dashboard'
 $beforeRefresh=$script:Commands.Count
 Click-Control $refs.Refresh
 Check ($script:Commands.Count -eq $beforeRefresh+1 -and $script:Commands[$script:Commands.Count-1].Command -eq 'statsRefresh' -and $refs.PageText.Text -eq '第 1 / 2 页' -and (Get-QmStatsCache).rows -eq 7) 'refresh rescans, keeps the cache honest, and resets the page'
 Click-Control $refs.Next
 Check ($refs.PageText.Text -eq '第 2 / 2 页' -and $refs.PeriodList.Children.Count -eq 1) 'pagination still advances after a refresh'
 $beforeInvalid=$script:Commands.Count
 Set-QmStatsRange '90d';Set-QmStatsGroup 'quarter';Set-QmStatsTab 'nope'
 Check ($script:Commands.Count -eq $beforeInvalid -and (Read-QmConfig).statsRange -eq '7d' -and (Read-QmConfig).statsGroup -eq 'day' -and (Read-QmConfig).statsTab -eq 'overview') 'invalid range, grouping and tab values are ignored without saving'
 Check ($refs.Overview.Visibility -eq 'Visible' -and $refs.Detail.Visibility -eq 'Collapsed' -and $refs.PeriodTitle.Text -eq '按日明细') 'an invalid tab leaves the overview view and daily rows'

 # Twelve period cap, estimation and token-only shares ------------------
 $wideDays=@{}
 for($i=0;$i -lt 20;$i++){
  $wideDays[(Day-Key $i)]=(New-DayBucket ([double](10+$i)) ([double](50+$i)) ([long]2) ($i -lt 10) $(if($i%2){'kmodel_latest'}else{'qmodel'}))
 }
 $tokenDays=@{}
 $tokenDays[(Day-Key 0)]=(New-DayBucket 0.0 40.0 1L $true 'lite')
 $wideSettings=Join-Path $tempRoot 'wide-settings'
 $tokenSettings=Join-Path $tempRoot 'token-settings'
 Write-Cache $wideSettings $wideDays 40
 Write-Cache $tokenSettings $tokenDays 1
 $script:QM_SETTINGSD=$wideSettings;Reset-CacheState;[void](Get-QmStatsCache)
 Click-Control $refs.RangeButtons['30d']
 Check ($refs.TrendBars.Children.Count -eq 12 -and $refs.TrendCaption.Text -like '展示最近 12 天*') 'the trend never renders more than twelve periods'
 $cappedKeys=@((Get-QmStatsChartData (Get-QmStatsData '30d') 'day').Bars|ForEach-Object {[string]$_.Key})
 Check ($cappedKeys.Count -eq 12 -and $cappedKeys[0] -eq (Day-Key 11) -and $cappedKeys[-1] -eq (Day-Key 0)) 'the capped series keeps the newest twelve in ascending order'
 Check ($refs.Summary['tokens'].Value.Text -eq '≈ 1.2k' -and $refs.Summary['credits'].Value.Text -eq '390' -and $refs.Summary['days'].Value.Text -eq '20') 'estimated and larger fixtures still total correctly'
 Check ($refs.ModelRows.Children.Count -eq 2 -and $refs.ModelCount.Text -eq '共 2 个模型 · 按积分占比') 'model ranking is unchanged by estimation'
 Check (-not (First-Tagged $refs.ModelRows.Children[0] 'QmStatsModelApprox')) 'model names do not duplicate the token estimation marker'
 $estimatedTokens=Row-Text $refs.ModelRows.Children[0] 'QmStatsModelTokens'
 Check ($estimatedTokens -like '≈ *' -and (Row-Text $refs.ModelRows.Children[0] 'QmStatsModelPercent') -notmatch '≈') 'estimated models mark only their token value'
 Click-Control $refs.TabButtons['detail']
 Click-Control $refs.Next
 Check ($refs.PageText.Text -eq '第 2 / 4 页' -and $refs.PeriodList.Children.Count -eq 6) 'twenty periods paginate six rows per page'
 Click-Control $refs.TabButtons['overview']
 Click-Control $refs.Next
 Check ($refs.PageText.Text -eq '第 3 / 4 页' -and $refs.Overview.Visibility -eq 'Visible' -and $refs.Detail.Visibility -eq 'Collapsed') 'pagination keeps moving while the overview is shown'
 $script:QM_SETTINGSD=$tokenSettings;Reset-CacheState;[void](Get-QmStatsCache)
 Sync-QmStatsWindow
 Check ($refs.Summary['credits'].Value.Text -eq '0.00' -and $refs.ModelCount.Text -eq '共 1 个模型 · 按 Token 占比（积分合计为 0）') 'zero credits fall back to token shares instead of an empty card'
 $tokenShare=Share-Of (First-Tagged $refs.ModelRows.Children[0] 'QmStatsShare')
 Check ($tokenShare -eq 1.0 -and (Row-Text $refs.ModelRows.Children[0] 'QmStatsModelPercent') -eq '  100%') 'the token share plate fills the whole row'
 $script:CFG.statsTab='detail';Sync-QmStatsWindow
 Check ($refs.Detail.Visibility -eq 'Visible' -and $refs.PeriodList.Children.Count -eq 1) 'token-share fixtures also render in the detail view'
 $script:CFG.statsTab='overview';Sync-QmStatsWindow

 # ---------------------------------------------------------------- graphite palette
 $script:QM_SETTINGSD=$wideSettings;Reset-CacheState;[void](Get-QmStatsCache)
 $script:CFG.skin='graphite'
 $graphite=New-QmStatsWindow
 $script:UI.statsWin=$graphite
 Sync-QmStatsWindow
 $graphiteRefs=$script:QM_STATS_REFS;$graphiteSkin=$script:QM_SKINS['graphite']
 Check ($graphite.Resources['QmResolvedSkin'] -eq 'graphite' -and $graphite.Background.Color -eq (Get-QmBrush $graphiteSkin.bg).Color -and $graphite.Width -eq 640 -and $graphite.Height -eq 760) 'graphite rebuild uses the matching window palette and size'
 Check ($graphiteRefs.RangeButtons['30d'].Foreground.Color -eq (Get-QmBrush $graphiteSkin.green).Color -and $graphiteRefs.RangeButtons['30d'].Background.Color -eq (Get-QmBrush $graphiteSkin.greenTint).Color -and $graphiteRefs.TabButtons['overview'].Background.Color -eq (Get-QmBrush $graphiteSkin.greenTint).Color) 'selected chips retint for the rebuilt palette'
 Check ((Bar-Of $graphiteRefs.TrendBars.Children[0]).Background.Color -eq (Get-QmBrush $graphiteSkin.green).Color) 'trend bars repaint with the rebuilt palette'
 $insightCard=First-Tagged $graphiteRefs.InsightRows.Children[0] 'QmStatsInsight'
 Check ($insightCard -and $insightCard.Background.Color -eq (Get-QmBrush $graphiteSkin.grayTint).Color) 'auto summary cards retint for the rebuilt palette'
 Check (!$graphite.IsVisible -and [Windows.Interop.WindowInteropHelper]::new($graphite).Handle -eq [IntPtr]::Zero) 'palette rebuild never shows a native window'
 $graphite.Tag='dispose';$graphite.Close()
 $script:CFG.skin='paper';$script:UI.statsWin=$window;$script:QM_STATS_REFS=$refs
 Sync-QmStatsWindow

 # ---------------------------------------------------------------- five skins build
 $okSkins=$true
 foreach($skin in @('paper','graphite','ocean','dusk','sand')){
  $script:CFG.skin=$skin
  $probe=New-QmStatsWindow;$script:UI.statsWin=$probe;Sync-QmStatsWindow
  $probeRefs=$script:QM_STATS_REFS
  if($probe.Resources['QmResolvedSkin'] -ne $skin -or $probeRefs.TrendBars.Children.Count -ne 12 -or $probeRefs.InsightRows.Children.Count -ne 4 -or $probeRefs.PeriodList.Children.Count -ne 6){$okSkins=$false}
  $probe.Tag='dispose';$probe.Close()
 }
 Check $okSkins 'all five skins render the dashboard with the same structure'
 $script:CFG.skin='paper';$script:UI.statsWin=$window;$script:QM_STATS_REFS=$refs
 Reset-CacheState;Sync-QmStatsWindow

 # ---------------------------------------------------------------- empty state
 $script:QM_PROJECTS=$emptyProjects;$script:QM_SETTINGSD=$emptySettings;Reset-CacheState
 $script:CFG.statsRange='7d'
 Click-Control $refs.Refresh
 Check ($refs.Summary['credits'].Value.Text -eq '0.00' -and $refs.Summary['tokens'].Value.Text -eq '0' -and $refs.Summary['requests'].Value.Text -eq '0' -and $refs.Summary['days'].Value.Text -eq '0') 'empty scan zeroes every summary card and the active-day count'
 Check ($refs.RangeText.Text -eq (Expected-RangeText $today.AddDays(-6) $today 0)) 'empty range text still describes the window'
 Check ($refs.TrendBars.Children.Count -eq 0 -and $refs.TrendEmpty.Visibility -eq 'Visible' -and $refs.TrendPlot.Visibility -eq 'Collapsed' -and $refs.TrendLabels.Visibility -eq 'Collapsed' -and $refs.TrendCaption.Text -eq '暂无趋势数据') 'empty trend hides the plot and shows its own empty state'
 Check ((Row-Text $refs.TrendEmpty 'QmStatsEmptyTitle') -eq '暂无趋势数据') 'trend empty state names the missing data'
 Check ($refs.ModelEmpty.Visibility -eq 'Visible' -and $refs.ModelRows.Children.Count -eq 0 -and $refs.ModelCount.Text -eq '共 0 个模型 · 暂无占比') 'empty model card explains the absence of records'
 Check ($refs.PeriodTitle.Text -eq '按日明细' -and $refs.PeriodNote.Text -eq '暂无记录' -and $refs.PeriodList.Children.Count -eq 1 -and $refs.Nav.Visibility -eq 'Collapsed' -and $refs.PageText.Text -eq '第 1 / 1 页') 'empty period list collapses navigation and names the state'
 $empty=First-Tagged $refs.PeriodList.Children[0] 'QmStatsEmpty'
 Check ($empty.Children[0].Child.Text -eq ([string][char]0xE9D9) -and $empty.Children[1].Text -eq '暂无用量记录' -and $empty.Children[2].Text -match '没有带积分的助手请求' -and $empty.Children[2].TextWrapping -eq 'Wrap') 'empty illustration includes glyph, title, and wrapped hint'
 Check ($refs.Summary['tokens'].Value.Text -notmatch '≈') 'empty summary does not imply estimated tokens'
 Check ((@($refs.InsightRows.Children|ForEach-Object {Row-Text $_ 'QmStatsInsightSummary'}) -join '|') -eq '暂无用量记录|暂无用量记录|暂无用量记录|暂无用量记录') 'auto summary states no records for every fixed window when the cache is empty'
 Check ((@($refs.InsightRows.Children|ForEach-Object {(First-Tagged $_ 'QmStatsInsightDelta').Text}) -join '|') -eq '—|—|—|—') 'empty auto summary badges stay neutral'
 $script:QM_STATS_ERROR='部分日志无法读取';Sync-QmStatsWindow
 Check ($refs.FooterNote.Text -eq '部分日志无法读取；请检查 Qoder 日志权限') 'partial-scan errors surface in the footer'
 $script:QM_STATS_ERROR='';Sync-QmStatsWindow
 Check ($refs.FooterNote.Text -eq '本机日志 · 不联网 · ≈估算' -and $refs.FooterNote.TextWrapping -eq 'Wrap') 'footer states the offline and estimation boundary'

 # ---------------------------------------------------------------- local close behavior
 $done=$refs.FooterDone
 Check ($done.Content -eq '完成' -and $done.IsDefault -and $done.IsCancel) 'done button is the default and cancel action'
 $beforeDone=$script:Commands.Count
 Click-Control $done
 Check ($script:Commands.Count -eq $beforeDone -and !$window.IsVisible) 'done hides locally without routing a command'
 $script:ClosedCount=0;$window.Add_Closed({$script:ClosedCount++})
 $window.Tag=$null;$window.Close()
 Check ($script:ClosedCount -eq 0 -and $script:UI.statsWin -eq $window -and !$window.IsVisible) 'ordinary close is canceled and hides instead of destroying the window'
 $window.Tag='dispose';$window.Close()
 Check ($script:ClosedCount -eq 1) 'dispose close actually releases the window'
 $script:UI.statsWin=$null

 Write-Output ('PASS='+$script:pass+' FAIL='+$script:fail)
 if($script:fail){exit 1}
}finally{
 if($script:UI.statsWin){try{$script:UI.statsWin.Tag='dispose';$script:UI.statsWin.Close()}catch{}}
 if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
