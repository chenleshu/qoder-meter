/*
 * Qoder Meter
 * A local, read-only status bar for Qoder.
 *
 * Data sources:
 *   - ~/Library/Application Support/com.qoder.app.stable/main.sqlite
 *   - ~/.qoder/projects/.../<session>.jsonl
 *   - ~/.qoder/logs/sessions/.../<session>/segments/*.jsonl
 *
 * It never writes to Qoder data and never touches the network.
 */

ObjC.import('Cocoa');

const CA = Application.currentApplication();
CA.includeStandardAdditions = true;

const HOME = $.NSHomeDirectory().js;
const DB_PATH = HOME + '/Library/Application Support/com.qoder.app.stable/main.sqlite';
const PROJECTS_ROOT = HOME + '/.qoder/projects';
const SESSIONS_ROOT = HOME + '/.qoder/logs/sessions';
const LOCAL_STORAGE_DIR = HOME + '/Library/Application Support/com.qoder.app.stable/Local Storage/leveldb';
const SETTINGS_DIR = HOME + '/Library/Application Support/QoderMeter';
const SETTINGS_PATH = SETTINGS_DIR + '/settings.json';
const LOG_PATH = HOME + '/Library/Logs/QoderMeter.log';
const OLD_LOGIN_PLIST = HOME + '/Library/LaunchAgents/com.qoder.meter.plist';
const WATCH_PLIST = HOME + '/Library/LaunchAgents/com.qoder.meter.watch.plist';
const WATCH_SCRIPT = SETTINGS_DIR + '/watch.sh';
const WATCH_LOG = SETTINGS_DIR + '/watch.log';
const PAUSE_FLAG = SETTINGS_DIR + '/autostart-paused';
const KEEP_FLAG = SETTINGS_DIR + '/keep-running';

const BAR_H_TITLE = 26;
const BAR_H_BOTTOM = 30;
const CARD_W = 232;
const CARD_H = 210;
const POLL_SECONDS = 0.6;

