# 本地用量统计：只读扫描 .qoder/projects 的会话 JSONL。
# 不访问账户接口、不写 Qoder 数据；聚合结果缓存在 Meter 自己的设置目录。
$script:QM_STATS_RANGES=[ordered]@{'7d'='7 天';'30d'='近 30 天';'month'='本月';'year'='近一年'}
$script:QM_STATS_GROUPS=[ordered]@{day='按日';week='按周';month='按月'}
$script:QM_STATS_TABS=[ordered]@{overview='总览';detail='明细'}
$script:QM_STATS_UNITS=@{day='天';week='周';month='个月'}
$script:QM_STATS_PAGE_SIZE=6
$script:QM_STATS_CHART_MAX=12
$script:QM_STATS_CHART_HEIGHT=104
$script:QM_STATS_CACHE_MS=10*60*1000
$script:QM_STATS_CACHE=$null
$script:QM_STATS_CACHE_LOADED=$false
$script:QM_STATS_CACHE_PATH_LOADED=''
$script:QM_STATS_PAGE=0
$script:QM_STATS_REFS=$null
$script:QM_STATS_ERROR=''
# 与 macOS 版一致的 Qoder 内部模型 id 展示名；日志里出现未知 id 时保留原值。
$script:QM_MODEL_LABELS=@{
 auto='Auto';cmodel='Cantus';dfmodel='DeepSeek-V4-Flash';dmodel='DeepSeek-V4-Pro'
 efficient='Efficient';gfmodel='GLM-5.3-Flash';gmodel='GLM-5.3';kmodel='Kimi-K2.7-Code'
 kmodel_latest='Kimi-K3';lite='Lite';mmodel='MiniMax-M3';performance='Performance'
 qfmodel='Qwen3.8-Flash';qmodel='Qwen3.7-Plus';qmodel_38max='Qwen3.8-Max'
 qmodel_latest='Qwen3.7-Max';ultimate='Ultimate'
}

function Get-QmStatsCachePath { return (Join-Path $script:QM_SETTINGSD 'stats-cache.json') }

function Get-QmFriendlyModel([string]$name) {
 $raw=([string]$name).Trim()
 if(!$raw){return '未知模型'}
 $key=$raw;$slash=$key.LastIndexOf('/')
 if($slash -ge 0){$key=$key.Substring($slash+1)}
 $key=$key.ToLowerInvariant() -replace '^qoder[-_]',''
 if($script:QM_MODEL_LABELS.ContainsKey($key)){return $script:QM_MODEL_LABELS[$key]}
 if($key -eq 'unknown' -or $key -eq 'none'){return '未知模型'}
 return ($raw -replace '_','-')
}

