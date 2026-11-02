# 验证 winsqlite3.dll + JSON1 + macOS 版 PAYLOAD_SQL 能否原样跑通
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\lib-interop.ps1')

$dbPath = Join-Path $env:APPDATA 'com.qoder.app.stable\main.sqlite'
Write-Output ("DB: " + $dbPath)
$db = [QoderMeter.Sq]::Open($dbPath)
Write-Output "[OK] winsqlite3 只读打开成功"

$probe = [QoderMeter.Sq]::QueryText($db, "select json_object('ver', sqlite_version(), 'json1', (select json_extract('{""a"":[1,2]}','$.a[1]')))")
Write-Output ("[OK] JSON1 可用: " + $probe)

$PAYLOAD_SQL = @'
select json_object(
  'window', coalesce((select value_json from app_settings where setting_key='window.workbenchBounds'),'null'),
  'sessions', (select json_group_array(json_object(
      'session_id', session_id,
      'title', title,
      'model', model,
      'cwd', cwd,
      'created_at', created_at,
      'updated_at', updated_at,
      'last_user_at', last_user_at,
      'prompt_count', prompt_count,
      'ctx_json', ctx_json
    )) from (
      select s.session_id, s.title, s.model, s.cwd, s.created_at, s.updated_at,
        (select max(created_at) from chat_session_messages m
           where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as last_user_at,
        (select count(*) from chat_session_messages m
           where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as prompt_count,
        coalesce(u.snapshot_json,'') as ctx_json
      from chat_sessions s
      left join chat_session_context_usage u on u.session_id=s.session_id
      where s.archived=0 and s.deleted_at is null
      order by coalesce(last_user_at,0) desc, s.updated_at desc
      limit 10
    ))
) as payload;
'@

$json = [QoderMeter.Sq]::QueryText($db, $PAYLOAD_SQL)
if (-not $json) { Write-Output "[FAIL] PAYLOAD_SQL 返回空"; [QoderMeter.Sq]::Close($db); exit 1 }
Write-Output ("[OK] PAYLOAD_SQL 通过，长度=" + $json.Length)

$p = $json | ConvertFrom-Json
Write-Output ("     window.workbenchBounds = " + ($p.window | ConvertTo-Json -Compress -Depth 6))
Write-Output ("     sessions = " + $p.sessions.Count)
$first = $p.sessions[0]
Write-Output ("     第一条: id=" + $first.session_id + " model=" + $first.model + " prompt=" + $first.prompt_count)
Write-Output ("       created_at=" + $first.created_at + "  updated_at=" + $first.updated_at + "  last_user_at=" + $first.last_user_at)
Write-Output ("       title=" + $first.title)
Write-Output ("       cwd=" + $first.cwd)
$ctx = $first.ctx_json | ConvertFrom-Json
Write-Output ("       ctx: totalTokens=" + $ctx.totalTokens + " maxTokens=" + $ctx.maxTokens + " percentage=" + $ctx.percentage + " model=" + $ctx.model)

Write-Output ""
Write-Output "=== 时间戳字段类型确认 ==="
$types = [QoderMeter.Sq]::QueryText($db, "select typeof(created_at)||'/'||typeof(updated_at)||'/'||typeof(last_active_at) from chat_sessions limit 1")
Write-Output ("     typeof = " + $types)

[QoderMeter.Sq]::Close($db)
Write-Output ""
Write-Output "[DONE] 数据层 SQLite 通道验证完成"