const CJK_RE = /[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/g;

const col = function (r, g, b, a) {
  return $.NSColor.colorWithCalibratedRedGreenBlueAlpha(r, g, b, a);
};
const wht = function (w, a) {
  return $.NSColor.colorWithCalibratedWhiteAlpha(w, a);
};

const PALETTE_DARK = {
  bg: col(0.075, 0.085, 0.112, 0.97),
  border: wht(1, 0.10),
  text: wht(0.96, 1),
  soft: wht(0.74, 1),
  gray: wht(0.56, 1),
  faint: wht(0.38, 1),
  green: col(0.32, 0.88, 0.58, 1),
  greenDim: col(0.40, 0.74, 0.56, 1),
  gold: col(0.95, 0.76, 0.36, 1),
  red: col(0.96, 0.42, 0.38, 1),
  blue: col(0.46, 0.68, 1, 1),
  track: wht(1, 0.13),
  divider: wht(1, 0.07)
};

const PALETTE_LIGHT = {
  bg: col(1, 1, 1, 0.97),
  border: col(0.85, 0.87, 0.90, 1),
  text: col(0.10, 0.12, 0.15, 1),
  soft: col(0.32, 0.36, 0.42, 1),
  gray: col(0.44, 0.48, 0.54, 1),
  faint: col(0.56, 0.60, 0.66, 1),
  green: col(0.03, 0.58, 0.40, 1),
  greenDim: col(0.16, 0.55, 0.44, 1),
  gold: col(0.66, 0.42, 0.08, 1),
  red: col(0.84, 0.16, 0.16, 1),
  blue: col(0.14, 0.38, 0.90, 1),
  track: col(0.90, 0.92, 0.95, 1),
  divider: col(0.90, 0.92, 0.95, 1)
};

let T = PALETTE_LIGHT;

const state = {
  sessionId: null,
  title: '',
  model: '',
  cwd: '',
  ctxStats: null,
  layout: 'sidebar',
  theme: 'light',
  positions: {},
  widths: { title: 800, bottom: 800 },
  bottomAutoHide: true,
  bottomRevealed: false,
  bottomOutside: false,
  bottomHoverAt: 0,
  recent: [],
  pinned: null,
  activeSessionId: null,
  routeCache: { path: '', size: -1, id: null },
  panelHidden: false,
  autoStart: false,
  closeWithQoder: true,
  qoderRunning: false,
  windowBounds: null,
  sdk: null,
  seg: null,
  turnId: null,
  tps: null,
  tpsHistory: [],
  turnTokens: 0,
  turnDuration: 0,
  turnWall: 0,
  turnRequestCount: 0,
  lastLatency: null,
  inFlight: false,
  inFlightElapsed: 0,
  requestStartedAt: 0,
  lastEventAt: 0,
  credits: 0,
  originalCredits: 0,
  estOut: 0,
  exactOut: 0,
  inputTokens: 0,
  assistantCount: 0,
  toolCount: 0,
  requestCount: 0,
  promptCount: 0,
  sessionStartedAt: 0,
  sessionAge: 0,
  turnStartedAt: 0,
  turnEndedAt: 0,
  creditsPerRequest: 0,
  lastQoderFrontAt: 0,
  uiReady: false,
  dragging: false,
  lastX: null,
  lastY: null,
  lastVisible: null,
  menuSig: '',
  lastError: '',
  segCheckAt: 0,
  sdkRetryAt: 0,
  lastTooltip: ''
};

let app = null;
let panel = null;
let bgBox = null;
let titleLabel = null;
let modelLabel = null;
let dotBox = null;
let tpsValue = null;
let turnValue = null;
let sessionAgeValue = null;
let outValue = null;
let creditsValue = null;
let requestValue = null;
let toolValue = null;
let latencyValue = null;
let stateLabel = null;
let sparkBars = [];
let dragView = null;
let metricsLabel = null;
let indicatorPanel = null;
let statusItem = null;
let controller = null;
let dragStartMouse = null;
let dragStartOrigin = null;
let settingsPanel = null;
let settingsAutoStart = null;
let settingsClose = null;
let settingsFollow = null;
let settingsPosPopup = null;
let settingsWidthPopup = null;
let settingsThemePopup = null;
let settingsBottomAutoHide = null;

/* ---------------------------------------------------------------- utils */

function q(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function sh(cmd) {
  try {
    return CA.doShellScript(cmd);
  } catch (e) {
    return '';
  }
}

function log(msg) {
  try {
    if (fileSize(LOG_PATH) > 2 * 1024 * 1024) {
      sh('/usr/bin/printf "" > ' + q(LOG_PATH));
    }
    const line = new Date().toISOString() + ' ' + msg;
    sh('/usr/bin/printf ' + q('%s\n') + ' ' + q(line) + ' >> ' + q(LOG_PATH));
  } catch (e) {
    // Logging must never take the UI down.
  }
}

function logError(where, e) {
  const text = where + ': ' + String((e && e.message) ? e.message : e);
  if (text !== state.lastError) {
    state.lastError = text;
    log(text);
  }
}

function fileSize(path) {
  try {
    const attrs = $.NSFileManager.defaultManager.attributesOfItemAtPathError(path, null);
    if (!attrs || attrs.isNil()) return -1;
    return Number(attrs.objectForKey($.NSFileSize).doubleValue);
  } catch (e) {
    return -1;
  }
}

function readString(path) {
  try {
    const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    if (!s || s.isNil()) return null;
    return s.js;
  } catch (e) {
    return null;
  }
}

function readBlock(path, offset) {
  try {
    const fh = $.NSFileHandle.fileHandleForReadingAtPath(path);
    if (!fh || fh.isNil()) return { text: '', bytes: 0 };
    fh.seekToFileOffset(offset);
    const data = fh.readDataToEndOfFile;
    if (!data || data.isNil()) {
      fh.closeFile;
      return { text: '', bytes: 0 };
    }
    const bytes = Number(data.length);
    const s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    fh.closeFile;
    return { text: (s && !s.isNil()) ? s.js : '', bytes: bytes };
  } catch (e) {
    return { text: '', bytes: 0 };
  }
}

function fmtK(n) {
  if (!n || n <= 0) return '—';
  if (n >= 1000000) return (n / 1000000).toFixed(2) + 'm';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}

function fmtCount(n) {
  if (!isFinite(n) || n <= 0) return '0';
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'm';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}

function fmtDuration(sec) {
  if (!isFinite(sec) || sec < 0) return '—';
  if (sec < 60) return Math.round(sec) + 's';
  if (sec < 3600) {
    const m = Math.floor(sec / 60);
    const s = Math.round(sec % 60);
    return m + 'm ' + (s < 10 ? '0' : '') + s + 's';
  }
  const h = Math.floor(sec / 3600);
  const m = Math.round((sec % 3600) / 60);
  return h + 'h ' + (m < 10 ? '0' : '') + m + 'm';
}

function fmtElapsed(sec) {
  if (!isFinite(sec) || sec <= 0) return '';
  if (sec < 10) return sec.toFixed(1) + 's';
  if (sec < 60) return Math.round(sec) + 's';
  return fmtDuration(sec);
}

function fmtTps(v) {
  if (v === null || v === undefined || !isFinite(v) || v <= 0) return '—';
  return v >= 100 ? String(Math.round(v)) : v.toFixed(1);
}

function fmtCredits(v) {
  if (!isFinite(v) || v <= 0) return '0.00';
  if (v >= 100) return v.toFixed(0);
  return v.toFixed(2);
}

function truncate(s, n) {
  s = String(s || '').replace(/\s+/g, ' ').trim();
  if (s.length <= n) return s;
  return s.slice(0, n - 1) + '…';
}

function pathJoin() {
  const parts = [];
  for (let i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
  return parts.join('/').replace(/\/+/g, '/');
}

/* ------------------------------------------------------------ persistence */

function loadSettings() {
  try {
    const text = readString(SETTINGS_PATH);
    if (!text) return;
    const obj = JSON.parse(text);
    if (obj && typeof obj === 'object') {
      state.pinned = obj.pinned || null;
      state.panelHidden = !!obj.panelHidden;
      let layout = obj.layout;
      if (layout === 'above') layout = 'title';
      if (layout === 'below') layout = 'bottom';
      if (layout === 'sidebar' || layout === 'title' || layout === 'bottom') {
        state.layout = layout;
      }
      if (obj.theme === 'light' || obj.theme === 'dark') {
        state.theme = obj.theme;
      }
      if (obj.positions && typeof obj.positions === 'object') {
        state.positions = obj.positions;
      }
      if (obj.widths && typeof obj.widths === 'object') {
        if (isFinite(obj.widths.title)) state.widths.title = Math.max(560, Math.min(1200, Number(obj.widths.title)));
        if (isFinite(obj.widths.bottom)) state.widths.bottom = Math.max(560, Math.min(1200, Number(obj.widths.bottom)));
      }
      if (typeof obj.bottomAutoHide === 'boolean') {
        state.bottomAutoHide = obj.bottomAutoHide;
      }
    }
    const fm = $.NSFileManager.defaultManager;
    state.autoStart = !!fm.fileExistsAtPath(WATCH_PLIST);
    state.closeWithQoder = !fm.fileExistsAtPath(KEEP_FLAG);
  } catch (e) {
    logError('loadSettings', e);
  }
}

function saveSettings() {
  try {
    sh('/bin/mkdir -p ' + q(SETTINGS_DIR));
    const obj = {
      pinned: state.pinned || null,
      panelHidden: !!state.panelHidden,
      layout: state.layout,
      theme: state.theme,
      positions: state.positions,
      widths: state.widths,
      bottomAutoHide: state.bottomAutoHide
    };
    const s = $.NSString.alloc.initWithString(JSON.stringify(obj, null, 2));
    s.writeToFileAtomicallyEncodingError(SETTINGS_PATH, true, $.NSUTF8StringEncoding, null);
  } catch (e) {
    logError('saveSettings', e);
  }
}

/* --------------------------------------------------------------- db query */

const PAYLOAD_SQL = `
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
`;

function queryPayload() {
  const cmd = '/usr/bin/sqlite3 -json -readonly -cmd ' + q('.timeout 600') + ' ' + q(DB_PATH) +
    " <<'QODER_METER_SQL'\n" + PAYLOAD_SQL + "\nQODER_METER_SQL";
  const out = sh(cmd).trim();
  if (!out) return null;
  const rows = JSON.parse(out);
  if (!rows || !rows.length || !rows[0].payload) return null;
  return JSON.parse(rows[0].payload);
}

function scanRouteFile(path) {
  try {
    const data = $.NSData.dataWithContentsOfFile(path);
    if (!data || data.isNil()) return null;
    const s = $.NSString.alloc.initWithDataEncoding(data, $.NSISOLatin1StringEncoding);
    if (!s || s.isNil()) return null;
    const text = s.js;
    const re = /qoder\.workbench\.navigation\.lastRoute\.v1[\s\S]{0,300}?#\/(?:chat|A)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/g;
    let m;
    let last = null;
    while ((m = re.exec(text))) last = m[1];
    return last;
  } catch (e) {
    return null;
  }
}

function readActiveSessionId() {
  try {
    const newest = sh('/bin/ls -t ' + q(LOCAL_STORAGE_DIR) +
      '/*.log 2>/dev/null | /usr/bin/head -n 3').trim();
    const logs = newest ? newest.split('\n') : [];
    for (let i = 0; i < logs.length; i++) {
      const f = logs[i];
      if (!f) continue;
      const size = fileSize(f);
      if (state.routeCache.path === f && state.routeCache.size === size) {
        return state.routeCache.id;
      }
      const id = scanRouteFile(f);
      if (id) {
        state.routeCache = { path: f, size: size, id: id };
        return id;
      }
    }

    const all = sh('/bin/ls -t ' + q(LOCAL_STORAGE_DIR) +
      '/* 2>/dev/null | /usr/bin/head -n 8').trim();
    const files = all ? all.split('\n') : [];
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      if (!f || logs.indexOf(f) >= 0) continue;
      const id = scanRouteFile(f);
      if (id) {
        state.routeCache = { path: f, size: fileSize(f), id: id };
        return id;
      }
    }
    return null;
  } catch (e) {
    logError('readActiveSessionId', e);
    return null;
  }
}

function querySessionRow(sid) {
  if (!/^[0-9a-f-]{36}$/i.test(sid)) return null;
  const sql = `
select s.session_id, s.title, s.model, s.cwd, s.created_at, s.updated_at,
  (select max(created_at) from chat_session_messages m
     where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as last_user_at,
  (select count(*) from chat_session_messages m
     where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as prompt_count,
  coalesce(u.snapshot_json,'') as ctx_json
from chat_sessions s
left join chat_session_context_usage u on u.session_id=s.session_id
where s.session_id='${sid}' and s.archived=0 and s.deleted_at is null
limit 1;
`;
  const cmd = '/usr/bin/sqlite3 -json -readonly -cmd ' + q('.timeout 600') + ' ' + q(DB_PATH) +
    " <<'QODER_METER_SESSION'\n" + sql + "\nQODER_METER_SESSION";
  const out = sh(cmd).trim();
  if (!out) return null;
  const rows = JSON.parse(out);
  return rows && rows.length ? rows[0] : null;
}

/* ------------------------------------------------------------ file caches */

function findSdkFile(row) {
  const cwd = String(row.cwd || '').replace(/\/+$/, '');
  const encoded = cwd.replace(/\//g, '-');
  const guess = pathJoin(PROJECTS_ROOT, encoded, row.session_id + '.jsonl');
  if (fileSize(guess) >= 0) return guess;
  const found = sh('/usr/bin/find ' + q(PROJECTS_ROOT) + ' -maxdepth 2 -type f -name ' +
    q(row.session_id + '.jsonl') + ' -print -quit').trim();
  return found || null;
}

function findSegmentFile(sessionId) {
  const dir = sh('/usr/bin/find ' + q(SESSIONS_ROOT) + ' -maxdepth 3 -type d -name ' +
    q(sessionId) + ' -print -quit').trim();
  if (!dir) return null;
  const newest = sh('/bin/ls -t ' + q(dir + '/segments') +
    '/*.jsonl 2>/dev/null | /usr/bin/head -n 1').trim();
  return newest || null;
}

function emptySdk(path) {
  return {
    path: path || null,
    offset: 0,
    tail: '',
    groups: [],
    credits: 0,
    originalCredits: 0,
    estOut: 0,
    exactOut: 0,
    inputTokens: 0,
    assistantCount: 0,
    toolCount: 0,
    requestCount: 0,
    requestIds: {},
    firstTs: 0,
    lastTs: 0
  };
}

function parseSdkText(sdk, text) {
  if (!text) return;
  const combined = sdk.tail + text;
  const lines = combined.split('\n');
  const complete = [];
  let carry = '';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === lines.length - 1) {
      if (line) {
        // A final line without a newline can still be a complete JSON object.
        try {
          JSON.parse(line);
          complete.push(line);
        } catch (e) {
          carry = line;
        }
      }
    } else if (line) {
      complete.push(line);
    }
  }
  sdk.tail = carry;
  for (let i = 0; i < complete.length; i++) {
    let e;
    try { e = JSON.parse(complete[i]); } catch (err) { continue; }
    if (!e) continue;
    const et = Date.parse(e.timestamp) || 0;
    if (et) {
      if (!sdk.firstTs || et < sdk.firstTs) sdk.firstTs = et;
      if (et > sdk.lastTs) sdk.lastTs = et;
    }
    if (e.type === 'assistant') parseSdkAssistant(sdk, e);
  }
  if (sdk.groups.length > 1200) {
    sdk.groups.splice(0, sdk.groups.length - 900);
  }
}

function parseSdkAssistant(sdk, e) {
  const msg = e.message || {};
  const content = Array.isArray(msg.content) ? msg.content : [];
  let chars = 0;
  let cjk = 0;
  let tools = 0;
  for (let i = 0; i < content.length; i++) {
    const b = content[i] || {};
    let t = '';
    if (b.type === 'text') t = b.text || '';
    else if (b.type === 'thinking') t = b.thinking || '';
    else if (b.type === 'tool_use') {
      try { t = JSON.stringify(b.input || {}); } catch (err) { t = ''; }
      tools++;
    } else if (b.type === 'tool_result') {
      continue;
    }
    chars += t.length;
    const m = t.match(CJK_RE);
    if (m) cjk += m.length;
  }
  const est = Math.round(cjk / 1.35 + (chars - cjk) / 3.8);
  const usage = msg.usage || {};
  const exact = Number(usage.output_tokens) || 0;
  const ts = Date.parse(e.timestamp) || 0;

  sdk.assistantCount++;
  sdk.toolCount += tools;
  sdk.estOut += est;
  sdk.exactOut += exact;
  sdk.credits += Number(usage.credits) || 0;
  sdk.originalCredits += Number(usage.original_credits) || 0;
  sdk.inputTokens += (Number(usage.input_tokens) || 0) +
    (Number(usage.cache_read_input_tokens) || 0) +
    (Number(usage.cache_creation_input_tokens) || 0);

  if (usage.request_id) {
    if (!sdk.requestIds[usage.request_id]) {
      sdk.requestIds[usage.request_id] = true;
      sdk.requestCount++;
    }
  } else if (usage.credits || usage.output_tokens || usage.input_tokens) {
    sdk.requestCount++;
  }

  if (!ts) return;
  const last = sdk.groups.length ? sdk.groups[sdk.groups.length - 1] : null;
  if (last && Math.abs(last.ts - ts) <= 12) {
    last.chars += chars;
    last.est += est;
    last.exact += exact;
  } else {
    sdk.groups.push({ ts: ts, chars: chars, est: est, exact: exact });
  }
}

function initSdk(row) {
  const path = findSdkFile(row);
  const sdk = emptySdk(path);
  state.sdk = sdk;
  if (!path) {
    state.sdkRetryAt = Date.now() + 5000;
    return;
  }
  const text = readString(path);
  if (text) parseSdkText(sdk, text);
  sdk.offset = fileSize(path);
  if (sdk.offset < 0) sdk.offset = 0;
}

function updateSdk() {
  const sdk = state.sdk;
  if (!sdk) return;
  if (!sdk.path) {
    if (Date.now() < state.sdkRetryAt || !state.sessionId) return;
    const row = { session_id: state.sessionId, cwd: state.cwd };
    initSdk(row);
    return;
  }
  const size = fileSize(sdk.path);
  if (size < 0) return;
  if (size < sdk.offset) {
    const row = { session_id: state.sessionId, cwd: state.cwd };
    initSdk(row);
    return;
  }
  if (size === sdk.offset) return;
  const block = readBlock(sdk.path, sdk.offset);
  if (!block.bytes) return;
  sdk.offset += block.bytes;
  parseSdkText(sdk, block.text);
}

function emptySeg(path) {
  return { path: path || null, offset: 0, tail: '', events: [], parsed: false };
}

const SEG_TYPES = {
  'turn.started': 1,
  'input.prompt.submitted': 1,
  'model.request.started': 1,
  'model.response.completed': 1,
  'tool.requested': 1,
  'tool.execution.finished': 1,
  'tool.shell.started': 1,
  'tool.shell.finished': 1
};

function parseSegText(seg, text) {
  if (!text) return;
  const combined = seg.tail + text;
  const lines = combined.split('\n');
  const complete = [];
  let carry = '';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === lines.length - 1) {
      if (line) {
        try {
          JSON.parse(line);
          complete.push(line);
        } catch (e) {
          carry = line;
        }
      }
    } else if (line) {
      complete.push(line);
    }
  }
  seg.tail = carry;
  for (let i = 0; i < complete.length; i++) {
    let e;
    try { e = JSON.parse(complete[i]); } catch (err) { continue; }
    if (!e || !SEG_TYPES[e.type]) continue;
    seg.events.push({
      type: e.type,
      ts: e.ts,
      turn_id: e.turn_id || null,
      request_id: e.request_id || null,
      data: e.data || null
    });
  }
  if (seg.events.length > 12000) {
    seg.events.splice(0, seg.events.length - 9000);
  }
}

