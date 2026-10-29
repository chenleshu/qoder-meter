# Qoder Meter for Windows - 账户积分与权益领取（内置）
# 读取本机 Qoder 登录态（Electron safeStorage 加密的 auth.v1.dat），
# 调用官方账号接口查询余额，并领取全部可领权益（每日 100、SOTA 补给包等）。
# 不保存密码、不打印令牌、不写 Qoder 数据；令牌只在内存中使用。

$script:QM_ACCOUNT_READ_MS = 30000
$script:QM_CAMPAIGN_READ_MS = 60000
$script:QM_CLAIM_RETRY_MS = 900000
$script:QM_AUTH_READ_MS = 300000
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
  $headers = @{ 'Authorization' = 'Bearer ' + $auth.Token; 'Accept' = 'application/json'; 'User-Agent' = 'QoderMeter/1.0' }
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

function Get-QmCampaignsNow {
  $c = Invoke-QmApi 'Get' '/sash/api/v1/me/campaigns' ''
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($x in @($c.campaigns)) {
    if (-not $x -or -not $x.campaignId) { continue }
    $title = ''; $desc = ''
    foreach ($pl in @($x.placements)) {
      if (-not $pl) { continue }
      $zh = $pl.content.'zh'
      if ($zh) {
        if (-not $title -and $zh.title) { $title = [string]$zh.title }
        if (-not $desc -and $zh.description) { $desc = [string]$zh.description }
      }
    }
    $benefit = $x.benefit
    $scope = ''
    try { $scope = [string]$benefit.modelScope.modelSeries.key } catch { }
    $list.Add([pscustomobject]@{
      CampaignId = [string]$x.campaignId; CampaignKey = [string]$x.campaignKey
      Title = $title; Description = $desc; ActionType = [string]$x.actionType
      ClaimStatus = [string]$x.claimStatus
      Amount = if ($benefit.amount) { [long]$benefit.amount } else { 0 }
      Kind = [string]$benefit.kind; Scope = $scope
      Validity = if ($benefit.validity.mode) { [string]$benefit.validity.mode } else { '' }
      FixedEnd = if ($benefit.validity.fixedEnd) { [string]$benefit.validity.fixedEnd } else { '' }
      Days = if ($benefit.validity.days) { [int]$benefit.validity.days } else { 0 }
      StartAt = [long]$x.startAt; EndAt = [long]$x.endAt
    })
  }
  return $list
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
  $out.Claimable = @($a.Campaigns | Where-Object { $_.ClaimStatus -eq 'CLAIMABLE' -and $_.ActionType -eq 'CLAIM_BENEFIT' })
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
  if ($null -eq $acct.Campaigns) {
    try { $acct.Campaigns = @(Get-QmCampaignsNow); $acct.CampAt = (Get-QmCstNow).Ticks } catch { return [pscustomobject]@{ Claimed = @(); Failed = @(); Message = $_.Exception.Message } }
  }
  $targets = @($acct.Campaigns | Where-Object { $_.ClaimStatus -eq 'CLAIMABLE' -and $_.ActionType -eq 'CLAIM_BENEFIT' })
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
        $r = Invoke-QmApi 'Post' ('/sash/api/v1/me/campaigns/' + [Uri]::EscapeDataString($c.CampaignId) + '/claim') ''
        if ($r -and $r.status -eq 'CLAIMED') {
          if (-not [long]$c.Amount -and $r.benefit.amount) { $c.Amount = [long]$r.benefit.amount }
          Add-QmClaimRecord $c $r
          $done.Add([pscustomobject]@{ Title = $c.Title; Amount = $c.Amount; Kind = $c.Kind; Scope = $c.Scope; ExpiresAt = [string]$r.expiresAt; Replayed = [bool]$r.replayed })
          $c.ClaimStatus = 'CLAIMED'
          if ($acct.LastFail) { [void]$acct.LastFail.Remove($c.CampaignId) }
        } else {
          if (-not $acct.LastFail) { $acct.LastFail = @{} }
          $acct.LastFail[$c.CampaignId] = $now
          $failed.Add([pscustomobject]@{ Title = $c.Title; Message = '未返回 CLAIMED' })
        }
      } catch {
        $msg = $_.Exception.Message
        if (-not $acct.LastFail) { $acct.LastFail = @{} }
        $acct.LastFail[$c.CampaignId] = $now
        $failed.Add([pscustomobject]@{ Title = $c.Title; Message = $msg })
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
    $targets = @($acct.Campaigns | Where-Object { $_.ClaimStatus -eq 'CLAIMABLE' -and $_.ActionType -eq 'CLAIM_BENEFIT' })
    if ($targets.Count -gt 0) { [void](Invoke-QmAccountClaim -Auto) }
  } elseif (-not $script:CFG.creditAuto) {
    $targets = @($acct.Campaigns | Where-Object { $_.ClaimStatus -eq 'CLAIMABLE' -and $_.ActionType -eq 'CLAIM_BENEFIT' })
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

function Show-QmClaimHistory {
  if (-not $script:UI.claimsWin) {
    $w = [Windows.Window]::new(); $w.Title = 'Qoder Meter 领取记录'; $w.Width = 470; $w.Height = 520
    $w.MinWidth = 380; $w.MinHeight = 320; $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterScreen'
    $skin = Resolve-QmSkin $script:CFG.skin; $t = $script:QM_SKINS[$skin]
    $w.Background = Get-QmBrush $t.bg; $w.Foreground = Get-QmBrush $t.text
    $k = Get-QmScale; $font = [math]::Round(12 * $k)
    $box = [Windows.Controls.TextBox]::new(); $box.IsReadOnly = $true; $box.TextWrapping = 'Wrap'
    $box.VerticalScrollBarVisibility = 'Auto'; $box.FontSize = $font - 1; $box.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI, Microsoft YaHei UI')
    $box.Background = Get-QmBrush $t.bg; $box.Foreground = Get-QmBrush $t.text; $box.BorderThickness = [Windows.Thickness]::new(0)
    $box.Padding = [Windows.Thickness]::new(14); $box.Margin = [Windows.Thickness]::new(14)
    $w.Content = $box; $script:UI.claimsWin = $w
    $w.Add_Closing({ param($sender, $e) if (-not $script:QM_SHUTDOWN -and $sender.Tag -ne 'dispose') { $e.Cancel = $true; $sender.Hide() } })
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $s = Get-QmAccountStatus
  $lines.Add('账户：' + $(if ($s.Name) { $s.Name } else { '—' }) + ' · ' + $s.Plan)
  $lines.Add('余额：' + (Format-QmNum $s.Balance) + '（' + (Format-QmBalanceDetail $s) + '）')
  foreach ($p in $s.Packages) { $lines.Add($p.Title + '：' + (Format-QmNum $p.Remaining) + ' / ' + (Format-QmNum $p.Total) + $(if ($p.ExpiresAt) { ' · ' + (Format-QmExpiry $p.ExpiresAt) + ' 到期' } else { '' })) }
  $lines.Add('')
  $lines.Add('最近领取')
  $entries = (Get-QmClaims).Entries.ToArray()
  $any = $false
  for ($i = $entries.Count - 1; $i -ge 0 -and $i -ge $entries.Count - 40; $i--) {
    $e = $entries[$i]; $any = $true
    $lines.Add($e.day + '  ' + $e.title + '  +' + (Format-QmNum ([long]$e.amount)) + $(if ($e.scope) { '（' + (Format-QmScope ([string]$e.scope)) + '）' } else { '' }))
  }
  if (-not $any) { $lines.Add('（暂无记录；从本版开始自动记录）') }
  if ($s.Message) { $lines.Add(''); $lines.Add('状态：' + $s.Message) }
  $script:UI.claimsWin.Content.Text = $lines -join "`r`n"
  $script:UI.claimsWin.Show(); [void]$script:UI.claimsWin.Activate()
}
