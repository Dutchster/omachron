"use strict"

const { test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../lib/Model.js")

test("dayKey pads month and day", () => {
  assert.equal(Model.dayKey(new Date(2026, 7, 15)), "2026-08-15")
  assert.equal(Model.dayKey(new Date(2026, 0, 3)), "2026-01-03")
})

// fmt is the compact form used everywhere space is tight: bar label,
// donut centre, legend rows, week and month bars.
test("fmt renders compact durations", () => {
  assert.equal(Model.fmt(0), "0m")
  assert.equal(Model.fmt(45000), "45s")
  assert.equal(Model.fmt(60000), "1m")
  assert.equal(Model.fmt(1800000), "30m")
  assert.equal(Model.fmt(3600000), "1h")
  assert.equal(Model.fmt(5400000), "1h 30m")
  assert.equal(Model.fmt(-5000), "0m")
})

// fmtWords is the worded subtitle in the Omachron panel hero
// ("2 hours 10 minutes"); assertions must match that rendering exactly.
test("fmtWords renders worded durations", () => {
  assert.equal(Model.fmtWords(0), "0 minutes")
  assert.equal(Model.fmtWords(45000), "45 seconds")
  assert.equal(Model.fmtWords(60000), "1 minute")
  assert.equal(Model.fmtWords(7800000), "2 hours 10 minutes")
})

test("canonicalApp folds browser subprocess names", () => {
  assert.equal(Model.canonicalApp("zen-bin"), "zen")
  assert.equal(Model.canonicalApp("brave-browser"), "brave")
  assert.equal(Model.canonicalApp("foot"), "foot")
  assert.equal(Model.canonicalApp(""), "")
})

test("canonicalApp folds Chromium web apps across profiles", () => {
  const defaultProfile = Model.canonicalApp("chrome-chatgpt.com__-Default")
  const numberedProfile = Model.canonicalApp("chrome-chatgpt.com__-Profile_2")

  assert.equal(defaultProfile, "chrome-chatgpt.com")
  assert.equal(numberedProfile, defaultProfile)
  assert.equal(
    Model.canonicalApp("chrome-music.apple.com__lv_home-Default"),
    "chrome-music.apple.com"
  )
})

test("canonicalApp normalizes Chromium-family web app keys", () => {
  assert.equal(
    Model.canonicalApp("chromium-calendar.google.com__-Profile_1"),
    "chromium-calendar.google.com"
  )
  assert.equal(
    Model.canonicalApp("brave-calendar.google.com__-Default"),
    "brave-calendar.google.com"
  )
  assert.equal(
    Model.canonicalApp("msedge-calendar.google.com__-Default"),
    "msedge-calendar.google.com"
  )
  assert.equal(
    Model.canonicalApp("vivaldi-calendar.google.com__-Default"),
    "vivaldi-calendar.google.com"
  )
})

test("displayName shortens reverse-DNS ids and passes plain names", () => {
  assert.equal(Model.displayName("com.github.user.Codium"), "codium")
  assert.equal(Model.displayName("org.mozilla.firefox"), "firefox")
  assert.equal(Model.displayName("io.github.pkruow.Cli"), "cli")
  assert.equal(Model.displayName("opencode"), "opencode")
  assert.equal(Model.displayName("google-chrome"), "google-chrome")
  assert.equal(Model.displayName(""), "")
  assert.equal(Model.displayName(null), "")
})

test("displayName names Chromium-family web app keys like the sites they wrap", () => {
  assert.equal(Model.displayName("chrome-chatgpt.com__-Default"), "chatgpt")
  assert.equal(
    Model.displayName("chrome-music.apple.com__lv_home-Default"),
    "apple music"
  )
  assert.equal(
    Model.displayName("chrome-calendar.google.com__-Profile_1"),
    "google calendar"
  )
  assert.equal(Model.displayName("chromium-chatgpt.com__-Default"), "chatgpt")
  assert.equal(Model.displayName("brave-chatgpt.com__-Default"), "chatgpt")
  assert.equal(Model.displayName("msedge-chatgpt.com__-Default"), "chatgpt")
  assert.equal(
    Model.displayName("vivaldi-chatgpt.com__-Default"),
    "chatgpt"
  )
  assert.equal(Model.displayName("chrome-chatgpt.com"), "chatgpt")
  assert.equal(Model.displayName("chrome-web.whatsapp.com__x-Default"), "whatsapp")
  assert.equal(Model.displayName("brave-news.bbc.co.uk__-Default"), "bbc")
})

test("webAppDomain extracts hosts from web-app window classes only", () => {
  assert.equal(Model.webAppDomain("brave-chatgpt.com__-Default"), "chatgpt.com")
  assert.equal(Model.webAppDomain("chrome-web.whatsapp.com__x-Default"),
    "web.whatsapp.com")
  assert.equal(Model.webAppDomain("firefox"), "")
  assert.equal(Model.webAppDomain("site:github.com"), "")
  assert.equal(Model.webAppDomain(""), "")
})

test("siteLabel walks parent suffixes and strips public suffixes", () => {
  assert.equal(Model.siteLabel("u.mail.google.com"), "gmail")
  assert.equal(Model.siteLabel("news.bbc.co.uk"), "bbc")
  assert.equal(Model.siteLabel("stackoverflow.com"), "stack overflow")
  assert.equal(Model.siteLabel("developer.mozilla.org"), "mdn")
  assert.equal(Model.siteLabel("localhost"), "localhost")
  assert.equal(Model.siteLabel("192.168.1.5"), "192.168.1.5")
})

test("displayName keeps dotted non-reverse-DNS names intact", () => {
  assert.equal(Model.displayName("Minecraft* 26.2"), "minecraft* 26.2")
  assert.equal(Model.displayName("editor-1.2"), "editor-1.2")
})

test("displayName passes unresolved Steam ids through untouched", () => {
  // Game titles are resolved by scripts/resolve_app.py before storage;
  // the display layer must never touch the filesystem for a label.
  // (require()-based resolution cannot run in QML's JS engine anyway.)
  assert.equal(Model.displayName("steam_app_730"), "steam_app_730")
  assert.equal(Model.resolveSteamAppName, undefined)
})

test("sanitizeHistory keeps valid sections and rejects malformed ones", () => {
  const days = { "2026-08-21": { total: 5, apps: { zen: 5 } } }
  const months = { "2026-07": 9823400 }

  const clean = Model.sanitizeHistory(days, months)
  assert.equal(clean.days, days)
  assert.equal(clean.months, months)

  // Arrays pass typeof "object" but are not valid history containers.
  assert.deepEqual(Model.sanitizeHistory([1, 2], days).days, {})
  assert.deepEqual(Model.sanitizeHistory(days, ["x"]).months, {})
  assert.deepEqual(Model.sanitizeHistory(null, undefined).days, {})
  assert.deepEqual(Model.sanitizeHistory("{}", 42).months, {})
})

test("appList drops sub-minute apps and sorts descending", () => {
  const today = {
    total: 300000,
    apps: { editor: 120000, foot: 30000, browser: 150000 }
  }
  const list = Model.appList(today)
  assert.deepEqual(list.map(a => a.app), ["browser", "editor"])
  assert.equal(list[0].pct, 50)
  assert.equal(list[1].pct, 40)
})

test("dayFor returns live today when nothing is selected", () => {
  const today = { total: 100, apps: { a: 100 } }
  const days = { "2026-08-17": { total: 50, apps: { b: 50 } } }
  assert.equal(Model.dayFor(days, today, "", "2026-08-18"), today)
})

test("dayFor returns live today when today's key is selected", () => {
  const today = { total: 100, apps: { a: 100 } }
  assert.equal(Model.dayFor({}, today, "2026-08-18", "2026-08-18"), today)
})

test("dayFor returns stored day for a past key", () => {
  const today = { total: 100, apps: { a: 100 } }
  const past = { total: 50, apps: { b: 50 } }
  const days = { "2026-08-17": past }
  assert.equal(Model.dayFor(days, today, "2026-08-17", "2026-08-18"), past)
})

test("dayFor returns null for unknown keys", () => {
  const today = { total: 1, apps: {} }
  assert.equal(Model.dayFor({}, today, "2026-01-01", "2026-08-18"), null)
})

test("prevKey handles month and year boundaries", () => {
  assert.equal(Model.prevKey("2026-08-15"), "2026-08-14")
  assert.equal(Model.prevKey("2026-03-01"), "2026-02-28")
  assert.equal(Model.prevKey("2026-01-01"), "2025-12-31")
})

test("weekKeys returns 7 keys ending today", () => {
  const keys = Model.weekKeys("2026-08-15")
  assert.equal(keys.length, 7)
  assert.equal(keys[6], "2026-08-15")
  assert.equal(keys[0], "2026-08-09")
})

// Replaces the coverage the old weekTrend guard test carried: every
// key-taking helper must return something empty rather than a garbage
// label when handed "" or a string that is not a YYYY-MM-DD key.
test("empty or malformed keys never produce garbage labels", () => {
  for (const bad of ["", "nonsense", "2026-08", "a-b-c"]) {
    assert.equal(Model.formatDate(bad), "", `formatDate(${bad})`)
    assert.equal(Model.formatDateLong(bad), "", `formatDateLong(${bad})`)
    assert.equal(Model.weekdayLabel(bad), "", `weekdayLabel(${bad})`)
    assert.equal(Model.weekStartMonday(bad), "", `weekStartMonday(${bad})`)
    assert.equal(Model.isoWeekNumber(bad), 0, `isoWeekNumber(${bad})`)
  }
  assert.deepEqual(Model.weekKeys(""), [])
  assert.deepEqual(Model.trailingDays({}, "", 7, 0), [])
  assert.deepEqual(Model.trailingMonths({}, {}, "", 12, 0), [])
  assert.equal(Model.relativeDayLabel("", "2026-08-15"), "")
})

test("relativeDayLabel names today and yesterday", () => {
  assert.equal(Model.relativeDayLabel("2026-08-15", "2026-08-15"), "Today")
  assert.equal(Model.relativeDayLabel("2026-08-14", "2026-08-15"), "Yesterday")
  assert.equal(Model.relativeDayLabel("2026-08-13", "2026-08-15"), "Thu")
})

test("busiestWeekDay picks the largest total in the trailing week", () => {
  const days = {
    "2026-08-09": { total: 1000 },
    "2026-08-11": { total: 9000 },
    "2026-08-15": { total: 3000 }
  }
  const best = Model.busiestWeekDay(days, "2026-08-15")
  assert.equal(best.key, "2026-08-11")
  assert.equal(best.total, 9000)
})

test("pruneDays keeps only the retention window", () => {
  const days = {
    "2026-07-15": { total: 1 },
    "2026-08-01": { total: 2 },
    "2026-08-10": { total: 3 },
    "2026-08-15": { total: 4 }
  }
  const out = Model.pruneDays(days, "2026-08-15", 7)
  assert.deepEqual(Object.keys(out), ["2026-08-10", "2026-08-15"])
})

test("pruneDays returns the same object when nothing is pruned", () => {
  const days = { "2026-08-15": { total: 3 } }
  assert.equal(Model.pruneDays(days, "2026-08-15", 31), days)
})

// Rows are looked up by label rather than index throughout, so reordering
// the patterns section does not cascade into a dozen broken assertions.
const row = (rows, label) => {
  const found = rows.find(r => r.label === label)
  assert.ok(found, `no row labelled "${label}" in [${rows.map(r => r.label)}]`)
  return found
}

test("insights leads with the work/slacking split, then the patterns", () => {
  const today = {
    total: 3600000,
    apps: { browser: 1800000, editor: 1800000 }
  }
  const days = {
    "2026-08-14": { total: 7200000 },
    "2026-08-11": { total: 14400000 }
  }
  const rows = Model.insights(today, days, "2026-08-15", "2026-08-15")
  assert.deepEqual(rows.map(r => r.label), [
    // Today
    "Focused", "Slacking", "Top app",
    // Progress
    "Slacking vs yesterday", "Slack rate vs week",
    "Total vs yesterday", "Total vs last week",
    // Patterns
    "Cleanest day", "Peak slack day", "Daily avg past week", "Streak",
    "Busiest day (7d)", "Busiest weekend"
  ])
  // The split is the headline: it comes before anything else.
  assert.equal(rows[0].kind, "focus")
  assert.equal(rows[1].kind, "slack")
  assert.ok(row(rows, "Top app").value.includes("browser"))
  assert.ok(row(rows, "Total vs yesterday").value.includes("less"))
  assert.ok(row(rows, "Daily avg past week").value.includes("/ day"))
})

test("every insight row carries a kind for the panel to style from", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-15", "2026-08-15")
  for (const r of rows) assert.ok(r.kind, `row "${r.label}" has no kind`)
})