function initSeg() {
  const path = findSegmentFile(state.sessionId);
  const seg = emptySeg(path);
  state.seg = seg;
  state.segCheckAt = Date.now() + 10000;
  if (!path) return;
  const size = fileSize(path);
  if (size < 0) return;
  const start = Math.max(0, size - 6 * 1024 * 1024);
  const block = readBlock(path, start);
  let text = block.text;
  if (start > 0) {
    const nl = text.indexOf('\n');
    text = nl >= 0 ? text.slice(nl + 1) : '';
  }
  seg.offset = start + block.bytes;
  seg.parsed = true;
  parseSegText(seg, text);
}

function updateSeg() {
  let seg = state.seg;
  if (!seg) return;
  if (Date.now() >= state.segCheckAt) {
    state.segCheckAt = Date.now() + 10000;
    const path = findSegmentFile(state.sessionId);
    if (path && path !== seg.path) {
      initSeg();
      return;
    }
  }
  if (!seg.path) return;
  const size = fileSize(seg.path);
  if (size < 0) return;
  if (size < seg.offset) {
    initSeg();
    return;
  }
  if (size === seg.offset) return;
  const block = readBlock(seg.path, seg.offset);
  if (!block.bytes) return;
  seg.offset += block.bytes;
  parseSegText(seg, block.text);
}

/* ------------------------------------------------------------- turn maths */

function computeTurn() {
  const seg = state.seg;
  const sdk = state.sdk;
  state.tps = null;
  state.tpsHistory = [];
  state.turnTokens = 0;
  state.turnDuration = 0;
  state.turnWall = 0;
  state.turnRequestCount = 0;
  state.turnStartedAt = 0;
  state.turnEndedAt = 0;
  state.lastLatency = null;
  state.inFlight = false;
  state.inFlightElapsed = 0;
  state.requestStartedAt = 0;
  state.lastEventAt = 0;

  if (!seg || !seg.events.length) return;

  const ev = seg.events;
  let lastStart = null;
  for (let i = ev.length - 1; i >= 0; i--) {
    if (ev[i].type === 'model.request.started') { lastStart = ev[i]; break; }
  }
  let turnId = lastStart ? lastStart.turn_id : null;
  if (!turnId) {
    for (let i = ev.length - 1; i >= 0; i--) {
      if (ev[i].type === 'turn.started') { turnId = ev[i].turn_id; break; }
    }
  }
  state.turnId = turnId || null;

  let pool = ev;
  if (turnId) {
    pool = ev.filter(function (e) { return e.turn_id === turnId; });
  }
  if (!pool.length) pool = ev.slice(-400);

  const starts = {};
  const completions = [];
  let lastEventAt = 0;
  for (let i = 0; i < pool.length; i++) {
    const e = pool[i];
    const t = Date.parse(e.ts) || 0;
    if (t > lastEventAt) lastEventAt = t;
    if (e.type === 'model.request.started' && e.request_id) {
      starts[e.request_id] = { ts: t, rid: e.request_id };
    } else if (e.type === 'model.response.completed' && e.request_id && starts[e.request_id]) {
      const s = starts[e.request_id];
      const dur = (t - s.ts) / 1000;
      if (dur >= 0 && dur < 900) {
        completions.push({ id: e.request_id, start: s.ts, end: t, dur: dur });
      }
    }
  }
  state.lastEventAt = lastEventAt;

  let awaiting = null;
  for (const rid in starts) {
    let found = false;
    for (let i = 0; i < completions.length; i++) {
      if (completions[i].id === rid) { found = true; break; }
    }
    if (!found && starts[rid].ts > (awaiting ? awaiting.ts : 0)) awaiting = starts[rid];
  }
  if (awaiting && Date.now() - awaiting.ts < 5 * 60 * 1000) {
    state.inFlight = true;
    state.requestStartedAt = awaiting.ts;
    state.inFlightElapsed = Math.max(0, (Date.now() - awaiting.ts) / 1000);
  }

  completions.sort(function (a, b) { return a.end - b.end; });
  state.turnRequestCount = completions.length;
  if (completions.length) {
    state.lastLatency = completions[completions.length - 1].dur;
  }

  let turnStart = 0;
  for (let i = 0; i < pool.length; i++) {
    const e = pool[i];
    if (e.type === 'turn.started' && !turnStart) {
      turnStart = Date.parse(e.ts) || 0;
    }
  }
  if (!turnStart && completions.length) turnStart = completions[0].start;
  if (!turnStart && awaiting) turnStart = awaiting.ts;
  state.turnStartedAt = turnStart;
  const recent = !!(lastEventAt && (Date.now() - lastEventAt < 20000));
  const end = (state.inFlight || recent) ? Date.now() : (lastEventAt || Date.now());
  state.turnEndedAt = end;
  state.turnWall = turnStart ? Math.max(0, (end - turnStart) / 1000) : 0;

  if (!completions.length || !sdk || !sdk.groups.length) return;

  // Assign each assistant-content group to the closest completed model request.
  const groups = sdk.groups.filter(function (g) { return g.ts >= turnStart - 5000; });
  const byCompletion = {};
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    let best = -1;
    let bestDiff = 1500;
    for (let j = 0; j < completions.length; j++) {
      const diff = Math.abs(completions[j].end - g.ts);
      if (diff < bestDiff) { bestDiff = diff; best = j; }
    }
    if (best >= 0) {
      byCompletion[best] = (byCompletion[best] || 0) + (g.exact > 0 ? g.exact : g.est);
    }
  }

  let tokens = 0;
  let duration = 0;
  const history = [];
  for (let i = 0; i < completions.length; i++) {
    const t = byCompletion[i] || 0;
    if (t > 0 && completions[i].dur > 0) {
      tokens += t;
      duration += completions[i].dur;
      history.push(t / completions[i].dur);
    }
  }
  state.turnTokens = tokens;
  state.turnDuration = duration;
  state.tpsHistory = history.slice(-14);
  if (duration > 0) state.tps = tokens / duration;
}

/* -------------------------------------------------------------- UI pieces */

function label(str, frame, size, color, weight, align, truncateTail) {
  const f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  f.setStringValue(str);
  f.setBezeled(false);
  f.setDrawsBackground(false);
  f.setEditable(false);
  f.setSelectable(false);
  f.setAlignment(align || 0);
  f.setFont($.NSFont.monospacedDigitSystemFontOfSizeWeight(size || 11,
    weight === undefined ? $.NSFontWeightRegular : weight));
  f.setTextColor(color);
  if (truncateTail) f.setLineBreakMode($.NSLineBreakByTruncatingTail);
  return f;
}

function box(frame, fill, radius, borderWidth, borderColor) {
  const b = $.NSBox.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  b.setBoxType(4); // NSBoxCustom
  b.setBorderType(borderWidth ? 1 : 0);
  b.setBorderWidth(borderWidth || 0);
  b.setCornerRadius(radius || 0);
  b.setTitlePosition(0);
  b.setTransparent(false);
  b.setFillColor(fill);
  if (borderColor) b.setBorderColor(borderColor);
  return b;
}

function resetUI() {
  bgBox = null;
  titleLabel = null;
  modelLabel = null;
  dotBox = null;
  tpsValue = null;
  turnValue = null;
  sessionAgeValue = null;
  outValue = null;
  creditsValue = null;
  requestValue = null;
  toolValue = null;
  latencyValue = null;
  stateLabel = null;
  sparkBars = [];
  dragView = null;
  metricsLabel = null;
}

