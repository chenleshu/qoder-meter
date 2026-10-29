'use strict';

// Offline: node /absolute/path/to/macos/bar-separators.test.cjs
// Runs the real source with strict AppKit geometry/control mocks, NOT main().
// No packages, Qoder installation, settings, user data, or network are needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sourcePath = path.join(__dirname, 'src', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8');
assert.match(source, /\nmain\(\);\s*$/, 'Refuse to load an unrecognized application entry point');
const forbiddenCalls = [];
function forbidden(name) {
  forbiddenCalls.push(name);
  throw new Error('Offline probe forbids: ' + name);
}
function color(r, g, b, alpha) {
  return { r, g, b, alpha, colorWithAlphaComponent(a) { return color(r, g, b, a); } };
}
function view(kind) {
  const v = { kind, children: [], stringValue: { js: '' },
    initWithFrame(frame) { this.frame = frame; return this; },
    addSubview(child) { this.children.push(child); },
    setStringValue(text) { this.stringValue = { js: text }; },
    setAttributedStringValue(text) { this.attributed = text; this.stringValue = { js: text.text }; }
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
function attributed() {
  const a = { text: '', attributes: [], segments: [],
    addAttributeValueRange(key, value, range) { this.attributes.push({ key, value, range }); },
    appendAttributedString(segment) { this.text += segment.text; this.segments.push(segment); }
  };
  a.mutableString = { setString(text) { a.text = text; } };
  return a;
}
const screen = { frame: { size: { width: 4096 } } };
const api = function (text) {
  return { js: text, sizeWithAttributes(attrs) {
    let width = 0;
    for (const ch of String(text)) width += attrs.size * (ch.charCodeAt(0) >= 0x2e80 ? 1 : 0.56);
    return { width };
  } };
};
Object.assign(api, {
  NSHomeDirectory: () => ({ js: '/offline-probe-no-user-data' }),
  NSColor: { colorWithCalibratedRedGreenBlueAlpha: color,
    colorWithCalibratedWhiteAlpha: (w, a) => color(w, w, w, a) },
  NSFont: { systemFontOfSizeWeight: (size, weight) => ({ size, weight }),
    monospacedDigitSystemFontOfSizeWeight: (size, weight) => ({ size, weight }) },
  NSDictionary: { dictionaryWithObjectForKey: font => font },
  NSScreen: { mainScreen: screen },
  NSMakeRect: (x, y, w, h) => ({ origin: { x, y }, size: { width: w, height: h } }),
  NSMakeRange: (location, length) => ({ location, length }),
  NSTextField: viewClass('NSTextField'), NSBox: viewClass('NSBox'),
  NSImageView: viewClass('NSImageView'), NSButton: viewClass('NSButton'),
  NSImage: { imageWithSystemSymbolNameAccessibilityDescription: () => ({ isNil: () => true }) },
  NSMutableAttributedString: { get alloc() { return { get init() { return attributed(); } }; } },
  NSFontWeightRegular: 0, NSFontWeightMedium: 0.23, NSFontWeightSemibold: 0.3,
  NSFontAttributeName: 'font', NSForegroundColorAttributeName: 'color',
  NSLineBreakByTruncatingTail: 4
});
const objc = new Proxy(api, { get(target, name) {
  if (name in target) return target[name];
  return forbidden('ObjC.' + String(name));
} });
const context = vm.createContext({
  $: objc, ObjC: { import() {}, registerSubclass() {} },
  Application: { currentApplication: () => ({ doShellScript: () => forbidden('shell') }) }
});
vm.runInContext(source.replace(/\nmain\(\);\s*$/, '\n') + `
  globalThis.probe = {
    state, FONT_SIZES, DISPLAY_FIELDS, SKINS, applyFontScale, computeBarLayout,
    buildBar, resetUI, setBarMetrics, metricSampleFields,
    theme: function (id) { T = SKINS[id]; },
    controls: function () { return { metricLabels, titleLabel, tpsValue, latencyValue, stateLabel }; }
  };
`, context, { filename: sourcePath, timeout: 10000 });
const p = context.probe;
const order = ['title', 'tps', 'turn', 'age', 'token', 'credits', 'requests', 'tools', 'latency', 'status'];
const modes = ['title', 'top', 'bottom', 'top-inline'];
const widths = [240, 336, 480, 780, 1280, 4096];
const near = (a, b) => assert.ok(Math.abs(a - b) < 0.001, `${a} != ${b}`);
let layouts = 0;
let builds = 0;
function verifyLayout(L, effectiveMode, width) {
  layouts++;
  assert.ok(L.W <= Math.max(width, Math.round(320 * L.S)));
  assert.equal(L.separator.width, 1);
  assert.equal(L.separator.padding, 4);
  assert.equal(L.separator.span, 9);
  near(L.separator.height, 12 * L.S);
  assert.equal(L.separators.length, Math.max(0, L.fields.length - 1));
  assert.equal(L.showMetrics, L.metrics.length > 0);
  let previousOrder = -1;
  L.fields.forEach((field, index) => {
    assert.ok(p.state.display[field.id], 'Disabled field is still allocated: ' + field.id);
    assert.ok(effectiveMode !== 'title' || field.id !== 'title');
    assert.ok(order.indexOf(field.id) > previousOrder, 'Field order changed');
    previousOrder = order.indexOf(field.id);
    assert.ok(Number.isFinite(field.x) && field.w > 0);
    assert.ok(field.x >= L.padL + L.dotHalo + L.dotGap);
    assert.ok(field.x + field.w <= L.statsX - Math.round(8 * L.S) + 0.001);
    if (!index) return;
    const prev = L.fields[index - 1];
    const line = L.separators[index - 1];
    assert.ok(field.x - prev.x - prev.w >= L.separator.span - 0.001, 'Overlapping fields');
    assert.ok(line.x >= prev.x + prev.w + 4 - 0.001, 'Rule overlaps preceding field');
    near(line.x + line.w + 4, field.x);
    near(line.w, 1);
    near(line.h, 12 * L.S);
    near(line.y + line.h / 2, L.H / 2);
    assert.ok(line.y >= 0 && line.y + line.h <= L.H);
  });
  // This also excludes a leading/title-only separator and a trailing rule before actions.
  if (L.fields.length <= 1) assert.equal(L.separators.length, 0);
  else {
    const last = L.fields[L.fields.length - 1];
    assert.ok(L.separators[L.separators.length - 1].x < last.x);
  }
  if (width === 4096) {
    const wanted = order.filter(id => p.state.display[id] && (id !== 'title' || effectiveMode !== 'title'));
    assert.deepEqual(Array.from(L.fields, f => f.id), wanted, 'Wide bar unexpectedly trimmed a field');
  }
}
function verifyBuild(L, mode, theme) {
  builds++;
  p.theme(theme);
  p.resetUI();
  assert.equal(Object.keys(p.controls().metricLabels).length, 0);
  const root = view('root');
  p.buildBar(root, mode, L); // Real box(), label(), rich text, and action-button builders.
  const controls = p.controls();
  assert.deepEqual(Object.keys(controls.metricLabels), Array.from(L.metrics, f => f.id));
  assert.equal(!!controls.titleLabel, L.showTitle);
  assert.equal(!!controls.tpsValue, L.showTps);
  assert.equal(!!controls.latencyValue, L.showLatency);
  assert.equal(!!controls.stateLabel, L.showStatus);
  const lines = root.children.filter(v => v.kind === 'NSBox' && v.fillColor.alpha === 0.35);
  assert.equal(lines.length, L.separators.length, 'Native rule count differs from layout');
  lines.forEach((line, index) => {
    const rect = L.separators[index];
    near(line.frame.origin.x, rect.x);
    near(line.frame.origin.y, rect.y);
    near(line.frame.size.width, rect.w);
    near(line.frame.size.height, rect.h);
    assert.equal(line.fillColor.r, p.SKINS[theme].gray.r);
    assert.equal(line.fillColor.g, p.SKINS[theme].gray.g);
    assert.equal(line.fillColor.b, p.SKINS[theme].gray.b);
    assert.equal(line.borderWidth, 0);
  });
  p.setBarMetrics(L, '2m 08s', '37m 21s', '≈ 28.4k', 6.25, 12, 34);
  const expected = { turn: '本轮 2m 08s', age: '总计 37m 21s', token: 'Token ≈ 28.4k',
    credits: '积分 6.25', requests: '12 请求', tools: '工具 34' };
  L.metrics.forEach(field => {
    const v = controls.metricLabels[field.id];
    assert.equal(v.attributed.text, expected[field.id]);
    assert.equal(v.lineBreakMode, 4);
    near(v.frame.origin.x, field.x);
    near(v.frame.size.width, field.w);
    assert.ok(!/[·|│]/.test(v.attributed.text), 'Text-based separator survived');
  });
  // Oversized runtime values stay in their own truncating controls, not a shared
  // label that could clip away a following field while leaving its separator.
  p.setBarMetrics(L, '999999h 59m', '999999h 59m', '≈ 9999999999亿', 1e12, 1e12, 1e12);
  L.metrics.forEach(field => near(controls.metricLabels[field.id].frame.size.width, field.w));
}
const skins = ['paper', 'graphite', 'ocean', 'dusk', 'sand'];
for (const mode of modes) for (const font of p.FONT_SIZES) for (const unit of ['latin', 'cn']) {
  p.state.fontSize = font.id;
  p.state.tokenUnit = unit;
  p.state.topInline = mode === 'top-inline';
  p.applyFontScale();
  const effectiveMode = mode === 'top-inline' ? 'title' : mode;
  for (const width of widths) {
    screen.frame.size.width = width + 16;
    p.state.windowBounds = { width: width + 360 };
    for (let mask = 0; mask < 1024; mask++) {
      p.DISPLAY_FIELDS.forEach((field, index) => { p.state.display[field.id] = !!(mask & (1 << index)); });
      const L = p.computeBarLayout(effectiveMode);
      verifyLayout(L, effectiveMode, width);
      // All off/on, every singleton/pair, and every single-field-off combination.
      const count = mask.toString(2).replace(/0/g, '').length;
      if (count <= 2 || count >= 9) verifyBuild(L, effectiveMode, skins[builds % skins.length]);
    }
  }
}
assert.deepEqual(forbiddenCalls, [], 'An offline check attempted non-rendering I/O');
console.log(`PASS: ${layouts} layouts, ${builds} real-source mock builds; all 1024 field masks, four sizes, both token units, narrow/wide bars, five skins. AppKit rendering is NOT tested here.`);