test("insights dashes every row when there is no activity", () => {
  const rows = Model.insights(Model.newDay(), {}, "2026-08-15", "2026-08-15")
  assert.equal(rows.length, 13)
  for (const r of rows) assert.ok(r.value.includes("\u2014"), r.label)
})

test("dailyAverage means the trailing window including empty days", () => {
  const days = {
    "2026-08-15": { total: 7200000 },
    "2026-08-14": { total: 3600000 }
  }
  // (2h + 1h + five empty days) / 7
  assert.equal(Math.round(Model.dailyAverage(days, "2026-08-15", 7, 0)),
    Math.round(10800000 / 7))
  assert.equal(Model.dailyAverage({}, "2026-08-15", 7, 0), 0)
})

test("usageStreak counts consecutive days and forgives an empty today", () => {
  const days = {
    "2026-08-14": { total: 100000 },
    "2026-08-13": { total: 100000 },
    "2026-08-11": { total: 100000 }
  }
  // today empty: streak counts from yesterday, broken at the 12th
  assert.equal(Model.usageStreak(days, "2026-08-15", 0), 2)
  // live today extends it
  assert.equal(Model.usageStreak(days, "2026-08-15", 50000), 3)
  assert.equal(Model.usageStreak({}, "2026-08-15", 0), 0)
})

test("weekVsLastWeek compares equal elapsed spans", () => {
  // 2026-08-15 is a Saturday: 6 elapsed days (Mon-Sat) each week.
  const days = {}
  for (let d = 10; d <= 15; d++) days[`2026-08-${d}`] = { total: 3600000 }
  for (let d = 3; d <= 9; d++) days[`2026-08-0${d}`] = { total: 7200000 }
  const week = Model.weekVsLastWeek(days, "2026-08-15", 0)
  assert.equal(week.thisMs, 6 * 3600000)
  assert.equal(week.lastMs, 6 * 7200000)
  assert.equal(week.delta, week.thisMs - week.lastMs)
})

test("busiestWeekend finds the heaviest Sat+Sun pair", () => {
  const days = {
    "2026-08-22": { total: 5 * 3600000 },  // Sat
    "2026-08-23": { total: 4 * 3600000 },  // Sun -- 9h together
    "2026-08-29": { total: 8 * 3600000 }   // Sat alone
  }
  const best = Model.busiestWeekend(days, "2026-08-30", 0)
  assert.equal(best.label, "Aug 22–23")
  assert.equal(best.ms, 9 * 3600000)
  assert.equal(best.satKey, "2026-08-22")
  assert.equal(best.sunKey, "2026-08-23")
  assert.equal(Model.busiestWeekend({}, "2026-08-15", 0), null)
})

test("busiestWeekend counts a weekend as one unit, never split", () => {
  // Sunday alone must be credited to the Saturday that starts its weekend.
  const days = { "2026-08-23": { total: 6 * 3600000 } }
  const best = Model.busiestWeekend(days, "2026-08-30", 0)
  assert.equal(best.satKey, "2026-08-22")
  assert.equal(best.ms, 6 * 3600000)
})

test("busiestWeekend folds in a today that is not persisted yet", () => {
  // 2026-08-29 is a Saturday; today is the Sunday closing that weekend.
  const best = Model.busiestWeekend({ "2026-08-29": { total: 3600000 } },
                                    "2026-08-30", 2 * 3600000)
  assert.equal(best.ms, 3 * 3600000)
  assert.equal(best.label, "Aug 29–30")
})

test("weekendLabel spans month boundaries", () => {
  assert.equal(Model.weekendLabel("2026-08-22", "2026-08-23"), "Aug 22–23")
  assert.equal(Model.weekendLabel("2026-08-31", "2026-09-01"), "Aug 31 – Sep 1")
  assert.equal(Model.weekendLabel("bad", "2026-09-01"), "")
})

test("appList honors a custom minimum threshold", () => {
  const today = {
    total: 900000,
    apps: { big: 600000, mid: 240000, small: 60000 }
  }
  assert.equal(Model.appList(today).length, 3)
  assert.equal(Model.appList(today, 300000).length, 1)
  assert.equal(Model.appList(today, 0).length, 3)
  assert.deepEqual(Model.appList(today, 120000).map(a => a.app), ["big", "mid"])
})

test("weekdayLabel returns short weekday for valid keys", () => {
  assert.equal(Model.weekdayLabel("2026-08-15"), "Sat")
  assert.equal(Model.weekdayLabel("2026-08-10"), "Mon")
})

test("weekdayLabel handles empty and malformed keys", () => {
  assert.equal(Model.weekdayLabel(""), "")
  assert.equal(Model.weekdayLabel("not-a-date"), "")
})