function Sort-QmStatsModels($models) {
 return @($models | Sort-Object -Property `
  @{Expression={[double]$_.Credits};Descending=$true},`
  @{Expression={[double]$_.Tokens};Descending=$true},`
  @{Expression={[string]$_.Name};Descending=$false})
}

function ConvertTo-QmStatsCache($obj) {
 if($null -eq $obj){return $null}
 $version=0
 try{$version=[int]$obj.version}catch{return $null}
 if($version -ne 1){return $null}
 $at=0L;$rows=0L
 try{$at=[long]$obj.at;$rows=[long]$obj.rows}catch{return $null}
 if($at -le 0 -or $at -gt ((QmNowMs)+86400000)){return $null}
 if($null -eq $obj.days){return $null}
 $days=@{}
 foreach($property in @($obj.days.PSObject.Properties)){
  $key=[string]$property.Name
  if($key -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $source=$property.Value
  if($null -eq $source){continue}
  $credits=0.0;$tokens=0.0;$requests=0L;$estimated=$false
  try{
   $credits=[double]$source.credits;$tokens=[double]$source.tokens
   $requests=[long]$source.requests;$estimated=[bool]$source.estimated
  }catch{continue}
  if($credits -lt 0 -or $tokens -lt 0 -or $requests -lt 0){continue}
  $models=@{}
  if($null -ne $source.models){
   foreach($mp in @($source.models.PSObject.Properties)){
    $name=[string]$mp.Name;if(!$name){continue}
    $m=$mp.Value;if($null -eq $m){continue}
    try{
     $mc=[double]$m.credits;$mt=[double]$m.tokens;$mr=[long]$m.requests;$me=[bool]$m.estimated
    }catch{continue}
    if($mc -lt 0 -or $mt -lt 0 -or $mr -lt 0){continue}
    $models[$name]=@{credits=$mc;tokens=$mt;requests=$mr;estimated=$me}
   }
  }
  $days[$key]=@{credits=$credits;tokens=$tokens;requests=$requests;estimated=$estimated;models=$models}
 }
 return @{at=$at;rows=$rows;days=$days}
}

function Read-QmStatsCacheFile {
 $path=Get-QmStatsCachePath
 try{
  if(!(Test-Path -LiteralPath $path)){return $null}
  $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
  if(!$text){return $null}
  return (ConvertTo-QmStatsCache ($text|ConvertFrom-Json))
 }catch{Write-QmLog ('统计缓存读取失败: '+$_.Exception.Message);return $null}
}

function Save-QmStatsCacheFile($cache) {
 if(!$cache){return}
 try{
  $path=Get-QmStatsCachePath;$dir=Split-Path $path -Parent
  if(!(Test-Path -LiteralPath $dir)){[void][IO.Directory]::CreateDirectory($dir)}
  $document=[ordered]@{version=1;at=[long]$cache.at;rows=[long]$cache.rows;days=[ordered]@{}}
  foreach($key in @($cache.days.Keys)){
   $day=$cache.days[$key]
   $models=[ordered]@{}
   foreach($name in @($day.models.Keys)){
    $m=$day.models[$name]
    $models[$name]=[ordered]@{credits=[double]$m.credits;tokens=[double]$m.tokens;requests=[long]$m.requests;estimated=[bool]$m.estimated}
   }
   $document.days[$key]=[ordered]@{credits=[double]$day.credits;tokens=[double]$day.tokens;requests=[long]$day.requests;estimated=[bool]$day.estimated;models=$models}
  }
  $json=ConvertTo-Json -InputObject $document -Depth 8 -Compress
  $tmp=$path+'.tmp'
  [IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false))
  if(Test-Path -LiteralPath $path){[IO.File]::Replace($tmp,$path,[NullString]::Value)}else{[IO.File]::Move($tmp,$path)}
 }catch{Write-QmLog ('统计缓存保存失败: '+$_.Exception.Message)}
}

function Get-QmStatsContentChars($content) {
 $chars=0;$cjk=0
 foreach($b in @($content)){
  if($null -eq $b){continue}
  $bt=DictVal $b 'type';$text=''
  if($bt -eq 'text'){$text=[string](DictVal $b 'text')}
  elseif($bt -eq 'thinking'){$text=[string](DictVal $b 'thinking')}
  elseif($bt -eq 'tool_use'){
   $value=$null
   if($b -is [System.Collections.IDictionary]){$value=$b['input']}
   elseif($b.PSObject.Properties['input']){$value=$b.input}
   $text=try{[QoderMeter.JsonEstimate]::ToolInput($value)}catch{''}
   if($null -eq $text){$text=''}
  }else{continue}
  $chars+=$text.Length
  $cjk+=$script:QM_CJK.Matches($text).Count
 }
 return @{Chars=$chars;Cjk=$cjk;Estimated=[QoderMeter.JsonEstimate]::Round($cjk/1.35+[math]::Max(0,$chars-$cjk)/3.8)}
}

function Update-QmStatsCache {
 $now=QmNowMs;$days=@{};$seen=@{};$rows=0L;$errorText='';$files=@()
 try{
  if(Test-Path -LiteralPath $script:QM_PROJECTS){
   $files=@(Get-ChildItem -LiteralPath $script:QM_PROJECTS -Recurse -File -Filter '*.jsonl' -Force -ErrorAction SilentlyContinue)
  }
 }catch{$errorText='无法读取 Qoder 项目目录';Write-QmLog ('统计目录读取失败: '+$_.Exception.Message)}
 foreach($file in $files){
  $stream=$null;$reader=$null
  try{
   $stream=[IO.FileStream]::new($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
   $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
   while($null -ne ($line=$reader.ReadLine())){
    if($line.Length -lt 16){continue}
    # 先做廉价的子串过滤，再解析 JSON；日志中绝大多数行不是带用量的助手记录。
    if($line.IndexOf('"assistant"',[StringComparison]::Ordinal) -lt 0){continue}
    if($line.IndexOf('"usage"',[StringComparison]::Ordinal) -lt 0){continue}
    if($line.IndexOf('"credits"',[StringComparison]::Ordinal) -lt 0){continue}
    $entry=ConvertFrom-JsonLine $line
    if(!$entry){continue}
    if([string](DictVal $entry 'type') -ne 'assistant'){continue}
    $message=DictVal $entry 'message';if(!$message){continue}
    $usage=DictVal $message 'usage';if(!$usage){continue}
    if($null -eq (DictVal $usage 'credits')){continue}
    $ts=QmParseTs (DictVal $entry 'timestamp');if(!$ts){continue}
    $rid=[string](DictVal $usage 'request_id')
    if($rid){if($seen.ContainsKey($rid)){continue};$seen[$rid]=$true}
    $local=[DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToLocalTime()
    $key=$local.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $credits=[math]::Max(0.0,(NumVal $usage 'credits'))
    $exact=(NumVal $usage 'input_tokens')+(NumVal $usage 'cache_read_input_tokens')+
      (NumVal $usage 'cache_creation_input_tokens')+(NumVal $usage 'output_tokens')
    if($exact -lt 0){$exact=0}
    $tokens=0.0;$estimated=$false
    if($exact -gt 0){$tokens=$exact}
    else{
     $shape=Get-QmStatsContentChars (DictVal $message 'content')
     $tokens=[double]$shape.Estimated
     $estimated=$tokens -gt 0
    }
    $model=[string](DictVal $message 'model');if(!$model){$model='unknown'}
    if(!$days.ContainsKey($key)){
     $days[$key]=@{credits=0.0;tokens=0.0;requests=0L;estimated=$false;models=@{}}
    }
    $day=$days[$key]
    $day.credits+=$credits;$day.tokens+=$tokens;$day.requests++
    if($estimated){$day.estimated=$true}
    if(!$day.models.ContainsKey($model)){
     $day.models[$model]=@{credits=0.0;tokens=0.0;requests=0L;estimated=$false}
    }
    $m=$day.models[$model]
    $m.credits+=$credits;$m.tokens+=$tokens;$m.requests++
    if($estimated){$m.estimated=$true}
    $rows++
   }
  }catch{$errorText='部分日志无法读取';Write-QmLog ('统计文件读取失败 '+$file.Name+': '+$_.Exception.Message)}
  finally{
   if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}
  }
 }
 $cache=@{at=$now;rows=$rows;days=$days}
 $script:QM_STATS_CACHE=$cache
 $script:QM_STATS_CACHE_LOADED=$true
 $script:QM_STATS_CACHE_PATH_LOADED=Get-QmStatsCachePath
 $script:QM_STATS_ERROR=$errorText
 Save-QmStatsCacheFile $cache
 return $cache
}

function Get-QmStatsCache([switch]$Force) {
 $path=Get-QmStatsCachePath
 if(!$script:QM_STATS_CACHE_LOADED -or $script:QM_STATS_CACHE_PATH_LOADED -ne $path){
  $script:QM_STATS_CACHE=Read-QmStatsCacheFile
  $script:QM_STATS_CACHE_LOADED=$true
  $script:QM_STATS_CACHE_PATH_LOADED=$path
 }
 $cache=$script:QM_STATS_CACHE
 if(!$Force -and $cache -and ((QmNowMs)-[long]$cache.at) -lt $script:QM_STATS_CACHE_MS){return $cache}
 return (Update-QmStatsCache)
}

function Get-QmStatsRangeStart([string]$range) {
 $today=[datetime]::Today
 switch($range){
  'month'{return [datetime]::new($today.Year,$today.Month,1)}
  '30d'{return $today.AddDays(-29)}
  'year'{return $today.AddDays(-364)}
  default{return $today.AddDays(-6)}
 }
}

function Get-QmStatsWindow([datetime]$start,[datetime]$end,[string]$range='') {
 $cache=Get-QmStatsCache
 $startKey=$start.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
 $endKey=$end.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
 $credits=0.0;$tokens=0.0;$requests=0L;$estimated=$false
 $modelMap=@{};$dayList=New-Object System.Collections.Generic.List[object]
 $keys=@($cache.days.Keys);[Array]::Sort($keys,[StringComparer]::Ordinal);[Array]::Reverse($keys)
 foreach($key in $keys){
  if([StringComparer]::Ordinal.Compare($key,$startKey) -lt 0){continue}
  if([StringComparer]::Ordinal.Compare($key,$endKey) -gt 0){continue}
  $day=$cache.days[$key]
  $credits+=[double]$day.credits;$tokens+=[double]$day.tokens;$requests+=[long]$day.requests
  if($day.estimated){$estimated=$true}
  $dayModels=@{}
  foreach($rawName in @($day.models.Keys)){
   $source=$day.models[$rawName];$name=Get-QmFriendlyModel $rawName
   if(!$dayModels.ContainsKey($name)){$dayModels[$name]=[pscustomobject]@{Name=$name;Credits=0.0;Tokens=0.0;Requests=0L;Estimated=$false}}
   $dm=$dayModels[$name]
   $dm.Credits+=[double]$source.credits;$dm.Tokens+=[double]$source.tokens;$dm.Requests+=[long]$source.requests
   if($source.estimated){$dm.Estimated=$true}
   if(!$modelMap.ContainsKey($name)){$modelMap[$name]=[pscustomobject]@{Name=$name;Credits=0.0;Tokens=0.0;Requests=0L;Estimated=$false}}
   $mm=$modelMap[$name]
   $mm.Credits+=[double]$source.credits;$mm.Tokens+=[double]$source.tokens;$mm.Requests+=[long]$source.requests
   if($source.estimated){$mm.Estimated=$true}
  }
  $dayList.Add([pscustomobject]@{
   Key=$key;Credits=[double]$day.credits;Tokens=[double]$day.tokens;Requests=[long]$day.requests
   Estimated=[bool]$day.estimated;Models=@(Sort-QmStatsModels $dayModels.Values)
  })
 }
 return [pscustomobject]@{
  Range=$range;Start=$start;End=$end;Credits=$credits;Tokens=$tokens;Requests=$requests
  Estimated=$estimated;ActiveDays=$dayList.Count;Days=$dayList.ToArray()
  Models=@(Sort-QmStatsModels $modelMap.Values);At=[long]$cache.at;Rows=[long]$cache.rows
 }
}

function Get-QmStatsData([string]$range) {
 if(!$script:QM_STATS_RANGES.Contains($range)){$range='7d'}
 return Get-QmStatsWindow (Get-QmStatsRangeStart $range) ([datetime]::Today) $range
}

# 全部窗口只使用当前 cache 里合法的本地日期，不引入额外的扫描语义。
function Get-QmStatsAllData {
 $cache=Get-QmStatsCache
 $today=[datetime]::Today
 $keys=@($cache.days.Keys|Where-Object {[string]$_ -match '^\d{4}-\d{2}-\d{2}$'})
 if($keys.Count -eq 0){return Get-QmStatsWindow $today $today 'all'}
 $sorted=@($keys);[Array]::Sort($sorted,[StringComparer]::Ordinal)
 $start=Get-QmStatsDayDate ([string]$sorted[0])
 if($start -eq [datetime]::MinValue -or $start -gt $today){$start=$today}
 return Get-QmStatsWindow $start $today 'all'
}

function Get-QmStatsDayDate([string]$key) {
 try{return [datetime]::ParseExact($key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}catch{return [datetime]::MinValue}
}

function Get-QmStatsWeekKey([string]$key) {
 $date=Get-QmStatsDayDate $key
 if($date -eq [datetime]::MinValue){return $key}
 $start=$date.Date.AddDays(-(([int]$date.DayOfWeek+6)%7))
 return $start.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
}

function Get-QmStatsPeriodKey([string]$group,[string]$key) {
 if($group -eq 'week'){return Get-QmStatsWeekKey $key}
 if($group -eq 'month'){if($key.Length -ge 7){return $key.Substring(0,7)}}
 return $key
}

function Get-QmStatsPeriodLabel([string]$group,[string]$key) {
 $today=[datetime]::Today
 $inv=[Globalization.CultureInfo]::InvariantCulture
 if($group -eq 'week'){
  $current=Get-QmStatsWeekKey $today.ToString('yyyy-MM-dd',$inv)
  if($key -eq $current){return '本周'}
  if($key -eq (Get-QmStatsDayDate $current).AddDays(-7).ToString('yyyy-MM-dd',$inv)){return '上周'}
  $start=Get-QmStatsDayDate $key;if($start -eq [datetime]::MinValue){return $key}
  return $start.ToString('MM-dd',$inv)+' ~ '+$start.AddDays(6).ToString('MM-dd',$inv)
 }
 if($group -eq 'month'){
  $current=$today.ToString('yyyy-MM',$inv)
  if($key -eq $current){return '本月'}
  if($key -eq $today.AddMonths(-1).ToString('yyyy-MM',$inv)){return '上月'}
  $parts=$key.Split('-');if($parts.Count -ne 2){return $key}
  $month=0;if(![int]::TryParse($parts[1],[ref]$month)){return $key}
  $monthText=$month.ToString($inv)
  if($parts[0] -eq $today.Year.ToString($inv)){return $monthText+' 月'}
  return $parts[0]+'年'+$monthText+'月'
 }
 $date=Get-QmStatsDayDate $key;if($date -eq [datetime]::MinValue){return $key}
 if($date.Date -eq $today){return '今天'}
 if($date.Date -eq $today.AddDays(-1)){return '昨天'}
 return $date.ToString('MM-dd',$inv)
}

function Format-QmStatsTokens($value) {
 if($null -eq $value -or $value -le 0){return '0'}
 return Format-QmK $value
}

function Get-QmStatsPeriodTip([string]$group,$key,$period) {
 $inv=[Globalization.CultureInfo]::InvariantCulture
 $tokenText=$(if($period.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $period.Tokens)
 $metric=(Format-QmCredits $period.Credits)+' 积分 · '+$tokenText+' Token · '+$period.Requests+' 请求'
 if($group -eq 'week'){
  $start=Get-QmStatsDayDate $key
  if($start -ne [datetime]::MinValue){
   return $start.ToString('yyyy-MM-dd',$inv)+' ~ '+$start.AddDays(6).ToString('yyyy-MM-dd',$inv)+' · '+$period.ActiveDays+' 天有记录'+"`n"+$metric
  }
 }
 if($group -eq 'month'){return $key+' · '+$period.ActiveDays+' 天有记录'+"`n"+$metric}
 return $key+"`n"+$metric
}

