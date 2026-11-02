'use strict';

// Offline stats-window construction checks:
//   node --test macos/*.test.cjs     (repository-wide macOS test run)
//   node stats-window.test.cjs       (single file)
// Loads the real source without main(), with inert AppKit mocks to build the
// dashboard control tree from a synthetic 30-day cache. It asserts the
// overview cards / trend bars / model shares / auto summary, the paged detail
// list, the no-right-click action row, tooltips and row geometry. It cannot
// validate AppKit drawing, fonts, hover behaviour or native window placement.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sourcePath = path.join(__dirname, 'src', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8');
assert.match(source, /\nmain\(\);\s*$/, 'Refuse to load an unrecognized application entry point');

function color(r, g, b, alpha) {
  return { r, g, b, alpha, colorWithAlphaComponent(a) { return color(r, g, b, a); } };
}
function view(kind) {
  const v = { kind, children: [], stringValue: { js: '' },
    initWithFrame(frame) { this.frame = frame; return this; },
    addSubview(child) { this.children.push(child); },
    setStringValue(text) { this.stringValue = { js: text }; }
  };
  return new Proxy(v, { get(target, name) {
    if (name in target) return target[name];
    if (typeof name === 'string' && name.startsWith('set')) {
      return value => { target[name[3].toLowerCase() + name.slice(4)] = value; };
    }
    return undefined;
  } });
}
function viewClass(kind) { return { get alloc() { return view(kind); } }; }
function statsPanel() {
  const v = view('NSPanel');
  v.frame = { origin: { x: 0, y: 0 }, size: { width: 0, height: 0 } };
  v.contentView = view('NSView');
  v.initWithContentRectStyleMaskBackingDefer = function (rect) { this.frame = rect; return this; };
  v.orderOut = function () { this.visible = false; return this; };
  v.orderFront = function () { this.visible = true; return this; };
  v.setFrameOrigin = function (point) { this.frame.origin = point; };
  return v;
}
const screen = {
  frame: { size: { width: 1440, height: 900 } },
  visibleFrame: { origin: { x: 0, y: 0 }, size: { width: 1440, height: 860 } }
};
const api = function (text) {
  return { js: text, sizeWithAttributes() { return { width: Math.ceil(String(text).length * 7) }; } };
};
Object.assign(api, {
  NSHomeDirectory: () => ({ js: '/offline-probe-no-user-data' }),
  NSColor: {
    colorWithCalibratedRedGreenBlueAlpha: color,
    colorWithCalibratedWhiteAlpha: (w, a) => color(w, w, w, a),
    secondaryLabelColor: color(0.4, 0.4, 0.4, 1),
    tertiaryLabelColor: color(0.6, 0.6, 0.6, 1),
    labelColor: color(0, 0, 0, 1),
    clearColor: color(0, 0, 0, 0)
  },
  NSFont: {
    systemFontOfSizeWeight: (size, weight) => ({ size, weight }),
    systemFontOfSize: size => ({ size }),
    monospacedDigitSystemFontOfSizeWeight: (size, weight) => ({ size, weight })
  },
  NSDictionary: { dictionaryWithObjectForKey: font => font },
  NSScreen: { mainScreen: screen },
  NSMakeRect: (x, y, w, h) => ({ origin: { x, y }, size: { width: w, height: h } }),
  NSMakePoint: (x, y) => ({ x, y }),
  NSTextField: viewClass('NSTextField'),
  NSBox: viewClass('NSBox'),
  NSImageView: viewClass('NSImageView'),
  NSButton: viewClass('NSButton'),
  NSPanel: { get alloc() { return statsPanel(); } },
  NSImage: { imageWithSystemSymbolNameAccessibilityDescription: () => ({ isNil: () => false }) },
  NSAppearance: { appearanceNamed: () => ({ isNil: () => false }) },
  NSBackingStoreBuffered: 2,
  NSBezelStyleRounded: 1,
  NSFontWeightRegular: 0, NSFontWeightMedium: 0.23, NSFontWeightSemibold: 0.3,
  NSFontAttributeName: 'font', NSLineBreakByTruncatingTail: 4,
  NSAppearanceNameAqua: 'aqua', NSAppearanceNameDarkAqua: 'dark'
});
const objc = new Proxy(api, {
  get(target, name) {
    if (name in target) return target[name];
    throw new Error('Offline probe forbids: ObjC.' + String(name));
  }
});
const context = vm.createContext({
  $: objc,
  ObjC: { import() {}, registerSubclass() {} },
  Application: { currentApplication: () => ({}) }
});
vm.runInContext(source.replace(/\nmain\(\);\s*$/, '\n') + `
  globalThis.probe = {
    state, dateKey, statsPeriods, buildStatsWindow, statsGroupMeta, STATS_GROUPS,
    STATS_VIEWS, STATS_PAGE_SIZE, STATS_TREND_MAX, SKINS, statsViewModel,
    getStatsPanel: function () { return statsPanel; }
  };
`, context, { filename: sourcePath, timeout: 10000 });
const p = context.probe;