test("insights shows correct labels when viewing a past day", () => {
  const today = { total: 100000, apps: { a: 100000 } }
  const days = {
    "2026-08-13": { total: 50000 },
    "2026-08-14": { total: 80000 }
  }
  const rows = Model.insights(today, days, "2026-08-15", "2026-08-14")
  assert.equal(rows[0].label, "Focused Fri")
  assert.equal(rows[1].label, "Slacking Fri")
  assert.ok(row(rows, "Top app Fri").value.includes("\u00b7"))
  // Comparisons name the day they compare against, not "yesterday".
  assert.ok(rows.some(r => r.label === "Slacking vs Thu"))
  assert.ok(rows.some(r => r.label === "Total vs Thu"))
})

test("fmtDelta words the comparison instead of signing it", () => {
  assert.equal(Model.fmtDelta(60000), "1m more")
  assert.equal(Model.fmtDelta(-120000), "2m less")
  assert.equal(Model.fmtDelta(0), "no change")
})

test("fmtWords renders singular for 1 second and 1 hour 1 minute", () => {
  assert.equal(Model.fmtWords(1000), "1 second")
  assert.equal(Model.fmtWords(3660000), "1 hour 1 minute")
})

test("formatDate returns month and day for valid keys", () => {
  assert.equal(Model.formatDate("2026-08-15"), "Aug 15")
  assert.equal(Model.formatDate("2026-01-01"), "Jan 1")
})

test("formatDate returns empty for empty or malformed keys", () => {
  assert.equal(Model.formatDate(""), "")
  assert.equal(Model.formatDate("not-a-date"), "")
})

test("busiestWeekDay returns zero total when all days are empty", () => {
  const days = {
    "2026-08-13": { total: 0 },
    "2026-08-14": { total: 0 },
    "2026-08-15": { total: 0 }
  }
  const best = Model.busiestWeekDay(days, "2026-08-15")
  assert.equal(best.total, 0)
})

test("browser_aliases.json is the single source of truth for canonicalApp", () => {
  const aliases = require("../lib/browser_aliases.json")
  assert.equal(typeof aliases, "object")
  assert.ok(Object.keys(aliases).length > 0)
  for (const [key, target] of Object.entries(aliases)) {
    assert.equal(Model.canonicalApp(key), target,
      `canonicalApp("${key}") should return "${target}" from browser_aliases.json`)
  }
})

// ---- Data safety: pruneDays -----------------------------------------------

test("pruneDays never removes todayKey", () => {
  const days = {}
  for (let i = 0; i < 40; i++) {
    const d = new Date(2026, 7, 15 - i)
    days[Model.dayKey(d)] = { total: i * 1000, apps: {} }
  }
  const out = Model.pruneDays(days, "2026-08-15", 7)
  assert.ok(out["2026-08-15"], "today must survive pruning")
})

test("pruneDays never removes days within the retention window", () => {
  const days = {
    "2026-08-09": { total: 100 },
    "2026-08-10": { total: 200 },
    "2026-08-11": { total: 300 },
    "2026-08-12": { total: 400 },
    "2026-08-13": { total: 500 },
    "2026-08-14": { total: 600 },
    "2026-08-15": { total: 700 }
  }
  const out = Model.pruneDays(days, "2026-08-15", 7)
  // All 7 days should survive
  assert.equal(Object.keys(out).length, 7)
})

test("pruneDays with keepDays of 1 keeps only today", () => {
  const days = {
    "2026-08-14": { total: 100 },
    "2026-08-15": { total: 200 }
  }
  const out = Model.pruneDays(days, "2026-08-15", 1)
  assert.deepEqual(Object.keys(out), ["2026-08-15"])
})

test("pruneDays with keepDays of 0 returns original (no-op)", () => {
  const days = { "2026-08-15": { total: 100 } }
  const out = Model.pruneDays(days, "2026-08-15", 0)
  assert.equal(out, days)
})

test("pruneDays with negative keepDays returns original (no-op)", () => {
  const days = { "2026-08-15": { total: 100 } }
  const out = Model.pruneDays(days, "2026-08-15", -5)
  assert.equal(out, days)
})

test("pruneDays with null days returns original", () => {
  assert.equal(Model.pruneDays(null, "2026-08-15", 7), null)
})

test("pruneDays across year boundary keeps correct window", () => {
  const days = {
    "2025-12-30": { total: 100 },
    "2025-12-31": { total: 200 },
    "2026-01-01": { total: 300 },
    "2026-01-02": { total: 400 }
  }
  const out = Model.pruneDays(days, "2026-01-02", 3)
  assert.ok(out["2026-01-02"])
  assert.ok(out["2026-01-01"])
  assert.ok(out["2025-12-31"])
  assert.equal(out["2025-12-30"], undefined)
})

// ---- Data safety: corrupt / missing input ----------------------------------

test("appList returns empty for null input", () => {
  assert.deepEqual(Model.appList(null), [])
  assert.deepEqual(Model.appList(undefined), [])
  assert.deepEqual(Model.appList({}), [])
})

test("appList ignores negative and NaN durations", () => {
  const today = {
    total: 1000,
    apps: { a: -5000, b: NaN, c: 120000 }
  }
  const list = Model.appList(today)
  // a: -5000 < 60000 => dropped, b: NaN => dropped, c: 120000 => kept
  assert.equal(list.length, 1)
  assert.equal(list[0].app, "c")
})

test("insights handles null day and empty days gracefully", () => {
  const rows = Model.insights(null, {}, "2026-08-15", "2026-08-15")
  assert.equal(rows.length, 13)
  for (const r of rows) assert.ok(r.value.includes("\u2014"), r.label)
})

test("insights handles day with apps but no total", () => {
  const day = { apps: { a: 60000 } }
  const rows = Model.insights(day, {}, "2026-08-15", "2026-08-15")
  assert.equal(rows.length, 13)
  // Top app is computed from the apps map even with no total recorded.
  assert.ok(row(rows, "Top app").value.includes("a"))
})

test("fmt and fmtWords handle very large values", () => {
  const day = 86400000 * 365  // one year in ms
  assert.ok(Model.fmt(day).includes("h"))
  assert.ok(Model.fmtWords(day).includes("hours"))
})

test("dayFor with null days and empty today returns null", () => {
  assert.equal(Model.dayFor(null, null, "2026-08-15", "2026-08-15"), null)
})

test("dayKey produces consistent keys across Date object reuse", () => {
  const d = new Date(2026, 0, 1)
  const k1 = Model.dayKey(d)
  const k2 = Model.dayKey(d)
  assert.equal(k1, k2)
  assert.equal(k1, "2026-01-01")
})

// ---- weekStartMonday -----------------------------------------------------

test("weekStartMonday returns Monday for mid-week date", () => {
  // 2026-08-19 is Wednesday; Monday is 2026-08-17
  assert.equal(Model.weekStartMonday("2026-08-19"), "2026-08-17")
})

test("weekStartMonday returns same day when already Monday", () => {
  assert.equal(Model.weekStartMonday("2026-08-17"), "2026-08-17")
})

test("weekStartMonday wraps to previous week on Sunday", () => {
  // 2026-08-16 is Sunday; Monday is 2026-08-10
  assert.equal(Model.weekStartMonday("2026-08-16"), "2026-08-10")
})

test("weekStartMonday returns empty for bad input", () => {
  assert.equal(Model.weekStartMonday(""), "")
  assert.equal(Model.weekStartMonday(null), "")
})

// ---- isoWeekNumber --------------------------------------------------------

test("isoWeekNumber returns ISO week for a Monday", () => {
  assert.equal(Model.isoWeekNumber("2026-08-17"), 34)
})

test("isoWeekNumber is consistent across the week", () => {
  assert.equal(Model.isoWeekNumber("2026-08-21"), 34)
})

test("isoWeekNumber handles year start", () => {
  assert.equal(Model.isoWeekNumber("2026-01-01"), 1)
  assert.equal(Model.isoWeekNumber("2025-12-29"), 1)
})

test("isoWeekNumber handles 53-week years", () => {
  assert.equal(Model.isoWeekNumber("2026-12-28"), 53)
  assert.equal(Model.isoWeekNumber("2027-01-03"), 53)
})

test("isoWeekNumber handles leap-year week boundary", () => {
  assert.equal(Model.isoWeekNumber("2024-12-30"), 1)
})

test("isoWeekNumber returns 0 for bad input", () => {
  assert.equal(Model.isoWeekNumber(""), 0)
  assert.equal(Model.isoWeekNumber("garbage"), 0)
})

// ---- msUntilNextHour -------------------------------------------------------

test("msUntilNextHour returns full hour at exact boundary", () => {
  assert.equal(Model.msUntilNextHour(new Date(2026, 7, 21, 10, 0, 0, 0).getTime()), 3600000)
})

test("msUntilNextHour counts down to the next hour", () => {
  assert.equal(Model.msUntilNextHour(new Date(2026, 7, 21, 10, 59, 30, 500).getTime()), 29500)
})

