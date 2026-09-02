// Pure JS helpers for Omachron: day keys, time formatting,
// per-app aggregation, and the small set of usage heuristics shown as
// insights. No Qt imports here so the functions stay testable in isolation.

function pad2(n) {
  n = Math.floor(n)
  return n < 10 ? "0" + n : String(n)
}

// Canonical tracking keys for multi-process browsers. A browser launched
// from a terminal resolves to its binary name (e.g. "zen-bin"), and its
// subprocesses can leak process names (Web Content, forkserver, …). Screen
// time must fold all of those into the single per-app key, otherwise a
// browser shows up as several individual rows.
//
// Single source of truth: lib/browser_aliases.json.  Both this module and
// scripts/resolve_app.py load from that file at runtime.
var BROWSER_ALIASES = (function () {
  if (typeof module !== "undefined" && module && module.exports)
    return require("./browser_aliases.json")
  // Qt.include() is deprecated in Qt 5.15+. Inline the JSON so the file
  // works with both QML's JS engine and Node.js without any deprecated APIs.
  return {"zen-bin":"zen","zen_browser":"zen","zen":"zen","firefox":"firefox",
    "librewolf":"librewolf","waterfox":"waterfox","tor-browser":"tor-browser",
    "mullvad-browser":"mullvad-browser","google-chrome":"google-chrome",
    "chrome":"google-chrome","chromium":"chromium","brave":"brave",
    "brave-browser":"brave","vivaldi":"vivaldi","vivaldi-stable":"vivaldi",
    "microsoft-edge":"microsoft-edge","edge":"microsoft-edge"}
})()

