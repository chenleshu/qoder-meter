'use strict';

// Offline stats-grouping and stats-dashboard logic checks:
//   node --test macos/*.test.cjs        (repository-wide macOS test run)
//   node stats-grouping.test.cjs        (single file)
// Loads the real source without main(), with AppKit replaced by inert mocks.
// It checks local daily/weekly/monthly buckets, the dashboard aggregations
// (trend, model share, auto summary, paging, statsView persistence) only.
// It does not read Qoder data, open windows, run jq, or touch the network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sourcePath = path.join(__dirname, 'src', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8');
assert.match(source, /\nmain\(\);\s*$/, 'Refuse to load an unrecognized application entry point');
assert.match(source, /function statsPeriods\(data, group\)/, 'statsPeriods is missing');

let writtenSettings = null;
function color(r, g, b, alpha) {
  return { r, g, b, alpha, colorWithAlphaComponent(a) { return color(r, g, b, a); } };
}
const settingsFiles = {};
const api = {
  NSHomeDirectory: () => ({ js: '/offline-probe-no-user-data' }),
  NSColor: {
    colorWithCalibratedRedGreenBlueAlpha: color,
    colorWithCalibratedWhiteAlpha: (w, a) => color(w, w, w, a)
  },
  // Only what loadSettings/saveSettings need; no file system is touched.
  NSUTF8StringEncoding: 4,
  NSString: {
    stringWithContentsOfFileEncodingError: (file) => {
      const text = settingsFiles[String(file)];
      if (typeof text !== 'string') return { isNil: () => true };
      return { isNil: () => false, js: text };
    },
    get alloc() {
      return { initWithString: text => ({
        js: text,
        writeToFileAtomicallyEncodingError(file, atomically, encoding) {
          writtenSettings = { file: String(file), text, encoding };
          settingsFiles[String(file)] = text;
          return true;
        }
      }) };
    }
  },
  NSFileManager: { defaultManager: { fileExistsAtPath: () => false } }
};
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
    state, STATS_GROUPS, STATS_PAGE_SIZE, STATS_VIEWS, STATS_TREND_MAX,
    STATS_SUMMARY_WINDOWS, statsGroupMeta, statsPeriodKey, statsViewModel,
    statsPeriodLabel, statsPeriodTip, statsPeriods, statsWeekKey, statsDirectText,
    statsCacheRows, statsWindowTotals, statsSummaryRanges, statsSummaryLine,
    statsAutoSummary, statsChangeNote, statsTrend, statsTrendLabel,
    statsModelShares, statsPageCount, statsPageRows, dateKey, dayLabel,
    saveSettings, loadSettings, SETTINGS_PATH
  };
