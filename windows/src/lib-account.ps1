# Qoder Meter for Windows - 账户积分与权益领取（内置）
# 读取本机 Qoder 登录态（Electron safeStorage 加密的 auth.v1.dat），
# 调用官方账号接口查询余额，并领取全部可领权益（每日 100、SOTA 补给包等）。
# 不保存密码、不打印令牌、不写 Qoder 数据；令牌只在内存中使用。

$script:QM_ACCOUNT_READ_MS = 30000
$script:QM_CAMPAIGN_READ_MS = 60000
$script:QM_CLAIM_RETRY_MS = 900000
$script:QM_AUTH_READ_MS = 300000
$script:QM_CACHE_READ_MS = 300000
# Qoder 桌面端在请求里带上 Cosy-ClientType；缺少它时活动接口会返回空列表，
# 领取接口也会拒绝（500/409）。10 是桌面客户端的取值。
$script:QM_CLIENT_TYPE = '10'
$script:QM_API_BASE = 'https://openapi.qoder.sh'
$script:QM_CLAIMS_PATH = Join-Path $script:QM_SETTINGSD 'claims.json'
$script:QM_CLAIMS_MAX = 400
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

if (-not ('QoderMeter.Shield' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace QoderMeter {
  [StructLayout(LayoutKind.Sequential)]
  internal struct AUTH_INFO {
    public uint cbSize;
    public uint dwInfoVersion;
    public IntPtr pbNonce;
    public uint cbNonce;
    public IntPtr pbAuthData;
    public uint cbAuthData;
    public IntPtr pbTag;
    public uint cbTag;
    public IntPtr pbMacContext;
    public uint cbMacContext;
    public uint cbAAD;
    public ulong cbData;
    public uint dwFlags;
  }

  // 用系统 bcrypt 解 Electron safeStorage 的 AES-256-GCM 数据（v10 前缀）。
  public static class Shield {
    [DllImport("bcrypt.dll")] static extern int BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, [MarshalAs(UnmanagedType.LPWStr)] string pszAlgId, [MarshalAs(UnmanagedType.LPWStr)] string pszImplementation, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptSetProperty(IntPtr hObject, [MarshalAs(UnmanagedType.LPWStr)] string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref AUTH_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr hKey);
    [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);

    private static void Check(int rc, string what) { if (rc != 0) throw new Exception(what + " rc=" + rc); }

    public static byte[] AesGcmDecrypt(byte[] key, byte[] nonce, byte[] cipher, byte[] tag) {
      IntPtr alg = IntPtr.Zero, hkey = IntPtr.Zero;
      try {
        Check(BCryptOpenAlgorithmProvider(out alg, "AES", null, 0), "open");
        byte[] mode = System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM");
        Check(BCryptSetProperty(alg, "ChainingMode", mode, mode.Length, 0), "mode");
        Check(BCryptGenerateSymmetricKey(alg, out hkey, IntPtr.Zero, 0, key, key.Length, 0), "key");
        byte[] output = new byte[cipher.Length];
        AUTH_INFO info = new AUTH_INFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(AUTH_INFO));
        info.dwInfoVersion = 1;
        IntPtr pNonce = Marshal.AllocHGlobal(nonce.Length);
        IntPtr pTag = Marshal.AllocHGlobal(tag.Length);
        try {
          Marshal.Copy(nonce, 0, pNonce, nonce.Length);
          Marshal.Copy(tag, 0, pTag, tag.Length);
          info.pbNonce = pNonce; info.cbNonce = (uint)nonce.Length;
          info.pbTag = pTag; info.cbTag = (uint)tag.Length;
          int written;
          Check(BCryptDecrypt(hkey, cipher, cipher.Length, ref info, null, 0, output, output.Length, out written, 0), "decrypt");
          if (written != cipher.Length) { byte[] trimmed = new byte[written]; Array.Copy(output, trimmed, written); return trimmed; }
          return output;
        } finally { Marshal.FreeHGlobal(pNonce); Marshal.FreeHGlobal(pTag); }
      } finally {
        if (hkey != IntPtr.Zero) BCryptDestroyKey(hkey);
        if (alg != IntPtr.Zero) BCryptCloseAlgorithmProvider(alg, 0);
      }
    }
  }
}
'@
}

function Get-QmCstNow {
  try {
    return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
  } catch {
    return [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).DateTime
  }
}

# 与 Qoder 每日权益一致：10:00（UTC+8）换周期。
function Get-QmCampaignDay { return (Get-QmCstNow).AddHours(-10).ToString('yyyy-MM-dd') }

function Read-QmSharedBytes([string]$path) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $ms = New-Object IO.MemoryStream
    try { $fs.CopyTo($ms); return $ms.ToArray() } finally { $ms.Dispose() }
  } finally { $fs.Dispose() }
}

