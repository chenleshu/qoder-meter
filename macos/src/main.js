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
ObjC.import('CoreGraphics');

const CA = Application.currentApplication();
CA.includeStandardAdditions = true;

const HOME = $.NSHomeDirectory().js;
const DB_PATH = HOME + '/Library/Application Support/com.qoder.app.stable/main.sqlite';
const PROJECTS_ROOT = HOME + '/.qoder/projects';
const SESSIONS_ROOT = HOME + '/.qoder/logs/sessions';
const LOCAL_STORAGE_DIR = HOME + '/Library/Application Support/com.qoder.app.stable/Local Storage/leveldb';
const SETTINGS_DIR = HOME + '/Library/Application Support/QoderMeter';
const SETTINGS_PATH = SETTINGS_DIR + '/settings.json';
const STATS_CACHE_PATH = SETTINGS_DIR + '/stats-cache.json';
const LOG_PATH = HOME + '/Library/Logs/QoderMeter.log';
const OLD_LOGIN_PLIST = HOME + '/Library/LaunchAgents/com.qoder.meter.plist';
const WATCH_PLIST = HOME + '/Library/LaunchAgents/com.qoder.meter.watch.plist';
const WATCH_SCRIPT = SETTINGS_DIR + '/watch.sh';
const WATCH_LOG = SETTINGS_DIR + '/watch.log';
const PAUSE_FLAG = SETTINGS_DIR + '/autostart-paused';
const KEEP_FLAG = SETTINGS_DIR + '/keep-running';

let BAR_H_TITLE = 28;
let BAR_H_TOP = 32;
let BAR_H_BOTTOM = 32;
const CARD_W = 246;
const CARD_H = 220;
const POLL_SECONDS = 0.6;
const STATS_PAGE_SIZE = 5;
const STATS_CACHE_MS = 10 * 60 * 1000;

const STATS_RANGES = [
  { id: '7d', label: '7 天' },
  { id: '30d', label: '近 30 天' },
  { id: 'month', label: '本月' },
  { id: 'year', label: '近一年' }
];

const STATS_MODES = [
  { id: 'hover', label: '悬停显示' },
  { id: 'direct', label: '直接显示' },
  { id: 'paged', label: '分页显示' }
];

/* Qoder 的本地日志只写内部模型 id（如 dfmodel）。这些是 Qoder 自带的
 * 展示名，运行时会优先从 Qoder 资源里的 model.<id>.label 重新校准。 */
const MODEL_LABELS = {
  auto: 'Auto',
  cmodel: 'Cantus',
  dfmodel: 'DeepSeek-V4-Flash',
  dmodel: 'DeepSeek-V4-Pro',
  efficient: 'Efficient',
  gfmodel: 'GLM-5.3-Flash',
  gmodel: 'GLM-5.3',
  kmodel: 'Kimi-K2.7-Code',
  kmodel_latest: 'Kimi-K3',
  lite: 'Lite',
  mmodel: 'MiniMax-M3',
  performance: 'Performance',
  qfmodel: 'Qwen3.8-Flash',
  qmodel: 'Qwen3.7-Plus',
  qmodel_38max: 'Qwen3.8-Max',
  qmodel_latest: 'Qwen3.7-Max',
  ultimate: 'Ultimate'
};
let MODEL_LABEL_MAP = Object.assign({}, MODEL_LABELS);

const FONT_SIZES = [
  { id: 'small', label: '小', scale: 0.96 },
  { id: 'normal', label: '标准', scale: 1.08 },
  { id: 'large', label: '大', scale: 1.2 },
  { id: 'xlarge', label: '特大', scale: 1.32 }
];

const TOKEN_UNITS = [
  { id: 'latin', label: 'b / m / k', sample: '≈ 888.8m' },
  { id: 'cn', label: '亿 / 万', sample: '≈ 8888.8万' }
];

const DISPLAY_FIELDS = [
  { id: 'tps', label: 'TPS' },
  { id: 'turn', label: '本轮' },
  { id: 'age', label: '总计' },
  { id: 'token', label: 'Token' },
  { id: 'credits', label: '积分' },
  { id: 'requests', label: '请求' },
  { id: 'tools', label: '工具' },
  { id: 'latency', label: '延迟' },
  { id: 'status', label: '状态' },
  { id: 'title', label: '标题' }
];