function makePanel(w, h) {
  panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, w, h),
    128, // borderless + nonactivating
    $.NSBackingStoreBuffered,
    false
  );
  panel.setLevel($.NSStatusWindowLevel);
  panel.setCollectionBehavior(1 | 256 | 16);
  panel.setOpaque(false);
  panel.setBackgroundColor($.NSColor.clearColor);
  panel.setHasShadow(true);
  panel.setHidesOnDeactivate(false);
  panel.setFloatingPanel(true);
  panel.setBecomesKeyOnlyIfNeeded(true);
  return panel.contentView;
}

function buildSidebar(root) {
  const W = CARD_W;
  const H = CARD_H;

  dotBox = box([14, H - 22, 7, 7], T.gray, 3.5, 0, null);
  root.addSubview(dotBox);

  modelLabel = label('会话统计', [25, H - 28, 100, 14], 8.5, T.faint, $.NSFontWeightMedium, 0, true);
  root.addSubview(modelLabel);

  stateLabel = label('', [W - 98, H - 28, 84, 14], 9, T.faint, $.NSFontWeightMedium, 2);
  root.addSubview(stateLabel);

  titleLabel = label('', [14, H - 52, W - 28, 20], 12.5, T.text, $.NSFontWeightSemibold, 0, true);
  root.addSubview(titleLabel);

  root.addSubview(label('本轮 TPS', [14, H - 72, 80, 12], 8.5, T.faint, $.NSFontWeightRegular));
  tpsValue = label('—', [13, H - 108, 100, 36], 28, T.green, $.NSFontWeightSemibold);
  root.addSubview(tpsValue);
  root.addSubview(label('tok/s', [76, H - 100, 38, 12], 8.5, T.faint, $.NSFontWeightRegular));

  root.addSubview(box([122, H - 116, 96, 1], T.divider, 0, 0, null));
  sparkBars = [];
  for (let i = 0; i < 14; i++) {
    const b = box([124 + i * 6.8, H - 114, 4, 1], T.track, 2, 0, null);
    root.addSubview(b);
    sparkBars.push(b);
  }

  root.addSubview(box([14, H - 124, W - 28, 1], T.divider, 0, 0, null));

  root.addSubview(label('本轮', [14, H - 142, 80, 11], 8.5, T.faint, $.NSFontWeightRegular));
  turnValue = label('—', [14, H - 160, 94, 17], 12, T.text, $.NSFontWeightMedium);
  root.addSubview(turnValue);

  root.addSubview(label('总计', [120, H - 142, 80, 11], 8.5, T.faint, $.NSFontWeightRegular));
  sessionAgeValue = label('—', [120, H - 160, 98, 17], 12, T.text, $.NSFontWeightMedium);
  root.addSubview(sessionAgeValue);

  root.addSubview(label('Token', [14, H - 174, 60, 11], 8.5, T.faint, $.NSFontWeightRegular));
  outValue = label('—', [14, H - 190, 94, 17], 12, T.text, $.NSFontWeightMedium);
  root.addSubview(outValue);

  root.addSubview(label('积分', [120, H - 174, 60, 11], 8.5, T.faint, $.NSFontWeightRegular));
  creditsValue = label('0.00', [120, H - 190, 98, 17], 12, T.gold, $.NSFontWeightSemibold);
  root.addSubview(creditsValue);

  requestValue = label('', [14, 6, W - 48, 12], 8.5, T.faint, $.NSFontWeightRegular, 0, true);
  root.addSubview(requestValue);

  root.addSubview(box([W / 2 - 14, H - 5, 28, 3], T.track, 1.5, 0, null));

  const gearLabel = label('⚙', [W - 26, 4, 16, 14], 11, T.faint, $.NSFontWeightRegular, 2);
  root.addSubview(gearLabel);
  const gearButton = $.NSButton.alloc.initWithFrame($.NSMakeRect(W - 28, 2, 20, 18));
  gearButton.setBordered(false);
  gearButton.setTitle('');
  gearButton.setTarget(controller);
  gearButton.setAction('openSettings:');
  try { gearButton.setToolTip('设置'); } catch (e) {}
  root.addSubview(gearButton);
}

function buildBar(root, mode) {
  const W = mode === 'title' ? state.widths.title : state.widths.bottom;
  const H = mode === 'title' ? BAR_H_TITLE : BAR_H_BOTTOM;
  const y = H === BAR_H_TITLE ? 5 : 7;
  const stateW = 70;
  const isTitleMode = mode === 'title';

  dotBox = box([12, Math.round((H - 6) / 2), 6, 6], T.gray, 3, 0, null);
  root.addSubview(dotBox);

  let metricsX = 22;
  if (!isTitleMode) {
    const titleW = Math.max(90, Math.min(220, Math.round(W * 0.24)));
    titleLabel = label('', [22, y, titleW, 15], 10.5,
      T.text, $.NSFontWeightMedium, 0, true);
    root.addSubview(titleLabel);
    metricsX = 22 + titleW + 8;
  }

  const metricsW = Math.max(60, W - metricsX - stateW - 40);
  metricsLabel = label('', [metricsX, y, metricsW, 15], H === BAR_H_TITLE ? 9 : 9.5,
    T.soft, $.NSFontWeightRegular, 0, true);
  root.addSubview(metricsLabel);

  stateLabel = label('', [W - stateW - 34, H === BAR_H_TITLE ? 5 : 8, stateW, 15],
    9, T.faint, $.NSFontWeightMedium, 2);
  root.addSubview(stateLabel);

  const gearLabel = label('⚙', [W - 26, H === BAR_H_TITLE ? 4 : 6, 16, 16],
    11, T.faint, $.NSFontWeightRegular, 2);
  root.addSubview(gearLabel);
  const gearButton = $.NSButton.alloc.initWithFrame(
    $.NSMakeRect(W - 28, H === BAR_H_TITLE ? 2 : 4, 20, 18));
  gearButton.setBordered(false);
  gearButton.setTitle('');
  gearButton.setTarget(controller);
  gearButton.setAction('openSettings:');
  try { gearButton.setToolTip('设置'); } catch (e) {}
  root.addSubview(gearButton);
}

function buildIndicator(w) {
  if (indicatorPanel) {
    indicatorPanel.orderOut(null);
    indicatorPanel = null;
  }
  indicatorPanel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, w, 4), 128, $.NSBackingStoreBuffered, false);
  indicatorPanel.setLevel($.NSStatusWindowLevel);
  indicatorPanel.setCollectionBehavior(1 | 256 | 16);
  indicatorPanel.setOpaque(false);
  indicatorPanel.setBackgroundColor($.NSColor.clearColor);
  indicatorPanel.setHasShadow(false);
  indicatorPanel.setHidesOnDeactivate(false);
  indicatorPanel.setIgnoresMouseEvents(true);
  const root = indicatorPanel.contentView;
  root.addSubview(box([0, 0, w, 1], T.divider, 0, 0, null));
  root.addSubview(box([Math.max(0, w / 2 - 32), 0, 64, 3], T.greenDim, 1.5, 0, null));
  indicatorPanel.orderOut(null);
}

function buildUI(mode) {
  state.uiReady = false;
  state.layout = mode || 'sidebar';
  state.lastX = null;
  state.lastY = null;
  state.lastTooltip = '';
  resetUI();
  const isCard = state.layout === 'sidebar';
  const isTitle = state.layout === 'title';
  const w = isCard ? CARD_W : (isTitle ? state.widths.title : state.widths.bottom);
  const h = isCard ? CARD_H : (isTitle ? BAR_H_TITLE : BAR_H_BOTTOM);
  const root = makePanel(w, h);
  panel.setHasShadow(!isTitle);

  bgBox = isTitle
    ? box([0, 0, w, h], $.NSColor.clearColor, 0, 0, null)
    : box([0, 0, w, h], T.bg, isCard ? 12 : 10, 1, T.border);
  root.addSubview(bgBox);

  if (isCard) buildSidebar(root);
  else buildBar(root, state.layout);

  const dragHeight = isCard ? 64 : (isTitle ? h : 0);
  if (dragHeight > 0) {
    const dragWidth = isTitle ? Math.max(0, w - 30) : w;
    dragView = $.MeterDragView.alloc.initWithFrame($.NSMakeRect(0, h - dragHeight, dragWidth, dragHeight));
    root.addSubview(dragView);
  }

  if (indicatorPanel) {
    indicatorPanel.orderOut(null);
    indicatorPanel = null;
  }
  if (state.layout === 'bottom') buildIndicator(state.widths.bottom);

  panel.orderOut(null);
  state.uiReady = true;
}

function dragBegin() {
  try {
    const m = $.NSEvent.mouseLocation;
    dragStartMouse = { x: Number(m.x), y: Number(m.y) };
    const f = panel.frame.origin;
    dragStartOrigin = { x: Number(f.x), y: Number(f.y) };
    state.dragging = true;
  } catch (e) {}
}

function dragMove() {
  try {
    if (!state.dragging || !dragStartMouse || !dragStartOrigin) return;
    const m = $.NSEvent.mouseLocation;
    const screen = $.NSScreen.mainScreen;
    const sw = Number(screen.frame.size.width);
    const sh = Number(screen.frame.size.height);
    const pw = Number(panel.frame.size.width);
    const ph = Number(panel.frame.size.height);
    let x = Math.round(dragStartOrigin.x + (Number(m.x) - dragStartMouse.x));
    let y = Math.round(dragStartOrigin.y + (Number(m.y) - dragStartMouse.y));
    x = Math.max(4, Math.min(x, sw - pw - 4));
    if (state.layout === 'title') {
      y = Math.round(dragStartOrigin.y);
    } else {
      y = Math.max(4, Math.min(y, sh - ph - 34));
    }
    panel.setFrameOrigin($.NSMakePoint(x, y));
    state.lastX = x;
    state.lastY = y;
  } catch (e) {}
}