function Get-QmStatsPeriods($data,[string]$group) {
 if(!$script:QM_STATS_GROUPS.Contains($group)){$group='day'}
 $periods=@{}
 $models=@{}
 foreach($day in @($data.Days)){
  $key=Get-QmStatsPeriodKey $group ([string]$day.Key)
  if(!$periods.ContainsKey($key)){
   $periods[$key]=@{Key=$key;Credits=0.0;Tokens=0.0;Requests=0L;Estimated=$false;ActiveDays=0}
   $models[$key]=@{}
  }
  $period=$periods[$key]
  $period.Credits+=[double]$day.Credits;$period.Tokens+=[double]$day.Tokens;$period.Requests+=[long]$day.Requests
  $period.ActiveDays++
  if($day.Estimated){$period.Estimated=$true}
  foreach($model in @($day.Models)){
   $name=[string]$model.Name
   if(!$models[$key].ContainsKey($name)){$models[$key][$name]=[pscustomobject]@{Name=$name;Credits=0.0;Tokens=0.0;Estimated=$false}}
   $m=$models[$key][$name]
   $m.Credits+=[double]$model.Credits;$m.Tokens+=[double]$model.Tokens
   if($model.Estimated){$m.Estimated=$true}
  }
 }
 $list=New-Object System.Collections.Generic.List[object]
 foreach($key in @($periods.Keys)){
  $period=$periods[$key]
  $list.Add([pscustomobject]@{
   Key=[string]$period.Key;Credits=[double]$period.Credits;Tokens=[double]$period.Tokens
   Requests=[long]$period.Requests;Estimated=[bool]$period.Estimated;ActiveDays=[int]$period.ActiveDays
   Models=@(Sort-QmStatsModels $models[$key].Values)
  })
 }
 $array=$list.ToArray()
 [Array]::Sort($array,[Comparison[object]]{
  param($a,$b)
  return [StringComparer]::Ordinal.Compare([string]$b.Key,[string]$a.Key)
 })
 return $array
}

function Get-QmStatsModelRows($models) {
 $array=@($models)
 if($array.Count -le 4){return $array}
 $rows=New-Object System.Collections.Generic.List[object]
 for($i=0;$i -lt 3;$i++){$rows.Add($array[$i])}
 $other=[pscustomobject]@{Name='其他 '+($array.Count-3)+' 个';Credits=0.0;Tokens=0.0;Requests=0L;Estimated=$false}
 for($i=3;$i -lt $array.Count;$i++){
  $other.Credits+=[double]$array[$i].Credits;$other.Tokens+=[double]$array[$i].Tokens
  if($array[$i].Estimated){$other.Estimated=$true}
 }
 $rows.Add($other)
 return $rows.ToArray()
}

function Get-QmStatsTopModelsText($period) {
 $models=@($period.Models);$parts=@()
 $limit=[math]::Min(2,$models.Count)
 for($i=0;$i -lt $limit;$i++){
  $m=$models[$i]
  $parts+=$m.Name+' '+(Format-QmCredits $m.Credits)+'分/'+$(if($m.Estimated){'≈'}else{''})+(Format-QmStatsTokens $m.Tokens)
 }
 if($models.Count -gt $limit){$parts+='+'+($models.Count-$limit)}
 return ($parts -join ' · ')
}

function Get-QmStatsRangeText($data) {
 $inv=[Globalization.CultureInfo]::InvariantCulture
 $sameYear=$data.Start.Year -eq $data.End.Year
 $left=$(if($sameYear){$data.Start.ToString('MM-dd',$inv)}else{$data.Start.ToString('yyyy-MM-dd',$inv)})
 $right=$(if($sameYear){$data.End.ToString('MM-dd',$inv)}else{$data.End.ToString('yyyy-MM-dd',$inv)})
 return $left+' ~ '+$right+' · 活跃 '+$data.ActiveDays+' 天'
}

function Format-QmStatsClock([long]$ms) {
 if($ms -le 0){return '—'}
 try{return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)}catch{return '—'}
}

# ---------------------------------------------------------------- 图表与自动摘要（纯计算）
# 趋势只展示最近 12 期并按周期升序排列，柱高按积分对峰值归一；无数据时留给空态。
function Get-QmStatsSeries($data,[string]$group) {
 if(!$script:QM_STATS_GROUPS.Contains($group)){$group='day'}
 $periods=@(Get-QmStatsPeriods $data $group)
 $take=[math]::Min($script:QM_STATS_CHART_MAX,$periods.Count)
 $recent=@($periods|Select-Object -First $take)
 [Array]::Reverse($recent)
 return $recent
}

function Get-QmStatsChartData($data,[string]$group) {
 if(!$script:QM_STATS_GROUPS.Contains($group)){$group='day'}
 $series=@(Get-QmStatsSeries $data $group)
 $peak=0.0;$credits=0.0;$tokens=0.0
 foreach($item in $series){
  if([double]$item.Credits -gt $peak){$peak=[double]$item.Credits}
  $credits+=[double]$item.Credits;$tokens+=[double]$item.Tokens
 }
 $bars=New-Object System.Collections.Generic.List[object]
 foreach($item in $series){
  $ratio=$(if($peak -gt 0){[math]::Max(0.0,[math]::Min(1.0,[double]$item.Credits/$peak))}else{0.0})
  $height=$(if($ratio -gt 0){[math]::Max(2.0,[math]::Round($ratio*$script:QM_STATS_CHART_HEIGHT,1))}else{0.0})
  $bars.Add([pscustomobject]@{
   Key=[string]$item.Key;Label=(Get-QmStatsPeriodLabel $group ([string]$item.Key))
   Ratio=$ratio;Height=$height;Peak=$peak;Period=$item
  })
 }
 return [pscustomobject]@{Group=$group;Bars=$bars.ToArray();Series=$series;Peak=$peak
  Credits=$credits;Tokens=$tokens;HasData=($series.Count -gt 0)}
}