const CJK_RE = /[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/g;

const col = function (r, g, b, a) {
  return $.NSColor.colorWithCalibratedRedGreenBlueAlpha(r, g, b, a);
};
const wht = function (w, a) {
  return $.NSColor.colorWithCalibratedWhiteAlpha(w, a);
};

const SKINS = {
  paper: {
    bg: col(1, 1, 1, 0.985),
    border: col(0.87, 0.89, 0.92, 1),
    text: col(0.08, 0.10, 0.13, 1),
    soft: col(0.28, 0.32, 0.38, 1),
    gray: col(0.43, 0.47, 0.53, 1),
    faint: col(0.59, 0.63, 0.69, 1),
    green: col(0.03, 0.58, 0.40, 1),
    greenDim: col(0.16, 0.55, 0.44, 1),
    gold: col(0.66, 0.41, 0.07, 1),
    red: col(0.84, 0.16, 0.16, 1),
    blue: col(0.14, 0.38, 0.90, 1),
    track: col(0.92, 0.93, 0.95, 1),
    divider: col(0.92, 0.93, 0.95, 1),
    greenTint: col(0.03, 0.58, 0.40, 0.10),
    goldTint: col(0.66, 0.41, 0.07, 0.11),
    grayTint: col(0.42, 0.46, 0.52, 0.07),
    blueTint: col(0.14, 0.38, 0.90, 0.10),
    highlight: wht(1, 0.70)
  },
  graphite: {
    bg: col(0.085, 0.095, 0.115, 0.975),
    border: wht(1, 0.10),
    text: wht(0.96, 1),
    soft: wht(0.78, 1),
    gray: wht(0.60, 1),
    faint: wht(0.42, 1),
    green: col(0.34, 0.88, 0.60, 1),
    greenDim: col(0.38, 0.72, 0.56, 1),
    gold: col(0.95, 0.78, 0.42, 1),
    red: col(0.96, 0.44, 0.40, 1),
    blue: col(0.52, 0.70, 1, 1),
    track: wht(1, 0.13),
    divider: wht(1, 0.075),
    greenTint: col(0.34, 0.88, 0.60, 0.14),
    goldTint: col(0.95, 0.78, 0.42, 0.15),
    grayTint: wht(1, 0.08),
    blueTint: col(0.52, 0.70, 1, 0.14),
    highlight: wht(1, 0.06)
  },
  ocean: {
    bg: col(0.955, 0.975, 0.995, 0.985),
    border: col(0.80, 0.86, 0.92, 1),
    text: col(0.06, 0.11, 0.18, 1),
    soft: col(0.24, 0.32, 0.42, 1),
    gray: col(0.40, 0.48, 0.57, 1),
    faint: col(0.56, 0.63, 0.71, 1),
    green: col(0.02, 0.50, 0.62, 1),
    greenDim: col(0.10, 0.46, 0.56, 1),
    gold: col(0.64, 0.42, 0.08, 1),
    red: col(0.82, 0.20, 0.24, 1),
    blue: col(0.10, 0.36, 0.82, 1),
    track: col(0.88, 0.92, 0.97, 1),
    divider: col(0.88, 0.92, 0.97, 1),
    greenTint: col(0.02, 0.50, 0.62, 0.11),
    goldTint: col(0.64, 0.42, 0.08, 0.11),
    grayTint: col(0.30, 0.42, 0.55, 0.075),
    blueTint: col(0.10, 0.36, 0.82, 0.10),
    highlight: wht(1, 0.80)
  },
  dusk: {
    bg: col(0.075, 0.085, 0.135, 0.975),
    border: wht(1, 0.10),
    text: wht(0.95, 1),
    soft: wht(0.76, 1),
    gray: wht(0.58, 1),
    faint: wht(0.40, 1),
    green: col(0.30, 0.78, 0.92, 1),
    greenDim: col(0.32, 0.66, 0.82, 1),
    gold: col(0.95, 0.76, 0.48, 1),
    red: col(0.96, 0.45, 0.44, 1),
    blue: col(0.58, 0.64, 1, 1),
    track: wht(1, 0.12),
    divider: wht(1, 0.075),
    greenTint: col(0.30, 0.78, 0.92, 0.14),
    goldTint: col(0.95, 0.76, 0.48, 0.15),
    grayTint: wht(1, 0.08),
    blueTint: col(0.58, 0.64, 1, 0.14),
    highlight: wht(1, 0.06)
  },
  sand: {
    bg: col(0.995, 0.975, 0.940, 0.985),
    border: col(0.89, 0.85, 0.78, 1),
    text: col(0.14, 0.11, 0.08, 1),
    soft: col(0.34, 0.29, 0.23, 1),
    gray: col(0.47, 0.42, 0.35, 1),
    faint: col(0.61, 0.56, 0.48, 1),
    green: col(0.28, 0.55, 0.30, 1),
    greenDim: col(0.38, 0.53, 0.32, 1),
    gold: col(0.66, 0.38, 0.04, 1),
    red: col(0.82, 0.20, 0.18, 1),
    blue: col(0.22, 0.38, 0.66, 1),
    track: col(0.93, 0.90, 0.84, 1),
    divider: col(0.93, 0.90, 0.84, 1),
    greenTint: col(0.28, 0.55, 0.30, 0.11),
    goldTint: col(0.66, 0.38, 0.04, 0.11),
    grayTint: col(0.50, 0.42, 0.30, 0.075),
    blueTint: col(0.22, 0.38, 0.66, 0.10),
    highlight: wht(1, 0.55)
  }
};

const SKIN_IDS = ['auto', 'paper', 'graphite', 'ocean', 'dusk', 'sand'];
const SKIN_NAMES = ['自动（跟随 Qoder）', '纸白', '石墨', '海盐', '暮色', '暖砂'];

let T = SKINS.paper;

const state = {
  sessionId: null,
  title: '',
  model: '',
  cwd: '',
  ctxStats: null,
  layout: 'sidebar',
  theme: 'auto',
  resolvedSkin: 'paper',
  autoThemeAt: 0,
  positions: {},
  widths: { title: 800, top: 800, bottom: 800 },
  display: {
    tps: true, turn: true, age: true, token: true, credits: true,
    requests: true, tools: true, latency: true, status: true, title: true
  },
  fontSize: 'normal',
  tokenUnit: 'latin',
  statsMode: 'hover',
  statsRange: '7d',
  statsHidden: false,
  statsPreview: false,
  statsPinned: false,
  statsPreviewAt: 0,
  statsHover: false,
  statsHoverAt: 0,
  statsSuppress: false,
  statsPage: 0,
  statsToggleAt: 0,
  statsCache: null,
  statsData: null,
  frontIsQoder: false,
  bottomAutoHide: true,
  bottomRevealed: false,
  bottomOutside: false,
  bottomHoverAt: 0,
  qoderFullscreen: false,
  topRevealed: false,
  topInline: false,
  topHoverAt: 0,
  updateUrl: null,
  updateChecking: false,
  barLayout: null,
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
let dotHalo = null;
let statusPill = null;
let accentBar = null;
let gripBox = null;
let latencyPill = null;
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
let metricLabels = {};
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
let settingsFontPopup = null;
let settingsTokenUnitPopup = null;
let settingsFieldChecks = [];
let statsPanel = null;
let statsPillBox = null;
let statsIconView = null;
let statsButtonRect = null;
let settingsThemePopup = null;
let settingsBottomAutoHide = null;
let settingsUpdateButton = null;
let settingsUpdateLabel = null;
let settingsHeaderBox = null;
let settingsHeaderIcon = null;

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

function fmtToken(n) {
  if (!n || n <= 0) return '—';
  if (state.tokenUnit === 'cn') {
    if (n >= 100000000) return (n / 100000000).toFixed(2) + '亿';
    if (n >= 10000) return (n / 10000).toFixed(1) + '万';
    return String(Math.round(n));
  }
  if (n >= 1000000000) return (n / 1000000000).toFixed(2) + 'b';
  if (n >= 1000000) return (n / 1000000).toFixed(2) + 'm';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}

function tokenUnitSample() {
  for (let i = 0; i < TOKEN_UNITS.length; i++) {
    if (TOKEN_UNITS[i].id === state.tokenUnit) return TOKEN_UNITS[i].sample;
  }
  return TOKEN_UNITS[0].sample;
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
  if (v >= 1000) {
    return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  }
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

/* --------------------------------------------------------------- themes */

function normalizeTheme(theme) {
  if (theme === 'light') return 'paper';
  if (theme === 'dark') return 'graphite';
  return SKIN_IDS.indexOf(theme) >= 0 ? theme : 'auto';
}

function systemIsDark() {
  try {
    const name = $.NSApplication.sharedApplication.effectiveAppearance.name;
    return String(name.js).toLowerCase().indexOf('dark') >= 0;
  } catch (e) {
    return false;
  }
}

function qoderThemeMode() {
  try {
    let raw = '';
    const dict = $.NSDictionary.dictionaryWithContentsOfFile(
      HOME + '/Library/Preferences/com.qoder.app.plist');
    if (dict && !dict.isNil()) {
      const v = dict.objectForKey('QoderApplicationIconProjection');
      if (v && !v.isNil() && v.js) raw = String(v.js);
    }
    if (!raw) {
      raw = sh('/usr/bin/defaults read com.qoder.app QoderApplicationIconProjection 2>/dev/null');
    }
    if (!raw) return null;
    const eff = raw.match(/"effectiveAppearance"\s*:\s*"([^"]+)"/);
    if (eff) return eff[1];
    const mode = raw.match(/"themeMode"\s*:\s*"([^"]+)"/);
    if (mode && mode[1] !== 'auto') return mode[1];
  } catch (e) {}
  return null;
}

function resolveSkin(theme) {
  const t = normalizeTheme(theme);
  if (t !== 'auto') return t;
  const qoderMode = qoderThemeMode();
  if (qoderMode === 'dark') return 'graphite';
  if (qoderMode === 'light') return 'paper';
  return systemIsDark() ? 'graphite' : 'paper';
}

function applySkin() {
  state.resolvedSkin = resolveSkin(state.theme);
  T = SKINS[state.resolvedSkin] || SKINS.paper;
}

function fontScale() {
  for (let i = 0; i < FONT_SIZES.length; i++) {
    if (FONT_SIZES[i].id === state.fontSize) return FONT_SIZES[i].scale;
  }
  return 1;
}

function applyFontScale() {
  const s = fontScale();
  BAR_H_TITLE = Math.round(28 * s);
  BAR_H_TOP = Math.round(32 * s);
  BAR_H_BOTTOM = Math.round(32 * s);
}

function textWidth(text, font) {
  try {
    const attrs = $.NSDictionary.dictionaryWithObjectForKey(font, $.NSFontAttributeName);
    const size = $(String(text)).sizeWithAttributes(attrs);
    return Math.ceil(Number(size.width));
  } catch (e) {
    return Math.ceil(String(text).length * 7);
  }
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
      if (layout === 'sidebar' || layout === 'title' || layout === 'top' || layout === 'bottom') {
        state.layout = layout;
      }
      if (obj.theme) {
        state.theme = normalizeTheme(obj.theme);
      }
      if (obj.positions && typeof obj.positions === 'object') {
        state.positions = obj.positions;
      }
      if (obj.widths && typeof obj.widths === 'object') {
        if (isFinite(obj.widths.title)) state.widths.title = Math.max(560, Math.min(1200, Number(obj.widths.title)));
        if (isFinite(obj.widths.top)) state.widths.top = Math.max(560, Math.min(1200, Number(obj.widths.top)));
        if (isFinite(obj.widths.bottom)) state.widths.bottom = Math.max(560, Math.min(1200, Number(obj.widths.bottom)));
        if (!isFinite(obj.widths.top) && isFinite(obj.widths.bottom)) {
          state.widths.top = state.widths.bottom;
        }
      }
      if (typeof obj.bottomAutoHide === 'boolean') {
        state.bottomAutoHide = obj.bottomAutoHide;
      }
      if (obj.display && typeof obj.display === 'object') {
        for (let i = 0; i < DISPLAY_FIELDS.length; i++) {
          const id = DISPLAY_FIELDS[i].id;
          if (typeof obj.display[id] === 'boolean') state.display[id] = obj.display[id];
        }
      }
      if (obj.fontSize) {
        for (let i = 0; i < FONT_SIZES.length; i++) {
          if (FONT_SIZES[i].id === obj.fontSize) state.fontSize = obj.fontSize;
        }
      }
      if (obj.tokenUnit) {
        for (let i = 0; i < TOKEN_UNITS.length; i++) {
          if (TOKEN_UNITS[i].id === obj.tokenUnit) state.tokenUnit = obj.tokenUnit;
        }
      }
      if (obj.statsMode) {
        for (let i = 0; i < STATS_MODES.length; i++) {
          if (STATS_MODES[i].id === obj.statsMode) state.statsMode = obj.statsMode;
        }
      }
      if (obj.statsRange) {
        for (let i = 0; i < STATS_RANGES.length; i++) {
          if (STATS_RANGES[i].id === obj.statsRange) state.statsRange = obj.statsRange;
        }
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
      display: state.display,
      fontSize: state.fontSize,
      tokenUnit: state.tokenUnit,
      statsMode: state.statsMode,
      statsRange: state.statsRange,
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

function readQoderWindowBounds() {
  try {
    const ref = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID);
    if (!ref) return null;
    const arr = ObjC.castRefToObject(ref);
    let best = null;
    for (let i = 0; i < arr.count; i++) {
      const d = arr.objectAtIndex(i);
      const owner = String(ObjC.unwrap(d.objectForKey('kCGWindowOwnerName')) || '');
      if (owner !== 'Qoder') continue;
      const layer = Number(ObjC.unwrap(d.objectForKey('kCGWindowLayer')) || 0);
      if (layer !== 0) continue;
      const alpha = Number(ObjC.unwrap(d.objectForKey('kCGWindowAlpha')) || 0);
      if (alpha <= 0) continue;
      const u = ObjC.unwrap(d.objectForKey('kCGWindowBounds'));
      if (!u) continue;
      const x = Number(ObjC.unwrap(u.X));
      const y = Number(ObjC.unwrap(u.Y));
      const width = Number(ObjC.unwrap(u.Width));
      const height = Number(ObjC.unwrap(u.Height));
      if (!isFinite(x) || !isFinite(y) || width < 320 || height < 240) continue;
      if (!best || width * height > best.width * best.height) {
        best = { x: x, y: y, width: width, height: height };
      }
    }
    return best;
  } catch (e) {
    return null;
  }
}

/* ------------------------------------------------------------ daily stats */

function normalizeModelKey(name) {
  let key = String(name || '').trim();
  if (!key) return 'unknown';
  const slash = key.lastIndexOf('/');
  if (slash >= 0) key = key.slice(slash + 1);
  return key.toLowerCase().replace(/^qoder[-_]/, '');
}

function friendlyModelName(name) {
  const raw = String(name || '').trim();
  if (!raw) return '未知模型';
  const key = normalizeModelKey(raw);
  if (MODEL_LABEL_MAP[key]) return MODEL_LABEL_MAP[key];
  if (key === 'unknown' || key === 'none') return '未知模型';
  return raw.replace(/_/g, '-');
}

function loadModelLabels() {
  try {
    let appPath = '/Applications/Qoder.app';
    try {
      const url = $.NSWorkspace.sharedWorkspace
        .URLForApplicationWithBundleIdentifier('com.qoder.app');
      if (url && !url.isNil() && url.path && !url.path.isNil()) appPath = url.path.js;
    } catch (e) {}
    const candidates = [
      appPath + '/Contents/Resources/dynamic-text/qoder.json',
      '/Applications/Qoder.app/Contents/Resources/dynamic-text/qoder.json'
    ];
    for (let i = 0; i < candidates.length; i++) {
      const text = readString(candidates[i]);
      if (!text) continue;
      const doc = JSON.parse(text);
      if (!doc || typeof doc !== 'object') continue;
      const map = Object.assign({}, MODEL_LABELS);
      const locales = ['en', 'zh'];
      for (let l = 0; l < locales.length; l++) {
        const table = doc[locales[l]];
        if (!table || typeof table !== 'object') continue;
        const keys = Object.keys(table);
        for (let k = 0; k < keys.length; k++) {
          const m = keys[k].match(/^model\.([a-zA-Z0-9_]+)\.label$/);
          if (!m) continue;
          const label = String(table[keys[k]] || '').trim();
          if (label) map[m[1].toLowerCase()] = label;
        }
      }
      MODEL_LABEL_MAP = map;
      return;
    }
  } catch (e) {
    logError('loadModelLabels', e);
  }
}

const STATS_JQ = [
  'def txt: (.message.content // []) | map(if .type=="text" then (.text//"") elif .type=="thinking" then (.thinking//"") elif .type=="tool_use" then ((.input//{})|tostring) else "" end) | join("");',
  'select(.type=="assistant" and (.message.usage.credits? != null)) |',
  '[.timestamp, (.message.model//"unknown"), (.message.usage.credits//0),',
  '(.message.usage.input_tokens//0), (.message.usage.cache_read_input_tokens//0),',
  '(.message.usage.cache_creation_input_tokens//0), (.message.usage.output_tokens//0),',
  '((.message.usage.request_id)//""), (txt|length), (txt|[scan("\\\\p{Han}")]|length)] | @tsv'
].join(' ');

function pad2(n) {
  return n < 10 ? '0' + n : String(n);
}

function dateKey(d) {
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

function loadStatsCache() {
  try {
    const text = readString(STATS_CACHE_PATH);
    if (!text) return;
    const obj = JSON.parse(text);
    if (!obj || !obj.days || typeof obj.days !== 'object') return;
    const at = Number(obj.at) || 0;
    if (Date.now() - at > STATS_CACHE_MS) return;
    state.statsCache = { at: at, days: obj.days, rows: Number(obj.rows) || 0 };
  } catch (e) {}
}

function saveStatsCache(cache) {
  try {
    sh('/bin/mkdir -p ' + q(SETTINGS_DIR));
    const obj = { at: cache.at, rows: cache.rows, days: cache.days };
    const s = $.NSString.alloc.initWithString(JSON.stringify(obj));
    s.writeToFileAtomicallyEncodingError(STATS_CACHE_PATH, true, $.NSUTF8StringEncoding, null);
  } catch (e) {}
}

function collectDailyUsage(force) {
  const now = Date.now();
  if (!force && state.statsCache && now - state.statsCache.at < STATS_CACHE_MS) {
    return state.statsCache;
  }
  const fileText = sh('/usr/bin/find ' + q(PROJECTS_ROOT) + ' -type f -name "*.jsonl" 2>/dev/null').trim();
  const files = fileText ? fileText.split(/\r\n|\r|\n/).filter(Boolean) : [];
  const days = {};
  if (!files.length) {
    state.statsCache = { at: now, days: days, rows: 0 };
    return state.statsCache;
  }
  const cmd = '/usr/bin/jq -r ' + q(STATS_JQ) + ' ' + files.map(q).join(' ') + ' 2>/dev/null || true';
  const out = sh(cmd);
  const seen = {};
  let rows = 0;
  const lines = out ? out.split(/\r\n|\r|\n/) : [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const cols = line.split('\t');
    if (cols.length < 10) continue;
    const ts = cols[0];
    const model = cols[1] || 'unknown';
    const rid = cols[7] || '';
    if (rid) {
      if (seen[rid]) continue;
      seen[rid] = true;
    }
    const t = Date.parse(ts);
    if (!isFinite(t)) continue;
    const key = dateKey(new Date(t));
    const credits = Number(cols[2]) || 0;
    const exact = (Number(cols[3]) || 0) + (Number(cols[4]) || 0) +
      (Number(cols[5]) || 0) + (Number(cols[6]) || 0);
    const chars = Number(cols[8]) || 0;
    const cjk = Number(cols[9]) || 0;
    const estimated = exact > 0 ? 0 :
      Math.round(cjk / 1.35 + Math.max(0, chars - cjk) / 3.8);
    const tokens = exact > 0 ? exact : estimated;
    if (!days[key]) {
      days[key] = { credits: 0, tokens: 0, requests: 0, estimated: false, models: {} };
    }
    const day = days[key];
    day.credits += credits;
    day.tokens += tokens;
    day.requests++;
    if (estimated > 0) day.estimated = true;
    if (!day.models[model]) {
      day.models[model] = { credits: 0, tokens: 0, requests: 0, estimated: false };
    }
    const m = day.models[model];
    m.credits += credits;
    m.tokens += tokens;
    m.requests++;
    if (estimated > 0) m.estimated = true;
    rows++;
  }
  log('STATS files=' + files.length + ' rows=' + rows + ' out=' + (out ? out.length : 0) + ' days=' + Object.keys(days).length);
  state.statsCache = { at: now, days: days, rows: rows };
  saveStatsCache(state.statsCache);
  return state.statsCache;
}

function statsRangeStart(range) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  if (range === 'month') return new Date(today.getFullYear(), today.getMonth(), 1);
  const start = new Date(today.getTime());
  if (range === '30d') start.setDate(start.getDate() - 29);
  else if (range === 'year') start.setDate(start.getDate() - 364);
  else start.setDate(start.getDate() - 6);
  return start;
}

function statsForRange(range) {
  const cache = collectDailyUsage(false);
  const now = new Date();
  const todayKey = dateKey(now);
  const startKey = dateKey(statsRangeStart(range));
  const models = {};
  const dayList = [];
  let credits = 0;
  let tokens = 0;
  let requests = 0;
  let estimated = false;
  const keys = Object.keys(cache.days);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (key < startKey || key > todayKey) continue;
    const d = cache.days[key];
    credits += d.credits;
    tokens += d.tokens;
    requests += d.requests;
    if (d.estimated) estimated = true;
    const modelRows = [];
    const dayModels = {};
    const mnames = Object.keys(d.models);
    for (let j = 0; j < mnames.length; j++) {
      const name = mnames[j];
      const m = d.models[name];
      const display = friendlyModelName(name);
      if (!dayModels[display]) {
        dayModels[display] = { name: display, credits: 0, tokens: 0, estimated: false };
      }
      const dm = dayModels[display];
      dm.credits += m.credits;
      dm.tokens += m.tokens;
      if (m.estimated) dm.estimated = true;
      if (!models[display]) {
        models[display] = { name: display, credits: 0, tokens: 0, requests: 0, estimated: false };
      }
      models[display].credits += m.credits;
      models[display].tokens += m.tokens;
      models[display].requests += m.requests;
      if (m.estimated) models[display].estimated = true;
    }
    const dmNames = Object.keys(dayModels);
    for (let j = 0; j < dmNames.length; j++) modelRows.push(dayModels[dmNames[j]]);
    modelRows.sort(function (a, b) { return b.credits - a.credits || b.tokens - a.tokens; });
    dayList.push({ key: key, credits: d.credits, tokens: d.tokens, requests: d.requests,
      estimated: d.estimated, models: modelRows });
  }
  dayList.sort(function (a, b) { return b.key.localeCompare(a.key); });
  const modelList = Object.keys(models).map(function (k) { return models[k]; });
  modelList.sort(function (a, b) { return b.credits - a.credits || b.tokens - a.tokens; });
  return {
    range: range, credits: credits, tokens: tokens, requests: requests,
    estimated: estimated, activeDays: dayList.length,
    days: dayList, models: modelList
  };
}

function fmtStatsTokens(v) {
  if (!v || v <= 0) return '0';
  return fmtToken(v);
}

function dayLabel(key) {
  const today = dateKey(new Date());
  if (key === today) return '今天';
  return key.slice(5);
}

function scanRouteFile(path) {  try {
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
  dotHalo = null;
  statusPill = null;
  accentBar = null;
  gripBox = null;
  latencyPill = null;
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
  metricLabels = {};
  statsPillBox = null;
  statsIconView = null;
  statsButtonRect = null;
}

function makePanel(w, h) {
  if (panel) {
    try { panel.orderOut(null); } catch (e) {}
  }
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

  root.addSubview(box([14, H - 2, W - 28, 1], T.highlight, 0, 0, null));

  dotHalo = box([12, H - 29, 14, 14], T.grayTint, 7, 0, null);
  root.addSubview(dotHalo);
  dotBox = box([15.5, H - 25.5, 7, 7], T.gray, 3.5, 0, null);
  root.addSubview(dotBox);

  modelLabel = label('会话统计', [32, H - 31, 80, 16], 9.2, T.faint, $.NSFontWeightMedium, 0, true);
  root.addSubview(modelLabel);

  statusPill = box([W - 116, H - 33, 102, 20], T.grayTint, 10, 0, null);
  root.addSubview(statusPill);
  stateLabel = label('', [W - 114, H - 32, 98, 18], 9.2, T.faint, $.NSFontWeightMedium, 2);
  root.addSubview(stateLabel);

  titleLabel = label('', [14, H - 57, W - 28, 22], 14.2, T.text, $.NSFontWeightSemibold, 0, true);
  root.addSubview(titleLabel);

  root.addSubview(label('本轮 TPS', [14, H - 77, 90, 14], 9.2, T.faint, $.NSFontWeightRegular));
  tpsValue = label('—', [13, H - 115, 110, 38], 30, T.green, $.NSFontWeightSemibold);
  root.addSubview(tpsValue);
  root.addSubview(label('tok/s', [84, H - 107, 40, 14], 9.2, T.faint, $.NSFontWeightRegular));

  root.addSubview(box([126, H - 121, 102, 1], T.divider, 0, 0, null));
  sparkBars = [];
  for (let i = 0; i < 14; i++) {
    const b = box([128 + i * 7, H - 119, 4.2, 1], T.track, 2.1, 0, null);
    root.addSubview(b);
    sparkBars.push(b);
  }

  root.addSubview(box([14, H - 129, W - 28, 1], T.divider, 0, 0, null));
  root.addSubview(box([122, 18, 1, 64], T.divider, 0, 0, null));

  root.addSubview(label('本轮', [14, H - 149, 90, 13], 9.2, T.faint, $.NSFontWeightRegular));
  turnValue = label('—', [14, H - 168, 100, 18], 13, T.text, $.NSFontWeightMedium);
  root.addSubview(turnValue);

  root.addSubview(label('总计', [130, H - 149, 90, 13], 9.2, T.faint, $.NSFontWeightRegular));
  sessionAgeValue = label('—', [130, H - 168, W - 146, 18], 13, T.text, $.NSFontWeightMedium);
  root.addSubview(sessionAgeValue);

  root.addSubview(label('Token', [14, H - 183, 70, 13], 9.2, T.faint, $.NSFontWeightRegular));
  outValue = label('—', [14, H - 201, 100, 18], 13, T.text, $.NSFontWeightMedium);
  root.addSubview(outValue);

  root.addSubview(label('积分', [130, H - 183, 70, 13], 9.2, T.faint, $.NSFontWeightRegular));
  creditsValue = label('0.00', [130, H - 201, W - 146, 18], 13, T.gold, $.NSFontWeightSemibold);
  root.addSubview(creditsValue);

  requestValue = label('', [14, 4, W - 78, 14], 9.2, T.faint, $.NSFontWeightRegular, 0, true);
  root.addSubview(requestValue);

  gripBox = box([W / 2 - 14, H - 5, 28, 3], T.track, 1.5, 0, null);
  root.addSubview(gripBox);

  addStatsButton(root, W - 58, 3, 13, T.gray);
  addGearButton(root, W - 30, 3, 13, T.gray);
}

// AppKit points match Windows DIPs: a 1pt rule with 4pt padding on each side.
// Keep the reserved span and the rendered geometry together (only height scales).
function barSeparatorGeometry(S) {
  const width = 1;
  const padding = 4;
  return { width: width, padding: padding, span: width + padding * 2, height: 12 * S };
}

function barMetricParts(turnText, ageText, outText, creditsText, requestsText, toolsText) {
  return [
    { id: 'turn', parts: [['本轮 ', 'faint'], [turnText, 'text', true]] },
    { id: 'age', parts: [['总计 ', 'faint'], [ageText, 'text', true]] },
    { id: 'token', parts: [['Token ', 'faint'], [outText, 'soft', true]] },
    { id: 'credits', parts: [['积分 ', 'faint'], [creditsText, 'gold', true]] },
    { id: 'requests', parts: [[requestsText + ' 请求', 'soft']] },
    { id: 'tools', parts: [['工具 ' + toolsText, 'soft']] }
  ];
}

function metricSampleFields(regFont, medFont) {
  return barMetricParts('88m 88s', '888h 88m', tokenUnitSample(), '888.88', '8888', '8.8k')
    .filter(function (field) { return !!state.display[field.id]; })
    .map(function (field) {
      // NSTextField has a 2pt text inset at either end. Separators stay outside it.
      let w = 4;
      field.parts.forEach(function (part) { w += textWidth(part[0], part[2] ? medFont : regFont); });
      return { id: field.id, w: Math.ceil(w), metric: true };
    });
}

function computeBarLayout(mode) {
  const S = fontScale();
  const H = mode === 'title' ? BAR_H_TITLE : (mode === 'top' ? BAR_H_TOP : BAR_H_BOTTOM);
  const titleFont = $.NSFont.systemFontOfSizeWeight(11.5 * S, $.NSFontWeightMedium);
  const tpsLabelFont = $.NSFont.systemFontOfSizeWeight(8.8 * S, $.NSFontWeightRegular);
  const tpsValueFont = $.NSFont.monospacedDigitSystemFontOfSizeWeight(15 * S, $.NSFontWeightSemibold);
  const metricsSize = (mode === 'title' ? 9.5 : 10) * S;
  const metricsReg = $.NSFont.monospacedDigitSystemFontOfSizeWeight(metricsSize, $.NSFontWeightRegular);
  const metricsMed = $.NSFont.monospacedDigitSystemFontOfSizeWeight(metricsSize, $.NSFontWeightMedium);
  const pillSize = 9.3 * S;
  const pillFont = $.NSFont.systemFontOfSizeWeight(pillSize, $.NSFontWeightRegular);
  const padL = Math.round(10 * S);
  const dotHalo = Math.round(14 * S);
  const dotGap = Math.round(7 * S);
  const separator = barSeparatorGeometry(S);
  const pillGap = Math.round(8 * S);
  const rightPad = Math.round(9 * S);
  const gearSize = Math.max(11, Math.round(13 * S));
  const gearPill = gearSize + 6;
  const statsGap = Math.round(4 * S);
  const statsSize = gearSize;
  const statsPill = gearPill;
  const pillH = Math.round(20 * S);
  const pillPad = Math.round(8 * S);
  const baseY = Math.round((H - 16 * S) / 2);

  const tpsLabelW = textWidth('TPS', tpsLabelFont) + Math.round(4 * S);
  const tpsValueW = Math.max(Math.round(46 * S), textWidth('888.8', tpsValueFont));
  const tpsGap = Math.round(3 * S);
  const tpsBlock = tpsLabelW + tpsGap + tpsValueW;

  const latencyTextW = textWidth('延迟 88.8s', pillFont);
  const statusTextW = textWidth('生成中 88.8s', pillFont);
  const latencyPillW = latencyTextW + pillPad * 2;
  const statusPillW = statusTextW + pillPad * 2;
  let fields = [];
  if (mode !== 'title' && state.display.title) fields.push({ id: 'title', w: Math.round(160 * S) });
  if (state.display.tps) fields.push({ id: 'tps', w: tpsBlock });
  fields = fields.concat(metricSampleFields(metricsReg, metricsMed));
  if (state.display.latency) fields.push({ id: 'latency', w: latencyPillW, pill: true });
  if (state.display.status) fields.push({ id: 'status', w: statusPillW, pill: true });

  const fieldsWidth = function () {
    return fields.reduce(function (sum, field) { return sum + field.w; }, 0) +
      Math.max(0, fields.length - 1) * separator.span;
  };
  const left = padL + dotHalo + dotGap;
  const right = statsPill + statsGap + gearPill + rightPad;
  let W = left + fieldsWidth() + (fields.length ? pillGap : 0) + right;

  const b = state.windowBounds;
  let maxW;
  if (mode === 'title' || (mode === 'top' && state.topInline)) {
    maxW = b && b.width ? Math.max(Math.round(320 * S), Math.round(b.width - 360)) :
      Math.round(900 * S);
  } else {
    const sw = Number($.NSScreen.mainScreen.frame.size.width);
    maxW = Math.max(Math.round(320 * S), sw - 16);
  }
  W = Math.max(Math.round(220 * S), Math.round(Math.min(W, maxW)));

  const gearX = W - rightPad - gearPill;
  const statsX = gearX - statsGap - statsPill;
  const budget = Math.max(0, statsX - pillGap - left);
  // Preserve the existing left/title/TPS and right/pill priorities. Omit complete
  // metric fields from the end, rather than clipping through a separator. Only
  // sacrifice fixed fields when even they cannot fit in a narrow inline bar.
  const trimOrder = ['tools', 'requests', 'credits', 'token', 'age', 'turn',
    'title', 'tps', 'latency', 'status'];
  for (let i = 0; i < trimOrder.length && fieldsWidth() > budget; i++) {
    const index = fields.findIndex(function (field) { return field.id === trimOrder[i]; });
    if (index < 0) continue;
    if (trimOrder[i] === 'title') {
      fields[index].w = Math.max(Math.round(48 * S), fields[index].w - (fieldsWidth() - budget));
      if (fieldsWidth() <= budget) break;
    }
    fields.splice(index, 1);
  }

  let cursor = left;
  let pillCursor = statsX - pillGap;
  for (let i = fields.length - 1; i >= 0; i--) {
    if (!fields[i].pill) continue;
    fields[i].x = pillCursor - fields[i].w;
    pillCursor = fields[i].x - separator.span;
  }
  fields.forEach(function (field) {
    if (field.pill) return;
    field.x = cursor;
    cursor += field.w + separator.span;
  });
  const get = function (id) {
    return fields.filter(function (field) { return field.id === id; })[0];
  };
  const title = get('title');
  const tps = get('tps');
  const latency = get('latency');
  const status = get('status');
  const metrics = fields.filter(function (field) { return field.metric; });
  // Only adjacent, actually rendered logical fields get a rule. The activity
  // dot and action buttons are not fields; never leave a rule at either end.
  const separators = fields.slice(1).map(function (field) {
    return { x: field.x - separator.padding - separator.width,
      y: (H - separator.height) / 2, w: separator.width, h: separator.height };
  });

  return {
    S, W, H, baseY, fields, separator, separators, metrics,
    titleFont, tpsLabelFont, tpsValueFont, metricsSize, metricsReg, metricsMed,
    pillFont, pillSize, pillH, pillPad,
    padL, dotX: padL, dotHalo, dotGap,
    showTitle: !!title, titleX: title ? title.x : 0, titleW: title ? title.w : 0,
    showTps: !!tps, tpsLabelX: tps ? tps.x : 0,
    tpsValueX: tps ? tps.x + tpsLabelW + tpsGap : 0, tpsLabelW, tpsValueW,
    showMetrics: metrics.length > 0,
    showLatency: !!latency, latencyPillX: latency ? latency.x : 0, latencyPillW, latencyTextW,
    showStatus: !!status, statusPillX: status ? status.x : 0, statusPillW, statusTextW,
    statsX, statsSize, statsPill,
    gearX, gearSize, gearPill
  };
}

function buildBar(root, mode, L) {
  const S = L.S;
  const W = L.W;
  const H = L.H;
  const dotInset = Math.round((L.dotHalo - 8 * S) / 2);

  accentBar = box([L.padL, H - 4, Math.max(1, W - L.padL * 2), 2], T.track, 1, 0, null);
  root.addSubview(accentBar);

  dotHalo = box([L.dotX, Math.round((H - L.dotHalo) / 2), L.dotHalo, L.dotHalo],
    T.grayTint, L.dotHalo / 2, 0, null);
  root.addSubview(dotHalo);
  dotBox = box([L.dotX + dotInset, Math.round((H - 8 * S) / 2), Math.round(8 * S),
    Math.round(8 * S)], T.gray, (8 * S) / 2, 0, null);
  root.addSubview(dotBox);

  if (L.showTitle) {
    titleLabel = label('', [L.titleX, L.baseY, L.titleW, Math.round(16 * S)],
      11.5 * S, T.text, $.NSFontWeightMedium, 0, true);
    root.addSubview(titleLabel);
  }

  if (L.showTps) {
    root.addSubview(label('TPS', [L.tpsLabelX, L.baseY + Math.round(2 * S),
      L.tpsLabelW, Math.round(11 * S)], 8.8 * S, T.faint, $.NSFontWeightRegular));
    tpsValue = label('—', [L.tpsValueX, L.baseY - Math.round(4 * S), L.tpsValueW,
      Math.round(20 * S)], 15 * S, T.green, $.NSFontWeightSemibold);
    root.addSubview(tpsValue);
  }

  L.metrics.forEach(function (field) {
    const view = label('', [field.x, L.baseY, field.w, Math.round(16 * S)],
      L.metricsSize, T.soft, $.NSFontWeightRegular, 0, true);
    metricLabels[field.id] = view;
    root.addSubview(view);
  });

  const pillY = Math.round((H - L.pillH) / 2);
  if (L.showLatency) {
    latencyPill = box([L.latencyPillX, pillY, L.latencyPillW, L.pillH],
      T.grayTint, L.pillH / 2, 0, null);
    root.addSubview(latencyPill);
    latencyValue = label('延迟 —', [L.latencyPillX + L.pillPad, L.baseY + Math.round(S),
      L.latencyTextW, Math.round(15 * S)], L.pillSize, T.gray, $.NSFontWeightRegular, 2);
    root.addSubview(latencyValue);
  }

  if (L.showStatus) {
    statusPill = box([L.statusPillX, pillY, L.statusPillW, L.pillH],
      T.grayTint, L.pillH / 2, 0, null);
    root.addSubview(statusPill);
    stateLabel = label('', [L.statusPillX + L.pillPad, L.baseY + Math.round(S),
      L.statusTextW, Math.round(15 * S)], L.pillSize, T.faint, $.NSFontWeightMedium, 2);
    root.addSubview(stateLabel);
  }

  L.separators.forEach(function (line) {
    root.addSubview(box([line.x, line.y, line.w, line.h],
      T.gray.colorWithAlphaComponent(0.35), 0, 0, null));
  });
  setBarMetrics(L, '—', '—', '—', 0, 0, 0);
  addStatsButton(root, L.statsX, Math.round((H - L.statsPill) / 2), L.statsSize, T.gray);
  addGearButton(root, L.gearX, Math.round((H - L.gearPill) / 2), L.gearSize, T.gray);
}

function buildIndicator(w) {
  if (indicatorPanel) {
    indicatorPanel.orderOut(null);
    indicatorPanel = null;
  }
  indicatorPanel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, w, 4), 128, $.NSBackingStoreBuffered, false);
  indicatorPanel.setLevel(3);
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
  const isTop = state.layout === 'top';
  const inline = isTitle || (isTop && state.topInline);
  let w;
  let h;
  let barLayout = null;
  if (isCard) {
    w = CARD_W;
    h = CARD_H;
    state.barLayout = null;
  } else {
    barLayout = computeBarLayout(inline ? 'title' : state.layout);
    state.barLayout = barLayout;
    w = barLayout.W;
    h = barLayout.H;
  }
  const root = makePanel(w, h);
  panel.setHasShadow(true);

  bgBox = box([0, 0, w, h], T.bg, isCard ? 14 : 12, 1, T.border);
  root.addSubview(bgBox);

  if (isCard) buildSidebar(root);
  else buildBar(root, inline ? 'title' : state.layout, barLayout);

  const dragHeight = isCard ? 64 : (inline ? h : 0);
  if (dragHeight > 0) {
    const dragWidth = inline
      ? Math.max(0, (barLayout ? barLayout.statsX - 2 : w - 62))
      : w;
    dragView = $.MeterDragView.alloc.initWithFrame($.NSMakeRect(0, h - dragHeight, dragWidth, dragHeight));
    root.addSubview(dragView);
  }

  if (indicatorPanel) {
    indicatorPanel.orderOut(null);
    indicatorPanel = null;
  }
  if (state.layout === 'bottom' || state.layout === 'top') {
    buildIndicator(w);
  }

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

function addGearButton(root, x, y, size, tint) {
  const pillSize = size + 6;
  root.addSubview(box([x, y, pillSize, pillSize], T.grayTint, pillSize / 2, 0, null));
  const iconX = x + (pillSize - size) / 2;
  const iconY = y + (pillSize - size) / 2;
  const img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('gearshape', '设置');
  const icon = $.NSImageView.alloc.initWithFrame($.NSMakeRect(iconX, iconY, size, size));
  if (img && !img.isNil()) {
    icon.setImage(img);
    try { icon.setContentTintColor(tint || T.gray); } catch (e) {}
  }
  root.addSubview(icon);
  const button = $.NSButton.alloc.initWithFrame($.NSMakeRect(x - 2, y - 2, pillSize + 4, pillSize + 4));
  button.setBordered(false);
  button.setTitle('');
  button.setTarget(controller);
  button.setAction('openSettings:');
  try { button.setToolTip('设置'); } catch (e) {}
  root.addSubview(button);
}

function addStatsButton(root, x, y, size, tint) {
  const pillSize = size + 6;
  const active = !!(state.statsPinned || state.statsHover);
  const pill = box([x, y, pillSize, pillSize],
    active ? T.greenTint : T.grayTint, pillSize / 2, 0, null);
  statsPillBox = pill;
  root.addSubview(pill);
  const iconX = x + (pillSize - size) / 2;
  const iconY = y + (pillSize - size) / 2;
  const img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('chart.bar.xaxis', '用量统计');
  const icon = $.NSImageView.alloc.initWithFrame($.NSMakeRect(iconX, iconY, size, size));
  if (img && !img.isNil()) {
    icon.setImage(img);
    try { icon.setContentTintColor(active ? T.green : (tint || T.gray)); } catch (e) {}
  }
  statsIconView = icon;
  root.addSubview(icon);
  const button = $.NSButton.alloc.initWithFrame($.NSMakeRect(x - 2, y - 2, pillSize + 4, pillSize + 4));
  button.setBordered(false);
  button.setTitle('');
  button.setTarget(controller);
  button.setAction('toggleStatsPopover:');
  try { button.setToolTip('用量统计'); } catch (e) {}
  root.addSubview(button);
  statsButtonRect = { x: x, y: y, w: pillSize, h: pillSize };
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
    const h = v > 0 ? Math.max(3, Math.min(26, 4 + (v / max) * 22)) : 1;
    const b = sparkBars[i];
    setBoxFrame(b, 128 + i * 7, CARD_H - 119, 4.2, h);
    b.setFillColor(v > 0 ? (i === n - 1 ? T.green : T.greenDim) : T.track);
  }
}

