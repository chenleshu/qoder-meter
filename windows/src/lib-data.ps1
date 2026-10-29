<#
  Qoder Meter for Windows - 数据层
  逐条对齐 macOS 版 src/main.js 的取数与算法口径：
    PAYLOAD_SQL / querySessionRow / readActiveSessionId / parseSdkAssistant /
    parseSegText / computeTurn / syncSdkTotals / refreshData
  只读，绝不写 Qoder 数据，绝不联网。
#>

$script:QM_HOME      = $env:USERPROFILE
$script:QM_DB        = Join-Path $env:APPDATA 'com.qoder.app.stable\main.sqlite'
$script:QM_LEVELDB   = Join-Path $env:APPDATA 'com.qoder.app.stable\Local Storage\leveldb'
$script:QM_PROJECTS  = Join-Path $script:QM_HOME '.qoder\projects'
$script:QM_SEGROOT   = Join-Path $script:QM_HOME '.qoder\logs\sessions'
$script:QM_SETTINGSD = Join-Path $env:APPDATA 'QoderMeter'

if (-not (Test-Path $script:QM_DB)) {
  # CN 版目录兜底
  $cn = Join-Path $env:APPDATA 'com.qodercn.app.stable'
  if (Test-Path (Join-Path $cn 'main.sqlite')) {
    $script:QM_DB      = Join-Path $cn 'main.sqlite'
    $script:QM_LEVELDB = Join-Path $cn 'Local Storage\leveldb'
  }
}

# ---------------------------------------------------------------- json 解析器
$script:QM_SER = $null
if (-not ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type])) {
  Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
}
if ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type]) {
  $script:QM_SER = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $script:QM_SER.MaxJsonLength = [int]::MaxValue
  $script:QM_SER.RecursionLimit = 200
}

