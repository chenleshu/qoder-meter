/*
 * macOS-only, offline AppKit PNG probe. Run in a logged-in graphical session:
 *   mkdir -p /tmp/qoder-meter-bars
 *   osascript -l JavaScript /absolute/path/to/macos/render-bar-probe.js \
 *     /absolute/path/to/macos/src/main.js /tmp/qoder-meter-bars
 *
 * Reads only the explicitly supplied source, never starts main(), and invokes
 * its real layout, controls, theme colors, rich text and updateUI with fixtures.
 * No Qoder data, saved settings, model discovery, timers, network or screenshot
 * permission are needed. PNGs cache the app's own NSView, not the user's screen.
 * The output directory must already exist. Existing probe PNGs are overwritten.
 */
function renderOfflineBars(outputDir) {
  const denyIO = function () { throw new Error('Offline render probe attempted application I/O'); };
  // Fail loudly if a rendering dependency starts calling the data/settings layer.
  main = denyIO;
  sh = denyIO;
  readString = denyIO;
  readBlock = denyIO;
  fileSize = denyIO;
  log = denyIO;
  loadSettings = denyIO;
  saveSettings = denyIO;
  loadModelLabels = denyIO;
  loadStatsCache = denyIO;
  refreshData = denyIO;
  collectDailyUsage = denyIO;
  readQoderWindowBounds = denyIO;
  qoderThemeMode = denyIO;
  fetchLatestRelease = denyIO;

  app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
  controller = $.QoderMeterController.alloc.init;
  const jobs = [];
  ['paper', 'graphite'].forEach(function (skin) {
    ['title', 'top', 'bottom'].forEach(function (mode) {
      FONT_SIZES.forEach(function (font) {
        jobs.push({ skin: skin, mode: mode, font: font.id, suffix: '', fields: null });
      });
    });
  });
  jobs.push({ skin: 'paper', mode: 'title', font: 'normal', suffix: '-all-off', fields: [] });
  jobs.push({ skin: 'paper', mode: 'top', font: 'normal', suffix: '-title-only', fields: ['title'] });
  jobs.push({ skin: 'paper', mode: 'bottom', font: 'normal', suffix: '-token-only', fields: ['token'] });
  jobs.push({ skin: 'paper', mode: 'bottom', font: 'normal', suffix: '-pills', fields: ['latency', 'status'] });
  jobs.push({ skin: 'graphite', mode: 'top', font: 'normal', suffix: '-sparse', fields: ['tps', 'credits', 'status'] });
  jobs.push({ skin: 'paper', mode: 'title', font: 'xlarge', suffix: '-narrow', fields: null, narrow: true });

  const outputs = [];
  const near = function (a, b) { return Math.abs(Number(a) - Number(b)) < 0.01; };
  jobs.forEach(function (job) {
    resetUI();
    state.layout = job.mode;
    state.fontSize = job.font;
    state.tokenUnit = 'latin';
    state.topInline = false;
    state.theme = job.skin;
    state.resolvedSkin = job.skin;
    T = SKINS[job.skin]; // No automatic theme detection or user preferences.
    applyFontScale();
    state.windowBounds = { x: 0, y: 0, width: job.narrow ? 680 : 10000, height: 900 };
    DISPLAY_FIELDS.forEach(function (field) {
      state.display[field.id] = job.fields === null || job.fields.indexOf(field.id) >= 0;
    });
    const now = Date.now();
    Object.assign(state, {
      sessionId: 'offline-render-fixture', title: '示例会话 · 界面优化', model: 'dfmodel',
      ctxStats: null, tps: 84.6, turnWall: 128, turnDuration: 8.4, turnTokens: 711,
      sessionStartedAt: now - 2241000, turnStartedAt: now - 128000,
      estOut: 28400, exactOut: 0, inputTokens: 0, credits: 6.25,
      requestCount: 12, toolCount: 34, promptCount: 4, turnRequestCount: 3,
      lastLatency: 1.8, inFlight: true, inFlightElapsed: 3.2, lastEventAt: now,
      lastTooltip: '', statsPinned: false, statsHover: false
    });
    const L = computeBarLayout(job.mode);
    state.barLayout = L;
    const root = makePanel(L.W, L.H);
    panel.setHasShadow(false);
    bgBox = box([0, 0, L.W, L.H], T.bg, 12, 1, T.border);
    root.addSubview(bgBox);
    buildBar(root, job.mode, L);
    state.uiReady = true;
    updateUI();

    if (L.separators.length !== Math.max(0, L.fields.length - 1)) {
      throw new Error('Unexpected separator count for ' + job.mode);
    }
    L.separators.forEach(function (line, index) {
      const previous = L.fields[index];
      const next = L.fields[index + 1];
      if (line.x < previous.x + previous.w + 4 - 0.01 || !near(line.x + line.w + 4, next.x)) {
        throw new Error('Orphan/overlapping separator for ' + job.mode);
      }
      let matches = 0;
      const children = root.subviews;
      for (let i = 0; i < Number(children.count); i++) {
        const child = children.objectAtIndex(i);
        const frame = child.frame;
        if (near(frame.origin.x, line.x) && near(frame.origin.y, line.y) &&
            near(frame.size.width, 1) && near(frame.size.height, 12 * L.S)) {
          if (!near(child.fillColor.alphaComponent, 0.35)) throw new Error('Incorrect native rule alpha');
          matches++;
        }
      }
      if (matches !== 1) throw new Error('Missing or duplicate native separator');
    });
    root.layoutSubtreeIfNeeded;
    root.displayIfNeeded;
    const bitmap = root.bitmapImageRepForCachingDisplayInRect(root.bounds);
    if (!bitmap || bitmap.isNil()) throw new Error('AppKit bitmap cache is unavailable');
    root.cacheDisplayInRectToBitmapImageRep(root.bounds, bitmap);
    const png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
    const file = outputDir + '/bar-' + job.mode + '-' + job.font + '-' + job.skin + job.suffix + '.png';
    if (!png || png.isNil() || !png.writeToFileAtomically(file, true)) {
      throw new Error('Unable to write PNG: ' + file);
    }
    outputs.push({ path: file, points: [L.W, L.H], pixels: [Number(bitmap.pixelsWide), Number(bitmap.pixelsHigh)],
      fields: L.fields.map(function (field) { return field.id; }), separators: L.separators.length });
    state.uiReady = false;
    panel.close;
    panel = null;
  });
  return JSON.stringify({ nativeAppKit: true, offlineFixtures: true, screenshots: outputs }, null, 2);
}

function run(argv) {
  if (argv.length !== 2 || argv[0][0] !== '/' || argv[1][0] !== '/') {
    throw new Error('Usage: osascript -l JavaScript render-bar-probe.js /absolute/src/main.js /absolute/existing-output-dir');
  }
  ObjC.import('Cocoa');
  const outputDir = argv[1].replace(/\/+$/, '') || '/';
  if (!$.NSFileManager.defaultManager.fileExistsAtPath(outputDir)) {
    throw new Error('Create the output directory first: ' + outputDir);
  }
  const raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!raw || raw.isNil()) throw new Error('Cannot read source: ' + argv[0]);
  const source = raw.js;
  if (!/\nmain\(\);\s*$/.test(source)) throw new Error('Refusing an unrecognized application entry point');
  const offlineSource = source.replace(/\nmain\(\);\s*$/, '\n');
  // The function is compiled in the same lexical scope as the real source, so
  // it uses private state and native builders without copying their logic.
  return Function('outputDir', offlineSource + '\nreturn (' + renderOfflineBars.toString() + ')(outputDir);')(outputDir);
}