test("msUntilNextHour includes milliseconds", () => {
  assert.equal(Model.msUntilNextHour(new Date(2026, 7, 21, 10, 0, 0, 250).getTime()), 3599750)
})

test("msUntilNextHour falls back to one minute for bad input", () => {
  assert.equal(Model.msUntilNextHour(NaN), 60000)
})

// ---- monSunWeeks ---------------------------------------------------------

const sampleDays = {
  "2026-08-17": { total: 3600000 },
  "2026-08-18": { total: 7200000 },
  "2026-08-19": { total: 1800000 }
}

test("monSunWeeks returns correct week count", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 2)
  assert.equal(weeks.length, 2)
})

test("monSunWeeks first week has 7 day entries", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  assert.equal(weeks[0].days.length, 7)
})

test("monSunWeeks weeks start on Monday", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  // 2026-08-17 is Monday
  assert.equal(weeks[0].days[0].key, "2026-08-17")
  assert.equal(weeks[0].days[0].label, "Mon")
})

test("monSunWeeks weeks end on Sunday", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  assert.equal(weeks[0].days[6].key, "2026-08-23")
  assert.equal(weeks[0].days[6].label, "Sun")
})

test("monSunWeeks marks today correctly", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  const today = weeks[0].days.find(d => d.isToday)
  assert.ok(today)
  assert.equal(today.key, "2026-08-19")
})

test("monSunWeeks marks future days in current week", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  // Thu Aug 20 - Sun Aug 23 are future
  for (let i = 3; i < 7; i++) {
    assert.ok(weeks[0].days[i].isFuture, `Day index ${i} should be future`)
  }
})

test("monSunWeeks returns empty for bad input", () => {
  assert.deepEqual(Model.monSunWeeks({}, "", 3), [])
  assert.deepEqual(Model.monSunWeeks({}, "2026-08-19", 0), [])
})

test("monSunWeeks week labels show dominant month", () => {
  // Week starting Aug 31 - Sep 6: Mon Aug 31, Tue Sep 1...
  // 4 days in Sep, 3 in Aug → month should be "Sep"
  const weeks = Model.monSunWeeks(sampleDays, "2026-09-02", 1)
  assert.equal(weeks[0].month, "Sep")
})

test("monSunWeeks populates ms from days data", () => {
  const weeks = Model.monSunWeeks(sampleDays, "2026-08-19", 1)
  const mon = weeks[0].days.find(d => d.key === "2026-08-17")
  assert.equal(mon.ms, 3600000)
})

// ---- rollupPrunedDays ----------------------------------------------------

test("rollupPrunedDays merges day totals into months", () => {
  const pruned = {
    "2026-06-01": { total: 3600000 },
    "2026-06-15": { total: 7200000 }
  }
  const result = Model.rollupPrunedDays({}, pruned, {})
  assert.equal(Model.monthTotal(result["2026-06"]), 10800000)
})

test("rollupPrunedDays accumulates onto existing months", () => {
  // A legacy bare number keeps its total and starts recording slack.
  const months = { "2026-06": 5000000 }
  const pruned = { "2026-06-20": { total: 3000000 } }
  const result = Model.rollupPrunedDays(months, pruned, {})
  assert.equal(Model.monthTotal(result["2026-06"]), 8000000)
})

test("rollupPrunedDays returns original months when nothing to prune", () => {
  const months = { "2026-05": 1000000 }
  const result = Model.rollupPrunedDays(months, {})
  assert.deepEqual(result, { "2026-05": 1000000 })
})

test("rollupPrunedDays skips days with zero total", () => {
  const pruned = { "2026-07-01": { total: 0 } }
  const result = Model.rollupPrunedDays({}, pruned)
  assert.deepEqual(result, {})
})

test("rollupPrunedDays handles null months input", () => {
  const pruned = { "2026-04-05": { total: 1000000 } }
  const result = Model.rollupPrunedDays(null, pruned, {})
  assert.equal(Model.monthTotal(result["2026-04"]), 1000000)
})

// Site tracking keys ("site:<registrable-domain>") come from
// scripts/resolve_app.py resolving the focused browser tab.

test("siteDomain extracts the domain of site keys only", () => {
  assert.equal(Model.siteDomain("site:github.com"), "github.com")
  assert.equal(Model.siteDomain("SITE:GitHub.com"), "github.com")
  assert.equal(Model.siteDomain("firefox"), "")
  assert.equal(Model.siteDomain("chrome-github.com__x-Default"), "")
  assert.equal(Model.siteDomain(""), "")
})

test("displayName names known web apps the way people know them", () => {
  assert.equal(Model.displayName("site:mail.google.com"), "gmail")
  assert.equal(Model.displayName("site:music.youtube.com"), "youtube music")
  assert.equal(Model.displayName("site:news.ycombinator.com"), "hacker news")
  assert.equal(Model.displayName("site:google.com"), "google")
})

test("displayName renders site keys without scheme or public suffix", () => {
  assert.equal(Model.displayName("site:github.com"), "github")
  assert.equal(Model.displayName("site:ycombinator.com"), "ycombinator")
  assert.equal(Model.displayName("site:bbc.co.uk"), "bbc")
  assert.equal(Model.displayName("site:anthropic.com"), "anthropic")
})

test("displayName keeps hosts that have no suffix to strip", () => {
  assert.equal(Model.displayName("site:localhost"), "localhost")
  assert.equal(Model.displayName("site:192.168.1.5"), "192.168.1.5")
})

test("canonicalApp passes site keys through unchanged", () => {
  assert.equal(Model.canonicalApp("site:github.com"), "site:github.com")
})

test("isBrowserApp matches site-capable browser classes", () => {
  assert.equal(Model.isBrowserApp("firefox"), true)
  assert.equal(Model.isBrowserApp("brave-browser"), true)
  assert.equal(Model.isBrowserApp("LibreWolf"), true)
  assert.equal(Model.isBrowserApp("vivaldi-stable"), true)
  assert.equal(Model.isBrowserApp("tor-browser"), false)
  assert.equal(Model.isBrowserApp("mullvad-browser"), false)
  assert.equal(Model.isBrowserApp("foot"), false)
  assert.equal(Model.isBrowserApp("chrome-github.com__x-Default"), false)
  assert.equal(Model.isBrowserApp(""), false)
})

test("appIconQueries builds desktop-entry candidates for programs", () => {
  assert.deepEqual(Model.appIconQueries("brave"), ["brave", "brave-browser"])
  assert.deepEqual(Model.appIconQueries("vivaldi"), ["vivaldi", "vivaldi-stable"])
  assert.deepEqual(Model.appIconQueries("com.mitchellh.ghostty"),
    ["com.mitchellh.ghostty"])
  assert.deepEqual(Model.appIconQueries("LibreWolf"),
    ["LibreWolf", "librewolf"])
  assert.deepEqual(Model.appIconQueries("org.localsend.localsend_app"),
    ["org.localsend.localsend_app", "localsend"])
  assert.deepEqual(Model.appIconQueries("Signal"),
    ["Signal", "signal", "signal-desktop"])
  assert.deepEqual(Model.appIconQueries("code"),
    ["code", "code-oss", "visual-studio-code"])
  assert.deepEqual(Model.appIconQueries("pinta"),
    ["pinta", "com.github.PintaProject.Pinta"])
})

test("appIconQueries is empty for sites, Other, and empty keys", () => {
  assert.deepEqual(Model.appIconQueries("site:github.com"), [])
  assert.deepEqual(Model.appIconQueries("Other"), [])
  assert.deepEqual(Model.appIconQueries(""), [])
  assert.deepEqual(Model.appIconQueries(null), [])
})

test("insights top app shows the display name for site keys", () => {
  const day = {
    total: 7200000,
    apps: { "site:ycombinator.com": 5400000, foot: 1800000 }
  }
  const rows = Model.insights(day, {}, "2026-08-29", "2026-08-29")
  assert.match(row(rows, "Top app").value, /^ycombinator /)
})

// ---- Slacking off ---------------------------------------------------------

test("isDefaultSlack covers the shipped sites and programs", () => {
  assert.equal(Model.isDefaultSlack("site:youtube.com"), true)
  assert.equal(Model.isDefaultSlack("site:reddit.com"), true)
  assert.equal(Model.isDefaultSlack("site:x.com"), true)
  assert.equal(Model.isDefaultSlack("steam"), true)
  assert.equal(Model.isDefaultSlack("site:github.com"), false)
  assert.equal(Model.isDefaultSlack("opencode"), false)
  assert.equal(Model.isDefaultSlack(""), false)
})

// Site keys reduce to a registrable domain, but lib/site_apps.json hosts
// keep their own subdomain — those still have to match through the parent.
test("isDefaultSlack matches parent suffixes of site keys", () => {
  assert.equal(Model.isDefaultSlack("site:music.youtube.com"), true)
  assert.equal(Model.isDefaultSlack("site:tv.youtube.com"), true)
  assert.equal(Model.isDefaultSlack("site:store.steampowered.com"), true)
})

