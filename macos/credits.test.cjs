'use strict';

// Offline: node /absolute/path/to/macos/credits.test.cjs
// Runs the real source with AppKit/shell mocks, NOT main().
// Every shell command, file write and notification is recorded instead of
// executed: no Qoder install, credentials, LaunchAgent, or network is touched.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sourcePath = path.join(__dirname, 'src', 'main.js');
const source = fs.readFileSync(sourcePath, 'utf8');
assert.match(source, /\nmain\(\);\s*$/, 'Refuse to load an unrecognized application entry point');
assert.match(source, /function tickCredits\(\)/, 'tickCredits is missing');

const shellCalls = [];
const notifications = [];
const fileWrites = {};
const files = {};
const HOME = '/offline-probe-no-user-data';
const SETTINGS_DIR = HOME + '/Library/Application Support/QoderMeter';
const HELPER = '/offline-bundle/Contents/Resources/credits.py';
const AGENT_PLIST = HOME + '/Library/LaunchAgents/com.qoder.meter.credits.plist';

function color(r, g, b, alpha) {
  return { r, g, b, alpha, colorWithAlphaComponent(a) { return color(r, g, b, a); } };
}

function view(kind) {
  const v = { kind, children: [], title: '', stringValue: { js: '' },
    initWithFrame(frame) { this.frame = frame; return this; },
    initWithTitleActionKeyEquivalent(title) { this.title = title; return this; },
    initWithContentRectStyleMaskBackingDefer(rect) {
      this.rect = rect;
      this.contentView = view('NSView');
      return this;
    },
    addSubview(child) { this.children.push(child); return this; },
    initWithFramePullsDown(rect) { this.rect = rect; return this; },
    addItemWithTitle(text) { (this.items = this.items || []).push(text); return this; },
    selectItemAtIndex(index) { this.selected = index; return this; },
    setStringValue(text) { this.stringValue = { js: text }; },
    addItem(item) { this.children.push(item); return this; },
    itemAtIndex(i) { return this.children[i]; },
    numberOfItems() { return this.children.length; },
    contentRectForBodyRect(rect) { return rect; },
    setContentView() { return this; }
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

function walk(node, out) {
  if (!node || typeof node !== 'object') return out;
  out.push(node);
  if (node.contentView) walk(node.contentView, out);
  (node.children || []).forEach(child => walk(child, out));
  return out;
}

let frozenMs = Date.parse('2026-11-02T03:00:00Z'); // 11:00 in UTC+8
let helperPresent = true;
const RealDate = Date;
class FrozenDate extends RealDate {
  constructor(...args) {
    if (args.length === 0) super(frozenMs);
    else super(...args);
  }
  static now() { return frozenMs; }
}

const api = {
  NSHomeDirectory: () => ({ js: HOME }),
  NSColor: {
    colorWithCalibratedRedGreenBlueAlpha: color,
    colorWithCalibratedWhiteAlpha: (w, a) => color(w, w, w, a),
    secondaryLabelColor: 'secondary', labelColor: 'label',
    controlTextColor: 'control', textColor: 'text', separatorColor: 'separator'
  },
  NSFont: {
    systemFontOfSizeWeight: (size, weight) => ({ size, weight }),
    systemFontOfSize: size => ({ size }),
    monospacedDigitSystemFontOfSizeWeight: (size, weight) => ({ size, weight })
  },
  NSFontWeightRegular: 0, NSFontWeightMedium: 0.23, NSFontWeightSemibold: 0.3,
  NSFontAttributeName: 'font', NSForegroundColorAttributeName: 'color',
  NSButtonTypeSwitch: 0, NSBezelStyleRounded: 1,
  NSLineBreakByTruncatingTail: 4, NSFileSize: 'NSFileSize',
  NSUTF8StringEncoding: 4, NSBackingStoreBuffered: 2,
  NSDictionary: { dictionaryWithObjectForKey: font => font },
  NSScreen: { mainScreen: { frame: { size: { width: 4096 } } } },
  NSMakeRect: (x, y, w, h) => ({ origin: { x, y }, size: { width: w, height: h } }),
  NSMakePoint: (x, y) => ({ x, y }),
  NSMakeSize: (w, h) => ({ width: w, height: h }),
  NSMakeEdgeInsets: () => ({}),
  NSAffineTransform: { transform: () => ({ scaleXBy: () => {}, transformRect: r => r }) },
  NSTextField: viewClass('NSTextField'), NSBox: viewClass('NSBox'),
  NSImageView: viewClass('NSImageView'), NSButton: viewClass('NSButton'),
  NSMenu: viewClass('NSMenu'), NSMenuItem: viewClass('NSMenuItem'),
  NSPopUpButton: viewClass('NSPopUpButton'), NSWindow: viewClass('NSWindow'),
  NSStatusBar: { systemStatusBar: { statusItemWithLength: () => view('NSStatusItem') } },
  NSImage: { imageWithSystemSymbolNameAccessibilityDescription: () => ({ isNil: () => true }) },
  NSAppearance: { appearanceNamed: () => ({ isNil: () => true }) },
  NSAppearanceNameAqua: 'aqua', NSAppearanceNameDarkAqua: 'dark',
  NSApplication: { sharedApplication: () => view('NSApplication') },
  // The bundle helper and the agent plist are the only paths this probe fakes.
  NSBundle: { mainBundle: { resourcePath: { js: '/offline-bundle/Contents/Resources' } } },
  NSMutableAttributedString: { get alloc() {
    return { get init() {
      const a = { text: '', attributes: [], segments: [],
        addAttributeValueRange(key, value, range) { this.attributes.push({ key, value, range }); },
        appendAttributedString(segment) { this.text += segment.text; } };
      a.mutableString = { setString(text) { a.text = text; } };
      return a;
    } };
  } },
  NSString: {
    stringWithContentsOfFileEncodingError(file) {
      const text = files[String(file)];
      if (typeof text !== 'string') return { isNil: () => true };
      return { isNil: () => false, js: text };
    },
    get alloc() {
      return { initWithString(text) {
        return { isNil: () => false, js: text,
          writeToFileAtomicallyEncodingError(file) {
            fileWrites[String(file)] = text;
            return true;
          } };
      } };
    }
  },
  NSUserDefaults: { standardUserDefaults: { stringForKey: () => ({ isNil: () => true }) } }
};
api.NSFileManager = { defaultManager: {
  fileExistsAtPath(p) {
    const key = String(p);
    if (key === HELPER) return helperPresent;
    if (key in files) return true;
    return key === AGENT_PLIST ? !!files[AGENT_PLIST] : false;
  },
  attributesOfItemAtPathError() { return { isNil: () => true }; },
  removeItemAtPathError(p) { delete files[String(p)]; return true; },
  createDirectoryAtPathWithIntermediateDirectoriesAttributesError() { return true; }
} };
api.NSObject = { alloc: { init: () => view('NSObject') } };

const objc = new Proxy(api, { get(target, name) {
  if (name in target) return target[name];
  throw new Error('Offline probe has no AppKit mock for: ' + String(name));
} });

const context = vm.createContext({
  $: objc,
  ObjC: { import() {}, registerSubclass() {} },
  Date: FrozenDate,
  JSON, console,
  Application: { currentApplication: () => ({
    includeStandardAdditions: true,
    doShellScript(cmd) {
      const text = String(cmd);
      shellCalls.push(text);
      // osascript notifications are captured, never run.
      const match = /display notification "([^"]*)"/.exec(text);
      if (match) notifications.push(match[1]);
      return '';
    }
  }) }
});

