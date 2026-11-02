#requires -Version 5.1
# Offline fixtures only. Node supplies an independent JSON.stringify/Math.round oracle;
# production uses only Windows/.NET. No installed files or Qoder databases are written.
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\lib-interop.ps1')
. (Join-Path $root 'src\lib-data.ps1')
$script:passed = 0; $script:failed = 0
function Assert-Equal($actual, $expected, [string]$label) {
  $same = if ($actual -is [string] -and $expected -is [string]) {
    [string]::Equals($actual, $expected, [StringComparison]::Ordinal)
  } else { $actual -ceq $expected }
  if (-not $same) { throw "$label expected=[$expected] actual=[$actual]" }
}
function Test-Case([string]$name, [scriptblock]$body) {
  try { & $body; $script:passed++; Write-Output "PASS $name" }
  catch { $script:failed++; Write-Output "FAIL $name : $($_.Exception.Message)" }
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('qm-data-regression-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$script:QM_DB = Join-Path $tempRoot 'fixture.sqlite'
$script:QM_LEVELDB = Join-Path $tempRoot 'leveldb'
$script:QM_PROJECTS = Join-Path $tempRoot 'projects'
$script:QM_SEGROOT = Join-Path $tempRoot 'sessions'
$script:QM_SETTINGSD = Join-Path $tempRoot 'meter'
foreach ($dir in @($script:QM_LEVELDB, $script:QM_PROJECTS, $script:QM_SEGROOT)) { [void][IO.Directory]::CreateDirectory($dir) }
function Invoke-FixtureSql([string]$sql) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sql))
  @'
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync(process.argv[2]);
db.exec(Buffer.from(process.argv[3],'base64').toString('utf8'));
db.close();
'@ | & node --no-warnings - $script:QM_DB $encoded
  if ($LASTEXITCODE -ne 0) { throw 'Fixture SQLite command failed' }
}
try {
  $inputs = @(
    @{ Name = 'escaping'; Json = '{"command":"/x/ 中文 \"quote\" apostrophe'' <tag> & \\path","controls":"\u0000\u0001\b\t\n\u000b\f\r\u001f","separators":"\u2028\u2029"}' },
    @{ Name = 'integer-keys'; Json = '{"10":"中","2":"文","01":"x","0":"<","4294967294":"&","4294967295":"''","nested":{"3":"/","1":"a"}}' },
    @{ Name = 'empty-array'; Json = '[]' },
    @{ Name = 'null-fallback'; Json = 'null' },
    @{ Name = 'false-fallback'; Json = 'false' },
    @{ Name = 'zero-fallback'; Json = '0' },
    @{ Name = 'empty-string-fallback'; Json = '""' },
    @{ Name = 'array-values'; Json = '[null,false,true,[],{},"/中文<&''",[1,2]]' },
    @{ Name = 'surrogates'; Json = '{"value":"\ud83d\ude00\ud800x\udfff"}' },
    @{ Name = 'numbers'; Json = '{"values":[1.0,-0.0,1e-7,1e-6,1e20,1e21,0.1,1.2345678901234567,9007199254740993]}' }
  )
  $oracleCode = @'
const x=JSON.parse(Buffer.from(process.argv[2],'base64').toString('utf8'));
const text=JSON.stringify(x||{}), cjk=(text.match(/[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/g)||[]).length;
console.log(JSON.stringify({chars:text.length,est:Math.round(cjk/1.35+(text.length-cjk)/3.8)}));
'@
  foreach ($fixture in $inputs) {
    Test-Case ('JSON.stringify ' + $fixture.Name) {
      $encoded = [Convert]::ToBase64String($utf8.GetBytes($fixture.Json))
      $want = ($oracleCode | & node --no-warnings - $encoded) | ConvertFrom-Json
      if ($LASTEXITCODE -ne 0) { throw 'Node oracle failed' }
      $sdk = New-QmSdk ''
      Parse-QmSdkText $sdk ('{"type":"assistant","timestamp":"2026-10-01T00:00:02Z","message":{"content":[{"type":"tool_use","input":' + $fixture.Json + '}]}}')
      Assert-Equal $sdk.AssistantCount 1 'assistant count'
      Assert-Equal $sdk.Groups[0].Chars $want.chars 'JSON character count'
      Assert-Equal $sdk.EstOut $want.est 'estimated tokens'
      Assert-Equal $sdk.ToolCount 1 'local tool count'
    }
  }
  Test-Case 'JSON number serialization matches 512 deterministic binary64 samples' {
    $samples = @'
const out=[], b=Buffer.alloc(8);
const add=n=>{b.writeDoubleBE(n);out.push({bits:b.toString('hex'),json:JSON.stringify(n),fixed:n.toFixed(2)});};
[Number.MIN_VALUE,Number.MAX_VALUE,-Number.MIN_VALUE,-Number.MAX_VALUE,0,-0,1e-6,1e-7,1e20,1e21,1000000000000000100,0.84551240822557006].forEach(add);
let seed=0x5eed1234;const next=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return seed>>>0;};
while(out.length<512){b.writeUInt32BE(next(),0);b.writeUInt32BE(next(),4);const n=b.readDoubleBE();if(Number.isFinite(n))add(n);}
console.log(JSON.stringify(out));
'@ | & node --no-warnings - | ConvertFrom-Json
    Assert-Equal @($samples).Count 512 'oracle sample count'
    foreach ($sample in $samples) {
      $number = [BitConverter]::Int64BitsToDouble([Convert]::ToInt64($sample.bits, 16))
      Assert-Equal ([QoderMeter.JsonEstimate]::ToolInput(@{ n = $number })) ('{"n":' + $sample.json + '}') ('JSON binary64 ' + $sample.bits)
      Assert-Equal ([QoderMeter.JsonEstimate]::Fixed($number, 2)) $sample.fixed ('toFixed binary64 ' + $sample.bits)
    }
  }
  Test-Case 'JSON estimates propagate unchanged to turn tokens and TPS' {
    $fixture = $inputs[0]
    $encoded = [Convert]::ToBase64String($utf8.GetBytes($fixture.Json))
    $want = ($oracleCode | & node --no-warnings - $encoded) | ConvertFrom-Json
    $sdk = New-QmSdk ''
    Parse-QmSdkText $sdk ('{"type":"assistant","timestamp":"2026-10-01T00:00:02Z","message":{"content":[{"type":"tool_use","input":' + $fixture.Json + '}]}}')
    Assert-Equal $sdk.EstOut $want.est 'estimate'
    $script:QM_S.sdk = $sdk; $script:QM_S.seg = New-QmSeg ''
    Parse-QmSegText $script:QM_S.seg (@'
{"type":"turn.started","ts":"2026-10-01T00:00:00Z","turn_id":"t"}
{"type":"model.request.started","ts":"2026-10-01T00:00:00Z","turn_id":"t","request_id":"r"}
{"type":"model.response.completed","ts":"2026-10-01T00:00:02Z","turn_id":"t","request_id":"r"}
'@)
    Compute-QmTurn
    Assert-Equal $script:QM_S.turnTokens $want.est 'turn tokens'
    Assert-Equal $script:QM_S.tps ($want.est / 2.0) 'turn TPS'
  }
  Test-Case 'display Math.round midpoint behavior' {
    Assert-Equal (Format-QmK 2.5) '3' 'K'
    Assert-Equal (Format-QmCount 2.5) '3' 'count'
    Assert-Equal (Format-QmDuration 2.5) '3s' 'duration'
    Assert-Equal (Format-QmDuration 62.5) '1m 03s' 'duration seconds'
    Assert-Equal (Format-QmDuration 3750) '1h 03m' 'duration minutes'
    Assert-Equal (Format-QmElapsed 12.5) '13s' 'elapsed'
    Assert-Equal (Format-QmTps 100.5) '101' 'TPS'
    Assert-Equal (Format-QmCredits 100.5) '101' 'credits'
  }
  Test-Case 'display toFixed follows binary64 rather than decimal bankers rounding' {
    Assert-Equal (Format-QmTps 2.25) '2.3' 'TPS fixed'
    Assert-Equal (Format-QmElapsed 2.25) '2.3s' 'elapsed fixed'
    Assert-Equal (Format-QmCount 1250) '1.3k' 'count fixed'
    Assert-Equal (Format-QmK 1250000) '1.25m' 'K fixed'
    Assert-Equal (Format-QmCredits 1.005) '1.00' 'binary64 below half'
    Assert-Equal (Format-QmCredits 1.015) '1.01' 'binary64 below half second case'
    Assert-Equal (Format-QmCredits 0.625) '0.63' 'exact half'
  }
  Test-Case 'SDK timestamps include non-assistant records and spaced JSON' {
    $sdk = New-QmSdk ''
    Parse-QmSdkText $sdk (@'
{"type":"user","timestamp":"2026-10-01T00:00:00Z"}
{"type": "assistant", "timestamp": "2026-10-01T00:00:02Z", "message":{"content":[]}}
{"type":"system","timestamp":"2026-10-01T00:00:05Z"}
{"type":"user","timestamp":"invalid"}
'@)
    Assert-Equal $sdk.FirstTs 1790812800000L 'first timestamp'
    Assert-Equal $sdk.LastTs 1790812805000L 'last timestamp'
    Assert-Equal $sdk.AssistantCount 1 'spaced assistant'
    $sdk = New-QmSdk ''
    Parse-QmSdkText $sdk '{"type":"user","timestamp":"2026-10-01T00:00:00Z","nested":{}'
    Parse-QmSdkText $sdk '}'
    Assert-Equal $sdk.FirstTs 1790812800000L 'partial non-assistant ending with nested brace'
  }
  Test-Case 'Read-QmBlock retains incomplete UTF8 suffix at byte offset' {
    $file = Join-Path $tempRoot 'utf8.jsonl'
    foreach ($sample in @('中', 'é', [char]::ConvertFromUtf32(0x1f600))) {
      $bytes = $utf8.GetBytes('abc' + $sample + '文')
      $charBytes = $utf8.GetByteCount($sample)
      for ($split = 1; $split -lt $charBytes; $split++) {
        [IO.File]::WriteAllBytes($file, [byte[]]$bytes[0..(2 + $split)])
        $first = Read-QmBlock $file 0
        Assert-Equal $first.Text 'abc' 'complete UTF8 prefix'
        Assert-Equal $first.Bytes 3L 'consumed byte offset'
        [IO.File]::WriteAllBytes($file, $bytes)
        $next = Read-QmBlock $file $first.Bytes
        Assert-Equal ($first.Text + $next.Text) ('abc' + $sample + '文') 'joined UTF8 text'
        Assert-Equal ($first.Bytes + $next.Bytes) $bytes.Length 'total bytes'
      }
    }
    [IO.File]::WriteAllBytes($file, [byte[]]@(0xe4,0xb8))
    Assert-Equal (Read-QmBlock $file 0).Bytes 0L 'only incomplete code point'
    # Real incremental SDK consumption, with Chinese split between polls.
    $json = '{"type":"assistant","timestamp":"2026-10-01T00:00:02Z","message":{"content":[{"type":"text","text":"中文"}]}}'
    $bytes = $utf8.GetBytes($json); $cut = $utf8.GetByteCount($json.Substring(0, $json.IndexOf('中'))) + 1
    [IO.File]::WriteAllBytes($file, [byte[]]$bytes[0..($cut - 1)])
    $sdk = New-QmSdk $file; $script:QM_S.sdk = $sdk
    Update-QmSdk
    Assert-Equal $sdk.AssistantCount 0 'partial record not counted'
    [IO.File]::WriteAllBytes($file, $bytes)
    Update-QmSdk; Update-QmSdk
    Assert-Equal $sdk.AssistantCount 1 'record counted once'
    Assert-Equal $sdk.Groups[0].Chars 2 'uncorrupted Chinese'
    Assert-Equal $sdk.EstOut 1 'Chinese estimate'
  }
  Test-Case 'segment discovery chooses newest mtime not filename order' {
    $dir = Join-Path $script:QM_SEGROOT '2026\sid\segments'
    [void][IO.Directory]::CreateDirectory($dir)
    $old = Join-Path $dir 'a.jsonl'; $new = Join-Path $dir 'z.jsonl'
    [IO.File]::WriteAllText($old, '', $utf8); [IO.File]::WriteAllText($new, '', $utf8)
    [IO.File]::SetLastWriteTimeUtc($old, [datetime]'2026-01-01')
    [IO.File]::SetLastWriteTimeUtc($new, [datetime]'2026-02-01')
    Assert-Equal (Find-QmSegmentFile 'sid') $new 'newest segment'
    [IO.File]::SetLastWriteTimeUtc($old, [datetime]'2026-03-01')
    Assert-Equal (Find-QmSegmentFile 'sid') $old 'newest changes without rename'
  }
  $idA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; $idB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  $routePrefix = 'qoder.workbench.navigation.lastRoute.v1 #/chat/'
  Test-Case 'route cache invalidates same-size log rewrite by mtime' {
    $file = Join-Path $script:QM_LEVELDB '000001.log'
    [IO.File]::WriteAllText($file, ($routePrefix + $idA), $utf8)
    [IO.File]::SetLastWriteTimeUtc($file, [datetime]'2026-01-01')
    Assert-Equal (Get-QmActiveSessionId) $idA 'initial route'
    [IO.File]::WriteAllText($file, ($routePrefix + $idB), $utf8)
    [IO.File]::SetLastWriteTimeUtc($file, [datetime]'2026-02-01')
    Assert-Equal (Get-QmActiveSessionId) $idB 'rewritten route'
  }
  Test-Case 'route scan reads newest 32 MiB, not oldest 32 MiB' {
    $file = Join-Path $tempRoot 'large.log'
    $fs = [IO.File]::OpenWrite($file)
    try {
      $bytes = $utf8.GetBytes($routePrefix + $idA); $fs.Write($bytes, 0, $bytes.Length)
      [void]$fs.Seek(33 * 1024 * 1024, [IO.SeekOrigin]::Begin)
      $bytes = $utf8.GetBytes($routePrefix + $idB); $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    Assert-Equal (Scan-QmRouteFile $file) $idB 'latest route after 32 MiB'
  }
  Invoke-FixtureSql @'
create table app_settings(setting_key text primary key, value_json text);
insert into app_settings values('applicationIcon.resolvedAppearance','"light"');
create table chat_sessions(session_id text primary key,title text,model text,cwd text,created_at integer,updated_at integer,archived integer,deleted_at integer);
create table chat_session_messages(session_id text,created_at integer,role text,source text);
create table chat_session_context_usage(session_id text,snapshot_json text);
with recursive n(x) as (select 1 union all select x+1 from n where x<12)
insert into chat_sessions select printf('00000000-0000-0000-0000-%012d',x),'fixture','model','C:/fixture',1790812800000,1790812800000+x,0,null from n;
'@
  Test-Case 'pinned session outside recent ten is queried and preserved' {
    $script:QM_S.pinned = '00000000-0000-0000-0000-000000000001'
    Refresh-QmData
    Assert-Equal $script:QM_S.error '' 'refresh error'
    Assert-Equal $script:QM_S.sessionId '00000000-0000-0000-0000-000000000001' 'pinned row'
    Assert-Equal $script:QM_S.pinned '00000000-0000-0000-0000-000000000001' 'pin retained'
  }
  Test-Case 'archived and deleted sessions cannot remain pinned' {
    foreach ($mutation in @('archived=1', 'archived=0,deleted_at=1790812800000')) {
      Invoke-FixtureSql ("update chat_sessions set $mutation where session_id='00000000-0000-0000-0000-000000000001'")
      $script:QM_S.pinned = '00000000-0000-0000-0000-000000000001'
      Refresh-QmData
      Assert-Equal $script:QM_S.error '' 'refresh error'
      Assert-Equal $script:QM_S.pinned $null 'invalid pin cleared'
      Assert-Equal $script:QM_S.sessionId '00000000-0000-0000-0000-000000000012' 'recent fallback'
    }
  }
  Test-Case 'appearance uses observed JSON-string source with two-second cache' {
    if (-not (Get-Command Get-QmAppAppearance -ErrorAction SilentlyContinue)) { throw 'Get-QmAppAppearance not implemented' }
    $script:testNow = 10000L
    function QmNowMs { $script:testNow }
    Assert-Equal (Get-QmAppAppearance) 'light' 'observed source'
    Invoke-FixtureSql 'update app_settings set value_json=''"dark"'' where setting_key=''applicationIcon.resolvedAppearance'''
    $script:testNow = 11999L
    Assert-Equal (Get-QmAppAppearance) 'light' 'cached before two seconds'
    $script:testNow = 12000L
    Assert-Equal (Get-QmAppAppearance) 'dark' 'refresh at two seconds'
    foreach ($value in @('"auto"', '"unsupported"', '{"theme":"light"}', 'null', 'invalid-json')) {
      Invoke-FixtureSql ("update app_settings set value_json='$value' where setting_key='applicationIcon.resolvedAppearance'")
      $script:testNow += 2000
      $want = if ($value -eq '"auto"') { 'auto' } else { $null }
      Assert-Equal (Get-QmAppAppearance) $want 'validated source value'
    }
    Invoke-FixtureSql 'delete from app_settings; insert into app_settings values(''theme.unverified'',''"dark"'')'
    $script:testNow += 2000
    Assert-Equal (Get-QmAppAppearance) $null 'no invented settings fallback'
  }
} finally {
  Close-QmDb
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output ("RESULT PowerShell {0}: {1} passed, {2} failed" -f $PSVersionTable.PSVersion, $script:passed, $script:failed)
if ($script:failed) { exit 1 }