function dragEnd() {
  try {
    if (!state.dragging) return;
    state.dragging = false;
    const b = state.windowBounds;
    if (b && panel) {
      const sh = Number($.NSScreen.mainScreen.frame.size.height);
      const bottom = sh - (b.y + b.height);
      const f = panel.frame.origin;
      const dy = state.layout === 'title'
        ? 3
        : Math.round(Number(f.y) - bottom);
      state.positions[state.layout] = {
        dx: Math.round(Number(f.x) - b.x),
        dy: dy
      };
      state.lastX = Math.round(Number(f.x));
      state.lastY = Math.round(Number(f.y));
      saveSettings();
    }
  } catch (e) {
    logError('dragEnd', e);
  }
}

function setText(field, text) {
  if (!field) return;
  const cur = field.stringValue;
  const old = (cur && cur.js !== undefined) ? cur.js : String(cur);
  if (old !== text) field.setStringValue(text);
}

function setColor(field, color) {
  if (!field || typeof field.setTextColor !== 'function') return;
  field.setTextColor(color);
}

function setBoxFrame(view, x, y, w, h) {
  if (!view) return;
  const f = view.frame;
  if (Math.abs(f.origin.x - x) < 0.5 && Math.abs(f.origin.y - y) < 0.5 &&
      Math.abs(f.size.width - w) < 0.5 && Math.abs(f.size.height - h) < 0.5) {
    return;
  }
  view.setFrame($.NSMakeRect(x, y, w, h));
}

function updateSparkline() {
  if (!sparkBars.length) return;
  const hist = state.tpsHistory || [];
  let max = 0;
  for (let i = 0; i < hist.length; i++) {
    if (hist[i] > max) max = hist[i];
  }
  if (max < 80) max = 80;
  if (max > 300) max = 300;
  const n = sparkBars.length;
  for (let i = 0; i < n; i++) {
    const idx = hist.length - n + i;
    const v = idx >= 0 ? hist[idx] : 0;
    const h = v > 0 ? Math.max(3, Math.min(24, 4 + (v / max) * 20)) : 1;
    const b = sparkBars[i];
    setBoxFrame(b, 124 + i * 6.8, CARD_H - 114, 4, h);
    b.setFillColor(v > 0 ? (i === n - 1 ? T.green : T.greenDim) : T.track);
  }
}

function updateUI() {
  if (!panel || !state.uiReady) return;
  const hasSession = !!state.sessionId;
  const stats = state.ctxStats || {};
  const toolCount = (stats.toolCalls && stats.toolCalls.total) || state.toolCount || 0;
  const requestCount = state.requestCount || 0;
  const active = !!(state.lastEventAt && (Date.now() - state.lastEventAt < 20000));

  if (state.turnStartedAt && (state.inFlight || active)) {
    state.turnWall = Math.max(0, (Date.now() - state.turnStartedAt) / 1000);
  }
  state.sessionAge = state.sessionStartedAt
    ? Math.max(0, (Date.now() - state.sessionStartedAt) / 1000)
    : 0;
  state.creditsPerRequest = requestCount > 0 ? state.credits / requestCount : 0;

  const tpsText = fmtTps(state.tps);
  const turnText = state.turnWall ? fmtDuration(state.turnWall) : '—';
  const ageText = state.sessionAge ? fmtDuration(state.sessionAge) : '—';
  const outText = state.exactOut > 0 ? fmtK(state.exactOut)
    : (state.estOut > 0 ? '≈ ' + fmtK(state.estOut) : '—');
  const latencyText = state.lastLatency ? fmtElapsed(state.lastLatency) : '—';

  setText(titleLabel, hasSession ? truncate(state.title || '未命名会话', 60) : '等待 Qoder 会话');
  if (modelLabel) {
    setText(modelLabel, '会话统计 · ' + (state.model || 'Qoder'));
  }

  if (state.layout === 'sidebar') {
    setText(tpsValue, tpsText);
    setText(turnValue, turnText);
    setText(sessionAgeValue, ageText);
    setText(outValue, outText);
    setText(creditsValue, fmtCredits(state.credits));
    setText(requestValue, fmtCount(requestCount) + ' 请求 · ' + fmtCount(toolCount) +
      ' 工具 · 延迟 ' + latencyText);
    updateSparkline();
  } else if (metricsLabel) {
    setText(metricsLabel,
      'TPS ' + tpsText +
      '  ·  本轮 ' + turnText +
      '  ·  总计 ' + ageText +
      '  ·  Token ' + outText +
      '  ·  积分 ' + fmtCredits(state.credits) +
      '  ·  ' + fmtCount(requestCount) + ' 请求' +
      '  ·  工具 ' + fmtCount(toolCount) +
      '  ·  延迟 ' + latencyText);
  }

  if (state.inFlight) {
    dotBox.setFillColor(T.green);
    setText(stateLabel, '生成中 ' + fmtElapsed(state.inFlightElapsed));
    setColor(stateLabel, T.green);
    setColor(tpsValue, T.green);
  } else {
    dotBox.setFillColor(active ? T.gold : T.gray);
    setText(stateLabel, active ? '本轮中' : (hasSession ? '空闲' : ''));
    setColor(stateLabel, active ? T.gold : T.faint);
    setColor(tpsValue, state.tps ? T.greenDim : T.faint);
  }

  const exactNote = state.exactOut > 0 ? 'Token 精确值'
    : 'Token 按字符估算（模型未返回精确值），积分来自 Qoder 本地账单';
  const tooltip = hasSession ? (
    '会话：' + (state.title || '') + '\n' +
    '模型：' + (state.model || '—') + '\n' +
    '本轮 TPS：' + tpsText + (state.tps ? '（模型调用平均，含思考/工具参数）' : '') + '\n' +
    '本轮时长：' + turnText + '\n' +
    '会话总时长：' + ageText + '（自会话创建）\n' +
    '本轮模型耗时：' + fmtDuration(state.turnDuration) + '\n' +
    '本轮输出：' + (state.turnTokens ? '≈ ' + fmtK(state.turnTokens) + ' tok' : '—') + '\n' +
    '会话输出：' + (state.exactOut > 0 ? fmtK(state.exactOut) : '≈ ' + fmtK(state.estOut)) + ' tok\n' +
    (state.inputTokens > 0 ? '输入 Token：' + fmtK(state.inputTokens) + '\n' : '') +
    '已用积分：' + fmtCredits(state.credits) + '\n' +
    '请求数：' + requestCount + '（本轮 ' + state.turnRequestCount + '）\n' +
    '工具调用：' + toolCount + '\n' +
    '最近请求延迟：' + latencyText + '\n' +
    '会话轮次：' + (state.promptCount || 0) + '\n' +
    '积分/请求：' + (state.creditsPerRequest ? state.creditsPerRequest.toFixed(2) : '—') + '\n' +
    exactNote
  ) : '等待 Qoder 会话';

  if (tooltip !== state.lastTooltip) {
    state.lastTooltip = tooltip;
    try {
      titleLabel.setToolTip(tooltip);
      bgBox.setToolTip(tooltip);
      if (dragView) dragView.setToolTip(tooltip);
    } catch (e) {}
  }

  const itemTitle = '◉' + (hasSession && state.tps ? ' ' + fmtTps(state.tps) : '');
  try {
    if (statusItem) {
      if (statusItem.button.title.js !== itemTitle) statusItem.button.title = itemTitle;
      statusItem.button.setToolTip('Qoder Meter · TPS ' + tpsText + ' · 本轮 ' + turnText);
    }
  } catch (e) {}
}

/* ---------------------------------------------------------------- layout */

function applyWindowLayout() {
  if (!panel || state.dragging) return;
  const b = state.windowBounds;
  if (!b || !isFinite(b.x) || !isFinite(b.y) || !isFinite(b.width) || !isFinite(b.height)) return;

  const screen = $.NSScreen.mainScreen;
  const sw = Number(screen.frame.size.width);
  const sh = Number(screen.frame.size.height);
  const bottom = sh - (b.y + b.height);
  const isCard = state.layout === 'sidebar';
  const isTitle = state.layout === 'title';
  const isBottom = state.layout === 'bottom';
  if (!isBottom) state.bottomOutside = false;
  const w = isCard ? CARD_W : (isTitle ? state.widths.title : state.widths.bottom);
  const h = isCard ? CARD_H : (isTitle ? BAR_H_TITLE : BAR_H_BOTTOM);

  const saved = state.positions[state.layout];
  const hasSaved = !!(saved && isFinite(saved.dx) && isFinite(saved.dy));
  let x;
  let y;

  if (isTitle) {
    x = b.x + (hasSaved ? Number(saved.dx) : 300);
    y = bottom + b.height - h - 3;
  } else if (isBottom) {
    const visibleBottom = Number(screen.visibleFrame.origin.y);
    state.bottomOutside = (bottom - h - 4) >= visibleBottom + 4;
    x = b.x + 250;
    y = state.bottomOutside ? (bottom - h - 4) : (bottom + 4);
  } else {
    x = b.x + (hasSaved ? Number(saved.dx) : 4);
    y = bottom + (hasSaved ? Number(saved.dy) : 174);
  }

  if (b.x >= 0 && b.x < sw) {
    if (x + w > sw - 8) x = Math.max(8, sw - w - 8);
    if (x < 8) x = 8;
  }
  if (b.y >= 0 && b.y < sh) {
    if (isCard && !hasSaved) {
      const winTop = bottom + b.height;
      if (y + h > winTop - 6) y = winTop - h - 6;
    }
    if (y + h > sh - 34) y = sh - h - 34;
    if (y < 4) y = 4;
  }

  x = Math.round(x);
  y = Math.round(y);
  if (state.lastX === x && state.lastY === y) {
    if (indicatorPanel) indicatorPanel.setFrameOrigin($.NSMakePoint(x, bottom));
    return;
  }
  state.lastX = x;
  state.lastY = y;

  panel.setFrameOrigin($.NSMakePoint(x, y));
  if (indicatorPanel) indicatorPanel.setFrameOrigin($.NSMakePoint(x, bottom));
}