let checks = 0;
function check(condition, message) {
  checks++;
  assert.ok(condition, message);
}
function collect(node, out) {
  if (!node || !node.children) return out;
  for (const child of node.children) {
    out.push(child);
    collect(child, out);
  }
  return out;
}
function build(view, group, mode, empty, page) {
  p.state.statsView = view;
  p.state.statsGroup = group;
  p.state.statsMode = mode || 'paged';
  p.state.statsPage = page || 0;
  p.state.statsHint = '';
  p.state.statsCache = empty
    ? { at: Date.now(), days: {}, rows: 0 }
    : { at: Date.now(), days: syntheticDays, rows: syntheticDays.length };
  p.buildStatsWindow();
  const panel = p.getStatsPanel();
  check(!!panel, 'stats panel was not built for ' + view + '/' + group);
  const nodes = collect(panel.contentView, []);
  return {
    view, group, nodes,
    W: panel.frame.size.width,
    H: panel.frame.size.height,
    panel,
    buttons: nodes.filter(x => x.kind === 'NSButton' && typeof x.title === 'string'),
    labels: nodes.filter(x => x.kind === 'NSTextField' && x.stringValue &&
      typeof x.stringValue.js === 'string'),
    boxes: nodes.filter(x => x.kind === 'NSBox'),
    chartBars: nodes.filter(x => x.kind === 'NSBox' && typeof x.toolTip === 'string' &&
      x.toolTip.indexOf(' 积分 · ') >= 0 && x.toolTip.indexOf('\n') >= 0),
    dateLabels: nodes.filter(x => x.kind === 'NSTextField' && typeof x.toolTip === 'string' &&
      x.toolTip.indexOf('天有记录') >= 0),
    totalLabels: nodes.filter(x => x.kind === 'NSTextField' && typeof x.toolTip === 'string' &&
      x.toolTip.indexOf('积分 ·') >= 0 && x.toolTip.indexOf('\n') < 0),
    summaryLabels: nodes.filter(x => x.stringValue && /^今天 · |^近 7 天 · |^本月 · |^全部 · /.test(x.stringValue.js))
  };
}
function findButton(ui, title) {
  return ui.buttons.find(x => x.title === title);
}
function findLabel(ui, text) {
  return ui.labels.find(x => x.stringValue.js === text);
}
function hasLabelStarting(ui, text) {
  return ui.labels.some(x => x.stringValue.js.indexOf(text) === 0);
}
function rect(node) {
  return { x: node.frame.origin.x, y: node.frame.origin.y,
    w: node.frame.size.width, h: node.frame.size.height };
}
function inside(ui, node, label) {
  const r = rect(node);
  checks++;
  assert.ok(r.x >= -0.01 && r.y >= -0.01 &&
    r.x + r.w <= ui.W + 0.01 && r.y + r.h <= ui.H + 0.01,
    label + ' leaves the panel: ' + JSON.stringify(r) + ' in ' + ui.W + 'x' + ui.H);
}
function rowsDontOverlap(ui, nodes, label) {
  const ys = nodes.map(x => rect(x).y).sort((a, b) => b - a);
  for (let i = 1; i < ys.length; i++) {
    checks++;
    assert.ok(ys[i - 1] - ys[i] >= 40, label + ' rows overlap each other');
  }
}

// Synthetic 30-day cache ending today, with two models and mixed estimates.
const today = new Date();
const syntheticDays = {};
for (let i = 0; i < 30; i++) {
  const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i);
  syntheticDays[p.dateKey(d)] = {
    credits: 10 + i, tokens: 1000 + i * 10, requests: 1 + (i % 3),
    estimated: i % 7 === 0,
    models: {
      auto: { credits: 6 + i, tokens: 600 + i * 6, requests: 1, estimated: i % 7 === 0 },
      qmodel: { credits: 4, tokens: 400 + i * 4, requests: 1, estimated: false }
    }
  };
}
p.state.statsRange = '30d';
p.state.statsMode = 'paged';
p.state.statsGroup = 'day';
p.state.statsPage = 0;
check(p.state.statsView === 'overview', 'the dashboard must default to 总览');