`, context, { filename: sourcePath, timeout: 10000 });
const p = context.probe;

let checks = 0;
function check(condition, message) {
  checks++;
  assert.ok(condition, message);
}
function same(actual, expected, message) {
  checks++;
  assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, message);
}
function model(name, credits, tokens, estimated) {
  return { name, credits, tokens, estimated: !!estimated };
}
function day(key, credits, tokens, requests, estimated, models) {
  return { key, credits, tokens, requests, estimated: !!estimated, models };
}

const sample = [
  day('2026-11-02', 10, 100, 1, false, [model('Auto', 10, 100)]),
  day('2026-11-01', 20, 200, 2, false, [model('Auto', 20, 200)]),
  day('2026-10-31', 30, 300, 3, false, [model('GLM-5.3', 30, 300)]),
  day('2026-10-26', 40, 400, 4, true, [
    model('Auto', 25, 250, true),
    model('GLM-5.3', 15, 150)
  ]),
  day('2026-10-25', 50, 500, 5, false, [model('Auto', 50, 500)]),
  day('2026-10-01', 60, 600, 6, false, [model('Qwen3.8-Max', 60, 600)])
];
const snapshot = JSON.stringify(sample);
function groups(list, group) {
  return p.statsPeriods({ days: list, models: [] }, group);
}

// Day grouping keeps the existing daily list and totals.
const daily = groups(sample, 'day');
check(daily.length === 6, 'day grouping must produce one bucket per active day');
same(daily.map(x => x.key), [
  '2026-11-02', '2026-11-01', '2026-10-31', '2026-10-26', '2026-10-25', '2026-10-01'
], 'day buckets must be newest first');
const novemberSecond = daily[0];
same([novemberSecond.credits, novemberSecond.tokens, novemberSecond.requests, novemberSecond.activeDays],
  [10, 100, 1, 1], 'day bucket totals changed');
check(novemberSecond.models.length === 1, 'day bucket model list changed');
check(p.statsPeriodLabel('day', p.dateKey(new Date())) === '今天', 'today label changed');
check(p.statsPeriodLabel('day', '2020-02-03') === '02-03', 'old day label changed');

// Monday–Sunday week bucketing, including month and year boundaries.
check(p.statsWeekKey('2026-10-25') === '2026-10-19', 'Sunday must belong to the previous Monday week');
check(p.statsWeekKey('2026-10-26') === '2026-10-26', 'Monday must start a new week');
check(p.statsWeekKey('2025-12-29') === '2025-12-29', 'week start across the year changed');
check(p.statsWeekKey('2026-01-04') === '2025-12-29', 'Sunday must join the December week');
check(p.statsPeriodLabel('week', '2025-12-29') === '12-29 ~ 01-04', 'cross-year week label changed');

const weekly = groups(sample, 'week');
same(weekly.map(x => x.key), [
  '2026-11-02', '2026-10-26', '2026-10-19', '2026-09-28'
], 'week buckets must be newest first');
const weekOfOctober26 = weekly[1];
same([weekOfOctober26.credits, weekOfOctober26.tokens, weekOfOctober26.requests,
  weekOfOctober26.activeDays], [90, 900, 9, 3], 'weekly totals changed');
check(weekOfOctober26.estimated === true, 'weekly estimate flag must be inherited');
check(weekOfOctober26.models.length === 2, 'weekly model list must merge duplicate models');
const auto = weekOfOctober26.models.find(m => m.name === 'Auto');
const glm = weekOfOctober26.models.find(m => m.name === 'GLM-5.3');
same([auto.credits, auto.tokens, auto.estimated], [45, 450, true],
  'weekly Auto totals changed');
same([glm.credits, glm.tokens, glm.estimated], [45, 450, false],
  'weekly GLM totals changed');
check(weekOfOctober26.models[0].credits >= weekOfOctober26.models[1].credits,
  'weekly models must be sorted by credits');
check(weekly[3].activeDays === 1, 'week with one active day changed');

const currentMonday = p.statsWeekKey(p.dateKey(new Date()));
check(p.statsPeriodLabel('week', currentMonday) === '本周', 'current week label changed');
const previousMondayDate = new Date();
previousMondayDate.setDate(previousMondayDate.getDate() - 7);
const previousMonday = p.statsWeekKey(p.dateKey(previousMondayDate));
check(p.statsPeriodLabel('week', previousMonday) === '上周', 'previous week label changed');

// Calendar-month bucketing.
const monthly = groups(sample, 'month');
same(monthly.map(x => x.key), ['2026-11', '2026-10'], 'month buckets must be newest first');
same([monthly[1].credits, monthly[1].tokens, monthly[1].requests, monthly[1].activeDays],
  [180, 1800, 18, 4], 'monthly totals changed');
same([monthly[0].credits, monthly[0].tokens, monthly[0].requests, monthly[0].activeDays],
  [30, 300, 3, 2], 'monthly November totals changed');
check(monthly[1].models.length === 3, 'monthly model list must merge duplicate models');

const now = new Date();
const currentMonthKey = p.dateKey(now).slice(0, 7);
check(p.statsPeriodLabel('month', currentMonthKey) === '本月', 'current month label changed');
const previousMonthDate = new Date(now.getFullYear(), now.getMonth() - 1, 1);
const previousMonthKey = p.dateKey(previousMonthDate).slice(0, 7);
check(p.statsPeriodLabel('month', previousMonthKey) === '上月', 'previous month label changed');
let otherMonth = 6;
if (otherMonth === now.getMonth()) otherMonth = 5;
if (otherMonth === previousMonthDate.getMonth()) otherMonth = 4;
const otherKey = now.getFullYear() + '-' + (otherMonth < 9 ? '0' : '') + (otherMonth + 1);
check(p.statsPeriodLabel('month', otherKey) === (otherMonth + 1) + ' 月',
  'same-year month label changed');
check(p.statsPeriodLabel('month', '2020-01') === '2020-01',
  'cross-year month label changed');

check(p.statsPeriodTip('week', '2026-10-26', { activeDays: 3 }) ===
  '2026-10-26 ~ 2026-11-01 · 3 天有记录', 'week tooltip changed');

// A partial range still produces complete week labels; labels use the full
// Monday–Sunday span while activeDays counts only days with records.
const partial = groups(sample.slice(2), 'week');
check(partial[0].activeDays === 2 && partial[0].key === '2026-10-26',
  'partial first week changed');

// Pure aggregation must not mutate the scan result.
check(JSON.stringify(sample) === snapshot, 'statsPeriods mutated its input');

check(p.statsGroupMeta('nope').id === 'day', 'invalid group must fall back to day');
check(p.statsGroupMeta('month').unit === '个月', 'month unit changed');
check(p.statsDirectText('week') === '最近 6 周', 'direct week caption changed');
check(p.statsDirectText('month') === '最近 6 个月', 'direct month caption changed');
check(p.statsDirectText('day') === '最近 6 天', 'direct day caption changed');
check(p.STATS_PAGE_SIZE === 6, 'detail page size changed');
check(p.STATS_TREND_MAX === 12, 'trend must cap at twelve periods');
check(p.state.statsGroup === 'day', 'default grouping must remain day');
same(p.STATS_GROUPS.map(g => g.id), ['day', 'week', 'month'], 'group order changed');

/* -------------------------------------------------------------- statsView */

same(p.STATS_VIEWS.map(v => v.id), ['overview', 'detail'], 'view order changed');
check(p.state.statsView === 'overview', 'the dashboard must open on 总览 by default');
check(p.statsViewModel('detail') === 'detail', 'detail view must be kept');
check(p.statsViewModel('overview') === 'overview', 'overview view must be kept');
check(p.statsViewModel('bogus') === 'overview', 'unknown statsView must fall back to overview');
check(p.statsViewModel(undefined) === 'overview', 'missing statsView must fall back to overview');
check(p.statsViewModel('') === 'overview', 'empty statsView must fall back to overview');

// save → load roundtrip keeps the saved view, and a broken file still falls back.
p.state.statsView = 'detail';
p.saveSettings();
check(!!writtenSettings, 'saveSettings produced no settings document');
check(JSON.parse(writtenSettings.text).statsView === 'detail', 'statsView was not persisted');
p.state.statsView = 'overview';
p.loadSettings();
check(p.state.statsView === 'detail', 'reopening must restore the saved statsView');
settingsFiles[p.SETTINGS_PATH] = '{"statsView":"weekly-report"}';
p.loadSettings();
check(p.state.statsView === 'overview', 'an invalid stored statsView must fall back to overview');
settingsFiles[p.SETTINGS_PATH] = '{"statsRange":"30d"}';
p.loadSettings();
check(p.state.statsView === 'overview', 'a statsView-less file must default to overview');
p.state.statsView = 'overview';
delete settingsFiles[p.SETTINGS_PATH];
writtenSettings = null;

/* -------------------------------------------------------------- auto summary */

// A fixed "today" keeps the four windows deterministic.
const TODAY = '2026-11-02';
function cacheRows(entries) {
  return entries.map(e => day(e.key, e.credits, e.tokens, e.requests, e.estimated, e.models));
}
const summaryRows = cacheRows(sample);
const summaries = p.statsAutoSummary(summaryRows, TODAY);
same(summaries.map(s => s.id), ['today', 'week7', 'month', 'all'],
  'auto summary must always emit the four fixed windows');
same(summaries.map(s => s.label), ['今天', '近 7 天', '本月', '全部'],
  'auto summary captions changed');
check(summaries.every(s => s.hasData), 'synthetic rows should light up every window');
check(summaries[0].text.indexOf('今天 · 10.00 积分') === 0, 'today line lost its credits');
check(summaries[0].text.indexOf('100 Token') >= 0, 'today line lost its tokens');
check(summaries[0].text.indexOf('1 请求') >= 0, 'today line lost its request count');
check(summaries[0].text.indexOf('活跃 1 天') >= 0, 'today line lost its active days');
check(summaries[0].text.indexOf('主力 Auto') >= 0, 'today line must name the leading model');
// 2026-11-01 held 20 credits, so today's 10 credits is a -50% step.
check(summaries[0].change === '较昨日 -50%', 'today must compare with yesterday: ' + summaries[0].change);
// 近 7 天 = 10-27 … 11-02 (60) against the same span before it (10-26 + 10-25 = 90).
same([summaries[1].totals.credits, summaries[1].totals.activeDays], [60, 3],
  'seven day window changed');
same([summaries[1].previous.start, summaries[1].previous.end], ['2026-10-20', '2026-10-26'],
  'seven day comparison window must be the same span immediately before');
same([summaries[1].previous.credits, summaries[1].change], [90, '较上 7 天 -33%'],
  'seven day comparison changed');
same([summaries[2].totals.credits, summaries[2].totals.activeDays], [30, 2],
  'month window changed');
same([summaries[3].start, summaries[3].end], ['2026-10-01', '2026-11-02'],
  '全部 must span every valid date in the cache');
same(summaries[3].totals.credits, 210, '全部 must total every cached day');
check(summaries[3].text.indexOf('日均 35.00 积分') >= 0, '全部 must add the daily average: ' + summaries[3].text);
check(summaries.every(s => s.text.indexOf('NaN') < 0 && s.text.indexOf('Infinity') < 0),
  'auto summary produced a non-finite number');

// A zero previous window must never divide.
const soloRows = cacheRows([day('2026-11-02', 12, 900, 3, false, [model('Lite', 12, 900)])]);
const solo = p.statsAutoSummary(soloRows, TODAY);
check(solo[0].change === '较昨日 新增', 'a zero yesterday must read 新增: ' + solo[0].change);
check(solo[1].change === '较上 7 天 新增', 'a zero previous week must not divide');
check(solo[3].change === '较上期 新增', 'the all window must still compare safely');
check(solo.every(s => s.text.indexOf('主力 Lite') >= 0), 'leading model missing from solo summary');
check(p.statsChangeNote(0, 0, '较昨日') === '较昨日 上期无记录', 'zero-over-zero must stay textual');
check(p.statsChangeNote(20, 20, '较昨日') === '较昨日 基本持平', 'equal windows must read 基本持平');
check(p.statsChangeNote(30, 20, '较昨日') === '较昨日 +50%', 'growth sign changed');
check(p.statsChangeNote(10, 20, '较昨日') === '较昨日 -50%', 'shrink sign changed');
check(p.statsChangeNote(20.05, 20, '较昨日') === '较昨日 基本持平', 'sub-percent drift stays 基本持平');
check(p.statsChangeNote(21, 20, '较昨日') === '较昨日 +5%', 'integer percent rounding changed');

// Empty caches still render the four fixed lines, each saying there is no data.
const empty = p.statsAutoSummary([], TODAY);
same(empty.map(s => s.hasData), [false, false, false, false], 'empty cache must not claim data');
check(empty.every(s => s.text.indexOf('暂无用量记录') >= 0), 'empty windows must say 暂无用量记录');
same(empty.map(s => s.label), ['今天', '近 7 天', '本月', '全部'], 'empty summary count changed');

// Friendly model names come from raw log ids, and invalid dates are dropped.
const rawCache = { days: {
  '2026-11-02': { credits: 6, tokens: 600, requests: 2, estimated: false,
    models: { qmodel: { credits: 6, tokens: 600, requests: 2, estimated: false } } },
  '2026-11-01': { credits: 4, tokens: 400, requests: 1, estimated: true,
    models: { 'qoder_dfmodel': { credits: 4, tokens: 400, requests: 1, estimated: true } } },
  'not-a-date': { credits: 99, tokens: 99, requests: 99, estimated: false, models: {} },
  '2026-10-32': { credits: 1, tokens: 1, requests: 1, estimated: false, models: {} },
  '2026-10-30': { credits: -5, tokens: 10, requests: 1, estimated: false, models: {} },
  '2026-10-29': { credits: 'oops', tokens: 10, requests: 1, estimated: false, models: {} }
} };
const cleaned = p.statsCacheRows(rawCache);
same(cleaned.map(r => r.key), ['2026-11-01', '2026-11-02'],
  'only well-formed local dates may enter the dashboard');
check(cleaned[1].models[0].name === 'Qwen3.7-Plus', 'raw model ids must be mapped for display');
check(cleaned[0].models[0].name === 'DeepSeek-V4-Flash', 'qoder- prefixed ids must normalize');
check(cleaned[0].estimated === true, 'the estimate flag must survive the cache read');
check(JSON.stringify(p.statsCacheRows(null)) === '[]', 'a missing cache must yield no rows');

/* ------------------------------------------------------------------- trend */

const trendDays = [];
for (let i = 0; i < 30; i++) {
  const d = new Date(2026, 10, 2);
  d.setDate(d.getDate() - i);
  const key = p.dateKey(d);
  trendDays.push(day(key, 10 + i, 100 + i, 1, false, [model('Auto', 10 + i, 100 + i)]));
}
const dayTrend = p.statsTrend({ days: trendDays, models: [] }, 'day');
check(dayTrend.count === p.STATS_TREND_MAX, 'trend must keep at most 12 periods');
check(dayTrend.bars.length === 12, 'trend bar list must match its count');
let ascending = true;
for (let i = 1; i < dayTrend.bars.length; i++) {
  if (dayTrend.bars[i].key <= dayTrend.bars[i - 1].key) ascending = false;
}
check(ascending, 'trend bars must run oldest → newest for left-to-right drawing');
check(dayTrend.bars[0].ratio === 1, 'the peak period must fill the plot height');
check(Math.max.apply(null, dayTrend.bars.map(b => b.ratio)) === 1,
  'at least one bar must reach the plot top');
same([dayTrend.basis, dayTrend.peak], ['credits', 21], 'trend basis changed');
same(dayTrend.total, 186, 'trend total must cover only the twelve kept periods');
check(dayTrend.bars[0].label === p.dayLabel(dayTrend.bars[0].key), 'day trend label changed');

const weekTrend = p.statsTrend({ days: trendDays, models: [] }, 'week');
check(weekTrend.bars.length <= 6, 'a 30-day span cannot produce more than six week buckets');
const weekKeys = [];
for (let i = 0; i < weekTrend.bars.length; i++) weekKeys.push(weekTrend.bars[i].key);
let weekAscending = true;
for (let i = 1; i < weekKeys.length; i++) {
  if (weekKeys[i] <= weekKeys[i - 1]) weekAscending = false;
}
check(weekAscending, 'weekly trend must stay oldest → newest');
same(weekKeys, ['2026-09-28', '2026-10-05', '2026-10-12', '2026-10-19', '2026-10-26', '2026-11-02'],
  'weekly trend buckets changed');
const monthTrend = p.statsTrend({ days: trendDays, models: [] }, 'month');
same(monthTrend.bars.map(b => b.key), ['2026-10', '2026-11'], 'monthly trend buckets changed');
same(monthTrend.bars.map(b => b.label), ['10月', '11月'], 'monthly trend labels changed');
check(p.statsTrend({ days: [], models: [] }, 'day').bars.length === 0, 'empty trend must stay empty');
check(p.statsTrend({ days: trendDays, models: [] }, 'nope').basis === 'credits',
  'an unknown group must still yield a usable series');

// Credits-less days fall back to tokens so the chart still draws something.
const tokenOnly = { days: [day('2026-11-02', 0, 500, 1, true, [model('Auto', 0, 500, true)]),
  day('2026-11-01', 0, 1000, 1, false, [model('Auto', 0, 1000)])], models: [] };
const tokenTrend = p.statsTrend(tokenOnly, 'day');
same([tokenTrend.basis, tokenTrend.peak, tokenTrend.total], ['tokens', 1000, 1500],
  'trend must switch to tokens when no credits were logged');
same(tokenTrend.bars.map(b => b.ratio), [1, 0.5], 'token trend ratios changed');

/* -------------------------------------------------------------- model share */

const fiveModels = [
  { name: 'Auto', credits: 50, tokens: 5000, estimated: false },
  { name: 'Qwen3.7-Max', credits: 25, tokens: 2500, estimated: false },
  { name: 'Kimi-K3', credits: 12.5, tokens: 1250, estimated: true },
  { name: 'Lite', credits: 7.5, tokens: 750, estimated: false },
  { name: 'Cantus', credits: 5, tokens: 500, estimated: false }
];
const creditShare = p.statsModelShares(fiveModels);
same(creditShare.basis, 'credits', 'credits must drive the share when present');
check(creditShare.rows.length === 4, 'the model mix must collapse to three plus 其他');
check(creditShare.rows[3].name.indexOf('其他') === 0, 'the tail row must be the 其他 bucket');
const shareSum = creditShare.rows.reduce((t, r) => t + r.share, 0);
check(Math.abs(shareSum - 1) < 1e-9, 'shares must add up to the whole: ' + shareSum);
same([creditShare.rows[0].name, creditShare.rows[0].share], ['Auto', 0.5], 'leading share changed');
same(p.statsModelShares([]).rows, [], 'no models must mean no share rows');
const zeroShare = p.statsModelShares([{ name: 'Lite', credits: 0, tokens: 800, estimated: true },
  { name: 'Auto', credits: 0, tokens: 200, estimated: false }]);
same(zeroShare.basis, 'tokens', 'a credits-free range must fall back to token shares');
same(zeroShare.rows.map(r => r.share), [0.8, 0.2], 'token shares changed');
const allZero = p.statsModelShares([{ name: 'Lite', credits: 0, tokens: 0, estimated: false }]);
check(allZero.rows[0].share === 0, 'a zero-total range must not divide');

/* ------------------------------------------------------------------ paging */

const manyPeriods = groups(trendDays, 'day');
check(manyPeriods.length === 30, 'daily buckets for a 30-day span changed');
same([p.statsPageCount(30, 6), p.statsPageCount(0, 6), p.statsPageCount(6, 6)], [5, 1, 1],
  'page count must follow the six-per-page detail list');
const first = p.statsPageRows(manyPeriods, 0, p.STATS_PAGE_SIZE);
check(first.rows.length === 6, 'detail pages hold six periods');
const firstPageKeys = [];
for (let i = 0; i < 6; i++) firstPageKeys.push(manyPeriods[i].key);
same(first.rows.map(r => r.key), firstPageKeys, 'first page order changed');
const last = p.statsPageRows(manyPeriods, 4, p.STATS_PAGE_SIZE);
same([last.page, last.pageCount, last.rows.length], [4, 5, 6], 'last page changed');
check(p.statsPageRows(manyPeriods, 99, p.STATS_PAGE_SIZE).page === 4,
  'an out-of-range page must clamp to the final page');
check(p.statsPageRows(manyPeriods, -3, p.STATS_PAGE_SIZE).page === 0,
  'a negative page must clamp to the first page');
same(p.statsPageRows([], 0, p.STATS_PAGE_SIZE).rows, [], 'an empty list must page as one empty page');
check(JSON.stringify(sample) === snapshot, 'dashboard aggregation mutated its input');

console.log('stats-grouping checks: PASS=' + checks + ' FAIL=0');