# JSON.stringify 的字符估算口径，不使用 JavaScriptSerializer 的 HTML 转义。
# 只处理 JSON 数据树；属性顺序不影响 UTF-16 字符数/CJK 数，故无需重排整数键。
# System.Numerics 是 .NET Framework 自带组件；精确有理数避免 R/G17 与 JS 最短数字串不同。
if (-not ('QoderMeter.JsonEstimate' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Numerics.dll', 'System.Web.Extensions.dll' -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace QoderMeter {
    public static class JsonEstimate {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // Exact rational value of a positive binary64 bit pattern. The pattern
        // just beyond MaxValue also supplies its finite rounding boundary.
        static void Rational(long bits, out BigInteger n, out BigInteger d) {
            int e = (int)((bits >> 52) & 2047);
            long m = bits & 0xfffffffffffffL;
            if (e != 0) m |= 0x10000000000000L;
            int shift = e == 0 ? -1074 : e - 1075;
            n = new BigInteger(m); d = BigInteger.One;
            if (shift >= 0) n <<= shift; else d <<= -shift;
        }

        static BigInteger Nearest(BigInteger n, BigInteger d, bool tiesEven) {
            BigInteger rem;
            BigInteger q = BigInteger.DivRem(n, d, out rem);
            int cmp = (rem * 2).CompareTo(d);
            if (cmp > 0 || (cmp == 0 && (!tiesEven || !q.IsEven))) q++;
            return q;
        }

        public static double Round(double v) {
            double f = Math.Floor(v);
            return v - f >= 0.5 ? f + 1 : f;
        }

        public static string Fixed(double v, int digits) {
            if (Double.IsNaN(v) || Double.IsInfinity(v)) return v.ToString(Inv);
            if (Math.Abs(v) >= 1e21) return Number(v);
            BigInteger n, d;
            Rational(BitConverter.DoubleToInt64Bits(Math.Abs(v)), out n, out d);
            string s = Nearest(n * BigInteger.Pow(10, digits), d, false).ToString(Inv);
            if (digits > 0) {
                s = s.PadLeft(digits + 1, '0');
                s = s.Insert(s.Length - digits, ".");
            }
            return (v < 0 ? "-" : "") + s;
        }

        // Shortest decimal inside the binary64 rounding interval; closest
        // decimal wins, with an even significand at an exact tie (ECMAScript).
        public static string Number(double v) {
            if (Double.IsNaN(v) || Double.IsInfinity(v)) return "null";
            if (v == 0) return "0";
            string sign = v < 0 ? "-" : "";
            v = Math.Abs(v);
            long bits = BitConverter.DoubleToInt64Bits(v);
            BigInteger n, d, pn, pd, nn, nd;
            Rational(bits, out n, out d);
            Rational(bits - 1, out pn, out pd);
            Rational(bits + 1, out nn, out nd);
            BigInteger ln = n * pd + pn * d, ld = 2 * d * pd;
            BigInteger un = n * nd + nn * d, ud = 2 * d * nd;
            bool inclusive = (bits & 1) == 0;
            int exponent = (int)Math.Floor(Math.Log10(v));
            for (int digits = 1; digits <= 17; digits++) {
                int scale = digits - 1 - exponent;
                BigInteger sn = n, sd = d;
                if (scale >= 0) sn *= BigInteger.Pow(10, scale);
                else sd *= BigInteger.Pow(10, -scale);
                BigInteger q = Nearest(sn, sd, true);
                int direction = sn.CompareTo(q * sd) >= 0 ? 1 : -1;
                for (int attempt = 0; attempt < 3; attempt++) {
                    BigInteger candidate = q + (attempt == 0 ? 0 : attempt == 1 ? direction : -direction);
                    if (candidate <= 0) continue;
                    BigInteger cn = candidate, cd = BigInteger.One;
                    if (scale >= 0) cd = BigInteger.Pow(10, scale);
                    else cn *= BigInteger.Pow(10, -scale);
                    int low = (cn * ld).CompareTo(ln * cd);
                    int high = (cn * ud).CompareTo(un * cd);
                    if ((low > 0 || (inclusive && low == 0)) && (high < 0 || (inclusive && high == 0))) {
                        string raw = candidate.ToString(Inv);
                        int position = raw.Length - scale;
                        string s = raw.TrimEnd('0');
                        if (position > 0 && position <= 21) {
                            s = position >= s.Length ? s.PadRight(position, '0') : s.Insert(position, ".");
                        } else if (position <= 0 && position > -6) {
                            s = "0." + new string('0', -position) + s;
                        } else {
                            int e = position - 1;
                            s = s.Substring(0, 1) + (s.Length > 1 ? "." + s.Substring(1) : "") +
                                "e" + (e >= 0 ? "+" : "") + e.ToString(Inv);
                        }
                        return sign + s;
                    }
                }
            }
            throw new InvalidOperationException("No binary64 decimal representation");
        }

        static void Quote(StringBuilder b, string s) {
            b.Append('"');
            for (int i = 0; i < s.Length; i++) {
                char c = s[i];
                switch (c) {
                    case '"': b.Append("\\\""); break;
                    case '\\': b.Append("\\\\"); break;
                    case '\b': b.Append("\\b"); break;
                    case '\t': b.Append("\\t"); break;
                    case '\n': b.Append("\\n"); break;
                    case '\f': b.Append("\\f"); break;
                    case '\r': b.Append("\\r"); break;
                    default:
                        if (Char.IsHighSurrogate(c) && i + 1 < s.Length && Char.IsLowSurrogate(s[i + 1])) {
                            b.Append(c); b.Append(s[++i]);
                        } else if (c < 32 || Char.IsSurrogate(c)) {
                            b.Append("\\u"); b.Append(((int)c).ToString("x4", Inv));
                        } else b.Append(c);
                        break;
                }
            }
            b.Append('"');
        }

        static bool Numeric(object v) {
            return v is byte || v is sbyte || v is short || v is ushort || v is int || v is uint ||
                v is long || v is ulong || v is float || v is double || v is decimal;
        }

        static void Write(StringBuilder b, object v, int depth) {
            if (depth > 200) throw new InvalidOperationException("JSON nesting limit");
            if (v == null) { b.Append("null"); return; }
            if (v is string) { Quote(b, (string)v); return; }
            if (v is bool) { b.Append((bool)v ? "true" : "false"); return; }
            if (Numeric(v)) { b.Append(Number(Convert.ToDouble(v, Inv))); return; }
            IDictionary dict = v as IDictionary;
            if (dict != null) {
                b.Append('{'); bool first = true;
                foreach (DictionaryEntry entry in dict) {
                    if (!first) b.Append(','); first = false;
                    Quote(b, (string)entry.Key); b.Append(':'); Write(b, entry.Value, depth + 1);
                }
                b.Append('}'); return;
            }
            IEnumerable list = v as IEnumerable;
            if (list != null) {
                b.Append('['); bool first = true;
                foreach (object item in list) {
                    if (!first) b.Append(','); first = false; Write(b, item, depth + 1);
                }
                b.Append(']'); return;
            }
            throw new InvalidOperationException("Expected a JSON data tree");
        }

        public static string ToolInput(object v) {
            // Match JSON.stringify(b.input || {}), including JS-truthy empty arrays.
            if (v == null || (v is bool && !(bool)v) || (v is string && ((string)v).Length == 0) ||
                (Numeric(v) && (Convert.ToDouble(v, Inv) == 0 || Double.IsNaN(Convert.ToDouble(v, Inv))))) return "{}";
            StringBuilder b = new StringBuilder(); Write(b, v, 0); return b.ToString();
        }

        static object RestoreStrings(object value, List<string> strings) {
            if (value is string) return strings[Int32.Parse((string)value, Inv)];
            IDictionary dict = value as IDictionary;
            if (dict != null) {
                Dictionary<string, object> restored = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (DictionaryEntry entry in dict)
                    restored[strings[Int32.Parse((string)entry.Key, Inv)]] = RestoreStrings(entry.Value, strings);
                return restored;
            }
            object[] array = value as object[];
            if (array != null) for (int i = 0; i < array.Length; i++) array[i] = RestoreStrings(array[i], strings);
            return value;
        }

        public static object Deserialize(string json, JavaScriptSerializer serializer) {
            if (json.IndexOf("\\u", StringComparison.Ordinal) < 0 || !Regex.IsMatch(json, @"\\u[dD][89a-fA-F]"))
                return serializer.DeserializeObject(json);
            // JavaScriptSerializer replaces lone escaped surrogates with U+FFFD.
            // For these uncommon records, mask ALL string tokens before parsing
            // structure and restore exact UTF16 afterwards (no sentinel collisions).
            List<string> strings = new List<string>();
            string masked = Regex.Replace(json, @"""(?:[^""\\]|\\.)*""", delegate(Match match) {
                string token = match.Value;
                StringBuilder text = new StringBuilder();
                for (int i = 1; i < token.Length - 1; i++) {
                    char c = token[i];
                    if (c < 32) throw new FormatException("Unescaped JSON control character");
                    if (c != '\\') { text.Append(c); continue; }
                    switch (token[++i]) {
                        case '"': text.Append('"'); break;
                        case '\\': text.Append('\\'); break;
                        case '/': text.Append('/'); break;
                        case 'b': text.Append('\b'); break;
                        case 'f': text.Append('\f'); break;
                        case 'n': text.Append('\n'); break;
                        case 'r': text.Append('\r'); break;
                        case 't': text.Append('\t'); break;
                        case 'u':
                            text.Append((char)Int32.Parse(token.Substring(i + 1, 4), NumberStyles.HexNumber, Inv));
                            i += 4; break;
                        default: throw new FormatException("Invalid JSON escape");
                    }
                }
                string index = strings.Count.ToString(Inv);
                strings.Add(text.ToString());
                return "\"" + index + "\"";
            });
            return RestoreStrings(serializer.DeserializeObject(masked), strings);
        }

        public static int CompleteUtf8Prefix(byte[] bytes, int count) {
            int start = count - 1;
            while (start >= 0 && count - start <= 4 && (bytes[start] & 0xc0) == 0x80) start--;
            if (start < 0 || count - start > 4) return count;
            int lead = bytes[start], have = count - start;
            int need = lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3 :
                lead >= 0xf0 && lead <= 0xf4 ? 4 : 1;
            if (have >= need) return count;
            // Invalid sequences are not an incomplete valid UTF8 suffix.
            if (have > 1 && ((lead == 0xe0 && bytes[start + 1] < 0xa0) ||
                (lead == 0xed && bytes[start + 1] >= 0xa0) || (lead == 0xf0 && bytes[start + 1] < 0x90) ||
                (lead == 0xf4 && bytes[start + 1] >= 0x90))) return count;
            return start;
        }
    }
}
'@
}