// A bare public suffix must never match on its own: "site:com" is not
// every .com site.
test("isDefaultSlack ignores a bare suffix", () => {
  assert.equal(Model.isDefaultSlack("site:com"), false)
  assert.equal(Model.isDefaultSlack("site:localhost"), false)
})

test("isDefaultSlack covers Chromium web-app windows", () => {
  assert.equal(Model.isDefaultSlack("chrome-youtube.com__-Default"), true)
  assert.equal(Model.isDefaultSlack("brave-github.com__-Default"), false)
})

test("isSlackApp lets overrides win over the defaults", () => {
  assert.equal(Model.isSlackApp("site:youtube.com", { "site:youtube.com": false }), false)
  assert.equal(Model.isSlackApp("site:github.com", { "site:github.com": true }), true)
  assert.equal(Model.isSlackApp("site:youtube.com", {}), true)
  assert.equal(Model.isSlackApp("site:youtube.com", null), true)
})

// Only disagreements are stored: flipping an entry back to what the
// shipped list already says drops the key entirely.
test("toggleSlack stores deviations and clears agreement", () => {
  const off = Model.toggleSlack({}, "site:youtube.com")
  assert.deepEqual(off, { "site:youtube.com": false })

  const back = Model.toggleSlack(off, "site:youtube.com")
  assert.deepEqual(back, {})

  const on = Model.toggleSlack({}, "opencode")
  assert.deepEqual(on, { opencode: true })
  assert.deepEqual(Model.toggleSlack(on, "opencode"), {})
})

test("toggleSlack never mutates the object it is given", () => {
  const before = { "site:youtube.com": false }
  const after = Model.toggleSlack(before, "steam")
  assert.deepEqual(before, { "site:youtube.com": false })
  assert.deepEqual(after, { "site:youtube.com": false, steam: false })
})

test("sanitizeSlack rejects anything that is not a boolean map", () => {
  assert.deepEqual(Model.sanitizeSlack(null), {})
  assert.deepEqual(Model.sanitizeSlack([true]), {})
  assert.deepEqual(Model.sanitizeSlack("nope"), {})
  assert.deepEqual(
    Model.sanitizeSlack({ "site:youtube.com": false, bad: 1, "SITE:X.COM": true }),
    { "site:youtube.com": false, "site:x.com": true }
  )
})

test("slackTotal and slackShare sum only slacking entries", () => {
  const day = {
    total: 4000000,
    apps: { "site:youtube.com": 1000000, "site:github.com": 2000000, steam: 1000000 }
  }
  assert.equal(Model.slackTotal(day, {}), 2000000)
  assert.equal(Model.slackShare(day, {}), 50)
  assert.equal(Model.slackTotal(day, { steam: false }), 1000000)
  assert.equal(Model.slackShare(day, { steam: false }), 25)
  assert.equal(Model.slackTotal(null, {}), 0)
  assert.equal(Model.slackShare({ total: 0, apps: {} }, {}), 0)
})

test("slackiestDay picks the heaviest day in the retained window", () => {
  const days = {
    "2026-08-13": { total: 3600000, apps: { "site:youtube.com": 3600000 } },
    "2026-08-14": { total: 7200000, apps: { "site:github.com": 7200000 } },
    "2026-08-15": { total: 1800000, apps: { "site:reddit.com": 1800000 } }
  }
  const peak = Model.slackiestDay(days, "2026-08-15", null, {})
  assert.equal(peak.key, "2026-08-13")
  assert.equal(peak.ms, 3600000)
})

// Today's bucket is not written to the mirror until the next persist, so
// a record set today has to come from the live day object.
test("slackiestDay folds in today's live bucket", () => {
  const days = {
    "2026-08-13": { total: 3600000, apps: { "site:youtube.com": 3600000 } },
    "2026-08-15": { total: 60000, apps: { "site:reddit.com": 60000 } }
  }
  const live = { total: 9000000, apps: { "site:reddit.com": 9000000 } }
  const peak = Model.slackiestDay(days, "2026-08-15", live, {})
  assert.equal(peak.key, "2026-08-15")
  assert.equal(peak.ms, 9000000)
})

test("slackiestDay reports nothing when no day qualifies", () => {
  const days = { "2026-08-14": { total: 7200000, apps: { "site:github.com": 7200000 } } }
  assert.deepEqual(Model.slackiestDay(days, "2026-08-15", null, {}), { key: "", ms: 0 })
  assert.deepEqual(Model.slackiestDay({}, "2026-08-15", null, {}), { key: "", ms: 0 })
})

test("slackHeat saturates on share of the day, not raw duration", () => {
  const day = 6 * 60 * 60 * 1000
  assert.equal(Model.slackHeat(0, day), 0)
  assert.equal(Model.slackHeat(-1, day), 0)
  // No day total means no share to reason about.
  assert.equal(Model.slackHeat(60 * 60 * 1000, 0), 0)
  // 40% of the day is full red, and anything past it stays pegged.
  assert.equal(Model.slackHeat(0.4 * day, day), 1)
  assert.equal(Model.slackHeat(0.9 * day, day), 1)
  // The same two hours reads very differently against a long day vs a short
  // one -- the whole point of moving off raw duration.
  const longDay = Model.slackHeat(2 * 60 * 60 * 1000, 12 * 60 * 60 * 1000)
  const shortDay = Model.slackHeat(2 * 60 * 60 * 1000, 3 * 60 * 60 * 1000)
  assert.ok(shortDay > longDay, "a short day should read hotter")
  assert.equal(shortDay, 1)
  assert.ok(longDay < 0.75)
  const short = Model.slackHeat(0.05 * day, day)
  const medium = Model.slackHeat(0.2 * day, day)
  assert.ok(short > 0 && short < medium && medium < 1)
})

test("insights reports the day's slacking and the peak slack day", () => {
  const today = {
    total: 3600000,
    apps: { "site:youtube.com": 1800000, editor: 1800000 }
  }
  const days = {
    "2026-08-13": { total: 9000000, apps: { "site:reddit.com": 9000000 } }
  }
  const rows = Model.insights(today, days, "2026-08-15", "2026-08-15", {}, today)
  assert.equal(row(rows, "Slacking").value, "30m · (50%)")
  // Focused is the complement; the two shares must add up to 100.
  assert.equal(row(rows, "Focused").value, "30m · (50%)")
  assert.equal(row(rows, "Peak slack day").value, "Thu, Aug 13 · 2h 30m")
})

test("insights honours slack overrides", () => {
  const today = { total: 3600000, apps: { "site:youtube.com": 3600000 } }
  const rows = Model.insights(today, {}, "2026-08-15", "2026-08-15",
    { "site:youtube.com": false }, today)
  assert.equal(row(rows, "Slacking").value, "0m · (0%)")
  // Opting youtube out makes the whole hour focused.
  assert.equal(row(rows, "Focused").value, "1h · (100%)")
  assert.equal(row(rows, "Peak slack day").value, "—")
})

// QML's JS engine has no require(), so lib/slack_apps.json is inlined into
// Model.js as a fallback literal. Node always takes the require() path, so
// nothing else would notice the two drifting apart — but the shell only
// ever runs the inline copy.
test("the inline slack list matches lib/slack_apps.json", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const src = fs.readFileSync(path.join(__dirname, "..", "lib", "Model.js"), "utf8")
  const inline = src.match(
    /\? require\("\.\/slack_apps\.json"\)\s*:\s*(\{[\s\S]*?\})\n  var sites/)
  assert.ok(inline, "SLACK_DEFAULTS inline fallback not found in Model.js")
  assert.deepEqual(JSON.parse(inline[1]), require("../lib/slack_apps.json"))
})

// Same hazard as the slack list above, and the one the shell actually
// renders every row through: SITE_APPS is inlined for QML and required
// under Node, so a name added to only one copy looks correct in the tests
// and wrong on screen.
test("the inline site-app map matches lib/site_apps.json", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const src = fs.readFileSync(path.join(__dirname, "..", "lib", "Model.js"), "utf8")
  const inline = src.match(
    /return require\("\.\/site_apps\.json"\)\s*\n  return (\{[\s\S]*?\})\n\}\)\(\)/)
  assert.ok(inline, "SITE_APPS inline fallback not found in Model.js")
  assert.deepEqual(JSON.parse(inline[1]), require("../lib/site_apps.json"))
})