var CHROMIUM_WEB_APP_RE = /^((?:chrome|chromium|brave|msedge|vivaldi)-([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?))(__.*-(?:Default|Profile_[0-9]+))?$/i

// Per-site tracking keys emitted by scripts/resolve_app.py for the focused
// browser tab: "site:" + the registrable domain (already reduced from the
// full hostname there). Kept distinct from Chromium web-app classes so a
// PWA and in-browser use of the same site stay separate rows.
var SITE_KEY_RE = /^site:([a-z0-9.:_-]+)$/i

// Browsers whose focused tab the resolver can read from the session store.
// tor-browser and mullvad-browser are deliberately not here.
var SITE_CAPABLE_BROWSERS = {
  "firefox": true, "zen": true, "librewolf": true, "waterfox": true,
  "chromium": true, "brave": true, "google-chrome": true,
  "vivaldi": true, "microsoft-edge": true
}

// Web apps that deserve their own identity: scripts/resolve_app.py keeps
// these hosts as their own tracking bucket, and this map names them the
// way people know them ("gmail", not "google"). Single source of truth:
// lib/site_apps.json — inlined here for QML's JS engine, required for
// Node, the same dual-load pattern as BROWSER_ALIASES.
//
// The " web" suffixes disambiguate a site from a native desktop app of the
// same name. Claude, Discord, Slack, Spotify and Telegram all ship Linux
// apps whose window class reduces to the same word as their domain's brand
// label, so the panel printed two rows reading "claude" -- different icons
// and different times, but identical text, which reads as a rendering bug.
// Only the label changes: every key here is already the registrable domain
// (or was mapped before), so no tracking bucket moves and no history splits.
var SITE_APPS = (function () {
  if (typeof module !== "undefined" && module && module.exports)
    return require("./site_apps.json")
  return {"mail.google.com":"gmail","docs.google.com":"google docs",
    "drive.google.com":"google drive",
    "calendar.google.com":"google calendar","meet.google.com":"google meet",
    "maps.google.com":"google maps","photos.google.com":"google photos",
    "translate.google.com":"google translate",
    "keep.google.com":"google keep","messages.google.com":"google messages",
    "contacts.google.com":"google contacts","news.google.com":"google news",
    "cloud.google.com":"google cloud","gemini.google.com":"gemini",
    "music.youtube.com":"youtube music",
    "studio.youtube.com":"youtube studio","tv.youtube.com":"youtube tv",
    "aws.amazon.com":"aws","music.amazon.com":"amazon music",
    "outlook.live.com":"outlook","outlook.office.com":"outlook",
    "teams.microsoft.com":"teams","copilot.microsoft.com":"copilot",
    "onedrive.live.com":"onedrive","web.whatsapp.com":"whatsapp",
    "web.telegram.org":"telegram web","web.snapchat.com":"snapchat",
    "app.slack.com":"slack web","app.element.io":"element",
    "chat.openai.com":"chatgpt","news.ycombinator.com":"hacker news",
    "stackoverflow.com":"stack overflow","developer.mozilla.org":"mdn",
    "npmjs.com":"npm","huggingface.co":"hugging face","bsky.app":"bluesky",
    "disneyplus.com":"disney+","music.apple.com":"apple music",
    "tv.apple.com":"apple tv","mail.proton.me":"proton mail",
    "calendar.proton.me":"proton calendar","mail.yahoo.com":"yahoo mail",
    "app.hey.com":"hey","3.basecamp.com":"basecamp",
    "claude.ai":"claude web","discord.com":"discord web",
    "spotify.com":"spotify web"}
})()

// Sites and programs that count as slacking off out of the box. Single
// source of truth: lib/slack_apps.json — inlined here for QML's JS engine,
// required under Node, the same dual-load pattern as BROWSER_ALIASES.
// Users override any entry from the panel; the overrides live in
// history.json and only ever store deviations from this list, so the
// defaults stay live as this file grows.
var SLACK_DEFAULTS = (function () {
  var raw = (typeof module !== "undefined" && module && module.exports)
    ? require("./slack_apps.json")
    : {"sites":["youtube.com","reddit.com","x.com","twitter.com",
        "instagram.com","facebook.com","tiktok.com","twitch.tv","kick.com",
        "netflix.com","hulu.com","disneyplus.com","primevideo.com",
        "hbomax.com","max.com","crunchyroll.com","dailymotion.com",
        "nebula.tv","9gag.com","imgur.com","pinterest.com","tumblr.com",
        "snapchat.com","threads.net","threads.com","bsky.app",
        "mastodon.social","quora.com","buzzfeed.com","4chan.org","vk.com",
        "weibo.com","steampowered.com","steamcommunity.com"],
       "apps":["steam","lutris","heroic","retroarch","gamescope"]}
  var sites = {}
  var apps = {}
  var i
  for (i = 0; i < (raw.sites || []).length; i++) sites[raw.sites[i]] = true
  for (i = 0; i < (raw.apps || []).length; i++) apps[raw.apps[i]] = true
  return { sites: sites, apps: apps }
})()

// Host of a Chromium web-app window class ("brave-chatgpt.com__-Default"
// -> "chatgpt.com"), or "" for any other key. Omarchy's default webapps
// (omarchy-launch-webapp) all produce this class shape.
function webAppDomain(app) {
  var m = String(app || "").match(CHROMIUM_WEB_APP_RE)
  return m ? m[2].toLowerCase() : ""
}

// Second-level labels that are themselves generic (bbc.co.uk's "co"), so
// the brand label sits one step further left.
var GENERIC_SECOND_LEVEL = {
  "co": true, "com": true, "org": true, "net": true, "ac": true,
  "gov": true, "edu": true, "or": true, "ne": true, "go": true
}

// Human name for a host: the site_apps map first (walking parent suffixes
// so u.mail.google.com still reads gmail), else the registrable brand
// label without its public suffix. localhost and IP literals stay whole.
function siteLabel(domain) {
  var labels = String(domain).split(".")
  for (var i = 0; i < labels.length; i++) {
    var candidate = labels.slice(i).join(".")
    if (Object.prototype.hasOwnProperty.call(SITE_APPS, candidate))
      return SITE_APPS[candidate]
  }
  if (labels.length < 2 || domain.indexOf(":") !== -1) return domain
  var allNumeric = true
  for (var li = 0; li < labels.length; li++) {
    if (!/^[0-9]+$/.test(labels[li])) { allNumeric = false; break }
  }
  if (allNumeric) return domain
  var idx = labels.length - 2
  if (labels.length >= 3
      && Object.prototype.hasOwnProperty.call(GENERIC_SECOND_LEVEL, labels[idx]))
    idx--
  return labels[idx]
}

// Registrable domain of a site tracking key ("site:github.com" ->
// "github.com"), or "" for any other app key.
function siteDomain(app) {
  var m = String(app || "").match(SITE_KEY_RE)
  return m ? m[1].toLowerCase() : ""
}

// Whether the compositor appId is a browser whose focused tab should be
// resolved to a site key (drives the service's resolver triggers).
function isBrowserApp(appId) {
  if (!appId) return false
  var key = String(appId).toLowerCase()
  if (!Object.prototype.hasOwnProperty.call(BROWSER_ALIASES, key)) return false
  var canon = BROWSER_ALIASES[key]
  return Object.prototype.hasOwnProperty.call(SITE_CAPABLE_BROWSERS, canon)
}

// Tracking keys are canonicalized (brave-browser -> brave), so the desktop
// entry they were installed under may need a different id. Extra lookup
// candidates per canonical key; everything else just tries itself.
var APP_ICON_HINTS = {
  "brave": ["brave-browser"],
  "vivaldi": ["vivaldi-stable"],
  "zen": ["zen-browser", "zen_browser"],
  "edge": ["microsoft-edge"],
  "org.localsend.localsend_app": ["localsend"],
  "pinta": ["com.github.PintaProject.Pinta"],
  "evince": ["org.gnome.Evince"],
  "darktable": ["org.darktable.darktable"],
  "shotcut": ["org.shotcut.Shotcut"],
  "openrgb": ["org.openrgb.OpenRGB"],
  "xournalpp": ["com.github.xournalpp.xournalpp"],
  "easyeffects": ["com.github.wwmm.easyeffects"],
  "obs": ["com.obsproject.Studio"],
  "moonlight": ["com.moonlight_stream.Moonlight"],
  "code": ["code-oss", "visual-studio-code"],
  "codium": ["vscodium", "codium"],
  "signal": ["signal-desktop"],
  "kdenlive": ["org.kde.kdenlive"],
  "disk utility": ["org.gnome.DiskUtility"],
  "qalculate": ["qalculate-gtk"]
}

// Desktop-entry lookup candidates for a program row's icon, most specific
// first. Site keys resolve to fetched favicons instead, and the grouped
// list's synthetic "Other" row never names a real program, so both return
// no candidates. The panel feeds these to DesktopEntries/iconPath; a row
// with no hit keeps the plain swatch look.
function appIconQueries(app) {
  var s = String(app || "")
  if (!s || s === "Other" || siteDomain(s)) return []
  var out = [s]
  var lower = s.toLowerCase()
  if (lower !== s) out.push(lower)
  var hints = Object.prototype.hasOwnProperty.call(APP_ICON_HINTS, lower)
    ? APP_ICON_HINTS[lower] : []
  for (var i = 0; i < hints.length; i++) {
    if (out.indexOf(hints[i]) === -1) out.push(hints[i])
  }
  return out
}

// Map any app name to its canonical tracking key. Unknown names pass
// through unchanged so non-browser apps keep their own identity.
function canonicalApp(name) {
  if (!name) return ""
  var key = String(name)
  if (BROWSER_ALIASES && Object.prototype.hasOwnProperty.call(BROWSER_ALIASES, key))
    return BROWSER_ALIASES[key]
  var webApp = key.match(CHROMIUM_WEB_APP_RE)
  if (webApp && webApp[3]) return webApp[1]
  return key
}

// Human-readable label for the panel. Chromium site windows are reduced
// to their hostname, reverse-DNS app IDs from the compositor (e.g.
// "com.github.user.Codium") are shortened to the last segment and
// lowercased, and plain binary names pass through unchanged.
// Steam window classes (e.g. "steam_app_730") arrive already resolved to
// game titles by scripts/resolve_app.py; unresolved ones fall through to
// the plain-name path. This layer never touches the filesystem: QML's JS
// engine has no require(), so fs-based lookups would throw at runtime.
function displayName(app) {
  if (!app) return ""
  var s = String(app)

  // Sites and Chromium web-app windows read like app names: known web
  // apps get the name people use ("site:mail.google.com" and a WhatsApp
  // webapp window both -> "whatsapp"-style names), everything else the
  // registrable brand label without its public suffix.
  var site = siteDomain(s)
  if (site) return siteLabel(site)

  var webApp = s.match(CHROMIUM_WEB_APP_RE)
  if (webApp) return siteLabel(webApp[2].toLowerCase())

  if (!/^(?:[a-z][a-z0-9-]*\.){2,}[a-z0-9_-]+$/i.test(s))
    return s.toLowerCase()
  var last = s.split(".").pop()
  if (!last) return s.toLowerCase()
  return last.charAt(0).toLowerCase() + last.slice(1).toLowerCase()
}

// Guards against a hand-edited or corrupted history file. The shell's
// load helper only guarantees "well-formed JSON of bounded byte size";
// everything object-shaped is enforced here, before any value reaches a
// long-lived QML model: date-shaped keys, exact per-entry structure with
// unknown keys stripped, bounded key lengths and entry counts, and finite
// numeric ranges. Violations fail closed — a bad entry is dropped, an
// over-cap or non-object section falls back to empty — so tracking starts
// clean instead of enumerating attacker-chosen keys later. The caps are
// far above anything this plugin writes (95 retained days, one entry per
// tracked app) while keeping a hostile file from smuggling unbounded
// structure past the byte ceiling.
var HISTORY_LIMITS = {
  maxDays: 400,
  maxMonths: 240,
  maxAppsPerDay: 512,
  maxKeyLen: 256,
  maxMs: 1e13, // ~317 years; every duration this plugin records is far below
  maxSlackKeys: 1024
}

var DAY_KEY_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/
var MONTH_KEY_RE = /^\d{4}-(0[1-9]|1[0-2])$/

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v)
}

function validMs(v) {
  return typeof v === "number" && isFinite(v) && v >= 0 && v <= HISTORY_LIMITS.maxMs
}

function validAppKey(k) {
  return k.length > 0 && k.length <= HISTORY_LIMITS.maxKeyLen
}

// One day record: exactly { total, apps }. Returns the original value when
// it is already exactly that shape (so unchanged input keeps identity), a
// rebuilt copy when app entries or unknown keys needed stripping, or null
// when the record itself is malformed (drops the whole day). An app map
// past the cardinality cap is truncated to its largest entries rather
// than dropped: a genuine heavy-browsing day mints one key per visited
// site and can legitimately exceed the cap, and the day total plus the
// dominant entries are the data worth keeping.
function sanitizeDayRecord(v) {
  if (!isPlainObject(v) || !validMs(v.total) || !isPlainObject(v.apps)) return null
  var appKeys = Object.keys(v.apps)
  var clean = appKeys.length <= HISTORY_LIMITS.maxAppsPerDay && Object.keys(v).length === 2
  for (var i = 0; clean && i < appKeys.length; i++) {
    if (!validAppKey(appKeys[i]) || !validMs(v.apps[appKeys[i]])) clean = false
  }
  if (clean) return v
  var valid = []
  for (var j = 0; j < appKeys.length; j++) {
    var a = appKeys[j]
    if (validAppKey(a) && validMs(v.apps[a])) valid.push(a)
  }
  if (valid.length > HISTORY_LIMITS.maxAppsPerDay) {
    valid.sort(function (x, y) { return v.apps[y] - v.apps[x] || (x < y ? -1 : 1) })
    valid = valid.slice(0, HISTORY_LIMITS.maxAppsPerDay)
  }
  var apps = {}
  for (var n = 0; n < valid.length; n++) apps[valid[n]] = v.apps[valid[n]]
  return { total: v.total, apps: apps }
}