function refreshVisibility() {
  if (!panel) return;
  let bid = '';
  try {
    const front = $.NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && front.bundleIdentifier && !front.bundleIdentifier.isNil()) {
      bid = front.bundleIdentifier.js;
    }
  } catch (e) {}
  if (bid === 'com.qoder.app' || bid.indexOf('qoder.meter') >= 0) {
    state.lastQoderFrontAt = Date.now();
  }
  const show = !state.panelHidden && state.qoderRunning &&
    (Date.now() - state.lastQoderFrontAt < 2500);
  const bottomCollapsed = state.layout === 'bottom' && !state.bottomOutside &&
    state.bottomAutoHide && !state.bottomRevealed;

  if (!show) {
    if (panel.isVisible) panel.orderOut(null);
    if (indicatorPanel && indicatorPanel.isVisible) indicatorPanel.orderOut(null);
    return;
  }

  if (bottomCollapsed) {
    if (panel.isVisible) panel.orderOut(null);
    if (indicatorPanel && !indicatorPanel.isVisible) indicatorPanel.orderFront(null);
  } else {
    if (!panel.isVisible) panel.orderFront(null);
    if (indicatorPanel && indicatorPanel.isVisible) indicatorPanel.orderOut(null);
  }
}

function updateBottomHover() {
  if (state.layout !== 'bottom' || state.bottomOutside || !state.bottomAutoHide || !state.windowBounds) {
    if (state.bottomRevealed) {
      state.bottomRevealed = false;
      applyWindowLayout();
    }
    return;
  }
  try {
    const b = state.windowBounds;
    const screen = $.NSScreen.mainScreen;
    const sw = Number(screen.frame.size.width);
    const sh = Number(screen.frame.size.height);
    const bottom = sh - (b.y + b.height);
    const w = state.widths.bottom;
    let x = b.x + 250;
    if (b.x >= 0 && b.x < sw) {
      if (x + w > sw - 8) x = Math.max(8, sw - w - 8);
      if (x < 8) x = 8;
    }
    const m = $.NSEvent.mouseLocation;
    let hover = false;
    if (state.bottomRevealed) {
      hover = m.x >= x - 12 && m.x <= x + w + 12 &&
        m.y >= bottom - 8 && m.y <= bottom + BAR_H_BOTTOM + 16;
    } else {
      hover = m.x >= x - 12 && m.x <= x + w + 12 &&
        m.y >= bottom - 8 && m.y <= bottom + 18;
    }
    if (hover) {
      state.bottomRevealed = true;
      state.bottomHoverAt = Date.now();
    } else if (state.bottomRevealed && Date.now() - state.bottomHoverAt > 1500) {
      state.bottomRevealed = false;
    }
  } catch (e) {}
}

/* ------------------------------------------------------------------ menu */

function menuItem(title, action, checked, represented) {
  const item = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(title, action, '');
  item.setTarget(controller);
  if (checked !== null) item.setState(checked ? 1 : 0);
  if (represented) item.setRepresentedObject(represented);
  return item;
}

function buildMenu() {
  const menu = $.NSMenu.alloc.initWithTitle('Qoder Meter');
  menu.setAutoenablesItems(false);

  menu.addItem(menuItem('设置…', 'openSettings:', null, null));
  menu.addItem($.NSMenuItem.separatorItem);

  menu.addItem(menuItem(state.panelHidden ? '显示状态条' : '隐藏状态条', 'togglePanel:', null, null));
  menu.addItem($.NSMenuItem.separatorItem);
  menu.addItem(menuItem('自动跟随当前打开的会话', 'autoFollow:', state.pinned ? false : true, null));

  const sub = $.NSMenu.alloc.initWithTitle('选择会话');
  sub.setAutoenablesItems(false);
  if (!state.recent.length) {
    const none = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('暂无会话', '', '');
    none.setEnabled(false);
    sub.addItem(none);
  } else {
    for (let i = 0; i < state.recent.length; i++) {
      const row = state.recent[i];
      const it = menuItem(truncate(row.title || row.session_id, 38), 'selectSession:',
        row.session_id === state.sessionId, row.session_id);
      sub.addItem(it);
    }
  }
  const sessionMenuItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('选择会话', '', '');
  sessionMenuItem.setSubmenu(sub);
  menu.addItem(sessionMenuItem);

  menu.addItem($.NSMenuItem.separatorItem);

  const posMenu = $.NSMenu.alloc.initWithTitle('显示位置');
  posMenu.setAutoenablesItems(false);
  posMenu.addItem(menuItem('侧边栏卡片（推荐）', 'layoutSidebar:', state.layout === 'sidebar', null));
  posMenu.addItem(menuItem('窗口标题栏（融入顶部）', 'layoutTitle:', state.layout === 'title', null));
  posMenu.addItem(menuItem('窗口下方（贴外）', 'layoutBottom:', state.layout === 'bottom', null));
  posMenu.addItem($.NSMenuItem.separatorItem);
  posMenu.addItem(menuItem('重置当前位置', 'resetPosition:', null, null));
  const posItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('显示位置', '', '');
  posItem.setSubmenu(posMenu);
  menu.addItem(posItem);

  const themeMenu = $.NSMenu.alloc.initWithTitle('外观');
  themeMenu.setAutoenablesItems(false);
  themeMenu.addItem(menuItem('浅色卡片', 'themeLight:', state.theme === 'light', null));
  themeMenu.addItem(menuItem('深色卡片', 'themeDark:', state.theme === 'dark', null));
  const themeItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('外观', '', '');
  themeItem.setSubmenu(themeMenu);
  menu.addItem(themeItem);

  menu.addItem($.NSMenuItem.separatorItem);
  menu.addItem(menuItem('随 Qoder 自动启动', 'toggleAutoStart:', state.autoStart, null));
  menu.addItem(menuItem('Qoder 退出时关闭', 'toggleCloseWithQoder:', state.closeWithQoder, null));
  menu.addItem(menuItem('立即刷新', 'refreshNow:', null, null));
  menu.addItem($.NSMenuItem.separatorItem);
  menu.addItem(menuItem('退出 Qoder 状态条', 'quitApp:', null, null));

  state.menuSig = menuSignature();
  if (statusItem) statusItem.setMenu(menu);
}

function menuSignature() {
  const parts = state.recent.map(function (r) { return r.session_id + ':' + (r.title || ''); });
  return parts.join('|') + '#' + (state.pinned || '') + '#' + state.sessionId + '#' +
    (state.panelHidden ? 1 : 0) + '#' + state.layout + '#' + state.theme + '#' +
    (state.autoStart ? 1 : 0) + '#' + (state.closeWithQoder ? 1 : 0);
}

function refreshMenu() {
  try {
    const fm = $.NSFileManager.defaultManager;
    state.autoStart = !!fm.fileExistsAtPath(WATCH_PLIST);
    state.closeWithQoder = !fm.fileExistsAtPath(KEEP_FLAG);
    if (menuSignature() !== state.menuSig) buildMenu();
  } catch (e) {
    logError('refreshMenu', e);
  }
}

function buildStatusItem() {
  statusItem = $.NSStatusBar.systemStatusBar.statusItemWithLength($.NSVariableStatusItemLength);
  statusItem.button.title = '◉ —';
  try {
    statusItem.button.setFont($.NSFont.monospacedDigitSystemFontOfSizeWeight(11, $.NSFontWeightRegular));
    statusItem.button.setToolTip('Qoder Meter');
  } catch (e) {}
  buildMenu();
}

/* --------------------------------------------------------------- actions */

function resetPosition() {
  delete state.positions[state.layout];
  state.lastX = null;
  state.lastY = null;
  saveSettings();
  applyWindowLayout();
}

function applyWidthPreset(width) {
  state.widths.title = width;
  state.widths.bottom = width;
  saveSettings();
  if (state.layout !== 'sidebar') {
    if (panel) panel.orderOut(null);
    if (indicatorPanel) indicatorPanel.orderOut(null);
    buildUI(state.layout);
    applyWindowLayout();
    refreshVisibility();
    updateUI();
  }
  updateSettingsControls();
}

function toggleBottomAutoHide() {
  state.bottomAutoHide = !state.bottomAutoHide;
  state.bottomRevealed = state.bottomAutoHide ? false : true;
  saveSettings();
  if (state.layout === 'bottom') {
    applyWindowLayout();
    refreshVisibility();
  }
  updateSettingsControls();
}

function sLabel(str, frame, size, weight, color) {
  const f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  f.setStringValue(str);
  f.setBezeled(false);
  f.setDrawsBackground(false);
  f.setEditable(false);
  f.setSelectable(false);
  f.setFont($.NSFont.systemFontOfSizeWeight(size || 11,
    weight === undefined ? $.NSFontWeightRegular : weight));
  f.setTextColor(color || $.NSColor.labelColor);
  return f;
}

function sCheckbox(title, frame, action, checked) {
  const b = $.NSButton.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  b.setButtonType($.NSButtonTypeSwitch);
  b.setTitle(title);
  b.setFont($.NSFont.systemFontOfSize(12));
  b.setState(checked ? 1 : 0);
  b.setTarget(controller);
  b.setAction(action);
  return b;
}

function sPopup(items, selected, frame, action) {
  const p = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]), false);
  for (let i = 0; i < items.length; i++) p.addItemWithTitle(items[i]);
  p.selectItemAtIndex(selected || 0);
  p.setTarget(controller);
  p.setAction(action);
  return p;
}

function sButton(title, frame, action, key) {
  const b = $.NSButton.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  b.setBezelStyle($.NSBezelStyleRounded);
  b.setTitle(title);
  b.setTarget(controller);
  b.setAction(action);
  if (key) {
    try { b.setKeyEquivalent(key); } catch (e) {}
  }
  return b;
}

function sSeparator(y) {
  return box([20, y, 380, 1], $.NSColor.separatorColor, 0, 0, null);
}