// A site whose brand label collides with a native desktop app has to be
// told apart from it, or the panel prints the same word twice.
test("sites that collide with a desktop app are named apart from it", () => {
  const collisions = {
    "site:claude.ai": "claude web",
    "site:discord.com": "discord web",
    "site:open.spotify.com": "spotify web",
    "site:app.slack.com": "slack web",
    "site:web.telegram.org": "telegram web",
  }
  for (const [key, label] of Object.entries(collisions)) {
    assert.equal(Model.displayName(key), label)
    // The bare app keeps the plain name, so the two rows never match.
    assert.notEqual(Model.displayName(key), label.replace(" web", ""))
  }
  assert.equal(Model.displayName("claude"), "claude")
  assert.equal(Model.displayName("discord"), "discord")
  assert.equal(Model.displayName("spotify"), "spotify")
})

// Naming a site must not move which bucket it is tracked in: every
// collision key is the registrable domain the resolver would have reduced
// to anyway, so no existing history splits in two on upgrade.
test("collision names are labels only, never new tracking buckets", () => {
  assert.equal(Model.siteLabel("open.spotify.com"), "spotify web")
  assert.equal(Model.siteLabel("claude.ai"), "claude web")
  assert.equal(Model.siteLabel("discord.com"), "discord web")
})

test("slack_apps.json is the single source of truth for isDefaultSlack", () => {
  const list = require("../lib/slack_apps.json")
  for (const site of list.sites) {
    assert.equal(Model.isDefaultSlack("site:" + site), true,
      `site:${site} should count as slacking off`)
  }
  for (const app of list.apps) {
    assert.equal(Model.isDefaultSlack(app), true,
      `${app} should count as slacking off`)
  }
})

// ---- Ordinals and the long date label -----------------------------------

test("ordinal suffixes, teens included", () => {
  assert.equal(Model.ordinal(1), "1st")
  assert.equal(Model.ordinal(2), "2nd")
  assert.equal(Model.ordinal(3), "3rd")
  assert.equal(Model.ordinal(4), "4th")
  // The teens are the exception: 11th/12th/13th, never 11st/12nd/13rd.
  assert.equal(Model.ordinal(11), "11th")
  assert.equal(Model.ordinal(12), "12th")
  assert.equal(Model.ordinal(13), "13th")
  assert.equal(Model.ordinal(21), "21st")
  assert.equal(Model.ordinal(22), "22nd")
  assert.equal(Model.ordinal(23), "23rd")
  assert.equal(Model.ordinal(31), "31st")
})

test("formatDateLong spells out the weekday", () => {
  assert.equal(Model.formatDateLong("2026-08-18"), "Tuesday, Aug 18th")
  assert.equal(Model.formatDateLong("2026-08-01"), "Saturday, Aug 1st")
  assert.equal(Model.formatDateLong("2026-08-13"), "Thursday, Aug 13th")
  assert.equal(Model.formatDateLong(""), "")
  assert.equal(Model.formatDateLong("nonsense"), "")
})

// ---- Fixed-range trends --------------------------------------------------

test("trailingDays returns n days oldest-first with the live total folded in", () => {
  const days = { "2026-08-28": { total: 1000 }, "2026-08-29": { total: 2000 } }
  const bars = Model.trailingDays(days, "2026-08-30", 3, 9000)
  assert.equal(bars.length, 3)
  assert.deepEqual(bars.map(b => b.key),
    ["2026-08-28", "2026-08-29", "2026-08-30"])
  assert.deepEqual(bars.map(b => b.ms), [1000, 2000, 9000])
  assert.deepEqual(bars.map(b => b.label), ["Fri", "Sat", "Sun"])
  assert.equal(bars[2].isToday, true)
  assert.equal(bars[0].isToday, false)
})

test("trailingDays covers gaps with zeroes and handles bad input", () => {
  const bars = Model.trailingDays({}, "2026-08-30", 3, 0)
  assert.deepEqual(bars.map(b => b.ms), [0, 0, 0])
  assert.deepEqual(Model.trailingDays({}, "", 5, 0), [])
  assert.deepEqual(Model.trailingDays({}, "2026-08-30", 0, 0), [])
})

test("trailingMonths merges raw days with monthly rollups", () => {
  const days = { "2026-08-28": { total: 1000 }, "2026-08-29": { total: 2000 } }
  const months = { "2026-07": 777 }
  const bars = Model.trailingMonths(days, months, "2026-08-30", 2, 9000)
  assert.deepEqual(bars.map(b => b.key), ["2026-07", "2026-08"])
  assert.equal(bars[0].ms, 777)
  // Aug: two raw days plus the live bucket for a today with no entry yet.
  assert.equal(bars[1].ms, 1000 + 2000 + 9000)
  assert.equal(bars[1].isCurrent, true)
  assert.equal(bars[0].isCurrent, false)
})

test("trailingMonths does not double-count a persisted today", () => {
  const days = { "2026-08-30": { total: 5000 } }
  const bars = Model.trailingMonths(days, {}, "2026-08-30", 1, 9000)
  // liveTotalFor takes the max, it does not add the two together.
  assert.equal(bars[0].ms, 9000)
})

test("trailingMonths walks back across a year boundary", () => {
  const bars = Model.trailingMonths({}, { "2025-12": 500 }, "2026-01-15", 2, 0)
  assert.deepEqual(bars.map(b => b.key), ["2025-12", "2026-01"])
  assert.equal(bars[0].ms, 500)
  assert.deepEqual(bars.map(b => b.label), ["Dec", "Jan"])
})

test("trendMax and trendTotal summarise a bar list", () => {
  const bars = [{ ms: 10 }, { ms: 50 }, { ms: 20 }]
  assert.equal(Model.trendMax(bars), 50)
  assert.equal(Model.trendTotal(bars), 80)
  assert.equal(Model.trendMax([]), 0)
  assert.equal(Model.trendTotal([]), 0)
  assert.equal(Model.trendMax(null), 0)
  assert.equal(Model.trendTotal(null), 0)
})

// ---- Rotating verdict phrasing -------------------------------------------

// ---- Slacking share carried on the trend bars ----------------------------

const SLACK_DAYS = {
  // youtube is a shipped slacking default, opencode is not.
  "2026-08-28": { total: 4 * 3600000, apps: { "site:youtube.com": 2 * 3600000, opencode: 2 * 3600000 } },
  "2026-08-29": { total: 4 * 3600000, apps: { opencode: 4 * 3600000 } }
}

test("trailingDays carries each day's slacking portion", () => {
  const bars = Model.trailingDays(SLACK_DAYS, "2026-08-29", 2, 0, {}, null)
  assert.equal(bars[0].slackMs, 2 * 3600000)   // half of Friday
  assert.equal(bars[1].slackMs, 0)             // none on Saturday
})

test("trailingDays reads today's slacking from the live bucket", () => {
  const live = { total: 6 * 3600000, apps: { "site:reddit.com": 3 * 3600000, opencode: 3 * 3600000 } }
  const bars = Model.trailingDays(SLACK_DAYS, "2026-08-30", 3, 6 * 3600000, {}, live)
  assert.equal(bars[2].ms, 6 * 3600000)
  assert.equal(bars[2].slackMs, 3 * 3600000)
})

test("trend slack never exceeds the bar it sits in", () => {
  // A stale total smaller than its own app breakdown must not produce a
  // slice taller than the bar.
  const days = { "2026-08-29": { total: 60000, apps: { "site:youtube.com": 9999999 } } }
  const bars = Model.trailingDays(days, "2026-08-29", 1, 0, {}, null)
  assert.ok(bars[0].slackMs <= bars[0].ms)
})

test("trailingDays honours slacking overrides", () => {
  // Opting opencode in and youtube out flips which half of Friday is slack.
  const bars = Model.trailingDays(SLACK_DAYS, "2026-08-28", 1, 0,
    { opencode: true, "site:youtube.com": false }, null)
  assert.equal(bars[0].slackMs, 2 * 3600000)
})

test("trailingMonths sums slacking, and reports none for rolled-up months", () => {
  const bars = Model.trailingMonths(SLACK_DAYS, { "2026-06": 9999999 },
                                    "2026-08-29", 3, 0, {}, null)
  const june = bars.find(b => b.key === "2026-06")
  const august = bars.find(b => b.key === "2026-08")
  // June survives only as an aggregate, so its breakdown is gone.
  assert.equal(june.ms, 9999999)
  assert.equal(june.slackMs, 0)
  assert.equal(august.slackMs, 2 * 3600000)
})

// ---- Work vs slacking, and showing progress ------------------------------

test("focusedTotal is the day minus its slacking", () => {
  const day = { total: 4 * 3600000, apps: { "site:youtube.com": 3600000, opencode: 3 * 3600000 } }
  assert.equal(Model.focusedTotal(day, {}), 3 * 3600000)
  // An override that reclassifies the app moves the line.
  assert.equal(Model.focusedTotal(day, { "site:youtube.com": false }), 4 * 3600000)
  assert.equal(Model.focusedTotal(null, {}), 0)
  // Never negative, even if a stale breakdown outweighs the stored total.
  assert.equal(Model.focusedTotal({ total: 1000, apps: { "site:youtube.com": 999999 } }, {}), 0)
})