// One month record: a bare number (legacy) or exactly { total, slack }.
function sanitizeMonthRecord(v) {
  if (validMs(v)) return v
  if (!isPlainObject(v) || !validMs(v.total)) return null
  if (v.slack === undefined) return { total: v.total, slack: 0 }
  if (!validMs(v.slack)) return null
  return Object.keys(v).length === 2 ? v : { total: v.total, slack: v.slack }
}

function sanitizeSection(section, keyRe, maxKeys, sanitizeRecord) {
  if (!isPlainObject(section)) return {}
  var keys = Object.keys(section)
  if (keys.length > maxKeys) return {}
  var out = {}
  var changed = false
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i]
    if (!keyRe.test(k)) { changed = true; continue }
    var v = sanitizeRecord(section[k])
    if (v === null) { changed = true; continue }
    if (v !== section[k]) changed = true
    out[k] = v
  }
  // Return the original object when nothing was dropped or rebuilt, so the
  // caller's identity comparison can tell whether to warn.
  return changed ? out : section
}

function sanitizeHistory(days, months) {
  return {
    days: sanitizeSection(days, DAY_KEY_RE, HISTORY_LIMITS.maxDays, sanitizeDayRecord),
    months: sanitizeSection(months, MONTH_KEY_RE, HISTORY_LIMITS.maxMonths, sanitizeMonthRecord)
  }
}

// The day object to render: live today when nothing is selected (or the
// selected key is today), otherwise the stored history day.
function dayFor(days, today, key, todayKey) {
  if (!key || key === todayKey) return today
  return days && days[key] ? days[key] : null
}

// Local-time calendar key, e.g. "2026-08-13".
function dayKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function newDay() {
  return { total: 0, apps: {} }
}

// Compact human duration: "0m", "45s", "23m", "3h", "2h 14m".
function fmt(ms) {
  ms = Math.max(0, Math.round(Number(ms) || 0))
  if (ms <= 0) return "0m"
  if (ms < 60000) return Math.max(1, Math.round(ms / 1000)) + "s"
  var mins = Math.round(ms / 60000)
  if (mins < 60) return mins + "m"
  var h = Math.floor(mins / 60)
  var m = mins % 60
  return m === 0 ? h + "h" : h + "h " + m + "m"
}

// Signed comparison, worded rather than symboled: "1h 16m more" reads as a
// sentence where "+ 1h 16m" makes you decode a sign first.
function fmtDelta(ms) {
  var v = Math.round(Number(ms) || 0)
  if (v === 0) return "no change"
  return fmt(Math.abs(v)) + (v < 0 ? " less" : " more")
}

// Worded duration for the panel: "0 MINUTES", "12 MINUTES",
// "2 HOURS 14 MINUTES", "45 SECONDS".
function fmtWords(ms) {
  ms = Math.max(0, Math.round(Number(ms) || 0))
  if (ms <= 0) return "0 minutes"
  if (ms < 60000) {
    var s = Math.max(1, Math.round(ms / 1000))
    return s + (s === 1 ? " second" : " seconds")
  }
  var mins = Math.round(ms / 60000)
  if (mins < 60) return mins + (mins === 1 ? " minute" : " minutes")
  var h = Math.floor(mins / 60)
  var m = mins % 60
  var part = h + (h === 1 ? " hour" : " hours")
  if (m > 0) part += " " + m + (m === 1 ? " minute" : " minutes")
  return part
}

// Sorted per-app list for today: [{ app, ms, pct }], most-used first.
// Entries under minMs are dropped (default: one minute) so the panel only
// lists meaningful entries; the "hide < N minutes" filter passes its own
// threshold, and 0 shows everything. Explicit typeof guard: QML's JS
// engine has no default parameters.
function appList(today, minMs) {
  var floor = typeof minMs === "number" ? minMs : 60000
  var apps = today && today.apps ? today.apps : {}
  var total = today && today.total ? today.total : 0
  var out = []
  for (var app in apps) {
    if (!Object.prototype.hasOwnProperty.call(apps, app)) continue
    var ms = Number(apps[app]) || 0
    if (ms < floor) continue
    out.push({ app: app, ms: ms, pct: total > 0 ? Math.round(100 * ms / total) : 0 })
  }
  out.sort(function(a, b) { return b.ms - a.ms })
  return out
}

// ---- Slacking off --------------------------------------------------------

// Whether the shipped list calls this tracking key slacking off. Sites
// match on any parent suffix, so music.youtube.com counts through
// youtube.com and a Chromium web-app window counts through its host.
function isDefaultSlack(app) {
  var s = String(app || "")
  if (!s) return false
  var domain = siteDomain(s) || webAppDomain(s)
  if (domain) {
    var labels = domain.split(".")
    for (var i = 0; i + 1 < labels.length; i++) {
      var candidate = labels.slice(i).join(".")
      if (Object.prototype.hasOwnProperty.call(SLACK_DEFAULTS.sites, candidate))
        return true
    }
    return false
  }
  return Object.prototype.hasOwnProperty.call(SLACK_DEFAULTS.apps, s.toLowerCase())
}

// Effective membership: a user override wins, otherwise the default list
// decides.
function isSlackApp(app, overrides) {
  var key = String(app || "").toLowerCase()
  if (!key) return false
  if (overrides && Object.prototype.hasOwnProperty.call(overrides, key))
    return overrides[key] === true
  return isDefaultSlack(app)
}

// Flips one key's membership, returning a NEW overrides object. A flip
// back to the shipped answer deletes the entry instead of pinning it, so
// later additions to lib/slack_apps.json still reach users who never
// disagreed about that key.
function toggleSlack(overrides, app) {
  var out = {}
  for (var k in overrides) {
    if (Object.prototype.hasOwnProperty.call(overrides, k)) out[k] = overrides[k] === true
  }
  var key = String(app || "").toLowerCase()
  if (!key) return out
  var next = !isSlackApp(app, overrides)
  if (next === isDefaultSlack(app)) delete out[key]
  else out[key] = next
  return out
}

// Same guard as sanitizeHistory, for the overrides section: anything that
// is not a plain object of booleans under the same key-length ceiling
// falls back to the shipped defaults rather than mislabelling every row,
// and an over-cap map is dropped outright (fail closed) — the plugin only
// ever stores disagreements with the shipped defaults, so a huge map
// cannot be ours.
function sanitizeSlack(v) {
  if (!isPlainObject(v)) return {}
  var keys = Object.keys(v)
  if (keys.length > HISTORY_LIMITS.maxSlackKeys) return {}
  var out = {}
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i]
    if (validAppKey(k) && typeof v[k] === "boolean") out[k.toLowerCase()] = v[k]
  }
  return out
}

// Slacked-off milliseconds inside one day record.
function slackTotal(day, overrides) {
  var apps = day && day.apps ? day.apps : {}
  var sum = 0
  for (var app in apps) {
    if (!Object.prototype.hasOwnProperty.call(apps, app)) continue
    if (isSlackApp(app, overrides)) sum += Number(apps[app]) || 0
  }
  return sum
}

// Slack share of a day's total, 0-100.
function slackShare(day, overrides) {
  var total = day && day.total ? day.total : 0
  if (total <= 0) return 0
  return Math.round(100 * slackTotal(day, overrides) / total)
}

