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
// Persistence is a single JSON file
//   ~/.config/omarchy/omachron/history.json
// shaped as
//   { "days":   { "<YYYY-MM-DD>": { "total": <ms>, "apps": { "<key>": <ms> } } },
//     "months": { "<YYYY-MM>": <ms> | { "total": <ms>, "slack": <ms> } },
//     "slack":  { "<key>": <bool> } }
//
// All disk access goes through scripts/fs_guard.py, which performs the
// whole transaction — trusted-chain traversal, O_NOFOLLOW leaf open, size
// and type checks on the held descriptor, quarantine/seed recovery, and
// atomic descriptor-relative publication — before this file ever parses a
// byte, and whose exit code gates whether the result is trusted at all.
// Loaded JSON is then schema-checked by Model.sanitizeHistory before any
// value reaches a long-lived model. Writes are event-driven (on focus
// change), debounced, and serialized through the same helper; a 60s
// commit bounds how much of an in-flight bucket can be lost to a crash.
// Data survives plugin hot-reloads because it lives on disk.
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
  readonly property string resolverPath: {
    var u = Qt.resolvedUrl("scripts/resolve_app.py").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }
  // Descriptor-based filesystem helper; every history/icon disk
  // transaction runs through it (see the header comment).
  readonly property string guardPath: {
    var u = Qt.resolvedUrl("scripts/fs_guard.py").toString()
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
    root.scheduleSave()
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

  // Folds the live in-memory day into the mirror and schedules the
  // debounced disk write — root.today is the source of truth while
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
    }
    root.days = kept
    root.scheduleSave()
  }

  function scheduleSave() {
    if (root.startupPhase) return
    saveTimer.restart()
  }

  // One invocation shape for every fs_guard call, so the deadline, the
  // kill-after grace, the python3 probe (Quickshell's Process exposes no
  // spawn-failure signal; the distinct 127 fails closed rather than
  // open), and the process-group semantics cannot drift apart between
  // load, save and listing.
  function guardCommand(sub) {
    return ["timeout", "--kill-after=2", "10", "sh", "-c",
      "command -v python3 >/dev/null 2>&1 && exec python3 \"$1\" " + sub + " || exit 127",
      "sh", root.guardPath]
  }

  // Serializes the full current state through fs_guard save-history. One
  // save runs at a time; a request arriving mid-save queues exactly one
  // follow-up, which snapshots the state current at launch, so the last
  // writer always carries everything. A payload identical to the last
  // successful save is skipped outright — the heartbeat persists on a
  // fixed cadence whether or not anything changed, and an idle session
  // should not rewrite the same bytes every few seconds.
  function startSave() {
    if (root.persistBlocked) return
    if (saveProc.running) {
      root.saveQueued = true
      return
    }
    var payload = JSON.stringify({
      days: root.days,
      months: root.months,
      slack: root.slack
    })
    if (payload === root.lastSavedPayload) return
    root.pendingPayload = payload
    saveProc.running = true
  }

  // fs_guard load-history exit codes 0 (existing history served), 4 (fresh
  // seed) and 5 (bad file quarantined, fresh seed served) all mean stdout
  // carries JSON the helper read off a verified descriptor. Anything else
  // — trust failure, IO failure, missing python3, the timeout wrapper —
  // means the trusted chain could not be established, and the session
  // fails closed: tracking runs in memory only and never writes through a
  // chain that failed verification (persistBlocked). Losing one session
  // of persistence to a transient error is the accepted cost.
  function onHistoryLoaded(code, text, errText) {
    if (errText.trim())
      console.warn("dutchster.omachron: fs_guard load-history:", errText.trim())
    var parsed = null
    if (code === 0 || code === 4 || code === 5) {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        // Contract violation: the helper only prints validated JSON.
        console.warn("dutchster.omachron: helper returned unparseable history")
      }
    }
    if (parsed === null || typeof parsed !== "object") {
      console.warn("dutchster.omachron: history unavailable (fs_guard exit "
        + code + "); tracking in memory only for this session")
      root.persistBlocked = true
      root.days = {}
      root.ready = true
      root.startupPhase = false
      root.lastTick = Date.now()
      root.switchActive()
      root.iconScanDone = true // icon cache sits behind the same failed chain
      return
    }
    // The helper guarantees well-formed JSON of bounded size; the schema —
    // date-shaped keys, exact record shapes, key-length/cardinality caps,
    // finite numeric ranges — is enforced here, before anything reaches a
    // long-lived model. Identity comparison tells us whether anything was
    // discarded so the user gets one clear warning — but only for
    // sections the file actually carried: a fresh seed is just "{}" and
    // its absent sections are not malformed.
    var clean = Model.sanitizeHistory(parsed.days, parsed.months)
    if ((parsed.days !== undefined && clean.days !== parsed.days)
        || (parsed.months !== undefined && clean.months !== parsed.months))
      console.warn("dutchster.omachron: history.json has malformed sections; ignoring them")
    var d = clean.days
    var m = clean.months
    root.slack = Model.sanitizeSlack(parsed.slack)
    var kept = Model.pruneDays(d, Model.dayKey(new Date()), root.keepDays)
    if (kept !== d) {
      // Same rollup as persist(): load-time retention drops also feed the
      // monthly aggregates instead of being lost.
      var pruned = {}
      for (var k in d) {
        if (Object.prototype.hasOwnProperty.call(d, k) && !Object.prototype.hasOwnProperty.call(kept, k)) pruned[k] = d[k]
      }
      m = Model.rollupPrunedDays(m, pruned, root.slack)
    }
    root.months = m
    root.days = kept
    root.todayKey = Model.dayKey(new Date())
    var prev = d[root.todayKey]
    root.today = prev && typeof prev === "object"
      ? { total: prev.total || 0, apps: Object.assign({}, prev.apps || {}) }
      : Model.newDay()
    root.ready = true
    root.startupPhase = false
    root.lastTick = Date.now()
    root.switchActive()
    iconListProc.running = true
  }

  // Set when the load transaction failed: the session tracks in memory
  // only and never writes to disk (fail closed, see onHistoryLoaded).
  property bool persistBlocked: false
  property bool saveQueued: false
  property bool saveFailedWarned: false
  // Snapshot handed to the running saveProc, and the payload of the last
  // save that succeeded (used to skip byte-identical rewrites).
  property string pendingPayload: ""
  property string lastSavedPayload: ""

  // Loads history through the fs_guard transaction (see guardCommand for
  // the wrapper semantics).
  Process {
    id: loadProc
    environment: ({ "HOME": root.home })
    command: root.guardCommand("load-history")
    stdout: StdioCollector {
      id: loadOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: loadErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onHistoryLoaded(exitCode, loadOut.text, loadErr.text)
    }
  }

  // Writes history through fs_guard save-history: the full state is
  // streamed over stdin and published by the helper as an atomic
  // descriptor-relative rename, so no pathname is composed on this side.
  // Closing stdinEnabled after the write flushes and signals EOF.
  Process {
    id: saveProc
    environment: ({ "HOME": root.home })
    stdinEnabled: true
    command: root.guardCommand("save-history")
    onStarted: {
      saveProc.write(root.pendingPayload)
      saveProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      saveProc.stdinEnabled = true // re-arm for the next run
      if (exitCode === 0) {
        root.lastSavedPayload = root.pendingPayload
        root.saveFailedWarned = false
      } else if (!root.saveFailedWarned) {
        root.saveFailedWarned = true
        console.warn("dutchster.omachron: history save failed (fs_guard exit "
          + exitCode + "); will keep retrying on future saves")
      }
      if (root.saveQueued) {
        root.saveQueued = false
        root.startSave() // re-snapshots, and skips if nothing changed
      }
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
  // the cache instead of refetching every site. fs_guard list-icons
  // enforces the boundary at the producer — descriptor-relative listing,
  // regular files only, hostname-shaped names, per-name length limit and
  // a hard item cap — so no overflow or partial record can exist in its
  // output; the loop below re-validates every line anyway (defense in
  // depth) with the same schema and an independent iteration cap, since
  // these keys later select fetch targets.
  Process {
    id: iconListProc
    environment: ({ "HOME": root.home })
    command: root.guardCommand("list-icons")
    stdout: StdioCollector {
      id: iconListOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var icons = {}
      if (exitCode === 0) {
        // The regex, caps and has-a-letter rule mirror fs_guard's
        // (DOMAIN_RE / MAX_ICONS / MAX_NAME); a drift test in
        // tests/test_fs_guard.py pins this copy to the helper's.
        var lines = iconListOut.text.split("\n")
        var max = Math.min(lines.length, 512)
        var re = /^[A-Za-z0-9]([A-Za-z0-9-]{0,62})?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62})?)+\.png$/
        for (var i = 0; i < max; i++) {
          var f = lines[i].trim()
          if (f.length <= 258 && re.test(f) && /[A-Za-z]/.test(f.slice(0, -4)))
            icons[f.slice(0, -4)] = true
        }
      } else {
        console.warn("dutchster.omachron: icon listing failed (fs_guard exit "
          + exitCode + "); starting with an empty icon cache")
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
    // Only the domain crosses the argv boundary; the destination path is
    // wholly owned by fs_guard icon-publish inside the fetcher, so this
    // side never composes a pathname for the script to honor.
    command: ["timeout", "--kill-after=5", "120",
      "bash", root.iconFetcherPath, root.iconFetching]
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
    onTriggered: root.startSave()
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      root.switchActive()
    }
  }

  Component.onCompleted: {
    loadProc.running = true
    borderSizeProc.running = true
  }
}