vm.runInContext(source.replace(/\nmain\(\);\s*$/, '\n') + `
  globalThis.probe = {
    state, loadSettings, saveSettings, refreshCreditState, creditDayKey,
    creditMenuTitle, creditMenuAction, creditButtonTitle, creditButtonEnabled,
    creditButtonTip, syncCreditAgent, toggleAutoClaim, tickCredits,
    claimCreditsNow, startCreditLogin, creditResultNotify, menuSignature,
    buildSettingsWindow, updateSettingsControls, settingsRoot: function () { return settingsPanel; },
    paths: { SETTINGS_DIR: SETTINGS_DIR, CRED_PATH: CRED_PATH, CRED_STATE_PATH: CRED_STATE_PATH,
      CRED_LOGIN_PATH: CRED_LOGIN_PATH, CRED_AGENT_PLIST: CRED_AGENT_PLIST,
      HELPER: $.NSBundle.mainBundle.resourcePath.js + '/credits.py' }
  };
`, context, { filename: sourcePath, timeout: 10000 });

const p = context.probe;
let checks = 0;
const ok = (condition, label) => { checks++; assert.ok(condition, label); };
const eq = (actual, expected, label) => {
  checks++;
  assert.equal(actual, expected, label + ' (got ' + JSON.stringify(actual) + ')');
};