/* ------------------------------------------------------------------ 总览 */

const overview = build('overview', 'day');
check(overview.W === 600, 'overview panel must be about 600 wide: ' + overview.W);
check(overview.H > 520 && overview.H < 760, 'overview height must adapt to its blocks: ' + overview.H);
check(!!findLabel(overview, '本地日志 · 趋势图与自动摘要'), 'dashboard subtitle missing');
check(!!findLabel(overview, '用量统计'), 'dashboard title missing');
check(overview.buttons.some(x => x.title === '×'), 'header close button missing');

// 视图 / 范围 / 粒度 / 显示方式 are all clickable inside the panel.
['总览', '明细'].forEach(title =>
  check(!!findButton(overview, title), 'view chip missing: ' + title));
['7 天', '30 天', '本月', '一年'].forEach(title =>
  check(!!findButton(overview, title), 'range chip missing: ' + title));
['按日', '按周', '按月'].forEach(title =>
  check(!!findButton(overview, title), 'group chip missing: ' + title));
['悬停', '直接', '分页'].forEach(title =>
  check(!!findButton(overview, title), 'mode chip missing: ' + title));

// No right-click on the status bar: the panel row must carry every exit.
['刷新', '设置', '更多操作', '关闭'].forEach(title =>
  check(!!findButton(overview, title), 'action button missing: ' + title));
check(!!findLabel(overview, '本机日志汇总 · 不联网 · 估算以 ≈ 标记'), 'footer note missing');

// Four summary cards.
['积分', 'Token', '请求', '活跃天'].forEach(title =>
  check(!!findLabel(overview, title), 'summary card missing: ' + title));
check(!!findLabel(overview, '活跃 30 天') === false, 'detail count must not leak into 总览');

// Trend: twelve NSBox bars, newest highlighted, no external image.
check(overview.chartBars.length === p.STATS_TREND_MAX,
  'trend must draw twelve NSBox bars, got ' + overview.chartBars.length);
const gold = p.SKINS.paper.gold;
const green = p.SKINS.paper.green;
const lastBar = overview.chartBars[overview.chartBars.length - 1];
check(Math.abs(lastBar.fillColor.r - gold.r) > 0.001,
  'the newest trend bar must use the green accent');
check(Math.abs(lastBar.fillColor.r - green.r) < 0.01 &&
  Math.abs(lastBar.fillColor.g - green.g) < 0.01, 'newest bar lost the accent color');
overview.chartBars.forEach(bar => inside(overview, bar, 'trend bar'));
check(overview.labels.some(x => /^积分趋势 · 最近 12 天$/.test(x.stringValue.js)),
  'trend section title changed');
// Blocks stack without colliding: axis labels stay above the model section.
const axisLabels = overview.labels.filter(x => /^(今天|\d{2}-\d{2})$/.test(x.stringValue.js));
check(axisLabels.length === 12, 'trend must label twelve periods, got ' + axisLabels.length);
const modelTitle = findLabel(overview, '模型构成 · 2 个');
axisLabels.forEach(x => {
  checks++;
  assert.ok(rect(x).y > rect(modelTitle).y + rect(modelTitle).h,
    'trend axis label collides with the model section');
});

// Model share bars with percentages.
check(!!findLabel(overview, '模型构成 · 2 个'), 'model section title changed');
check(!!findLabel(overview, '按积分占比'), 'model share basis changed');
check(overview.labels.some(x => /^\d+%$/.test(x.stringValue.js)), 'model share percent missing');

// Four rule-generated auto summary lines.
check(overview.summaryLabels.length === 4, 'auto summary must render four fixed lines');
['今天', '近 7 天', '本月', '全部'].forEach(label =>
  check(overview.summaryLabels.some(x => x.stringValue.js.indexOf(label + ' ·') === 0),
    'auto summary line missing: ' + label));
check(overview.summaryLabels.every(x => x.stringValue.js.indexOf('积分') >= 0),
  'auto summary lines lost their credits');
check(overview.summaryLabels.every(x => x.stringValue.js.indexOf('主力') >= 0),
  'auto summary lines must name the leading model');
check(overview.summaryLabels.every(x => !/NaN|Infinity/.test(x.stringValue.js)),
  'auto summary produced a non-finite number');
