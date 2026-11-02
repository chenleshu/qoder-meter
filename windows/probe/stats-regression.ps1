#requires -Version 5.1
# Offline Windows usage-statistics regression. No network, account API, Qoder file write, or real claim.
$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path $PSScriptRoot -Parent
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run with Windows PowerShell 5.1.'}
$inv=[Globalization.CultureInfo]::InvariantCulture
$script:pass=0;$script:fail=0
function Check($ok,[string]$name){if($ok){$script:pass++;Write-Output "PASS $name"}else{$script:fail++;Write-Output "FAIL $name"}}
function Near([double]$a,[double]$b){return [math]::Abs($a-$b) -lt 0.000001}
function Day-Key([int]$offset){return [datetime]::Today.AddDays(-$offset).ToString('yyyy-MM-dd',$inv)}
function Reset-CacheState {
 $script:QM_STATS_CACHE=$null;$script:QM_STATS_CACHE_LOADED=$false;$script:QM_STATS_CACHE_PATH_LOADED='';$script:QM_STATS_ERROR=''
}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('qm-stats-reg-'+[guid]::NewGuid().ToString('N'))
$mainProjects=Join-Path $tempRoot 'main-projects'
$mainSettings=Join-Path $tempRoot 'main-settings'
$utf8=[Text.UTF8Encoding]::new($false)
$lock=$null
try{
 [void][IO.Directory]::CreateDirectory((Join-Path $mainProjects 'alpha\nested'))
 [void][IO.Directory]::CreateDirectory($mainSettings)
 . (Join-Path $root 'src\lib-interop.ps1')
 . (Join-Path $root 'src\lib-data.ps1')
 $script:QM_PROJECTS=$mainProjects
 $script:QM_SETTINGSD=$mainSettings
 . (Join-Path $root 'src\lib-config-layout.ps1')
 . (Join-Path $root 'src\lib-stats.ps1')
 $script:CFG_PATH=Join-Path $tempRoot 'config\settings.json'

 $today=[datetime]::Today
 function Ts([datetime]$local){return ([DateTimeOffset]::new($local)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
 $same=[hashtable]@{type='assistant';timestamp=(Ts $today.AddHours(10));message=@{model='dfmodel';usage=@{input_tokens=100;cache_read_input_tokens=50;cache_creation_input_tokens=25;output_tokens=30;credits=1.5;request_id='r1'};content=@(@{type='text';text='ignored because exact tokens exist'})}}
 $records=@(
  $same,
  @{type='assistant';timestamp=(Ts $today.AddHours(10));message=@{model='dfmodel';usage=@{input_tokens=9999;credits=999;request_id='r1'};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(11));message=@{model='qoder/qmodel';usage=@{credits=0.25;request_id='r2'};content=@(@{type='text';text='中文'})}},
  @{type='assistant';timestamp=(Ts $today.AddDays(-1).AddHours(12));message=@{model='gfmodel';usage=@{credits=2;request_id='r3'};content=@(@{type='text';text='abcd'})}},
  @{type='assistant';timestamp=(Ts $today.AddDays(-8).AddHours(9));message=@{model='qmodel';usage=@{input_tokens=400;cache_read_input_tokens=300;cache_creation_input_tokens=200;output_tokens=100;credits=9;request_id='r4'};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddDays(-40).AddHours(9));message=@{model='mmodel';usage=@{input_tokens=500;credits=4;request_id='r5'};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(12));message=@{model='dfmodel';usage=@{credits=0;request_id='r6'};content=@(@{type='text';text='abcd'})}},
  @{type='assistant';timestamp=(Ts $today.AddHours(12));message=@{model='auto';usage=@{input_tokens=99;credits=$null;request_id='r7'};content=@()}},
  @{type='user';timestamp=(Ts $today);message=@{model='auto';usage=@{credits=99;request_id='r8'};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(13));message=@{model='kmodel_latest';usage=@{credits=0.5;request_id=''};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(13));message=@{model='kmodel_latest';usage=@{credits=0.5};content=@()}},
  @{type='assistant';message=@{model='auto';usage=@{credits=1;request_id='r9'};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(14));credits=0;message=@{model='auto';usage=@{input_tokens=7};content=@()}},
  @{type='assistant';timestamp=(Ts $today.AddHours(15));message=@{model='cmodel';usage=@{credits=0.75;request_id='r10'};content=@(@{type='tool_use';input=@{x=1}})}},
  @{type='assistant';timestamp=(Ts $today.AddDays(-2).AddHours(12));message=@{model='dfmodel';usage=@{input_tokens=100;credits=2.5;request_id='r11'};content=@()}}
 )
 $lines=@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 12 -Compress})
 $lines+='{"type":"assistant","message":{"usage":{"credits":'
 [IO.File]::WriteAllText((Join-Path $mainProjects 'alpha\chat.jsonl'),($lines -join "`n"),$utf8)
 # Identical duplicate request delivered by a second project file; global dedup must keep one row.
 [IO.File]::WriteAllText((Join-Path $mainProjects 'alpha\nested\other.jsonl'),(ConvertTo-Json -InputObject $same -Depth 12 -Compress),$utf8)

 # ---------------------------------------------------------------- scan
 $cache=Get-QmStatsCache -Force
 Check ($cache.rows -eq 10 -and $cache.days.Count -eq 5) 'scan aggregates ten unique assistant requests across five local dates'
 $todayKey=$today.ToString('yyyy-MM-dd',$inv)
 $yKey=$today.AddDays(-1).ToString('yyyy-MM-dd',$inv)
 $d2=$today.AddDays(-2).ToString('yyyy-MM-dd',$inv)
 $d8=$today.AddDays(-8).ToString('yyyy-MM-dd',$inv)
 $d40=$today.AddDays(-40).ToString('yyyy-MM-dd',$inv)
 Check ((Near $cache.days[$todayKey].credits 3.5) -and (Near $cache.days[$todayKey].tokens 209) -and $cache.days[$todayKey].requests -eq 6 -and $cache.days[$todayKey].estimated -and $cache.days[$todayKey].models.Count -eq 4) 'today bucket merges credits, exact and estimated tokens, and four models'
 Check ((Near $cache.days[$yKey].credits 2) -and (Near $cache.days[$yKey].tokens 1) -and $cache.days[$yKey].requests -eq 1 -and $cache.days[$yKey].estimated) 'yesterday uses the CJK estimator when exact usage is absent'
 Check ((Near $cache.days[$d2].tokens 100) -and !$cache.days[$d2].estimated -and (Near $cache.days[$d8].tokens 1000)) 'exact totals remain unestimated and older days are retained in the cache'
 Check ((Near $cache.days[$d40].credits 4) -and $cache.days.Count -eq 5) 'long-range day is cached outside the default window'

 # ---------------------------------------------------------------- ranges
 $data7=Get-QmStatsData '7d'
 Check ($data7.Range -eq '7d' -and $data7.ActiveDays -eq 3 -and (Near $data7.Credits 8) -and (Near $data7.Tokens 310) -and $data7.Requests -eq 8 -and $data7.Estimated) 'seven-day totals include only today, yesterday, and two days ago'
 Check ($data7.Start.Date -eq $today.AddDays(-6) -and $data7.End.Date -eq $today -and $data7.Days.Count -eq 3 -and $data7.Days[0].Key -eq $todayKey) 'seven-day window and descending day order are exact'
 $m7=@($data7.Models)
 Check ($m7.Count -eq 5 -and $m7[0].Name -eq 'DeepSeek-V4-Flash' -and (Near $m7[0].Credits 4) -and (Near $m7[0].Tokens 306) -and $m7[0].Requests -eq 3) 'models merge across days and sort by credits then tokens'
 Check ($m7[1].Name -eq 'GLM-5.3-Flash' -and $m7[2].Name -eq 'Kimi-K3' -and (Near $m7[2].Credits 1) -and $m7[2].Requests -eq 2 -and $m7[3].Name -eq 'Cantus' -and $m7[4].Name -eq 'Qwen3.7-Plus') 'friendly model names and per-model request counts survive aggregation'
 Check ($m7[0].Estimated -and $m7[2].Estimated -eq $false -and $m7[3].Estimated) 'per-model estimation flags distinguish exact and estimated usage'
 $data30=Get-QmStatsData '30d'
 Check ($data30.ActiveDays -eq 4 -and (Near $data30.Credits 17) -and (Near $data30.Tokens 1310) -and $data30.Requests -eq 9) 'thirty-day totals include the eighth previous day and exclude the fortieth'
 Check ($data30.Models[0].Name -eq 'Qwen3.7-Plus' -and (Near $data30.Models[0].Credits 9.25) -and (Near $data30.Models[0].Tokens 1001)) 'thirty-day model ranking reflects the added older session'
 $dataYear=Get-QmStatsData 'year'
 Check ($dataYear.ActiveDays -eq 5 -and (Near $dataYear.Credits 21) -and (Near $dataYear.Tokens 1810) -and $dataYear.Requests -eq 10 -and $dataYear.Models.Count -eq 6) 'year range includes every cached day'
 Check ($dataYear.Models[0].Name -eq 'Qwen3.7-Plus' -and $dataYear.Models[1].Name -eq 'MiniMax-M3' -and $dataYear.Models[2].Name -eq 'DeepSeek-V4-Flash') 'equal credits fall back to tokens and then name ordering'
 $dataMonth=Get-QmStatsData 'month'
 Check ($dataMonth.Start -eq [datetime]::new($today.Year,$today.Month,1) -and $dataMonth.End.Date -eq $today -and $dataMonth.ActiveDays -ge 1 -and $dataMonth.ActiveDays -le 3) 'month range starts on the first and never exceeds today'
 Check ((@($dataMonth.Days|Where-Object {$_.Key -notlike ($today.ToString('yyyy-MM',$inv)+'*')}).Count -eq 0)) 'month range contains only keys in the current calendar month'
 $fallback=Get-QmStatsData 'bogus'
 Check ($fallback.Range -eq '7d' -and (Near $fallback.Credits 8)) 'unknown range falls back to seven days'
 Check ((Get-QmStatsRangeStart '7d') -eq $today.AddDays(-6) -and (Get-QmStatsRangeStart '30d') -eq $today.AddDays(-29) -and (Get-QmStatsRangeStart 'year') -eq $today.AddDays(-364) -and (Get-QmStatsRangeStart 'month') -eq [datetime]::new($today.Year,$today.Month,1)) 'range starts are stable calendar boundaries'

 # ---------------------------------------------------------------- loaded cache boundary
 $boundarySettings=Join-Path $tempRoot 'boundary-settings'
 [void][IO.Directory]::CreateDirectory($boundarySettings)
 $boundaryDays=[ordered]@{}
 foreach($offset in @(0,-6,-7,1)){
  $key=$today.AddDays($offset).ToString('yyyy-MM-dd',$inv)
  $boundaryDays[$key]=[ordered]@{credits=1.0;tokens=10.0;requests=1;estimated=$false;models=[ordered]@{auto=[ordered]@{credits=1.0;tokens=10.0;requests=1;estimated=$false}}}
 }
 $boundaryDoc=ConvertTo-Json -InputObject ([ordered]@{version=1;at=(QmNowMs);rows=4;days=$boundaryDays}) -Depth 10 -Compress
 [IO.File]::WriteAllText((Join-Path $boundarySettings 'stats-cache.json'),$boundaryDoc,$utf8)
 $script:QM_SETTINGSD=$boundarySettings;Reset-CacheState
 $boundary7=Get-QmStatsData '7d';$boundary30=Get-QmStatsData '30d';$boundaryYear=Get-QmStatsData 'year'
 Check ($boundary7.ActiveDays -eq 2 -and (Near $boundary7.Credits 2) -and $boundary7.Days[0].Key -eq $todayKey) 'seven-day filter includes day six but not day seven'
 Check ($boundary30.ActiveDays -eq 3 -and (Near $boundary30.Credits 3)) 'thirty-day filter includes day seven'
 Check ($boundaryYear.ActiveDays -eq 3 -and (@($boundaryYear.Days|Where-Object {$_.Key -eq $today.AddDays(1).ToString('yyyy-MM-dd',$inv)}).Count -eq 0)) 'future-dated cache entries never enter a range'
 $script:QM_SETTINGSD=$mainSettings;Reset-CacheState;Get-QmStatsCache|Out-Null

 # ---------------------------------------------------------------- cache file persistence
 $cachePath=Get-QmStatsCachePath
 Check ($cachePath -eq (Join-Path $mainSettings 'stats-cache.json') -and [IO.File]::Exists($cachePath)) 'cache lives under the Meter settings directory'
 Check (@(Get-ChildItem -LiteralPath $mainSettings -Filter '*.tmp' -Force).Count -eq 0) 'atomic cache save leaves no temporary file'
 $read=Read-QmStatsCacheFile
 Check ($read -and $read.rows -eq 10 -and $read.days.Count -eq 5 -and $read.at -eq $cache.at) 'persisted cache round-trips with its scan time and row count'
 $atBefore=$cache.at
 $extra=@{type='assistant';timestamp=(Ts $today.AddHours(16));message=@{model='dfmodel';usage=@{input_tokens=10;credits=5;request_id='r12'};content=@()}}
 [IO.File]::AppendAllText((Join-Path $mainProjects 'alpha\chat.jsonl'),"`n"+(ConvertTo-Json -InputObject $extra -Depth 12 -Compress),$utf8)
 $fresh=Get-QmStatsCache
 Check ($fresh.at -eq $atBefore -and $fresh.rows -eq 10 -and (Near (Get-QmStatsData '7d').Credits 8)) 'ten-minute cache suppresses a rescan after a log append'
 $forced=Get-QmStatsCache -Force
 Check ($forced.rows -eq 11 -and (Near (Get-QmStatsData '7d').Credits 13) -and (Near (Get-QmStatsData '7d').Tokens 320) -and (Get-QmStatsData '7d').Requests -eq 9) 'forced refresh sees the appended request'
 $atForced=$forced.at
 $script:QM_STATS_CACHE=$null;$script:QM_STATS_CACHE_LOADED=$false;$script:QM_STATS_CACHE_PATH_LOADED=''
 $reloaded=Get-QmStatsCache
 Check ($reloaded.rows -eq 11 -and $reloaded.at -eq $atForced) 'simulated restart reuses the on-disk cache without rescanning'
 $extra2=@{type='assistant';timestamp=(Ts $today.AddHours(17));message=@{model='gfmodel';usage=@{input_tokens=5;credits=1;request_id='r13'};content=@()}}
 [IO.File]::AppendAllText((Join-Path $mainProjects 'alpha\chat.jsonl'),"`n"+(ConvertTo-Json -InputObject $extra2 -Depth 12 -Compress),$utf8)
 $script:QM_STATS_CACHE.at=(QmNowMs)-$script:QM_STATS_CACHE_MS-1000;$script:QM_STATS_CACHE.rows=999
 $expired=Get-QmStatsCache
 Check ($expired.rows -eq 12 -and (Near (Get-QmStatsData '7d').Credits 14) -and (Near (Get-QmStatsData '7d').Tokens 325) -and $expired.at -gt (QmNowMs)-60000) 'expired cache rescans and replaces the stale row count'
 $again=Get-QmStatsCache
 Check ($again.at -eq $expired.at -and $again.rows -eq 12) 'rescanned cache is fresh for the next open'
 $newSettings=Join-Path $tempRoot 'path-settings'
 $script:QM_SETTINGSD=$newSettings
 $pathScan=Get-QmStatsCache
 Check ($pathScan.rows -eq 12 -and (Test-Path -LiteralPath (Join-Path $newSettings 'stats-cache.json')) -and [IO.File]::Exists($cachePath)) 'settings-path change loads or rebuilds its own cache without touching the old one'
 $script:QM_SETTINGSD=$mainSettings;Reset-CacheState

 # ---------------------------------------------------------------- cache validation
 function New-CacheDoc {
  $days=[ordered]@{'2026-01-02'=[ordered]@{credits=1.5;tokens=10;requests=1;estimated=$false;models=[ordered]@{dfmodel=[ordered]@{credits=1.5;tokens=10;requests=1;estimated=$false}}}}
  return [ordered]@{version=1;at=QmNowMs;rows=2;days=$days}
 }
 function Roundtrip($object){return (ConvertTo-Json -InputObject $object -Depth 12 -Compress|ConvertFrom-Json)}
 $validDoc=New-CacheDoc
 $valid=ConvertTo-QmStatsCache (Roundtrip $validDoc)
 Check ($valid -and $valid.days.Count -eq 1 -and $valid.days['2026-01-02'].models.Count -eq 1) 'valid cache document is accepted'
 $bad=New-CacheDoc;$bad.version=2
 Check ($null -eq (ConvertTo-QmStatsCache (Roundtrip $bad))) 'unknown cache version is rejected'
 $bad=New-CacheDoc;$bad.at=0
 Check ($null -eq (ConvertTo-QmStatsCache (Roundtrip $bad))) 'missing cache time is rejected'
 $bad=New-CacheDoc;$bad.at=(QmNowMs)+172800000
 Check ($null -eq (ConvertTo-QmStatsCache (Roundtrip $bad))) 'future cache time is rejected'
 $bad=New-CacheDoc;$bad.days=$null
 Check ($null -eq (ConvertTo-QmStatsCache (Roundtrip $bad))) 'cache without days is rejected'
 $bad=New-CacheDoc;$bad.days['not-a-day']=[ordered]@{credits=1;tokens=1;requests=1;estimated=$false;models=[ordered]@{}}
 $bad.days['2026-01-03']=[ordered]@{credits=-1;tokens=1;requests=1;estimated=$false;models=[ordered]@{}}
 $bad.days['2026-01-04']=[ordered]@{credits=1;tokens=1;requests=-1;estimated=$false;models=[ordered]@{}}
 $bad.days['2026-01-05']=[ordered]@{credits=1;tokens=1;requests=1;estimated=$false;models=[ordered]@{bad=[ordered]@{credits=-2;tokens=1;requests=1;estimated=$false}}}
 $filtered=ConvertTo-QmStatsCache (Roundtrip $bad)
 Check ($filtered -and $filtered.days.Count -eq 2 -and !$filtered.days.ContainsKey('not-a-day') -and !$filtered.days.ContainsKey('2026-01-03') -and !$filtered.days.ContainsKey('2026-01-04') -and $filtered.days['2026-01-05'].models.Count -eq 0) 'invalid dates, negative totals, and negative models are discarded individually'
 $bad=New-CacheDoc;$bad.days['2026-01-02'].requests='oops'
 $filtered=ConvertTo-QmStatsCache (Roundtrip $bad)
 Check ($filtered -and $filtered.days.Count -eq 0) 'non-numeric cache counters discard the affected day without rejecting the cache'

 # ---------------------------------------------------------------- corrupted on-disk cache self-heals
 [IO.File]::WriteAllText($cachePath,'{"version":1,"at":',$utf8)
 Reset-CacheState
 $healed=Get-QmStatsCache -Force
 Check ($healed.rows -eq 12 -and $script:QM_STATS_CACHE_PATH_LOADED -eq $cachePath) 'corrupt cache file is ignored and atomically replaced'
 $readHealed=Read-QmStatsCacheFile
 Check ($readHealed -and $readHealed.rows -eq 12) 'replaced cache file validates'

 # ---------------------------------------------------------------- deterministic dedup
 $dedupProjects=Join-Path $tempRoot 'dedup-projects';$dedupSettings=Join-Path $tempRoot 'dedup-settings'
 [void][IO.Directory]::CreateDirectory($dedupProjects);[void][IO.Directory]::CreateDirectory($dedupSettings)
 $dedupLines=@(
  (ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(9));message=@{model='dfmodel';usage=@{input_tokens=10;credits=1;request_id='same-id'};content=@()}} -Depth 12 -Compress),
  (ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(9));message=@{model='qmodel';usage=@{input_tokens=90;credits=9;request_id='same-id'};content=@()}} -Depth 12 -Compress),
  (ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(10));message=@{model='dfmodel';usage=@{input_tokens=1;credits=0.5};content=@()}} -Depth 12 -Compress),
  (ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(11));message=@{model='dfmodel';usage=@{input_tokens=1;credits=0.5};content=@()}} -Depth 12 -Compress)
 )
 [IO.File]::WriteAllText((Join-Path $dedupProjects 'single.jsonl'),($dedupLines -join "`n"),$utf8)
 $script:QM_PROJECTS=$dedupProjects;$script:QM_SETTINGSD=$dedupSettings;Reset-CacheState
 $dedup=Get-QmStatsCache -Force
 Check ($dedup.rows -eq 3 -and (Near $dedup.days[$todayKey].credits 2) -and (Near $dedup.days[$todayKey].tokens 12) -and $dedup.days[$todayKey].requests -eq 3) 'first request id wins and request-id-less rows each count once'
 Check ($dedup.days[$todayKey].models.Count -eq 1 -and $dedup.days[$todayKey].models.ContainsKey('dfmodel')) 'deduplicated later model never enters the bucket'

 # ---------------------------------------------------------------- unreadable file
 $lockProjects=Join-Path $tempRoot 'lock-projects';$lockSettings=Join-Path $tempRoot 'lock-settings'
 [void][IO.Directory]::CreateDirectory($lockProjects);[void][IO.Directory]::CreateDirectory($lockSettings)
 $readablePath=Join-Path $lockProjects 'a-readable.jsonl';$lockedPath=Join-Path $lockProjects 'b-locked.jsonl'
 $readableLine=ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(10));message=@{model='dfmodel';usage=@{input_tokens=1;credits=1;request_id='lock-read'};content=@()}} -Depth 12 -Compress
 $lockedLine=ConvertTo-Json -InputObject @{type='assistant';timestamp=(Ts $today.AddHours(11));message=@{model='gfmodel';usage=@{input_tokens=2;credits=2;request_id='lock-hidden'};content=@()}} -Depth 12 -Compress
 [IO.File]::WriteAllText($readablePath,$readableLine,$utf8);[IO.File]::WriteAllText($lockedPath,$lockedLine,$utf8)
 $lock=[IO.File]::Open($lockedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 $script:QM_PROJECTS=$lockProjects;$script:QM_SETTINGSD=$lockSettings;Reset-CacheState
 $partial=Get-QmStatsCache -Force
 Check ($partial.rows -eq 1 -and $script:QM_STATS_ERROR -eq '部分日志无法读取' -and (Test-Path -LiteralPath (Join-Path $lockSettings 'stats-cache.json'))) 'locked log reports a partial scan while caching readable files'
 $lock.Dispose();$lock=$null
 $full=Get-QmStatsCache -Force
 Check ($full.rows -eq 2 -and $script:QM_STATS_ERROR -eq '') 'released log is picked up by the next forced scan'

 # ---------------------------------------------------------------- missing projects directory
 $emptySettings=Join-Path $tempRoot 'empty-settings';[void][IO.Directory]::CreateDirectory($emptySettings)
 $script:QM_PROJECTS=Join-Path $tempRoot 'absent-projects';$script:QM_SETTINGSD=$emptySettings;Reset-CacheState
 $empty=Get-QmStatsCache -Force
 $emptyData=Get-QmStatsData '7d'
 Check ($empty.rows -eq 0 -and $empty.days.Count -eq 0 -and $script:QM_STATS_ERROR -eq '') 'missing project directory yields an empty cache without an error'
 Check ($emptyData.Credits -eq 0 -and $emptyData.Tokens -eq 0 -and $emptyData.Requests -eq 0 -and $emptyData.ActiveDays -eq 0 -and $emptyData.Days.Count -eq 0 -and $emptyData.Models.Count -eq 0) 'empty cache produces zero totals and no periods'
 Check ((Get-QmStatsRangeText $emptyData) -match '活跃 0 天$' -and (Get-QmStatsPeriods $emptyData 'day').Count -eq 0) 'empty range text and grouping are stable'
 $script:QM_PROJECTS=$mainProjects;$script:QM_SETTINGSD=$mainSettings;Reset-CacheState;Get-QmStatsCache|Out-Null

 # ---------------------------------------------------------------- grouping with fixed dates
 function New-Day([string]$key,[double]$credits,[double]$tokens,[string]$model,[bool]$estimated=$false){
  return [pscustomobject]@{Key=$key;Credits=$credits;Tokens=$tokens;Requests=1L;Estimated=$estimated;Models=@([pscustomobject]@{Name=$model;Credits=$credits;Tokens=$tokens;Requests=1L;Estimated=$estimated})}
 }
 $synthetic=[pscustomobject]@{Days=@(
  (New-Day '2026-02-28' 1 10 'A'),(New-Day '2026-03-01' 2 20 'A'),(New-Day '2026-03-02' 3 30 'B'),
  (New-Day '2026-03-08' 4 40 'B'),(New-Day '2026-03-09' 5 50 'C'),(New-Day '2026-03-31' 6 60 'C'),
  (New-Day '2026-04-01' 7 70 'D' $true)
 )}
 Check ((Get-QmStatsPeriodKey 'day' '2026-03-04') -eq '2026-03-04' -and (Get-QmStatsPeriodKey 'month' '2026-03-31') -eq '2026-03' -and (Get-QmStatsPeriodKey 'month' '2026') -eq '2026') 'period keys truncate months and preserve day keys'
 Check ((Get-QmStatsWeekKey '2026-03-01') -eq '2026-02-23' -and (Get-QmStatsWeekKey '2026-03-02') -eq '2026-03-02' -and (Get-QmStatsWeekKey '2026-03-08') -eq '2026-03-02' -and (Get-QmStatsWeekKey '2026-04-01') -eq '2026-03-30' -and (Get-QmStatsWeekKey 'bad') -eq 'bad') 'weeks start on Monday and invalid keys pass through'
 $weeks=@(Get-QmStatsPeriods $synthetic 'week')
 Check ($weeks.Count -eq 4 -and $weeks[0].Key -eq '2026-03-30' -and $weeks[1].Key -eq '2026-03-09' -and $weeks[2].Key -eq '2026-03-02' -and $weeks[3].Key -eq '2026-02-23') 'weekly groups are ordered newest first'
 Check ((Near $weeks[0].Credits 13) -and (Near $weeks[0].Tokens 130) -and $weeks[0].ActiveDays -eq 2 -and $weeks[0].Estimated -and $weeks[0].Models.Count -eq 2) 'cross-month week merges totals, active days, and models'
 Check ((Near $weeks[2].Credits 7) -and $weeks[2].ActiveDays -eq 2 -and (Near $weeks[3].Credits 3)) 'adjacent weeks split at the Monday boundary'
 $months=@(Get-QmStatsPeriods $synthetic 'month')
 Check ($months.Count -eq 3 -and $months[0].Key -eq '2026-04' -and $months[1].Key -eq '2026-03' -and $months[2].Key -eq '2026-02') 'monthly groups are ordered newest first'
 Check ((Near $months[1].Credits 20) -and (Near $months[1].Tokens 200) -and $months[1].ActiveDays -eq 5 -and $months[1].Models.Count -eq 3 -and !$months[1].Estimated) 'monthly group includes every day in the calendar month'
 Check ((Near $months[0].Credits 7) -and $months[0].Estimated) 'monthly group retains the estimation flag'
 $days=@(Get-QmStatsPeriods $synthetic 'day')
 Check ($days.Count -eq 7 -and $days[0].Key -eq '2026-04-01' -and $days[6].Key -eq '2026-02-28' -and $days[0].Estimated -and !$days[1].Estimated) 'daily groups keep one row per active day in descending order'
 $defaultDays=@(Get-QmStatsPeriods $synthetic 'quarter')
 Check ($defaultDays.Count -eq 7 -and $defaultDays[0].Key -eq '2026-04-01') 'unknown grouping falls back to day'

 Check ((Get-QmStatsPeriodLabel 'day' $todayKey) -eq '今天' -and (Get-QmStatsPeriodLabel 'day' $yKey) -eq '昨天' -and (Get-QmStatsPeriodLabel 'day' '1999-12-31') -eq '12-31') 'daily labels cover today, yesterday, and older dates'
 $monday=$today.AddDays(-(([int]$today.DayOfWeek+6)%7))
 Check ((Get-QmStatsPeriodLabel 'week' $monday.ToString('yyyy-MM-dd',$inv)) -eq '本周' -and (Get-QmStatsPeriodLabel 'week' $monday.AddDays(-7).ToString('yyyy-MM-dd',$inv)) -eq '上周' -and (Get-QmStatsPeriodLabel 'week' '2026-03-02') -eq '03-02 ~ 03-08') 'weekly labels identify current, previous, and fixed ranges'
 $lastMonth=$today.AddMonths(-1)
 Check ((Get-QmStatsPeriodLabel 'month' $today.ToString('yyyy-MM',$inv)) -eq '本月' -and (Get-QmStatsPeriodLabel 'month' $lastMonth.ToString('yyyy-MM',$inv)) -eq '上月' -and (Get-QmStatsPeriodLabel 'month' '1999-12') -eq '1999年12月') 'monthly labels identify current, previous, and cross-year months'
 $otherYear=$today.Year-1
 Check ((Get-QmStatsPeriodLabel 'month' ($otherYear.ToString($inv)+'-05')) -eq ($otherYear.ToString($inv)+'年5月')) 'older same-year-excluded month label includes its year'

 # ---------------------------------------------------------------- period formatting
 $week0=$weeks[0]
 Check ((Get-QmStatsPeriodTip 'week' $week0.Key $week0) -eq "2026-03-30 ~ 2026-04-05 · 2 天有记录`n13.00 积分 · ≈ 130 Token · 2 请求") 'weekly tooltip combines fixed dates, active days, and metrics'
 $day0=$days[0]
 Check ((Get-QmStatsPeriodTip 'day' $day0.Key $day0) -eq "2026-04-01`n7.00 积分 · ≈ 70 Token · 1 请求") 'daily tooltip marks estimated tokens with the approximate sign'
 Check ((Get-QmStatsPeriodTip 'month' '2026-03' $months[1]) -eq "2026-03 · 5 天有记录`n20.00 积分 · 200 Token · 5 请求") 'monthly tooltip uses calendar-month wording'
 Check ((Get-QmStatsTopModelsText $week0) -eq 'D 7.00分/≈70 · C 6.00分/60') 'top-model summary marks estimation per model'
 Check ((Get-QmStatsTopModelsText $days[1]) -eq 'C 6.00分/60') 'single-model summary has no overflow suffix'

 # ---------------------------------------------------------------- formatting and model names
 Check ((Format-QmStatsTokens 0) -eq '0' -and (Format-QmStatsTokens (-5)) -eq '0' -and (Format-QmStatsTokens 861) -eq '861' -and (Format-QmStatsTokens 1000) -eq '1.0k' -and (Format-QmStatsTokens 1500000) -eq '1.50m') 'token formatter matches the compact meter units'
 Check ((Get-QmFriendlyModel '') -eq '未知模型' -and (Get-QmFriendlyModel 'unknown') -eq '未知模型' -and (Get-QmFriendlyModel 'none') -eq '未知模型' -and (Get-QmFriendlyModel 'qoder-unknown') -eq '未知模型') 'unknown model ids fall back to the localized placeholder'
 Check ((Get-QmFriendlyModel '  dfmodel ') -eq 'DeepSeek-V4-Flash' -and (Get-QmFriendlyModel 'qoder/qmodel') -eq 'Qwen3.7-Plus' -and (Get-QmFriendlyModel 'QODER/QMODEL_LATEST') -eq 'Qwen3.7-Max' -and (Get-QmFriendlyModel 'QODER/KMODEL_LATEST') -eq 'Kimi-K3') 'model ids normalize prefixes, paths, and case'
 Check ((Get-QmFriendlyModel 'vendor/foo_bar') -eq 'vendor/foo-bar' -and (Get-QmFriendlyModel 'custom_model') -eq 'custom-model') 'unmapped ids keep their vendor path and replace underscores'
 $sorted=@(Sort-QmStatsModels @(
  [pscustomobject]@{Name='Zeta';Credits=2;Tokens=0},
  [pscustomobject]@{Name='Beta';Credits=1;Tokens=9},
  [pscustomobject]@{Name='Alpha';Credits=1;Tokens=9},
  [pscustomobject]@{Name='Gamma';Credits=1;Tokens=5}
 ))
 Check (($sorted.Name -join '|') -eq 'Zeta|Alpha|Beta|Gamma') 'model sort is credits, then tokens, then name ascending'
 $five=@(1..5|ForEach-Object {[pscustomobject]@{Name=('M'+$_);Credits=6-$_;Tokens=(6-$_)*10;Requests=1;Estimated=($_-eq 4)}})
 $rows=@(Get-QmStatsModelRows $five)
 Check ($rows.Count -eq 4 -and $rows[3].Name -eq '其他 2 个' -and (Near $rows[3].Credits 3) -and (Near $rows[3].Tokens 30) -and $rows[3].Estimated) 'five models collapse to the top three plus a counted remainder'
 Check ((@(Get-QmStatsModelRows ($five[0..3])).Count) -eq 4 -and (@(Get-QmStatsModelRows @())).Count -eq 0 -and (@(Get-QmStatsModelRows ($five[0..4])).Count) -eq 4) 'model rows keep four entries at the threshold and tolerate empty input'

 # ---------------------------------------------------------------- content estimation
 $entry=ConvertFrom-JsonLine '{"content":[{"type":"text","text":"中文"}]}'
 $shape=Get-QmStatsContentChars (DictVal $entry 'content')
 Check ($shape.Chars -eq 2 -and $shape.Cjk -eq 2 -and $shape.Estimated -eq 1) 'single text block uses the CJK divisor'
 $entry=ConvertFrom-JsonLine '{"content":[{"type":"text","text":"ab"},{"type":"thinking","thinking":"四"},{"type":"tool_use","input":{"x":1}},{"type":"redacted_thinking","data":"hidden"}]}'
 $shape=Get-QmStatsContentChars (DictVal $entry 'content')
 Check ($shape.Chars -eq 10 -and $shape.Cjk -eq 1 -and $shape.Estimated -eq 3) 'text, thinking, and stringified tool input all contribute; redacted thinking is ignored'
 $shape=Get-QmStatsContentChars $null
 Check ($shape.Chars -eq 0 -and $shape.Cjk -eq 0 -and $shape.Estimated -eq 0) 'missing content estimates zero tokens'
 $entry=ConvertFrom-JsonLine '{"content":[{"type":"text","text":"😀"}]}'
 $shape=Get-QmStatsContentChars (DictVal $entry 'content')
 Check ($shape.Chars -eq 2 -and $shape.Cjk -eq 0 -and $shape.Estimated -eq 1) 'surrogate pairs count as two UTF-16 units without CJK weight'
 $shape=Get-QmStatsContentChars @()
 Check ($shape.Chars -eq 0 -and $shape.Cjk -eq 0 -and $shape.Estimated -eq 0) 'empty content array is contained'

 # ---------------------------------------------------------------- range text and clock
 Check ((Get-QmStatsRangeText ([pscustomobject]@{Start=[datetime]::new(2026,3,2);End=[datetime]::new(2026,3,8);ActiveDays=3})) -eq '03-02 ~ 03-08 · 活跃 3 天') 'same-year range text omits years'
 Check ((Get-QmStatsRangeText ([pscustomobject]@{Start=[datetime]::new(2025,12,30);End=[datetime]::new(2026,1,2);ActiveDays=2})) -eq '2025-12-30 ~ 2026-01-02 · 活跃 2 天') 'cross-year range text includes both years'
 Check ((Format-QmStatsClock 0) -eq '—' -and (Format-QmStatsClock -1) -eq '—' -and (Format-QmStatsClock 1760000000000) -match '^\d{2}:\d{2}$') 'clock formatter handles empty and valid timestamps'

 # ---------------------------------------------------------------- config keys
 $freshCfg=New-QmConfig
 Check ($freshCfg.statsRange -eq '7d' -and $freshCfg.statsGroup -eq 'day') 'new configuration starts at seven days grouped by day'
 $merged=Merge-QmConfig ([pscustomobject]@{statsRange='30d';statsGroup='week'})
 Check ($merged.statsRange -eq '30d' -and $merged.statsGroup -eq 'week' -and $merged.display.tps) 'valid statistics preferences merge without disturbing display defaults'
 $merged=Merge-QmConfig ([pscustomobject]@{statsRange='90d';statsGroup='quarter'})
 Check ($merged.statsRange -eq '7d' -and $merged.statsGroup -eq 'day') 'invalid statistics preferences reset to defaults'
 $merged=Merge-QmConfig ([pscustomobject]@{statsRange='year';statsGroup='month';skin='ocean'})
 Check ($merged.statsRange -eq 'year' -and $merged.statsGroup -eq 'month' -and $merged.skin -eq 'ocean') 'statistics preferences merge alongside unrelated settings'
 $script:CFG=New-QmConfig;$script:CFG.statsRange='month';$script:CFG.statsGroup='month';$script:CFG.skin='ocean'
 Save-QmConfig
 $saved=Read-QmConfig
 Check ($saved.statsRange -eq 'month' -and $saved.statsGroup -eq 'month' -and $saved.skin -eq 'ocean') 'statistics preferences persist through the config file'

 # ---------------------------------------------------------------- explicit and all windows
 $allData=Get-QmStatsAllData
 Check ($allData.Range -eq 'all' -and $allData.Start -eq $today.AddDays(-40) -and $allData.End -eq $today -and $allData.Rows -eq 12) 'the all window spans the earliest cached date to today'
 Check ($allData.ActiveDays -eq 5 -and (Near $allData.Credits 27) -and (Near $allData.Tokens 1825) -and $allData.Requests -eq 12) 'the all window totals every cached day in the current cache'
 $window3=Get-QmStatsWindow $today.AddDays(-2) $today 'w'
 Check ($window3.Range -eq 'w' -and $window3.ActiveDays -eq 3 -and $window3.Days[-1].Key -eq $today.AddDays(-2).ToString('yyyy-MM-dd',$inv)) 'an explicit window filters days the same way as a named range'
 Check ((Get-QmStatsData '7d').Start -eq (Get-QmStatsRangeStart '7d') -and (Get-QmStatsData '7d').End -eq $today) 'named ranges keep their documented boundaries'

 # ---------------------------------------------------------------- trend series
 $series=@(Get-QmStatsSeries $synthetic 'day')
 Check ($series.Count -eq 7 -and $series[0].Key -eq '2026-02-28' -and $series[-1].Key -eq '2026-04-01') 'chart series are ascending and cover every period'
 $chartData=Get-QmStatsChartData $synthetic 'day'
 Check ($chartData.Bars.Count -eq 7 -and (Near $chartData.Peak 7) -and (Near $chartData.Credits 28) -and (Near $chartData.Tokens 280) -and $chartData.HasData) 'chart totals and peak come from the selected range and grouping'
 Check ((Near $chartData.Bars[0].Ratio (1/7.0)) -and $chartData.Bars[-1].Ratio -eq 1.0 -and $chartData.Bars[-1].Height -eq 104.0 -and (Near $chartData.Bars[0].Height 14.9)) 'bar heights normalize credits against the peak'
 Check ((Get-QmStatsChartData $synthetic 'quarter').Bars.Count -eq 7 -and (Get-QmStatsChartData $synthetic 'month').Bars[0].Key -eq '2026-02') 'unknown grouping falls back to days and months key correctly'
 $chartMonths=@(Get-QmStatsChartData $synthetic 'month')
 Check ($chartMonths.Bars.Count -eq 3 -and $chartMonths.Bars[0].Label -eq '2 月' -and $chartMonths.Bars[-1].Label -eq '4 月') 'monthly chart labels reuse the period wording'
 $fifteen=@(1..15|ForEach-Object {New-Day ('2026-05-'+($_.ToString('00',$inv))) (10+$_) (20+$_) 'A'})
 $capped=Get-QmStatsChartData ([pscustomobject]@{Days=$fifteen}) 'day'
 Check ($capped.Bars.Count -eq 12 -and $capped.Bars[0].Key -eq '2026-05-04' -and $capped.Bars[-1].Key -eq '2026-05-15') 'the chart keeps only the newest twelve periods in ascending order'
 $zeroPeak=Get-QmStatsChartData ([pscustomobject]@{Days=@((New-Day '2026-05-01' 0 0 'A'))}) 'day'
 Check ($zeroPeak.HasData -and (Near $zeroPeak.Peak 0) -and $zeroPeak.Bars[0].Height -eq 0.0) 'a zero-credit period renders no bar height instead of dividing by zero'
 $emptyChart=Get-QmStatsChartData ([pscustomobject]@{Days=@()}) 'day'
 Check (-not $emptyChart.HasData -and $emptyChart.Bars.Count -eq 0) 'an empty range reports no chart data'
 Check ((Get-QmStatsBarTip 'day' '2026-04-01' $series[-1]) -eq "2026-04-01`n7.00 积分 · ≈ 70 Token · 1 请求 · 1 天有记录`nD 7.00分/≈70") 'daily bar tips add active days and model shares'
 Check ((Get-QmStatsBarTip 'week' '2026-03-02' $weeks[2]) -like '2026-03-02 ~ 2026-03-08（03-02 ~ 03-08）*') 'weekly bar tips keep the fixed date span'
 Check ((Get-QmStatsBarTip 'month' '2026-03' $chartMonths.Bars[1].Period) -like '2026-03月*' -and (Get-QmStatsBarTip 'month' '2026-03' $chartMonths.Bars[1].Period) -match '天有记录') 'monthly bar tips name the calendar month and active days'

 # ---------------------------------------------------------------- model shares
 function New-Model([string]$name,[double]$credits,[double]$tokens,[bool]$estimated){
  return [pscustomobject]@{Name=$name;Credits=$credits;Tokens=$tokens;Requests=1L;Estimated=$estimated}
 }
 function New-Models([object[]]$specs){
  $list=New-Object System.Collections.Generic.List[object]
  foreach($spec in $specs){$list.Add((New-Model ([string]$spec[0]) ([double]$spec[1]) ([double]$spec[2]) ([bool]$spec[3])))}
  return $list.ToArray()
 }
 $creditShares=Get-QmStatsModelShares ([pscustomobject]@{Models=(New-Models @(@('A',3,10,$false),@('B',1,5,$true)))})
 Check ($creditShares.Basis -eq 'credits' -and $creditShares.HasData -and (Near $creditShares.Rows[0].Share 0.75) -and $creditShares.Rows[0].Percent -eq 75 -and $creditShares.Rows[1].Percent -eq 25) 'credits drive the share when the total is positive'
 Check ($creditShares.Rows[1].Estimated -and $creditShares.Rows[1].Name -eq 'B') 'estimation flags survive the share pass-through'
 $tokenShares=Get-QmStatsModelShares ([pscustomobject]@{Models=(New-Models @(@('A',0,10,$false),@('B',0,5,$false)))})
 Check ($tokenShares.Basis -eq 'tokens' -and $tokenShares.HasData -and (Near $tokenShares.Rows[0].Share (10/15.0)) -and $tokenShares.Rows[0].Percent -eq 67) 'zero credits fall back to token shares'
 $deadShares=Get-QmStatsModelShares ([pscustomobject]@{Models=(New-Models @(@('A',0,0,$false)))})
 Check ($deadShares.Basis -eq '' -and -not $deadShares.HasData -and $deadShares.Rows[0].Share -eq 0.0) 'credits and tokens both zero leaves the card empty'
 $manyShares=Get-QmStatsModelShares ([pscustomobject]@{Models=(New-Models @(@('A',5,50,$false),@('B',4,40,$false),@('C',3,30,$false),@('D',2,20,$false),@('E',1,10,$false)))})
 Check ($manyShares.Rows.Count -eq 4 -and $manyShares.Rows[-1].Name -eq '其他 2 个' -and (Near (($manyShares.Rows|Measure-Object -Property Share -Sum).Sum) 1.0)) 'overflow models collapse into one counted remainder row'

 # ---------------------------------------------------------------- auto summary
 Check ((Format-QmStatsDelta 5 0) -eq '新增' -and (Format-QmStatsDelta 0 0) -eq '上一周期无记录') 'a zero previous period never becomes a division'
 Check ((Format-QmStatsDelta 110 100) -eq '+10%' -and (Format-QmStatsDelta 90 100) -eq '-10%' -and (Format-QmStatsDelta 100 100) -eq '基本持平') 'period deltas are rounded percentages'
 Check ((Format-QmStatsDelta 100.4 100) -eq '基本持平' -and (Format-QmStatsDelta 100.5 100) -eq '+1%') 'fractional deltas round away from zero'
 function Write-InsightCache([string]$dir,[hashtable]$days){
  $document=[ordered]@{version=1;at=(QmNowMs);rows=0;days=[ordered]@{}}
  $total=0L
  foreach($key in $days.Keys){
   $day=$days[$key]
   $models=[ordered]@{}
   foreach($name in @($day.models.Keys)){
    $model=$day.models[$name]
    $models[$name]=[ordered]@{credits=[double]$model.credits;tokens=[double]$model.tokens;requests=[long]$model.requests;estimated=[bool]$model.estimated}
    $total+=[long]$model.requests
   }
   $document.days[$key]=[ordered]@{credits=[double]$day.credits;tokens=[double]$day.tokens;requests=[long]$day.requests;estimated=[bool]$day.estimated;models=$models}
  }
  $document.rows=$total
  [void][IO.Directory]::CreateDirectory($dir)
  [IO.File]::WriteAllText((Join-Path $dir 'stats-cache.json'),(ConvertTo-Json -InputObject $document -Depth 10 -Compress),$utf8)
 }
 function New-Bucket([double]$credits,[double]$tokens,[long]$requests,[bool]$estimated,[string]$model){
  return @{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated;models=@{$model=@{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated}}}
 }
 $insightsSettings=Join-Path $tempRoot 'insight-settings'
 $insightDays=@{}
 $insightDays[(Day-Key 0)]=(New-Bucket 10.0 100.0 2L $true 'auto')
 $insightDays[(Day-Key 1)]=(New-Bucket 5.0 50.0 1L $false 'auto')
 $insightDays[(Day-Key 8)]=(New-Bucket 3.0 30.0 1L $false 'cmodel')
 $insightDays[(Day-Key 40)]=(New-Bucket 7.0 70.0 1L $false 'auto')
 Write-InsightCache $insightsSettings $insightDays
 $script:QM_SETTINGSD=$insightsSettings;Reset-CacheState
 $windows=@(Get-QmStatsInsightWindows)
 Check ($windows.Count -eq 4 -and (($windows|ForEach-Object {[string]$_.Key}) -join '|') -eq 'today|week|month|all') 'auto summary always covers today, seven days, month and all'
 $relationOk=$true
 foreach($entry in $windows){
  $span=($entry.End-$entry.Start).Days+1
  $prevSpan=($entry.PrevEnd-$entry.PrevStart).Days+1
  if($span -ne $prevSpan -or $entry.PrevEnd.AddDays(1) -ne $entry.Start){$relationOk=$false}
 }
 Check $relationOk 'every comparison window is the immediately preceding period of equal length'
 Check ($windows[3].Start -eq $today.AddDays(-40) -and $windows[3].End -eq $today) 'the all window follows the cached dates, not the selected range'
 $ins=@(Get-QmStatsInsights)
 Check ($ins.Count -eq 4 -and (Near $ins[0].Credits 10) -and $ins[0].ActiveDays -eq 1 -and $ins[0].Requests -eq 2 -and (Near $ins[0].PrevCredits 5) -and $ins[0].Delta -eq '+100%') 'today compares against yesterday with a rounded increase'
 Check ($ins[0].Estimated -and $ins[0].TopModel -eq 'Auto') 'estimated days keep the estimation flag and the friendly top model'
 Check ($ins[0].Summary -eq '活跃 1 天 · 较昨日 +100% · 主力 Auto') 'today summary is a single rule-generated sentence'
 Check ($ins[1].ActiveDays -eq 2 -and (Near $ins[1].Credits 15) -and $ins[1].Delta -eq '+400%') 'the seven day window totals today and yesterday against the previous week'
 Check ($ins[3].Delta -eq '新增' -and $ins[3].ActiveDays -eq 4 -and (Near $ins[3].DailyCredits (25/4.0)) -and $ins[3].Summary -like '*日均 6.25 积分') 'the all window adds a daily average and reports growth over an empty predecessor'
 $quietSettings=Join-Path $tempRoot 'quiet-settings'
 $quietDays=@{}
 $quietDays[(Day-Key 1)]=(New-Bucket 5.0 50.0 1L $false 'auto')
 Write-InsightCache $quietSettings $quietDays
 $script:QM_SETTINGSD=$quietSettings;Reset-CacheState
 $quiet=@(Get-QmStatsInsights)
 Check ($quiet[0].HasData -eq $false -and $quiet[0].Summary -eq '暂无用量记录' -and $quiet[0].Delta -eq '') 'a period without records states it plainly instead of dividing'
 Check ($quiet[1].HasData -and $quiet[1].Delta -eq '新增') 'a first record is reported as new rather than a percentage'
 $emptyInsights=Join-Path $tempRoot 'no-data-settings'
 Write-InsightCache $emptyInsights @{}
 $script:QM_SETTINGSD=$emptyInsights;Reset-CacheState
 $none=@(Get-QmStatsInsights)
 Check ($none.Count -eq 4 -and (@($none|Where-Object {-not $_.HasData}).Count -eq 4) -and (@($none|Where-Object {$_.Summary -ne '暂无用量记录'}).Count -eq 0)) 'an empty cache leaves every summary window without records'
 Check ($none[3].Start -eq $today -and $none[3].End -eq $today -and -not (Get-QmStatsChartData (Get-QmStatsAllData) 'day').HasData) 'an empty cache gives the all window a zero-length range and no chart'
 $script:QM_PROJECTS=$mainProjects;$script:QM_SETTINGSD=$mainSettings;Reset-CacheState;Get-QmStatsCache|Out-Null

 # ---------------------------------------------------------------- view tab config
 $freshTabs=New-QmConfig
 Check ($freshTabs.statsTab -eq 'overview') 'new configuration defaults to the overview tab'
 $merged=Merge-QmConfig ([pscustomobject]@{statsTab='detail'})
 Check ($merged.statsTab -eq 'detail' -and $merged.statsRange -eq '7d') 'a saved detail tab survives reload'
 $merged=Merge-QmConfig ([pscustomobject]@{statsTab='chart'})
 Check ($merged.statsTab -eq 'overview') 'an unknown tab resets to the overview default'
 $merged=Merge-QmConfig ([pscustomobject]@{statsRange='year';statsGroup='week'})
 Check ($merged.statsTab -eq 'overview' -and $merged.statsRange -eq 'year') 'a missing tab keeps the default while other keys merge'
 $merged=Merge-QmConfig ([pscustomobject]@{statsTab='detail';skin='dusk'})
 Check ($merged.statsTab -eq 'detail' -and $merged.skin -eq 'dusk') 'the tab merges alongside unrelated settings'
 $script:CFG=New-QmConfig;$script:CFG.statsTab='detail';Save-QmConfig
 $saved=Read-QmConfig
 Check ($saved.statsTab -eq 'detail' -and $saved.statsRange -eq '7d') 'the statistics tab persists through the config file'
 $script:CFG.statsTab='broken';Save-QmConfig
 Check ((Read-QmConfig).statsTab -eq 'overview') 'a written invalid tab is normalized on the next load'
 $script:CFG=New-QmConfig
 Write-Output ('PASS='+$script:pass+' FAIL='+$script:fail)
 if($script:fail){exit 1}
}finally{
 if($lock){$lock.Dispose()}
 if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