function creditFile(obj) { files[p.paths.CRED_PATH] = JSON.stringify(obj); }
function stateFile(obj) { files[p.paths.CRED_STATE_PATH] = JSON.stringify(obj); }
function loginFile(obj) { files[p.paths.CRED_LOGIN_PATH] = JSON.stringify(obj); }
function resetWorld() {
  Object.keys(files).forEach(key => { delete files[key]; });
  Object.keys(fileWrites).forEach(key => { delete fileWrites[key]; });
  shellCalls.length = 0;
  notifications.length = 0;
}
function lastCommands() { return shellCalls.slice(-6).join('\n'); }

/* ------------------------------------------------------------ 1. settings */
resetWorld();
files[p.paths.SETTINGS_DIR + '/settings.json'] = JSON.stringify({ autoClaim: false });
p.state.recent = [];
p.loadSettings();
eq(p.state.autoClaim, false, 'autoClaim:false is loaded from settings.json');
p.state.autoClaim = true;
p.saveSettings();
checks++;
assert.match(fileWrites[p.paths.SETTINGS_DIR + '/settings.json'] || '',
  /"autoClaim": true/, 'saveSettings persists autoClaim');

/* ------------------------------------------------------- 2. 10:00 UTC+8 */
resetWorld();
frozenMs = Date.parse('2026-11-02T01:30:00Z'); // 09:30 in UTC+8, still yesterday
eq(p.creditDayKey(), '2026-11-01', 'Before 10:00 UTC+8 belongs to the previous window');
frozenMs = Date.parse('2026-11-02T02:00:00Z'); // 10:00 in UTC+8
eq(p.creditDayKey(), '2026-11-02', 'From 10:00 UTC+8 the daily window opens');

/* ------------------------------------------------- 3. state file mapping */
resetWorld();
creditFile({ deviceToken: 'dt', email: 'dev@example.com' });
stateFile({ claimedDay: p.creditDayKey(), outcome: 'claimed', credit: 100,
  nextCheckAt: '2030-01-01T00:00:00Z', signInExpired: false, lastAttemptAt: '2026-11-02T02:05:00Z' });
loginFile({ status: 'success' });
p.refreshCreditState();
eq(p.state.creditLoggedIn, true, 'deviceToken means logged in');
eq(p.state.creditEmail, 'dev@example.com', 'email drives the settings tooltip');
eq(p.state.creditClaimedToday, true, 'claimedDay matching today marks the claim done');
eq(p.state.creditPendingLogin, false, 'a finished login is no longer pending');
resetWorld();
loginFile({ status: 'pending' });
p.refreshCreditState();
eq(p.state.creditPendingLogin, true, 'status:pending is a waiting login');

/* ------------------------------------------------------ 4. menu routing */
resetWorld();
p.state.creditBusy = false;
const titles = [];
const pick = () => { titles.push(p.creditMenuTitle()); return p.creditMenuAction(); };
loginFile({}); creditFile({}); stateFile({});
p.refreshCreditState();
eq(pick(), 'loginCredits:', 'logged out routes to login');
ok(/登录 Qoder/.test(titles[titles.length - 1]), 'logged out title asks for login');
p.state.creditPendingLogin = true;
eq(pick(), 'showCreditLogin:', 'a pending login routes to opening the URL again');
ok(/等待浏览器/.test(titles[titles.length - 1]), 'pending title waits for the browser');
p.state.creditPendingLogin = false;
p.state.creditSignInExpired = true;
eq(pick(), 'loginCredits:', 'an expired session routes back to login');
p.state.creditSignInExpired = false;
p.state.creditLoggedIn = true;
p.state.creditClaimedToday = false;
eq(pick(), 'claimCreditsNow:', 'a live session claims on demand');
p.state.creditClaimedToday = true;
ok(/今日已领 100 Credits ✓/.test(p.creditMenuTitle()), 'claimed title is terminal for the day');

/* ------------------------------------------------ 5. agent plist sync */
resetWorld();
creditFile({ deviceToken: 'dt' });
p.state.autoClaim = false;
p.state.creditBusy = false;
p.syncCreditAgent();
files[AGENT_PLIST] = 'stale';
p.state.autoClaim = false;
p.syncCreditAgent();
ok(/bootout/.test(lastCommands()) && /rm -f/.test(lastCommands()),
  'autoClaim off uninstalls the credits LaunchAgent');
