'use strict';

// Offline: node /absolute/path/to/macos/stats-scan.test.cjs
// Runs the real scan engine with a scripted shell: find / stat / jq output all
// come from fixtures, and cache writes stay in memory. The jq stub burns the
// same wall time a real 2 MB session log costs, so the per-tick budget is
// actually exercised. No Qoder data, no disk, no network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sourcePath = path.join(__dirname, 'src', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8');
assert.match(source, /\nmain\(\);\s*$/, 'Refuse to load an unrecognized application entry point');

const HOME = '/offline-probe-no-user-data';
const SETTINGS_DIR = HOME + '/Library/Application Support/QoderMeter';
const written = {};
const JQ_MS = 130; // 真实机器上每个会话日志的 jq 解析耗时量级

const FILES = {
  '/p/a.jsonl': { size: 1000, mtime: 1730000000 },
  '/p/b.jsonl': { size: 2000, mtime: 1730000100 },
  '/p/c.jsonl': { size: 3000, mtime: 1730000200 },
  '/p/d.jsonl': { size: 4000, mtime: 1730000300 },
  '/p/e.jsonl': { size: 5000, mtime: 1730000400 }
};
// 每行: timestamp, model, credits, input, cacheRead, cacheWrite, output,
//       request_id, chars, cjk —— 第 11 列 input_filename 由夹具补上。
const ROWS = {
  '/p/a.jsonl': [
    ['2026-10-01T02:00:00Z', 'gmodel', '1.5', '10', '2', '0', '3', 'r-1', '200', '40'],
    ['2026-10-01T03:00:00Z', 'qmodel', '0.25', '0', '0', '0', '0', 'r-2', '380', '135'],
    ['2026-10-01T04:00:00Z', 'gmodel', '1.5', '10', '2', '0', '3', 'r-1', '200', '40'],
    ['2026-10-02T01:00:00Z', 'gmodel', '2', '5', '0', '0', '5', 'r-3', '10', '0']
  ],
  '/p/b.jsonl': [
    ['2026-10-01T05:00:00Z', 'gmodel', '0.75', '4', '1', '0', '1', 'r-4', '100', '0'],
    ['2026-10-03T06:00:00Z', 'unknown', '0', '0', '0', '0', '0', '', '76', '0']
  ],
  '/p/c.jsonl': [
    ['2026-10-02T07:00:00Z', 'qmodel', '3', '0', '0', '0', '0', 'r-5', '1350', '405']
  ],
  '/p/d.jsonl': [
    ['2026-10-04T08:00:00Z', 'dfmodel', '0.5', '6', '0', '0', '2', 'r-6', '40', '0'],
    ['2026-10-01T09:00:00Z', 'gmodel', '1', '0', '0', '0', '0', 'r-7', '190', '0']
  ],
  '/p/e.jsonl': [
    ['2026-10-05T10:00:00Z', 'gmodel', '4', '12', '3', '0', '9', 'r-8', '30', '0']
  ]
};
let present = Object.keys(FILES);
const jqBatches = [];

function tsvFor(list) {
  const out = [];
  for (const p of list) {
    for (const r of (ROWS[p] || [])) out.push(r.slice(0, 10).concat([p]).join('\t'));
  }
  return out.join('\n');
}

// 与改造前完全相同的整表算法，用作口径基准（rid 全局去重）。
function legacyAggregate(list) {
  const seen = {};
  const days = {};
  let rows = 0;
  for (const line of tsvFor(list || present).split('\n')) {
    if (!line) continue;
    const c = line.split('\t');
    if (c.length < 10) continue;
    if (c[7]) { if (seen[c[7]]) continue; seen[c[7]] = true; }
    const t = Date.parse(c[0]);
    if (!isFinite(t)) continue;
    const d = new Date(t);
    const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') +
      '-' + String(d.getDate()).padStart(2, '0');
    const credits = Number(c[2]) || 0;
    const exact = (Number(c[3]) || 0) + (Number(c[4]) || 0) +
      (Number(c[5]) || 0) + (Number(c[6]) || 0);
    const chars = Number(c[8]) || 0;
    const cjk = Number(c[9]) || 0;
    const estimated = exact > 0 ? 0 : Math.round(cjk / 1.35 + Math.max(0, chars - cjk) / 3.8);
    const tokens = exact > 0 ? exact : estimated;
    days[key] = days[key] || { credits: 0, tokens: 0, requests: 0, estimated: false, models: {} };
    const day = days[key];
    day.credits += credits; day.tokens += tokens; day.requests++;
    if (estimated > 0) day.estimated = true;
    const model = c[1] || 'unknown';
    day.models[model] = day.models[model] || { credits: 0, tokens: 0, requests: 0, estimated: false };
    const m = day.models[model];
    m.credits += credits; m.tokens += tokens; m.requests++;
    if (estimated > 0) m.estimated = true;
    rows++;
  }
  return { days: days, rows: rows };
}