function buildSettingsWindow() {
  settingsPanel = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 420, 520),
    3, // titled + closable
    $.NSBackingStoreBuffered,
    false
  );
  settingsPanel.setTitle('Qoder Meter 设置');
  settingsPanel.setReleasedWhenClosed(false);
  settingsPanel.setHidesOnDeactivate(false);
  settingsPanel.setLevel(26);

  const root = settingsPanel.contentView;
  root.addSubview(sLabel('Qoder Meter', [20, 482, 340, 24], 17, $.NSFontWeightSemibold));
  root.addSubview(sLabel('状态条显示、启动与会话跟随', [22, 462, 340, 16], 11, $.NSFontWeightRegular,
    $.NSColor.secondaryLabelColor));

  root.addSubview(sLabel('启动与退出', [20, 432, 340, 18], 11, $.NSFontWeightSemibold));
  settingsAutoStart = sCheckbox('随 Qoder 自动启动', [20, 404, 360, 24],
    'settingsToggleAutoStart:', state.autoStart);
  settingsClose = sCheckbox('Qoder 退出时关闭', [20, 378, 360, 24],
    'settingsToggleClose:', state.closeWithQoder);
  root.addSubview(settingsAutoStart);
  root.addSubview(settingsClose);
  root.addSubview(sSeparator(362));

  root.addSubview(sLabel('显示', [20, 336, 340, 18], 11, $.NSFontWeightSemibold));
  root.addSubview(sLabel('显示位置', [20, 308, 90, 18], 11));
  settingsPosPopup = sPopup(['侧边栏卡片（推荐）', '窗口标题栏（融入顶部）', '窗口下方（贴外）'],
    state.layout === 'sidebar' ? 0 : (state.layout === 'title' ? 1 : 2),
    [118, 304, 282, 26], 'settingsPosChanged:');
  root.addSubview(settingsPosPopup);

  root.addSubview(sLabel('状态条宽度', [20, 276, 90, 18], 11));
  const currentWidth = state.layout === 'title' ? state.widths.title : state.widths.bottom;
  const widthIndex = currentWidth <= 680 ? 0 : (currentWidth >= 880 ? 2 : 1);
  settingsWidthPopup = sPopup(['紧凑（640）', '标准（800）', '宽（960）'], widthIndex,
    [118, 272, 282, 26], 'settingsWidthChanged:');
  root.addSubview(settingsWidthPopup);

  root.addSubview(sLabel('外观', [20, 244, 90, 18], 11));
  settingsThemePopup = sPopup(['浅色卡片', '深色卡片'], state.theme === 'dark' ? 1 : 0,
    [118, 240, 282, 26], 'settingsThemeChanged:');
  root.addSubview(settingsThemePopup);

  settingsBottomAutoHide = sCheckbox('下方空间不足时自动隐藏', [20, 210, 360, 24],
    'settingsBottomAutoHideToggle:', state.bottomAutoHide);
  root.addSubview(settingsBottomAutoHide);
  root.addSubview(sSeparator(192));

  root.addSubview(sLabel('会话', [20, 166, 340, 18], 11, $.NSFontWeightSemibold));
  settingsFollow = sCheckbox('自动跟随当前打开的会话', [20, 138, 360, 24],
    'settingsFollowToggle:', state.pinned ? false : true);
  root.addSubview(settingsFollow);
  root.addSubview(sLabel('关闭后可在菜单中手动选择并固定会话。', [20, 114, 380, 16], 10,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));
  root.addSubview(sLabel('拖动卡片顶部可移动；宽度对标题栏和底部条生效。', [20, 90, 380, 16], 10,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));

  root.addSubview(sButton('重置当前位置', [20, 36, 140, 28], 'resetPosition:', null));
  root.addSubview(sButton('完成', [300, 36, 100, 28], 'closeSettings:', '\r'));
  settingsPanel.center;
}

function updateSettingsControls() {
  if (!settingsPanel) return;
  try {
    settingsAutoStart.setState(state.autoStart ? 1 : 0);
    settingsClose.setState(state.closeWithQoder ? 1 : 0);
    settingsFollow.setState(state.pinned ? 0 : 1);
    settingsBottomAutoHide.setState(state.bottomAutoHide ? 1 : 0);
    settingsPosPopup.selectItemAtIndex(state.layout === 'sidebar' ? 0 : (state.layout === 'title' ? 1 : 2));
    const width = state.layout === 'title' ? state.widths.title : state.widths.bottom;
    settingsWidthPopup.selectItemAtIndex(width <= 680 ? 0 : (width >= 880 ? 2 : 1));
    settingsThemePopup.selectItemAtIndex(state.theme === 'dark' ? 1 : 0);
    const name = state.theme === 'dark' ? $.NSAppearanceNameDarkAqua : $.NSAppearanceNameAqua;
    const appearance = $.NSAppearance.appearanceNamed(name);
    if (appearance && !appearance.isNil()) settingsPanel.setAppearance(appearance);
  } catch (e) {
    logError('updateSettingsControls', e);
  }
}

function showSettings() {
  if (!settingsPanel) buildSettingsWindow();
  updateSettingsControls();
  try {
    settingsPanel.center;
    settingsPanel.makeKeyAndOrderFront(null);
    $.NSApplication.sharedApplication.activateIgnoringOtherApps(true);
  } catch (e) {
    logError('showSettings', e);
  }
}

function setTheme(theme) {
  const next = theme === 'dark' ? 'dark' : 'light';
  if (next === state.theme) {
    buildMenu();
    return;
  }
  state.theme = next;
  T = next === 'dark' ? PALETTE_DARK : PALETTE_LIGHT;
  saveSettings();
  if (panel) panel.orderOut(null);
  buildUI(state.layout);
  applyWindowLayout();
  refreshVisibility();
  updateUI();
  updateSettingsControls();
  buildMenu();
}

function setLayout(mode) {
  if (mode !== 'sidebar' && mode !== 'title' && mode !== 'bottom') return;
  if (mode === state.layout) {
    buildMenu();
    return;
  }
  state.layout = mode;
  state.bottomRevealed = mode === 'bottom' ? !state.bottomAutoHide : false;
  state.lastX = null;
  state.lastY = null;
  saveSettings();
  if (panel) panel.orderOut(null);
  if (indicatorPanel) indicatorPanel.orderOut(null);
  buildUI(mode);
  applyWindowLayout();
  refreshVisibility();
  updateUI();
  updateSettingsControls();
  buildMenu();
}

ObjC.registerSubclass({
  name: 'MeterDragView',
  superclass: 'NSView',
  methods: {
    'acceptsFirstMouse:': {
      types: ['bool', ['id']],
      implementation: function (event) { return true; }
    },
    'mouseDown:': {
      types: ['void', ['id']],
      implementation: function (event) { dragBegin(); }
    },
    'mouseDragged:': {
      types: ['void', ['id']],
      implementation: function (event) { dragMove(); }
    },
    'mouseUp:': {
      types: ['void', ['id']],
      implementation: function (event) { dragEnd(); }
    }
  }
});

ObjC.registerSubclass({
  name: 'QoderMeterController',
  methods: {
    'togglePanel:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        state.panelHidden = !state.panelHidden;
        saveSettings();
        refreshVisibility();
        buildMenu();
      }
    },
    'autoFollow:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        state.pinned = null;
        saveSettings();
        refreshData();
        updateSettingsControls();
        buildMenu();
      }
    },
    'selectSession:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        let sid = '';
        try {
          const ro = sender.representedObject;
          sid = (ro && ro.js !== undefined) ? ro.js : String(ro || '');
        } catch (e) {}
        if (!sid) return;
        state.pinned = sid;
        saveSettings();
        refreshData();
        updateSettingsControls();
        buildMenu();
      }
    },
    'layoutSidebar:': {
      types: ['void', ['id']],
      implementation: function (sender) { setLayout('sidebar'); }
    },
    'layoutTitle:': {
      types: ['void', ['id']],
      implementation: function (sender) { setLayout('title'); }
    },
    'layoutBottom:': {
      types: ['void', ['id']],
      implementation: function (sender) { setLayout('bottom'); }
    },
    'themeLight:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('light'); }
    },
    'themeDark:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('dark'); }
    },
    'toggleAutoStart:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleAutoStart();
        refreshMenu();
        updateSettingsControls();
        buildMenu();
      }
    },
    'toggleCloseWithQoder:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleCloseWithQoder();
        refreshMenu();
        updateSettingsControls();
        buildMenu();
      }
    },
    'openSettings:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        showSettings();
      }
    },
    'resetPosition:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        resetPosition();
        buildMenu();
        updateSettingsControls();
      }
    },
    'settingsToggleAutoStart:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleAutoStart();
        refreshMenu();
        updateSettingsControls();
        buildMenu();
      }
    },
    'settingsToggleClose:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleCloseWithQoder();
        refreshMenu();
        updateSettingsControls();
        buildMenu();
      }
    },
    'settingsFollowToggle:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const on = Number(sender.state) === 1;
        state.pinned = on ? null : state.sessionId;
        saveSettings();
        refreshData();
        updateSettingsControls();
        buildMenu();
      }
    },
    'settingsPosChanged:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(settingsPosPopup.indexOfSelectedItem);
        setLayout(idx === 0 ? 'sidebar' : (idx === 1 ? 'title' : 'bottom'));
        updateSettingsControls();
      }
    },
    'settingsWidthChanged:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(settingsWidthPopup.indexOfSelectedItem);
        applyWidthPreset(idx === 0 ? 640 : (idx === 2 ? 960 : 800));
        updateSettingsControls();
      }
    },
    'settingsBottomAutoHideToggle:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleBottomAutoHide();
        updateSettingsControls();
      }
    },
    'settingsThemeChanged:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(settingsThemePopup.indexOfSelectedItem);
        setTheme(idx === 1 ? 'dark' : 'light');
        updateSettingsControls();
      }
    },
    'closeSettings:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        if (settingsPanel) settingsPanel.orderOut(null);
      }
    },
    'refreshNow:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        refreshData();
      }
    },
    'quitApp:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        if (state.autoStart) {
          sh('/bin/mkdir -p ' + q(SETTINGS_DIR));
          sh('/usr/bin/touch ' + q(PAUSE_FLAG));
        }
        app.terminate(null);
      }
    }
  }
});