check(!!findLabel(overview, '自动摘要 · 规则生成'), 'auto summary caption missing');
// Section captions must not sit on top of their right-hand notes.
const titlePairs = [
  ['积分趋势 · 最近 12 天', /^按(积分| Token) · 峰值/],
  ['模型构成 · 2 个', /^按(积分| Token)占比$/],
  ['自动摘要 · 规则生成', /^本地 JSONL · 不联网$/]
];
titlePairs.forEach(pair => {
  const left = findLabel(overview, pair[0]);
  const right = overview.labels.find(x => pair[1].test(x.stringValue.js));
  check(!!left && !!right, 'section caption pair missing: ' + pair[0]);
  const a = rect(left);
  const b = rect(right);
  check(a.y === b.y && a.x + a.w <= b.x + 0.01, 'section captions overlap: ' + pair[0]);
});
inside(overview, findLabel(overview, '积分趋势 · 最近 12 天'), 'trend caption');
check(overview.dateLabels.length === 0, 'overview must not draw the paged detail rows');

/* ------------------------------------------------------------------ 明细 */

const detail = build('detail', 'day');
check(detail.H < overview.H + 240, 'detail height must stay compact: ' + detail.H);
check(!!findLabel(detail, '共 30 天'), 'daily group count changed');
check(!!findLabel(detail, '今天'), 'daily grouping must show today');
check(detail.dateLabels.length === 6, 'paged detail view must show six periods');
check(detail.totalLabels.length === 6, 'paged detail view must show six totals');
check(detail.buttons.filter(x => x.title === '刷新').length === 1, 'detail lost its refresh button');
check(!!findButton(detail, '更多操作'), 'detail lost the more-actions button');
check(!!findLabel(detail, '第 1 / 5 页'), 'detail paging caption changed');
check(!!findButton(detail, '‹ 上一页') && !!findButton(detail, '下一页 ›'), 'detail paging buttons changed');
// Inline mini bars compare each period against the range peak.
const minis = detail.boxes.filter(x => x.toolTip && String(x.toolTip).indexOf(' 积分 · ') >= 0 &&
  Math.abs(x.fillColor.r - gold.r) < 0.01 && Math.abs(x.fillColor.g - gold.g) < 0.01);
check(minis.length === 6, 'detail rows must carry a mini bar each, got ' + minis.length);
check(Math.max.apply(null, minis.map(x => x.frame.size.width)) <= 110.001,
  'mini bars must stay inside their 110pt track');
rowsDontOverlap(detail, detail.dateLabels, 'detail');
detail.dateLabels.concat(minis).forEach(node => inside(detail, node, 'detail row'));
// Top-model text stays on the second line of every row.
check(detail.labels.some(x => /^Auto \d/.test(x.stringValue.js)), 'row top-model text missing');

const secondPage = build('detail', 'day', 'paged', false, 4);
check(!!findLabel(secondPage, '第 5 / 5 页'), 'last detail page caption changed');
check(secondPage.dateLabels.length === 6, 'last page must still fill six periods');
const overflow = build('detail', 'day', 'paged', false, 99);
check(!!findLabel(overflow, '第 5 / 5 页'), 'an out-of-range page must clamp');

/* --------------------------------------------------------- chips and rows */

const viewChip = rect(findButton(detail, '总览'));
const rangeChip = rect(findButton(detail, '7 天'));
const groupChip = rect(findButton(detail, '按日'));
const modeChip = rect(findButton(detail, '悬停'));
check(viewChip.y === rangeChip.y, 'view and range chips are not on the same row');
check(viewChip.x + viewChip.w < rangeChip.x, 'view chips overlap the range chips');
check(groupChip.y === modeChip.y, 'group and mode chips are not on the same row');
check(groupChip.x + groupChip.w < modeChip.x, 'group chips overlap the mode chips');
check(groupChip.y + groupChip.h <= viewChip.y, 'group row overlaps the view row');
['刷新', '设置', '更多操作', '关闭'].forEach(title => {
  const button = findButton(detail, title);
  inside(detail, button, 'action button ' + title);
  check(rect(button).y + rect(button).h <= detail.H, 'action button below the panel edge');
});
const footerButtons = ['刷新', '设置', '更多操作', '关闭'].map(t => rect(findButton(detail, t)));
for (let i = 1; i < footerButtons.length; i++) {
  check(footerButtons[i - 1].x + footerButtons[i - 1].w <= footerButtons[i].x + 0.01,
    'footer buttons overlap');
}

/* ------------------------------------------------------------ grouping UI */

