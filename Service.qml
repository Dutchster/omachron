import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "lib/Model.js" as Model
import "lib/State.js" as State

// Omachron: long-running focus-time tracker.
//
// Watches the compositor's active toplevel (ToplevelManager) and accrues
// focused time per app into a per-day record persisted as JSON. No focused
// window means the clock is paused; idle/lock/desktop time is not counted.
//
// Persistence is a single append-only JSON file
//   ~/.config/omarchy/omachron/history.json
// shaped as
//   { "<YYYY-MM-DD>": { "total": <ms>, "apps": { "<appId>": <ms> } } }
//
// Writes are event-driven (on focus change) and debounced through the
// adapter; a 60s commit bounds how much of an in-flight bucket can be lost
// to a crash. Data survives plugin hot-reloads because it lives on disk.
//
// State transitions live in State.js (pure, testable). This file owns the
// side effects: timers, disk I/O, process spawning, and QML property
// bindings.
Item {
  id: root

  // Injected by omarchy-shell (the generic service loader).
  property var shell: null
  // State.js receives this explicitly because QML JavaScript modules do not
  // share the Model import from this file as a global.
  readonly property var stateModel: Model

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: home + "/.config/omarchy/omachron"
  readonly property string historyPath: dataDir + "/history.json"
  readonly property string resolverPath: {
    var u = Qt.resolvedUrl("scripts/resolve_app.py").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }
  readonly property string iconsDir: dataDir + "/icons"
  readonly property string iconFetcherPath: {
    var u = Qt.resolvedUrl("scripts/fetch_site_icon.sh").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }

  // Terminals report themselves as their windowing appId, but screen time
  // should reflect what is actually running inside them (opencode, btop…).
  // When the active toplevel is one of these, Service resolves the pty's
  // foreground process group via resolve_app.py.
  readonly property var terminalAppIds: ["foot", "alacritty", "kitty", "ghostty",
    "wezterm", "konsole", "gnome-terminal", "tilix", "xfce4-terminal", "termite", "st",
    "org.omarchy.terminal"]

  // Retention window in days. History older than this is pruned on load and
  // before every write, so the append-only JSON can't grow without bound.
  // Covers the 13-week paginated trend (~91 days) plus slack for week
  // alignment; anything older is rolled into monthly aggregates.
  readonly property int keepDays: 95

  // The gap check resolves suspends down to roughly this threshold: a 5s
  // heartbeat keeps lastTick fresh, so a tick arriving more than
  // suspendGapMs after the last one means the event loop was frozen —
  // the machine was asleep (or the clock jumped).
  readonly property int suspendGapMs: 30 * 1000
  property double lastTick: 0

  // ---- Live state, exposed to the bar widget and panel. These are always
  //      REPLACED with fresh objects, never mutated in place, so QML
  //      bindings on them fire and the persistence adapter sees the change.
  property string todayKey: Model.dayKey(new Date())
  property var today: Model.newDay()
  // Full history mirror (dayKey -> day); what the adapter persists.
  property var days: ({})
  // Monthly aggregates (YYYY-MM -> ms). Days dropped by the retention window
  // are rolled up here so calendar year/month totals survive pruning.
  property var months: ({})
  // Slacking-off membership overrides (tracking key -> bool). Only keys the
  // user disagrees with lib/slack_apps.json about are stored, so the shipped
  // defaults keep applying to everything else. REPLACED, never mutated.
  property var slack: ({})

  property string activeApp: ""
  property double activeStart: 0
  // appId as reported by the compositor; activeApp is the resolved tracking
  // name (identical unless the toplevel is a terminal, browser, or Steam
  // game).
  property string rawApp: ""
  property string resolveForApp: ""
  property bool resolveInFlight: false
  // Resolve freshness tokens: every resolve request bumps resolveGeneration;
  // resolveSpawnGen snapshots it only when a process actually launches.
  // State.applyResolvedApp discards results whose tokens differ, so an
  // in-flight answer for foot(A) can never be attributed to foot(B).
  property int resolveGeneration: 0
  property int resolveSpawnGen: 0
  property bool ready: false
  property bool startupPhase: true

  // ---- Session lock ------------------------------------------------------
  // Omarchy locks through ext-session-lock (the shell's own omarchy.lock
  // service), and a lock surface is not a toplevel: the compositor goes on
  // reporting the window that was focused when the screen locked, so the
  // heartbeat would accrue a whole night onto it. shouldTrack() cannot catch
  // this because the appId never changes, so the lock state is read from the
  // shell instead. The binding re-evaluates when the shell's service table is
  // replaced, and degrades to "never locked" on a shell that predates
  // serviceFor().
  readonly property var lockService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("omarchy.lock")
    : null
  readonly property bool sessionLocked: !!(lockService && lockService.locked)

  onSessionLockedChanged: {
    if (!root.ready) return
    var now = Date.now()
    if (root.sessionLocked) {
      // Bank what was earned up to the lock, then stop the clock. Bumping the
      // resolve generation discards any answer still in flight so it cannot
      // reopen a bucket behind the lock.
      applyState(State.closeActiveBucket(
        root, root.activeApp, root.activeStart, now,
        root.todayKey, root.suspendGapMs, root.lastTick))
      root.activeApp = ""
      root.activeStart = 0
      root.rawApp = ""
      root.resolveInFlight = false
      root.resolveGeneration++
      root.lastTick = now
      root.persist()
    } else {
      // The locked stretch is not screen time, so reset the suspend-gap
      // baseline before reopening a bucket for whatever now holds focus.
      root.lastTick = now
      root.switchActive()
    }
  }

  // ---- Site favicons. siteIcons maps domain -> true once
  // <iconsDir>/<domain>.png exists on disk; it is REPLACED, never mutated,
  // so panel bindings fire. Fetches run one at a time through
  // scripts/fetch_site_icon.sh, at most once per domain per shell session
  // (iconAttempted); a miss retries on the next shell start.
  property var siteIcons: ({})
  property int iconVersion: 0
  property var iconQueue: []
  property var iconAttempted: ({})
  property string iconFetching: ""
  property bool iconScanDone: false

  // ---- Public read API for the UI ----------------------------------------
  readonly property string barLabel: today ? Model.fmt(today.total) : ""
  readonly property bool hasActivity: today && today.total > 0

  function appList() { return Model.appList(root.today) }
  function insights() {
    return Model.insights(root.today, root.days, root.todayKey, root.todayKey,
                          root.slack, root.today)
  }
  readonly property double slackTotal: today ? Model.slackTotal(today, slack) : 0
  // Today's running total, for the bar widget's go-outside nudges.
  readonly property double todayTotal: today ? (today.total || 0) : 0
  // Exposed so the bar widget can build the Friday recap without reaching
  // into the persistence layer itself.
  readonly property var historyDays: root.days

  // Flips one entry's slacking membership and writes it straight through;
  // the panel calls this when a usage row is clicked.
  function toggleSlack(app) {
    if (!app) return
    root.slack = Model.toggleSlack(root.slack, app)
    historyAdapter.slack = root.slack
  }
  function fmt(ms) { return Model.fmt(ms) }
  function relativeDayLabel(key) { return Model.relativeDayLabel(key, root.todayKey) }

  // ---- State transition helpers ------------------------------------------
  // Apply a partial state patch from a State.js function to live QML
  // properties so bindings fire correctly.
  function applyState(patch) {
    if (!patch) return
    if (patch.today !== undefined) root.today = patch.today
    if (patch.days !== undefined) root.days = patch.days
    if (patch.todayKey !== undefined) root.todayKey = patch.todayKey
    if (patch.activeApp !== undefined) root.activeApp = patch.activeApp
    if (patch.activeStart !== undefined) root.activeStart = patch.activeStart
    if (patch.lastTick !== undefined) root.lastTick = patch.lastTick
    if (patch.resolveInFlight !== undefined) root.resolveInFlight = patch.resolveInFlight
  }

  // ---- Tracking ----------------------------------------------------------

  function isTerminal(appId) {
    return appId && root.terminalAppIds.indexOf(appId.toLowerCase()) !== -1
  }

  // Browsers resolve like terminals: the compositor only knows "firefox",
  // the resolver reads the focused tab's site from the browser's own
  // session store (see scripts/resolve_app.py).
  function isBrowser(appId) {
    return Model.isBrowserApp(appId)
  }

  // Steam games report their AppID as the window class; the resolver turns
  // that into the game title from local manifests before it is tracked.
  function isSteamApp(appId) {
    return appId && appId.toLowerCase().indexOf("steam_app_") === 0
  }

  // Windows that are never user-facing screen time — the idle screensaver,
  // xdg desktop portal windows that steal focus. These open no bucket, so
  // they count neither as an app nor into today's total.
  function shouldTrack(appId) {
    if (!appId) return false
    var id = String(appId).toLowerCase()
    if (id === "org.omarchy.screensaver") return false
    if (id.indexOf("xdg-desktop-portal") === 0) return false
    return true
  }

  function switchActive() {
    var now = Date.now()
    applyState(State.closeActiveBucket(
      root, root.activeApp, root.activeStart, now,
      root.todayKey, root.suspendGapMs, root.lastTick))
    root.persist()

    // Focus changes still arrive while the session is locked (the lock
    // surface taking and releasing keyboard focus, a suspend/resume behind
    // it). None of them open a bucket.
    if (root.sessionLocked) {
      root.activeApp = ""
      root.activeStart = 0
      root.rawApp = ""
      root.resolveInFlight = false
      return
    }

    var tl = ToplevelManager.activeToplevel
    var app = tl && tl.appId ? tl.appId : ""
    root.rawApp = app
    root.resolveInFlight = false
    if (app && !root.shouldTrack(app)) {
      root.activeApp = ""
      root.activeStart = 0
      return
    }
    if (app && (root.isTerminal(app) || root.isSteamApp(app) || root.isBrowser(app))) {
      root.activeApp = ""
      root.activeStart = 0
      root.beginResolve()
    } else {
      root.activeApp = Model.canonicalApp(app)
      root.activeStart = app ? now : 0
      // Chromium web-app windows (omarchy-launch-webapp, installed PWAs)
      // carry a site in their class; fetch that site's favicon so their
      // rows read like the site rows do.
      var webDomain = Model.webAppDomain(root.activeApp)
      if (webDomain) root.requestSiteIcon(webDomain)
    }
  }

  // Requests a fresh foreground resolution for the focused terminal. The
  // generation is bumped on every request but snapshotted only when a
  // process actually launches; a request made while one is in flight
  // invalidates the running process's result instead of queueing a second.
  function beginResolve() {
    root.resolveForApp = root.rawApp
    root.resolveInFlight = true
    root.resolveGeneration++
    if (!resolverProc.running) {
      root.resolveSpawnGen = root.resolveGeneration
      resolverProc.running = true
    }
  }

  // Applies a resolver result. Called both for the initial focus resolve and
  // for periodic refreshes while a terminal or browser stays focused (its
  // foreground process or focused tab can change: opencode -> bash,
  // github.com -> ycombinator.com).
  function applyResolvedApp(name) {
    var patch = State.applyResolvedApp(
      root, name, root.resolveForApp, root.todayKey,
      root.suspendGapMs, root.lastTick)
    // Clear resolveInFlight unconditionally: the resolver process has exited.
    // State.applyResolvedApp includes it in its patch when the result is
    // acted on; when the result is discarded (no-op) the flag must still be
    // cleared so the refresh timer can re-resolve after 5s instead of
    // waiting for the 10s watchdog.
    root.resolveInFlight = false
    applyState(patch)
    if (patch) root.persist()
    var domain = Model.siteDomain(root.activeApp)
    if (domain) root.requestSiteIcon(domain)
  }

  // Bounds crash loss: folds the in-flight bucket into today, then restarts
  // the timer so a crash loses at most the current interval.
  function commitElapsed(now) {
    if (!root.ready || !root.activeApp || !root.activeStart) return
    applyState(State.commitElapsed(
      root, root.activeApp, root.activeStart, now,
      root.todayKey, root.suspendGapMs, root.lastTick))
  }

  function rolloverIfNeeded() {
    var key = Model.dayKey(new Date())
    var patch = State.rolloverIfNeeded(root, key)
    if (!patch) return
    var now = Date.now()
    var app = root.activeApp

    // Close the open bucket first so its elapsed time lands on the day it
    // started (the bucket may still be on yesterday). rolloverIfNeeded's
    // patch then carries the live today into the new calendar day. We close
    // and reopen rather than leaving the bucket straddling midnight because
    // commitElapsed already handles mid-commit splits conservatively; this
    // path is the authoritative midnight transition where attribution must
    // be exact.
    applyState(State.closeActiveBucket(
      root, root.activeApp, root.activeStart, now,
      root.todayKey, root.suspendGapMs, root.lastTick))
    applyState(patch)

    // Reopen a fresh bucket for the still-focused app so tracking continues
    // past midnight without waiting for a focus change.
    root.activeApp = app
    root.activeStart = app ? Date.now() : 0
    root.persist()
  }

  // ---- Persistence -------------------------------------------------------

  // Reassigns a fresh top-level object so the JsonAdapter's notifier fires,
  // which schedules the debounced disk write. The live in-memory day is
  // folded into the mirror first — root.today is the source of truth while
  // root.days mirrors what is on disk.
  function persist() {
    if (root.startupPhase) return
    var merged = Object.assign({}, root.days)
    merged[root.todayKey] = root.today
    var kept = Model.pruneDays(merged, root.todayKey, root.keepDays)
    if (kept !== merged) {
      // Days dropped by retention roll up into monthly aggregates so the
      // calendar view keeps year-scale totals after raw days expire.
      var pruned = {}
      for (var k in merged) {
        if (Object.prototype.hasOwnProperty.call(merged, k) && !Object.prototype.hasOwnProperty.call(kept, k)) pruned[k] = merged[k]
      }
      root.months = Model.rollupPrunedDays(root.months, pruned, root.slack)
      historyAdapter.months = root.months
    }
    root.days = kept
    historyAdapter.days = kept
  }

  function scheduleSave() {
    if (root.startupPhase) return
    saveTimer.restart()
  }

  function onHistoryLoaded() {
    // sanitizeHistory rejects arrays and other non-objects that would slip
    // through a bare typeof check; identity comparison tells us whether
    // anything was discarded so the user gets one clear warning.
    var clean = Model.sanitizeHistory(historyAdapter.days, historyAdapter.months)
    if (clean.days !== historyAdapter.days || clean.months !== historyAdapter.months)
      console.warn("dutchster.omachron: history.json has malformed sections; ignoring them")
    var d = clean.days
    var m = clean.months
    root.slack = Model.sanitizeSlack(historyAdapter.slack)
    var kept = Model.pruneDays(d, Model.dayKey(new Date()), root.keepDays)
    if (kept !== d) {
      // Same rollup as persist(): load-time retention drops also feed the
      // monthly aggregates instead of being lost.
      var pruned = {}
      for (var k in d) {
        if (Object.prototype.hasOwnProperty.call(d, k) && !Object.prototype.hasOwnProperty.call(kept, k)) pruned[k] = d[k]
      }
      m = Model.rollupPrunedDays(m, pruned)
      historyAdapter.months = m
    }
    root.months = m
    root.days = kept
    if (!root.ready) {
      root.todayKey = Model.dayKey(new Date())
      var prev = d[root.todayKey]
      root.today = prev && typeof prev === "object"
        ? { total: prev.total || 0, apps: Object.assign({}, prev.apps || {}) }
        : Model.newDay()
      root.ready = true
      root.startupPhase = false
      root.lastTick = Date.now()
      root.switchActive()
      root.sweepTodayIcons()
    } else {
      // Retry after a seed: keep the live bucket, just refresh the mirror.
      var nd = Object.assign({}, root.days)
      nd[root.todayKey] = root.today
      root.days = nd
    }
  }

  function onHistoryLoadFailed() {
    // Expected on the very first run (file seeded by ensureDirProc) and on
    // a malformed file. Preserve a corrupt file before the next persist
    // overwrites it, then start empty rather than refusing to track.
    console.warn("dutchster.omachron: history load failed, starting empty")
    if (!root.backupAttempted) {
      root.backupAttempted = true
      backupProc.running = true
    }
    if (!root.ready) {
      root.days = {}
      root.ready = true
      root.startupPhase = false
      root.lastTick = Date.now()
      root.switchActive()
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    printErrors: true
    atomicWrites: true
    onAdapterUpdated: root.scheduleSave()
    onLoaded: root.onHistoryLoaded()
    onLoadFailed: root.onHistoryLoadFailed()

    JsonAdapter {
      id: historyAdapter
      property var days: ({})
      property var months: ({})
      property var slack: ({})
    }
  }

  // ---- Hyprland window border -------------------------------------------
  // The panel lines its corner up with a tiled window's, and Hyprland insets
  // a tiled window by gaps_out PLUS border_size. Style exposes gaps_out and
  // rounding but not border_size, so read it from the same source Style uses.
  // Defaults to Hyprland's own default, so the very first frame is already
  // right on an unconfigured system and a failed read never moves the panel.
  property int hyprBorderSize: 2

  function refreshBorderSize() {
    borderSizeProc.running = true
  }

  Process {
    id: borderSizeProc
    // head bounds the collector at the producer: hyprctl's reply is a few
    // dozen bytes, so anything past the cap is garbage by definition.
    command: ["sh", "-c",
      "hyprctl -j getoption general:border_size 2>/dev/null | head -c 4096; exit 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var n = Number(JSON.parse(String(text || "{}")).int)
          if (isFinite(n) && n >= 0) root.hyprBorderSize = Math.round(n)
        } catch (e) {
          console.warn("dutchster.omachron: could not read general:border_size")
        }
      }
    }
  }

  // Prepares the data directory and seeds an empty history — and, because
  // it runs before every FileView reload, it is also the boundary that
  // keeps a pre-positioned path out of the adapter: anything at
  // history.json that is not a regular file owned by us (a symlink, a
  // fifo, a foreign-uid file) is moved aside, a file past the byte
  // ceiling is evicted before FileView would buffer it, the seed is
  // written under noclobber (O_CREAT|O_EXCL, which refuses to follow even
  // a dangling symlink), and the mode is pinned to 0600.
  Process {
    id: ensureDirProc
    environment: ({ "HOME": root.home })
    command: ["bash", "-c", [
      'd="$HOME/.config/omarchy/omachron"',
      'mkdir -p "$d/icons"',
      'f="$d/history.json"',
      'now=$(date +%s)',
      'if [[ -L "$f" || ( -e "$f" && ! -f "$f" ) || ( -e "$f" && ! -O "$f" ) ]]; then mv -f -- "$f" "$f.invalid-$now" 2>/dev/null || rm -f -- "$f"; fi',
      'if [[ -f "$f" && $(stat -c%s -- "$f" 2>/dev/null || echo 0) -gt 10485760 ]]; then mv -f -- "$f" "$f.oversized-$now"; fi',
      '[[ -e "$f" ]] || (set -C; printf "{}\\n" > "$f") 2>/dev/null',
      '[[ -f "$f" && ! -L "$f" ]] && chmod 600 -- "$f"',
      'exit 0'
    ].join("; ")]
    onExited: {
      historyFile.reload()
      iconScanProc.running = true
    }
  }

  // ---- Site favicons -----------------------------------------------------

  function requestSiteIcon(domain) {
    if (!domain || root.siteIcons[domain] || root.iconAttempted[domain]) return
    var seen = Object.assign({}, root.iconAttempted)
    seen[domain] = true
    root.iconAttempted = seen
    root.iconQueue = root.iconQueue.concat([domain])
    root.pumpIconQueue()
  }

  function pumpIconQueue() {
    if (iconFetchProc.running || root.iconQueue.length === 0) return
    var queue = root.iconQueue.slice()
    root.iconFetching = queue.shift()
    root.iconQueue = queue
    iconFetchProc.running = true
  }

  // Icons already tracked today may predate this shell session; queue any
  // that are still missing once the on-disk scan has answered which exist.
  function sweepTodayIcons() {
    if (!root.iconScanDone || !root.today || !root.today.apps) return
    for (var app in root.today.apps) {
      if (!Object.prototype.hasOwnProperty.call(root.today.apps, app)) continue
      var domain = Model.siteDomain(app) || Model.webAppDomain(app)
      if (domain) root.requestSiteIcon(domain)
    }
  }

  // One-shot startup inventory of already-fetched icons, so restarts reuse
  // the cache instead of refetching every site. head bounds the collector
  // at the producer; a listing past the cap only means a few icons
  // re-fetch, which the per-domain queue absorbs.
  Process {
    id: iconScanProc
    environment: ({ "HOME": root.home })
    command: ["bash", "-c",
      "ls \"$HOME/.config/omarchy/omachron/icons\" 2>/dev/null | head -c 65536; exit 0"]
    stdout: StdioCollector {
      id: iconScanOut
      waitForEnd: true
    }
    onExited: {
      var icons = {}
      var lines = iconScanOut.text.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var f = lines[i].trim()
        if (f.slice(-4) === ".png") icons[f.slice(0, -4)] = true
      }
      root.siteIcons = icons
      root.iconVersion++
      root.iconScanDone = true
      root.sweepTodayIcons()
    }
  }

  // Fetches one site icon at a time; the queue survives failures because a
  // miss only marks iconAttempted (retry next shell session, not in a loop).
  //
  // Wrapped in GNU timeout, which runs the command in its own process
  // group and signals the GROUP — both when its own deadline expires and
  // when the watchdog below TERMs it — so bash's curl/getent descendants
  // are reaped with it instead of being orphaned mid-transfer.
  Process {
    id: iconFetchProc
    command: ["timeout", "--kill-after=5", "120",
      "bash", root.iconFetcherPath, root.iconFetching,
      root.iconsDir + "/" + root.iconFetching + ".png"]
    onExited: function(exitCode) {
      if (exitCode === 0 && root.iconFetching) {
        var icons = Object.assign({}, root.siteIcons)
        icons[root.iconFetching] = true
        root.siteIcons = icons
        root.iconVersion++
      }
      root.iconFetching = ""
      root.pumpIconQueue()
    }
  }

  // The fetcher bounds its own network calls (curl --max-time, timeout on
  // getent) and the timeout wrapper bounds the whole tree at 120s — but
  // the queue only advances onExited, so this backstop kills a run the
  // wrapper somehow failed to end. TERMing the wrapper forwards to its
  // process group, taking the descendants with it; the domain stays in
  // iconAttempted, so it retries next shell session rather than looping.
  Timer {
    id: iconFetchWatchdog
    interval: 130000
    repeat: false
    running: iconFetchProc.running
    onTriggered: {
      if (iconFetchProc.running) iconFetchProc.running = false
    }
  }

  // Safety net: catches appId-only changes and any missed activeToplevel
  // events. Cheap enough to run every 2s; real switches are event-driven.
  Timer {
    id: reconcileTimer
    interval: 2000
    repeat: true
    running: root.ready
    onTriggered: {
      var tl = ToplevelManager.activeToplevel
      var app = tl && tl.appId ? tl.appId : ""
      if (app !== root.rawApp) root.switchActive()
    }
  }

  // Preserve a corrupt history file before the next persist overwrites it.
  // Only a non-empty regular non-symlink file that fails to parse is moved
  // aside, so transient load errors never destroy a valid history — and
  // the parse itself is size-capped so this never buffers an oversized
  // file just to decide it is broken.
  property bool backupAttempted: false
  Process {
    id: backupProc
    environment: ({ "HOME": root.home })
    command: ["bash", "-c", [
      'f="$HOME/.config/omarchy/omachron/history.json"',
      '[[ -f "$f" && ! -L "$f" && -s "$f" ]] || exit 0',
      'size=$(stat -c%s -- "$f" 2>/dev/null || echo 0)',
      'if (( size > 10485760 )) || ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then mv -f -- "$f" "$f.corrupt-$(date +%s)"; fi'
    ].join("; ")]
  }

  // A terminal's foreground process changes without the compositor noticing
  // (opencode exits, leaving bash), and a browser can navigate without a
  // title change. Re-resolve while either stays focused.
  Timer {
    id: focusRefreshTimer
    interval: 5000
    repeat: true
    running: root.ready && (root.isTerminal(root.rawApp) || root.isBrowser(root.rawApp))
      && !root.resolveInFlight
    onTriggered: root.beginResolve()
  }

  // Tab switches change the window title, not the appId, so the reconcile
  // timer never sees them. A title change while a browser is focused
  // re-resolves immediately; rapid churn during page loads is coalesced by
  // the resolve generation tokens.
  readonly property string activeTitle: {
    var tl = ToplevelManager.activeToplevel
    return tl && tl.title ? tl.title : ""
  }
  onActiveTitleChanged: {
    if (root.ready && root.isBrowser(root.rawApp)) root.beginResolve()
  }

  // If a resolver run never exits (hung hyprctl, wedged /proc read), kill it
  // and clear the in-flight flag so the refresh timer can start a fresh
  // process instead of stalling terminal tracking forever. The killed
  // process's onExited is ignored: applyResolvedApp returns early once
  // resolveInFlight is false.
  Timer {
    id: resolveWatchdog
    interval: 10000
    repeat: false
    running: root.resolveInFlight
    onTriggered: {
      root.resolveInFlight = false
      if (resolverProc.running) resolverProc.running = false
    }
  }

  // Resolves the app running in the focused terminal (see resolve_app.py).
  // An empty stdout falls back to rawApp silently by design, so stderr is
  // logged: without it a broken resolver degrades tracking invisibly.
  //
  // The sh -c wrapper guards against a missing python3: Quickshell's
  // Process exposes no spawn-failure signal, so a bare python3 command
  // that cannot start would leave resolves stalling until the watchdog.
  // sh always exists, exits 0 without output instead, and the empty
  // result falls back to tracking the raw terminal class.
  //
  // The timeout wrapper gives the whole resolver tree (sh execs into
  // python3, which spawns hyprctl) a hard in-tree deadline just past the
  // 10s watchdog, and — because GNU timeout signals its child's process
  // group — makes both that deadline and the watchdog's TERM reap the
  // descendants, not just the direct child.
  Process {
    id: resolverProc
    command: ["timeout", "--kill-after=2", "12", "sh", "-c",
      "command -v python3 >/dev/null 2>&1 && exec python3 \"$1\" || exit 0",
      "sh", root.resolverPath]
    stdout: StdioCollector {
      id: resolverOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: resolverErr
      waitForEnd: true
    }
    onExited: {
      var err = resolverErr.text.trim()
      if (err) console.warn("dutchster.omachron: resolver stderr:", err)
      root.applyResolvedApp(resolverOut.text.trim())
      // A request that arrived while this run was in flight superseded its
      // result (generation mismatch); resolve again now instead of leaving
      // the switch to the 5s refresh timer.
      if (root.resolveGeneration !== root.resolveSpawnGen
          && (root.isTerminal(root.rawApp) || root.isBrowser(root.rawApp))
          && !resolverProc.running)
        root.beginResolve()
    }
  }

  // Keeps the suspend-gap baseline fresh every few seconds so the gap check
  // resolves suspends down to ~30s instead of being locked to the 60s commit
  // cadence. On a detected gap the open bucket is dropped without accrual
  // (closeActiveBucket's gap branch) and tracking restarts from wake time.
  Timer {
    id: heartbeatTimer
    interval: 5000
    repeat: true
    running: root.ready
    onTriggered: {
      var now = Date.now()
      if (State.isSuspendGap(now, root.lastTick, root.suspendGapMs)) {
        applyState(State.closeActiveBucket(
          root, root.activeApp, root.activeStart, now,
          root.todayKey, root.suspendGapMs, root.lastTick))
        root.persist()
        root.switchActive()
      } else {
        root.rolloverIfNeeded()
        root.commitElapsed(now)
        root.persist()
      }
      root.lastTick = now
    }
  }

  Timer {
    id: commitTimer
    interval: 60000
    repeat: true
    running: root.ready
    onTriggered: {
      var now = Date.now()
      root.rolloverIfNeeded()
      root.commitElapsed(now)
      root.persist()
      root.lastTick = now
    }
  }

  Timer {
    id: saveTimer
    interval: 1500
    repeat: false
    onTriggered: historyFile.writeAdapter()
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      root.switchActive()
    }
  }

  Component.onCompleted: {
    ensureDirProc.running = true
    borderSizeProc.running = true
  }
}