// Heaviest slacking day on record: { key, ms }, ms 0 when nothing
// qualifies. Only days that still carry per-app detail can be scored —
// pruning keeps a day's total but drops its breakdown — so this spans the
// retention window rather than all of history. liveToday is folded in
// explicitly because today's bucket only reaches the mirror on persist.
function slackiestDay(days, todayKey, liveToday, overrides) {
  var best = { key: "", ms: 0 }
  var all = days || {}
  for (var k in all) {
    if (!Object.prototype.hasOwnProperty.call(all, k)) continue
    if (k === todayKey) continue
    var ms = slackTotal(all[k], overrides)
    if (ms > best.ms) best = { key: k, ms: ms }
  }
  if (todayKey) {
    var todayMs = slackTotal(liveToday || all[todayKey], overrides)
    if (todayMs > best.ms) best = { key: todayKey, ms: todayMs }
  }
  return best
}

// Row heat for a slacking entry, 0-1: the panel fades the row toward the
// theme's urgent colour by this much. Saturates at two hours, with the
// early minutes weighted so a short session already shows.
// Share of the day at which a slacking entry reads fully red. Heat is a
// proportion, not a duration: two hours of YouTube on a twelve-hour day is
// a footnote, while the same two hours on a three-hour day is the whole
// story. Time alone could not tell those apart.
var SLACK_HEAT_FULL_SHARE = 0.4

// Row heat for a slacking entry, 0-1: the panel fades the row toward the
// theme's urgent colour by this much. Saturates once the entry accounts for
// SLACK_HEAT_FULL_SHARE of the day, with the early share weighted by the
// 0.6 curve so a small-but-real share already shows some colour.
function slackHeat(ms, totalMs) {
  var v = Math.max(0, Number(ms) || 0)
  var total = Math.max(0, Number(totalMs) || 0)
  if (v <= 0 || total <= 0) return 0
  var share = Math.min(1, (v / total) / SLACK_HEAT_FULL_SHARE)
  return Math.pow(share, 0.6)
}

function totalFor(days, key) {
  var d = days && days[key]
  return d && d.total ? d.total : 0
}

function prevKey(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  d.setDate(d.getDate() - 1)
  return dayKey(d)
}

var WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Full date label for a dayKey, e.g. "Aug 15".
function formatDate(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  return MONTH_NAMES[d.getMonth()] + " " + d.getDate()
}

var WEEKDAY_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                    "Friday", "Saturday"]

// Ordinal suffix for a day of the month: 1st, 2nd, 3rd, 4th ... The teens
// are the exception -- 11th/12th/13th, not 11st/12nd/13rd.
function ordinal(n) {
  n = Math.floor(Number(n) || 0)
  var rem100 = n % 100
  if (rem100 >= 11 && rem100 <= 13) return n + "th"
  var rem10 = n % 10
  if (rem10 === 1) return n + "st"
  if (rem10 === 2) return n + "nd"
  if (rem10 === 3) return n + "rd"
  return n + "th"
}

// Long date label with the weekday spelled out, e.g. "Sunday, Aug 18th".
// Used where a bare "Aug 18" would leave you counting back to work out
// which day of the week it actually was.
function formatDateLong(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  return WEEKDAY_FULL[d.getDay()] + ", " + MONTH_NAMES[d.getMonth()]
    + " " + ordinal(d.getDate())
}

// Abbreviated long-date: "Sat, Jul 18". Same information as formatDateLong
// in roughly two-thirds the width, for the value column where the full
// weekday name pushed the time off the end. No ordinal suffix either: the
// "th" earns nothing next to a weekday that has already fixed the date, and
// the value column is the one place in the panel with no width to spare.
function formatDateShort(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  return WEEKDAY_NAMES[d.getDay()] + ", " + MONTH_NAMES[d.getMonth()]
    + " " + d.getDate()
}

// Short weekday name for any key, e.g. "Mon".  Unlike relativeDayLabel
// this never returns "Today" or "Yesterday".
function weekdayLabel(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  return WEEKDAY_NAMES[d.getDay()]
}

// Weekday label for a dayKey relative to today: "Today", "Yesterday", or
// the short weekday name.

function relativeDayLabel(key, todayKey) {
  if (!key) return ""
  if (key === todayKey) return "Today"
  if (key === prevKey(todayKey)) return "Yesterday"
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  return WEEKDAY_NAMES[d.getDay()]
}

// Last 7 day keys ending at todayKey, oldest first.
function weekKeys(todayKey) {
  if (!todayKey) return []
  var keys = []
  var key = todayKey
  for (var i = 0; i < 7; i++) {
    keys.unshift(key)
    key = prevKey(key)
  }
  return keys
}

// Busiest day in the trailing 7 days: { key, total }.
function busiestWeekDay(days, todayKey) {
  var keys = weekKeys(todayKey)
  if (!keys.length) return { key: "", total: 0 }
  var best = { key: keys[keys.length - 1], total: 0 }
  for (var i = 0; i < keys.length; i++) {
    var total = totalFor(days, keys[i])
    if (total > best.total) best = { key: keys[i], total: total }
  }
  return best
}

// Drops history older than keepDays (cutoff = todayKey - (keepDays - 1)).
// Keys are ISO "YYYY-MM-DD", so plain string comparison orders them
// correctly — sanitizeHistory guarantees every stored key is date-shaped
// and persist() only adds todayKey, so no non-date key can reach the
// comparison. Returns the original object when nothing is pruned so
// callers can avoid needless object churn on every persist.
function pruneDays(days, todayKey, keepDays) {
  if (!days || keepDays <= 0) return days
  var cutoff = todayKey
  for (var i = 1; i < keepDays; i++) cutoff = prevKey(cutoff)
  var out = {}
  var changed = false
  for (var k in days) {
    if (k >= cutoff) out[k] = days[k]
    else changed = true
  }
  return changed ? out : days
}

// Ordered list of insight rows: [{ label, value }]. Day-specific rows
// follow the selected day; the pattern rows (average, week pace, streak,
// weekday) stay anchored to now. Missing data shows "—" placeholders.
// slack holds the user's membership overrides and liveToday today's
// unpersisted bucket, both needed by the two slacking rows.
// Section a row belongs under, in render order. Rows come out of insights()
// already grouped, so a caller only needs to notice where one section ends
// and the next begins -- and a section whose rows have all been dismissed
// simply never appears, header included.
function startsGroup(rows, index) {
  var list = Array.isArray(rows) ? rows : []
  if (index < 0 || index >= list.length) return false
  if (index === 0) return true
  return list[index].group !== list[index - 1].group
}

// ---- Dismissable stats ---------------------------------------------------
// Rows the user has dismissed are stored as a list of insight ids in the
// widget's settings. Ids are stable across relabelling, so hiding "Streak"
// keeps it hidden even if its wording changes; hiding is by identity, never
// by position or label.

function hiddenSet(hidden) {
  var set = {}
  var list = Array.isArray(hidden) ? hidden : []
  for (var i = 0; i < list.length; i++) {
    if (typeof list[i] === "string" && list[i]) set[list[i]] = true
  }
  return set
}

function visibleInsights(rows, hidden) {
  var set = hiddenSet(hidden)
  var out = []
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) if (!set[list[i].id]) out.push(list[i])
  return out
}

// The dismissed rows, in the order they would otherwise appear, so the
// settings view can offer them back in a stable order.
function hiddenInsights(rows, hidden) {
  var set = hiddenSet(hidden)
  var out = []
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) if (set[list[i].id]) out.push(list[i])
  return out
}