function Read-QmAuth {
  $now = (Get-QmCstNow).Ticks
  $cache = $script:QM_AUTH
  if ($cache -and $cache.ReadAt -and ($now - $cache.ReadAt) -lt ($script:QM_AUTH_READ_MS * 10000)) { return $cache }
  $out = [pscustomobject]@{ Token = ''; Name = ''; Email = ''; UserId = ''; ExpiresAt = ''; ReadAt = $now; Error = '' }
  try {
    $base = Split-Path $script:QM_DB -Parent
    $statePath = Join-Path $base 'Local State'
    $authPath = Join-Path $base 'auth.v1.dat'
    if (-not (Test-Path -LiteralPath $authPath)) { throw '未找到 Qoder 登录态（auth.v1.dat）' }
    if (-not (Test-Path -LiteralPath $statePath)) { throw '未找到 Qoder 本地密钥（Local State）' }
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $b64 = [string]$state.os_crypt.encrypted_key
    if (-not $b64) { throw 'Qoder 本地密钥不可用' }
    $raw = [Convert]::FromBase64String($b64)
    if ($raw.Length -le 5 -or [Text.Encoding]::ASCII.GetString($raw, 0, 5) -ne 'DPAPI') { throw '未知的 Qoder 密钥格式' }
    $blob = New-Object byte[] ($raw.Length - 5)
    [Array]::Copy($raw, 5, $blob, 0, $blob.Length)
    $key = [Security.Cryptography.ProtectedData]::Unprotect($blob, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $buf = Read-QmSharedBytes $authPath
    if ($buf.Length -lt 40 -or [Text.Encoding]::ASCII.GetString($buf, 0, 3) -ne 'v10') { throw '未知的 Qoder 登录态格式' }
    $nonce = New-Object byte[] 12; [Array]::Copy($buf, 3, $nonce, 0, 12)
    $ct = New-Object byte[] ($buf.Length - 31); [Array]::Copy($buf, 15, $ct, 0, $ct.Length)
    $tag = New-Object byte[] 16; [Array]::Copy($buf, $buf.Length - 16, $tag, 0, 16)
    $plain = [QoderMeter.Shield]::AesGcmDecrypt($key, $nonce, $ct, $tag)
    $j = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    if (-not $j.token) { throw '登录态中没有令牌' }
    $out.Token = [string]$j.token
    $out.ExpiresAt = [string]$j.expiresAt
    if ($j.user) { $out.Name = [string]$j.user.name; $out.Email = [string]$j.user.email; $out.UserId = [string]$j.user.id }
  } catch {
    $out.Token = ''; $out.Error = $_.Exception.Message
    # Retry a failed login read after one minute so a fresh Qoder login is picked up promptly.
    $out.ReadAt = $now - (($script:QM_AUTH_READ_MS - 60000) * 10000)
  }
  $script:QM_AUTH = $out
  return $out
}

function Get-QmAuth {
  $a = Read-QmAuth
  if (-not $a.Token) { throw $a.Error }
  return $a
}

function ConvertFrom-QmApiError($err) {
  $msg = $err.Exception.Message
  try {
    if ($err.ErrorDetails.Message) {
      $j = $err.ErrorDetails.Message | ConvertFrom-Json
      if ($j.errorCode -eq 'Unauthorized' -or $j.code -eq 'TOKEN_INVALID') { $script:QM_AUTH = $null }
      if ($j.message) { $msg = [string]$j.message }
      elseif ($j.errorMessage) { $msg = [string]$j.errorMessage }
      if ($j.code) { $msg = [string]$j.code + ': ' + $msg }
    }
  } catch { }
  return $msg
}

function Invoke-QmApi([string]$method, [string]$path, [string]$body) {
  $ProgressPreference = 'SilentlyContinue'
  $auth = Get-QmAuth
  $headers = @{ 'Authorization' = 'Bearer ' + $auth.Token; 'Accept' = 'application/json'; 'User-Agent' = 'QoderMeter/1.0'; 'Cosy-ClientType' = $script:QM_CLIENT_TYPE }
  try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $args = @{ Uri = ($script:QM_API_BASE + $path); Method = $method; Headers = $headers; TimeoutSec = 8; UseBasicParsing = $true }
    if ($null -ne $body -and $body -ne '') { $args.Body = $body; $args.ContentType = 'application/json' }
    $resp = Invoke-WebRequest @args
    # Windows PowerShell 5.1 falls back to Latin-1 unless the server sends a charset;
    # decode the raw bytes explicitly so Chinese benefit names are not mojibake.
    if ($null -eq $resp) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    $msg = ConvertFrom-QmApiError $_
    if ($status -eq 401) { $msg = '登录态已失效，请在 Qoder 重新登录' }
    elseif ($status -eq 429) { $msg = '请求过于频繁，稍后再试' }
    throw $msg
  }
}

# ---------------------------------------------------------------- 余额与权益
function Get-QmUsageNow {
  $u = Invoke-QmApi 'Get' '/sash/api/v2/me/usage' ''
  if (-not $u -or -not $u.qoderUsage) { throw '账号接口没有返回积分信息' }
  $q = $u.qoderUsage
  $pkgs = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($q.dedicatedResourcePackages)) {
    if (-not $p) { continue }
    $title = [string]$p.name
    $desc = ''
    foreach ($lab in @($p.displayLabels)) {
      if (-not $lab) { continue }
      if ($lab.dimension -eq 'title' -and $lab.valueI18n.'zh-CN') { $title = [string]$lab.valueI18n.'zh-CN' }
      if ($lab.dimension -eq 'description' -and $lab.valueI18n.'zh-CN') { $desc = [string]$lab.valueI18n.'zh-CN' }
    }
    $pkgs.Add([pscustomobject]@{
      Name = [string]$p.name; Title = $title; Description = $desc
      Total = [long]$p.total; Used = [long]$p.used; Remaining = [long]$p.remaining
      ExpiresAt = [long]$p.expiresAt; Available = [bool]$p.available; Status = [string]$p.status
    })
  }
  $uq = $q.userQuota; $aq = $q.addOnQuota
  return [pscustomobject]@{
    Plan = [string]$q.userType; ExpiresAt = [long]$q.expiresAt
    PlanTotal = [long]$uq.total; PlanUsed = [long]$uq.used; PlanRemaining = [long]$uq.remaining
    AddOnTotal = if ($aq) { [long]$aq.total } else { 0 }
    AddOnUsed = if ($aq) { [long]$aq.used } else { 0 }
    AddOnRemaining = if ($aq) { [long]$aq.remaining } else { 0 }
    Packages = $pkgs
  }
}

function ConvertTo-QmCampaign($x) {
  if (-not $x -or -not $x.campaignId) { return $null }
  $title = ''; $desc = ''
  foreach ($pl in @($x.placements)) {
    if (-not $pl) { continue }
    $zh = $pl.content.'zh'
    if (-not $zh -and $pl.content.'en') { $zh = $pl.content.'en' }
    if ($zh) {
      if (-not $title -and $zh.title) { $title = [string]$zh.title }
      if (-not $desc -and $zh.description) { $desc = [string]$zh.description }
    }
  }
  $benefit = $x.benefit
  $scope = ''
  try { $scope = [string]$benefit.modelScope.modelSeries.key } catch { }
  return [pscustomobject]@{
    CampaignId = [string]$x.campaignId; CampaignKey = [string]$x.campaignKey
    Title = $title; Description = $desc; ActionType = [string]$x.actionType
    ClaimStatus = [string]$x.claimStatus
    Amount = if ($benefit.amount) { [long]$benefit.amount } else { 0 }
    Kind = [string]$benefit.kind; Scope = $scope
    Validity = if ($benefit.validity.mode) { [string]$benefit.validity.mode } else { '' }
    FixedEnd = if ($benefit.validity.fixedEnd) { [string]$benefit.validity.fixedEnd } else { '' }
    Days = if ($benefit.validity.days) { [int]$benefit.validity.days } else { 0 }
    StartAt = [long]$x.startAt; EndAt = [long]$x.endAt
  }
}

function Get-QmCampaignsNow {
  $c = Invoke-QmApi 'Get' '/sash/api/v1/me/campaigns' ''
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($x in @($c.campaigns)) {
    $item = ConvertTo-QmCampaign $x
    if ($item) { $list.Add($item) }
  }
  # Qoder's webview also caches the campaign list. If the API answers with an
  # empty list (older clients), fall back to that cache; when the API returns
  # any campaigns its view wins, so a stale cache cannot resurrect a benefit
  # that was already claimed.
  if ($script:QM_CAMPAIGN_CACHE_FALLBACK -and $list.Count -eq 0) {
    try {
      $seen = @{}; foreach ($x in $list) { $seen[[string]$x.CampaignId] = $true }
      $claimed = Get-QmClaimedTodayIds
      foreach ($x in @(Get-QmCachedCampaigns)) {
        if ($seen[[string]$x.CampaignId] -or $claimed[[string]$x.CampaignId]) { continue }
        if ($x.ClaimStatus -ne 'CLAIMABLE' -or $x.ActionType -ne 'CLAIM_BENEFIT') { continue }
        $list.Add($x); $seen[[string]$x.CampaignId] = $true
      }
    } catch { }
  }
  return $list
}

