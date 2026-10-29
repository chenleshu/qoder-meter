# Settings and pure physical-pixel docking geometry. No desktop side effects.
function New-QmConfig {
 return [pscustomobject]@{
  schemaVersion=3; layout='title';skin='auto';fontSize='normal';paused=$false;panelHidden=$false
  closeWithQoder=$true;creditAuto=$true
  pinned='';bottomAutoHide=$true
  display=[ordered]@{tps=$true;turn=$true;age=$true;token=$true;balance=$true;credits=$true;requests=$true;tools=$true;latency=$true;status=$true;title=$true;credit=$true}
  positions=[ordered]@{sidebar=@(0,0);title=@(0,0);toolbar=@(0,0);bottom=@(0,0)}
 }
}
function Merge-QmConfig($source) {
 $cfg=New-QmConfig
 if(!$source){return $cfg}
 foreach($name in @('display','positions')){
  foreach($key in @($cfg.$name.Keys)){
   $v=$source.$name.$key
   if($null -eq $v){continue}
   if($name -eq 'display'){if($v -is [bool]){$cfg.display[$key]=$v}}
   elseif($v -is [array] -and $v.Count -eq 2){try{$cfg.positions[$key]=@([double]$v[0],[double]$v[1])}catch{}}
  }
 }
 foreach($p in @('layout','skin','fontSize','pinned')) {if($null -ne $source.$p){$cfg.$p=[string]$source.$p}}
 foreach($p in @('paused','panelHidden','closeWithQoder','creditAuto','bottomAutoHide')) {if($source.$p -is [bool]){$cfg.$p=$source.$p}}
 if($cfg.layout -eq 'top'){$cfg.layout='toolbar'}
 # Migrate the old obstructive default card into the user's title-bar position.
 if(!$source.schemaVersion -and $cfg.layout -eq 'sidebar'){$cfg.layout='title'}
 if($cfg.layout -notin @('title','toolbar','bottom','sidebar')){$cfg.layout='title'}
 if($cfg.skin -notin @('auto','paper','graphite','ocean','dusk','sand')){$cfg.skin='auto'}
 if($cfg.fontSize -notin @('small','normal','large','xlarge')){$cfg.fontSize='normal'}
 if($cfg.pinned -and $cfg.pinned -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){$cfg.pinned=''}
 return $cfg
}
function Read-QmConfig {
 try {if(Test-Path -LiteralPath $script:CFG_PATH){return Merge-QmConfig ([IO.File]::ReadAllText($script:CFG_PATH)|ConvertFrom-Json)}}catch{Write-QmLog ('配置读取失败: '+$_.Exception.Message)}
 return New-QmConfig
}
function Save-QmConfig {
 try{
  $dir=Split-Path $script:CFG_PATH -Parent
  if(!(Test-Path $dir)){[void][IO.Directory]::CreateDirectory($dir)}
  $tmp=$script:CFG_PATH+'.tmp'
  [IO.File]::WriteAllText($tmp,($script:CFG|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  if(Test-Path $script:CFG_PATH){[IO.File]::Replace($tmp,$script:CFG_PATH,[NullString]::Value)}else{[IO.File]::Move($tmp,$script:CFG_PATH)}
 }catch{Write-QmLog ('配置保存失败: '+$_.Exception.Message);throw}
}
function Get-QmDockRegion($q,[string]$layout){
 $k=$q.Dpi/96.0;$wd=$q.W/$k
 # Reserved areas correspond to Qoder's native caption/menu, session controls and context indicator.
 switch($layout){
  'title' {$left=320;$right=145;$y=4;$height=32}
  'toolbar' {$left=[math]::Max(440,$wd*0.39);$right=224;$y=50;$height=28}
  'bottom' {$left=272;$right=380;$y=$q.H/$k-32;$height=26}
  'sidebar' {$left=16;$right=16;$y=[math]::Max(90,$q.H/$k-300);$height=250}
  default {$left=320;$right=145;$y=4;$height=32}
 }
 $x=$q.L+$left*$k;$r=$q.R-$right*$k
 # Never grow over native controls when the window is too narrow: show only a hover indicator.
 $width=[math]::Max(0,$r-$x)
 return [pscustomobject]@{X=[math]::Round($x);Y=[math]::Round($q.T+$y*$k);W=[math]::Round($width);H=[math]::Round($height*$k);Right=[math]::Round($r);Bottom=[math]::Round($q.T+($y+$height)*$k);K=$k;Layout=$layout}
}
function Get-QmDockPlacement($region,[double]$width,[double]$height,$offset){
 $dx=0;$dy=0
 if($offset -and $offset.Count -ge 2){$dx=[double]$offset[0]*$region.K;$dy=[double]$offset[1]*$region.K}
 $baseX=$region.X+[math]::Max(0,($region.W-$width)/2)
 $baseY=$region.Y+($region.H-$height)/2
 $x=[math]::Max($region.X,[math]::Min($region.Right-$width,$baseX+$dx))
 $y=$baseY
 if($region.Layout -eq 'sidebar'){$baseX=$region.X;$baseY=$region.Y;$x=$baseX+$dx;$y=$baseY+$dy}
 return [pscustomobject]@{X=[math]::Round($x);Y=[math]::Round($y);BaseX=$baseX;BaseY=$baseY}
}