# CJK 字符类（用码位构造，避免脚本文件编码影响正则字面量）
$script:QM_CJK = [regex]("[" + [char]0x2E80 + "-" + [char]0x9FFF +
  [char]0xF900 + "-" + [char]0xFAFF +
  [char]0xFF00 + "-" + [char]0xFFEF + "]")

# ------------------------------------------------------------------ SQL 口径
$script:QM_PAYLOAD_SQL = @'
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

function Get-QmSessionSql([string]$sid) {
  return @"
select json_object(
  'session_id', s.session_id, 'title', s.title, 'model', s.model, 'cwd', s.cwd,
  'created_at', s.created_at, 'updated_at', s.updated_at,
  'last_user_at', (select max(created_at) from chat_session_messages m
     where m.session_id=s.session_id and m.role='user' and m.source='host-projection'),
  'prompt_count', (select count(*) from chat_session_messages m
     where m.session_id=s.session_id and m.role='user' and m.source='host-projection'),
  'ctx_json', coalesce(u.snapshot_json,'')
) as payload
from chat_sessions s
left join chat_session_context_usage u on u.session_id=s.session_id
where s.session_id='$sid' and s.archived=0 and s.deleted_at is null
limit 1;
"@
}

# ------------------------------------------------------------------ 通用工具
function QmNowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function QmParseTs([object]$v) {
  if ($null -eq $v) { return 0 }
  $s = [string]$v
  if (-not $s) { return 0 }
  # 数字（秒或毫秒）
  $num = 0L
  if ([long]::TryParse($s, [ref]$num)) {
    if ($num -gt 100000000000000) { return 0 }
    if ($num -gt 100000000000) { return $num }        # 已是毫秒
    if ($num -gt 1000000000) { return $num * 1000 }   # 秒
    return 0
  }
  $dto = [DateTimeOffset]::MinValue
  try {
    $dto = [DateTimeOffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture)
    return $dto.ToUnixTimeMilliseconds()
  } catch { }
  try {
    $dto = [DateTimeOffset]::Parse($s)
    return $dto.ToUnixTimeMilliseconds()
  } catch { }
  return 0
}

function Read-QmBlock([string]$path, [long]$offset) {
  # 从 offset 读到 EOF，返回 Text / Bytes（对齐 readBlock）
  $out = @{ Text = ''; Bytes = 0L }
  if (-not $path) { return $out }
  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      if ($offset -gt 0) { [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin) }
      $cap = [int][Math]::Min(64 * 1024 * 1024, [Math]::Max(0, $fs.Length - $offset))
      if ($cap -le 0) { return $out }
      $buf = New-Object byte[] $cap
      $got = 0; $read = 0
      while ($got -lt $cap) {
        $read = $fs.Read($buf, $got, $cap - $got)
        if ($read -le 0) { break }
        $got += $read
      }
      if ($got -le 0) { return $out }
      # 未完成的 UTF8 码点留在文件里；下次从同一字节偏移重新读。
      $complete = [QoderMeter.JsonEstimate]::CompleteUtf8Prefix($buf, $got)
      $out.Bytes = [long]$complete
      $out.Text  = [System.Text.Encoding]::UTF8.GetString($buf, 0, $complete)
    } finally { $fs.Dispose() }
  } catch { }
  return $out
}

function Get-QmFileSize([string]$path) {
  if (-not $path) { return -1L }
  try { return ([System.IO.FileInfo]::new($path)).Length } catch { return -1L }
}

# --------------------------------------------------------------- sqlite 通道
$script:QM_DB_H = [IntPtr]::Zero

function Open-QmDb {
  if ($script:QM_DB_H -ne [IntPtr]::Zero) { return $true }
  try {
    $script:QM_DB_H = [QoderMeter.Sq]::Open($script:QM_DB)
    return $true
  } catch {
    Write-QmLog ('open-db 失败: ' + $_.Exception.Message)
    $script:QM_DB_H = [IntPtr]::Zero
    return $false
  }
}

function Close-QmDb {
  if ($script:QM_DB_H -ne [IntPtr]::Zero) {
    try { [void][QoderMeter.Sq]::Close($script:QM_DB_H) } catch { }
    $script:QM_DB_H = [IntPtr]::Zero
  }
}

function Query-QmJson([string]$sql) {
  # 单列 JSON 文本；失败时重连一次
  for ($try = 0; $try -lt 2; $try++) {
    if (-not (Open-QmDb)) { return $null }
    try {
      $txt = [QoderMeter.Sq]::QueryText($script:QM_DB_H, $sql)
      if ($null -eq $txt) { return $null }
      return $txt
    } catch {
      Write-QmLog ('query 失败(第' + ($try + 1) + '次): ' + $_.Exception.Message)
      Close-QmDb
    }
  }
  return $null
}

function Get-QmPayload {
  $txt = Query-QmJson $script:QM_PAYLOAD_SQL
  if (-not $txt) { return $null }
  try { return $txt | ConvertFrom-Json } catch { Write-QmLog 'payload 解析失败'; return $null }
}

function Get-QmSessionRow([string]$sid) {
  if ($sid -notmatch '^[0-9a-fA-F-]{36}$') { return $null }
  $txt = Query-QmJson (Get-QmSessionSql $sid)
  if (-not $txt) { return $null }
  try { return $txt | ConvertFrom-Json } catch { return $null }
}