function color(r, g, b, a) {
  return { r, g, b, a, colorWithAlphaComponent(x) { return color(r, g, b, x); } };
}
const api = {
  NSHomeDirectory: () => ({ js: HOME }),
  NSColor: { colorWithCalibratedRedGreenBlueAlpha: color,
    colorWithCalibratedWhiteAlpha: (w, a) => color(w, w, w, a) },
  NSUTF8StringEncoding: 4,
  NSString: {
    stringWithContentsOfFileEncodingError(file) {
      const text = written[String(file)];
      return typeof text === 'string' ? { isNil: () => false, js: text } : { isNil: () => true };
    },
    get alloc() {
      return { initWithString(text) {
        return { writeToFileAtomicallyEncodingError(file) { written[String(file)] = text; return true; } };
      } };
    }
  },
  NSFileManager: { defaultManager: {
    attributesOfItemAtPathError() { return { isNil: () => true }; }
  } }
};
const context = vm.createContext({
  $: new Proxy(api, { get: (t, n) => (n in t ? t[n] : undefined) }),
  ObjC: { import() {}, registerSubclass() {} },
  console,
  Application: { currentApplication: () => ({
    includeStandardAdditions: true,
    doShellScript(cmd) {
      const text = String(cmd);
      if (text.startsWith('/usr/bin/find')) return present.join('\n');
      if (text.includes('/usr/bin/stat -f')) {
        return present.filter(p => text.includes("'" + p + "'"))
          .map(p => p + '|' + FILES[p].size + '|' + FILES[p].mtime).join('\n');
      }
      if (text.includes('/usr/bin/jq -r')) {
        const batch = present.filter(p => text.includes("'" + p + "'"));
        const until = Date.now() + JQ_MS;
        while (Date.now() < until) { /* 模拟真实解析耗时 */ }
        jqBatches.push(batch);
        return tsvFor(batch);
      }
      return '';
    }
  }) }
});
vm.runInContext(source.replace(/\nmain\(\);\s*$/, '\n') + `
  globalThis.probe = {
    state, collectDailyUsage, tickStatsScan, statsScanNote,
    statsFileIndexRef: function () { return statsFileIndex; },
    STATS_INDEX_PATH: STATS_INDEX_PATH, STATS_SCAN_SLICE_FILES: STATS_SCAN_SLICE_FILES
  };
`, context, { filename: sourcePath, timeout: 20000 });

const p = context.probe;
let checks = 0;
const ok = (cond, label) => { checks++; assert.ok(cond, label); };
const eq = (a, b, label) => {
  checks++;
  assert.equal(a, b, label + ' (got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b) + ')');
};
const digest = days => JSON.stringify(Object.keys(days).sort().map(k => {
  const models = Object.keys(days[k].models).sort()
    .map(n => [n, Math.round(days[k].models[n].credits * 1e6), days[k].models[n].tokens,
      days[k].models[n].requests, !!days[k].models[n].estimated]);
  return [k, Math.round(days[k].credits * 1e6), days[k].tokens, days[k].requests,
    !!days[k].estimated, models];
}));

/* ------------------------------------------------------- 1. 冷启动切片 */
present = Object.keys(FILES);
jqBatches.length = 0;
p.state.statsCache = null;
p.state.statsScanning = false;
const coldStart = Date.now();
const cold = p.collectDailyUsage(false);
const coldMs = Date.now() - coldStart;
ok(coldMs < 2 * JQ_MS + 160, 'a cold open blocks for at most about two slices: ' + coldMs + 'ms');
eq(p.state.statsScanning, true, 'a cold open leaves the rest of the scan to the timer');
eq(jqBatches.length, 2, 'the cold open runs exactly the slices its time budget allows');
const scanned = jqBatches.reduce((acc, batch) => acc.concat(batch), []);
eq(scanned.length, 4, 'four of the five files are already indexed inline');
checks++;
assert.equal(digest(cold.days), digest(legacyAggregate(scanned).days),
  'the partial result equals the legacy scan over just those files');