function Get-QmStatsBarTip([string]$group,$key,$period) {
 $inv=[Globalization.CultureInfo]::InvariantCulture
 $text=[string]$key;$dates=$text
 if($group -eq 'week'){
  $start=Get-QmStatsDayDate $text
  if($start -ne [datetime]::MinValue){$dates=$start.ToString('yyyy-MM-dd',$inv)+' ~ '+$start.AddDays(6).ToString('yyyy-MM-dd',$inv)}
 }elseif($group -eq 'month'){
  if($text.Length -eq 7){$dates=$text+'月'}
 }
 $tokenText=$(if($period.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $period.Tokens)
 $metric=(Format-QmCredits $period.Credits)+' 积分 · '+$tokenText+' Token · '+$period.Requests+' 请求 · '+$period.ActiveDays+' 天有记录'
 $models=Get-QmStatsTopModelsText $period
 if(!$models){$models='暂无模型记录'}
 $label=Get-QmStatsPeriodLabel $group $text
 # 按日时“03-04”这类标签与信息行重复，只在今天/昨天等相对说法上补充。
 $head=$dates
 if($label -ne $dates -and -not ($group -eq 'day' -and $label -like '*-*')){$head=$dates+'（'+$label+'）'}
 return $head+"`n"+$metric+"`n"+$models
}

# 模型占比：总积分优先，积分全为 0 时退回 Token 占比，两者都为 0 交由界面显示空态。
function Get-QmStatsModelShares($data) {
 $all=@($data.Models)
 $totalCredits=0.0;$totalTokens=0.0
 foreach($m in $all){$totalCredits+=[double]$m.Credits;$totalTokens+=[double]$m.Tokens}
 $rows=@(Get-QmStatsModelRows $all)
 $basis='';$total=0.0
 if($totalCredits -gt 0){$basis='credits';$total=$totalCredits}
 elseif($totalTokens -gt 0){$basis='tokens';$total=$totalTokens}
 $list=New-Object System.Collections.Generic.List[object]
 foreach($m in $rows){
  $value=$(if($basis -eq 'credits'){[double]$m.Credits}elseif($basis -eq 'tokens'){[double]$m.Tokens}else{0.0})
  $share=$(if($total -gt 0){[math]::Max(0.0,[math]::Min(1.0,$value/$total))}else{0.0})
  $list.Add([pscustomobject]@{Name=[string]$m.Name;Credits=[double]$m.Credits;Tokens=[double]$m.Tokens
   Requests=[long]$m.Requests;Estimated=[bool]$m.Estimated;Share=$share;Percent=[int][math]::Round($share*100.0)})
 }
 return [pscustomobject]@{Rows=$list.ToArray();Basis=$basis;TotalCredits=$totalCredits
  TotalTokens=$totalTokens;Count=$all.Count;HasData=(($list.Count -gt 0) -and $basis -ne '')}
}

# 增减百分比按积分比较；上一周期为 0 时不做除法。
function Format-QmStatsDelta([double]$current,[double]$previous) {
 if($previous -le 0){if($current -gt 0){return '新增'};return '上一周期无记录'}
 $pct=[int][math]::Round((($current-$previous)/$previous)*100.0,[System.MidpointRounding]::AwayFromZero)
 if($pct -eq 0){return '基本持平'}
 if($pct -gt 0){return '+'+$pct+'%'}
 return '-'+([math]::Abs($pct))+'%'
}

function Get-QmStatsInsightWindows {
 $today=[datetime]::Today
 $monthStart=[datetime]::new($today.Year,$today.Month,1)
 $all=Get-QmStatsAllData
 $allStart=$all.Start;$allEnd=$all.End
 if($allStart -gt $allEnd){$allStart=$allEnd}
 $monthSpan=($today-$monthStart).Days+1
 $allSpan=($allEnd-$allStart).Days+1
 return @(
  [pscustomobject]@{Key='today';Title='今天';Start=$today;End=$today;PrevStart=$today.AddDays(-1);PrevEnd=$today.AddDays(-1);PrevLabel='较昨日'}
  [pscustomobject]@{Key='week';Title='近 7 天';Start=$today.AddDays(-6);End=$today;PrevStart=$today.AddDays(-13);PrevEnd=$today.AddDays(-7);PrevLabel='较上 7 天'}
  [pscustomobject]@{Key='month';Title='本月';Start=$monthStart;End=$today;PrevStart=$monthStart.AddDays(-$monthSpan);PrevEnd=$monthStart.AddDays(-1);PrevLabel='较上月同期'}
  [pscustomobject]@{Key='all';Title='全部';Start=$allStart;End=$allEnd;PrevStart=$allStart.AddDays(-$allSpan);PrevEnd=$allStart.AddDays(-1);PrevLabel='较上一周期'}
 )
}

# 固定分析今天 / 近 7 天 / 本月 / 全部，不受当前范围、粒度或视图 tab 影响。
function Get-QmStatsInsights {
 $list=New-Object System.Collections.Generic.List[object]
 foreach($window in @(Get-QmStatsInsightWindows)){
  $current=Get-QmStatsWindow $window.Start $window.End ([string]$window.Key)
  $previous=Get-QmStatsWindow $window.PrevStart $window.PrevEnd 'prev'
  $models=@($current.Models)
  $top=$(if($models.Count){[string]$models[0].Name}else{''})
  $active=[int]$current.ActiveDays
  $has=$active -gt 0
  $delta=$(if($has){Format-QmStatsDelta ([double]$current.Credits) ([double]$previous.Credits)}else{''})
  $daily=$(if($window.Key -eq 'all' -and $active -gt 0){[double]$current.Credits/$active}else{0.0})
  $parts=@()
  if($has){
   $parts+='活跃 '+$active+' 天'
   if($delta){$parts+=([string]$window.PrevLabel)+' '+$delta}
   if($top){$parts+='主力 '+$top}
   if($window.Key -eq 'all'){$parts+='日均 '+(Format-QmCredits $daily)+' 积分'}
  }
  $list.Add([pscustomobject]@{
   Key=[string]$window.Key;Title=[string]$window.Title;Start=$window.Start;End=$window.End
   Credits=[double]$current.Credits;Tokens=[double]$current.Tokens;Requests=[long]$current.Requests
   Estimated=[bool]$current.Estimated;ActiveDays=$active;HasData=$has
   TopModel=$top;Delta=$delta;PrevCredits=[double]$previous.Credits;DailyCredits=$daily
   Summary=$(if($has){$parts -join ' · '}else{'暂无用量记录'})
  })
 }
 return $list.ToArray()
}

# ------------------------------------------------------------------ 窗口
function Set-QmStatsPickState($button,[bool]$selected,[string]$skin) {
 if(!$button){return}
 $t=$script:QM_SKINS[$skin]
 $button.Background=Get-QmBrush $(if($selected){$t.greenTint}else{$t.grayTint})
 $button.BorderBrush=Get-QmBrush $(if($selected){$t.greenTint}else{$t.divider})
 $button.Foreground=Get-QmBrush $(if($selected){$t.green}else{$t.soft})
 $button.FontWeight=[Windows.FontWeightConverter]::new().ConvertFromString($(if($selected){'SemiBold'}else{'Normal'}))
}

function New-QmStatsPick([string]$text,[string]$command,$value,[string]$skin) {
 $b=[Windows.Controls.Button]::new();$b.Content=$text;$b.Tag=@{Command=$command;Value=$value}
 $b.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'QmGhostButton')
 $b.FontSize=11;$b.Height=26;$b.MinHeight=26;$b.MinWidth=52
 $b.Padding=[Windows.Thickness]::new(6,0,6,0);$b.Margin=[Windows.Thickness]::new(0,0,5,0)
 $b.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 return $b
}

function New-QmGlyphPlate([int]$glyph,[string]$color,[string]$tint,[double]$size) {
 $badge=[Windows.Controls.Border]::new();$badge.Width=$size;$badge.Height=$size
 $badge.CornerRadius=[Windows.CornerRadius]::new($size*0.32);$badge.Background=Get-QmBrush $tint
 $badge.VerticalAlignment='Center';$badge.Tag='QmStatsBadge'
 $mark=New-QmText ([string][char]$glyph) ($size*0.58) $color 'SemiBold'
 $mark.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
 $mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center';$mark.TextTrimming='None'
 $badge.Child=$mark;return $badge
}

function New-QmStatsSurface([string]$skin,[double]$top,[double]$bottom) {
 $t=$script:QM_SKINS[$skin]
 $b=[Windows.Controls.Border]::new();$b.Background=Get-QmBrush $t.track;$b.BorderBrush=Get-QmBrush $t.divider
 $b.BorderThickness=[Windows.Thickness]::new(1);$b.CornerRadius=[Windows.CornerRadius]::new(12)
 $b.Padding=[Windows.Thickness]::new(12,10,12,10);$b.Margin=[Windows.Thickness]::new(0,$top,0,$bottom)
 $stack=[Windows.Controls.StackPanel]::new();$b.Child=$stack
 return [pscustomobject]@{Root=$b;Body=$stack}
}