/* ------------------------------------------------------------ login item */

function xmlEscape(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function toggleAutoStart() {
  try {
    const fm = $.NSFileManager.defaultManager;
    if (fm.fileExistsAtPath(WATCH_PLIST)) {
      sh('/bin/launchctl unload -w ' + q(WATCH_PLIST) + ' 2>/dev/null');
      fm.removeItemAtPathError(WATCH_PLIST, null);
      fm.removeItemAtPathError(PAUSE_FLAG, null);
      state.autoStart = false;
      return;
    }

    if (fm.fileExistsAtPath(OLD_LOGIN_PLIST)) {
      sh('/bin/launchctl unload -w ' + q(OLD_LOGIN_PLIST) + ' 2>/dev/null');
      fm.removeItemAtPathError(OLD_LOGIN_PLIST, null);
    }

    sh('/bin/mkdir -p ' + q(SETTINGS_DIR));
    const bundlePath = $.NSBundle.mainBundle.bundlePath.js;
    const script = '#!/bin/bash\n' +
      'APP=' + q(bundlePath) + '\n' +
      'APPLE="$APP/Contents/MacOS/applet"\n' +
      'CFG="$HOME/Library/Application Support/QoderMeter"\n' +
      'PAUSE="$CFG/autostart-paused"\n' +
      'KEEP="$CFG/keep-running"\n' +
      'running=0\n' +
      'if pgrep -x Qoder >/dev/null 2>&1 || pgrep -f "/Applications/Qoder.app/Contents/MacOS/Qoder" >/dev/null 2>&1; then running=1; fi\n' +
      'if [ "$running" -eq 0 ]; then\n' +
      '  rm -f "$PAUSE"\n' +
      '  if [ ! -f "$KEEP" ]; then\n' +
      '    pkill -f "^$APPLE$" >/dev/null 2>&1\n' +
      '  fi\n' +
      '  exit 0\n' +
      'fi\n' +
      '[ -f "$PAUSE" ] && exit 0\n' +
      'if ! pgrep -f "^$APPLE$" >/dev/null 2>&1; then\n' +
      '  /usr/bin/open -g "$APP"\n' +
      'fi\n';

    const ss = $.NSString.alloc.initWithString(script);
    ss.writeToFileAtomicallyEncodingError(WATCH_SCRIPT, true, $.NSUTF8StringEncoding, null);
    sh('/bin/chmod +x ' + q(WATCH_SCRIPT));

    const plist = '<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
      '<plist version="1.0"><dict>\n' +
      '<key>Label</key><string>com.qoder.meter.watch</string>\n' +
      '<key>ProgramArguments</key><array>\n' +
      '<string>/bin/bash</string><string>' + xmlEscape(WATCH_SCRIPT) + '</string>\n' +
      '</array>\n' +
      '<key>RunAtLoad</key><true/>\n' +
      '<key>StartInterval</key><integer>3</integer>\n' +
      '<key>ProcessType</key><string>Background</string>\n' +
      '<key>StandardOutPath</key><string>' + xmlEscape(WATCH_LOG) + '</string>\n' +
      '<key>StandardErrorPath</key><string>' + xmlEscape(WATCH_LOG) + '</string>\n' +
      '</dict></plist>\n';

    const ps = $.NSString.alloc.initWithString(plist);
    ps.writeToFileAtomicallyEncodingError(WATCH_PLIST, true, $.NSUTF8StringEncoding, null);
    sh('/bin/mkdir -p ' + q(HOME + '/Library/LaunchAgents'));
    fm.removeItemAtPathError(PAUSE_FLAG, null);
    sh('/bin/launchctl load -w ' + q(WATCH_PLIST) + ' 2>/dev/null');
    state.autoStart = !!fm.fileExistsAtPath(WATCH_PLIST);
  } catch (e) {
    logError('toggleAutoStart', e);
  }
}

function toggleCloseWithQoder() {
  try {
    const fm = $.NSFileManager.defaultManager;
    sh('/bin/mkdir -p ' + q(SETTINGS_DIR));
    if (fm.fileExistsAtPath(KEEP_FLAG)) {
      fm.removeItemAtPathError(KEEP_FLAG, null);
      state.closeWithQoder = true;
    } else {
      sh('/usr/bin/touch ' + q(KEEP_FLAG));
      state.closeWithQoder = false;
    }
  } catch (e) {
    logError('toggleCloseWithQoder', e);
  }
}

/* -------------------------------------------------------------- refresh */

function parseSnapshot(row) {
  let snap = {};
  try { snap = JSON.parse(row.ctx_json || '{}'); } catch (e) {}
  return snap.sessionStats || null;
}

function switchSession(row) {
  state.sessionId = row.session_id;
  state.title = row.title || '';
  state.model = row.model || '';
  state.cwd = row.cwd || '';
  state.sessionStartedAt = Number(row.created_at) || 0;
  state.sessionAge = 0;
  state.promptCount = Number(row.prompt_count) || 0;
  state.sdk = null;
  state.seg = null;
  state.tps = null;
  state.tpsHistory = [];
  state.turnTokens = 0;
  state.turnDuration = 0;
  state.turnWall = 0;
  state.turnRequestCount = 0;
  state.turnStartedAt = 0;
  state.turnEndedAt = 0;
  state.lastLatency = null;
  state.inFlight = false;
  state.inFlightElapsed = 0;
  state.credits = 0;
  state.originalCredits = 0;
  state.estOut = 0;
  state.exactOut = 0;
  state.inputTokens = 0;
  state.assistantCount = 0;
  state.toolCount = 0;
  state.requestCount = 0;
  state.creditsPerRequest = 0;
  state.lastEventAt = 0;
  initSdk(row);
  initSeg();
  syncSdkTotals();
}

function syncSdkTotals() {
  const sdk = state.sdk;
  if (!sdk) return;
  state.credits = sdk.credits;
  state.originalCredits = sdk.originalCredits;
  state.estOut = sdk.estOut;
  state.exactOut = sdk.exactOut;
  state.inputTokens = sdk.inputTokens;
  state.assistantCount = sdk.assistantCount;
  state.toolCount = sdk.toolCount;
  state.requestCount = sdk.requestCount;
  if (!state.sessionStartedAt && sdk.firstTs) state.sessionStartedAt = sdk.firstTs;
}

function refreshData() {
  try {
    const payload = queryPayload();
    if (payload) {
      if (payload.window && payload.window !== 'null') {
        try { state.windowBounds = JSON.parse(payload.window); } catch (e) {}
      }
      state.recent = Array.isArray(payload.sessions) ? payload.sessions : [];
      const activeId = readActiveSessionId();
      state.activeSessionId = activeId;

      let row = null;
      if (state.pinned) {
        for (let i = 0; i < state.recent.length; i++) {
          if (state.recent[i].session_id === state.pinned) { row = state.recent[i]; break; }
        }
        if (!row) state.pinned = null;
      }
      if (!row && activeId) {
        for (let i = 0; i < state.recent.length; i++) {
          if (state.recent[i].session_id === activeId) { row = state.recent[i]; break; }
        }
        if (!row) {
          row = querySessionRow(activeId);
          if (row) state.recent.unshift(row);
        }
      }
      if (!row) row = state.recent[0] || null;

      if (row) {
        if (row.session_id !== state.sessionId) {
          switchSession(row);
        } else {
          state.title = row.title || '';
          state.model = row.model || '';
          state.cwd = row.cwd || '';
          state.sessionStartedAt = Number(row.created_at) || state.sessionStartedAt;
          state.promptCount = Number(row.prompt_count) || 0;
        }
        state.ctxStats = parseSnapshot(row);
      } else {
        state.sessionId = null;
        state.title = '';
        state.model = '';
        state.cwd = '';
        state.sdk = null;
        state.seg = null;
        state.ctxStats = null;
        state.tps = null;
        state.tpsHistory = [];
        state.credits = 0;
        state.estOut = 0;
        state.exactOut = 0;
        state.assistantCount = 0;
        state.toolCount = 0;
        state.requestCount = 0;
        state.promptCount = 0;
        state.sessionStartedAt = 0;
        state.sessionAge = 0;
        state.turnWall = 0;
        state.turnStartedAt = 0;
        state.turnRequestCount = 0;
      }
    }

    try {
      state.qoderRunning = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.qoder.app').count > 0;
    } catch (e) {
      state.qoderRunning = false;
    }

    if (state.sessionId) {
      updateSdk();
      updateSeg();
      syncSdkTotals();
      computeTurn();
    }
    updateUI();
  } catch (e) {
    logError('refreshData', e);
  }
}

/* ----------------------------------------------------------------- main */

function tick() {
  try {
    if (state.inFlight && state.requestStartedAt) {
      state.inFlightElapsed = Math.max(0, (Date.now() - state.requestStartedAt) / 1000);
    }
    updateUI();
    updateBottomHover();
    applyWindowLayout();
    refreshVisibility();
  } catch (e) {
    logError('tick', e);
  }
}

function main() {
  app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  controller = $.QoderMeterController.alloc.init;

  loadSettings();

  try {
    const fm = $.NSFileManager.defaultManager;
    if (fm.fileExistsAtPath(OLD_LOGIN_PLIST)) {
      sh('/bin/launchctl unload -w ' + q(OLD_LOGIN_PLIST) + ' 2>/dev/null');
      fm.removeItemAtPathError(OLD_LOGIN_PLIST, null);
    }
  } catch (e) {}

  T = state.theme === 'dark' ? PALETTE_DARK : PALETTE_LIGHT;
  buildUI(state.layout);
  buildStatusItem();

  state.lastQoderFrontAt = Date.now();
  refreshData();
  applyWindowLayout();
  refreshVisibility();

  let counter = 0;
  $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(POLL_SECONDS, true, function () {
    counter++;
    if (counter % 3 === 0) refreshData();
    tick();
    if (counter % 8 === 0) refreshMenu();
  });

  log('started');
  app.run();
}

main();
