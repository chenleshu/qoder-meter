/*
 * Qoder Meter for Windows — 数据源可行性探针（只读）
 * 对应 macOS 版 main.js 的四个来源：
 *   1) main.sqlite  (chat_sessions / chat_session_messages / chat_session_context_usage / app_settings)
 *   2) Local Storage leveldb 里的 lastRoute
 *   3) ~/.qoder/projects/<encoded-cwd>/<session>.jsonl  (usage: credits / output_tokens / request_id)
 *   4) ~/.qoder/logs/sessions/.../<session>/segments/*.jsonl (turn/model/tool 事件)
 */
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const HOME = process.env.USERPROFILE || process.env.HOME;
const APPDATA = process.env.APPDATA;

const CANDIDATE_ROOTS = [
  { id: 'stable', dir: path.join(APPDATA, 'com.qoder.app.stable') },
  { id: 'cn', dir: path.join(APPDATA, 'com.qodercn.app.stable') },
];
const PROJECTS_ROOT = path.join(HOME, '.qoder', 'projects');
const SESSIONS_ROOT = path.join(HOME, '.qoder', 'logs', 'sessions');

const line = (t) => console.log('\n===== ' + t + ' =====');
const ok = (m) => console.log('  [OK] ' + m);
const bad = (m) => console.log('  [FAIL] ' + m);

/* ------------------------------------------------------------------ 1. sqlite */
line('1) main.sqlite 只读打开 + 口径 SQL');
let db = null, dbDir = null;
for (const c of CANDIDATE_ROOTS) {
  const p = path.join(c.dir, 'main.sqlite');
  if (!fs.existsSync(p)) { console.log('  -- ' + c.id + ': no main.sqlite'); continue; }
  try {
    const d = new DatabaseSync(p, { readOnly: true });
    const n = d.prepare('select count(*) as c from chat_sessions').get().c;
    db = d; dbDir = c.dir;
    ok(c.id + ': 只读打开成功, chat_sessions=' + n + ' 行');
    break;
  } catch (e) {
    bad(c.id + ': ' + e.message);
  }
}
if (!db) { console.log('\nsqlite 不可用，终止探针。'); process.exit(1); }

const sessionRow = db.prepare(`
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
limit 1
`).get();
if (sessionRow) {
  ok('最新会话可查: ' + sessionRow.session_id + ' / model=' + sessionRow.model +
     ' / prompt_count=' + sessionRow.prompt_count);
  console.log('     title=' + String(sessionRow.title).slice(0, 40));
  console.log('     cwd=' + sessionRow.cwd);
  console.log('     ctx_json 长度=' + (sessionRow.ctx_json || '').length +
     (sessionRow.ctx_json ? '  keys=' + Object.keys(JSON.parse(sessionRow.ctx_json)).slice(0, 12).join(',') : ''));
} else bad('会话查询返回空');

const win = db.prepare("select value_json from app_settings where setting_key='window.workbenchBounds'").get();
win ? ok('app_settings.window.workbenchBounds 存在') : bad('workbenchBounds 缺失（macOS 版用它做窗口兜底）');

/* -------------------------------------------------------------- 2. lastRoute */
line('2) Local Storage leveldb → lastRoute');
const RE_ROUTE = /qoder\.workbench\.navigation\.lastRoute\.v1[\s\S]{0,300}?#\/(?:chat|A)\/([0-9a-f]{8}-[0-9a-f-]{22,27})/g;
function scanRouteFile(p) {
  let buf;
  try { buf = fs.readFileSync(p); } catch (e) { return { err: e.message }; }
  const text = buf.toString('latin1');
  let m, last = null;
  while ((m = RE_ROUTE.exec(text))) last = m[1];
  return last ? { id: last } : {};
}
const lvDirs = CANDIDATE_ROOTS
  .map(c => path.join(c.dir, 'Local Storage', 'leveldb'))
  .filter(d => fs.existsSync(d));
let routeId = null;
for (const d of lvDirs) {
  const files = fs.readdirSync(d)
    .filter(f => /\.(log|ldb)$/.test(f))
    .map(f => ({ f, t: fs.statSync(path.join(d, f)).mtimeMs }))
    .sort((a, b) => b.t - a.t);
  for (const { f } of files) {
    const r = scanRouteFile(path.join(d, f));
    if (r.err) { bad(f + ': 读取被占用 ' + r.err); continue; }
    if (r.id) {
      routeId = r.id;
      ok(path.join(path.basename(d), f) + ' → 当前会话 ' + r.id + '（文件未被锁，可读）');
      break;
    }
  }
  if (routeId) break;
}
if (!routeId) bad('未从 leveldb 解析出 lastRoute');