checks++;
assert.equal(fileWrites[AGENT_PLIST], undefined, 'autoClaim off never rewrites the plist');
resetWorld();
p.state.autoClaim = true;
p.syncCreditAgent();
const plist = fileWrites[AGENT_PLIST] || '';
for (const needle of ['com.qoder.meter.credits', '/usr/bin/python3', HELPER,
  '<string>claim</string>', '<string>--auto</string>', '<key>StartInterval</key><integer>3600</integer>']) {
  checks++;
  assert.ok(plist.includes(needle), 'agent plist misses ' + needle);
}
ok(/bootstrap gui/.test(lastCommands()), 'autoClaim on bootstraps the agent for this login session');
// A bundle without credits.py must not leave an agent pointing at a missing helper.
resetWorld();
files[AGENT_PLIST] = 'stale';
p.state.autoClaim = true;
helperPresent = false;
p.syncCreditAgent();
helperPresent = true;
checks++;
assert.equal(fileWrites[AGENT_PLIST], undefined, 'a missing helper never rewrites the agent plist');
ok(/bootout/.test(lastCommands()) && /rm -f/.test(lastCommands()),
  'a missing helper tears the credits agent down instead of failing silently');

/* --------------------------------------------------- 6. tick auto claim */
const helperCalls = () => shellCalls.filter(line => /credits\.py/.test(line));
function dueState() {
  resetWorld();
  creditFile({ deviceToken: 'dt', email: 'dev@example.com' });
  stateFile({ outcome: 'failed', lastAttemptAt: '2026-11-01T02:00:00Z' });
  loginFile({ status: 'success' });
  p.state.creditBusy = false;
  p.state.creditBusyMark = '';
  p.state.creditAutoAt = 0;
  p.state.creditTickAt = 0;
  p.state.creditNotifiedKey = '';
  p.state.creditLastOutcome = '';
  p.state.autoClaim = true;
  p.refreshCreditState();
}
dueState();
p.tickCredits();
ok(/nohup .*credits\.py' claim(?! --auto)/.test(lastCommands()),
  'a due auto claim runs the helper with claim');
eq(p.state.creditBusy, true, 'starting a claim marks the task busy');

dueState();
p.state.autoClaim = false;
p.tickCredits();
eq(helperCalls().length, 0, 'autoClaim off never fires a claim from the UI');

dueState();
stateFile({ outcome: 'claimed', credit: 100, claimedDay: p.creditDayKey(),
  lastAttemptAt: '2026-11-01T02:00:00Z' });
p.refreshCreditState();
eq(p.state.creditClaimedToday, true, 'a recorded claim day is read back as done');
p.tickCredits();
eq(helperCalls().length, 0, 'a claim already recorded for today is not retried');

dueState();
stateFile({ nextCheckAt: new Date(frozenMs + 3600000).toISOString(),
  lastAttemptAt: '2026-11-01T02:00:00Z' });
p.refreshCreditState();
p.tickCredits();
eq(helperCalls().length, 0, 'nextCheckAt in the future defers the retry');

dueState();
p.tickCredits();
p.state.creditBusy = false;
p.state.creditTickAt = 0;
p.tickCredits();
eq(helperCalls().length, 1, 'the 10 minute UI throttle blocks a second attempt');

dueState();
const attempt = '2026-11-01T02:00:00Z';
stateFile({ outcome: 'failed', lastAttemptAt: attempt });
p.refreshCreditState();
p.state.creditBusy = true;
p.state.creditBusyMark = attempt;
p.state.creditBusyAt = frozenMs - 121000;
p.state.creditAutoAt = frozenMs - 1000; // the 10 minute gate must not refire yet
p.tickCredits();
eq(p.state.creditBusy, false, 'a hung claim task is released after two minutes');
eq(helperCalls().length, 0, 'releasing a hung task does not start another claim');