ok(/正在补扫本机日志 4\/5/.test(p.statsScanNote()), 'the footer reports scan progress');

let ticks = 0;
while (p.state.statsScanning && ticks < 20) { p.tickStatsScan(); ticks++; }
eq(ticks, 1, 'one more tick finishes the last slice');
eq(jqBatches.length, 3, 'the whole cold scan costs three jq invocations for five files');
eq(p.state.statsScanning, false, 'the scan completes in the background');
eq(p.state.statsCache.rows, legacyAggregate().rows, 'the finished row count matches the legacy scan');
checks++;
assert.equal(digest(p.state.statsCache.days), digest(legacyAggregate().days),
  'daily and per-model aggregates match the legacy whole-tree scan');
eq(Object.keys(p.statsFileIndexRef()).length, 5, 'every scanned file is indexed');
checks++;
assert.equal(JSON.parse(written[p.STATS_INDEX_PATH]).v, 2, 'the index carries a version for drift');

/* ------------------------------------------------------ 2. 稳态不再重扫 */
jqBatches.length = 0;
p.state.statsCache = null;
const warm = p.collectDailyUsage(false);
eq(jqBatches.length, 0, 'reopening with unchanged logs runs no jq at all');
eq(p.state.statsScanning, false, 'a warm open finishes inside one call');
checks++;
assert.equal(digest(warm.days), digest(legacyAggregate().days), 'the warm aggregate is unchanged');

/* --------------------------------------------------- 3. 只重扫变化的文件 */
FILES['/p/c.jsonl'].size = 3600;
jqBatches.length = 0;
p.state.statsCache = null;
p.collectDailyUsage(false);
eq(jqBatches.length, 1, 'one changed file means one jq call');
checks++;
assert.deepEqual(jqBatches[0], ['/p/c.jsonl'], 'only the changed file is handed to jq');
checks++;
assert.equal(digest(p.state.statsCache.days), digest(legacyAggregate().days),
  'the aggregate stays correct after a file grows');

/* --------------------------------------------------------- 4. 删除轮转 */
present = ['/p/a.jsonl', '/p/b.jsonl', '/p/d.jsonl', '/p/e.jsonl'];
jqBatches.length = 0;
p.state.statsCache = null;
p.collectDailyUsage(false);
eq(jqBatches.length, 0, 'a removed file is dropped without any rescan');
checks++;
assert.ok(!('/p/c.jsonl' in p.statsFileIndexRef()), 'the index forgets deleted logs');
checks++;
assert.equal(digest(p.state.statsCache.days), digest(legacyAggregate().days),
  'totals drop together with the removed file');

/* ----------------------------------------------- 5. 空目录与异常清单 */
present = [];
jqBatches.length = 0;
p.state.statsCache = null;
const empty = p.collectDailyUsage(false);
eq(empty.rows, 0, 'no logs means no rows');
eq(jqBatches.length, 0, 'an empty tree never calls jq');
eq(p.state.statsScanning, false, 'an empty tree is not left scanning');

/* ------------------------------------------------------- 6. 关键接线 */
checks++;
assert.ok(/if \(statsPanel && !state\.statsHidden\) rebuildStatsWindow\(\);/.test(source),
  'a finished scan must not reopen a panel the user closed');
checks++;
assert.ok(/tickStatsScan\(\);/.test(source.split('function tick()')[1].split('\nfunction ')[0]),
  'the scan advances from the existing timer, not from a blocking call');
checks++;
assert.ok(!/collectDailyUsage\(true\)/.test(source),
  'no code path may force a synchronous full scan any more');
checks++;
assert.ok(/input_filename/.test(source), 'jq output carries the file name for per-file buckets');
checks++;
assert.ok(/statsScanNote\(\) \|\| state\.statsHint/.test(source),
  'the panel footer shows scan progress ahead of stale hints');

console.log('stats-scan checks: PASS=' + checks + ' FAIL=0');