# 实测 app_settings 仅有此相关键，value_json 是 JSON 字符串（当前为 "light"）。
# 这是应用图标的 resolvedAppearance，不推断未观察到的主题偏好或跟随系统设置。
$script:QM_APPEARANCE_CACHE = @{ Db = ''; At = 0L; Value = $null }
function Get-QmAppAppearance {
  $now = QmNowMs
  $cache = $script:QM_APPEARANCE_CACHE
  if ($cache.Db -eq $script:QM_DB -and $now -ge $cache.At -and ($now - $cache.At) -lt 2000) {
    return $cache.Value
  }
  $value = $null
  $txt = Query-QmJson "select value_json from app_settings where setting_key='applicationIcon.resolvedAppearance' limit 1;"
  if ($txt) {
    try {
      $parsed = $txt | ConvertFrom-Json
      if ($parsed -is [string] -and @('light', 'dark', 'auto') -ccontains $parsed) { $value = $parsed }
    } catch { }
  }
  $script:QM_APPEARANCE_CACHE = @{ Db = $script:QM_DB; At = $now; Value = $value }
  return $value
}

# -------------------------------------------------------- lastRoute 扫描
$script:QM_ROUTE_RE = [regex]'qoder\.workbench\.navigation\.lastRoute\.v1[\s\S]{0,300}?#/(?:chat|A)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'

function Scan-QmRouteFile([string]$path) {
  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = [int][Math]::Min($fs.Length, 32 * 1024 * 1024)
      [void]$fs.Seek([Math]::Max(0, $fs.Length - $len), [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] $len
      $got = 0
      while ($got -lt $len) { $r = $fs.Read($buf, $got, $len - $got); if ($r -le 0) { break }; $got += $r }
      $text = (Get-Encoding -Id 28591).GetString($buf, 0, $got)
    } finally { $fs.Dispose() }
    $ms = $script:QM_ROUTE_RE.Matches($text)
    if ($ms.Count -eq 0) { return $null }
    return $ms[$ms.Count - 1].Groups[1].Value
  } catch { return $null }
}

function Get-Encoding([int]$id) {
  try { return [System.Text.Encoding]::GetEncoding($id) } catch { return [System.Text.Encoding]::Latin1 }
}

$script:QM_ROUTE_CACHE = @{ Path = ''; Size = -1L; Mtime = 0L; Id = $null }

function Get-QmActiveSessionId {
  if (-not (Test-Path $script:QM_LEVELDB)) { return $null }
  $all = Get-ChildItem -LiteralPath $script:QM_LEVELDB -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.log' -or $_.Extension -eq '.ldb' } |
    Sort-Object -Property LastWriteTime -Descending
  $logs = @($all | Where-Object { $_.Extension -eq '.log' } | Select-Object -First 3)
  $others = @($all | Select-Object -First 8 | Where-Object { $logs.FullName -notcontains $_.FullName })
  foreach ($f in (@($logs) + $others)) {
    $size = $f.Length
    $mtime = $f.LastWriteTimeUtc.Ticks
    if ($script:QM_ROUTE_CACHE.Path -eq $f.FullName -and $script:QM_ROUTE_CACHE.Size -eq $size -and
        $script:QM_ROUTE_CACHE.Mtime -eq $mtime) {
      return $script:QM_ROUTE_CACHE.Id
    }
    $id = Scan-QmRouteFile $f.FullName
    if ($id) {
      $script:QM_ROUTE_CACHE = @{ Path = $f.FullName; Size = $size; Mtime = $mtime; Id = $id }
      return $id
    }
  }
  return $null
}

# ------------------------------------------------------------ sdk jsonl
function Find-QmSdkFile([string]$cwd, [string]$sid) {
  $enc = ($cwd -replace '[\\/]+$', '') -replace '[\\/]', '-'
  $guess = Join-Path (Join-Path $script:QM_PROJECTS $enc) ($sid + '.jsonl')
  if (Test-Path -LiteralPath $guess) { return $guess }
  if (-not (Test-Path $script:QM_PROJECTS)) { return $null }
  $hit = Get-ChildItem -LiteralPath $script:QM_PROJECTS -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName ($sid + '.jsonl') } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  return $hit
}

function New-QmSdk([string]$path) {
  return [pscustomobject]@{
    Path = $path; Offset = 0L; Tail = ''; Groups = (New-Object System.Collections.Generic.List[object])
    Credits = 0.0; OriginalCredits = 0.0; EstOut = 0L; ExactOut = 0L; InputTokens = 0L
    AssistantCount = 0; ToolCount = 0; RequestCount = 0
    RequestIds = @{}; FirstTs = 0L; LastTs = 0L
  }
}

function Parse-QmSdkText($sdk, [string]$text) {
  if (-not $text) { return }
  $combined = $sdk.Tail + $text
  $lines = $combined -split "`n"
  $carry = ''
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($null -eq $line -or $line.Length -eq 0) { continue }
    $isLast = ($i -eq $lines.Count - 1)
    $o = ConvertFrom-JsonLine $line
    if ($null -ne $o) {
      # 函数先更新时间范围，再按 type 过滤，与原版 parseSdkText 一致。
      Parse-QmSdkAssistant $sdk $o
    } elseif ($isLast) { $carry = $line }
  }
  $sdk.Tail = $carry
  if ($sdk.Tail.Length -gt 4000000) { $sdk.Tail = '' }
  if ($sdk.Groups.Count -gt 1200) { $sdk.Groups.RemoveRange(0, $sdk.Groups.Count - 900) }
}

function Looks-LikeJson([string]$line) {
  return $line.TrimEnd().EndsWith('}')
}

function ConvertFrom-JsonLine([string]$line) {
  if ($script:QM_SER) {
    try { return [QoderMeter.JsonEstimate]::Deserialize($line, $script:QM_SER) } catch { return $null }
  }
  try { return $line | ConvertFrom-Json } catch { return $null }
}