// Adds or removes one id, returning a NEW array so QML bindings fire.
function toggleHiddenStat(hidden, id) {
  if (!id) return Array.isArray(hidden) ? hidden.slice() : []
  var list = Array.isArray(hidden) ? hidden : []
  var out = []
  var found = false
  for (var i = 0; i < list.length; i++) {
    if (list[i] === id) { found = true; continue }
    if (typeof list[i] === "string" && list[i] && out.indexOf(list[i]) < 0)
      out.push(list[i])
  }
  if (!found) out.push(id)
  return out
}

// ---- Slacking budget -----------------------------------------------------
// The one forward-looking number in the plugin: everything else reports on
// a day already spent. A budget of 0 means no budget, not a budget of zero.

function budgetState(slackMs, budgetMs) {
  var budget = Number(budgetMs) || 0
  var used = Math.max(0, Number(slackMs) || 0)
  if (!isFinite(used)) used = 0
  if (!(budget > 0))
    return { active: false, over: false, ratio: 0, usedMs: used, budgetMs: 0,
             remainingMs: 0, overMs: 0 }
  return {
    active: true,
    over: used > budget,
    // Capped so a wildly blown budget cannot drive a progress bar off the
    // end of its track.
    ratio: Math.min(1, used / budget),
    usedMs: used,
    budgetMs: budget,
    remainingMs: Math.max(0, budget - used),
    overMs: Math.max(0, used - budget)
  }
}

function budgetLabel(state) {
  if (!state || !state.active) return ""
  if (state.over) return fmt(state.overMs) + " over budget"
  return fmt(state.remainingMs) + " of slack left"
}

// ---- Friday recap --------------------------------------------------------
// A once-a-week summary, delivered on the day you are most likely to want
// to hear it and least likely to act on it.

function isRecapDay(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return false
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return false
  return d.getDay() === 5
}

// Totals the trailing 7 days against the 7 before them. Returns null when
// there is nothing to report, so the caller can stay silent rather than
// send a notification full of dashes.
function weeklyRecap(days, todayKey, overrides, liveToday, liveTotal) {
  if (!todayKey) return null
  var thisTotal = 0, thisSlack = 0, prevTotal = 0, prevSlack = 0
  var key = todayKey
  for (var i = 0; i < 14; i++) {
    var d = (key === todayKey && liveToday) ? liveToday : (days || {})[key]
    var total = (key === todayKey)
      ? liveTotalFor(days, key, todayKey, liveTotal)
      : (d && d.total ? d.total : 0)
    var slack = slackTotal(d, overrides)
    if (i < 7) { thisTotal += total; thisSlack += slack }
    else { prevTotal += total; prevSlack += slack }
    key = prevKey(key)
  }
  if (thisTotal <= 0) return null

  var share = Math.round(100 * thisSlack / thisTotal)
  var body = share + "% of it slacking"
  if (prevTotal > 0) {
    var wasShare = Math.round(100 * prevSlack / prevTotal)
    body += share === wasShare
      ? ", the same as the week before"
      : ", " + (share > wasShare ? "up from " : "down from ")
        + wasShare + "% the week before"
  }
  return {
    title: "Your week: " + fmt(thisTotal),
    body: body + ".",
    totalMs: thisTotal,
    slackMs: thisSlack,
    sharePct: share
  }
}

// ---- Go-outside nudges -------------------------------------------------

// How many whole `everyHours` blocks a day's total has passed. The caller
// notifies when this rises, so a 3-hour interval fires at 3h, 6h, 9h and so
// on, and never twice for the same block. 0 hours means the feature is off.
function reminderLevel(totalMs, everyHours) {
  var hours = Number(everyHours) || 0
  if (hours <= 0) return 0
  var ms = Math.max(0, Number(totalMs) || 0)
  if (!isFinite(ms)) return 0
  return Math.floor(ms / (hours * 3600000))
}

// ---- Work vs slacking ----------------------------------------------------

// The part of a day that was not slacking. The panel leads with this pair:
// what you got done, and what got away from you.
function focusedTotal(day, overrides) {
  var total = day && day.total ? day.total : 0
  return Math.max(0, total - slackTotal(day, overrides))
}

// Slacking share of a day as a float percentage (slackShare rounds; this
// does not, so averages over several days do not accumulate rounding).
function slackSharePct(day, overrides) {
  var total = day && day.total ? day.total : 0
  if (total <= 0) return 0
  return 100 * slackTotal(day, overrides) / total
}

// Average slacking share across the `n` days *before* key, skipping days
// with nothing recorded. `days` counts how many actually contributed, so a
// caller can tell "0% average" apart from "no history to compare against".
function priorSlackShare(days, key, n, overrides) {
  var sum = 0
  var count = 0
  var k = prevKey(key)
  for (var i = 0; i < n; i++) {
    var d = (days || {})[k]
    if (d && d.total > 0) {
      sum += slackSharePct(d, overrides)
      count++
    }
    k = prevKey(k)
  }
  return { avg: count > 0 ? sum / count : 0, days: count }
}

// Lightest-slacking day in the trailing window: the one to point at when
// asking what a good day looks like. Days under `minMs` are ignored, since
// a five-minute day at 0% slacking is not an achievement.
var CLEAN_DAY_MIN_MS = 30 * 60 * 1000
function cleanestDay(days, todayKey, n, overrides, liveToday) {
  if (!todayKey || n <= 0) return null
  var best = null
  var k = todayKey
  for (var i = 0; i < n; i++) {
    var d = (k === todayKey && liveToday) ? liveToday : (days || {})[k]
    var total = d && d.total ? d.total : 0
    if (total >= CLEAN_DAY_MIN_MS) {
      var share = slackSharePct(d, overrides)
      if (!best || share < best.share) best = { key: k, share: share, ms: total }
    }
    k = prevKey(k)
  }
  return best
}

// Movement in a rate, said the way a person would say it. Naming the old
// number ("was 32%") beats quoting the gap ("27 pts worse"): points are
// the correct unit but they read as a score being kept, and the reader can
// see the current rate two rows above anyway.
function fmtRateChange(nowPct, priorPct) {
  var now = Math.round(Number(nowPct) || 0)
  var was = Math.round(Number(priorPct) || 0)
  // Both numbers, always. "was 32%" names the baseline but leaves the
  // reader to hunt for where they actually are; the row has to stand on
  // its own rather than lean on the Slacking row above it.
  //
  // "up from"/"down from" said out loud what the row's arrow and colour
  // were already saying, and the pair was the widest value in the panel --
  // wide enough to run into its own label. The direction lives in the
  // glyph; the words only have to carry the two numbers.
  if (now === was) return now + "%, unchanged"
  return now + "%, was " + was + "%"
}