/* ----------------------------------------- 7. login handshake and result */
resetWorld();
creditFile({});
stateFile({});
loginFile({ status: 'pending' });
p.refreshCreditState();
p.state.creditBusy = false;
p.startCreditLogin();
ok(/credits\.py' login/.test(lastCommands()), 'login launches the device flow helper');
p.claimCreditsNow();
eq(p.state.creditBusy, true, 'a busy login is not interrupted by a manual claim');
loginFile({ status: 'success' });
creditFile({ deviceToken: 'dt', email: 'dev@example.com' });
notifications.length = 0;
shellCalls.length = 0;
p.state.creditTickAt = 0;
p.tickCredits();
ok(notifications.some(text => /登录成功/.test(text)), 'a finished login notifies and starts the claim');
ok(/credits\.py' claim/.test(lastCommands()), 'login success immediately claims the daily grant');

notifications.length = 0;
stateFile({ outcome: 'claimed', credit: 100, claimedDay: p.creditDayKey(),
  lastAttemptAt: new Date(frozenMs + 5000).toISOString() });
p.state.creditTickAt = 0;
p.state.creditBusyMark = 'claim|old';
p.state.creditNotifiedKey = '';
p.tickCredits();
ok(notifications.some(text => /已领取 100 Credits/.test(text)),
  'a claimed result raises one notification');
notifications.length = 0;
p.state.creditTickAt = 0;
p.tickCredits();
eq(notifications.length, 0, 'the same day and outcome is not notified twice');

/* ------------------------------------------- 8. settings window controls */
resetWorld();
p.buildSettingsWindow();
const controls = walk(p.settingsRoot(), []);
const checkbox = controls.find(node => node.title === '每天自动领取 100 Credits');
ok(checkbox, 'settings window offers the daily auto claim switch');
eq(checkbox && checkbox.action, 'settingsAutoClaimToggle:', 'switch action is wired');
const button = controls.find(node => node.action === 'settingsCreditAction:');
ok(button, 'settings window has the Credits login/claim button');
p.state.creditLoggedIn = false;
p.state.creditPendingLogin = false;
p.state.creditSignInExpired = false;
p.state.creditClaimedToday = false;
p.state.creditBusy = false;
p.updateSettingsControls();
eq(p.creditButtonTitle(), '登录 Qoder', 'logged out shows a login button');
ok(/登录后每天自动领取/.test(p.creditButtonTip()), 'logged out tooltip explains the grant');
p.state.creditLoggedIn = true;
p.state.creditClaimedToday = true;
p.updateSettingsControls();
eq(p.creditButtonTitle(), '今日已领', 'a claimed day disables the button label');
eq(p.creditButtonEnabled(), false, 'a claimed day cannot be claimed again');
p.state.creditClaimedToday = false;
p.state.creditBusy = true;
eq(p.creditButtonTitle(), '领取中…', 'a running claim is labelled as busy');
eq(p.creditButtonEnabled(), false, 'a running claim is not clickable');

/* ------------------------------------- 9. menu rebuilds on credit change */
resetWorld();
p.state.recent = [];
p.state.creditOutcome = 'failed';
p.state.creditClaimedToday = false;
const before = p.menuSignature();
p.state.creditClaimedToday = true;
p.state.creditOutcome = 'claimed';
const afterClaim = p.menuSignature();
checks++;
assert.notEqual(afterClaim, before, 'a claim result changes the menu signature');
p.state.autoClaim = false;
checks++;
assert.notEqual(p.menuSignature(), afterClaim, 'the auto claim switch changes the menu signature');

const repoRoot = path.join(__dirname, '..');
const buildSh = fs.readFileSync(path.join(repoRoot, 'macos', 'build.sh'), 'utf8');
const uninstallSh = fs.readFileSync(path.join(repoRoot, 'macos', 'uninstall.sh'), 'utf8');
const workflow = fs.readFileSync(path.join(repoRoot, '.github', 'workflows', 'build.yml'), 'utf8');
const helper = fs.readFileSync(path.join(__dirname, 'src', 'credits.py'), 'utf8');
ok(buildSh.includes('cp "$ROOT/src/credits.py" "$TMP/Contents/Resources/credits.py"'),
  'build.sh ships the claim helper inside the bundle');
ok(uninstallSh.includes('com.qoder.meter.credits.plist'),
  'uninstall.sh removes the credits LaunchAgent');
ok(workflow.includes('QoderMeter.app/Contents/Resources/credits.py'),
  'CI proves the helper is packed before artifacts are uploaded');
for (const guard of ['row.get("actionType") != "CLAIM_BENEFIT"',
  'str(benefit.get("kind") or "").upper() != "CREDITS"', 'amount == 100', 'os.chmod(tmp, 0o600)']) {
  checks++;
  assert.ok(helper.includes(guard), 'claim helper misses safety guard ' + guard);
}

console.log('credits checks: PASS=' + checks + ' FAIL=0');