test("slackSharePct keeps the fraction unrounded", () => {
  const day = { total: 3, apps: { "site:youtube.com": 1 } }
  assert.ok(Math.abs(Model.slackSharePct(day, {}) - 33.333) < 0.01)
  assert.equal(Model.slackSharePct({ total: 0, apps: {} }, {}), 0)
  assert.equal(Model.slackSharePct(null, {}), 0)
})

test("priorSlackShare averages only the days that hold data", () => {
  const days = {
    "2026-08-28": { total: 100, apps: { "site:youtube.com": 60 } },  // 60%
    "2026-08-26": { total: 100, apps: { "site:youtube.com": 20 } }   // 20%
  }
  const prior = Model.priorSlackShare(days, "2026-08-29", 7, {})
  assert.equal(prior.days, 2, "empty days must not drag the average to zero")
  assert.equal(prior.avg, 40)
  // No history at all is reported as such, not as a 0% average.
  assert.deepEqual(Model.priorSlackShare({}, "2026-08-29", 7, {}), { avg: 0, days: 0 })
})

test("fmtRateChange names the old rate instead of scoring the gap", () => {
  // No direction word: the row's arrow and colour already carry it, and the
  // pair was wide enough to collide with its own label.
  assert.equal(Model.fmtRateChange(59, 32), "59%, was 32%")
  assert.equal(Model.fmtRateChange(25, 50), "25%, was 50%")
  assert.equal(Model.fmtRateChange(40, 40), "40%, unchanged")
  // Rounds both sides before comparing, so 40.4 vs 39.6 is not "was 40%".
  assert.equal(Model.fmtRateChange(40.4, 39.6), "40%, unchanged")
  assert.equal(Model.fmtRateChange(NaN, NaN), "0%, unchanged")
})

test("cleanestDay finds the lightest slacking day, ignoring trivial ones", () => {
  const days = {
    "2026-08-28": { total: 4 * 3600000, apps: { "site:youtube.com": 3600000 } },   // 25%
    "2026-08-29": { total: 4 * 3600000, apps: { "site:youtube.com": 2 * 3600000 } } // 50%
  }
  const best = Model.cleanestDay(days, "2026-08-29", 7, {}, null)
  assert.equal(best.key, "2026-08-28")
  assert.equal(best.share, 25)

  // A two-minute day at 0% is not an achievement, so it must not win.
  const withStub = Object.assign({ "2026-08-27": { total: 120000, apps: { opencode: 120000 } } }, days)
  assert.equal(Model.cleanestDay(withStub, "2026-08-29", 7, {}, null).key, "2026-08-28")
  assert.equal(Model.cleanestDay({}, "2026-08-29", 7, {}, null), null)
})

test("progress rows read as improvements when slacking falls", () => {
  const days = {
    "2026-08-29": { total: 4 * 3600000, apps: { "site:youtube.com": 3 * 3600000 } }
  }
  const today = { total: 4 * 3600000, apps: { "site:youtube.com": 3600000, opencode: 3 * 3600000 } }
  const rows = Model.insights(today, days, "2026-08-30", "2026-08-30", {}, today)
  // Two fewer hours of slacking than yesterday, and a much lower rate.
  assert.equal(row(rows, "Slacking vs yesterday").value, "2h less")
  assert.equal(row(rows, "Slack rate vs week").value, "25%, was 75%")
  // Total was identical, so that row must not claim any movement.
  assert.equal(row(rows, "Total vs yesterday").value, "no change")
})

test("progress rows read as regressions when slacking climbs", () => {
  const days = {
    "2026-08-29": { total: 4 * 3600000, apps: { opencode: 4 * 3600000 } }
  }
  const today = { total: 4 * 3600000, apps: { "site:youtube.com": 2 * 3600000, opencode: 2 * 3600000 } }
  const rows = Model.insights(today, days, "2026-08-30", "2026-08-30", {}, today)
  assert.equal(row(rows, "Slacking vs yesterday").value, "2h more")
  assert.equal(row(rows, "Slack rate vs week").value, "50%, was 0%")
})

test("progress rows dash out rather than invent a baseline", () => {
  const today = { total: 3600000, apps: { "site:youtube.com": 3600000 } }
  const rows = Model.insights(today, {}, "2026-08-30", "2026-08-30", {}, today)
  assert.equal(row(rows, "Slacking vs yesterday").value, "—")
  assert.equal(row(rows, "Slack rate vs week").value, "—")
})

// ---- Go-outside nudges ---------------------------------------------------

test("reminderLevel counts whole intervals and never fires twice for one", () => {
  const h = 3600000
  assert.equal(Model.reminderLevel(0, 4), 0)
  assert.equal(Model.reminderLevel(3.99 * h, 4), 0)
  assert.equal(Model.reminderLevel(4 * h, 4), 1)
  assert.equal(Model.reminderLevel(7.9 * h, 4), 1, "still the first block")
  assert.equal(Model.reminderLevel(8 * h, 4), 2)
  assert.equal(Model.reminderLevel(20 * h, 4), 5)
})

test("reminderLevel treats a zero or negative interval as off", () => {
  assert.equal(Model.reminderLevel(99 * 3600000, 0), 0)
  assert.equal(Model.reminderLevel(99 * 3600000, -3), 0)
  assert.equal(Model.reminderLevel(99 * 3600000, undefined), 0)
})

test("reminderLevel tolerates junk totals", () => {
  assert.equal(Model.reminderLevel(-5000, 4), 0)
  assert.equal(Model.reminderLevel(NaN, 4), 0)
  assert.equal(Model.reminderLevel(Infinity, 4), 0)
  assert.equal(Model.reminderLevel(undefined, 4), 0)
})

// ---- Abbreviated dates and dismissable stats -----------------------------

test("formatDateShort keeps the weekday but abbreviates it", () => {
  // No ordinal suffix: the weekday has already pinned the date, and this is
  // the value column, where every character is competing with the label.
  assert.equal(Model.formatDateShort("2026-07-18"), "Sat, Jul 18")
  assert.equal(Model.formatDateShort("2026-08-01"), "Sat, Aug 1")
  assert.equal(Model.formatDateShort(""), "")
  assert.equal(Model.formatDateShort("nonsense"), "")
  // Shorter than the long form, same information.
  assert.ok(Model.formatDateShort("2026-07-18").length
    < Model.formatDateLong("2026-07-18").length)
})

test("every insight row has a stable id", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  const ids = rows.map(r => r.id)
  for (const id of ids) assert.ok(id, "a row is missing its id")
  assert.equal(new Set(ids).size, ids.length, "ids must be unique")
  // Ids are identity, not wording: viewing a past day relabels rows but
  // must not renumber them.
  const past = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-28")
  assert.deepEqual(past.map(r => r.id), ids)
  assert.notDeepEqual(past.map(r => r.label), rows.map(r => r.label))
})

test("visibleInsights and hiddenInsights partition the rows", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  const hidden = ["streak", "peak"]
  const shown = Model.visibleInsights(rows, hidden)
  const gone = Model.hiddenInsights(rows, hidden)
  assert.equal(shown.length + gone.length, rows.length)
  assert.deepEqual(gone.map(r => r.id), ["peak", "streak"], "original order kept")
  assert.ok(!shown.some(r => hidden.includes(r.id)))
  // No hidden list means nothing is filtered.
  assert.equal(Model.visibleInsights(rows, []).length, rows.length)
  assert.equal(Model.visibleInsights(rows, null).length, rows.length)
  assert.equal(Model.hiddenInsights(rows, null).length, 0)
})

test("toggleHiddenStat adds, removes, and returns a new array", () => {
  const before = []
  const one = Model.toggleHiddenStat(before, "streak")
  assert.deepEqual(one, ["streak"])
  assert.deepEqual(before, [], "input must not be mutated")
  const two = Model.toggleHiddenStat(one, "peak")
  assert.deepEqual(two, ["streak", "peak"])
  assert.deepEqual(Model.toggleHiddenStat(two, "streak"), ["peak"])
  // Junk in the stored list is dropped rather than propagated.
  assert.deepEqual(Model.toggleHiddenStat(["streak", null, "streak", 7], "peak"),
                   ["streak", "peak"])
  assert.deepEqual(Model.toggleHiddenStat(["a"], ""), ["a"])
})

test("hiding every stat leaves an empty but valid list", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  const all = rows.map(r => r.id)
  assert.deepEqual(Model.visibleInsights(rows, all), [])
  assert.equal(Model.hiddenInsights(rows, all).length, rows.length)
})

// ---- Monthly aggregates keep their slacking ------------------------------