/* --------------------------------------------------------------- 3. sdk jsonl */
line('3) projects/<encoded-cwd>/<session>.jsonl');
const sid = routeId || (sessionRow && sessionRow.session_id);
function findSdkFile(cwd, sessionId) {
  const guess = path.join(PROJECTS_ROOT, String(cwd || '').replace(/[\\/]+$/, '').replace(/[\\/]/g, '-'), sessionId + '.jsonl');
  if (fs.existsSync(guess)) return guess;
  if (!fs.existsSync(PROJECTS_ROOT)) return null;
  for (const d of fs.readdirSync(PROJECTS_ROOT)) {
    const p = path.join(PROJECTS_ROOT, d, sessionId + '.jsonl');
    if (fs.existsSync(p)) return p;
  }
  return null;
}
const sdkPath = sid && sessionRow ? findSdkFile(sessionRow.cwd, sid) : null;
if (sdkPath) {
  const size = fs.statSync(sdkPath).size;
  ok('找到 ' + sdkPath.replace(HOME, '~') + ' (' + Math.round(size / 1024) + ' KB)');
  const text = fs.readFileSync(sdkPath, 'utf8');
  let assistant = 0, withUsage = 0, credits = 0, exactOut = 0, reqIds = new Set();
  for (const l of text.split('\n')) {
    if (!l) continue;
    let e; try { e = JSON.parse(l); } catch (err) { continue; }
    if (e.type !== 'assistant') continue;
    assistant++;
    const u = (e.message || {}).usage || {};
    if (Object.keys(u).length) withUsage++;
    credits += Number(u.credits) || 0;
    exactOut += Number(u.output_tokens) || 0;
    if (u.request_id) reqIds.add(u.request_id);
  }
  console.log('     assistant行=' + assistant + ' 含usage行=' + withUsage +
    ' 去重请求数=' + reqIds.size);
  (assistant && withUsage) ? ok('积分累计=' + credits.toFixed(2) + ' 精确输出token=' + exactOut)
    : bad('jsonl 里没有 usage 字段 → Token/积分口径需要改走 sqlite ctx_json');
} else bad('未找到 sdk jsonl（TPS 估算将不可用）');

/* ------------------------------------------------------------ 4. segments */
line('4) logs/sessions/**/<session>/segments/*.jsonl');
function findSegmentFile(sessionId) {
  if (!fs.existsSync(SESSIONS_ROOT)) return null;
  const stack = [{ d: SESSIONS_ROOT, depth: 0 }];
  while (stack.length) {
    const { d, depth } = stack.pop();
    if (depth > 3) continue;
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { continue; }
    for (const en of ents) {
      if (!en.isDirectory()) continue;
      const full = path.join(d, en.name);
      if (en.name === sessionId) {
        const seg = path.join(full, 'segments');
        if (fs.existsSync(seg)) {
          const files = fs.readdirSync(seg).filter(f => f.endsWith('.jsonl'))
            .map(f => ({ f, t: fs.statSync(path.join(seg, f)).mtimeMs }))
            .sort((a, b) => b.t - a.t);
          if (files.length) return path.join(seg, files[0].f);
        }
      }
      stack.push({ d: full, depth: depth + 1 });
    }
  }
  return null;
}
const segPath = sid ? findSegmentFile(sid) : null;
if (segPath) {
  ok('找到 ' + segPath.replace(HOME, '~'));
  const SEG_TYPES = new Set(['turn.started', 'input.prompt.submitted', 'model.request.started',
    'model.response.completed', 'tool.requested', 'tool.execution.finished',
    'tool.shell.started', 'tool.shell.finished']);
  const counts = {};
  const text = fs.readFileSync(segPath, 'utf8');
  for (const l of text.split('\n')) {
    if (!l) continue;
    let e; try { e = JSON.parse(l); } catch (err) { continue; }
    if (SEG_TYPES.has(e.type)) counts[e.type] = (counts[e.type] || 0) + 1;
  }
  const ks = Object.keys(counts);
  ks.length ? ok('事件类型命中: ' + ks.map(k => k + '×' + counts[k]).join(', '))
    : bad('segment 内没有已知事件类型');
} else bad('未找到 segment 文件（本轮时长/状态将不可用）');

/* ------------------------------------------------------- 5. Qoder 进程与窗口 */
line('5) Qoder 进程');
try {
  const procs = fs.readdirSync('C:/'); // no-op keeps try block meaningful
} catch (e) {}
console.log('  -- 进程/窗口需由 PowerShell EnumWindows 验证，见 next step');