function DictVal($d, [string]$k) {
  if ($null -eq $d) { return $null }
  if ($d -is [System.Collections.IDictionary]) {
    if ($d.ContainsKey($k)) { return $d[$k] }
    return $null
  }
  $p = $d.PSObject.Properties[$k]
  if ($p) { return $p.Value }
  return $null
}

function NumVal($d, [string]$k) {
  $v = DictVal $d $k
  if ($null -eq $v) { return 0.0 }
  $r = 0.0
  if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$r)) { return $r }
  return 0.0
}

function Parse-QmSdkAssistant($sdk, $e) {
  $ts = QmParseTs (DictVal $e 'timestamp')
  if ($ts) {
    if (-not $sdk.FirstTs -or $ts -lt $sdk.FirstTs) { $sdk.FirstTs = $ts }
    if ($ts -gt $sdk.LastTs) { $sdk.LastTs = $ts }
  }
  if ((DictVal $e 'type') -ne 'assistant') { return }

  $msg = DictVal $e 'message'
  $content = @(DictVal $msg 'content')
  $chars = 0; $cjk = 0; $tools = 0
  foreach ($b in $content) {
    if ($null -eq $b) { continue }
    $bt = DictVal $b 'type'
    $t = ''
    if ($bt -eq 'text') { $t = [string](DictVal $b 'text') }
    elseif ($bt -eq 'thinking') { $t = [string](DictVal $b 'thinking') }
    elseif ($bt -eq 'tool_use') {
      # 不经 PowerShell 管道展开 input，否则 [] / 单元素数组会被丢失形状。
      $value = $null
      if ($b -is [System.Collections.IDictionary]) { $value = $b['input'] }
      elseif ($b.PSObject.Properties['input']) { $value = $b.input }
      $t = try { [QoderMeter.JsonEstimate]::ToolInput($value) } catch { '' }
      if ($null -eq $t) { $t = '' }
      $tools++
    } elseif ($bt -eq 'tool_result') { continue }
    if ($null -eq $t) { $t = '' }
    $chars += $t.Length
    $cjk += $script:QM_CJK.Matches($t).Count
  }
  $est = [QoderMeter.JsonEstimate]::Round($cjk / 1.35 + ($chars - $cjk) / 3.8)
  $usage = DictVal $msg 'usage'
  $exact = [int](NumVal $usage 'output_tokens')

  $sdk.AssistantCount++
  $sdk.ToolCount += $tools
  $sdk.EstOut += $est
  $sdk.ExactOut += $exact
  $sdk.Credits += (NumVal $usage 'credits')
  $sdk.OriginalCredits += (NumVal $usage 'original_credits')
  $sdk.InputTokens += [int]((NumVal $usage 'input_tokens') + (NumVal $usage 'cache_read_input_tokens') + (NumVal $usage 'cache_creation_input_tokens'))

  $rid = DictVal $usage 'request_id'
  if ($rid) {
    if (-not $sdk.RequestIds.ContainsKey($rid)) {
      $sdk.RequestIds[$rid] = $true
      $sdk.RequestCount++
    }
  } elseif ((NumVal $usage 'credits') -or $exact -or (NumVal $usage 'input_tokens')) {
    $sdk.RequestCount++
  }

  if (-not $ts) { return }
  $n = $sdk.Groups.Count
  if ($n -gt 0) {
    $last = $sdk.Groups[$n - 1]
    if ([math]::Abs($last.Ts - $ts) -le 12) {
      $last.Chars += $chars; $last.Est += $est; $last.Exact += $exact
      return
    }
  }
  $sdk.Groups.Add([pscustomobject]@{ Ts = [long]$ts; Chars = $chars; Est = [long]$est; Exact = $exact })
}

function Init-QmSdk($row) {
  $path = Find-QmSdkFile ([string](DictVal $row 'cwd')) ([string](DictVal $row 'session_id'))
  $sdk = New-QmSdk $path
  $script:QM_S.sdk = $sdk
  if (-not $path) { $script:QM_S.sdkRetryAt = (QmNowMs) + 5000; return }
  $blk = Read-QmBlock $path 0
  Parse-QmSdkText $sdk $blk.Text
  $sdk.Offset = [long]$blk.Bytes
}

function Update-QmSdk {
  $sdk = $script:QM_S.sdk
  if (-not $sdk) { return }
  if (-not $sdk.Path) {
    if ((QmNowMs) -lt $script:QM_S.sdkRetryAt -or -not $script:QM_S.sessionId) { return }
    Init-QmSdk ([pscustomobject]@{ session_id = $script:QM_S.sessionId; cwd = $script:QM_S.cwd })
    return
  }
  $size = Get-QmFileSize $sdk.Path
  if ($size -lt 0) { return }
  if ($size -lt $sdk.Offset) {
    Init-QmSdk ([pscustomobject]@{ session_id = $script:QM_S.sessionId; cwd = $script:QM_S.cwd })
    return
  }
  if ($size -eq $sdk.Offset) { return }
  $blk = Read-QmBlock $sdk.Path $sdk.Offset
  if ($blk.Bytes -le 0) { return }
  $sdk.Offset += $blk.Bytes
  Parse-QmSdkText $sdk $blk.Text
}

# ------------------------------------------------------------ segment 事件
$script:QM_SEG_TYPES = @{}
'input.prompt.submitted','turn.started','model.request.started','model.response.completed',
'tool.requested','tool.execution.finished','tool.shell.started','tool.shell.finished' |
  ForEach-Object { $script:QM_SEG_TYPES[$_] = 1 }