const weekUI = build('detail', 'week');
check(!!findLabel(weekUI, '按周'), 'weekly section header missing');
check(!!findLabel(weekUI, '本周'), 'weekly grouping must mark the current week');
check(weekUI.labels.some(x => /^共 \d+ 周$/.test(x.stringValue.js)), 'weekly count missing');
const weeklyPeriods = p.statsPeriods({ days: Object.keys(syntheticDays)
  .sort().reverse().map(k => Object.assign({ key: k }, syntheticDays[k])) }, 'week');
check(weekUI.dateLabels.length === Math.min(p.STATS_PAGE_SIZE, weeklyPeriods.length),
  'weekly page size changed');
check(weekUI.dateLabels.every(x => x.toolTip.indexOf('~') >= 0), 'weekly tooltip lost its range');
check(weekUI.totalLabels.length === weekUI.dateLabels.length, 'weekly totals are incomplete');
check(weekUI.totalLabels.some(x => / · \d+ 天$/.test(x.toolTip)), 'weekly totals must include active days');
check(weekUI.buttons.filter(x => x.title === '按周').length === 1, 'duplicate weekly chip');
const weekTrend = build('overview', 'week');
check(weekTrend.chartBars.length === weeklyPeriods.length,
  'weekly trend must draw one bar per week bucket');

const monthUI = build('detail', 'month');
check(!!findLabel(monthUI, '按月'), 'monthly section header missing');
check(!!findLabel(monthUI, '本月'), 'monthly grouping must mark the current month');
check(monthUI.labels.some(x => /^共 \d+ 个月$/.test(x.stringValue.js)), 'monthly count missing');
check(monthUI.dateLabels.length >= 1 && monthUI.dateLabels.length <= 2,
  'monthly view must show current and previous months');
check(monthUI.totalLabels.every(x => / · \d+ 天$/.test(x.toolTip)), 'monthly totals must include active days');

const directUI = build('detail', 'month', 'direct');
check(!!findLabel(directUI, '按月 · 最近 6 个月'), 'direct monthly caption changed');
check(!findButton(directUI, '‹ 上一页'), 'direct mode must not page');

/* -------------------------------------------------------------- empty UI */

const emptyDetail = build('detail', 'week', 'paged', true);
check(!!findLabel(emptyDetail, '暂无用量记录'), 'empty detail state missing');
check(emptyDetail.dateLabels.length === 0, 'empty detail rendered period rows');
check(!!findButton(emptyDetail, '更多操作'), 'empty detail lost its action row');
check(!!findLabel(emptyDetail, '暂无记录'), 'empty detail caption changed');

const emptyOverview = build('overview', 'day', 'paged', true);
check(emptyOverview.chartBars.length === 0, 'empty overview must not draw bars');
check(!!findLabel(emptyOverview, '暂无用量记录'), 'empty overview trend caption missing');
check(!!findLabel(emptyOverview, '暂无模型记录'), 'empty overview model caption missing');
check(emptyOverview.summaryLabels.length === 4, 'empty overview must still show four lines');
check(emptyOverview.summaryLabels.every(x => x.stringValue.js.indexOf('暂无用量记录') >= 0),
  'empty overview summary must say 暂无用量记录');

// One-month range with monthly grouping must collapse to a single bucket.
p.state.statsRange = 'month';
const singleUI = build('detail', 'month');
const monthCount = singleUI.labels.find(x => /^共 \d+ 个月$/.test(x.stringValue.js));
check(!!monthCount && monthCount.stringValue.js === '共 1 个月', 'monthly range did not collapse to one period');
check(singleUI.dateLabels.length === 1, 'single-month view must show one period');
check(!!findLabel(singleUI, '本月'), 'single-month view lost the current-month label');
check(!findButton(singleUI, '‹ 上一页'), 'a single detail page must hide the pager');
const singleOverview = build('overview', 'month');
check(singleOverview.chartBars.length === 1, 'single-month trend must draw one bar');
p.state.statsRange = '30d';

// A narrow screen must shrink the panel instead of overflowing it.
screen.frame.size.width = 520;
screen.visibleFrame.size.width = 520;
const narrow = build('overview', 'day');
check(narrow.W <= 520, 'panel must fit a narrow screen: ' + narrow.W);
narrow.nodes.forEach(node => inside(narrow, node, 'narrow panel child'));
screen.frame.size.width = 1440;
screen.visibleFrame.size.width = 1440;

console.log('stats-window checks: PASS=' + checks + ' FAIL=0');