function New-QmStatsSection([int]$glyph,[string]$title,[string]$note,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $head=[Windows.Controls.Grid]::new()
 foreach($width in @('*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$head.ColumnDefinitions.Add($cd)
 }
 $left=[Windows.Controls.StackPanel]::new();$left.Orientation='Horizontal'
 [void]$left.Children.Add((New-QmGlyphPlate $glyph $t.green $t.greenTint (20*$k)))
 $name=New-QmText $title (11.5*$k) $t.text 'SemiBold';$name.Margin=[Windows.Thickness]::new(8,0,0,0);$name.VerticalAlignment='Center'
 [void]$left.Children.Add($name);[void]$head.Children.Add($left)
 $noteText=New-QmText $note (9.5*$k) $t.faint;$noteText.HorizontalAlignment='Right';$noteText.VerticalAlignment='Center'
 [Windows.Controls.Grid]::SetColumn($noteText,1);[void]$head.Children.Add($noteText)
 return [pscustomobject]@{Root=$head;Note=$noteText;Title=$name}
}

function New-QmStatsCard([int]$glyph,[string]$label,[string]$color,[string]$tint,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $card=[Windows.Controls.Border]::new();$card.Background=Get-QmBrush $t.track;$card.BorderBrush=Get-QmBrush $t.divider
 $card.BorderThickness=[Windows.Thickness]::new(1);$card.CornerRadius=[Windows.CornerRadius]::new(12)
 $card.Padding=[Windows.Thickness]::new(11,9,11,10);$card.Margin=[Windows.Thickness]::new(0,0,8,0);$card.Tag='QmStatsCard'
 $stack=[Windows.Controls.StackPanel]::new();$card.Child=$stack
 $head=[Windows.Controls.StackPanel]::new();$head.Orientation='Horizontal'
 [void]$head.Children.Add((New-QmGlyphPlate $glyph $color $tint (18*$k)))
 $name=New-QmText $label (9.8*$k) $t.faint 'Medium';$name.Margin=[Windows.Thickness]::new(7,0,0,0);$name.VerticalAlignment='Center'
 [void]$head.Children.Add($name);[void]$stack.Children.Add($head)
 $value=New-QmText '—' (21*$k) $color 'SemiBold' $true
 $value.Margin=[Windows.Thickness]::new(0,5,0,0);$value.Tag='QmStatsCardValue';[void]$stack.Children.Add($value)
 return [pscustomobject]@{Root=$card;Value=$value;Label=$name}
}

function New-QmStatsShare([string]$fill,[string]$track,[double]$share,[double]$height) {
 # Star columns express the share without measuring text, so a longer label can
 # never push the plate past its row or change the row height.
 $ratio=[math]::Max(0.0,[math]::Min(1.0,[double]$share))
 $trackBorder=[Windows.Controls.Border]::new();$trackBorder.Background=Get-QmBrush $track
 $trackBorder.CornerRadius=[Windows.CornerRadius]::new($height/2);$trackBorder.Height=$height
 $trackBorder.Tag='QmStatsShare'
 $grid=[Windows.Controls.Grid]::new()
 $left=[Windows.Controls.ColumnDefinition]::new();$left.Width=[Windows.GridLength]::new($ratio,[Windows.GridUnitType]::Star)
 $right=[Windows.Controls.ColumnDefinition]::new();$right.Width=[Windows.GridLength]::new(1.0-$ratio,[Windows.GridUnitType]::Star)
 [void]$grid.ColumnDefinitions.Add($left);[void]$grid.ColumnDefinitions.Add($right)
 $fillBorder=[Windows.Controls.Border]::new();$fillBorder.Background=Get-QmBrush $fill
 $fillBorder.CornerRadius=[Windows.CornerRadius]::new($height/2);$fillBorder.HorizontalAlignment='Stretch'
 $fillBorder.Tag='QmStatsShareFill';[void]$grid.Children.Add($fillBorder)
 $trackBorder.Child=$grid;return $trackBorder
}

function New-QmStatsEmptyState([string]$title,[string]$hint,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $box=[Windows.Controls.StackPanel]::new();$box.HorizontalAlignment='Center';$box.Tag='QmStatsEmpty'
 $circle=[Windows.Controls.Border]::new();$circle.Width=40;$circle.Height=40;$circle.CornerRadius=[Windows.CornerRadius]::new(20)
 $circle.Background=Get-QmBrush $t.greenTint;$circle.HorizontalAlignment='Center';$circle.Margin=[Windows.Thickness]::new(0,10,0,0)
 $glyph=New-QmText ([string][char]0xE9D9) 16 $t.green 'SemiBold'
 $glyph.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
 $glyph.HorizontalAlignment='Center';$glyph.VerticalAlignment='Center';$circle.Child=$glyph
 [void]$box.Children.Add($circle)
 $head=New-QmText $title (12.5*$k) $t.text 'SemiBold';$head.HorizontalAlignment='Center';$head.Tag='QmStatsEmptyTitle'
 $head.Margin=[Windows.Thickness]::new(0,9,0,0);[void]$box.Children.Add($head)
 $text=New-QmText $hint (9.8*$k) $t.faint;$text.TextWrapping='Wrap';$text.TextTrimming='None'
 $text.TextAlignment='Center';$text.MaxWidth=330;$text.HorizontalAlignment='Center';$text.Margin=[Windows.Thickness]::new(0,5,0,2)
 [void]$box.Children.Add($text)
 return $box
}

function New-QmStatsWindow {
 $skin=Resolve-QmSkin $script:CFG.skin;$t=$script:QM_SKINS[$skin];$k=Get-QmScale
 $w=[Windows.Window]::new();$w.Title='Qoder Meter 用量统计'
 $w.Width=640;$w.Height=760;$w.MinWidth=520;$w.MinHeight=600
 $w.ResizeMode='CanResize';$w.ShowInTaskbar=$false;$w.WindowStartupLocation='CenterScreen'
 Initialize-QmThemedWindow $w $skin
 $outer=[Windows.Controls.Grid]::new();$outer.Margin=[Windows.Thickness]::new(22,18,22,16)
 foreach($height in @('Auto','Auto','Auto','Auto','*','Auto')){
  $rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLengthConverter]::new().ConvertFromString($height);[void]$outer.RowDefinitions.Add($rd)
 }
 # Header ---------------------------------------------------------------
 $head=[Windows.Controls.Grid]::new()
 foreach($width in @('Auto','*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$head.ColumnDefinitions.Add($cd)
 }
 $logo=[Windows.Controls.Border]::new();$logo.Width=34;$logo.Height=34;$logo.CornerRadius=[Windows.CornerRadius]::new(10);$logo.Background=Get-QmBrush $t.greenTint;$logo.Name='QmStatsLogo'
 $mark=New-QmText ([string][char]0xE9D9) (14*$k) $t.green 'SemiBold';$mark.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
 $mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center';$logo.Child=$mark;[void]$head.Children.Add($logo)
 $titles=[Windows.Controls.StackPanel]::new();$titles.Margin=[Windows.Thickness]::new(10,0,0,0);$titles.VerticalAlignment='Center'
 [void]$titles.Children.Add((New-QmText '用量统计' (18*$k) $t.text 'SemiBold'))
 $sub=New-QmText '本地日志 · 趋势图与自动摘要' (10*$k) $t.faint;$sub.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$titles.Children.Add($sub)
 [Windows.Controls.Grid]::SetColumn($titles,1);[void]$head.Children.Add($titles)
 $logoHint=New-QmText '只读本机' (9.2*$k) $t.faint;$logoHint.VerticalAlignment='Center';$logoHint.HorizontalAlignment='Right'
 [Windows.Controls.Grid]::SetColumn($logoHint,2);[void]$head.Children.Add($logoHint)
 [void]$outer.Children.Add($head)
 # Range controls -------------------------------------------------------
 $rangeRow=[Windows.Controls.Grid]::new();$rangeRow.Margin=[Windows.Thickness]::new(0,12,0,0)
 foreach($width in @('*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$rangeRow.ColumnDefinitions.Add($cd)
 }
 $rangeChips=[Windows.Controls.StackPanel]::new();$rangeChips.Orientation='Horizontal';$rangeChips.Name='QmStatsRanges'
 $rangeButtons=[ordered]@{}
 foreach($id in $script:QM_STATS_RANGES.Keys){
  $chip=New-QmStatsPick $script:QM_STATS_RANGES[$id] 'statsRange' $id $skin
  $rangeButtons[$id]=$chip;[void]$rangeChips.Children.Add($chip)
 }
 [void]$rangeRow.Children.Add($rangeChips)
 $refresh=New-QmThemedButton '刷新' $skin;$refresh.FontSize=10.5;$refresh.Padding=[Windows.Thickness]::new(11,3,11,3);$refresh.MinHeight=26;$refresh.Height=26
 $refresh.Tag=@{Command='statsRefresh';Value=''}
 $refresh.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 [Windows.Controls.Grid]::SetColumn($refresh,1);[void]$rangeRow.Children.Add($refresh)
 [Windows.Controls.Grid]::SetRow($rangeRow,1);[void]$outer.Children.Add($rangeRow)
 # Group controls -------------------------------------------------------
 $groupRow=[Windows.Controls.Grid]::new();$groupRow.Margin=[Windows.Thickness]::new(0,8,0,0)
 foreach($width in @('*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$groupRow.ColumnDefinitions.Add($cd)
 }
 $groupChips=[Windows.Controls.StackPanel]::new();$groupChips.Orientation='Horizontal';$groupChips.Name='QmStatsGroups'
 $groupButtons=[ordered]@{}
 foreach($id in $script:QM_STATS_GROUPS.Keys){
  $chip=New-QmStatsPick $script:QM_STATS_GROUPS[$id] 'statsGroup' $id $skin
  $groupButtons[$id]=$chip;[void]$groupChips.Children.Add($chip)
 }
 [void]$groupRow.Children.Add($groupChips)
 $updated=New-QmText '更新 —' (9.5*$k) $t.faint;$updated.HorizontalAlignment='Right';$updated.VerticalAlignment='Center'
 [Windows.Controls.Grid]::SetColumn($updated,1);[void]$groupRow.Children.Add($updated)
 [Windows.Controls.Grid]::SetRow($groupRow,2);[void]$outer.Children.Add($groupRow)
 # View tabs ------------------------------------------------------------
 $tabRow=[Windows.Controls.Grid]::new();$tabRow.Margin=[Windows.Thickness]::new(0,10,0,0)
 foreach($width in @('Auto','*')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$tabRow.ColumnDefinitions.Add($cd)
 }
 $tabChips=[Windows.Controls.StackPanel]::new();$tabChips.Orientation='Horizontal';$tabChips.Name='QmStatsTabs'
 $tabButtons=[ordered]@{}
 foreach($id in $script:QM_STATS_TABS.Keys){
  $chip=New-QmStatsPick $script:QM_STATS_TABS[$id] 'statsTab' $id $skin
  $chip.MinWidth=64;$tabButtons[$id]=$chip;[void]$tabChips.Children.Add($chip)
 }
 [void]$tabRow.Children.Add($tabChips)
 $rangeText=New-QmText '' (10*$k) $t.soft;$rangeText.HorizontalAlignment='Right';$rangeText.VerticalAlignment='Center'
 [Windows.Controls.Grid]::SetColumn($rangeText,1);[void]$tabRow.Children.Add($rangeText)
 [Windows.Controls.Grid]::SetRow($tabRow,3);[void]$outer.Children.Add($tabRow)
 # Content --------------------------------------------------------------
 $content=[Windows.Controls.Grid]::new();$content.Name='QmStatsContent'
 [Windows.Controls.Grid]::SetRow($content,4);[void]$outer.Children.Add($content)
 # Overview -------------------------------------------------------------
 $overviewScroll=[Windows.Controls.ScrollViewer]::new();$overviewScroll.Name='QmStatsOverview'
 $overviewScroll.VerticalScrollBarVisibility='Auto';$overviewScroll.HorizontalScrollBarVisibility='Disabled'
 $overview=[Windows.Controls.StackPanel]::new();$overviewScroll.Content=$overview
 $cards=[Windows.Controls.Grid]::new();$cards.Name='QmStatsSummary';$cards.Margin=[Windows.Thickness]::new(0,2,0,0)
 for($i=0;$i -lt 4;$i++){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);[void]$cards.ColumnDefinitions.Add($cd)
 }
 $cardDefs=@(
  @{Key='credits';Glyph=0xE945;Label='积分';Color=$t.gold;Tint=$t.goldTint},
  @{Key='tokens';Glyph=0xE950;Label='Token';Color=$t.blue;Tint=$t.blueTint},
  @{Key='requests';Glyph=0xE9D9;Label='请求';Color=$t.green;Tint=$t.greenTint},
  @{Key='days';Glyph=0xE823;Label='活跃天';Color=$t.text;Tint=$t.grayTint}
 )
 $summaryRefs=@{}
 for($i=0;$i -lt $cardDefs.Count;$i++){
  $def=$cardDefs[$i]
  $card=New-QmStatsCard $def.Glyph $def.Label $def.Color $def.Tint $skin $k
  if($i -eq $cardDefs.Count-1){$card.Root.Margin=[Windows.Thickness]::new(0)}
  [Windows.Controls.Grid]::SetColumn($card.Root,$i);[void]$cards.Children.Add($card.Root)
  $summaryRefs[$def.Key]=$card
 }
 [void]$overview.Children.Add($cards)
 # Trend chart ----------------------------------------------------------
 $trend=New-QmStatsSurface $skin 10 0
 $trendSection=New-QmStatsSection 0xE9D9 '趋势' '最近 12 期 · 按积分' $skin $k
 [void]$trend.Body.Children.Add($trendSection.Root)
 $trendCaption=New-QmText '' (9.5*$k) $t.faint;$trendCaption.Margin=[Windows.Thickness]::new(0,4,0,0);[void]$trend.Body.Children.Add($trendCaption)
 $plotHost=[Windows.Controls.Grid]::new();$plotHost.Height=($script:QM_STATS_CHART_HEIGHT+14);$plotHost.Margin=[Windows.Thickness]::new(0,6,0,0)
 $plotHost.Name='QmStatsTrend'
 $lines=[Windows.Controls.Grid]::new();$lines.IsHitTestVisible=$false
 foreach($place in @('Top','Center','Bottom')){
  $rule=[Windows.Controls.Border]::new();$rule.Height=1;$rule.Background=Get-QmBrush $t.divider;$rule.VerticalAlignment=$place
  $rule.SnapsToDevicePixels=$true;[void]$lines.Children.Add($rule)
 }
 [void]$plotHost.Children.Add($lines)
 $bars=[Windows.Controls.Grid]::new();$bars.Margin=[Windows.Thickness]::new(0,10,0,2);$bars.Name='QmStatsTrendBars'
 [void]$plotHost.Children.Add($bars)
 $trendEmpty=New-QmStatsEmptyState '暂无趋势数据' '当前范围与粒度内没有带积分的助手请求；刷新或放宽范围后再试。' $skin $k
 $trendEmpty.Margin=[Windows.Thickness]::new(0,4,0,2);$trendEmpty.Visibility='Collapsed'
 [void]$trend.Body.Children.Add($plotHost);[void]$trend.Body.Children.Add($trendEmpty)
 $labels=[Windows.Controls.Grid]::new();$labels.Height=16;$labels.Name='QmStatsTrendLabels';$labels.Visibility='Collapsed'
 [void]$trend.Body.Children.Add($labels)
 [void]$overview.Children.Add($trend.Root)
 # Model mix ------------------------------------------------------------
 $models=New-QmStatsSurface $skin 10 0
 $modelSection=New-QmStatsSection 0xE790 '模型构成' '按积分排序' $skin $k
 [void]$models.Body.Children.Add($modelSection.Root)
 $modelCount=New-QmText '共 0 个模型' (9.5*$k) $t.faint;$modelCount.Margin=[Windows.Thickness]::new(0,4,0,0)
 [void]$models.Body.Children.Add($modelCount)
 $modelRows=[Windows.Controls.StackPanel]::new();$modelRows.Margin=[Windows.Thickness]::new(0,6,0,0);$modelRows.Name='QmStatsModelRows'
 [void]$models.Body.Children.Add($modelRows)
 $modelEmpty=New-QmStatsEmptyState '暂无模型记录' '当前范围内没有积分或 Token 记录。' $skin $k
 $modelEmpty.Visibility='Collapsed';[void]$models.Body.Children.Add($modelEmpty)
 [void]$overview.Children.Add($models.Root)
 # Auto summary ---------------------------------------------------------
 $insights=New-QmStatsSurface $skin 10 0
 $insightSection=New-QmStatsSection 0xE81C '自动摘要' '固定窗口 · 规则生成' $skin $k
 [void]$insights.Body.Children.Add($insightSection.Root)
 $insightNote=New-QmText '对比上一同长周期 · 不使用 AI' (9.5*$k) $t.faint;$insightNote.Margin=[Windows.Thickness]::new(0,4,0,0)
 [void]$insights.Body.Children.Add($insightNote)
 $insightRows=[Windows.Controls.StackPanel]::new();$insightRows.Margin=[Windows.Thickness]::new(0,6,0,0);$insightRows.Name='QmStatsInsightRows'
 [void]$insights.Body.Children.Add($insightRows)
 [void]$overview.Children.Add($insights.Root)
 [void]$content.Children.Add($overviewScroll)
 # Detail ---------------------------------------------------------------
 $detailWrap=[Windows.Controls.Grid]::new();$detailWrap.Name='QmStatsDetail'
 foreach($height in @('Auto','*','Auto')){
  $rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLengthConverter]::new().ConvertFromString($height);[void]$detailWrap.RowDefinitions.Add($rd)
 }
 $periodHead=[Windows.Controls.Grid]::new();$periodHead.Margin=[Windows.Thickness]::new(2,0,2,6)
 foreach($width in @('*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$periodHead.ColumnDefinitions.Add($cd)
 }
 $periodTitle=New-QmText '按日明细' (11.5*$k) $t.text 'SemiBold';[void]$periodHead.Children.Add($periodTitle)
 $periodNote=New-QmText '' (9.5*$k) $t.faint;$periodNote.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetColumn($periodNote,1)
 [void]$periodHead.Children.Add($periodNote)
 [void]$detailWrap.Children.Add($periodHead)
 $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled'
 $periodList=[Windows.Controls.StackPanel]::new();$periodList.Name='QmStatsPeriodList';$periodList.Margin=[Windows.Thickness]::new(0,0,4,0);$scroll.Content=$periodList
 [Windows.Controls.Grid]::SetRow($scroll,1);[void]$detailWrap.Children.Add($scroll)
 $nav=[Windows.Controls.Grid]::new();$nav.Margin=[Windows.Thickness]::new(0,6,0,0)
 foreach($column in @(0,1,2)){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($(if($column -eq 1){'*'}else{'Auto'}));[void]$nav.ColumnDefinitions.Add($cd)
 }
 $prev=New-QmThemedButton '‹ 上一页' $skin;$prev.FontSize=10.5;$prev.Padding=[Windows.Thickness]::new(9,3,9,3);$prev.MinHeight=26
 $prev.Tag=@{Command='statsPage';Value=-1};$prev.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 [void]$nav.Children.Add($prev)
 $pageText=New-QmText '' (9.5*$k) $t.faint;$pageText.HorizontalAlignment='Center';[Windows.Controls.Grid]::SetColumn($pageText,1);[void]$nav.Children.Add($pageText)
 $next=New-QmThemedButton '下一页 ›' $skin;$next.FontSize=10.5;$next.Padding=[Windows.Thickness]::new(9,3,9,3);$next.MinHeight=26;$next.HorizontalAlignment='Right'
 $next.Tag=@{Command='statsPage';Value=1};$next.Add_Click({param($sender,$eventArgs) Invoke-QmCommand $sender.Tag.Command $sender.Tag.Value})
 [Windows.Controls.Grid]::SetColumn($next,2);[void]$nav.Children.Add($next)
 [Windows.Controls.Grid]::SetRow($nav,2);[void]$detailWrap.Children.Add($nav)
 [void]$content.Children.Add($detailWrap)
 # Footer ---------------------------------------------------------------
 $foot=[Windows.Controls.Grid]::new();$foot.Margin=[Windows.Thickness]::new(0,10,0,0)
 foreach($width in @('*','Auto')){
  $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$foot.ColumnDefinitions.Add($cd)
 }
 $footNote=New-QmText '本机日志 · 不联网 · ≈估算' (9.2*$k) $t.faint
 $footNote.Name='QmStatsFooter';$footNote.TextWrapping='Wrap';$footNote.TextTrimming='None';$footNote.VerticalAlignment='Center'
 [void]$foot.Children.Add($footNote)
 $done=New-QmThemedButton '完成' $skin $true;$done.MinWidth=82;$done.IsDefault=$true;$done.IsCancel=$true
 $done.Add_Click({param($sender,$eventArgs) if($script:UI.statsWin){$script:UI.statsWin.Hide()}})
 [Windows.Controls.Grid]::SetColumn($done,1);[void]$foot.Children.Add($done)
 [Windows.Controls.Grid]::SetRow($foot,5);[void]$outer.Children.Add($foot)
 $w.Content=$outer
 $w.Add_Closing({param($sender,$e) if(-not $script:QM_SHUTDOWN -and $sender.Tag -ne 'dispose'){$e.Cancel=$true;$sender.Hide()}})
 $script:QM_STATS_PAGE=0
 $script:QM_STATS_REFS=@{
  RangeButtons=$rangeButtons;GroupButtons=$groupButtons;TabButtons=$tabButtons;RangeText=$rangeText;Updated=$updated
  Summary=$summaryRefs;TrendCaption=$trendCaption;TrendBars=$bars;TrendLabels=$labels;TrendEmpty=$trendEmpty;TrendPlot=$plotHost
  TrendNote=$trendSection.Note;ModelCount=$modelCount;ModelRows=$modelRows;ModelEmpty=$modelEmpty;ModelNote=$modelSection.Note
  InsightRows=$insightRows;InsightNote=$insightNote;Overview=$overviewScroll;Detail=$detailWrap
  PeriodTitle=$periodTitle;PeriodNote=$periodNote;PeriodList=$periodList
  Nav=$nav;PageText=$pageText;Prev=$prev;Next=$next;FooterNote=$footNote;HeaderHint=$logoHint;Refresh=$refresh
  Header=$head;Titles=$titles;Logo=$logo;FooterDone=$done;Tabs=$tabChips
 }
 return $w
}

function Sync-QmStatsWindow {
 if(!$script:UI.statsWin -or !$script:QM_STATS_REFS){return}
 $refs=$script:QM_STATS_REFS;$skin=Resolve-QmSkin $script:CFG.skin;$t=$script:QM_SKINS[$skin];$k=Get-QmScale
 $tab=[string]$script:CFG.statsTab;if(!$script:QM_STATS_TABS.Contains($tab)){$tab='overview'}
 $data=Get-QmStatsData $script:CFG.statsRange
 foreach($id in $refs.RangeButtons.Keys){Set-QmStatsPickState $refs.RangeButtons[$id] ($id -eq $script:CFG.statsRange) $skin}
 foreach($id in $refs.GroupButtons.Keys){Set-QmStatsPickState $refs.GroupButtons[$id] ($id -eq $script:CFG.statsGroup) $skin}
 foreach($id in $refs.TabButtons.Keys){Set-QmStatsPickState $refs.TabButtons[$id] ($id -eq $tab) $skin}
 $refs.RangeText.Text=Get-QmStatsRangeText $data
 $refs.Updated.Text='更新 '+(Format-QmStatsClock $data.At)
 $refs.Summary['credits'].Value.Text=Format-QmCredits $data.Credits
 $refs.Summary['tokens'].Value.Text=$(if($data.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $data.Tokens)
 $refs.Summary['requests'].Value.Text=Format-QmCount $data.Requests
 $refs.Summary['days'].Value.Text=[string]$data.ActiveDays
 $refs.FooterNote.Text=$(if($script:QM_STATS_ERROR){$script:QM_STATS_ERROR+'；请检查 Qoder 日志权限'}else{'本机日志 · 不联网 · ≈估算'})
 $refs.Overview.Visibility=$(if($tab -eq 'overview'){'Visible'}else{'Collapsed'})
 $refs.Detail.Visibility=$(if($tab -eq 'detail'){'Visible'}else{'Collapsed'})
 Sync-QmStatsTrend $refs $data $skin $k
 Sync-QmStatsModels $refs $data $skin $k
 Sync-QmStatsInsights $refs $skin $k
 Sync-QmStatsPeriods $refs $data $skin $k
}

function Sync-QmStatsTrend($refs,$data,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $group=[string]$script:CFG.statsGroup;if(!$script:QM_STATS_GROUPS.Contains($group)){$group='day'}
 $chart=Get-QmStatsChartData $data $group
 $bars=$refs.TrendBars;$labels=$refs.TrendLabels
 $bars.Children.Clear();$bars.ColumnDefinitions.Clear()
 $labels.Children.Clear();$labels.ColumnDefinitions.Clear()
 if($chart.HasData){
  $units=$(if($group -eq 'week'){'周'}elseif($group -eq 'month'){'个月'}else{'天'})
  $refs.TrendCaption.Text='展示最近 '+$chart.Bars.Count+' '+$units+' · 峰值 '+(Format-QmCredits $chart.Peak)+' 积分 · 合计 '+(Format-QmCredits $chart.Credits)+' 积分'
  $refs.TrendNote.Text='最近 '+$script:QM_STATS_CHART_MAX+' 期 · 按积分'
  $index=0
  foreach($bar in @($chart.Bars)){
   $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
   [void]$bars.ColumnDefinitions.Add($cd)
   $labelCd=[Windows.Controls.ColumnDefinition]::new();$labelCd.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
   [void]$labels.ColumnDefinitions.Add($labelCd)
   $slot=[Windows.Controls.Grid]::new();$slot.Tag='QmStatsTrendSlot'
   [Windows.Controls.Grid]::SetColumn($slot,$index);[void]$bars.Children.Add($slot)
   $track=[Windows.Controls.Border]::new();$track.Background=Get-QmBrush $t.grayTint
   $track.CornerRadius=[Windows.CornerRadius]::new(3);$track.VerticalAlignment='Stretch';[void]$slot.Children.Add($track)
   $rect=[Windows.Controls.Border]::new();$rect.Background=Get-QmBrush $t.green
   $rect.CornerRadius=[Windows.CornerRadius]::new(3,3,0,0);$rect.VerticalAlignment='Bottom'
   $rect.Height=[double]$bar.Height;$rect.HorizontalAlignment='Stretch'
   $rect.MinWidth=4;$rect.Margin=[Windows.Thickness]::new(3,0,3,0);$rect.Tag='QmStatsTrendBar'
   $rect.ToolTip=Get-QmStatsBarTip $group ([string]$bar.Key) $bar.Period
   [Windows.Controls.ToolTipService]::SetInitialShowDelay($rect,450)
   [void]$slot.Children.Add($rect)
   $label=New-QmText ([string]$bar.Label) (8.6*$k) $t.faint
   $label.TextAlignment='Center';$label.HorizontalAlignment='Center';$label.Margin=[Windows.Thickness]::new(1,2,1,0)
   [Windows.Controls.Grid]::SetColumn($label,$index);[void]$labels.Children.Add($label)
   $index++
  }
  $refs.TrendEmpty.Visibility='Collapsed';$refs.TrendPlot.Visibility='Visible';$refs.TrendLabels.Visibility='Visible'
 }else{
  $refs.TrendCaption.Text='暂无趋势数据'
  $refs.TrendNote.Text='最近 '+$script:QM_STATS_CHART_MAX+' 期 · 按积分'
  $refs.TrendEmpty.Visibility='Visible';$refs.TrendPlot.Visibility='Collapsed';$refs.TrendLabels.Visibility='Collapsed'
 }
}

function Sync-QmStatsModels($refs,$data,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $shares=Get-QmStatsModelShares $data
 $refs.ModelRows.Children.Clear()
 $refs.ModelCount.Text='共 '+$shares.Count+' 个模型 · '+($(if($shares.Basis -eq 'credits'){'按积分占比'}elseif($shares.Basis -eq 'tokens'){'按 Token 占比（积分合计为 0）'}else{'暂无占比'}))
 $refs.ModelNote.Text=$(if($shares.Basis -eq 'credits'){'按积分排序'}elseif($shares.Basis -eq 'tokens'){'按 Token 排序'}else{'按积分排序'})
 if(-not $shares.HasData){
  $refs.ModelEmpty.Visibility='Visible';return
 }
 $refs.ModelEmpty.Visibility='Collapsed'
 foreach($row in @($shares.Rows)){
  $grid=[Windows.Controls.Grid]::new();$grid.Margin=[Windows.Thickness]::new(0,3,0,3);$grid.Tag='QmStatsModelRow'
  foreach($width in @('*','58','76')){
   $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($cd)
  }
  $left=[Windows.Controls.StackPanel]::new();$left.VerticalAlignment='Center'
  $nameLine=[Windows.Controls.StackPanel]::new();$nameLine.Orientation='Horizontal'
  $name=New-QmText ([string]$row.Name) (11*$k) $t.text 'Medium';$name.MaxWidth=250;$name.Tag='QmStatsModelName';[void]$nameLine.Children.Add($name)
  $percent=New-QmText ('  '+[string]$row.Percent+'%') (9.5*$k) $t.faint;$percent.VerticalAlignment='Center'
  $percent.Tag='QmStatsModelPercent';[void]$nameLine.Children.Add($percent);[void]$left.Children.Add($nameLine)
  $fill=$(if($shares.Basis -eq 'credits'){$t.gold}else{$t.blue})
  $bar=New-QmStatsShare $fill $t.track ([double]$row.Share) (4*$k)
  $bar.Margin=[Windows.Thickness]::new(0,4,6,0);[void]$left.Children.Add($bar)
  [void]$grid.Children.Add($left)
  $credits=New-QmText (Format-QmCredits $row.Credits) (10*$k) $t.gold 'SemiBold' $true
  $credits.Tag='QmStatsModelCredits';$credits.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetColumn($credits,1);[void]$grid.Children.Add($credits)
  $tokens=New-QmText ($(if($row.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $row.Tokens)) (10*$k) $t.soft 'Normal' $true
  $tokens.Tag='QmStatsModelTokens';$tokens.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetColumn($tokens,2);[void]$grid.Children.Add($tokens)
  [void]$refs.ModelRows.Children.Add($grid)
 }
}

function Sync-QmStatsInsights($refs,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $refs.InsightRows.Children.Clear()
 foreach($row in @(Get-QmStatsInsights)){
  $card=[Windows.Controls.Border]::new();$card.Background=Get-QmBrush $t.grayTint
  $card.CornerRadius=[Windows.CornerRadius]::new(10);$card.Padding=[Windows.Thickness]::new(11,8,11,9)
  $card.Margin=[Windows.Thickness]::new(0,0,0,6);$card.Tag='QmStatsInsight'
  $grid=[Windows.Controls.Grid]::new()
  foreach($width in @('*','Auto')){
   $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($cd)
  }
  $left=[Windows.Controls.StackPanel]::new();$left.VerticalAlignment='Center'
  $title=New-QmText ([string]$row.Title) (11*$k) $t.text 'SemiBold';$title.Tag='QmStatsInsightTitle';[void]$left.Children.Add($title)
  $tokenText=$(if($row.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $row.Tokens)
  $metrics=New-QmText ((Format-QmCredits $row.Credits)+' 积分 · '+$tokenText+' Token · '+[string]$row.Requests+' 请求') (10*$k) $t.soft 'Normal' $true
  $metrics.Tag='QmStatsInsightMetrics';$metrics.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$left.Children.Add($metrics)
  $summary=New-QmText ([string]$row.Summary) (9.5*$k) $t.faint
  $summary.Tag='QmStatsInsightSummary';$summary.TextWrapping='Wrap';$summary.TextTrimming='None'
  $summary.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$left.Children.Add($summary)
  [void]$grid.Children.Add($left)
  $badge=[string]$row.Delta
  if(-not $badge){$badge='—'}
  $badgeColor=$(if(-not $row.HasData){$t.faint}elseif($badge -eq '基本持平' -or $badge -eq '上一周期无记录'){$t.faint}elseif($badge -like '-*'){$t.red}else{$t.green})
  $delta=New-QmText $badge (10.5*$k) $badgeColor 'SemiBold'
  $delta.HorizontalAlignment='Right';$delta.VerticalAlignment='Center';$delta.Tag='QmStatsInsightDelta'
  [Windows.Controls.Grid]::SetColumn($delta,1);[void]$grid.Children.Add($delta)
  $card.Child=$grid;[void]$refs.InsightRows.Children.Add($card)
 }
}

function Sync-QmStatsPeriods($refs,$data,[string]$skin,[double]$k) {
 $t=$script:QM_SKINS[$skin]
 $group=[string]$script:CFG.statsGroup;if(!$script:QM_STATS_GROUPS.Contains($group)){$group='day'}
 $periods=@(Get-QmStatsPeriods $data $group)
 $totalPages=[math]::Max(1,[int][math]::Ceiling($periods.Count/[double]$script:QM_STATS_PAGE_SIZE))
 $script:QM_STATS_PAGE=[math]::Max(0,[math]::Min($script:QM_STATS_PAGE,$totalPages-1))
 $page=$script:QM_STATS_PAGE
 $slice=@($periods|Select-Object -Skip ($page*$script:QM_STATS_PAGE_SIZE) -First $script:QM_STATS_PAGE_SIZE)
 $refs.PeriodTitle.Text=$script:QM_STATS_GROUPS[$group]+'明细'
 $refs.PeriodNote.Text=$(if($periods.Count){'共 '+$periods.Count+' '+$script:QM_STATS_UNITS[$group]}else{'暂无记录'})
 $refs.PeriodList.Children.Clear()
 $peak=0.0
 foreach($period in $periods){if([double]$period.Credits -gt $peak){$peak=[double]$period.Credits}}
 if(-not $slice.Count){
  [void]$refs.PeriodList.Children.Add((New-QmStatsEmptyState '暂无用量记录' '当前范围与分组内没有带积分的助手请求；可在 Qoder 正常对话后再刷新。' $skin $k))
 }else{
  foreach($period in $slice){
   $row=[Windows.Controls.Border]::new();$row.Background=Get-QmBrush $t.track
   $row.CornerRadius=[Windows.CornerRadius]::new(9);$row.Padding=[Windows.Thickness]::new(10,6,10,7)
   $row.Margin=[Windows.Thickness]::new(0,0,0,6);$row.Tag='QmStatsPeriodRow'
   $row.ToolTip=Get-QmStatsPeriodTip $group ([string]$period.Key) $period
   [Windows.Controls.ToolTipService]::SetInitialShowDelay($row,450)
   $stack=[Windows.Controls.StackPanel]::new()
   $top=[Windows.Controls.Grid]::new()
   foreach($width in @('Auto','*','Auto')){
    $cd=[Windows.Controls.ColumnDefinition]::new();$cd.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$top.ColumnDefinitions.Add($cd)
   }
   $label=New-QmText (Get-QmStatsPeriodLabel $group ([string]$period.Key)) (11.5*$k) $t.text 'SemiBold'
   $label.Tag='QmStatsPeriodLabel'
   $label.MinWidth=$(if($group -eq 'week'){112}elseif($group -eq 'month'){62}else{48});[void]$top.Children.Add($label)
   $metrics=[Windows.Controls.StackPanel]::new();$metrics.Orientation='Horizontal';$metrics.HorizontalAlignment='Right'
   $creditValue=New-QmText ((Format-QmCredits $period.Credits)+' 积分') (10.5*$k) $t.gold 'SemiBold' $true
   $creditValue.Tag='QmStatsPeriodCredits';[void]$metrics.Children.Add($creditValue)
   $tokens=New-QmText (' · '+$(if($period.Estimated){'≈ '}else{''})+(Format-QmStatsTokens $period.Tokens)+' tok') (10*$k) $t.soft 'Normal' $true
   $tokens.Tag='QmStatsPeriodTokens';[void]$metrics.Children.Add($tokens)
   $tail=$(if($group -eq 'day'){' · '+$period.Requests+' 请求'}else{' · '+$period.ActiveDays+' 天'})
   $tailText=New-QmText $tail (9.5*$k) $t.faint;$tailText.Tag='QmStatsPeriodTail';[void]$metrics.Children.Add($tailText)
   [Windows.Controls.Grid]::SetColumn($metrics,2);[void]$top.Children.Add($metrics)
   [void]$stack.Children.Add($top)
   $share=$(if($peak -gt 0){[double]$period.Credits/$peak}else{0.0})
   $mini=New-QmStatsShare $t.green $t.grayTint $share (4*$k)
   $mini.Margin=[Windows.Thickness]::new(0,4,8,0);$mini.Tag='QmStatsPeriodBar';[void]$stack.Children.Add($mini)
   $modelText=New-QmText (Get-QmStatsTopModelsText $period) (9.5*$k) $t.faint
   $modelText.Tag='QmStatsPeriodModels';$modelText.TextTrimming='CharacterEllipsis'
   $modelText.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$stack.Children.Add($modelText)
   $row.Child=$stack;[void]$refs.PeriodList.Children.Add($row)
  }
 }
 $refs.Nav.Visibility=$(if($totalPages -gt 1){'Visible'}else{'Collapsed'})
 $refs.Prev.IsEnabled=($page -gt 0);$refs.Next.IsEnabled=($page -lt $totalPages-1)
 $refs.PageText.Text='第 '+($page+1)+' / '+$totalPages+' 页'
}

function Set-QmStatsRange([string]$range) {
 if(!$script:QM_STATS_RANGES.Contains($range)){return}
 $script:CFG.statsRange=$range;Save-QmConfig;$script:QM_STATS_PAGE=0;Sync-QmStatsWindow
}

function Set-QmStatsGroup([string]$group) {
 if(!$script:QM_STATS_GROUPS.Contains($group)){return}
 $script:CFG.statsGroup=$group;Save-QmConfig;$script:QM_STATS_PAGE=0;Sync-QmStatsWindow
}

# 切换视图只改可见面板，不重置分页，回到明细时仍停在上次的页码。
function Set-QmStatsTab([string]$tab) {
 if(!$script:QM_STATS_TABS.Contains($tab)){return}
 $script:CFG.statsTab=$tab;Save-QmConfig;Sync-QmStatsWindow
}

function Move-QmStatsPage([int]$delta) {
 $data=Get-QmStatsData $script:CFG.statsRange
 $periods=@(Get-QmStatsPeriods $data $script:CFG.statsGroup)
 $totalPages=[math]::Max(1,[int][math]::Ceiling($periods.Count/[double]$script:QM_STATS_PAGE_SIZE))
 $script:QM_STATS_PAGE=[math]::Max(0,[math]::Min($script:QM_STATS_PAGE+$delta,$totalPages-1))
 Sync-QmStatsWindow
}

function Refresh-QmStatsWindow {
 [void](Get-QmStatsCache -Force)
 $script:QM_STATS_PAGE=0
 Sync-QmStatsWindow
}

function Show-QmStatsWindow {
 $skin=Resolve-QmSkin $script:CFG.skin
 if($script:UI.statsWin -and $script:UI.statsWin.Resources['QmResolvedSkin'] -ne $skin){
  $old=$script:UI.statsWin;$width=$old.Width;$height=$old.Height;$left=$old.Left;$top=$old.Top
  $old.Tag='dispose';$old.Close()
  $script:UI.statsWin=New-QmStatsWindow
  $script:UI.statsWin.Width=$width;$script:UI.statsWin.Height=$height
  if(-not [double]::IsNaN($left) -and -not [double]::IsNaN($top)){
   $script:UI.statsWin.WindowStartupLocation='Manual';$script:UI.statsWin.Left=$left;$script:UI.statsWin.Top=$top
  }
 }
 if(!$script:UI.statsWin){$script:UI.statsWin=New-QmStatsWindow}
 [void](Get-QmStatsCache)
 Sync-QmStatsWindow
 $script:UI.statsWin.Show();[void]$script:UI.statsWin.Activate()
}