function Find-QmSegmentFile([string]$sid) {
  if (-not $sid -or -not (Test-Path $script:QM_SEGROOT)) { return $null }
  $dirs = Get-ChildItem -LiteralPath $script:QM_SEGROOT -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $sid } | Select-Object -First 1
  if (-not $dirs) { return $null }
  $seg = Join-Path $dirs.FullName 'segments'
  if (-not (Test-Path $seg)) { return $null }
  $f = Get-ChildItem -LiteralPath $seg -Filter *.jsonl -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function New-QmSeg([string]$path) {
  return [pscustomobject]@{ Path = $path; Offset = 0L; Tail = ''; Events = (New-Object System.Collections.Generic.List[object]); Parsed = $false }
}

function Parse-QmSegText($seg, [string]$text) {
  if (-not $text) { return }
  $lines = ($seg.Tail + $text) -split "`n"
  $carry = ''
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($null -eq $line -or $line.Length -eq 0) { continue }
    if ($line.IndexOf('"type":"') -lt 0) { continue }
    $o = ConvertFrom-JsonLine $line
    if ($null -eq $o) {
      if ($i -eq $lines.Count - 1) { $carry = $line }
      continue
    }
    $tp = [string](DictVal $o 'type')
    if (-not $script:QM_SEG_TYPES.ContainsKey($tp)) { continue }
    $seg.Events.Add([pscustomobject]@{
      Type = $tp; Ts = [long](QmParseTs (DictVal $o 'ts'))
      TurnId = [string](DictVal $o 'turn_id'); RequestId = [string](DictVal $o 'request_id')
    })
  }
  $seg.Tail = $carry
  if ($seg.Tail.Length -gt 4000000) { $seg.Tail = '' }
  if ($seg.Events.Count -gt 12000) { $seg.Events.RemoveRange(0, $seg.Events.Count - 9000) }
}

function Init-QmSeg {
  $path = Find-QmSegmentFile $script:QM_S.sessionId
  $seg = New-QmSeg $path
  $script:QM_S.seg = $seg
  $script:QM_S.segCheckAt = (QmNowMs) + 10000
  if (-not $path) { return }
  $size = Get-QmFileSize $path
  if ($size -lt 0) { return }
  $start = [Math]::Max(0, $size - 6 * 1024 * 1024)
  $blk = Read-QmBlock $path $start
  $text = $blk.Text
  if ($start -gt 0) {
    $nl = $text.IndexOf("`n")
    $text = if ($nl -ge 0) { $text.Substring($nl + 1) } else { '' }
  }
  $seg.Offset = $start + $blk.Bytes
  $seg.Parsed = $true
  Parse-QmSegText $seg $text
}

function Update-QmSeg {
  $seg = $script:QM_S.seg
  if (-not $seg) { return }
  if ((QmNowMs) -ge $script:QM_S.segCheckAt) {
    $script:QM_S.segCheckAt = (QmNowMs) + 10000
    $path = Find-QmSegmentFile $script:QM_S.sessionId
    if ($path -and $path -ne $seg.Path) { Init-QmSeg; return }
  }
  if (-not $seg.Path) { return }
  $size = Get-QmFileSize $seg.Path
  if ($size -lt 0) { return }
  if ($size -lt $seg.Offset) { Init-QmSeg; return }
  if ($size -eq $seg.Offset) { return }
  $blk = Read-QmBlock $seg.Path $seg.Offset
  if ($blk.Bytes -le 0) { return }
  $seg.Offset += $blk.Bytes
  Parse-QmSegText $seg $blk.Text
}