function setBarMetrics(L, turnText, ageText, outText, credits, requests, tools) {
  if (!L) return;
  barMetricParts(turnText, ageText, outText, fmtCredits(credits), fmtCount(requests), fmtCount(tools))
    .forEach(function (field) {
      const view = metricLabels[field.id];
      if (!view) return; // Disabled or trimmed fields have neither a view nor a rule.
      const text = $.NSMutableAttributedString.alloc.init;
      field.parts.forEach(function (part) {
        const seg = $.NSMutableAttributedString.alloc.init;
        seg.mutableString.setString(part[0]);
        const range = $.NSMakeRange(0, part[0].length);
        seg.addAttributeValueRange($.NSForegroundColorAttributeName, T[part[1]], range);
        seg.addAttributeValueRange($.NSFontAttributeName, part[2] ? L.metricsMed : L.metricsReg, range);
        text.appendAttributedString(seg);
      });
      view.setAttributedStringValue(text);
    });
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
  const outText = state.exactOut > 0 ? fmtToken(state.exactOut)
    : (state.estOut > 0 ? '≈ ' + fmtToken(state.estOut) : '—');
  const latencyText = state.lastLatency ? fmtElapsed(state.lastLatency) : '—';

  if (titleLabel) {
    setText(titleLabel, hasSession ? truncate(state.title || '未命名会话', 60) : '等待 Qoder 会话');
  }
  if (modelLabel) {
    setText(modelLabel, '会话统计');
  }

  if (state.layout === 'sidebar') {
    setText(tpsValue, tpsText);
    setText(turnValue, turnText);
    setText(sessionAgeValue, ageText);
    setText(outValue, outText);
    setText(creditsValue, fmtCredits(state.credits));
    setText(requestValue, '延迟 ' + latencyText + ' · ' + fmtCount(requestCount) +
      ' 请求 · ' + fmtCount(toolCount) + ' 工具');
    updateSparkline();
  } else {
    if (tpsValue) setText(tpsValue, tpsText);
    setBarMetrics(state.barLayout, turnText, ageText, outText,
      state.credits, requestCount, toolCount);
    if (latencyValue) {
      setText(latencyValue, '延迟 ' + latencyText);
      setColor(latencyValue, state.lastLatency ? T.gray : T.faint);
      if (latencyPill) latencyPill.setFillColor(state.lastLatency ? T.grayTint : T.track);
    }
  }

  const statusColor = state.inFlight ? T.green : (active ? T.gold : T.gray);
  const statusTint = state.inFlight ? T.greenTint : (active ? T.goldTint : T.grayTint);
  if (dotHalo) dotHalo.setFillColor(statusTint);
  if (dotBox) dotBox.setFillColor(statusColor);
  if (statusPill) statusPill.setFillColor(statusTint);
  if (accentBar) accentBar.setFillColor(state.inFlight ? T.green : (active ? T.gold : T.track));
  if (gripBox) gripBox.setFillColor(state.inFlight ? T.green : (active ? T.gold : T.track));
  if (stateLabel) {
    setText(stateLabel, state.inFlight ? ('生成中 ' + fmtElapsed(state.inFlightElapsed))
      : (active ? '本轮中' : (hasSession ? '空闲' : '')));
    setColor(stateLabel, state.inFlight ? T.green : (active ? T.gold : T.faint));
  }
  if (tpsValue) {
    setColor(tpsValue, state.inFlight ? T.green : (state.tps ? T.greenDim : T.faint));
  }

  const exactNote = state.exactOut > 0 ? 'Token 精确值'
    : 'Token 按字符估算（模型未返回精确值），积分来自 Qoder 本地账单';
  const tooltip = hasSession ? (
    '会话：' + (state.title || '') + '\n' +
    '模型：' + (state.model ? friendlyModelName(state.model) : '—') + '\n' +
    '本轮 TPS：' + tpsText + (state.tps ? '（模型调用平均，含思考/工具参数）' : '') + '\n' +
    '本轮时长：' + turnText + '\n' +
    '会话总时长：' + ageText + '（自会话创建）\n' +
    '本轮模型耗时：' + fmtDuration(state.turnDuration) + '\n' +
    '本轮输出：' + (state.turnTokens ? '≈ ' + fmtToken(state.turnTokens) + ' tok' : '—') + '\n' +
    '会话输出：' + (state.exactOut > 0 ? fmtToken(state.exactOut) : '≈ ' + fmtToken(state.estOut)) + ' tok\n' +
    (state.inputTokens > 0 ? '输入 Token：' + fmtToken(state.inputTokens) + '\n' : '') +
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
      if (titleLabel) titleLabel.setToolTip(tooltip);
      if (bgBox) bgBox.setToolTip(tooltip);
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
  const topInset = Math.max(0, Math.round(sh - (Number(screen.visibleFrame.origin.y) +
    Number(screen.visibleFrame.size.height))));
  const bottom = sh - (b.y + b.height);
  const isCard = state.layout === 'sidebar';
  const isTitle = state.layout === 'title';
  const isTop = state.layout === 'top';
  const isBottom = state.layout === 'bottom';
  if (!isBottom) state.bottomOutside = false;
  const isFullscreen = b.x <= 1 && b.y <= 1 && b.width >= sw - 2 && b.height >= sh - 2;
  state.qoderFullscreen = isFullscreen;
  const roomAbove = (b.y - BAR_H_TOP - 4) >= 34;
  if (isTop) {
    const wantInline = !isFullscreen && !roomAbove;
    if (wantInline !== state.topInline) {
      state.topInline = wantInline;
      state.lastX = null;
      state.lastY = null;
      rebuildPanelUI();
      return;
    }
  }
  const inline = isTitle || (isTop && state.topInline);
  const pf = panel.frame;
  const w = Number(pf.size.width);
  const h = Number(pf.size.height);
  if (!isTop) state.topRevealed = false;

  const saved = state.positions[state.layout];
  const hasSaved = !!(saved && isFinite(saved.dx) && isFinite(saved.dy));
  let x;
  let y;

  if (isTitle) {
    x = b.x + (hasSaved ? Number(saved.dx) : (b.width - w - 12));
    y = bottom + b.height - h - 3;
  } else if (isTop) {
    if (isFullscreen) {
      x = b.x + Math.round((b.width - w) / 2);
      y = sh - topInset - h - 4;
    } else if (inline) {
      state.topRevealed = false;
      x = b.x + (hasSaved ? Number(saved.dx) : (b.width - w - 12));
      y = bottom + b.height - h - 3;
    } else {
      x = b.x + 8;
      y = bottom + b.height + 4;
    }
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
  const indicatorY = isTop ? (sh - topInset - 4) : bottom;
  if (state.lastX === x && state.lastY === y) {
    if (indicatorPanel) indicatorPanel.setFrameOrigin($.NSMakePoint(x, indicatorY));
    return;
  }
  state.lastX = x;
  state.lastY = y;

  panel.setFrameOrigin($.NSMakePoint(x, y));
  if (indicatorPanel) indicatorPanel.setFrameOrigin($.NSMakePoint(x, indicatorY));
}

function updateTopHover() {
  if (state.layout !== 'top' || !state.qoderFullscreen || !state.windowBounds) {
    if (state.topRevealed) state.topRevealed = false;
    return;
  }
  try {
    const b = state.windowBounds;
    const screen = $.NSScreen.mainScreen;
    const sw = Number(screen.frame.size.width);
    const sh = Number(screen.frame.size.height);
    const topInset = Math.max(0, Math.round(sh - (Number(screen.visibleFrame.origin.y) +
      Number(screen.visibleFrame.size.height))));
    const w = panel ? Number(panel.frame.size.width) : state.widths.top;
    const h = BAR_H_TOP;
    let x = b.x + Math.round((b.width - w) / 2);
    if (x + w > sw - 8) x = Math.max(8, sw - w - 8);
    if (x < 8) x = 8;
    const m = $.NSEvent.mouseLocation;
    const hover = state.topRevealed
      ? (m.x >= x - 12 && m.x <= x + w + 12 &&
         m.y >= sh - topInset - h - 18 && m.y <= sh - topInset + 8)
      : (m.x >= x - 12 && m.x <= x + w + 12 &&
         m.y >= sh - topInset - 10 && m.y <= sh - topInset + 8);
    if (hover) {
      state.topRevealed = true;
      state.topHoverAt = Date.now();
    } else if (state.topRevealed && Date.now() - state.topHoverAt > 1500) {
      state.topRevealed = false;
    }
  } catch (e) {}
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
  const frontIsQoder = bid === 'com.qoder.app';
  state.frontIsQoder = frontIsQoder;
  if (frontIsQoder) state.lastQoderFrontAt = Date.now();
  const show = !state.panelHidden && state.qoderRunning && frontIsQoder;
  const topCollapsed = state.layout === 'top' && state.qoderFullscreen && !state.topRevealed;
  const bottomCollapsed = state.layout === 'bottom' && !state.bottomOutside &&
    (state.bottomAutoHide || state.qoderFullscreen) && !state.bottomRevealed;
  const collapsed = topCollapsed || bottomCollapsed;

  if (!show) {
    if (panel.isVisible) panel.orderOut(null);
    if (indicatorPanel && indicatorPanel.isVisible) indicatorPanel.orderOut(null);
    return;
  }

  if (collapsed) {
    if (panel.isVisible) panel.orderOut(null);
    if (indicatorPanel && !indicatorPanel.isVisible) indicatorPanel.orderFront(null);
  } else {
    if (!panel.isVisible) panel.orderFront(null);
    if (indicatorPanel && indicatorPanel.isVisible) indicatorPanel.orderOut(null);
  }
}

function updateBottomHover() {
  const autoHide = state.bottomAutoHide || state.qoderFullscreen;
  if (state.layout !== 'bottom' || state.bottomOutside || !autoHide || !state.windowBounds) {
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
    const w = panel ? Number(panel.frame.size.width) : state.widths.bottom;
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

function representedId(sender) {
  try {
    const ro = sender.representedObject;
    return (ro && ro.js !== undefined) ? String(ro.js) : String(ro || '');
  } catch (e) {
    return '';
  }
}

function buildMenu() {
  const menu = $.NSMenu.alloc.initWithTitle('Qoder Meter');
  menu.setAutoenablesItems(false);

  menu.addItem(menuItem('设置…', 'openSettings:', null, null));
  menu.addItem(menuItem('用量统计…', 'openStats:', null, null));
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
  posMenu.addItem(menuItem('窗口上方（贴外）', 'layoutTop:', state.layout === 'top', null));
  posMenu.addItem(menuItem('窗口下方（贴外）', 'layoutBottom:', state.layout === 'bottom', null));
  posMenu.addItem($.NSMenuItem.separatorItem);
  posMenu.addItem(menuItem('重置当前位置', 'resetPosition:', null, null));
  const posItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('显示位置', '', '');
  posItem.setSubmenu(posMenu);
  menu.addItem(posItem);

  const displayMenu = $.NSMenu.alloc.initWithTitle('显示内容');
  displayMenu.setAutoenablesItems(false);
  for (let i = 0; i < DISPLAY_FIELDS.length; i++) {
    const field = DISPLAY_FIELDS[i];
    displayMenu.addItem(menuItem(field.label, 'toggleDisplay:', !!state.display[field.id], field.id));
  }
  const displayItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('显示内容', '', '');
  displayItem.setSubmenu(displayMenu);
  menu.addItem(displayItem);

  const fontMenu = $.NSMenu.alloc.initWithTitle('字号');
  fontMenu.setAutoenablesItems(false);
  for (let i = 0; i < FONT_SIZES.length; i++) {
    fontMenu.addItem(menuItem(FONT_SIZES[i].label, 'fontSizeMenu:',
      state.fontSize === FONT_SIZES[i].id, FONT_SIZES[i].id));
  }
  const fontItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('字号', '', '');
  fontItem.setSubmenu(fontMenu);
  menu.addItem(fontItem);

  const tokenUnitMenu = $.NSMenu.alloc.initWithTitle('Token 单位');
  tokenUnitMenu.setAutoenablesItems(false);
  for (let i = 0; i < TOKEN_UNITS.length; i++) {
    tokenUnitMenu.addItem(menuItem(TOKEN_UNITS[i].label, 'tokenUnitMenu:',
      state.tokenUnit === TOKEN_UNITS[i].id, TOKEN_UNITS[i].id));
  }
  const tokenUnitItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('Token 单位', '', '');
  tokenUnitItem.setSubmenu(tokenUnitMenu);
  menu.addItem(tokenUnitItem);

  const statsModeMenu = $.NSMenu.alloc.initWithTitle('统计显示');
  statsModeMenu.setAutoenablesItems(false);
  for (let i = 0; i < STATS_MODES.length; i++) {
    statsModeMenu.addItem(menuItem(STATS_MODES[i].label, 'statsModeMenu:',
      state.statsMode === STATS_MODES[i].id, STATS_MODES[i].id));
  }
  const statsModeItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('统计显示', '', '');
  statsModeItem.setSubmenu(statsModeMenu);
  menu.addItem(statsModeItem);

  const themeMenu = $.NSMenu.alloc.initWithTitle('外观');
  themeMenu.setAutoenablesItems(false);
  themeMenu.addItem(menuItem('自动（跟随 Qoder）', 'themeAuto:', state.theme === 'auto', null));
  themeMenu.addItem(menuItem('纸白', 'themePaper:', state.theme === 'paper', null));
  themeMenu.addItem(menuItem('石墨', 'themeGraphite:', state.theme === 'graphite', null));
  themeMenu.addItem(menuItem('海盐', 'themeOcean:', state.theme === 'ocean', null));
  themeMenu.addItem(menuItem('暮色', 'themeDusk:', state.theme === 'dusk', null));
  themeMenu.addItem(menuItem('暖砂', 'themeSand:', state.theme === 'sand', null));
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
    state.fontSize + '#' + state.tokenUnit + '#' + JSON.stringify(state.display) + '#' +
    state.statsMode + '#' + state.statsRange + '#' + (state.statsHidden ? 1 : 0) + '#' +
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

function sLabel(str, frame, size, weight, color, align) {
  const f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  f.setStringValue(str);
  f.setBezeled(false);
  f.setDrawsBackground(false);
  f.setEditable(false);
  f.setSelectable(false);
  f.setFont($.NSFont.systemFontOfSizeWeight(size || 11,
    weight === undefined ? $.NSFontWeightRegular : weight));
  f.setTextColor(color || $.NSColor.labelColor);
  if (align !== undefined) f.setAlignment(align);
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

function sFieldCheckbox(title, frame, index, checked) {
  const b = sCheckbox(title, frame, 'settingsToggleField:', checked);
  b.setFont($.NSFont.systemFontOfSize(12));
  b.setTag(index);
  return b;
}

function sPopup(items, selected, frame, action) {
  const p = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]), false);
  for (let i = 0; i < items.length; i++) p.addItemWithTitle(items[i]);
  p.selectItemAtIndex(selected || 0);
  p.setFont($.NSFont.systemFontOfSize(12));
  p.setTarget(controller);
  p.setAction(action);
  return p;
}

function sButton(title, frame, action, key) {
  const b = $.NSButton.alloc.initWithFrame($.NSMakeRect(frame[0], frame[1], frame[2], frame[3]));
  b.setBezelStyle($.NSBezelStyleRounded);
  b.setTitle(title);
  b.setFont($.NSFont.systemFontOfSize(12));
  b.setTarget(controller);
  b.setAction(action);
  if (key) {
    try { b.setKeyEquivalent(key); } catch (e) {}
  }
  return b;
}

function sSeparator(y) {
  return box([20, y, 420, 1], $.NSColor.separatorColor, 0, 0, null);
}

/* ------------------------------------------------------------ app updates */

function appVersion() {
  try {
    const v = $.NSBundle.mainBundle.objectForInfoDictionaryKey('CFBundleShortVersionString');
    if (v && !v.isNil()) {
      const s = String(v.js).trim();
      if (s) return s;
    }
  } catch (e) {}
  return '0.0.0';
}

function versionParts(v) {
  return String(v).replace(/^v/i, '').split(/[^0-9]+/)
    .filter(function (part) { return part.length > 0; })
    .map(function (part) { return parseInt(part, 10) || 0; });
}

function isNewerVersion(latest, current) {
  const a = versionParts(latest);
  const b = versionParts(current);
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const x = a[i] || 0;
    const y = b[i] || 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return false;
}

function setUpdateStatus(text, color) {
  if (!settingsUpdateLabel) return;
  settingsUpdateLabel.setStringValue(text);
  settingsUpdateLabel.setTextColor(color || $.NSColor.secondaryLabelColor);
}

function fetchLatestRelease() {
  const cmd = '/usr/bin/curl -fsSL --connect-timeout 2 --max-time 5 ' +
    '-H ' + q('Accept: application/vnd.github+json') + ' ' +
    '-H ' + q('User-Agent: QoderMeter/' + appVersion()) + ' ' +
    q('https://api.github.com/repos/chenleshu/qoder-meter/releases/latest');
  const out = sh(cmd);
  if (!out) return null;
  const tag = (out.match(/"tag_name"\s*:\s*"([^"]+)"/) || [])[1];
  const url = (out.match(/"html_url"\s*:\s*"([^"]+)"/) || [])[1];
  if (!tag) return null;
  return {
    tag: String(tag).replace(/^v/i, ''),
    url: url ? String(url).replace(/\\\//g, '/') :
      'https://github.com/chenleshu/qoder-meter/releases/latest'
  };
}

function buildSettingsWindow() {
  settingsPanel = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 460, 576),
    3, // titled + closable
    $.NSBackingStoreBuffered,
    false
  );
  settingsPanel.setTitle('Qoder Meter 设置');
  settingsPanel.setReleasedWhenClosed(false);
  settingsPanel.setHidesOnDeactivate(false);
  settingsPanel.setLevel(26);

  const root = settingsPanel.contentView;
  settingsHeaderBox = box([20, 524, 28, 28], T.greenTint, 8, 0, null);
  root.addSubview(settingsHeaderBox);
  settingsHeaderIcon = $.NSImageView.alloc.initWithFrame($.NSMakeRect(26.5, 530.5, 15, 15));
  const headerImage = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('gauge', 'Qoder Meter');
  if (headerImage && !headerImage.isNil()) {
    settingsHeaderIcon.setImage(headerImage);
    try { settingsHeaderIcon.setContentTintColor(T.green); } catch (e) {}
  }
  root.addSubview(settingsHeaderIcon);
  root.addSubview(sLabel('Qoder Meter', [56, 528, 250, 20], 16, $.NSFontWeightSemibold));
  root.addSubview(sLabel('状态条显示、启动与会话跟随', [56, 508, 250, 14], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));

  settingsUpdateButton = sButton('检查更新', [314, 524, 126, 28], 'checkUpdates:');
  try {
    settingsUpdateButton.setFont($.NSFont.systemFontOfSize(12));
    settingsUpdateButton.setToolTip('点击后访问 GitHub Releases 检查新版本');
  } catch (e) {}
  root.addSubview(settingsUpdateButton);
  settingsUpdateLabel = sLabel('v' + appVersion(), [310, 508, 130, 14], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor);
  try { settingsUpdateLabel.setAlignment(2); } catch (e) {}
  root.addSubview(settingsUpdateLabel);

  root.addSubview(sLabel('启动与退出', [22, 478, 300, 16], 12, $.NSFontWeightSemibold));
  settingsAutoStart = sCheckbox('随 Qoder 自动启动', [22, 448, 416, 22],
    'settingsToggleAutoStart:', state.autoStart);
  settingsClose = sCheckbox('Qoder 退出时关闭', [22, 420, 416, 22],
    'settingsToggleClose:', state.closeWithQoder);
  root.addSubview(settingsAutoStart);
  root.addSubview(settingsClose);
  root.addSubview(sSeparator(408));

  root.addSubview(sLabel('显示', [22, 382, 300, 16], 12, $.NSFontWeightSemibold));
  root.addSubview(sLabel('显示位置', [22, 350, 100, 16], 12));
  settingsPosPopup = sPopup(['侧边栏卡片（推荐）', '窗口标题栏（融入顶部）', '窗口上方（贴外）', '窗口下方（贴外）'],
    state.layout === 'sidebar' ? 0 : (state.layout === 'title' ? 1 : (state.layout === 'top' ? 2 : 3)),
    [142, 344, 296, 28], 'settingsPosChanged:');
  try { settingsPosPopup.setToolTip('全屏时贴外形态会收成屏幕边缘细线，悬停展开'); } catch (e) {}
  root.addSubview(settingsPosPopup);

  root.addSubview(sLabel('字号', [22, 314, 100, 16], 12));
  let fontIndex = 0;
  const fontLabels = [];
  for (let i = 0; i < FONT_SIZES.length; i++) {
    fontLabels.push(FONT_SIZES[i].label);
    if (FONT_SIZES[i].id === state.fontSize) fontIndex = i;
  }
  settingsFontPopup = sPopup(fontLabels, fontIndex,
    [142, 308, 296, 28], 'settingsFontChanged:');
  try { settingsFontPopup.setToolTip('作用于标题栏、窗口上方和下方状态条；宽度会随字号自动调整'); } catch (e) {}
  root.addSubview(settingsFontPopup);

  root.addSubview(sLabel('外观', [22, 278, 100, 16], 12));
  settingsThemePopup = sPopup(SKIN_NAMES, Math.max(0, SKIN_IDS.indexOf(state.theme)),
    [142, 272, 296, 28], 'settingsThemeChanged:');
  try { settingsThemePopup.setToolTip('自动会跟随 Qoder 的深浅色；Qoder 未设置时跟随系统'); } catch (e) {}
  root.addSubview(settingsThemePopup);

  settingsBottomAutoHide = sCheckbox('下方空间不足时自动隐藏', [22, 240, 416, 22],
    'settingsBottomAutoHideToggle:', state.bottomAutoHide);
  root.addSubview(settingsBottomAutoHide);
  root.addSubview(sSeparator(226));

  root.addSubview(sLabel('显示内容', [22, 198, 180, 16], 12, $.NSFontWeightSemibold));
  root.addSubview(sLabel('Token 单位', [262, 198, 76, 16], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));
  let tokenUnitIndex = 0;
  const tokenUnitLabels = [];
  for (let i = 0; i < TOKEN_UNITS.length; i++) {
    tokenUnitLabels.push(TOKEN_UNITS[i].label);
    if (TOKEN_UNITS[i].id === state.tokenUnit) tokenUnitIndex = i;
  }
  settingsTokenUnitPopup = sPopup(tokenUnitLabels, tokenUnitIndex,
    [340, 190, 98, 28], 'settingsTokenUnitChanged:');
  try { settingsTokenUnitPopup.setToolTip('状态条和用量统计中的 Token 缩写单位'); } catch (e) {}
  root.addSubview(settingsTokenUnitPopup);
  settingsFieldChecks = [];
  for (let i = 0; i < DISPLAY_FIELDS.length; i++) {
    const field = DISPLAY_FIELDS[i];
    const col = i % 5;
    const row = Math.floor(i / 5);
    const cb = sFieldCheckbox(field.label, [22 + col * 84, row === 0 ? 164 : 136, 80, 22],
      i, !!state.display[field.id]);
    settingsFieldChecks.push(cb);
    root.addSubview(cb);
  }
  root.addSubview(sSeparator(122));

  root.addSubview(sLabel('会话', [22, 96, 200, 16], 12, $.NSFontWeightSemibold));
  settingsFollow = sCheckbox('自动跟随当前打开的会话', [22, 66, 416, 22],
    'settingsFollowToggle:', state.pinned ? false : true);
  root.addSubview(settingsFollow);
  root.addSubview(sLabel('状态条宽度随内容与字号自适应；关闭跟随后可在菜单选择并固定会话。',
    [22, 44, 416, 14], 11, $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));

  root.addSubview(sButton('重置当前位置', [22, 8, 150, 28], 'resetPosition:', null));
  root.addSubview(sButton('用量统计', [196, 8, 110, 28], 'openStats:', null));
  root.addSubview(sButton('完成', [330, 8, 108, 28], 'closeSettings:', '\r'));
  settingsPanel.center;
}

function updateSettingsControls() {
  if (!settingsPanel) return;
  try {
    settingsAutoStart.setState(state.autoStart ? 1 : 0);
    settingsClose.setState(state.closeWithQoder ? 1 : 0);
    settingsFollow.setState(state.pinned ? 0 : 1);
    settingsBottomAutoHide.setState(state.bottomAutoHide ? 1 : 0);
    settingsPosPopup.selectItemAtIndex(state.layout === 'sidebar' ? 0 :
      (state.layout === 'title' ? 1 : (state.layout === 'top' ? 2 : 3)));
    if (settingsFontPopup) {
      let fontIndex = 0;
      for (let i = 0; i < FONT_SIZES.length; i++) {
        if (FONT_SIZES[i].id === state.fontSize) fontIndex = i;
      }
      settingsFontPopup.selectItemAtIndex(fontIndex);
    }
    for (let i = 0; i < settingsFieldChecks.length && i < DISPLAY_FIELDS.length; i++) {
      settingsFieldChecks[i].setState(state.display[DISPLAY_FIELDS[i].id] ? 1 : 0);
    }
    if (settingsTokenUnitPopup) {
      let tokenUnitIndex = 0;
      for (let i = 0; i < TOKEN_UNITS.length; i++) {
        if (TOKEN_UNITS[i].id === state.tokenUnit) tokenUnitIndex = i;
      }
      settingsTokenUnitPopup.selectItemAtIndex(tokenUnitIndex);
    }
    settingsThemePopup.selectItemAtIndex(Math.max(0, SKIN_IDS.indexOf(state.theme)));
    const dark = state.resolvedSkin === 'graphite' || state.resolvedSkin === 'dusk';
    const name = dark ? $.NSAppearanceNameDarkAqua : $.NSAppearanceNameAqua;
    const appearance = $.NSAppearance.appearanceNamed(name);
    if (appearance && !appearance.isNil()) settingsPanel.setAppearance(appearance);
    if (settingsHeaderBox) settingsHeaderBox.setFillColor(T.greenTint);
    if (settingsHeaderIcon) settingsHeaderIcon.setContentTintColor(T.green);
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

function fmtDateShort(d) {
  return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

function fmtClock(ms) {
  const d = new Date(Number(ms) || Date.now());
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

function statsRangeText(data) {
  const start = statsRangeStart(state.statsRange);
  const end = new Date();
  const sameYear = start.getFullYear() === end.getFullYear();
  const left = sameYear ? fmtDateShort(start) : (start.getFullYear() + '-' + fmtDateShort(start));
  const right = sameYear ? fmtDateShort(end) : (end.getFullYear() + '-' + fmtDateShort(end));
  return left + ' ~ ' + right + ' · 活跃 ' + data.activeDays + ' 天';
}

function statsModelRows(data) {
  if (data.models.length <= 4) return data.models.slice(0, 4);
  const rows = data.models.slice(0, 3);
  const other = { name: '其他 ' + (data.models.length - 3) + ' 个', credits: 0, tokens: 0, estimated: false };
  for (let i = 3; i < data.models.length; i++) {
    other.credits += data.models[i].credits;
    other.tokens += data.models[i].tokens;
    if (data.models[i].estimated) other.estimated = true;
  }
  rows.push(other);
  return rows;
}

function statsDayModelsText(day) {
  const parts = [];
  const n = Math.min(2, day.models.length);
  for (let i = 0; i < n; i++) {
    const m = day.models[i];
    parts.push(m.name + ' ' + fmtCredits(m.credits) + '分/' +
      (m.estimated ? '≈' : '') + fmtStatsTokens(m.tokens));
  }
  if (day.models.length > n) parts.push('+' + (day.models.length - n));
  return parts.join(' · ');
}

function statsSummary(root, x, y, w, h, data) {
  root.addSubview(box([x, y, w, h], T.grayTint, 10, 0, null));
  const cellW = w / 3;
  for (let i = 1; i < 3; i++) {
    root.addSubview(box([x + cellW * i, y + 10, 1, h - 20], T.divider, 0, 0, null));
  }
  const cells = [
    { label: '总积分', value: fmtCredits(data.credits), color: T.gold },
    { label: '总 Token', value: (data.estimated ? '≈ ' : '') + fmtStatsTokens(data.tokens), color: T.soft },
    { label: '请求数', value: fmtCount(data.requests), color: T.text }
  ];
  for (let i = 0; i < cells.length; i++) {
    const cx = x + cellW * i + 12;
    root.addSubview(sLabel(cells[i].label, [cx, y + 29, cellW - 20, 14], 11,
      $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));
    const value = sLabel(cells[i].value, [cx, y + 7, cellW - 20, 22], 19,
      $.NSFontWeightSemibold, cells[i].color);
    try { value.setLineBreakMode($.NSLineBreakByTruncatingTail); } catch (e) {}
    root.addSubview(value);
  }
}

function statsPick(root, title, x, y, w, h, tag, action, selected, tip) {
  root.addSubview(box([x, y, w, h], selected ? T.greenTint : T.grayTint, 8, 0, null));
  const b = sButton(title, [x, y, w, h], action, null);
  try {
    b.setBordered(false);
    b.setFont($.NSFont.systemFontOfSizeWeight(11,
      selected ? $.NSFontWeightSemibold : $.NSFontWeightRegular));
    b.setTag(tag);
    if (tip) b.setToolTip(tip);
  } catch (e) {}
  root.addSubview(b);
}

function statsNavButton(root, title, x, y, w, action) {
  root.addSubview(box([x, y, w, 26], T.grayTint, 8, 0, null));
  const b = sButton(title, [x, y, w, 26], action, null);
  try {
    b.setBordered(false);
    b.setFont($.NSFont.systemFontOfSizeWeight(11, $.NSFontWeightMedium));
  } catch (e) {}
  root.addSubview(b);
}

function buildStatsWindow() {
  if (statsPanel) {
    statsPanel.orderOut(null);
    statsPanel = null;
  }
  const data = statsForRange(state.statsRange);
  state.statsData = data;
  const direct = state.statsMode === 'direct';
  const modelRows = statsModelRows(data);
  const totalPages = Math.max(1, Math.ceil(data.days.length / STATS_PAGE_SIZE));
  state.statsPage = Math.max(0, Math.min(state.statsPage, totalPages - 1));
  const page = direct ? 0 : state.statsPage;
  const days = data.days.slice(page * STATS_PAGE_SIZE, page * STATS_PAGE_SIZE + STATS_PAGE_SIZE);
  const navVisible = !direct && totalPages > 1;

  const margin = 16;
  const nameFont = $.NSFont.systemFontOfSizeWeight(12, $.NSFontWeightMedium);
  const metricFont = $.NSFont.systemFontOfSizeWeight(19, $.NSFontWeightSemibold);
  let need = 448;
  for (let i = 0; i < modelRows.length; i++) {
    need = Math.max(need, margin + textWidth(modelRows[i].name, nameFont) + 10 + 46 + 10 + 68 + margin);
  }
  const tokenValueText = (data.estimated ? '≈ ' : '') + fmtStatsTokens(data.tokens);
  const summaryTextNeed = Math.max(
    textWidth(fmtCredits(data.credits), metricFont),
    textWidth(tokenValueText, metricFont),
    textWidth(fmtCount(data.requests), metricFont)
  );
  need = Math.max(need, margin * 2 + 3 * (summaryTextNeed + 24));
  const W = Math.max(448, Math.min(600, Math.ceil(need / 2) * 2));

  const modelHeaderTop = 158;
  const modelRowsTop = 176;
  const modelRowH = 19;
  const modelBlockRows = Math.max(1, modelRows.length);
  const dailyHeaderTop = modelRowsTop + modelBlockRows * modelRowH + 10;
  const rowsTop = dailyHeaderTop + 18;
  const rowH = 38;
  const H = days.length
    ? rowsTop + days.length * rowH + (navVisible ? 36 : 10)
    : rowsTop + 26;

  statsPanel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, W, H), 128, $.NSBackingStoreBuffered, false);
  statsPanel.setLevel(26);
  statsPanel.setCollectionBehavior(1 | 256 | 16);
  statsPanel.setOpaque(false);
  statsPanel.setBackgroundColor($.NSColor.clearColor);
  statsPanel.setHasShadow(true);
  statsPanel.setHidesOnDeactivate(false);
  statsPanel.setBecomesKeyOnlyIfNeeded(true);
  const darkAppearance = state.resolvedSkin === 'graphite' || state.resolvedSkin === 'dusk';
  const appearanceName = darkAppearance ? $.NSAppearanceNameDarkAqua : $.NSAppearanceNameAqua;
  const statsAppearance = $.NSAppearance.appearanceNamed(appearanceName);
  if (statsAppearance && !statsAppearance.isNil()) statsPanel.setAppearance(statsAppearance);

  const top = function (t, h) { return H - t - h; };
  let statsSolidBg = T.bg;
  try { statsSolidBg = T.bg.colorWithAlphaComponent(1); } catch (e) {}
  const root = statsPanel.contentView;
  root.addSubview(box([0, 0, W, H], statsSolidBg, 14, 1, T.border));
  root.addSubview(box([margin, H - 2, W - margin * 2, 1], T.highlight, 0, 0, null));

  root.addSubview(box([margin, top(10, 24), 24, 24], T.greenTint, 7, 0, null));
  const statsIcon = $.NSImageView.alloc.initWithFrame($.NSMakeRect(margin + 5.5, top(10, 24) + 5.5, 13, 13));
  const statsImage = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('chart.bar.xaxis',
    '用量统计');
  if (statsImage && !statsImage.isNil()) {
    statsIcon.setImage(statsImage);
    try { statsIcon.setContentTintColor(T.green); } catch (e) {}
  }
  root.addSubview(statsIcon);
  root.addSubview(sLabel('用量统计', [margin + 32, top(7, 20), 200, 20], 16,
    $.NSFontWeightSemibold));
  root.addSubview(sLabel('本地日志 · 每日积分与单模型用量', [margin + 32, top(27, 14), 300, 14],
    11, $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));

  const close = sButton('×', [W - margin - 24, top(10, 24), 24, 24], 'closeStats:', null);
  try { close.setBordered(false); close.setFont($.NSFont.systemFontOfSize(15)); } catch (e) {}
  root.addSubview(close);

  const ctrlY = top(48, 26);
  const rangeX = margin;
  const rangeW = 50;
  const rangeGap = 5;
  const shortRangeLabels = ['7 天', '30 天', '本月', '一年'];
  for (let i = 0; i < STATS_RANGES.length; i++) {
    statsPick(root, shortRangeLabels[i] || STATS_RANGES[i].label, rangeX + i * (rangeW + rangeGap),
      ctrlY, rangeW, 26, i, 'statsRangePick:', state.statsRange === STATS_RANGES[i].id,
      STATS_RANGES[i].label);
  }
  const modeX = rangeX + 4 * (rangeW + rangeGap) + 12;
  const modeW = 44;
  const modeGap = 4;
  const shortModeLabels = ['悬停', '直接', '分页'];
  for (let i = 0; i < STATS_MODES.length; i++) {
    statsPick(root, shortModeLabels[i] || STATS_MODES[i].label, modeX + i * (modeW + modeGap),
      ctrlY, modeW, 26, i, 'statsModePick:', state.statsMode === STATS_MODES[i].id,
      STATS_MODES[i].label);
  }
  const refresh = sButton('刷新', [W - margin - 40, ctrlY, 40, 26], 'statsRefresh:', null);
  try {
    refresh.setBordered(false);
    refresh.setFont($.NSFont.systemFontOfSizeWeight(11, $.NSFontWeightRegular));
  } catch (e) {}
  root.addSubview(box([W - margin - 40, ctrlY, 40, 26], T.grayTint, 8, 0, null));
  root.addSubview(refresh);

  root.addSubview(sLabel(statsRangeText(data), [margin, top(80, 14), W - 130, 14], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));
  const updated = sLabel('更新 ' + fmtClock(state.statsCache ? state.statsCache.at : Date.now()),
    [W - margin - 96, top(80, 14), 96, 14], 11, $.NSFontWeightRegular,
    $.NSColor.tertiaryLabelColor, 2);
  root.addSubview(updated);

  statsSummary(root, margin, top(100, 50), W - margin * 2, 50, data);

  const tokensX = W - margin - 68;
  const creditsX = tokensX - 10 - 46;
  root.addSubview(sLabel('按模型 · ' + data.models.length + ' 个',
    [margin, top(modelHeaderTop, 16), 180, 16], 12, $.NSFontWeightSemibold));
  root.addSubview(sLabel('积分', [creditsX, top(modelHeaderTop, 16), 46, 16], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor, 2));
  root.addSubview(sLabel('Token', [tokensX, top(modelHeaderTop, 16), 68, 16], 11,
    $.NSFontWeightRegular, $.NSColor.secondaryLabelColor, 2));

  if (!modelRows.length) {
    root.addSubview(sLabel('暂无模型记录', [margin, top(modelRowsTop, 16), 300, 16], 11,
      $.NSFontWeightRegular, $.NSColor.secondaryLabelColor));
  } else {
    for (let i = 0; i < modelRows.length; i++) {
      const m = modelRows[i];
      const y = top(modelRowsTop + i * modelRowH, 17);
      const nameLabel = sLabel(m.name, [margin, y, creditsX - margin - 10, 17], 12,
        $.NSFontWeightMedium, T.text);
      try { nameLabel.setLineBreakMode($.NSLineBreakByTruncatingTail); } catch (e) {}
      root.addSubview(nameLabel);
      const creditsLabel = sLabel(fmtCredits(m.credits), [creditsX, y, 46, 17], 11,
        $.NSFontWeightRegular, T.soft, 2);
      root.addSubview(creditsLabel);
      const tokensLabel = sLabel((m.estimated ? '≈ ' : '') + fmtStatsTokens(m.tokens),
        [tokensX, y, 68, 17], 11, $.NSFontWeightRegular, T.soft, 2);
      root.addSubview(tokensLabel);
    }
  }

  root.addSubview(box([margin, top(dailyHeaderTop - 6, 1), W - margin * 2, 1], T.divider, 0, 0, null));
  root.addSubview(sLabel(direct ? '按天 · 最近 5 天' : '按天',
    [margin, top(dailyHeaderTop, 16), 220, 16], 12, $.NSFontWeightSemibold));
  if (data.days.length) {
    root.addSubview(sLabel('共 ' + data.days.length + ' 天',
      [W - margin - 100, top(dailyHeaderTop, 16), 100, 16], 11,
      $.NSFontWeightRegular, $.NSColor.secondaryLabelColor, 2));
  }

  if (!days.length) {
    root.addSubview(sLabel('暂无用量记录', [margin, top(rowsTop, 18), W - margin * 2, 18], 11,
      $.NSFontWeightRegular, $.NSColor.secondaryLabelColor, 2));
  } else {
    for (let i = 0; i < days.length; i++) {
      const d = days[i];
      const y = top(rowsTop + i * rowH, rowH);
      const dateLabel = sLabel(dayLabel(d.key), [margin, y + 20, 68, 15], 12,
        $.NSFontWeightMedium, T.text);
      root.addSubview(dateLabel);
      const totalLabel = sLabel(fmtCredits(d.credits) + ' 积分 · ' +
        (d.estimated ? '≈ ' : '') + fmtStatsTokens(d.tokens) + ' tok',
        [margin + 76, y + 20, W - margin * 2 - 76, 15], 11, $.NSFontWeightRegular, T.soft, 2);
      root.addSubview(totalLabel);
      const modelLabel = sLabel(statsDayModelsText(d), [margin, y + 4, W - margin * 2, 14], 11,
        $.NSFontWeightRegular, $.NSColor.secondaryLabelColor);
      try { modelLabel.setLineBreakMode($.NSLineBreakByTruncatingTail); } catch (e) {}
      root.addSubview(modelLabel);
      if (i < days.length - 1) {
        root.addSubview(box([margin, y, W - margin * 2, 1], T.divider, 0, 0, null));
      }
    }
  }

  if (navVisible) {
    statsNavButton(root, '‹ 上一页', margin, 8, 72, 'statsPrevPage:');
    statsNavButton(root, '下一页 ›', W - margin - 72, 8, 72, 'statsNextPage:');
    root.addSubview(sLabel('第 ' + (page + 1) + ' / ' + totalPages + ' 页',
      [W / 2 - 60, 13, 120, 15], 11, $.NSFontWeightRegular,
      $.NSColor.tertiaryLabelColor, 2));
  }

  statsPanel.orderOut(null);
  placeStatsPanel();
}

function setStatsIconActive(active) {
  if (statsPillBox) {
    try { statsPillBox.setFillColor(active ? T.greenTint : T.grayTint); } catch (e) {}
  }
  if (statsIconView) {
    try { statsIconView.setContentTintColor(active ? T.green : T.gray); } catch (e) {}
  }
}

function statsIconScreenRect() {
  if (!panel || !statsButtonRect) return null;
  try {
    const pf = panel.frame;
    return {
      x: Number(pf.origin.x) + statsButtonRect.x,
      y: Number(pf.origin.y) + statsButtonRect.y,
      w: statsButtonRect.w,
      h: statsButtonRect.h
    };
  } catch (e) {
    return null;
  }
}

function placeStatsPanel() {
  if (!statsPanel) return;
  const screen = $.NSScreen.mainScreen;
  const sw = Number(screen.frame.size.width);
  const sh = Number(screen.frame.size.height);
  const vf = screen.visibleFrame;
  const floorY = Number(vf.origin.y) + 6;
  const ceilY = Math.min(sh - 34, Number(vf.origin.y) + Number(vf.size.height) - 6);
  const frame = statsPanel.frame;
  const W = Number(frame.size.width);
  const H = Number(frame.size.height);
  const anchor = statsIconScreenRect();
  let x;
  let y;
  if (anchor) {
    x = Math.round(anchor.x + anchor.w - W);
    y = Math.round(anchor.y - 8 - H);
    const belowFits = y >= floorY;
    if (!belowFits) {
      if (state.layout === 'sidebar') {
        const leftX = Number(panel.frame.origin.x) - W - 10;
        if (leftX >= 8) {
          x = Math.round(leftX);
          y = Math.round(Math.min(ceilY - H, Math.max(floorY, anchor.y + anchor.h - H)));
        } else {
          y = floorY;
        }
      } else {
        y = Math.round(anchor.y + anchor.h + 8);
        if (y + H > ceilY) y = Math.round(Math.max(floorY, ceilY - H));
      }
    }
  } else if (state.windowBounds) {
    const b = state.windowBounds;
    x = Math.round(b.x + b.width - W - 12);
    y = Math.round(b.y + b.height - H - 44);
  } else {
    x = Math.round((sw - W) / 2);
    y = Math.round((sh - H) / 2);
  }
  x = Math.max(8, Math.min(x, sw - W - 8));
  y = Math.max(floorY, Math.min(y, ceilY - H));
  statsPanel.setFrameOrigin($.NSMakePoint(Math.round(x), Math.round(y)));
}

function refreshStatsVisibility() {
  const front = !!state.frontIsQoder;
  if (front && state.statsPreview && Date.now() - state.statsPreviewAt > 1500) {
    state.statsPreview = false;
  }
  const showPanel = !state.panelHidden && state.qoderRunning && !state.statsHidden && (
    (state.statsPinned && (front || state.statsPreview)) ||
    (front && state.statsMode === 'direct') ||
    (front && state.statsMode === 'hover' && state.statsHover)
  );
  setStatsIconActive(showPanel || (state.statsPinned && front) || state.statsHover);
  if (showPanel) {
    if (!statsPanel) {
      try { buildStatsWindow(); } catch (e) { logError('buildStatsWindow', e); return; }
    }
    placeStatsPanel();
    if (!statsPanel.isVisible) statsPanel.orderFront(null);
  } else if (statsPanel && statsPanel.isVisible) {
    statsPanel.orderOut(null);
  }
}

function updateStatsHover() {
  if (!state.frontIsQoder) {
    if (!state.statsPinned) state.statsHover = false;
    return;
  }
  if (state.statsMode !== 'hover' && !state.statsPinned) {
    state.statsHover = false;
    return;
  }
  try {
    const m = $.NSEvent.mouseLocation;
    let over = false;
    const anchor = statsIconScreenRect();
    if (anchor) {
      over = m.x >= anchor.x - 8 && m.x <= anchor.x + anchor.w + 8 &&
        m.y >= anchor.y - 8 && m.y <= anchor.y + anchor.h + 8;
    }
    if (!over && statsPanel && statsPanel.isVisible) {
      const f = statsPanel.frame;
      over = m.x >= Number(f.origin.x) - 6 && m.x <= Number(f.origin.x) + Number(f.size.width) + 6 &&
        m.y >= Number(f.origin.y) - 6 && m.y <= Number(f.origin.y) + Number(f.size.height) + 6;
    }
    if (state.statsSuppress) {
      if (!over) state.statsSuppress = false;
      if (!state.statsPinned) state.statsHover = false;
      return;
    }
    if (over) {
      if (state.statsMode === 'hover' && !state.statsPinned) {
        state.statsHover = true;
        state.statsHoverAt = Date.now();
      }
    } else if (state.statsHover && !state.statsPinned && Date.now() - state.statsHoverAt > 1200) {
      state.statsHover = false;
    }
  } catch (e) {}
}

function rebuildStatsWindow() {
  if (statsPanel) {
    statsPanel.orderOut(null);
    statsPanel = null;
  }
  refreshStatsVisibility();
}

function openStats(preview) {
  try {
    if (settingsPanel) settingsPanel.orderOut(null);
    state.statsHidden = false;
    state.statsSuppress = false;
    state.statsPinned = true;
    state.statsPreview = preview !== false;
    state.statsPreviewAt = state.statsPreview ? Date.now() : 0;
    if (state.statsMode === 'hover') state.statsHover = true;
    rebuildStatsWindow();
    buildMenu();
  } catch (e) { logError('openStats', e); }
}

function toggleStatsPopover() {
  const now = Date.now();
  if (now - state.statsToggleAt < 400) return;
  state.statsToggleAt = now;
  if (statsPanel && statsPanel.isVisible) {
    if (state.statsPinned || state.statsMode === 'direct') {
      closeStats();
    } else {
      state.statsPinned = true;
      state.statsPreview = false;
      refreshStatsVisibility();
      buildMenu();
    }
  } else {
    openStats(false);
  }
}

function closeStats() {
  state.statsPinned = false;
  state.statsPreview = false;
  state.statsHover = false;
  if (state.statsMode === 'hover') {
    state.statsHidden = false;
    state.statsSuppress = true;
  } else {
    state.statsHidden = true;
    state.statsSuppress = false;
  }
  refreshStatsVisibility();
  buildMenu();
}

function setStatsMode(id) {
  let valid = false;
  for (let i = 0; i < STATS_MODES.length; i++) {
    if (STATS_MODES[i].id === id) valid = true;
  }
  if (!valid) return;
  const wasVisible = !!(statsPanel && statsPanel.isVisible);
  state.statsMode = id;
  state.statsHidden = false;
  state.statsSuppress = false;
  state.statsPinned = wasVisible;
  state.statsPreview = wasVisible && !state.frontIsQoder;
  state.statsPreviewAt = state.statsPreview ? Date.now() : 0;
  state.statsHover = false;
  state.statsPage = 0;
  saveSettings();
  rebuildStatsWindow();
  buildMenu();
}

function setStatsRange(id) {
  let valid = false;
  for (let i = 0; i < STATS_RANGES.length; i++) {
    if (STATS_RANGES[i].id === id) valid = true;
  }
  if (!valid) return;
  state.statsRange = id;
  state.statsSuppress = false;
  state.statsPage = 0;
  saveSettings();
  rebuildStatsWindow();
  buildMenu();
}

function rebuildPanelUI() {
  if (panel) panel.orderOut(null);
  buildUI(state.layout);
  applyWindowLayout();
  refreshVisibility();
  updateUI();
  updateSettingsControls();
  buildMenu();
  if (statsPanel) rebuildStatsWindow();
}

function setTheme(theme) {
  const next = normalizeTheme(theme);
  if (next === state.theme) {
    buildMenu();
    return;
  }
  const prevSkin = state.resolvedSkin;
  state.theme = next;
  applySkin();
  saveSettings();
  if (state.resolvedSkin !== prevSkin) {
    rebuildPanelUI();
  } else {
    updateSettingsControls();
    buildMenu();
  }
}

function setFontSize(id) {
  let valid = false;
  for (let i = 0; i < FONT_SIZES.length; i++) {
    if (FONT_SIZES[i].id === id) valid = true;
  }
  if (!valid || id === state.fontSize) {
    buildMenu();
    return;
  }
  state.fontSize = id;
  applyFontScale();
  saveSettings();
  rebuildPanelUI();
}

function setTokenUnit(id) {
  let valid = false;
  for (let i = 0; i < TOKEN_UNITS.length; i++) {
    if (TOKEN_UNITS[i].id === id) valid = true;
  }
  if (!valid || id === state.tokenUnit) {
    updateSettingsControls();
    buildMenu();
    return;
  }
  state.tokenUnit = id;
  saveSettings();
  rebuildPanelUI();
}

function toggleDisplayField(id) {
  if (typeof state.display[id] !== 'boolean') return;
  state.display[id] = !state.display[id];
  saveSettings();
  rebuildPanelUI();
}

function syncAutoTheme() {
  if (state.theme !== 'auto') return;
  const now = Date.now();
  if (now - state.autoThemeAt < 2000) return;
  state.autoThemeAt = now;
  const skin = resolveSkin('auto');
  if (skin === state.resolvedSkin) return;
  state.resolvedSkin = skin;
  T = SKINS[skin] || SKINS.paper;
  rebuildPanelUI();
}

function setLayout(mode) {
  if (mode !== 'sidebar' && mode !== 'title' && mode !== 'top' && mode !== 'bottom') return;
  if (mode === state.layout) {
    buildMenu();
    return;
  }
  state.layout = mode;
  state.bottomRevealed = mode === 'bottom'
    ? (!state.bottomAutoHide && !state.qoderFullscreen) : false;
  state.topRevealed = false;
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
    'layoutTop:': {
      types: ['void', ['id']],
      implementation: function (sender) { setLayout('top'); }
    },
    'layoutBottom:': {
      types: ['void', ['id']],
      implementation: function (sender) { setLayout('bottom'); }
    },
    'themeAuto:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('auto'); }
    },
    'themePaper:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('paper'); }
    },
    'themeGraphite:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('graphite'); }
    },
    'themeOcean:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('ocean'); }
    },
    'themeDusk:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('dusk'); }
    },
    'themeSand:': {
      types: ['void', ['id']],
      implementation: function (sender) { setTheme('sand'); }
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
        setLayout(idx === 0 ? 'sidebar' : (idx === 1 ? 'title' : (idx === 2 ? 'top' : 'bottom')));
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
        setTheme(SKIN_IDS[idx] || 'auto');
        updateSettingsControls();
      }
    },
    'settingsFontChanged:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(settingsFontPopup.indexOfSelectedItem);
        const font = FONT_SIZES[idx] || FONT_SIZES[1];
        setFontSize(font.id);
      }
    },
    'settingsTokenUnitChanged:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(settingsTokenUnitPopup.indexOfSelectedItem);
        const unit = TOKEN_UNITS[idx] || TOKEN_UNITS[0];
        setTokenUnit(unit.id);
      }
    },
    'settingsToggleField:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(sender.tag);
        const field = DISPLAY_FIELDS[idx];
        if (field) toggleDisplayField(field.id);
      }
    },
    'fontSizeMenu:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        setFontSize(representedId(sender));
      }
    },
    'tokenUnitMenu:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        setTokenUnit(representedId(sender));
      }
    },
    'toggleDisplay:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        toggleDisplayField(representedId(sender));
      }
    },
    'openStats:': {
      types: ['void', ['id']],
      implementation: function (sender) { openStats(); }
    },
    'toggleStatsPopover:': {
      types: ['void', ['id']],
      implementation: function (sender) { toggleStatsPopover(); }
    },
    'closeStats:': {
      types: ['void', ['id']],
      implementation: function (sender) { closeStats(); }
    },
    'statsRangePick:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(sender.tag);
        setStatsRange((STATS_RANGES[idx] || STATS_RANGES[0]).id);
      }
    },
    'statsModePick:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const idx = Number(sender.tag);
        setStatsMode((STATS_MODES[idx] || STATS_MODES[0]).id);
      }
    },
    'statsModeMenu:': {
      types: ['void', ['id']],
      implementation: function (sender) { setStatsMode(representedId(sender)); }
    },
    'statsPrevPage:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const data = state.statsData || statsForRange(state.statsRange);
        const total = Math.max(1, Math.ceil(data.days.length / STATS_PAGE_SIZE));
        state.statsPage = Math.max(0, Math.min(state.statsPage, total - 1) - 1);
        rebuildStatsWindow();
      }
    },
    'statsNextPage:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        const data = state.statsData || statsForRange(state.statsRange);
        const total = Math.max(1, Math.ceil(data.days.length / STATS_PAGE_SIZE));
        state.statsPage = Math.min(total - 1, state.statsPage + 1);
        rebuildStatsWindow();
      }
    },
    'statsRefresh:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        collectDailyUsage(true);
        state.statsData = null;
        rebuildStatsWindow();
      }
    },
    'checkUpdates:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        if (state.updateChecking) return;
        state.updateChecking = true;
        try {
          sender.setEnabled(false);
          sender.setTitle('检查中…');
          setUpdateStatus('正在连接 GitHub…');
          sender.displayIfNeeded();
          if (settingsUpdateLabel) settingsUpdateLabel.displayIfNeeded();
        } catch (e) {}

        const info = fetchLatestRelease();
        state.updateChecking = false;
        if (!settingsUpdateButton) return;
        settingsUpdateButton.setEnabled(true);

        const current = appVersion();
        if (!info) {
          settingsUpdateButton.setTitle('检查更新');
          settingsUpdateButton.setAction('checkUpdates:');
          setUpdateStatus('检查失败，请稍后再试', T.red);
          return;
        }
        if (isNewerVersion(info.tag, current)) {
          state.updateUrl = info.url;
          settingsUpdateButton.setTitle('获取更新');
          settingsUpdateButton.setAction('openUpdate:');
          setUpdateStatus('发现 v' + info.tag, T.green);
        } else {
          state.updateUrl = null;
          settingsUpdateButton.setTitle('检查更新');
          settingsUpdateButton.setAction('checkUpdates:');
          setUpdateStatus('已是最新 v' + current);
        }
      }
    },
    'openUpdate:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        if (!state.updateUrl) return;
        sh('/usr/bin/open ' + q(state.updateUrl));
        setUpdateStatus('已打开下载页');
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
    const liveBounds = readQoderWindowBounds();
    if (liveBounds) state.windowBounds = liveBounds;
    syncAutoTheme();
    updateUI();
    updateBottomHover();
    updateTopHover();
    updateStatsHover();
    applyWindowLayout();
    refreshVisibility();
    refreshStatsVisibility();
  } catch (e) {
    logError('tick', e);
  }
}

function main() {
  app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  controller = $.QoderMeterController.alloc.init;

  loadSettings();
  applyFontScale();
  loadModelLabels();
  loadStatsCache();

  try {
    const fm = $.NSFileManager.defaultManager;
    if (fm.fileExistsAtPath(OLD_LOGIN_PLIST)) {
      sh('/bin/launchctl unload -w ' + q(OLD_LOGIN_PLIST) + ' 2>/dev/null');
      fm.removeItemAtPathError(OLD_LOGIN_PLIST, null);
    }
  } catch (e) {}

  applySkin();
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
