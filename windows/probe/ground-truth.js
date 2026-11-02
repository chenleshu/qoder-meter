/*
 * 独立口径实现（Node），用于交叉验证 PowerShell 移植版的数字。
 * 直接读同一批文件，按 macOS 版算法独立算一遍。
 */
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const HOME = process.env.USERPROFILE;
const DB = path.join(process.env.APPDATA, 'com.qoder.app.stable', 'main.sqlite');
const LV = path.join(process.env.APPDATA, 'com.qoder.app.stable', 'Local Storage', 'leveldb');
const PROJECTS = path.join(HOME, '.qoder', 'projects');
const SEGROOT = path.join(HOME, '.qoder', 'logs', 'sessions');
const CJK = /[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/g;

const db = new DatabaseSync(DB, { readOnly: true });
const payload = JSON.parse(db.prepare(`
select json_object(
  'window', coalesce((select value_json from app_settings where setting_key='window.workbenchBounds'),'null'),
  'sessions', (select json_group_array(json_object(
      'session_id', session_id,'title', title,'model', model,'cwd', cwd,
      'created_at', created_at,'updated_at', updated_at,'last_user_at', last_user_at,
      'prompt_count', prompt_count,'ctx_json', ctx_json
    )) from (
      select s.session_id, s.title, s.model, s.cwd, s.created_at, s.updated_at,
        (select max(created_at) from chat_session_messages m where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as last_user_at,
        (select count(*) from chat_session_messages m where m.session_id=s.session_id and m.role='user' and m.source='host-projection') as prompt_count,
        coalesce(u.snapshot_json,'') as ctx_json
      from chat_sessions s left join chat_session_context_usage u on u.session_id=s.session_id
      where s.archived=0 and s.deleted_at is null
      order by coalesce(last_user_at,0) desc, s.updated_at desc limit 10
    ))
) as payload`).get().payload);

// lastRoute
const re = /qoder\.workbench\.navigation\.lastRoute\.v1[\s\S]{0,300}?#\/(?:chat|A)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/g;
let activeId = null;
for (const f of fs.readdirSync(LV).map(n => ({ n, t: fs.statSync(path.join(LV, n)).mtimeMs })).sort((a, b) => b.t - a.t)) {
  if (!/\.(log|ldb)$/.test(f.n)) continue;
  const text = fs.readFileSync(path.join(LV, f.n)).toString('latin1');
  let m, last = null;
  while ((m = re.exec(text))) last = m[1];
  if (last) { activeId = last; break; }
}
const wantId = process.argv[2] || activeId;
const row = payload.sessions.find(s => s.session_id === wantId) || payload.sessions[0];

// sdk jsonl
function sdkPath(r) {
  const enc = String(r.cwd || '').replace(/[\\/]+$/, '').replace(/[\\/]/g, '-');
  const g = path.join(PROJECTS, enc, r.session_id + '.jsonl');
  if (fs.existsSync(g)) return g;
  for (const d of fs.readdirSync(PROJECTS)) {
    const p = path.join(PROJECTS, d, r.session_id + '.jsonl');
    if (fs.existsSync(p)) return p;
  }
  return null;
}
const sp = sdkPath(row);
const acc = { credits: 0, originalCredits: 0, estOut: 0, exactOut: 0, inputTokens: 0, assistantCount: 0, toolCount: 0, requestCount: 0, ids: new Set(), groups: [] };
if (sp) {
  for (const line of fs.readFileSync(sp, 'utf8').split('\n')) {
    if (!line) continue;
    let e; try { e = JSON.parse(line); } catch (x) { continue; }
    if (e.type !== 'assistant') continue;
    const msg = e.message || {};
    const content = Array.isArray(msg.content) ? msg.content : [];
    let chars = 0, cjk = 0, tools = 0;
    for (const b of content) {
      if (!b) continue;
      let t = '';
      if (b.type === 'text') t = b.text || '';
      else if (b.type === 'thinking') t = b.thinking || '';
      else if (b.type === 'tool_use') { t = JSON.stringify(b.input || {}); tools++; }
      else if (b.type === 'tool_result') continue;
      chars += t.length;
      const m = t.match(CJK); if (m) cjk += m.length;
    }
    const est = Math.round(cjk / 1.35 + (chars - cjk) / 3.8);
    const usage = msg.usage || {};
    const exact = Number(usage.output_tokens) || 0;
    const ts = Date.parse(e.timestamp) || 0;
    acc.assistantCount++;
    acc.toolCount += tools;
    acc.estOut += est;
    acc.exactOut += exact;
    acc.credits += Number(usage.credits) || 0;
    acc.originalCredits += Number(usage.original_credits) || 0;
    acc.inputTokens += (Number(usage.input_tokens) || 0) + (Number(usage.cache_read_input_tokens) || 0) + (Number(usage.cache_creation_input_tokens) || 0);
    if (usage.request_id) { if (!acc.ids.has(usage.request_id)) { acc.ids.add(usage.request_id); acc.requestCount++; } }
    else if (usage.credits || usage.output_tokens || usage.input_tokens) acc.requestCount++;
    if (!ts) continue;
    const last = acc.groups.length ? acc.groups[acc.groups.length - 1] : null;
    if (last && Math.abs(last.ts - ts) <= 12) { last.chars += chars; last.est += est; last.exact += exact; }
    else acc.groups.push({ ts, chars, est, exact });
  }
}

// segments
function segDir(sid) {
  const walk = (d, depth) => {
    if (depth > 3) return null;
    for (const en of fs.readdirSync(d, { withFileTypes: true })) {
      if (!en.isDirectory()) continue;
      const full = path.join(d, en.name);
      if (en.name === sid) return full;
      const r = walk(full, depth + 1);
      if (r) return r;
    }
    return null;
  };
  return walk(SEGROOT, 0);
}
let tps = null, turnRequestCount = 0, turnWall = 0, lastLatency = null, turnTokens = 0, turnDuration = 0, events = [];
const dir = row && segDir(row.session_id);
if (dir) {
  const segd = path.join(dir, 'segments');
  const files = fs.readdirSync(segd).filter(f => f.endsWith('.jsonl'))
    .map(f => ({ f, t: fs.statSync(path.join(segd, f)).mtimeMs })).sort((a, b) => b.t - a.t);
  if (files.length) {
    for (const line of fs.readFileSync(path.join(segd, files[0].f), 'utf8').split('\n')) {
      if (!line) continue;
      let e; try { e = JSON.parse(line); } catch (x) { continue; }
      if (!['turn.started', 'input.prompt.submitted', 'model.request.started', 'model.response.completed',
        'tool.requested', 'tool.execution.finished', 'tool.shell.started', 'tool.shell.finished'].includes(e.type)) continue;
      events.push({ type: e.type, ts: Date.parse(e.ts) || 0, turn_id: e.turn_id || null, request_id: e.request_id || null });
    }
  }
}
if (events.length) {
  let lastStart = null;
  for (let i = events.length - 1; i >= 0; i--) if (events[i].type === 'model.request.started') { lastStart = events[i]; break; }
  let turnId = lastStart ? lastStart.turn_id : null;
  if (!turnId) for (let i = events.length - 1; i >= 0; i--) if (events[i].type === 'turn.started') { turnId = events[i].turn_id; break; }
  let pool = turnId ? events.filter(e => e.turn_id === turnId) : events;
  if (!pool.length) pool = events.slice(-400);
  const starts = {}; const completions = [];
  let lastEventAt = 0;
  for (const e of pool) {
    const t = e.ts;
    if (t > lastEventAt) lastEventAt = t;
    if (e.type === 'model.request.started' && e.request_id) starts[e.request_id] = { ts: t, rid: e.request_id };
    else if (e.type === 'model.response.completed' && e.request_id && starts[e.request_id]) {
      const s = starts[e.request_id]; const dur = (t - s.ts) / 1000;
      if (dur >= 0 && dur < 900) completions.push({ id: e.request_id, start: s.ts, end: t, dur });
    }
  }
  let awaiting = null;
  for (const rid in starts) {
    if (!completions.find(c => c.id === rid) && starts[rid].ts > (awaiting ? awaiting.ts : 0)) awaiting = starts[rid];
  }
  const inFlight = !!(awaiting && Date.now() - awaiting.ts < 300000);
  completions.sort((a, b) => a.end - b.end);
  turnRequestCount = completions.length;
  if (completions.length) lastLatency = completions[completions.length - 1].dur;
  let turnStart = 0;
  for (const e of pool) if (e.type === 'turn.started' && !turnStart) turnStart = e.ts;
  if (!turnStart && completions.length) turnStart = completions[0].start;
  if (!turnStart && awaiting) turnStart = awaiting.ts;
  const recent = !!(lastEventAt && Date.now() - lastEventAt < 20000);
  const end = (inFlight || recent) ? Date.now() : (lastEventAt || Date.now());
  turnWall = turnStart ? Math.max(0, (end - turnStart) / 1000) : 0;
  const groups = acc.groups.filter(g => g.ts >= turnStart - 5000);
  const byC = {};
  for (const g of groups) {
    let best = -1, bestDiff = 1500;
    for (let j = 0; j < completions.length; j++) {
      const diff = Math.abs(completions[j].end - g.ts);
      if (diff < bestDiff) { bestDiff = diff; best = j; }
    }
    if (best >= 0) byC[best] = (byC[best] || 0) + (g.exact > 0 ? g.exact : g.est);
  }
  for (let i = 0; i < completions.length; i++) {
    const t = byC[i] || 0;
    if (t > 0 && completions[i].dur > 0) { turnTokens += t; turnDuration += completions[i].dur; }
  }
  if (turnDuration > 0) tps = turnTokens / turnDuration;
}

const ctx = row ? JSON.parse(row.ctx_json || '{}') : {};
const fmt = (n) => !n ? '0' : (n >= 1e6 ? (n / 1e6).toFixed(2) + 'm' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(Math.round(n)));
console.log('=== Node 独立口径（交叉验证基准）===');
console.log('session        :', row && row.session_id, activeId === row.session_id ? '(=lastRoute)' : '(fallback recent[0])');
console.log('title          :', row && row.title);
console.log('model          :', row && row.model, ' promptCount=', row && row.prompt_count);
console.log('created_at     :', row && row.created_at, ' age=' + (((Date.now() - (row && row.created_at)) / 1000).toFixed(0)) + 's');
console.log('credits        :', acc.credits.toFixed(6), ' original=', acc.originalCredits.toFixed(6));
console.log('requestCount   :', acc.requestCount);
console.log('toolCount(sdk) :', acc.toolCount, ' ctxStats.toolCalls.total=', ctx && ctx.sessionStats && ctx.sessionStats.toolCalls && ctx.sessionStats.toolCalls.total);
console.log('assistantCount :', acc.assistantCount);
console.log('exactOut       :', acc.exactOut, ' estOut=', acc.estOut, ' inputTokens=', acc.inputTokens);
console.log('groups         :', acc.groups.length);
console.log('seg events     :', events.length);
console.log('turnRequestCnt :', turnRequestCount, ' turnWall=', turnWall.toFixed(1) + 's', ' turnDuration=', turnDuration.toFixed(2) + 's');
console.log('tps            :', tps === null ? '—' : tps.toFixed(2), ' turnTokens=', turnTokens, ' lastLatency=', lastLatency);
console.log('out display    :', acc.exactOut > 0 ? fmt(acc.exactOut) : '~ ' + fmt(acc.estOut));
console.log('ctx totalTokens:', ctx && ctx.totalTokens, ' maxTokens=', ctx && ctx.maxTokens, ' percentage=', ctx && ctx.percentage);