# ------------------------------------------------------------------ 本轮计算
function Compute-QmTurn {
  $seg = $script:QM_S.seg
  $sdk = $script:QM_S.sdk
  $state = $script:QM_S
  $state.tps = $null; $state.tpsHistory = @(); $state.turnTokens = 0; $state.turnDuration = 0.0
  $state.turnWall = 0.0; $state.turnRequestCount = 0; $state.turnStartedAt = 0L; $state.turnEndedAt = 0L
  $state.lastLatency = $null; $state.inFlight = $false; $state.inFlightElapsed = 0.0
  $state.requestStartedAt = 0L; $state.lastEventAt = 0L
  if (-not $seg -or $seg.Events.Count -eq 0) { return }

  $ev = $seg.Events
  $lastStart = $null
  for ($i = $ev.Count - 1; $i -ge 0; $i--) { if ($ev[$i].Type -eq 'model.request.started') { $lastStart = $ev[$i]; break } }
  $turnId = if ($lastStart) { $lastStart.TurnId } else { $null }
  if (-not $turnId) {
    for ($i = $ev.Count - 1; $i -ge 0; $i--) { if ($ev[$i].Type -eq 'turn.started') { $turnId = $ev[$i].TurnId; break } }
  }
  $state.turnId = $turnId

  # List[object] 不能用 @() 包裹（会走 CopyTo 重载绑定并抛 ArgumentException）
  $pool = $ev.ToArray()
  if ($turnId) { $pool = @($ev | Where-Object { $_.TurnId -eq $turnId }) }
  if ($pool.Count -eq 0) { $pool = @($ev | Select-Object -Last 400) }

  $starts = @{}
  $completions = New-Object System.Collections.Generic.List[object]
  $lastEventAt = 0L
  $now = QmNowMs
  foreach ($e in $pool) {
    $t = $e.Ts
    if ($t -gt $lastEventAt) { $lastEventAt = $t }
    if ($e.Type -eq 'model.request.started' -and $e.RequestId) {
      $starts[$e.RequestId] = [pscustomobject]@{ Ts = $t; Rid = $e.RequestId }
    } elseif ($e.Type -eq 'model.response.completed' -and $e.RequestId -and $starts.ContainsKey($e.RequestId)) {
      $s = $starts[$e.RequestId]
      $dur = ($t - $s.Ts) / 1000.0
      if ($dur -ge 0 -and $dur -lt 900) {
        $completions.Add([pscustomobject]@{ Id = $e.RequestId; Start = $s.Ts; End = $t; Dur = $dur })
      }
    }
  }
  $state.lastEventAt = $lastEventAt

  $awaiting = $null
  foreach ($rid in $starts.Keys) {
    $s = $starts[$rid]
    $found = $false
    foreach ($c in $completions) { if ($c.Id -eq $rid) { $found = $true; break } }
    if (-not $found -and $s.Ts -gt $(if ($awaiting) { $awaiting.Ts } else { 0 })) { $awaiting = $s }
  }
  if ($awaiting -and ($now - $awaiting.Ts) -lt 300000) {
    $state.inFlight = $true
    $state.requestStartedAt = $awaiting.Ts
    $state.inFlightElapsed = [Math]::Max(0, ($now - $awaiting.Ts) / 1000.0)
  }

  $sorted = @($completions | Sort-Object End)
  $state.turnRequestCount = $sorted.Count
  if ($sorted.Count) { $state.lastLatency = $sorted[$sorted.Count - 1].Dur }

  $turnStart = 0L
  foreach ($e in $pool) {
    if ($e.Type -eq 'turn.started' -and -not $turnStart) { $turnStart = $e.Ts }
  }
  if (-not $turnStart -and $sorted.Count) { $turnStart = $sorted[0].Start }
  if (-not $turnStart -and $awaiting) { $turnStart = $awaiting.Ts }
  $state.turnStartedAt = $turnStart
  $recent = ($lastEventAt -and (($now - $lastEventAt) -lt 20000))
  $end = if ($state.inFlight -or $recent) { $now } elseif ($lastEventAt) { $lastEventAt } else { $now }
  $state.turnEndedAt = $end
  $state.turnWall = if ($turnStart) { [Math]::Max(0, ($end - $turnStart) / 1000.0) } else { 0 }

  if (-not $sorted.Count -or -not $sdk -or $sdk.Groups.Count -eq 0) { return }

  $groups = @($sdk.Groups | Where-Object { $_.Ts -ge ($turnStart - 5000) })
  $byCompletion = @{}
  for ($i = 0; $i -lt $groups.Count; $i++) {
    $g = $groups[$i]
    $best = -1; $bestDiff = 1500
    for ($j = 0; $j -lt $sorted.Count; $j++) {
      $diff = [math]::Abs($sorted[$j].End - $g.Ts)
      if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $j }
    }
    if ($best -ge 0) {
      $val = if ($g.Exact -gt 0) { $g.Exact } else { $g.Est }
      $byCompletion[$best] = $(if ($byCompletion.ContainsKey($best)) { $byCompletion[$best] } else { 0 }) + $val
    }
  }

  $tokens = 0L; $duration = 0.0; $history = @()
  for ($i = 0; $i -lt $sorted.Count; $i++) {
    $t = if ($byCompletion.ContainsKey($i)) { $byCompletion[$i] } else { 0 }
    if ($t -gt 0 -and $sorted[$i].Dur -gt 0) {
      $tokens += $t
      $duration += $sorted[$i].Dur
      $history += ($t / $sorted[$i].Dur)
    }
  }
  $state.turnTokens = $tokens
  $state.turnDuration = $duration
  $state.tpsHistory = @($history | Select-Object -Last 14)
  if ($duration -gt 0) { $state.tps = $tokens / $duration }
}

# -------------------------------------------------------------- 状态与刷新
$script:QM_S = [pscustomobject][ordered]@{
  sessionId = $null; title = ''; model = ''; cwd = ''; sessionStartedAt = 0L; promptCount = 0
  credits = 0.0; originalCredits = 0.0; estOut = 0L; exactOut = 0L; inputTokens = 0L
  assistantCount = 0; toolCount = 0; requestCount = 0; creditsPerRequest = 0.0
  tps = $null; tpsHistory = @(); turnTokens = 0L; turnDuration = 0.0; turnWall = 0.0
  turnRequestCount = 0; turnStartedAt = 0L; turnEndedAt = 0L; turnId = $null
  lastLatency = $null; inFlight = $false; inFlightElapsed = 0.0; requestStartedAt = 0L; lastEventAt = 0L
  ctxStats = $null; recent = @(); pinned = $null; activeSessionId = $null; windowBounds = $null
  sdk = $null; seg = $null; sdkRetryAt = 0L; segCheckAt = 0L; error = ''
}

function Sync-QmSdkTotals {
  $sdk = $script:QM_S.sdk
  if (-not $sdk) { return }
  $state = $script:QM_S
  $state.credits = $sdk.Credits; $state.originalCredits = $sdk.OriginalCredits
  $state.estOut = $sdk.EstOut; $state.exactOut = $sdk.ExactOut; $state.inputTokens = $sdk.InputTokens
  $state.assistantCount = $sdk.AssistantCount; $state.toolCount = $sdk.ToolCount; $state.requestCount = $sdk.RequestCount
  if (-not $state.sessionStartedAt -and $sdk.FirstTs) { $state.sessionStartedAt = $sdk.FirstTs }
}

function Switch-QmSession($row) {
  $state = $script:QM_S
  $state.sessionId = [string](DictVal $row 'session_id')
  $state.title = [string](DictVal $row 'title')
  $state.model = [string](DictVal $row 'model')
  $state.cwd = [string](DictVal $row 'cwd')
  $state.sessionStartedAt = [long](NumVal $row 'created_at')
  $state.promptCount = [int](NumVal $row 'prompt_count')
  $state.sdk = $null; $state.seg = $null
  $state.credits = 0.0; $state.estOut = 0; $state.exactOut = 0; $state.inputTokens = 0
  $state.toolCount = 0; $state.requestCount = 0; $state.assistantCount = 0
  Init-QmSdk $row
  Init-QmSeg
  Sync-QmSdkTotals
}