# Read a Chromium cache file while Qoder holds it open (share read/write/delete).
function Read-QmCacheText([string]$path) {
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]7))
  try {
    $ms = New-Object IO.MemoryStream
    try { $fs.CopyTo($ms); $bytes = $ms.ToArray() } finally { $ms.Dispose() }
  } finally { $fs.Dispose() }
  return ([Text.Encoding]::GetEncoding(28591)).GetString($bytes)
}

# Extract the newest {"showCampaign":...,"campaigns":[...]} object from cache text.
function ConvertFrom-QmCampaignCacheText([string]$text) {
  if (-not $text) { return $null }
  $latin = [Text.Encoding]::GetEncoding(28591)
  $utf8 = New-Object Text.UTF8Encoding $false
  $needle = '"showCampaign"'
  $best = $null; $bestEnd = 0L; $pos = 0
  while (($pos = $text.IndexOf($needle, $pos, [StringComparison]::Ordinal)) -ge 0) {
    $start = $pos
    while ($start -gt 0 -and $text[$start] -ne '{') { $start-- }
    $depth = 0; $inStr = $false; $esc = $false; $end = -1
    $limit = [Math]::Min($text.Length, $start + 400000)
    for ($i = $start; $i -lt $limit; $i++) {
      $ch = $text[$i]
      if ($inStr) {
        if ($esc) { $esc = $false }
        elseif ($ch -eq '\') { $esc = $true }
        elseif ($ch -eq '"') { $inStr = $false }
        continue
      }
      if ($ch -eq '"') { $inStr = $true; continue }
      if ($ch -eq '{') { $depth++ }
      elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -gt $start) {
      try {
        $json = $utf8.GetString($latin.GetBytes($text.Substring($start, $end - $start + 1)))
        $obj = $json | ConvertFrom-Json
      } catch { $obj = $null }
      if ($obj -and $obj.campaigns -and @($obj.campaigns).Count -gt 0) {
        $maxEnd = 0L
        foreach ($c in @($obj.campaigns)) { if ([long]$c.endAt -gt $maxEnd) { $maxEnd = [long]$c.endAt } }
        if (-not $best -or $maxEnd -gt $bestEnd) { $best = $obj; $bestEnd = $maxEnd }
      }
    }
    $pos += $needle.Length
  }
  return $best
}

function Get-QmCachedCampaigns {
  $now = (Get-QmCstNow).Ticks
  $slot = $script:QM_CACHE_CAMPAIGNS
  if ($slot -and ($now - [long]$slot.ReadAt) -lt ($script:QM_CACHE_READ_MS * 10000)) { return $slot.List }
  $list = New-Object System.Collections.Generic.List[object]
  $best = $null; $bestEnd = 0L
  try {
    $base = Split-Path $script:QM_DB -Parent
    $cacheDir = Join-Path $base 'Cache\Cache_Data'
    if (Test-Path -LiteralPath $cacheDir) {
      foreach ($f in @(Get-ChildItem -LiteralPath $cacheDir -Filter 'data_*' -File -ErrorAction SilentlyContinue)) {
        $text = $null
        try { $text = Read-QmCacheText $f.FullName } catch { continue }
        $obj = ConvertFrom-QmCampaignCacheText $text
        if (-not $obj) { continue }
        $maxEnd = 0L
        foreach ($c in @($obj.campaigns)) { if ([long]$c.endAt -gt $maxEnd) { $maxEnd = [long]$c.endAt } }
        if (-not $best -or $maxEnd -gt $bestEnd) { $best = $obj; $bestEnd = $maxEnd }
      }
    }
  } catch { }
  if ($best) {
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($x in @($best.campaigns)) {
      $item = ConvertTo-QmCampaign $x
      if (-not $item) { continue }
      # Drop entries whose window has passed; cached bodies can lag behind Qoder.
      if ($item.StartAt -gt 0 -and $item.StartAt -gt ($nowSec + 300)) { continue }
      if ($item.EndAt -gt 0 -and $item.EndAt -le $nowSec) { continue }
      $list.Add($item)
    }
  }
  $script:QM_CACHE_CAMPAIGNS = [pscustomobject]@{ ReadAt = $now; List = $list }
  return $list
}

function Get-QmClaimedTodayIds {
  $set = @{}
  $day = Get-QmCampaignDay
  foreach ($e in (Get-QmClaims).Entries) { if ([string]$e.day -eq $day) { $set[[string]$e.campaignId] = $true } }
  return $set
}

function Get-QmClaimableCampaigns($campaigns) {
  $claimed = Get-QmClaimedTodayIds
  return @($campaigns | Where-Object { $_.ClaimStatus -eq 'CLAIMABLE' -and $_.ActionType -eq 'CLAIM_BENEFIT' -and -not $claimed[[string]$_.CampaignId] })
}

# ---------------------------------------------------------------- 领取记录
function Get-QmClaims {
  if ($script:QM_CLAIMS) { return $script:QM_CLAIMS }
  $obj = [pscustomobject]@{ Version = 1; Entries = (New-Object System.Collections.Generic.List[object]) }
  try {
    if (Test-Path -LiteralPath $script:QM_CLAIMS_PATH) {
      $raw = [IO.File]::ReadAllText($script:QM_CLAIMS_PATH) | ConvertFrom-Json
      foreach ($e in @($raw.entries)) { if ($e -and $e.campaignId) { $obj.Entries.Add($e) } }
    }
  } catch { }
  $script:QM_CLAIMS = $obj
  return $obj
}

function Save-QmClaims {
  try {
    if (-not (Test-Path $script:QM_SETTINGSD)) { [void][IO.Directory]::CreateDirectory($script:QM_SETTINGSD) }
    $data = [pscustomobject]@{ version = 1; entries = $script:QM_CLAIMS.Entries.ToArray() }
    $json = ConvertTo-Json -InputObject $data -Depth 6 -Compress
    $tmp = $script:QM_CLAIMS_PATH + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    [IO.File]::Copy($tmp, $script:QM_CLAIMS_PATH, $true)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  } catch { }
}

function Add-QmClaimRecord($campaign, $result) {
  $claims = Get-QmClaims
  $day = Get-QmCampaignDay
  foreach ($e in $claims.Entries) { if ([string]$e.campaignId -eq [string]$campaign.CampaignId -and [string]$e.day -eq $day) { return } }
  $claims.Entries.Add([pscustomobject]@{
    campaignId = [string]$campaign.CampaignId; campaignKey = [string]$campaign.CampaignKey
    day = $day; title = [string]$campaign.Title; amount = [long]$campaign.Amount
    kind = [string]$campaign.Kind; scope = [string]$campaign.Scope
    claimedAt = $(if ($result.claimedAt) { [string]$result.claimedAt } else { (Get-QmCstNow).ToString('s') })
    expiresAt = $(if ($result.expiresAt) { [string]$result.expiresAt } else { '' })
    replayed = [bool]$result.replayed
  })
  if ($claims.Entries.Count -gt $script:QM_CLAIMS_MAX) { $claims.Entries.RemoveRange(0, $claims.Entries.Count - $script:QM_CLAIMS_MAX) }
  Save-QmClaims
}

# ---------------------------------------------------------------- 展示辅助
function Format-QmScope([string]$scope) {
  switch ($scope) {
    'C_S_U_SERIES' { return 'SOTA 专属' }
    'ALL_MODELS'   { return '全模型' }
    default        { return '' }
  }
}

function Format-QmExpiry([long]$ms) {
  if ($ms -le 0) { return '' }
  try {
    $d = [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToOffset([TimeSpan]::FromHours(8))
    $now = [DateTimeOffset]::new((Get-QmCstNow), [TimeSpan]::FromHours(8))
    if ($d.Date -eq $now.Date) { return '今天 ' + $d.ToString('HH:mm') }
    if ($d.Date -eq $now.Date.AddDays(1)) { return '明天 ' + $d.ToString('HH:mm') }
    return $d.ToString('MM-dd HH:mm')
  } catch { return '' }
}

function Format-QmPlan([string]$plan) {
  switch ($plan) {
    'personal_professional' { return 'Pro' }
    'personal_free'         { return '免费版' }
    'personal_teams'        { return 'Teams' }
    'enterprise'            { return '企业版' }
    default { if ($plan) { return $plan } else { return '—' } }
  }
}

function Format-QmNum([long]$n) { return $n.ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }

function Format-QmBalanceDetail($s) {
  $parts = @('套餐 ' + (Format-QmNum $s.PlanRemaining))
  if ($s.AddOnTotal -gt 0 -or $s.AddOnRemaining -gt 0) { $parts += '加赠 ' + (Format-QmNum $s.AddOnRemaining) }
  if ($s.PackageRemaining -gt 0) { $parts += '活动包 ' + (Format-QmNum $s.PackageRemaining) }
  return $parts -join ' · '
}

# ---------------------------------------------------------------- 状态
function Get-QmAccountStatus {
  $a = $script:ACCOUNT
  $out = [pscustomobject][ordered]@{
    State = 'loading'; Name = ''; Plan = ''; PlanExpiresAt = 0L
    Balance = 0L; PlanRemaining = 0L; PlanTotal = 0L; AddOnRemaining = 0L; AddOnTotal = 0L; PackageRemaining = 0L
    Packages = @(); Claimable = @(); TodayAmount = 0L; TodayCount = 0; TodayItems = @()
    Message = ''; At = ''
  }
  if (-not $a) { return $out }
  if ($a.Auth -and $a.Auth.Name) { $out.Name = $a.Auth.Name }
  if ($a.Error) { $out.State = if ($a.Auth -and $a.Auth.Error) { 'noauth' } else { 'error' }; $out.Message = $a.Error; return $out }
  if ($a.Usage) {
    $u = $a.Usage
    $out.State = 'ok'; $out.Plan = Format-QmPlan $u.Plan; $out.PlanExpiresAt = $u.ExpiresAt
    $out.PlanRemaining = $u.PlanRemaining; $out.PlanTotal = $u.PlanTotal
    $out.AddOnRemaining = $u.AddOnRemaining; $out.AddOnTotal = $u.AddOnTotal
    $out.Packages = @($u.Packages | Where-Object { $_.Available -and $_.Remaining -gt 0 })
    $pkgSum = 0L; foreach ($p in $out.Packages) { $pkgSum += $p.Remaining }
    $out.PackageRemaining = $pkgSum
    $out.Balance = $u.PlanRemaining + $u.AddOnRemaining + $pkgSum
  }
  $out.Claimable = @(Get-QmClaimableCampaigns $a.Campaigns)
  $day = Get-QmCampaignDay
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($e in (Get-QmClaims).Entries) {
    if ([string]$e.day -eq $day) { $items.Add($e); $out.TodayAmount += [long]$e.amount; $out.TodayCount++ }
  }
  $out.TodayItems = $items.ToArray()
  if ($a.At) { $out.At = $a.At }
  return $out
}

function Format-QmAccountPill {
  $s = Get-QmAccountStatus
  if ($script:ACCOUNT -and $script:ACCOUNT.Running) { return @{ Text = '领取中…'; Tone = 'gray' } }
  if ($s.State -eq 'noauth') { return @{ Text = '未登录'; Tone = 'gray' } }
  if ($s.State -eq 'error') { return @{ Text = '账号异常'; Tone = 'red' } }
  if ($s.Claimable.Count -gt 0) { return @{ Text = '待领 ' + $s.Claimable.Count + ' 项'; Tone = 'gold' } }
  if ($s.State -ne 'ok') { return @{ Text = '账号读取中'; Tone = 'gray' } }
  # Show the remaining balance and today's gains instead of a bare "not claimed" label.
  $text = '余 ' + (Format-QmNum $s.Balance) + ' · 今 +' + (Format-QmNum $s.TodayAmount)
  if ($s.TodayCount -gt 0) { return @{ Text = $text; Tone = 'green' } }
  return @{ Text = $text; Tone = 'gray' }
}

# ---------------------------------------------------------------- 领取
function Invoke-QmAccountClaim([switch]$Auto) {
  $acct = $script:ACCOUNT
  if ($acct.Running) { return [pscustomobject]@{ Claimed = @(); Failed = @(); Message = '上一次领取尚未结束' } }
  $done = New-Object System.Collections.Generic.List[object]
  $failed = New-Object System.Collections.Generic.List[object]
  $firstFail = New-Object System.Collections.Generic.List[object]
  if ($null -eq $acct.Campaigns) {
    try { $acct.Campaigns = @(Get-QmCampaignsNow); $acct.CampAt = (Get-QmCstNow).Ticks } catch { return [pscustomobject]@{ Claimed = @(); Failed = @(); Message = $_.Exception.Message } }
  }
  $targets = @(Get-QmClaimableCampaigns $acct.Campaigns)
  if (-not $targets.Count) { return [pscustomobject]@{ Claimed = @(); Failed = @(); Message = '没有可领取的权益' } }
  $attempted = $false
  $acct.Running = $true
  try {
    foreach ($c in $targets) {
      $now = (Get-QmCstNow).Ticks
      if ($Auto -and $acct.LastFail -and $acct.LastFail.ContainsKey($c.CampaignId)) {
        if (($now - [long]$acct.LastFail[$c.CampaignId]) -lt ($script:QM_CLAIM_RETRY_MS * 10000)) { continue }
      }
      try {
        $attempted = $true
        $r = Invoke-QmApi 'Post' ('/sash/api/v1/me/campaigns/' + [Uri]::EscapeDataString($c.CampaignId) + '/claim') '{}'
        if ($r -and $r.status -eq 'CLAIMED') {
          if (-not [long]$c.Amount -and $r.benefit.amount) { $c.Amount = [long]$r.benefit.amount }
          Add-QmClaimRecord $c $r
          $done.Add([pscustomobject]@{ Title = $c.Title; Amount = $c.Amount; Kind = $c.Kind; Scope = $c.Scope; ExpiresAt = [string]$r.expiresAt; Replayed = [bool]$r.replayed })
          $c.ClaimStatus = 'CLAIMED'
          if ($acct.LastFail) { [void]$acct.LastFail.Remove($c.CampaignId) }
        } else {
          $wasCooling = $acct.LastFail -and $acct.LastFail.ContainsKey($c.CampaignId)
          if (-not $acct.LastFail) { $acct.LastFail = @{} }
          $acct.LastFail[$c.CampaignId] = $now
          if (-not $wasCooling) { $firstFail.Add([pscustomobject]@{ Title = $c.Title; Message = '未返回 CLAIMED' }) }
          $failed.Add([pscustomobject]@{ Title = $c.Title; Message = '未返回 CLAIMED' })
          try { Write-QmLog ('claim: ' + $c.Title + ' 未返回 CLAIMED') } catch { }
        }
      } catch {
        $msg = $_.Exception.Message
        $wasCooling = $acct.LastFail -and $acct.LastFail.ContainsKey($c.CampaignId)
        if (-not $acct.LastFail) { $acct.LastFail = @{} }
        $acct.LastFail[$c.CampaignId] = $now
        if (-not $wasCooling) { $firstFail.Add([pscustomobject]@{ Title = $c.Title; Message = $msg }) }
        $failed.Add([pscustomobject]@{ Title = $c.Title; Message = $msg })
        try { Write-QmLog ('claim: ' + $c.Title + ' ' + $msg) } catch { }
      }
    }
  } finally { $acct.Running = $false }
  if ($done.Count -gt 0) {
    $acct.UsageAt = 0  # 立即刷新余额
    $lines = @()
    foreach ($d in $done) {
      $scope = Format-QmScope $d.Scope
      $tail = @(); if ($scope) { $tail += $scope }
      if ($d.ExpiresAt) { try { $tail += ('有效至 ' + (Format-QmExpiry ([DateTimeOffset]::Parse($d.ExpiresAt).ToUnixTimeMilliseconds()))) } catch { } }
      $lines += ($d.Title + ' +' + (Format-QmNum $d.Amount) + $(if ($tail.Count) { '（' + ($tail -join ' · ') + '）' } else { '' }))
    }
    $text = $lines -join "`n"
    if ($text.Length -gt 240) { $text = $text.Substring(0, 237) + '…' }
    Show-QmBalloon ('已领取 ' + $done.Count + ' 项权益') $text
  }
  # Auto-claim must not fail silently: surface the first failure per campaign,
  # then stay quiet during the retry cooldown.
  if ($Auto -and $firstFail.Count -gt 0) {
    $f = $firstFail[0]
    Show-QmBalloon '自动领取失败' ($f.Title + '：' + $f.Message + "`n将在 15 分钟后重试")
  }
  if ($attempted) { $acct.CampAt = 0 }
  $msg = if ($done.Count) { '已领取 ' + $done.Count + ' 项' + $(if ($failed.Count) { '，' + $failed.Count + ' 项失败' } else { '' }) } elseif ($failed.Count) { '领取失败：' + $failed[0].Message } else { '没有可领取的权益' }
  return [pscustomobject]@{ Claimed = $done.ToArray(); Failed = $failed.ToArray(); Message = $msg }
}

# ---------------------------------------------------------------- 定时入口
function Update-QmAccountState {
  $acct = $script:ACCOUNT
  if (-not $acct) { return }
  $now = (Get-QmCstNow).Ticks
  if (-not $acct.Auth -or ($now - $acct.Auth.ReadAt) -gt ($script:QM_AUTH_READ_MS * 10000)) {
    $acct.Auth = Read-QmAuth
    $acct.Error = $acct.Auth.Error
  }
  if (-not $acct.Auth.Token) { $acct.Error = $acct.Auth.Error; return }
  # One failed network round must not retry on every 1.8s UI tick.
  if ($now -lt [long]$acct.NextTry) { return }
  if (-not $acct.Usage -or ($now - $acct.UsageAt) -gt ($script:QM_ACCOUNT_READ_MS * 10000)) {
    try {
      $acct.Usage = Get-QmUsageNow
      $acct.UsageAt = $now; $acct.Error = ''; $acct.NextTry = 0
    } catch { $acct.Error = $_.Exception.Message; $acct.NextTry = $now + 600000000 }
  }
  if ($null -eq $acct.Campaigns -or ($now - $acct.CampAt) -gt ($script:QM_CAMPAIGN_READ_MS * 10000)) {
    try {
      $acct.Campaigns = @(Get-QmCampaignsNow)
      $acct.CampAt = $now
      if ($acct.Error -and $acct.Usage) { $acct.Error = '' }
    } catch {
      if (-not $acct.Usage) { $acct.Error = $_.Exception.Message }
      $acct.NextTry = $now + 600000000
    }
  }
  if ($script:CFG.creditAuto -and -not $acct.Running) {
    $targets = @(Get-QmClaimableCampaigns $acct.Campaigns)
    if ($targets.Count -gt 0) { [void](Invoke-QmAccountClaim -Auto) }
  } elseif (-not $script:CFG.creditAuto) {
    $targets = @(Get-QmClaimableCampaigns $acct.Campaigns)
    if ($targets.Count -gt 0) {
      $fresh = @($targets | Where-Object { -not $acct.Notified -or -not $acct.Notified.ContainsKey($_.CampaignId) })
      if ($fresh.Count -gt 0) {
        if (-not $acct.Notified) { $acct.Notified = @{} }
        $names = @(); foreach ($t in $fresh) { $acct.Notified[$t.CampaignId] = $true; $names += ($t.Title + ' +' + (Format-QmNum $t.Amount)) }
        Show-QmBalloon ('发现 ' + $fresh.Count + ' 项可领权益') (($names -join "`n") + "`n右键 Meter 可立即领取")
      }
    }
  }
}

function Format-QmClaimTime([string]$value) {
  if (-not $value) { return '' }
  try {
    $d = [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
    return $d.ToOffset([TimeSpan]::FromHours(8)).ToString('HH:mm')
  } catch { return '' }
}

function Format-QmClaimExpiry([string]$value) {
  if (-not $value) { return '' }
  try {
    if ($value -match '^\d{10,}$') { return Format-QmExpiry ([long]$value) }
    $d = [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
    return Format-QmExpiry ($d.ToUnixTimeMilliseconds())
  } catch { return '' }
}

function Format-QmClaimWeekday([datetime]$date) {
  return @('周日','周一','周二','周三','周四','周五','周六')[[int]$date.DayOfWeek]
}

function New-QmClaimPill([string]$text, [string]$ink, [string]$tint) {
  $p = [Windows.Controls.Border]::new(); $p.Background = Get-QmBrush $tint
  $p.CornerRadius = [Windows.CornerRadius]::new(8); $p.Padding = [Windows.Thickness]::new(8, 2, 8, 2); $p.VerticalAlignment = 'Center'
  $p.Child = New-QmText $text 9.5 $ink 'Medium'
  return $p
}

function New-QmClaimHistoryWindow {
  $skin = Resolve-QmSkin $script:CFG.skin; $t = $script:QM_SKINS[$skin]; $k = Get-QmScale
  $w = [Windows.Window]::new(); $w.Title = 'Qoder Meter 领取记录'
  $w.Width = 500; $w.Height = 620; $w.MinWidth = 430; $w.MinHeight = 420
  $w.ResizeMode = 'CanResize'; $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterScreen'
  Initialize-QmThemedWindow $w $skin
  $outer = [Windows.Controls.Grid]::new(); $outer.Margin = [Windows.Thickness]::new(22)
  foreach ($height in @('Auto', 'Auto', '*', 'Auto')) {
    $rd = [Windows.Controls.RowDefinition]::new(); $rd.Height = [Windows.GridLengthConverter]::new().ConvertFromString($height); [void]$outer.RowDefinitions.Add($rd)
  }
  # Header ---------------------------------------------------------------
  $head = [Windows.Controls.Grid]::new(); $head.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
  foreach ($width in @('Auto', '*')) {
    $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$head.ColumnDefinitions.Add($cd)
  }
  $logo = [Windows.Controls.Border]::new(); $logo.Width = 34; $logo.Height = 34; $logo.CornerRadius = [Windows.CornerRadius]::new(10); $logo.Background = Get-QmBrush $t.goldTint
  $mark = New-QmText ([string][char]0xE81C) (14 * $k) $t.gold 'SemiBold'; $mark.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
  $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'; $logo.Child = $mark; [void]$head.Children.Add($logo)
  $titles = [Windows.Controls.StackPanel]::new(); $titles.Margin = [Windows.Thickness]::new(10, 0, 0, 0); $titles.VerticalAlignment = 'Center'
  [void]$titles.Children.Add((New-QmText '领取记录' (18 * $k) $t.text 'SemiBold'))
  $sub = New-QmText '账户余额与每日权益到账明细' (10 * $k) $t.faint; $sub.Margin = [Windows.Thickness]::new(0, 3, 0, 0); [void]$titles.Children.Add($sub)
  [Windows.Controls.Grid]::SetColumn($titles, 1); [void]$head.Children.Add($titles)
  [Windows.Controls.Grid]::SetRow($head, 0); [void]$outer.Children.Add($head)
  # Summary --------------------------------------------------------------
  $sum = [Windows.Controls.Border]::new(); $sum.Background = Get-QmBrush $t.track; $sum.BorderBrush = Get-QmBrush $t.divider
  $sum.BorderThickness = [Windows.Thickness]::new(1); $sum.CornerRadius = [Windows.CornerRadius]::new(12)
  $sum.Padding = [Windows.Thickness]::new(14, 12, 14, 13); $sum.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
  $sg = [Windows.Controls.StackPanel]::new(); $sum.Child = $sg
  $who = [Windows.Controls.Grid]::new()
  foreach ($width in @('*', 'Auto')) {
    $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$who.ColumnDefinitions.Add($cd)
  }
  $nameRow = [Windows.Controls.StackPanel]::new(); $nameRow.Orientation = 'Horizontal'; $nameRow.VerticalAlignment = 'Center'
  $name = New-QmText 'Qoder 账户' (12.5 * $k) $t.text 'SemiBold'; [void]$nameRow.Children.Add($name)
  $plan = [Windows.Controls.Border]::new(); $plan.Background = Get-QmBrush $t.grayTint; $plan.CornerRadius = [Windows.CornerRadius]::new(7)
  $plan.Padding = [Windows.Thickness]::new(7, 2, 7, 2); $plan.Margin = [Windows.Thickness]::new(8, 0, 0, 0); $plan.VerticalAlignment = 'Center'
  $planText = New-QmText '—' (9.5 * $k) $t.soft 'Medium'; $plan.Child = $planText; [void]$nameRow.Children.Add($plan)
  [void]$who.Children.Add($nameRow)
  $statePill = New-QmClaimPill '读取中' $t.gray $t.grayTint; $stateText = $statePill.Child
  [Windows.Controls.Grid]::SetColumn($statePill, 1); [void]$who.Children.Add($statePill); [void]$sg.Children.Add($who)
  $bal = [Windows.Controls.Grid]::new(); $bal.Margin = [Windows.Thickness]::new(0, 7, 0, 0)
  foreach ($width in @('*', 'Auto')) {
    $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$bal.ColumnDefinitions.Add($cd)
  }
  $balLine = [Windows.Controls.StackPanel]::new(); $balLine.Orientation = 'Horizontal'
  $balance = New-QmText '—' (25 * $k) $t.gold 'SemiBold' $true; [void]$balLine.Children.Add($balance)
  $balCap = New-QmText '可用积分' (9.5 * $k) $t.faint; $balCap.Margin = [Windows.Thickness]::new(8, 0, 0, 3); $balCap.VerticalAlignment = 'Bottom'; [void]$balLine.Children.Add($balCap)
  [void]$bal.Children.Add($balLine)
  $todayBox = [Windows.Controls.StackPanel]::new(); $todayBox.HorizontalAlignment = 'Right'; $todayBox.VerticalAlignment = 'Center'
  $today = New-QmText '+0' (14 * $k) $t.faint 'SemiBold' $true; $today.HorizontalAlignment = 'Right'; [void]$todayBox.Children.Add($today)
  $todaySub = New-QmText '今日暂无领取' (9.5 * $k) $t.faint; $todaySub.HorizontalAlignment = 'Right'; $todaySub.Margin = [Windows.Thickness]::new(0, 2, 0, 0); [void]$todayBox.Children.Add($todaySub)
  [Windows.Controls.Grid]::SetColumn($todayBox, 1); [void]$bal.Children.Add($todayBox); [void]$sg.Children.Add($bal)
  $detail = New-QmText '' (9.8 * $k) $t.soft; $detail.TextWrapping = 'Wrap'; $detail.TextTrimming = 'None'; $detail.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
  [void]$sg.Children.Add($detail)
  [Windows.Controls.Grid]::SetRow($sum, 1); [void]$outer.Children.Add($sum)
  # List -----------------------------------------------------------------
  $listWrap = [Windows.Controls.Grid]::new()
  foreach ($height in @('Auto', '*')) {
    $rd = [Windows.Controls.RowDefinition]::new(); $rd.Height = [Windows.GridLengthConverter]::new().ConvertFromString($height); [void]$listWrap.RowDefinitions.Add($rd)
  }
  $listHead = [Windows.Controls.Grid]::new(); $listHead.Margin = [Windows.Thickness]::new(2, 0, 2, 7)
  foreach ($width in @('*', 'Auto')) {
    $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$listHead.ColumnDefinitions.Add($cd)
  }
  [void]$listHead.Children.Add((New-QmText '最近记录' (11.5 * $k) $t.text 'SemiBold'))
  $listNote = New-QmText '按天分组' (9.5 * $k) $t.faint; $listNote.VerticalAlignment = 'Center'
  [Windows.Controls.Grid]::SetColumn($listNote, 1); [void]$listHead.Children.Add($listNote); [void]$listWrap.Children.Add($listHead)
  $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $rows = [Windows.Controls.StackPanel]::new(); $rows.Margin = [Windows.Thickness]::new(0, 0, 6, 0); $scroll.Content = $rows
  [Windows.Controls.Grid]::SetRow($scroll, 1); [void]$listWrap.Children.Add($scroll)
  [Windows.Controls.Grid]::SetRow($listWrap, 2); [void]$outer.Children.Add($listWrap)
  # Footer ---------------------------------------------------------------
  $foot = [Windows.Controls.Grid]::new(); $foot.Margin = [Windows.Thickness]::new(0, 10, 0, 0)
  foreach ($width in @('*', 'Auto')) {
    $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$foot.ColumnDefinitions.Add($cd)
  }
  $count = New-QmText '' (9.5 * $k) $t.faint; $count.VerticalAlignment = 'Center'; [void]$foot.Children.Add($count)
  $done = New-QmThemedButton '完成' $skin $true; $done.MinWidth = 82; $done.IsDefault = $true; $done.IsCancel = $true
  $done.Add_Click({ param($sender, $eventArgs) $script:UI.claimsWin.Hide() })
  [Windows.Controls.Grid]::SetColumn($done, 1); [void]$foot.Children.Add($done)
  [Windows.Controls.Grid]::SetRow($foot, 3); [void]$outer.Children.Add($foot)
  $w.Content = $outer
  $w.Add_Closing({ param($sender, $e) if (-not $script:QM_SHUTDOWN -and $sender.Tag -ne 'dispose') { $e.Cancel = $true; $sender.Hide() } })
  $script:QM_CLAIMS_REFS = @{
    Name = $name; Plan = $plan; PlanText = $planText; StatePill = $statePill; State = $stateText
    Balance = $balance; Today = $today; TodaySub = $todaySub; Detail = $detail
    List = $rows; ListNote = $listNote; Count = $count
  }
  return $w
}

function Sync-QmClaimHistory {
  if (-not $script:UI.claimsWin -or -not $script:QM_CLAIMS_REFS) { return }
  $refs = $script:QM_CLAIMS_REFS; $s = Get-QmAccountStatus; $t = $script:QM_SKINS[(Resolve-QmSkin $script:CFG.skin)]; $k = Get-QmScale
  $running = [bool]$script:ACCOUNT.Running
  $pillText = '读取中'; $pillInk = $t.gray; $pillTint = $t.grayTint
  if ($running) { $pillText = '领取中'; $pillInk = $t.gold; $pillTint = $t.goldTint }
  elseif ($s.State -eq 'ok' -and $s.Claimable.Count -gt 0) { $pillText = '可领 ' + $s.Claimable.Count + ' 项'; $pillInk = $t.gold; $pillTint = $t.goldTint }
  elseif ($s.State -eq 'ok') { $pillText = '已连接'; $pillInk = $t.green; $pillTint = $t.greenTint }
  elseif ($s.State -eq 'noauth') { $pillText = '未登录'; $pillInk = $t.gray; $pillTint = $t.grayTint }
  elseif ($s.State -eq 'error') { $pillText = '读取失败'; $pillInk = $t.red; $pillTint = $t.grayTint }
  $refs.State.Text = $pillText; $refs.State.Foreground = Get-QmBrush $pillInk; $refs.StatePill.Background = Get-QmBrush $pillTint
  $refs.Name.Text = $(if ($s.Name) { $s.Name } else { 'Qoder 账户' })
  if ($s.Plan) { $refs.PlanText.Text = $s.Plan; $refs.Plan.Visibility = 'Visible' } else { $refs.Plan.Visibility = 'Collapsed' }
  $refs.Balance.Text = $(if ($s.State -eq 'ok') { Format-QmNum $s.Balance } else { '—' })
  $refs.Today.Text = '+'+ (Format-QmNum $s.TodayAmount)
  $refs.Today.Foreground = Get-QmBrush $(if ($s.TodayAmount -gt 0) { $t.green } else { $t.faint })
  $refs.TodaySub.Text = $(if ($s.TodayCount -gt 0) { '今日已领 · ' + $s.TodayCount + ' 项' } else { '今日暂无领取' })
  $lines = New-Object System.Collections.Generic.List[string]
  if ($s.State -eq 'noauth') { $lines.Add('未登录：' + $s.Message); $lines.Add('在 Qoder 客户端登录后自动读取余额与权益。') }
  elseif ($s.State -eq 'error') { $lines.Add('账号读取失败：' + $s.Message) }
  elseif ($s.State -eq 'ok') {
    $lines.Add('余额构成：' + (Format-QmBalanceDetail $s))
    foreach ($p in $s.Packages) { $lines.Add($p.Title + '：' + (Format-QmNum $p.Remaining) + ' / ' + (Format-QmNum $p.Total) + $(if ($p.ExpiresAt) { ' · ' + (Format-QmExpiry $p.ExpiresAt) + ' 到期' } else { '' })) }
    if ($s.Claimable.Count -gt 0) { $lines.Add('待领取 ' + $s.Claimable.Count + ' 项') }
  } else { $lines.Add('正在读取账户余额与可领权益…') }
  if ($s.Message -and $s.State -notin @('noauth', 'error')) { $lines.Add('状态：' + $s.Message) }
  $refs.Detail.Text = $lines -join "`n"
  # Rows are rebuilt from the local ledger; no network request is made here.
  $entries = (Get-QmClaims).Entries.ToArray()
  $total = 0L; foreach ($e in $entries) { $total += [long]$e.amount }
  $refs.Count.Text = $(if ($entries.Count) { '共 ' + $entries.Count + ' 条记录 · 累计 +' + (Format-QmNum $total) + ' · 最多保留 400 条' } else { '记录保存在本机 · 最多保留 400 条' })
  # The window can stay open while auto-claim adds records; only the row list needs
  # a rebuild, and only when its contents actually change.
  $rowSig = [string]$entries.Count + '|' + (Get-QmCampaignDay) + '|' + $(if ($entries.Count) { [string]$entries[$entries.Count - 1].claimedAt } else { '' })
  if ($refs.RowSignature -ceq $rowSig) { return }
  $refs.RowSignature = $rowSig
  $refs.List.Children.Clear()
  if (-not $entries.Count) {
    $refs.ListNote.Text = '按天分组'
    $empty = [Windows.Controls.StackPanel]::new(); $empty.HorizontalAlignment = 'Center'; $empty.Margin = [Windows.Thickness]::new(0, 36, 0, 0)
    $circle = [Windows.Controls.Border]::new(); $circle.Width = 46; $circle.Height = 46; $circle.CornerRadius = [Windows.CornerRadius]::new(23)
    $circle.Background = Get-QmBrush $t.goldTint; $circle.HorizontalAlignment = 'Center'
    $glyph = New-QmText ([string][char]0xE719) 18 $t.gold 'SemiBold'; $glyph.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets'); $glyph.HorizontalAlignment = 'Center'; $glyph.VerticalAlignment = 'Center'
    $circle.Child = $glyph; [void]$empty.Children.Add($circle)
    $emptyTitle = New-QmText '暂无领取记录' (13 * $k) $t.text 'SemiBold'; $emptyTitle.HorizontalAlignment = 'Center'; $emptyTitle.Margin = [Windows.Thickness]::new(0, 12, 0, 0); [void]$empty.Children.Add($emptyTitle)
    $emptyText = New-QmText '开启自动领取后，每日积分与活动补给包会在这里留下记录。' (10.5 * $k) $t.faint
    $emptyText.TextWrapping = 'Wrap'; $emptyText.TextTrimming = 'None'; $emptyText.TextAlignment = 'Center'; $emptyText.MaxWidth = 290
    $emptyText.HorizontalAlignment = 'Center'; $emptyText.Margin = [Windows.Thickness]::new(0, 6, 0, 0); [void]$empty.Children.Add($emptyText)
    [void]$refs.List.Children.Add($empty)
    return
  }
  $groups = [ordered]@{}; $shown = 0
  for ($i = $entries.Count - 1; $i -ge 0 -and $shown -lt 40; $i--) {
    $e = $entries[$i]; $day = [string]$e.day
    if (-not $groups.Contains($day)) { $groups[$day] = New-Object System.Collections.Generic.List[object] }
    $groups[$day].Add($e); $shown++
  }
  $refs.ListNote.Text = '最近 ' + $shown + ' 条'
  $todayKey = Get-QmCampaignDay; $yesterdayKey = (Get-QmCstNow).AddDays(-1).AddHours(-10).ToString('yyyy-MM-dd')
  $first = $true
  $orderedDays = @($groups.Keys | Sort-Object -Descending)
  foreach ($day in $orderedDays) {
    $label = $day; $dateText = ''
    try {
      $parsed = [datetime]::ParseExact($day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
      $dateText = $parsed.ToString('MM-dd') + ' ' + (Format-QmClaimWeekday $parsed)
      if ($day -eq $todayKey) { $label = '今天' } elseif ($day -eq $yesterdayKey) { $label = '昨天' } else { $label = $parsed.ToString('MM-dd'); $dateText = Format-QmClaimWeekday $parsed }
    } catch { }
    $dayTotal = 0L; foreach ($e in $groups[$day]) { $dayTotal += [long]$e.amount }
    $dayHead = [Windows.Controls.Grid]::new(); $dayHead.Margin = [Windows.Thickness]::new(2, $(if ($first) { 0 } else { 12 }), 2, 6)
    foreach ($width in @('Auto', 'Auto', '*', 'Auto')) {
      $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$dayHead.ColumnDefinitions.Add($cd)
    }
    $dayLabel = New-QmText $label (11.5 * $k) $(if ($day -eq $todayKey) { $t.green } else { $t.text }) 'SemiBold'; [void]$dayHead.Children.Add($dayLabel)
    if ($dateText) {
      $dayDate = New-QmText $dateText (9.5 * $k) $t.faint; $dayDate.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
      [Windows.Controls.Grid]::SetColumn($dayDate, 1); [void]$dayHead.Children.Add($dayDate)
    }
    $daySum = New-QmText ('+' + (Format-QmNum $dayTotal)) (11 * $k) $t.green 'SemiBold' $true; $daySum.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($daySum, 3); [void]$dayHead.Children.Add($daySum)
    [void]$refs.List.Children.Add($dayHead)
    foreach ($e in $groups[$day]) {
      $row = [Windows.Controls.Border]::new(); $row.Background = Get-QmBrush $t.track; $row.CornerRadius = [Windows.CornerRadius]::new(9)
      $row.Padding = [Windows.Thickness]::new(11, 8, 11, 8); $row.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
      $rg = [Windows.Controls.Grid]::new()
      foreach ($width in @('*', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$rg.ColumnDefinitions.Add($cd)
      }
      $stack = [Windows.Controls.StackPanel]::new()
      $titleRow = [Windows.Controls.Grid]::new()
      foreach ($width in @('*', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$titleRow.ColumnDefinitions.Add($cd)
      }
      $title = New-QmText ([string]$e.title) (11.8 * $k) $t.text 'Medium'; [void]$titleRow.Children.Add($title)
      $scope = Format-QmScope ([string]$e.scope)
      if ($scope) {
        $chip = [Windows.Controls.Border]::new(); $chip.CornerRadius = [Windows.CornerRadius]::new(6); $chip.Padding = [Windows.Thickness]::new(6, 1, 6, 1); $chip.VerticalAlignment = 'Center'; $chip.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
        $isSota = [string]$e.scope -eq 'C_S_U_SERIES'
        $chip.Background = Get-QmBrush $(if ($isSota) { $t.goldTint } else { $t.blueTint })
        $chip.Child = New-QmText $scope (8.5 * $k) $(if ($isSota) { $t.gold } else { $t.blue }) 'Medium'
        [Windows.Controls.Grid]::SetColumn($chip, 1); [void]$titleRow.Children.Add($chip)
      }
      [void]$stack.Children.Add($titleRow)
      $metaBits = @()
      $time = Format-QmClaimTime ([string]$e.claimedAt); if ($time) { $metaBits += $time + ' 领取' }
      $expiry = Format-QmClaimExpiry ([string]$e.expiresAt); if ($expiry) { $metaBits += '有效至 ' + $expiry }
      if ($metaBits.Count) {
        $meta = New-QmText ($metaBits -join ' · ') (9.5 * $k) $t.faint; $meta.Margin = [Windows.Thickness]::new(0, 3, 0, 0); [void]$stack.Children.Add($meta)
      }
      [void]$rg.Children.Add($stack)
      $amount = New-QmText ('+' + (Format-QmNum ([long]$e.amount))) (13.5 * $k) $t.green 'SemiBold' $true
      $amount.VerticalAlignment = 'Center'; $amount.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
      [Windows.Controls.Grid]::SetColumn($amount, 1); [void]$rg.Children.Add($amount)
      $row.Child = $rg; [void]$refs.List.Children.Add($row)
    }
    $first = $false
  }
}

function Show-QmClaimHistory {
  $skin = Resolve-QmSkin $script:CFG.skin
  if ($script:UI.claimsWin -and $script:UI.claimsWin.Resources['QmResolvedSkin'] -ne $skin) {
    $old = $script:UI.claimsWin
    $width = $old.Width; $height = $old.Height; $left = $old.Left; $top = $old.Top
    $old.Tag = 'dispose'; $old.Close()
    $script:UI.claimsWin = New-QmClaimHistoryWindow
    $script:UI.claimsWin.Width = $width; $script:UI.claimsWin.Height = $height
    if (-not [double]::IsNaN($left) -and -not [double]::IsNaN($top)) {
      $script:UI.claimsWin.WindowStartupLocation = 'Manual'; $script:UI.claimsWin.Left = $left; $script:UI.claimsWin.Top = $top
    }
  }
  if (-not $script:UI.claimsWin) { $script:UI.claimsWin = New-QmClaimHistoryWindow }
  Sync-QmClaimHistory
  $script:UI.claimsWin.Show(); [void]$script:UI.claimsWin.Activate()
}