// Rows for the patterns section. Every row carries a `kind` so the panel can
// pick its glyph and colour from the row's meaning rather than by matching
// on label text -- and so a row where "less" is an improvement (slacking)
// can be told apart from one where it is merely a decrease (total time).
function insights(day, days, todayKey, activeKey, slack, liveToday) {
  var key = activeKey || todayKey
  var isToday = key === todayKey
  var total = day && day.total ? day.total : 0
  var liveTotal = isToday ? total : 0
  var dash = "—"
  var when = isToday ? "" : " " + weekdayLabel(key)

  var slackMs = slackTotal(day, slack)
  var focusMs = focusedTotal(day, slack)
  var slackPct = slackShare(day, slack)

  // --- the headline pair: what got done, what got away ---
  var list = [{
    id: "focused",
    group: "Today",
    label: "Focused" + when,
    kind: "focus",
    value: total > 0
      ? fmt(focusMs) + " · (" + Math.max(0, 100 - slackPct) + "%)"
      : dash
  }]

  list.push({
    id: "slacking",
    group: "Today",
    label: "Slacking" + when,
    kind: "slack",
    value: total > 0 ? fmt(slackMs) + " · (" + slackPct + "%)" : dash
  })

  var apps = appList(day)
  var topApp = apps.length ? apps[0] : null
  list.push({
    id: "topApp",
    group: "Today",
    label: "Top app" + when,
    kind: "top",
    value: topApp
      ? displayName(topApp.app) + " · " + "(" + topApp.pct + "%)" + " · " + fmt(topApp.ms)
      : dash
  })

  // --- improvement: is the slacking going down? ---
  var compareKey = prevKey(key)
  var comparedTo = isToday ? "yesterday" : weekdayLabel(compareKey)
  var prevDay = (days || {})[compareKey]
  var prevSlack = slackTotal(prevDay, slack)
  var prevTotal = totalFor(days, compareKey)
  list.push({
    id: "slackVsPrev",
    group: "Progress",
    label: "Slacking vs " + comparedTo,
    kind: "slackDelta",
    value: prevTotal > 0 ? fmtDelta(slackMs - prevSlack) : dash
  })

  var prior = priorSlackShare(days, key, 7, slack)
  list.push({
    id: "slackRate",
    group: "Progress",
    label: "Slack rate vs week",
    kind: "shareDelta",
    value: (prior.days > 0 && total > 0)
      ? fmtRateChange(slackSharePct(day, slack), prior.avg)
      : dash
  })

  // --- totals, explicitly labelled as totals ---
  list.push({
    id: "totalVsPrev",
    group: "Progress",
    label: "Total vs " + comparedTo,
    kind: "delta",
    value: prevTotal > 0 ? fmtDelta(total - prevTotal) : dash
  })

  var week = weekVsLastWeek(days, todayKey, liveTotal)
  list.push({
    id: "totalVsWeek",
    group: "Progress",
    label: "Total vs last week",
    kind: "delta",
    value: week.lastMs > 0 || week.thisMs > 0 ? fmtDelta(week.delta) : dash
  })

  // --- records and habits ---
  var clean = cleanestDay(days, todayKey, 7, slack, liveToday)
  list.push({
    id: "cleanest",
    group: "Patterns",
    label: "Cleanest day",
    kind: "clean",
    value: clean
      ? relativeDayLabel(clean.key, todayKey) + " · " + Math.round(clean.share) + "% slacking"
      : dash
  })

  var peak = slackiestDay(days, todayKey, liveToday, slack)
  list.push({
    id: "peak",
    group: "Patterns",
    label: "Peak slack day",
    kind: "peak",
    value: peak.ms > 0 ? formatDateShort(peak.key) + " · " + fmt(peak.ms) : dash
  })

  var avg = dailyAverage(days, todayKey, 7, liveTotal)
  list.push({
    id: "dailyAvg",
    group: "Patterns",
    label: "Daily avg past week",
    kind: "avg",
    value: avg > 0 ? fmt(avg) + " / day" : dash
  })

  var streak = usageStreak(days, todayKey, liveTotal)
  list.push({
    id: "streak",
    group: "Patterns",
    label: "Streak",
    kind: "streak",
    value: streak > 0 ? streak + (streak === 1 ? " day" : " days") : dash
  })

  var busiest = busiestWeekDay(days, todayKey)
  list.push({
    id: "busiest",
    group: "Patterns",
    label: "Busiest day (7d)",
    kind: "busy",
    value: busiest.total > 0
      ? weekdayLabel(busiest.key) + " · " + fmt(busiest.total) : dash
  })

  var weekend = busiestWeekend(days, todayKey, liveTotal)
  list.push({
    id: "weekend",
    group: "Patterns",
    label: "Busiest weekend",
    kind: "weekend",
    value: weekend ? weekend.label + " · " + fmt(weekend.ms) : dash
  })

  return list
}

// Total for a key, with the live (not yet persisted) today folded in.
function liveTotalFor(days, key, todayKey, liveTotal) {
  if (key === todayKey) return Math.max(totalFor(days, key), liveTotal || 0)
  return totalFor(days, key)
}

// Mean of the trailing n calendar days ending at todayKey, empty days
// included: an honest per-day average, not per-active-day.
function dailyAverage(days, todayKey, n, liveTotal) {
  if (!todayKey || n <= 0) return 0
  var sum = 0
  var key = todayKey
  for (var i = 0; i < n; i++) {
    sum += liveTotalFor(days, key, todayKey, liveTotal)
    key = prevKey(key)
  }
  return sum / n
}

// Consecutive days with any usage, counted back from today (or from
// yesterday while today is still empty, so a fresh morning doesn't read
// as a broken streak).
function usageStreak(days, todayKey, liveTotal) {
  if (!todayKey) return 0
  var key = liveTotalFor(days, todayKey, todayKey, liveTotal) > 0
    ? todayKey : prevKey(todayKey)
  var n = 0
  while (key && n < 365 && liveTotalFor(days, key, todayKey, liveTotal) > 0) {
    n++
    key = prevKey(key)
  }
  return n
}

// This Mon-Sun week against last week over the SAME elapsed span (Monday
// through today vs last week's Monday through the same weekday), so a
// half-finished week isn't compared to a full one.
function weekVsLastWeek(days, todayKey, liveTotal) {
  var weeks = monSunWeeks(days, todayKey, 2)
  if (weeks.length < 2) return { thisMs: 0, lastMs: 0, delta: 0 }
  var thisMs = 0
  var lastMs = 0
  var elapsed = 0
  for (var i = 0; i < 7; i++) {
    var d = weeks[0].days[i]
    if (d.isFuture) break
    thisMs += liveTotalFor(days, d.key, todayKey, liveTotal)
    elapsed++
  }
  for (var j = 0; j < elapsed; j++) {
    lastMs += Number(weeks[1].days[j].ms) || 0
  }
  return { thisMs: thisMs, lastMs: lastMs, delta: thisMs - lastMs }
}

// Label for a Sat-Sun pair: "Aug 22-23", or "Aug 31 - Sep 1" when the
// weekend straddles a month boundary.
function weekendLabel(satKey, sunKey) {
  var a = String(satKey).split("-")
  var b = String(sunKey).split("-")
  if (a.length !== 3 || b.length !== 3) return ""
  var am = MONTH_NAMES[Number(a[1]) - 1]
  var bm = MONTH_NAMES[Number(b[1]) - 1]
  if (!am || !bm) return ""
  var ad = Number(a[2])
  var bd = Number(b[2])
  if (am === bm) return am + " " + ad + "\u2013" + bd
  return am + " " + ad + " \u2013 " + bm + " " + bd
}

// The heaviest Saturday+Sunday pair on record. Anchored on Saturdays so a
// weekend is always counted as one unit, never split across two results.
// Returns null when no weekend holds any time.
function busiestWeekend(days, todayKey, liveTotal) {
  var all = days || {}
  var keys = []
  var seen = {}
  for (var k in all) {
    if (!Object.prototype.hasOwnProperty.call(all, k)) continue
    keys.push(k)
    seen[k] = true
  }
  // Today may not have been persisted yet, but its weekend still counts.
  if (todayKey && !seen[todayKey]) keys.push(todayKey)

  // Reduce every weekend day to the Saturday that opens its weekend, so a
  // weekend known only by its Sunday is still found, and one known by both
  // days is only weighed once.
  var saturdays = {}
  for (var i = 0; i < keys.length; i++) {
    var parts = String(keys[i]).split("-")
    if (parts.length !== 3) continue
    var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    if (isNaN(d.getTime())) continue
    var dow = d.getDay()
    if (dow !== 6 && dow !== 0) continue
    if (dow === 0) d.setDate(d.getDate() - 1)
    saturdays[dayKey(d)] = true
  }

  var best = null
  for (var satKey in saturdays) {
    if (!Object.prototype.hasOwnProperty.call(saturdays, satKey)) continue
    var sp = satKey.split("-")
    var sun = new Date(Number(sp[0]), Number(sp[1]) - 1, Number(sp[2]))
    sun.setDate(sun.getDate() + 1)
    var sunKey = dayKey(sun)
    var ms = liveTotalFor(all, satKey, todayKey, liveTotal)
      + liveTotalFor(all, sunKey, todayKey, liveTotal)
    if (ms > 0 && (!best || ms > best.ms))
      best = { satKey: satKey, sunKey: sunKey, ms: ms }
  }
  if (!best) return null
  return {
    label: weekendLabel(best.satKey, best.sunKey),
    ms: best.ms,
    satKey: best.satKey,
    sunKey: best.sunKey
  }
}