function Refresh-QmData {
  $state = $script:QM_S
  try {
    $payload = Get-QmPayload
    if ($payload) {
      $winTxt = [string]$payload.window
      if ($winTxt -and $winTxt -ne 'null') {
        try { $state.windowBounds = $winTxt | ConvertFrom-Json } catch { }
      }
      $state.recent = @($payload.sessions)
      $activeId = Get-QmActiveSessionId
      $state.activeSessionId = $activeId

      $row = $null
      if ($state.pinned) {
        $row = @($state.recent | Where-Object { $_.session_id -eq $state.pinned }) | Select-Object -First 1
        if (-not $row) {
          $row = Get-QmSessionRow $state.pinned
          if ($row) { $state.recent = @(@($row) + $state.recent) }
          else { $state.pinned = $null }
        }
      }
      if (-not $row -and $activeId) {
        $row = @($state.recent | Where-Object { $_.session_id -eq $activeId }) | Select-Object -First 1
        if (-not $row) {
          $r2 = Get-QmSessionRow $activeId
          if ($r2) { $row = $r2; $state.recent = @(@($r2) + $state.recent) }
        }
      }
      if (-not $row) { $row = @($state.recent | Select-Object -First 1) }
      if ($row -is [array]) { $row = $row[0] }

      if ($row) {
        if (([string](DictVal $row 'session_id')) -ne $state.sessionId) {
          Switch-QmSession $row
        } else {
          $state.title = [string](DictVal $row 'title')
          $state.model = [string](DictVal $row 'model')
          $state.cwd = [string](DictVal $row 'cwd')
          $state.sessionStartedAt = [long](NumVal $row 'created_at')
          $state.promptCount = [int](NumVal $row 'prompt_count')
        }
        $ctxTxt = [string](DictVal $row 'ctx_json')
        if ($ctxTxt) {
          try {
            $c = $ctxTxt | ConvertFrom-Json
            $state.ctxStats = $c.sessionStats
          } catch { $state.ctxStats = $null }
        } else { $state.ctxStats = $null }
      } else {
        $state.sessionId = $null; $state.title = ''; $state.model = ''; $state.cwd = ''
        $state.sdk = $null; $state.seg = $null; $state.ctxStats = $null
        $state.credits = 0; $state.estOut = 0; $state.exactOut = 0; $state.toolCount = 0
        $state.requestCount = 0; $state.promptCount = 0; $state.sessionStartedAt = 0; $state.turnWall = 0
      }
    }

    if ($state.sessionId) {
      Update-QmSdk
      Update-QmSeg
      Sync-QmSdkTotals
      Compute-QmTurn
    }
    $state.error = ''
  } catch {
    $frames = @($_.ScriptStackTrace -split "`r?`n" | Where-Object { $_ })
    $at = ''
    if ($frames.Count -gt 1) { $at = ($frames[1] -replace '^.*\(', '') -replace '\)$', '' }
    $state.error = $_.Exception.Message + ' @ ' + $at
    Write-QmLog ('refreshData: ' + $state.error)
  }
}

function Write-QmLog([string]$msg) {
  try {
    if (-not (Test-Path $script:QM_SETTINGSD)) { New-Item -ItemType Directory -Path $script:QM_SETTINGSD -Force | Out-Null }
    $p = Join-Path $script:QM_SETTINGSD 'meter.log'
    if ((Get-QmFileSize $p) -gt 512000) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::AppendAllText($p, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $msg + "`r`n")
  } catch { }
}

# ------------------------------------------------------------------- 格式化
function Format-QmK($n) {
  if (-not $n -or $n -le 0) { return '—' }
  if ($n -ge 1000000) { return [QoderMeter.JsonEstimate]::Fixed($n / 1000000, 2) + 'm' }
  if ($n -ge 1000) { return [QoderMeter.JsonEstimate]::Fixed($n / 1000, 1) + 'k' }
  return ([QoderMeter.JsonEstimate]::Round($n)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-QmCount($n) {
  if ($null -eq $n -or $n -le 0) { return '0' }
  if ($n -ge 1000000) { return [QoderMeter.JsonEstimate]::Fixed($n / 1000000, 1) + 'm' }
  if ($n -ge 1000) { return [QoderMeter.JsonEstimate]::Fixed($n / 1000, 1) + 'k' }
  return ([QoderMeter.JsonEstimate]::Round($n)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-QmDuration($sec) {
  if ($null -eq $sec -or $sec -lt 0) { return '—' }
  if ($sec -lt 60) { return ([int][QoderMeter.JsonEstimate]::Round($sec)).ToString() + 's' }
  if ($sec -lt 3600) {
    $m = [int][math]::Floor($sec / 60)
    $s = [int][QoderMeter.JsonEstimate]::Round($sec % 60)
    $pad = if ($s -lt 10) { '0' } else { '' }
    return ('' + $m) + 'm ' + $pad + ('' + $s) + 's'
  }
  $h = [int][math]::Floor($sec / 3600)
  $m = [int][QoderMeter.JsonEstimate]::Round(($sec % 3600) / 60)
  $pad = if ($m -lt 10) { '0' } else { '' }
  return ('' + $h) + 'h ' + $pad + ('' + $m) + 'm'
}

function Format-QmElapsed($sec) {
  if ($null -eq $sec -or $sec -le 0) { return '' }
  if ($sec -lt 10) { return [QoderMeter.JsonEstimate]::Fixed($sec, 1) + 's' }
  if ($sec -lt 60) { return ([QoderMeter.JsonEstimate]::Round($sec)).ToString() + 's' }
  return Format-QmDuration $sec
}

function Format-QmTps($v) {
  if ($null -eq $v -or $v -le 0) { return '—' }
  if ($v -ge 100) { return ([QoderMeter.JsonEstimate]::Round($v)).ToString() }
  return [QoderMeter.JsonEstimate]::Fixed($v, 1)
}

function Format-QmCredits($v) {
  if ($null -eq $v -or $v -le 0) { return '0.00' }
  if ($v -ge 100) { return [QoderMeter.JsonEstimate]::Fixed($v, 0) }
  return [QoderMeter.JsonEstimate]::Fixed($v, 2)
}

function Cut-QmText([string]$s, [int]$n) {
  $s = ('' + $s) -replace '\s+', ' '
  $s = $s.Trim()
  if ($s.Length -le $n) { return $s }
  return $s.Substring(0, $n - 1) + '…'
}