test("month entries read in both the legacy and current shapes", () => {
  // Old files stored a bare number of milliseconds.
  assert.equal(Model.monthTotal(5000), 5000)
  assert.equal(Model.monthSlack(5000), 0)
  assert.equal(Model.monthSlackKnown(5000), false, "a bare number knows nothing about slacking")
  // New files store the pair.
  assert.equal(Model.monthTotal({ total: 5000, slack: 2000 }), 5000)
  assert.equal(Model.monthSlack({ total: 5000, slack: 2000 }), 2000)
  assert.equal(Model.monthSlackKnown({ total: 5000, slack: 2000 }), true)
  // Junk of every shape reads as empty rather than throwing.
  for (const junk of [null, undefined, {}, -5, NaN, "nonsense", []]) {
    assert.equal(Model.monthTotal(junk), 0, String(junk))
    assert.equal(Model.monthSlack(junk), 0, String(junk))
  }
  // Slack can never exceed the total it sits inside.
  assert.equal(Model.monthSlack({ total: 100, slack: 999 }), 100)
})

test("rollupPrunedDays carries slacking into the month", () => {
  const pruned = {
    "2026-01-05": { total: 4 * 3600000, apps: { "site:youtube.com": 3600000, opencode: 3 * 3600000 } },
    "2026-01-06": { total: 2 * 3600000, apps: { opencode: 2 * 3600000 } }
  }
  const out = Model.rollupPrunedDays({}, pruned, {})
  assert.equal(Model.monthTotal(out["2026-01"]), 6 * 3600000)
  assert.equal(Model.monthSlack(out["2026-01"]), 3600000)
  assert.equal(Model.monthSlackKnown(out["2026-01"]), true)
})

test("rollupPrunedDays honours slacking overrides at roll-up time", () => {
  const pruned = { "2026-01-05": { total: 3600000, apps: { "site:youtube.com": 3600000 } } }
  const out = Model.rollupPrunedDays({}, pruned, { "site:youtube.com": false })
  assert.equal(Model.monthSlack(out["2026-01"]), 0)
})

test("trailingMonths accepts mixed legacy and current month shapes", () => {
  const months = { "2026-05": 9000000, "2026-06": { total: 36000000, slack: 18000000 } }
  const bars = Model.trailingMonths({}, months, "2026-08-30", 4, 0, {}, null)
  const may = bars.find(b => b.key === "2026-05")
  const june = bars.find(b => b.key === "2026-06")
  assert.equal(may.ms, 9000000)
  assert.equal(may.slackMs, 0)
  assert.equal(may.slackKnown, false, "a legacy month must not read as slack-free")
  assert.equal(june.ms, 36000000)
  assert.equal(june.slackMs, 18000000)
  assert.equal(june.slackKnown, true)
})

// ---- Budget and recap ----------------------------------------------------

test("budgetState reports remaining, then overage", () => {
  const under = Model.budgetState(90 * 60000, 120 * 60000)
  assert.equal(under.active, true)
  assert.equal(under.over, false)
  assert.equal(under.remainingMs, 30 * 60000)
  assert.equal(Model.budgetLabel(under), "30m of slack left")

  const over = Model.budgetState(180 * 60000, 120 * 60000)
  assert.equal(over.over, true)
  assert.equal(over.overMs, 60 * 60000)
  assert.equal(Model.budgetLabel(over), "1h over budget")
  // The ratio drives a progress bar, so it must never exceed its track.
  assert.equal(over.ratio, 1)
})

test("a budget of zero is no budget, not a budget of zero", () => {
  const none = Model.budgetState(99999, 0)
  assert.equal(none.active, false)
  assert.equal(none.over, false, "no budget can never be exceeded")
  assert.equal(Model.budgetLabel(none), "")
  assert.equal(Model.budgetLabel(null), "")
})

test("budgetState tolerates junk", () => {
  for (const junk of [NaN, undefined, null, -5, Infinity]) {
    const st = Model.budgetState(junk, 60000)
    assert.ok(isFinite(st.ratio) && st.ratio >= 0 && st.ratio <= 1, String(junk))
  }
})

test("isRecapDay is Friday and nothing else", () => {
  assert.equal(Model.isRecapDay("2026-08-28"), true)   // Friday
  for (const notFriday of ["2026-08-27", "2026-08-29", "2026-08-30", "2026-08-31"])
    assert.equal(Model.isRecapDay(notFriday), false, notFriday)
  assert.equal(Model.isRecapDay(""), false)
  assert.equal(Model.isRecapDay("nonsense"), false)
})

test("weeklyRecap compares the last 7 days with the 7 before", () => {
  const days = {}
  for (let i = 1; i <= 14; i++) {
    const d = String(i).padStart(2, "0")
    days["2026-08-" + d] = {
      total: 4 * 3600000,
      // The older week slacked twice as much as the recent one.
      apps: { "site:youtube.com": (i <= 7 ? 2 : 1) * 3600000, opencode: 2 * 3600000 }
    }
  }
  const recap = Model.weeklyRecap(days, "2026-08-14", {}, null, 0)
  assert.equal(recap.title, "Your week: 28h")
  assert.equal(recap.sharePct, 25)
  assert.ok(recap.body.includes("down from 50% the week before"), recap.body)
})

test("weeklyRecap stays silent with nothing to report", () => {
  assert.equal(Model.weeklyRecap({}, "2026-08-14", {}, null, 0), null)
  assert.equal(Model.weeklyRecap({}, "", {}, null, 0), null)
})

test("weeklyRecap omits the comparison when there is no prior week", () => {
  const days = { "2026-08-14": { total: 3600000, apps: { opencode: 3600000 } } }
  const recap = Model.weeklyRecap(days, "2026-08-14", {}, null, 0)
  assert.ok(recap.body.includes("0% of it slacking"))
  assert.ok(!recap.body.includes("week before"), recap.body)
})

test("appTrend follows one app across the trailing days", () => {
  const days = {
    "2026-08-28": { total: 100, apps: { youtube: 60, opencode: 40 } },
    "2026-08-29": { total: 100, apps: { opencode: 100 } }
  }
  const live = { total: 50, apps: { youtube: 50 } }
  const bars = Model.appTrend(days, "2026-08-30", "youtube", 3, live)
  assert.deepEqual(bars.map(b => b.ms), [60, 0, 50], "a day without the app is a zero, not a gap")
  assert.deepEqual(bars.map(b => b.label), ["Fri", "Sat", "Sun"])
  assert.equal(bars[2].isToday, true)
})

test("appTrend returns nothing for junk input", () => {
  assert.deepEqual(Model.appTrend({}, "2026-08-30", "", 3, null), [])
  assert.deepEqual(Model.appTrend({}, "", "youtube", 3, null), [])
  assert.deepEqual(Model.appTrend({}, "2026-08-30", "youtube", 0, null), [])
  // A corrupt entry reads as zero rather than poisoning the chart.
  const bad = { "2026-08-30": { total: 5, apps: { youtube: "lots" } } }
  assert.equal(Model.appTrend(bad, "2026-08-30", "youtube", 1, null)[0].ms, 0)
})

// ---- Stat sections -------------------------------------------------------

test("insight rows come out grouped, in section order", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  const groups = rows.map(r => r.group)
  for (const g of groups) assert.ok(g, "a row is missing its group")
  // Each section must be contiguous -- the panel draws a header wherever
  // the group changes, so a group appearing twice would draw twice.
  const order = groups.filter((g, i) => g !== groups[i - 1])
  assert.deepEqual(order, ["Today", "Progress", "Patterns"])
  assert.equal(new Set(order).size, order.length, "a section was split in two")
})

test("startsGroup marks exactly the first row of each section", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  const flags = rows.map((r, i) => Model.startsGroup(rows, i))
  assert.equal(flags.filter(Boolean).length, 3, "one header per section")
  assert.equal(flags[0], true)
  for (let i = 1; i < rows.length; i++)
    assert.equal(flags[i], rows[i].group !== rows[i - 1].group, rows[i].label)
})

test("startsGroup follows the filtered list, not the original", () => {
  const rows = Model.insights({ total: 3600000, apps: { a: 3600000 } },
                              {}, "2026-08-30", "2026-08-30")
  // Hide all of Today: Progress must then own the first header.
  const hidden = rows.filter(r => r.group === "Today").map(r => r.id)
  const shown = Model.visibleInsights(rows, hidden)
  assert.equal(shown[0].group, "Progress")
  assert.equal(Model.startsGroup(shown, 0), true)
  const headers = shown.filter((r, i) => Model.startsGroup(shown, i)).map(r => r.group)
  assert.deepEqual(headers, ["Progress", "Patterns"],
    "a section with nothing left must not keep its heading")
})

test("startsGroup tolerates junk indices", () => {
  assert.equal(Model.startsGroup([], 0), false)
  assert.equal(Model.startsGroup(null, 0), false)
  assert.equal(Model.startsGroup([{ group: "a" }], -1), false)
  assert.equal(Model.startsGroup([{ group: "a" }], 5), false)
})