// ---- Scrollable Mon-Sun bar graph helpers --------------------------------

// Returns the Monday of the ISO week containing `key`.
function weekStartMonday(key) {
  if (!key) return ""
  var parts = String(key).split("-")
  if (parts.length !== 3) return ""
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return ""
  var day = d.getDay()
  var diff = (day === 0 ? -6 : 1) - day
  d.setDate(d.getDate() + diff)
  return dayKey(d)
}

// ISO-8601 week number (Mon=1 .. Sun=7 weeks, W1 holds the first Thursday).
// Returns 0 for input that does not parse as a YYYY-MM-DD key.
function isoWeekNumber(key) {
  var parts = String(key).split("-")
  if (parts.length !== 3) return 0
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  if (isNaN(d.getTime())) return 0
  // Shift to the week's Thursday: ISO years are identified by that day.
  var target = new Date(d.valueOf())
  target.setDate(target.getDate() - ((d.getDay() + 6) % 7) + 3)
  // The Thursday of the week containing Jan 4 is always in ISO week 1.
  var firstThursday = new Date(target.getFullYear(), 0, 4)
  firstThursday.setDate(firstThursday.getDate() - ((firstThursday.getDay() + 6) % 7) + 3)
  return 1 + Math.round((target - firstThursday) / (7 * 86400000))
}

// Milliseconds from nowMs until the next full hour boundary. Used to turn
// the hero hourglass exactly on the hour. Falls back to one minute for
// input that does not parse as a timestamp.
function msUntilNextHour(nowMs) {
  var d = new Date(Number(nowMs))
  if (isNaN(d.getTime())) return 60000
  return (3600 - d.getMinutes() * 60 - d.getSeconds()) * 1000 - d.getMilliseconds()
}

// One app's trailing history, for the drill-down under a usage row.
// Oldest first, like every other trend here.
function appTrend(days, todayKey, app, n, liveToday) {
  if (!todayKey || !app || n <= 0) return []
  var keys = []
  var key = todayKey
  for (var i = 0; i < n; i++) { keys.unshift(key); key = prevKey(key) }
  var out = []
  for (var j = 0; j < keys.length; j++) {
    var k = keys[j]
    var d = (k === todayKey && liveToday) ? liveToday : (days || {})[k]
    var apps = d && d.apps ? d.apps : null
    var ms = apps && apps[app] ? Number(apps[app]) : 0
    if (!isFinite(ms) || ms < 0) ms = 0
    var parts = String(k).split("-")
    var dt = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    out.push({
      key: k,
      ms: ms,
      label: WEEKDAY_NAMES[dt.getDay()],
      isToday: k === todayKey
    })
  }
  return out
}

// ---- Fixed-range trends -------------------------------------------------
// Three ranges the panel can show without any pagination: the last 7 days,
// the last 30 days, and the last 12 months. Each returns bars oldest-first
// so the newest sits on the right, the direction a trend is read in.

// Trailing `n` days ending at todayKey, oldest first. liveTotal folds the
// in-flight today bucket in so the newest bar tracks the running clock.
function trailingDays(days, todayKey, n, liveTotal, slack, liveToday) {
  if (!todayKey || n <= 0) return []
  var keys = []
  var key = todayKey
  for (var i = 0; i < n; i++) {
    keys.unshift(key)
    key = prevKey(key)
  }
  var out = []
  for (var j = 0; j < keys.length; j++) {
    var k = keys[j]
    var parts = String(k).split("-")
    var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    var ms = liveTotalFor(days, k, todayKey, liveTotal)
    // Today's breakdown lives in the in-flight bucket, which is fresher
    // than the mirror in `days`.
    var dayObj = (k === todayKey && liveToday) ? liveToday : (days || {})[k]
    out.push({
      key: k,
      ms: ms,
      slackMs: Math.min(ms, slackTotal(dayObj, slack)),
      label: WEEKDAY_NAMES[d.getDay()],
      dayLabel: String(d.getDate()),
      isToday: k === todayKey
    })
  }
  return out
}

// Trailing `n` calendar months ending at todayKey's month, oldest first.
// Merges raw days with the persisted monthly rollups, so this reaches past
// the ~3 month retention window that daily detail is pruned to.
function trailingMonths(days, months, todayKey, n, liveTotal, slack, liveToday) {
  var parts = String(todayKey || "").split("-")
  var nowYear = Number(parts[0])
  var nowMonth = Number(parts[1]) - 1
  if (!nowYear || isNaN(nowMonth) || n <= 0) return []
  var out = []
  for (var i = n - 1; i >= 0; i--) {
    var m = nowMonth - i
    var y = nowYear
    while (m < 0) { m += 12; y -= 1 }
    var monthKey = y + "-" + pad2(m + 1)
    var total = monthTotal(months && months[monthKey])
    // Rolled-up months carry their own slacking now, so a year bar is
    // coloured even for months whose daily detail has been pruned. Months
    // rolled up before that was recorded contribute 0, which reads as
    // "not known" rather than "none" -- see monthSlackKnown.
    var slackMs = monthSlack(months && months[monthKey])
    var sawToday = false
    var sawAnyDay = false
    for (var dk in days) {
      if (!Object.prototype.hasOwnProperty.call(days, dk)) continue
      var dp = String(dk).split("-")
      if (dp.length !== 3) continue
      if (Number(dp[0]) !== y || Number(dp[1]) - 1 !== m) continue
      sawAnyDay = true
      if (dk === todayKey) {
        sawToday = true
        total += liveTotalFor(days, dk, todayKey, liveTotal)
        slackMs += slackTotal(liveToday || days[dk], slack)
      } else {
        var d = days[dk]
        total += d && d.total ? d.total : 0
        slackMs += slackTotal(d, slack)
      }
    }
    var isCurrent = y === nowYear && m === nowMonth
    // A brand new day has no `days` entry yet, so the live bucket would
    // otherwise be missing from the current month's bar.
    if (isCurrent && !sawToday) {
      total += Math.max(0, Number(liveTotal) || 0)
      slackMs += slackTotal(liveToday, slack)
    }
    out.push({
      key: monthKey,
      month: m,
      year: y,
      label: MONTH_NAMES[m],
      ms: total,
      slackMs: Math.min(total, slackMs),
      // False only for a legacy month rolled up before slacking was kept:
      // its bar is drawn without a slice and should not be read as a clean
      // month.
      slackKnown: sawAnyDay || monthSlackKnown(months && months[monthKey]),
      isCurrent: isCurrent
    })
  }
  return out
}

// Wall-clock milliseconds a trend range spans, for the "share of possible
// time" toggle. Daily bars are 24h each; monthly bars use the real length
// of each month, so February does not read as a busier month than March.
function trendPossibleMs(bars, isDaily) {
  var list = Array.isArray(bars) ? bars : []
  if (isDaily) return list.length * 86400000
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var y = Number(list[i].year)
    var m = Number(list[i].month)
    if (isNaN(y) || isNaN(m)) continue
    // Day 0 of the next month is the last day of this one.
    total += new Date(y, m + 1, 0).getDate() * 86400000
  }
  return total
}

