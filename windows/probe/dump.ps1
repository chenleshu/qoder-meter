<#
  数据层自检：跑一次完整刷新并打印全部指标 + 耗时
  用法: powershell -File probe/dump.ps1 [-Seconds 3]
#>
param([int]$Seconds = 0, [string]$Pin = '')

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\lib-interop.ps1')
. (Join-Path $root 'src\lib-data.ps1')
if ($Pin) { $script:QM_S.pinned = $Pin }

function Show-QmSnapshot([string]$tag) {
  $S = $script:QM_S
  $ctxTool = 0
  if ($S.ctxStats -and $S.ctxStats.PSObject.Properties['toolCalls']) {
    $tc = $S.ctxStats.toolCalls
    if ($tc -and $tc.PSObject.Properties['total']) { $ctxTool = [int]$tc.total }
  }
  # 与主程序一致：优先本会话 jsonl 数到的工具调用数
  $toolCount = [int]$S.toolCount
  if (-not $toolCount -and $ctxTool) { $toolCount = $ctxTool }
  $outText = if ($S.exactOut -gt 0) { Format-QmK $S.exactOut }
             elseif ($S.estOut -gt 0) { '~ ' + (Format-QmK $S.estOut) } else { '—' }
  Write-Output ("[{0}] session={1}" -f $tag, $S.sessionId)
  Write-Output ("  title      : " + $S.title)
  Write-Output ("  model      : " + $S.model + "   promptCount=" + $S.promptCount)
  Write-Output ("  activeId   : " + $S.activeSessionId + "   recent=" + @($S.recent).Count)
  Write-Output ("  credits    : " + (Format-QmCredits $S.credits))
  Write-Output ("  requests   : " + $S.requestCount + "  (本轮 " + $S.turnRequestCount + ")")
  Write-Output ("  tools      : " + $toolCount + "  (sdk 累计 " + $S.toolCount + ")")
  Write-Output ("  out tokens : " + $outText + "   exact=" + $S.exactOut + " est=" + $S.estOut)
  Write-Output ("  input tok  : " + (Format-QmK $S.inputTokens))
  Write-Output ("  tps        : " + (Format-QmTps $S.tps) + "   history=" + @($S.tpsHistory).Count)
  Write-Output ("  turn wall  : " + (Format-QmDuration $S.turnWall))
  Write-Output ("  turn dur   : " + (Format-QmDuration $S.turnDuration))
  $age = if ($S.sessionStartedAt) { [math]::Max(0, ((QmNowMs) - $S.sessionStartedAt) / 1000.0) } else { 0 }
  Write-Output ("  session age: " + (Format-QmDuration $age) + "  (started=" + $S.sessionStartedAt + ")")
  Write-Output ("  latency    : " + (Format-QmElapsed $S.lastLatency))
  Write-Output ("  state      : " + $(if ($S.inFlight) { '生成中 ' + (Format-QmElapsed $S.inFlightElapsed) } elseif ($S.lastEventAt -and ((QmNowMs) - $S.lastEventAt -lt 20000)) { '本轮中' } else { '空闲' }))
  Write-Output ("  sdk file   : " + $(if ($S.sdk) { $S.sdk.Path + '  offset=' + $S.sdk.Offset + '  groups=' + $S.sdk.Groups.Count } else { '(none)' }))
  Write-Output ("  seg file   : " + $(if ($S.seg) { $S.seg.Path + '  offset=' + $S.seg.Offset + '  events=' + $S.seg.Events.Count } else { '(none)' }))
  Write-Output ("  ctx        : totalTokens=" + $(if ($S.ctxStats) { $S.ctxStats.totalTokens } else { 'n/a' }) + "  error='" + $S.error + "'")
}

$t0 = Get-Date
Refresh-QmData
$t1 = Get-Date
Write-Output ("首次刷新耗时: " + [math]::Round(($t1 - $t0).TotalMilliseconds) + " ms")
Show-QmSnapshot 'init'

if ($Seconds -gt 0) {
  Write-Output ""
  Write-Output ("增量轮询 " + $Seconds + " 秒（0.6s 周期），观察每次耗时:")
  $end = (Get-Date).AddSeconds($Seconds)
  $i = 0
  while ((Get-Date) -lt $end) {
    Start-Sleep -Milliseconds 600
    $a = Get-Date
    Refresh-QmData
    $b = Get-Date
    $i++
    if ($i % 3 -eq 0 -or ($b - $a).TotalMilliseconds -gt 120) {
      Write-Output ("  #" + $i + " 刷新 " + [math]::Round(($b - $a).TotalMilliseconds) + " ms  credits=" + (Format-QmCredits $script:QM_S.credits) + "  req=" + $script:QM_S.requestCount + "  tps=" + (Format-QmTps $script:QM_S.tps))
    }
  }
  Write-Output ""
  Show-QmSnapshot ('after-' + $i)
}

Close-QmDb