// Largest bar in a trend list; 0 for an empty or all-zero range.
function trendMax(bars) {
  var max = 0
  var list = Array.isArray(bars) ? bars : []
  for (var i = 0; i < list.length; i++) {
    var ms = Number(list[i].ms) || 0
    if (ms > max) max = ms
  }
  return max
}

// Summed time across a trend list.
function trendTotal(bars) {
  var total = 0
  var list = Array.isArray(bars) ? bars : []
  for (var i = 0; i < list.length; i++) total += Number(list[i].ms) || 0
  return total
}

// Mon-Sun aligned weeks for the scrollable bar graph. Returns an array of
// `weekCount` week objects, newest first. Each week:
//   { month: "Aug", days: [{ key, ms, label, isEmpty, isFuture, isToday }] }
// Mon = index 0, Sun = index 6. Future days in the current week are flagged
// so the UI can render faint stubs.
function monSunWeeks(days, todayKey, weekCount) {
  if (!todayKey || weekCount <= 0) return []
  var weeks = []
  var monStart = weekStartMonday(todayKey)
  if (!monStart) return []
  for (var w = 0; w < weekCount; w++) {
    var weekDays = []
    var monthCounts = {}
    for (var di = 0; di < 7; di++) {
      var dParts = String(monStart).split("-")
      var dObj = new Date(Number(dParts[0]), Number(dParts[1]) - 1, Number(dParts[2]) + di)
      var dk = dayKey(dObj)
      var isFuture = dk > todayKey
      var ms = isFuture ? 0 : totalFor(days, dk)
      if (!isFuture) {
        var m = MONTH_NAMES[dObj.getMonth()]
        monthCounts[m] = (monthCounts[m] || 0) + 1
      }
      weekDays.push({
        key: dk,
        ms: ms,
        label: WEEKDAY_NAMES[dObj.getDay()],
        isEmpty: ms <= 0 && !isFuture,
        isFuture: isFuture,
        isToday: dk === todayKey
      })
    }
    var month = ""
    var bestCount = 0
    for (var mKey in monthCounts) {
      if (monthCounts[mKey] > bestCount) {
        bestCount = monthCounts[mKey]
        month = mKey
      }
    }
    weeks.push({ month: month, days: weekDays })
    // Next week: go back 7 days from this Monday.
    var mParts = String(monStart).split("-")
    var mObj = new Date(Number(mParts[0]), Number(mParts[1]) - 1, Number(mParts[2]) - 7)
    monStart = dayKey(mObj)
  }
  return weeks
}

// Monthly totals for a given year. Returns 12 objects:
//   { month: 0-11, label: "Jan", ms: number, hours: "156h" }
// ---- Monthly aggregates --------------------------------------------------
// A month entry used to be a bare number of milliseconds. It is now
// { total, slack } so the yearly view can colour its bars and the slacking
// stats can reach past the daily-detail retention window. Both shapes are
// read here; a number is treated as a month whose slacking is simply not
// known (which is exactly what it is -- absence of data, not absence of
// slacking). Nothing migrates old numbers in place: the breakdown they
// would need was thrown away when they were rolled up, so inventing a zero
// would be a lie that later maths would trust.

function monthTotal(entry) {
  if (entry === null || entry === undefined) return 0
  if (typeof entry === "number") return isFinite(entry) && entry > 0 ? entry : 0
  var v = Number(entry.total)
  return isFinite(v) && v > 0 ? v : 0
}

// Slacking recorded for a month, and whether it is known at all.
function monthSlack(entry) {
  if (!entry || typeof entry !== "object") return 0
  var v = Number(entry.slack)
  return isFinite(v) && v > 0 ? Math.min(v, monthTotal(entry)) : 0
}

function monthSlackKnown(entry) {
  return !!(entry && typeof entry === "object" && entry.slack !== undefined)
}

// Merges day totals about to be pruned into the monthly aggregates object.
// Returns a new months object with the pruned days rolled up. Each day's
// total is added to its "YYYY-MM" key.
function rollupPrunedDays(months, prunedDays, overrides) {
  if (!prunedDays) return months || {}
  var out = Object.assign({}, months || {})
  for (var dk in prunedDays) {
    if (!Object.prototype.hasOwnProperty.call(prunedDays, dk)) continue
    var d = prunedDays[dk]
    var total = d && d.total ? d.total : 0
    if (total <= 0) continue
    var parts = String(dk).split("-")
    if (parts.length !== 3) continue
    var mk = parts[0] + "-" + parts[1]
    var prev = out[mk]
    // Roll the day's slacking up with its total, so the breakdown survives
    // the day itself. A month that already holds a legacy bare number keeps
    // its total and starts recording slack from here.
    out[mk] = {
      total: monthTotal(prev) + total,
      slack: monthSlack(prev) + slackTotal(d, overrides)
    }
  }
  return out
}
// Node-style exports only so `node --test` can drive these pure functions;
// QML's JS engine never defines `module`, so this guard is inert there.
if (typeof module !== "undefined" && module && module.exports) {
  module.exports = {
    pad2: pad2,
    canonicalApp: canonicalApp,
    displayName: displayName,
    siteDomain: siteDomain,
    webAppDomain: webAppDomain,
    siteLabel: siteLabel,
    isBrowserApp: isBrowserApp,
    appIconQueries: appIconQueries,
    sanitizeHistory: sanitizeHistory,
    HISTORY_LIMITS: HISTORY_LIMITS,
    dayFor: dayFor,
    dayKey: dayKey,
    newDay: newDay,
    fmt: fmt,
    fmtDelta: fmtDelta,
    fmtWords: fmtWords,

    appList: appList,
    isDefaultSlack: isDefaultSlack,
    isSlackApp: isSlackApp,
    toggleSlack: toggleSlack,
    sanitizeSlack: sanitizeSlack,
    slackTotal: slackTotal,
    slackShare: slackShare,
    slackSharePct: slackSharePct,
    focusedTotal: focusedTotal,
    priorSlackShare: priorSlackShare,
    cleanestDay: cleanestDay,
    fmtRateChange: fmtRateChange,
    reminderLevel: reminderLevel,
    budgetState: budgetState,
    budgetLabel: budgetLabel,
    isRecapDay: isRecapDay,
    weeklyRecap: weeklyRecap,
    slackiestDay: slackiestDay,
    slackHeat: slackHeat,
    totalFor: totalFor,
    prevKey: prevKey,
    relativeDayLabel: relativeDayLabel,
    weekdayLabel: weekdayLabel,
    formatDate: formatDate,
    formatDateShort: formatDateShort,
    visibleInsights: visibleInsights,
    startsGroup: startsGroup,
    hiddenInsights: hiddenInsights,
    toggleHiddenStat: toggleHiddenStat,
    formatDateLong: formatDateLong,
    ordinal: ordinal,
    trailingDays: trailingDays,
    appTrend: appTrend,
    trailingMonths: trailingMonths,
    trendMax: trendMax,
    trendPossibleMs: trendPossibleMs,
    trendTotal: trendTotal,
    weekKeys: weekKeys,
    busiestWeekDay: busiestWeekDay,
    pruneDays: pruneDays,
    insights: insights,
    dailyAverage: dailyAverage,
    usageStreak: usageStreak,
    weekVsLastWeek: weekVsLastWeek,
    busiestWeekend: busiestWeekend,
    weekendLabel: weekendLabel,
    weekStartMonday: weekStartMonday,
    isoWeekNumber: isoWeekNumber,
    msUntilNextHour: msUntilNextHour,
    monSunWeeks: monSunWeeks,
    monthTotal: monthTotal,
    monthSlack: monthSlack,
    monthSlackKnown: monthSlackKnown,
    rollupPrunedDays: rollupPrunedDays
  }
}
