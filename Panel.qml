import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model
import "lib/Messages.js" as Messages

// Popup for the Omachron bar widget: today's total, the per-app
// breakdown, and a short behaviour-insights section. Read-only — the panel
// is a mirror of the Service's live state.
Panel {
  id: root
  moduleName: "dutchster.omachron"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The bar tracks the widget mounted in its slot — BarWidget.qml — so the
  // popout coordinator and panel switching must identify us by that widget.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("dutchster.omachron") : null
  readonly property bool serviceReady: service && service.ready === true
  readonly property var today: service ? service.today : null
  readonly property var days: service ? service.days : {}
  readonly property var months: service ? service.months : {}
  readonly property string todayKey: serviceReady ? service.todayKey : ""
  // Fetched site favicons (domain -> true), replaced by the service as
  // fetches land so legend rows pick icons up live.
  readonly property var siteIcons: service && service.siteIcons ? service.siteIcons : ({})
  readonly property string iconsDir: service ? service.iconsDir : ""

  // Slacking off: the service owns the membership overrides (persisted in
  // history.json) and this panel is where they are edited — clicking a
  // usage row flips that entry in or out of the list.
  readonly property var slack: service && service.slack ? service.slack : ({})
  readonly property double slackMs: serviceReady ? Model.slackTotal(root.activeDay, root.slack) : 0
  readonly property int slackShare: serviceReady ? Model.slackShare(root.activeDay, root.slack) : 0
  // Which phrasing of the verdict is showing. Advanced on a slow timer while
  // the panel is open, and once more on every open, so the line varies
  // without ever reshuffling under the reader mid-glance.
  property int verdictVariant: 0

  readonly property string slackVerdict: serviceReady
    ? Messages.slackVerdict(root.slackMs, root.dayTotal,
                         root.activeDayKey === root.todayKey, root.verdictVariant)
    : ""

  function isSlackApp(app) { return Model.isSlackApp(app, root.slack) }

  // Which usage row is expanded to show its own history; "" for none.
  property string expandedApp: ""

  function toggleExpandedApp(app) {
    root.expandedApp = (root.expandedApp === app) ? "" : app
  }

  readonly property var expandedTrend: root.expandedApp && serviceReady
    ? Model.appTrend(root.days, root.todayKey, root.expandedApp, 7, root.today)
    : []

  function toggleSlack(app) {
    if (root.service && typeof root.service.toggleSlack === "function")
      root.service.toggleSlack(app)
  }

  // Relative luminance, for deciding whether two theme colours are actually
  // distinguishable.
  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  // The colour slacking is drawn in. Normally the theme's urgent, but some
  // themes set urgent to something within a hair of the bar's own grey --
  // one shipped theme resolves it to a dark teal, which made the stacked
  // bars unreadable. When the gap is too small to see, the hue is pushed
  // toward red and lifted away from the bar until it separates. Still
  // derived from the theme, never a hardcoded colour.
  readonly property color barBase: Qt.rgba(root.contentForeground.r,
                                           root.contentForeground.g,
                                           root.contentForeground.b, 0.28)
  readonly property color slackColour: {
    var urgent = Color.urgent
    // Composite the bar's alpha against the panel background so the
    // comparison is between what is actually painted, not two abstractions.
    var bg = bar ? bar.background : Color.background
    var barPainted = Qt.rgba(bg.r + (root.contentForeground.r - bg.r) * 0.28,
                             bg.g + (root.contentForeground.g - bg.g) * 0.28,
                             bg.b + (root.contentForeground.b - bg.b) * 0.28, 1)
    var gap = Math.abs(root.luminance(urgent) - root.luminance(barPainted))
    var hueGap = Math.abs(urgent.hslHue - barPainted.hslHue)
    if (gap > 0.18 || (gap > 0.08 && hueGap > 0.08)) return urgent
    // Too close to read: keep the theme's hue family but force it warm and
    // bright enough to register as a separate band.
    var lifted = Qt.hsla(urgent.hslHue > 0.5 ? 0.02 : urgent.hslHue,
                         Math.max(0.55, urgent.hslSaturation),
                         Math.max(0.55, root.luminance(barPainted) + 0.3),
                         1)
    return lifted
  }

  // Mixes the theme's urgent colour into base by t (0-1): the one place
  // the slacking heat turns into a colour.
  function heatColor(base, t) {
    var hot = root.slackColour
    var k = Math.max(0, Math.min(1, t))
    return Qt.rgba(base.r + (hot.r - base.r) * k,
                   base.g + (hot.g - base.g) * k,
                   base.b + (hot.b - base.b) * k,
                   base.a)
  }

  // Row tint: a slacking entry reddens as its time racks up, everything
  // else keeps the plain foreground.
  function slackColor(app, ms, base) {
    if (!root.isSlackApp(app)) return base
    return root.heatColor(base, Model.slackHeat(ms, root.dayTotal))
  }

  // Theme icons for program rows, resolved through the same chain the
  // shell's launcher uses: desktop entry (exact id, then Quickshell's
  // heuristic appId match) to icon theme path. "" means no icon and the
  // row's icon slot stays empty. Cached per tracking key by plain
  // mutation — nothing binds to the cache object itself, and icons don't
  // change within a session.
  property var programIconCache: ({})

  // Generic fallbacks so every real row leads with an icon: the standard
  // executable icon for programs (the shell launcher's own fallback), a
  // web icon for sites whose favicon hasn't been fetched yet or failed.
  readonly property string genericAppIcon: Quickshell.iconPath("application-x-executable", true)
  readonly property string siteFallbackIcon: {
    var p = Quickshell.iconPath("applications-internet", true)
    return p !== "" ? p : root.genericAppIcon
  }

  function programIconSource(app) {
    var key = String(app || "")
    var cached = root.programIconCache[key]
    if (cached !== undefined) return cached
    var path = ""
    var queries = Model.appIconQueries(key)
    for (var i = 0; i < queries.length && !path; i++) {
      var entry = DesktopEntries.byId(queries[i])
      if (!entry) entry = DesktopEntries.heuristicLookup(queries[i])
      if (entry && entry.icon) path = Quickshell.iconPath(entry.icon, true)
    }
    // Last resorts: the key itself may be a theme icon name (mpv, steam),
    // else the generic application icon. Only the grouped "Other" pseudo
    // row (no queries) stays icon-less.
    if (!path && queries.length > 0)
      path = Quickshell.iconPath(queries[0].toLowerCase(), true)
    if (!path && queries.length > 0)
      path = root.genericAppIcon
    root.programIconCache[key] = path
    return path
  }

  // Day selection: clicking a week-trend bar sets selectedKey; empty = live
  // today.  All derived data flows from activeDay / activeDayKey so the
  // hero, list, and insights automatically reflect the selection.
  property string selectedKey: ""
  readonly property var activeDay: serviceReady ? Model.dayFor(root.days, root.today, root.selectedKey, root.todayKey) : null
  readonly property string activeDayKey: root.selectedKey || root.todayKey
  readonly property string activeDayLabel: serviceReady ? Model.formatDate(root.activeDayKey) : ""
  readonly property double dayTotal: root.activeDay ? (root.activeDay.total || 0) : 0

  // All derived data is gated on service.ready: before the service has
  // loaded its history, todayKey is "" and the Model helpers would produce
  // garbage labels ("NaN-NaN-NaN") instead of an empty chart.
  // "Hide < N minutes" filter: entries under the threshold vanish from
  // the usage list. Persisted in the widget's shell.json entry
  // (hideUnderMinutes) through the host widget, like icon-only mode.
  readonly property var hideCycle: [0, 1, 5, 10, 15, 30]
  readonly property var hostSettings: hostWidget ? hostWidget.settings : null
  readonly property int hideUnderMinutes: {
    var v = root.hostSettings && root.hostSettings.hideUnderMinutes !== undefined
      ? Number(root.hostSettings.hideUnderMinutes) : 1
    return isNaN(v) || v < 0 ? 1 : v
  }
  readonly property double hideUnderMs: root.hideUnderMinutes * 60000

  // Go-outside nudge interval, in hours; 0 is off. Stored in the widget's
  // shell.json entry, same as the other preferences.
  readonly property var reminderCycle: [0, 2, 3, 4, 6, 8]
  readonly property int reminderHours: {
    var v = root.hostSettings && root.hostSettings.reminderHours !== undefined
      ? Number(root.hostSettings.reminderHours) : 4
    return isNaN(v) || v < 0 ? 4 : v
  }

  function cycleReminder() {
    var i = root.reminderCycle.indexOf(root.reminderHours)
    var next = root.reminderCycle[(i + 1) % root.reminderCycle.length]
    if (root.hostWidget && typeof root.hostWidget.setReminderHours === "function")
      root.hostWidget.setReminderHours(next)
  }

  // Dismissed stats. The list lives in the widget's settings; the panel
  // filters against it and the settings drawer offers them back.
  readonly property var hiddenStats: {
    var v = root.hostSettings && root.hostSettings.hiddenStats
    return Array.isArray(v) ? v : []
  }

  function toggleStat(id) {
    if (root.hostWidget && typeof root.hostWidget.setHiddenStats === "function")
      root.hostWidget.setHiddenStats(Model.toggleHiddenStat(root.hiddenStats, id))
  }

  function resetSettings() {
    if (root.hostWidget && typeof root.hostWidget.resetSettings === "function")
      root.hostWidget.resetSettings()
  }

  // ---- Slacking budget ---------------------------------------------------
  readonly property var budgetCycle: [0, 30, 60, 90, 120, 180, 240]
  readonly property int slackBudgetMinutes: {
    var v = root.hostSettings && root.hostSettings.slackBudgetMinutes !== undefined
      ? Number(root.hostSettings.slackBudgetMinutes) : 0
    return isNaN(v) || v < 0 ? 0 : v
  }
  readonly property var budget: Model.budgetState(root.slackMs, root.slackBudgetMinutes * 60000)

  function cycleBudget() {
    var i = root.budgetCycle.indexOf(root.slackBudgetMinutes)
    var next = root.budgetCycle[(i + 1) % root.budgetCycle.length]
    if (root.hostWidget && typeof root.hostWidget.setSlackBudget === "function")
      root.hostWidget.setSlackBudget(next)
  }

  property bool settingsOpen: false

  function openSettings(open) {
    settingsDrawer.sliding = true
    root.settingsOpen = open
    // The two drawers share the card, so opening one closes the other.
  }

  function cycleHideUnder() {
    var i = root.hideCycle.indexOf(root.hideUnderMinutes)
    var next = root.hideCycle[(i + 1) % root.hideCycle.length]
    if (root.hostWidget && typeof root.hostWidget.setHideUnderMinutes === "function")
      root.hostWidget.setHideUnderMinutes(next)
  }

  readonly property var fullApps: serviceReady ? Model.appList(root.activeDay, root.hideUnderMs) : []
  readonly property var allInsightRows: serviceReady
    ? Model.insights(root.activeDay, root.days, root.todayKey, root.activeDayKey,
                     root.slack, root.today)
    : []
  readonly property var insightRows: Model.visibleInsights(root.allInsightRows, root.hiddenStats)
  readonly property var dismissedRows: Model.hiddenInsights(root.allInsightRows, root.hiddenStats)
  // ---- Trend ranges ------------------------------------------------------
  // Three fixed windows instead of pagination: nobody wonders what their
  // usage was in the second week of last January, so there is nothing to
  // page through. Week and month are daily bars; year is one bar per month,
  // which reaches past the ~3 month retention window via the rollups.
  property string trendRange: "week"
  readonly property bool trendIsDaily: root.trendRange !== "year"
  // The heading is the control: clicking the highlighted period advances it.
  readonly property var trendRanges: ["week", "month", "year"]

  function cycleTrendRange() {
    var i = root.trendRanges.indexOf(root.trendRange)
    root.trendRange = root.trendRanges[(i + 1) % root.trendRanges.length]
  }
  // Today's running total, so the newest bar tracks the live clock rather
  // than the last committed write.
  readonly property double liveTodayMs: root.today ? (root.today.total || 0) : 0

  readonly property var trendBars: {
    if (!root.serviceReady) return []
    if (root.trendRange === "year")
      return Model.trailingMonths(root.days, root.months, root.todayKey, 12,
                                  root.liveTodayMs, root.slack, root.today)
    return Model.trailingDays(root.days, root.todayKey,
                              root.trendRange === "month" ? 30 : 7,
                              root.liveTodayMs, root.slack, root.today)
  }
  readonly property double trendMaxMs: Model.trendMax(root.trendBars)
  readonly property double trendTotalMs: Model.trendTotal(root.trendBars)
  readonly property double trendPossibleMs: Model.trendPossibleMs(root.trendBars, root.trendIsDaily)

  // Labels crowd into each other once bars get thin, so the 30-day range
  // labels every 5th bar and the rest label every one.
  readonly property int trendLabelEvery: root.trendRange === "month" ? 5 : 1

  // Header total toggles between absolute time and share of the range.
  property bool weekTotalAsPct: false


  // Shared panel-styled tooltip: matches the drawer's background, foreground
  // and font so popups read as part of the shell rather than platform chrome.
  component PanelToolTip: ToolTip {
    id: panelTip
    property string tipText: ""
    delay: 300
    padding: 0
    background: Rectangle {
      color: bar ? bar.background : Color.background
      border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.25)
      border.width: 1
      radius: Style.space(3)
    }
    contentItem: Text {
      textFormat: Text.PlainText
      text: panelTip.tipText
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: root.fontCaption
      leftPadding: Style.space(8)
      rightPadding: Style.space(8)
      topPadding: Style.space(4)
      bottomPadding: Style.space(4)
    }
  }

  // The usage list is the centrepiece, so it takes the full panel width and
  // a tall scroll cap. The height is fixed so the panel does not resize as
  // days with more or fewer entries are selected.
  readonly property real listMaxHeight: Style.space(224)

  // Nerd Font's Font Awesome glyphs do not share an ink height. Measured
  // against the shipped font they band from 0.58em (xmark) up to 0.92em
  // (star, fire, clock, calendar, bolt); drawn at one pixelSize a star
  // towers over a check. Every glyph is therefore scaled to one painted
  // height, so "same size" means same ink rather than same font size. The
  // bands share an ink centre to within half a pixel at these sizes, so
  // normalising height costs no vertical alignment.
  readonly property real iconInkTarget: 0.809
  readonly property var iconInk: ({
    "\uf00d": 0.577,  // xmark      dismiss a stat
    "\uf013": 0.923,  // gear       settings
    "\uf005": 0.923,  // star       top app
    "\uf017": 0.923,  // clock      busiest day
    "\uf053": 0.809,  // chevron    back out of settings
    "\uf061": 0.692,  // arrow right   delta, unchanged
    "\uf062": 0.809,  // arrow up      delta, more
    "\uf063": 0.807,  // arrow down    delta, less
    "\uf06c": 0.809,  // leaf       cleanest day
    "\uf06d": 0.923,  // fire       peak slack day
    "\uf06e": 0.808,  // eye        restore a hidden stat
    "\uf071": 0.808,  // warning    slacking
    "\uf073": 0.923,  // calendar   busiest weekend
    "\uf080": 0.808,  // bar chart  daily average
    "\uf0e2": 0.809,  // undo       reset to defaults
    "\uf0e7": 0.923,  // bolt       streak
    "\uf140": 0.923,  // bullseye   focused
    "\uf2f2": 0.923   // stopwatch  logo
  })

  // Pixel size that fits `glyph` in the same square a 0.809em glyph fills
  // at `basePx`. Matching ink *height* alone is not enough: leaf is 0.81em
  // tall but 0.92em wide, so it stayed at full size while the rounder
  // glyphs shrank, and ended up both the widest icon in the list and the
  // one sitting closest to its label. Scaling by the larger of the two
  // dimensions keeps every icon inside one box. An unlisted glyph passes
  // through unscaled.
  function iconPx(glyph, basePx) {
    var box = Math.max(root.iconInk[glyph] || 0, root.iconInkW[glyph] || 0)
    if (!(box > 0)) return basePx
    return Math.max(1, Math.round(basePx * root.iconInkTarget / box))
  }

  // Ink width in em, measured the same way as iconInk. Widths vary as much
  // as heights did -- warning paints 0.92em wide where bolt paints 0.69em --
  // so iconPx sizes against whichever dimension is larger, and iconGap
  // measures the label's gap from this width rather than the slot edge.
  readonly property var iconInkW: ({
    "\uf00d": 0.577,  // xmark
    "\uf013": 0.871,  // gear
    "\uf005": 0.953,  // star
    "\uf017": 0.923,  // clock
    "\uf053": 0.462,  // chevron
    "\uf061": 0.808,  // arrow right
    "\uf062": 0.692,  // arrow up
    "\uf063": 0.692,  // arrow down
    "\uf06c": 0.923,  // leaf
    "\uf06d": 0.808,  // fire
    "\uf06e": 1.039,  // eye
    "\uf071": 0.924,  // warning
    "\uf073": 0.808,  // calendar
    "\uf080": 0.923,  // bar chart
    "\uf0e2": 0.837,  // undo
    "\uf0e7": 0.692,  // bolt
    "\uf140": 0.923,  // bullseye
    "\uf2f2": 0.750   // stopwatch
  })

  // Left margin for the label that follows an icon, so the gap measured
  // from painted ink is `gapPx` for every glyph. The glyph is centred in a
  // fixed slot, so a wide one finishes close to the slot edge and a narrow
  // one leaves slack; without this the same margin buys a very different
  // gap per row. Falls back to the plain margin for an unlisted glyph.
  function iconGap(glyph, basePx, slotPx, gapPx) {
    var w = root.iconInkW[glyph]
    if (!w) return gapPx
    var slack = (slotPx - w * root.iconPx(glyph, basePx)) / 2
    return Math.max(1, Math.round(gapPx - slack))
  }

  // Per-row glyph and colour for the patterns section. Both key off the
  // row's `kind` rather than its label text: a row where "less" is a win
  // (slacking going down) has to be distinguishable from one where less is
  // merely less (total time), and label prefixes cannot carry that.
  function insightIcon(kind, value) {
    if (kind === "focus") return "\uf140"    // bullseye: on target
    if (kind === "slack") return "\uf071"    // warning: the mark the app rows use
    if (kind === "delta" || kind === "slackDelta" || kind === "shareDelta")
      return root.deltaArrow(value)
    if (kind === "top") return "\uf005"      // star
    if (kind === "clean") return "\uf06c"    // leaf
    if (kind === "peak") return "\uf06d"     // fire
    if (kind === "avg") return "\uf080"      // bar chart
    if (kind === "streak") return "\uf0e7"   // bolt
    if (kind === "weekend") return "\uf073"  // calendar
    if (kind === "busy") return "\uf017"     // clock
    return ""
  }

  // A rate row reads "33%, was 38%" -- both numbers and no direction word,
  // because the arrow beside it is already saying which way it went. Compare
  // the pair to recover the direction: -1 improved, 1 regressed, 0 flat or
  // not a rate row.
  function rateDirection(value) {
    var m = /^(\d+)%, was (\d+)%$/.exec(String(value))
    if (!m) return 0
    var now = Number(m[1])
    var was = Number(m[2])
    return now === was ? 0 : (now > was ? 1 : -1)
  }

  // True when a delta row represents progress: less slacking, a lower slack
  // rate. Deliberately not applied to total time -- more or less screen time
  // is not on its own an improvement, and pretending otherwise would be
  // scoring the user against a goal they never set.
  function isImprovement(value) {
    var v = String(value)
    return v.indexOf(" less") >= 0 || root.rateDirection(v) < 0
  }

  function isRegression(value) {
    var v = String(value)
    return v.indexOf(" more") >= 0 || root.rateDirection(v) > 0
  }

  function insightIconColor(kind, value) {
    if (kind === "slack")
      return root.slackMs > 0
        ? root.heatColor(root.contentForeground, Model.slackHeat(root.slackMs, root.dayTotal))
        : root.contentForeground
    if (kind === "peak") return root.heatColor(root.contentForeground, 0.7)
    if (kind === "focus" || kind === "clean") return Color.accent
    if (kind === "slackDelta" || kind === "shareDelta") {
      if (root.isImprovement(value)) return Color.accent
      if (root.isRegression(value)) return root.slackColour
      return root.contentForeground
    }
    // Total-time deltas stay neutral; a drop is dimmed, not celebrated.
    if (kind === "delta")
      return root.isImprovement(value)
        ? Qt.darker(root.contentForeground, 1.5)
        : root.contentForeground
    return root.contentForeground
  }

  // Progress is worth saying twice: the number itself carries the verdict,
  // not just the glyph beside it.
  function insightValueColor(kind, value) {
    if (kind === "slackDelta" || kind === "shareDelta") {
      if (root.isImprovement(value)) return Color.accent
      if (root.isRegression(value)) return root.slackColour
    }
    return root.contentForeground
  }

  // Only the slacking row pulses, and only when there is slacking to warn
  // about. Pulsing the per-app row markers too was unbearable: a dozen rows
  // blinking out of phase.
  function insightFlashes(kind) {
    return kind === "slack" && root.slackMs > 0
  }

  // fmtDelta words its result ("1h 16m more") and fmtRateChange names both
  // rates ("33%, was 38%"), so the arrow reads the value, not a sign.
  function deltaArrow(value) {
    var v = String(value)
    if (root.isRegression(v)) return "\uf062"
    if (root.isImprovement(v)) return "\uf063"
    return "\uf061"
  }

  // The single most motivating number, lifted out of the patterns list so it
  // is readable without scrolling: is the slacking going down or not. The
  // list below still carries it, alongside the slack-rate comparison.
  readonly property var slackProgress: {
    var rows = root.insightRows
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "slackDelta") return rows[i]
    return null
  }
  readonly property bool hasSlackProgress:
    root.slackProgress !== null && String(root.slackProgress.value).indexOf("\u2014") < 0

  // StyledText needs "#rrggbb"; a Qt color stringifies to #aarrggbb, which
  // the rich-text parser silently drops.

  // Guarded so the widget renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Slightly larger type than the shell defaults so rows and stats stay
  // legible on low-DPI screens; every pixelSize in this panel goes
  // through these.
  readonly property real uiScale: 1.15
  readonly property int fontTitle: Math.round(Style.font.title * uiScale)
  // The two headline numbers. Display size because they are the reason the
  // panel gets opened; everything else in the hero supports them.
  readonly property int fontHero: Math.round(Style.font.display * uiScale)
  readonly property int fontBody: Math.round(Style.font.bodySmall * uiScale)
  readonly property int fontCaption: Math.round(Style.font.caption * uiScale)

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Click-scrolling for the usage list. A page is most of the visible
  // height, less one row, so the row you were reading stays on screen.
  function scrollUsage(dir) {
    var max = Math.max(0, usageScroll.contentHeight - usageScroll.height)
    if (max <= 0) return
    var step = Math.max(Style.space(40), usageScroll.height - Style.space(28))
    var to = Math.max(0, Math.min(max, usageScroll.contentY + dir * step))
    usageScrollAnim.stop()
    usageScrollAnim.from = usageScroll.contentY
    usageScrollAnim.to = to
    usageScrollAnim.start()
  }

  function scrollBy(dy) {
    var flick = panelScroll
    if (!flick || flick.contentHeight <= flick.height) return
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy))
  }

  // Walks the visible trend bars. Only meaningful on the daily ranges; the
  // year view has no single day to land on.
  function stepSelectedDay(dx) {
    if (!root.trendIsDaily) return
    var bars = root.trendBars
    if (!bars.length) return
    var current = root.activeDayKey
    var at = -1
    for (var i = 0; i < bars.length; i++) if (bars[i].key === current) at = i
    if (at < 0) at = bars.length - 1
    var next = Math.max(0, Math.min(bars.length - 1, at + (dx > 0 ? 1 : -1)))
    if (bars[next].ms > 0) root.selectDay(bars[next].key)
  }

  function selectDay(key) {
    if (!key) return
    if (key === root.todayKey || root.selectedKey === key)
      root.selectedKey = ""
    else
      root.selectedKey = key
  }


  // Inset from the screen edge and from the bar, matching where Hyprland
  // actually puts a tiled window's corner. Hyprland insets a tiled window
  // by gaps_out *plus* border_size -- with gaps_out 10 and a 2px border a
  // window's right edge lands 12px in, not 10 -- so the border has to be
  // added back or the panel sits proud of every window beside it.
  // Style.gapsOut is general:gaps_out already halved (the shell's own
  // panel convention), so it is doubled back first. Every term is read
  // live from the theme; nothing here is pinned to a number.
  readonly property int hyprBorderSize:
    root.service && root.service.hyprBorderSize !== undefined
      ? Number(root.service.hyprBorderSize) : 2
  readonly property int screenGap: Style.gapsOut * 2 + root.hyprBorderSize

  // gaps_out and border_size can both change while the shell runs, so
  // re-read on open rather than trusting the value read at startup.
  onOpenedChanged: {
    if (root.opened && root.service
        && typeof root.service.refreshBorderSize === "function")
      root.service.refreshBorderSize()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    margin: root.screenGap
    // Left at the component default this was Style.gapsOut -- half a gap --
    // so the panel floated above the line every window's bottom edge sits on.
    gap: root.screenGap
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(384))
    // No cap of our own. fittedContentHeight already clamps to the space
    // the screen actually has once the bar and gaps are taken out, so on a
    // large display the whole panel fits and never scrolls -- and on a
    // small one it fills what is there and the outer Flickable takes over.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true

      // Drawer travel, relative to the card content area (this item) and
      // NOT panel.width -- the KeyboardPanel is the full-screen overlay
      // window, so its width is the display's, not the card's.
      readonly property real drawerWidth: width
      // Left/right walks the trend bars, so a day can be selected without
      // the mouse; up/down still scrolls the card.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.scrollBy(-dy * Style.space(24))
        if (dx !== 0) root.stepSelectedDay(dx)
      }

      // The README has claimed "keyboard-first" since before half of these
      // controls existed. These are the ones that were mouse-only.
      Keys.onPressed: function(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
          return
        switch (event.key) {
        case Qt.Key_R:
          root.cycleTrendRange(); event.accepted = true; break
        case Qt.Key_S:
          root.openSettings(!root.settingsOpen); event.accepted = true; break
        case Qt.Key_T:
          root.selectDay(root.todayKey); event.accepted = true; break
        case Qt.Key_B:
          root.cycleBudget(); event.accepted = true; break
        }
      }
      // Esc backs out of a drawer first; only a second press dismisses
      // the whole panel.
      onCloseRequested: {
        if (root.settingsOpen) root.openSettings(false)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---- Settings side drawer (full-card overlay) -----------------------
      // Everything adjustable lives here rather than scattered across the
      // panel: the small-entry filter, the go-outside nudges, the stats you
      // have dismissed, and the way back to defaults.
      Item {
        id: settingsDrawer
        width: keyCatcher.drawerWidth
        height: keyCatcher.height
        anchors.top: parent.top
        x: root.settingsOpen ? 0 : keyCatcher.drawerWidth
        z: 11
        visible: x < keyCatcher.drawerWidth

        // Only animate a deliberate
        // open/close, never a layout-driven reposition.
        property bool sliding: false

        Behavior on x {
          enabled: settingsDrawer.sliding
          NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        onXChanged: {
          if (root.settingsOpen ? x <= 0 : x >= keyCatcher.drawerWidth)
            sliding = false
        }

        Rectangle {
          anchors.fill: parent
          color: bar ? bar.background : Color.background
          radius: Style.space(6)
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: function (mouse) { mouse.accepted = true }
        }

        Flickable {
          id: settingsScroll
          anchors.fill: parent
          anchors.margins: Style.space(10)
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: settingsColumn
            width: settingsScroll.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(settingsBack.implicitHeight, settingsTitle.implicitHeight)

              Text {
                id: settingsBack
                textFormat: Text.PlainText
                text: ""
                color: settingsBackMouse.containsMouse
                  ? root.contentForeground : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: root.iconPx(settingsBack.text, root.fontBody)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  id: settingsBackMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openSettings(false)
                }
              }

              Text {
                id: settingsTitle
                textFormat: Text.PlainText
                text: "Settings"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: root.fontTitle
                font.bold: true
                anchors.left: settingsBack.right
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            // --- the two adjustable values -------------------------------
            Repeater {
              model: [
                {
                  key: "hide",
                  label: "Hide entries under",
                  value: root.hideUnderMinutes > 0 ? root.hideUnderMinutes + " min" : "show all",
                  hint: "Usage rows shorter than this stay out of the list"
                },
                {
                  key: "budget",
                  label: "Slacking budget",
                  value: root.slackBudgetMinutes > 0
                    ? Model.fmt(root.slackBudgetMinutes * 60000) + " / day" : "none",
                  hint: "Notifies you once when the day's slacking passes it"
                },
                {
                  key: "nudge",
                  label: "Go outside nudge",
                  value: root.reminderHours > 0 ? "every " + root.reminderHours + "h" : "off",
                  hint: "Notifies you after this much screen time in a day"
                }
              ]

              Item {
                id: settingRow
                required property var modelData
                width: settingsColumn.width
                implicitHeight: Math.max(settingLabel.implicitHeight, settingValue.implicitHeight)
                  + settingHint.implicitHeight + Style.space(2)

                Text {
                  id: settingLabel
                  textFormat: Text.PlainText
                  text: settingRow.modelData.label
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontBody
                  anchors.left: parent.left
                  anchors.top: parent.top
                }

                Text {
                  id: settingValue
                  textFormat: Text.PlainText
                  text: settingRow.modelData.value
                  color: settingMouse.containsMouse ? Color.accent : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontBody
                  font.bold: true
                  anchors.right: parent.right
                  anchors.top: parent.top
                }

                Text {
                  id: settingHint
                  textFormat: Text.PlainText
                  text: settingRow.modelData.hint
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontCaption
                  wrapMode: Text.WordWrap
                  width: parent.width
                  anchors.top: settingLabel.bottom
                  anchors.topMargin: Style.space(2)
                }

                MouseArea {
                  id: settingMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (settingRow.modelData.key === "hide") root.cycleHideUnder()
                    else if (settingRow.modelData.key === "budget") root.cycleBudget()
                    else root.cycleReminder()
                  }
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            // --- dismissed stats -----------------------------------------
            Text {
              textFormat: Text.PlainText
              text: root.dismissedRows.length > 0
                ? "Hidden stats · click to restore"
                : "Hidden stats"
              color: root.contentForeground
              opacity: 0.75
              font.family: root.contentFontFamily
              font.pixelSize: root.fontBody
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              visible: root.dismissedRows.length === 0
              text: "Nothing hidden. Hover a stat and click the cross beside it."
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: root.fontCaption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Repeater {
              model: root.dismissedRows

              Item {
                id: hiddenRow
                required property var modelData
                width: settingsColumn.width
                implicitHeight: Math.max(hiddenLabel.implicitHeight, hiddenPlus.implicitHeight)

                Text {
                  id: hiddenPlus
                  textFormat: Text.PlainText
                  text: ""
                  color: hiddenMouse.containsMouse ? Color.accent : Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: root.iconPx(hiddenPlus.text, root.fontCaption)
                  width: Style.space(16)
                  horizontalAlignment: Text.AlignHCenter
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: hiddenLabel
                  textFormat: Text.PlainText
                  text: hiddenRow.modelData.label
                  color: hiddenMouse.containsMouse ? root.contentForeground : Qt.darker(root.contentForeground, 1.3)
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontBody
                  anchors.left: hiddenPlus.right
                  anchors.leftMargin: root.iconGap(hiddenPlus.text, root.fontCaption,
                    Style.space(16), Style.space(7))
                  anchors.verticalCenter: parent.verticalCenter
                }

                MouseArea {
                  id: hiddenMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleStat(hiddenRow.modelData.id)
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            // --- reset ----------------------------------------------------
            Item {
              width: parent.width
              implicitHeight: resetLabel.implicitHeight + resetHint.implicitHeight + Style.space(2)

              // The glyph is its own item rather than a character inside the
              // label: welded into the text run it inherited the bold weight
              // and sat on a fixed two-space gap that scaled with nothing.
              Text {
                id: resetIcon
                textFormat: Text.PlainText
                text: ""
                color: resetMouse.containsMouse ? Color.urgent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: root.iconPx(resetIcon.text, root.fontBody)
                anchors.left: parent.left
                anchors.baseline: resetLabel.baseline
              }

              Text {
                id: resetLabel
                textFormat: Text.PlainText
                text: "Reset to defaults"
                color: resetMouse.containsMouse ? Color.urgent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: root.fontBody
                font.bold: true
                anchors.left: resetIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.top: parent.top
              }

              Text {
                id: resetHint
                textFormat: Text.PlainText
                text: "Restores every stat, the default filter and the default nudge interval. Your history and slacking choices are untouched."
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: root.fontCaption
                wrapMode: Text.WordWrap
                width: parent.width
                anchors.top: resetLabel.bottom
                anchors.topMargin: Style.space(2)
              }

              MouseArea {
                id: resetMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.resetSettings()
              }
            }
          }
        }
      }

      // ---- Main content (full width, drawer slides over it) --------------
      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: panelColumn.width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: panelColumn
          width: panelScroll.width
          spacing: Style.space(12)

          // ---- Hero: today's total, SHOW MORE/LESS toggle top-right ------
          Item {
            width: parent.width
            height: implicitHeight
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            // Easter egg: the hourglass is turned exactly on the hour.
            property int lastFlipHour: -1

            Timer {
              id: hourTick
              interval: root.serviceReady ? Model.msUntilNextHour(Date.now()) : 60000
              repeat: false
              running: root.serviceReady
              onTriggered: {
                var h = new Date().getHours()
                if (h !== parent.lastFlipHour) {
                  parent.lastFlipHour = h
                  heroFlip.restart()
                }
                interval = Model.msUntilNextHour(Date.now())
                restart()
              }
            }

            SequentialAnimation {
              id: heroFlip
              NumberAnimation {
                target: heroIcon
                property: "rotation"
                from: 0
                to: 360
                duration: 700
                easing.type: Easing.OutBack
              }
            }

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Math.round(Style.fontPx(2.8) * root.uiScale)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.top: parent.top
              anchors.topMargin: -Style.space(4)


            }

            // "Hide < N minutes" filter control: click cycles the
            // threshold; the choice persists in the widget's shell.json
            // entry.
            Row {
              id: hideFilterCorner
              spacing: Style.space(4)
              anchors.right: parent.right
              anchors.top: parent.top

              // The corner is now one door into settings rather than a
              // single toggle: the filter, the nudges and the dismissed
              // stats all live behind it.
              Text {
                textFormat: Text.PlainText
                text: "\uf013"
                color: hideFilterMouse.containsMouse || root.settingsOpen
                  ? root.contentForeground
                  : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: root.iconPx("\uf013", root.fontCaption)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: hideFilterMouse
              anchors.fill: hideFilterCorner
              anchors.margins: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSettings(!root.settingsOpen)

              PanelToolTip {
                visible: hideFilterMouse.containsMouse
                tipText: "Settings"
              }
            }

            PanelToolTip {
              visible: hideFilterMouse.containsMouse
              tipText: "Entries under this are hidden \u00b7 click to change"
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.top: parent.top
              spacing: Style.space(2)

              // Only the title shares its line with the corner filter, so
              // only the title gives up width for it. The subtitle and the
              // verdict run the full width -- the verdict is the longest
              // string in the panel and was losing its time to the elide.
              // Identity line. This used to be the largest text in the
              // panel, spending the most prominent slot on the one thing
              // you already knew -- which plugin you just opened. It is an
              // eyebrow now and the numbers below take the weight. A
              // selected past day rides here as context, rather than as a
              // prefix buried at the head of the stats sentence.
              Text {
                textFormat: Text.PlainText
                text: root.activeDayKey === root.todayKey || !root.activeDayLabel
                  ? "Omachron"
                  : "Omachron \u00b7 " + root.activeDayLabel
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: root.fontCaption
                font.bold: true
                elide: Text.ElideRight
                width: parent.width - hideFilterCorner.implicitWidth - Style.space(8)
              }

              // The two numbers the panel exists to report, side by side at
              // display size with their names beneath. Both were previously
              // caption-sized inside a single styled run: accurate, but you
              // had to read a sentence to find either of them.
              Row {
                spacing: Style.space(22)
                visible: root.dayTotal > 0

                Column {
                  spacing: 0
                  Text {
                    textFormat: Text.PlainText
                    text: Model.fmt(root.dayTotal)
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontHero
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "total"
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontCaption
                  }
                }

                Column {
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    text: root.slackMs > 0 ? Model.fmt(root.slackMs) : "none"
                    color: root.slackMs > 0
                      ? root.heatColor(root.contentForeground,
                          Model.slackHeat(root.slackMs, root.dayTotal))
                      : Color.accent
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontHero
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.slackMs > 0
                      ? "slacking (" + root.slackShare + "%)"
                      : "slacking"
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontCaption
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.dayTotal <= 0
                text: "Nothing tracked yet"
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: root.fontCaption
                width: parent.width
              }

              // The greeting the plugin opens with: how much of the day
              // went to slacking off. Reddens with the share, matching the
              // heat on the rows that produced it.
              // Two different registers, deliberately. The verdict is a
              // joke: quiet, italic, unsaturated. The progress line under it
              // is the real number and keeps the loud colour. When both were
              // caption-weight and both tinted red they read as one blurred
              // sentence.
              Text {
                id: verdictText
                textFormat: Text.PlainText
                text: root.slackVerdict
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.italic: true
                font.pixelSize: root.fontCaption
                // The rotating phrases vary a lot in length, and the time
                // suffix grows through the day, so this wraps rather than
                // eliding -- losing the time off the end was the one thing
                // the line could not afford.
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                width: parent.width

                // The rotation dips the line rather than swapping it dead.
                // It multiplies the real opacity instead of animating it, so
                // the binding on slackMs survives -- and it is driven off
                // verdictVariant, never off `text`, which also changes every
                // few seconds as the clock advances and would strobe.
                property real fadeFactor: 1.0
                opacity: (root.slackMs > 0 ? 0.95 : 0.7) * fadeFactor

                Connections {
                  target: root
                  function onVerdictVariantChanged() { verdictFade.restart() }
                }

                SequentialAnimation {
                  id: verdictFade
                  NumberAnimation {
                    target: verdictText; property: "fadeFactor"
                    to: 0.0; duration: 110; easing.type: Easing.InQuad
                  }
                  NumberAnimation {
                    target: verdictText; property: "fadeFactor"
                    to: 1.0; duration: 220; easing.type: Easing.OutQuad
                  }
                }
              }

              // Progress line: whether the slacking is going down, in the
              // colour of the answer. Hidden rather than dashed when there
              // is no previous day to compare against -- an empty verdict
              // is worse than no verdict.
              Text {
                textFormat: Text.PlainText
                visible: root.hasSlackProgress
                text: root.hasSlackProgress
                  ? root.deltaArrow(root.slackProgress.value) + "  "
                    + root.slackProgress.value + " slacking than "
                    + String(root.slackProgress.label).replace("Slacking vs ", "")
                  : ""
                color: root.hasSlackProgress
                  ? root.insightValueColor("slackDelta", root.slackProgress.value)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: root.fontCaption
                font.bold: true
                topPadding: Style.space(2)
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                width: parent.width
              }

              // Budget: the only forward-looking thing in the panel. Hidden
              // entirely when unset, rather than shown as an empty track --
              // an unset budget is not a budget of zero.
              Item {
                visible: root.budget.active
                width: parent.width
                implicitHeight: visible ? budgetLabelText.implicitHeight + Style.space(8) : 0

                Text {
                  id: budgetLabelText
                  textFormat: Text.PlainText
                  text: Model.budgetLabel(root.budget)
                  color: root.budget.over ? root.slackColour : Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontCaption
                  font.bold: root.budget.over
                  anchors.top: parent.top
                  anchors.left: parent.left
                }

                Rectangle {
                  id: budgetTrack
                  width: parent.width
                  height: Style.space(3)
                  radius: height / 2
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                 root.contentForeground.b, 0.12)
                  anchors.bottom: parent.bottom

                  Rectangle {
                    width: Math.max(2, budgetTrack.width * root.budget.ratio)
                    height: parent.height
                    radius: parent.radius
                    color: root.budget.over ? root.slackColour : Color.accent
                    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                  }
                }
              }

            }
          }

          // ---- Per-app usage list ----------------------------------------
          Item {
            width: parent.width
            height: root.listMaxHeight

            Flickable {
              id: usageScroll
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.top: parent.top
              clip: true
              contentWidth: width
              contentHeight: usageList.implicitHeight
              // Fixed height so the panel size stays identical across days.
              height: parent.height
              interactive: contentHeight > height
              flickableDirection: Flickable.VerticalFlick
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: usageList
                width: parent.width - Style.space(8)
                spacing: Style.space(4)
                // Vertically center short lists within the fixed-height
                // viewport; clamp to 0 so long lists still scroll from top.
                y: Math.max(0, (usageScroll.height - implicitHeight) / 2)

                // Empty-state message when the selected day has no data.
                Text {
                  textFormat: Text.PlainText
                  visible: root.fullApps.length === 0
                  text: "No data"
                  color: root.contentForeground
                  opacity: 0.4
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontBody
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                }

                Repeater {
                  model: root.fullApps

                  Column {
                    id: appEntry
                    required property var modelData
                    width: parent.width
                    spacing: 0

                  Item {
                    id: appRow
                    readonly property var modelData: appEntry.modelData
                    readonly property bool expanded: root.expandedApp === appRow.appName

                    readonly property string appName: String(modelData.app || "")
                    readonly property string appLabel: Model.displayName(modelData.app)
                    readonly property string timeLabel: Model.fmt(modelData.ms)
                    // Slacking rows redden as their time racks up, so the
                    // day's worst offenders stand out without reading a
                    // single number.
                    readonly property bool slacking: root.isSlackApp(appName)
                    // Whether the slacking marker occupies its slot. On a
                    // row that is not already counted the marker is
                    // hover-only, and it has to stay up while the marker's
                    // OWN MouseArea holds the cursor as well as while the
                    // row does. That area sits above rowMouse, so hovering
                    // the marker set rowMouse.containsMouse false, which
                    // collapsed the marker to zero width, which disabled
                    // the area, which handed the hover straight back to
                    // rowMouse -- a loop that re-ran every frame. It
                    // flickered the marker, and the app name that sizes
                    // against it flickered with it.
                    readonly property bool markerShown: appRow.slacking
                      || rowMouse.containsMouse || slackMarkMouse.containsMouse
                    readonly property real heat: slacking ? Model.slackHeat(modelData.ms, root.dayTotal) : 0
                    readonly property color rowColor:
                      root.slackColor(appName, modelData.ms, root.contentForeground)
                    // Website and web-app rows show the site's fetched
                    // favicon and program rows their desktop-entry theme
                    // icon, so all read like apps. The icon slot is
                    // fixed-width so names stay aligned on rows with no
                    // icon to show.
                    readonly property string faviconDomain: {
                      var d = Model.siteDomain(modelData.app)
                      return d !== "" ? d : Model.webAppDomain(modelData.app)
                    }
                    readonly property bool hasSiteIcon: faviconDomain !== ""
                      && root.siteIcons[faviconDomain] === true
                    readonly property string rowIconSource: {
                      if (hasSiteIcon)
                        return "file://" + root.iconsDir + "/" + faviconDomain + ".png"
                      if (faviconDomain !== "") return root.siteFallbackIcon
                      return root.programIconSource(appName)
                    }

                    width: parent.width
                    implicitHeight: Math.max(Style.space(15), Math.max(appNameText.implicitHeight, appTimeText.implicitHeight)) + Style.space(5)

                    // Hover plate, plus a faint wash on slacking rows that
                    // deepens with the heat.
                    Rectangle {
                      anchors.fill: parent
                      anchors.leftMargin: -Style.space(4)
                      anchors.rightMargin: -Style.space(4)
                      radius: Style.space(3)
                      color: appRow.slacking ? root.slackColour : root.contentForeground
                      opacity: appRow.slacking
                        ? (rowMouse.containsMouse ? 0.10 + appRow.heat * 0.12 : appRow.heat * 0.12)
                        : (rowMouse.containsMouse ? 0.07 : 0)
                    }

                    Image {
                      id: rowIcon
                      visible: appRow.rowIconSource !== ""
                      width: Style.space(14)
                      height: Style.space(14)
                      sourceSize.width: 64
                      sourceSize.height: 64
                      fillMode: Image.PreserveAspectFit
                      smooth: true
                      asynchronous: true
                      source: appRow.rowIconSource
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // appLabel derives from modelData.app, which is the
                    // app_id a Wayland client picks for itself -- arbitrary,
                    // unbounded, and not normalised away by Model.displayName.
                    // Text.AutoText would sniff that and render markup as
                    // rich text, so the format is pinned here. Every Text in
                    // this file is pinned for the same reason: none of them
                    // want rich text, and a future binding shouldn't have to
                    // remember.
                    Text {
                      id: appNameText
                      textFormat: Text.PlainText
                      text: appRow.appLabel
                      color: appRow.rowColor
                      opacity: appRow.slacking ? 0.95 : 0.6
                      font.family: root.contentFontFamily
                      font.pixelSize: root.fontBody
                      elide: Text.ElideRight
                      width: parent.width - appTimeText.implicitWidth - slackMark.width
                        - Style.space(10) - Style.space(14) - Style.space(6)
                      anchors.left: rowIcon.right
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // Membership marker: shown lit on slacking rows, and
                    // faintly on hover to advertise that a click adds this
                    // entry to the list.
                    Text {
                      id: slackMark
                      textFormat: Text.PlainText
                      text: appRow.markerShown ? "\uf071" : ""
                      color: appRow.slacking ? appRow.rowColor : root.contentForeground
                      opacity: appRow.slacking ? 0.9 : 0.3
                      font.family: root.contentFontFamily
                      font.pixelSize: root.iconPx("\uf071", root.fontCaption)
                      width: appRow.markerShown ? Style.space(20) : 0
                      horizontalAlignment: Text.AlignHCenter
                      anchors.left: appNameText.right
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // Share bar: the row's slice of the day at a glance.
                    Rectangle {
                      height: 2
                      radius: 1
                      color: appRow.slacking ? appRow.rowColor : root.contentForeground
                      opacity: appRow.slacking ? 0.45 + appRow.heat * 0.4 : 0.22
                      x: Style.space(14) + Style.space(6)
                      width: Math.max(2, (parent.width - x)
                        * Math.min(1, (Number(appRow.modelData.pct) || 0) / 100))
                      anchors.bottom: parent.bottom
                    }

                    Text {
                      id: appTimeText
                      textFormat: Text.PlainText
                      text: appRow.timeLabel
                      color: appRow.rowColor
                      font.family: root.contentFontFamily
                      font.pixelSize: root.fontBody
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                    }

                    // The row click used to silently reclassify the app --
                    // a destructive, unlabelled action on the largest target
                    // in the panel. It now opens the app's own history, and
                    // reclassifying moved onto the marker that was already
                    // advertising itself for exactly that.
                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleExpandedApp(appRow.appName)
                    }

                    PanelToolTip {
                      visible: rowMouse.containsMouse && !slackMarkMouse.containsMouse
                      tipText: root.expandedApp === appRow.appName
                        ? "Click to collapse"
                        : "Click for this app's past week"
                    }

                    MouseArea {
                      id: slackMarkMouse
                      anchors.fill: slackMark
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      enabled: slackMark.width > 0
                      cursorShape: Qt.PointingHandCursor
                      onClicked: function (mouse) {
                        root.toggleSlack(appRow.appName)
                        mouse.accepted = true
                      }

                      PanelToolTip {
                        visible: slackMarkMouse.containsMouse
                        tipText: appRow.slacking
                          ? "Counted as slacking · click to stop"
                          : "Click to count as slacking"
                      }
                    }
                  }

                  // Drill-down: this one app's past week, so a row answers
                  // "is this getting worse?" without leaving the list.
                  Item {
                    id: appDrill
                    width: appEntry.width
                    visible: appRow.expanded
                    height: visible ? Style.space(52) : 0

                    readonly property var bars: appRow.expanded ? root.expandedTrend : []
                    readonly property real peak: Model.trendMax(bars)

                    Row {
                      id: drillRow
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(20)
                      anchors.rightMargin: Style.space(4)
                      anchors.topMargin: Style.space(2)
                      anchors.bottomMargin: Style.space(6)
                      spacing: 0

                      Repeater {
                        model: appDrill.bars

                        Item {
                          id: drillSlot
                          required property var modelData
                          width: drillRow.width / Math.max(1, appDrill.bars.length)
                          height: drillRow.height

                          readonly property real track: Style.space(26)
                          readonly property real px: {
                            if (!(appDrill.peak > 0)) return 2
                            var ms = Number(modelData.ms)
                            if (!isFinite(ms) || ms <= 0) return 2
                            return Math.max(2, Math.min(track, track * ms / appDrill.peak))
                          }

                          Rectangle {
                            width: Math.max(2, parent.width * 0.5)
                            height: drillSlot.px
                            radius: Style.space(2)
                            color: appRow.slacking ? root.slackColour
                              : Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                        root.contentForeground.b, 0.35)
                            opacity: Number(drillSlot.modelData.ms) > 0 ? 1.0 : 0.25
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Style.space(12)

                            PanelToolTip {
                              visible: drillHover.containsMouse && Number(drillSlot.modelData.ms) > 0
                              tipText: Model.formatDateShort(drillSlot.modelData.key)
                                + " · " + Model.fmt(drillSlot.modelData.ms)
                            }
                          }

                          MouseArea {
                            id: drillHover
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                          }

                          Text {
                            textFormat: Text.PlainText
                            text: drillSlot.modelData.label
                            color: root.contentForeground
                            opacity: drillSlot.modelData.isToday ? 0.85 : 0.4
                            font.family: root.contentFontFamily
                            font.pixelSize: root.fontCaption
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            anchors.bottom: parent.bottom
                          }
                        }
                      }
                    }
                  }
                  }
                }
              }
            }

            NumberAnimation {
              id: usageScrollAnim
              target: usageScroll
              property: "contentY"
              duration: 170
              easing.type: Easing.OutCubic
            }

            // Scroll affordances. The standard behaviour: an up chevron only
            // once there is something above, a down chevron only while there
            // is more below -- so a list that fits shows neither, and at
            // either end only one points the way you can actually go. Each
            // sits on a plate of the panel's own background so the rows do
            // not read through the glyph.
            Repeater {
              model: [
                { up: true, glyph: "\uf077" },
                { up: false, glyph: "\uf078" }
              ]

              Item {
                id: chevron
                required property var modelData
                readonly property real maxY: Math.max(0, usageScroll.contentHeight - usageScroll.height)

                visible: modelData.up
                  ? usageScroll.contentY > 1
                  : usageScroll.contentY < maxY - 1
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.top: modelData.up ? parent.top : undefined
                anchors.bottom: modelData.up ? undefined : parent.bottom
                height: Style.space(17)
                z: 5

                Rectangle {
                  anchors.fill: parent
                  color: bar ? bar.background : Color.background
                  opacity: 0.94
                }

                Text {
                  textFormat: Text.PlainText
                  text: chevron.modelData.glyph
                  color: chevronMouse.containsMouse
                    ? Color.accent : Qt.darker(root.contentForeground, 1.25)
                  font.family: root.contentFontFamily
                  font.pixelSize: root.fontCaption
                  anchors.centerIn: parent
                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                MouseArea {
                  id: chevronMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.scrollUsage(chevron.modelData.up ? -1 : 1)
                }
              }
            }

            // Thin scrollbar indicator on the right edge.
            Rectangle {
              property real ratio: usageScroll.contentHeight > 0
                ? usageScroll.height / usageScroll.contentHeight : 0
              visible: usageScroll.contentHeight > usageScroll.height
              width: Style.space(3)
              height: Math.max(Style.space(16), usageScroll.height * ratio)
              radius: width / 2
              color: root.contentForeground
              opacity: 0.25
              anchors.right: parent.right
              y: usageScroll.y + (usageScroll.height - height) * (
                   usageScroll.contentHeight > usageScroll.height
                     ? usageScroll.contentY / (usageScroll.contentHeight - usageScroll.height)
                     : 0)
            }
          }

          // ---- Week trend + insights ------------------------------------
          Item {
            width: parent.width
            height: patternsColumn.implicitHeight
            implicitHeight: height

            Column {
              id: patternsColumn
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator {
                width: parent.width
                foreground: root.contentForeground
              }

              // Trend graph over one of three fixed ranges. Nothing here
              // paginates: the range buttons swap the whole window at once,
              // so every view is one glance with no scrolling.
              Item {
                width: parent.width
                height: trendColumn.implicitHeight
                implicitHeight: height

                Column {
                  id: trendColumn
                  width: parent.width
                  spacing: Style.space(18)

                  // Header: range buttons on the left, range total on the
                  // right (click to flip to its share of the possible time).
                  // The heading is the range control: "Usage past " stays
                  // put and the period after it is the button. Clicking
                  // anywhere on the phrase advances week -> month -> year.
                  Item {
                    width: parent.width
                    implicitHeight: Math.max(headingRow.implicitHeight, trendTotalLabel.implicitHeight)

                    Row {
                      id: headingRow
                      spacing: 0
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        textFormat: Text.PlainText
                        text: "Usage past "
                        color: root.contentForeground
                        opacity: headingMouse.containsMouse ? 1.0 : 0.85
                        font.family: root.contentFontFamily
                        font.pixelSize: root.fontCaption
                        font.bold: true
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                      }

                      Text {
                        id: rangeWord
                        textFormat: Text.PlainText
                        text: root.trendRange
                        color: Color.accent
                        font.family: root.contentFontFamily
                        font.pixelSize: root.fontCaption
                        font.bold: true
                        font.underline: headingMouse.containsMouse

                        // A short cross-fade on the swap, so the period
                        // visibly changes rather than silently substituting.
                        Behavior on text {
                          SequentialAnimation {
                            NumberAnimation { target: rangeWord; property: "opacity"; to: 0.0; duration: 90 }
                            PropertyAction { target: rangeWord; property: "text" }
                            NumberAnimation { target: rangeWord; property: "opacity"; to: 1.0; duration: 140 }
                          }
                        }
                      }
                    }

                    MouseArea {
                      id: headingMouse
                      anchors.fill: headingRow
                      anchors.margins: -Style.space(5)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.cycleTrendRange()

                      PanelToolTip {
                        visible: headingMouse.containsMouse
                        tipText: "Click for the past " + (root.trendRange === "week"
                          ? "month" : (root.trendRange === "month" ? "year" : "week"))
                      }
                    }

                    Text {
                      id: trendTotalLabel
                      textFormat: Text.PlainText
                      text: root.weekTotalAsPct
                        ? (root.trendPossibleMs > 0
                            ? Math.round(root.trendTotalMs / root.trendPossibleMs * 100) + "%"
                            : "0%")
                        : Model.fmt(root.trendTotalMs)
                      color: root.contentForeground
                      opacity: trendTotalMouse.containsMouse ? 1.0 : 0.6
                      font.family: root.contentFontFamily
                      font.pixelSize: root.fontCaption
                      elide: Text.ElideRight
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter

                      MouseArea {
                        id: trendTotalMouse
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.weekTotalAsPct = !root.weekTotalAsPct
                      }

                      PanelToolTip {
                        visible: trendTotalMouse.containsMouse
                        tipText: {
                          var hours = Math.round(root.trendPossibleMs / 3600000)
                          return root.weekTotalAsPct
                            ? "% of the range's " + hours + " hours"
                            : "logged of " + hours + " possible hours"
                        }
                      }
                    }
                  }

                  // The bars themselves: one per day (week/month) or one per
                  // month (year). Widths come from the bar count, so the row
                  // always fills exactly and never needs to scroll.
                  Row {
                    id: trendRow
                    width: parent.width
                    spacing: 0
                    topPadding: Style.space(8)

                    // Held true for a beat after the range changes so the
                    // bars snap to their new scale instead of animating
                    // through it.
                    property bool rangeSettling: false
                    Connections {
                      target: root
                      function onTrendRangeChanged() {
                        trendRow.rangeSettling = true
                        rangeSettleTimer.restart()
                      }
                    }
                    Timer {
                      id: rangeSettleTimer
                      interval: 60
                      onTriggered: trendRow.rangeSettling = false
                    }

                    readonly property int count: Math.max(1, root.trendBars.length)
                    readonly property real slotWidth: width / count
                    // Thin ranges need proportionally fatter bars or they
                    // vanish; 7 bars can afford the airier half-slot look.
                    readonly property real barFraction: count > 20 ? 0.72 : (count > 10 ? 0.62 : 0.5)

                    Repeater {
                      model: root.trendBars

                      Item {
                        id: barSlot
                        required property var modelData
                        required property int index

                        width: trendRow.slotWidth
                        height: Style.space(80)

                        readonly property bool isDaily: root.trendIsDaily
                        readonly property bool isActive: isDaily
                          ? modelData.key === root.activeDayKey
                          : false
                        readonly property bool isCurrent: isDaily
                          ? modelData.isToday === true
                          : modelData.isCurrent === true
                        readonly property bool isEmpty: !(Number(modelData.ms) > 0)
                        readonly property bool hasData: !isEmpty && root.trendMaxMs > 0
                        // Height of the track a bar is drawn in.
                        readonly property real barTrack: Style.space(64)

                        // Clamped to the track, deliberately. Switching range
                        // reassigns the Repeater's model and trendMaxMs from
                        // the same source, and for a frame a delegate can see
                        // the NEW range's values against the OLD range's
                        // maximum -- a month's total over a day's peak, which
                        // is a bar some twenty times too tall. It also guards
                        // NaN, which a recycled delegate briefly holding no
                        // modelData would otherwise push into the layout.
                        readonly property real barPx: {
                          if (!hasData || !(root.trendMaxMs > 0)) return 3
                          var ms = Number(modelData.ms)
                          if (!isFinite(ms) || ms <= 0) return 3
                          var px = barTrack * ms / root.trendMaxMs
                          if (!isFinite(px)) return 3
                          return Math.max(3, Math.min(barTrack, px))
                        }
                        // Only daily bars can select a day; a month bar has
                        // no single day to show a breakdown for.
                        readonly property bool selectable: isDaily && hasData
                        // Portion of this bar that went to slacking, 0-1.
                        readonly property real slackShare: {
                          var ms = Number(modelData.ms) || 0
                          var sl = Number(modelData.slackMs) || 0
                          if (!isFinite(ms) || !isFinite(sl) || ms <= 0 || sl <= 0) return 0
                          return Math.max(0, Math.min(1, sl / ms))
                        }
                        readonly property bool labelled: index % root.trendLabelEvery === 0
                          || index === root.trendBars.length - 1

                        Rectangle {
                          width: Math.max(2, parent.width * trendRow.barFraction)
                          radius: Style.space(2)
                          // A bar carries exactly two colours: urgent for the
                          // slacking share, this one for focus --
                          // that is the whole legend. Today and the selected
                          // day are marked by a brighter shade of the *same*
                          // colour (and a bold label), never a third hue, or
                          // the stack would stop meaning what the legend says.
                          color: barSlot.isEmpty
                            ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
                            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.28)
                          opacity: barSlot.hasData && barMouse.containsMouse && !barSlot.isActive ? 0.5 : 1.0
                          anchors.horizontalCenter: parent.horizontalCenter
                          anchors.bottom: parent.bottom
                          anchors.bottomMargin: Style.space(14)
                          height: barSlot.barPx

                          // Slacking, stacked from the baseline up, so the
                          // red reads as a share of that day's bar rather
                          // than an amount of time. A short day spent
                          // entirely slacking is a fully red short bar.
                          Rectangle {
                            visible: barSlot.hasData && barSlot.slackShare > 0
                            width: parent.width
                            height: Math.max(1, Math.round(parent.height * barSlot.slackShare))
                            radius: parent.radius
                            color: root.slackColour
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            // Eases as the day accrues, but not across a range
                            // switch: there the whole model is different data,
                            // so morphing one range's slice into another's is
                            // motion that means nothing.
                            Behavior on height {
                              enabled: !trendRow.rangeSettling
                              NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }
                          }
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: barSlot.labelled
                            ? (root.trendIsDaily
                                ? (root.trendRange === "month" ? modelData.dayLabel : modelData.label)
                                : modelData.label)
                            : ""
                          // Today and the selected day are called out here
                          // rather than in the bar: a bar has exactly two
                          // colours to spend and the legend spends both.
                          color: (barSlot.isActive || barSlot.isCurrent)
                            ? Color.accent
                            : root.contentForeground
                          opacity: (barSlot.isActive || barSlot.isCurrent || !barSlot.isEmpty) ? 1.0 : 0.3
                          font.family: root.contentFontFamily
                          font.pixelSize: root.fontCaption
                          font.bold: barSlot.isActive || barSlot.isCurrent
                          width: parent.width
                          horizontalAlignment: Text.AlignHCenter
                          anchors.bottom: parent.bottom
                        }

                        // Thin bars are hard to hit, so the hover and click
                        // target is the whole slot rather than the drawn bar.
                        // It fills barSlot directly: deriving negative margins
                        // from an anchors.fill width is an anchor loop.
                        MouseArea {
                          id: barMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          enabled: !barSlot.isEmpty
                          cursorShape: barSlot.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                          onClicked: if (barSlot.selectable) root.selectDay(barSlot.modelData.key)

                          PanelToolTip {
                            visible: barMouse.containsMouse && !barSlot.isEmpty
                            tipText: {
                              var head = root.trendIsDaily
                                ? Model.formatDateLong(barSlot.modelData.key)
                                : barSlot.modelData.label + " " + barSlot.modelData.year
                              var line = head + " · " + Model.fmt(barSlot.modelData.ms)
                              if (barSlot.slackShare > 0)
                                line += " · " + Model.fmt(barSlot.modelData.slackMs)
                                  + " slacking (" + Math.round(barSlot.slackShare * 100) + "%)"
                              return line
                            }
                          }
                        }
                      }
                    }
                  }

                  // Names the encoding, so a part-red bar does not have to
                  // be guessed at. Swatch colours are read from the same
                  // expressions the bars use, not restated as literals --
                  // a legend that can drift out of step with its chart is
                  // worse than none.
                  Row {
                    id: legendRow
                    spacing: Style.space(14)

                    Repeater {
                      model: [
                        { swatch: root.slackColour, label: "slacking" },
                        { swatch: Qt.rgba(root.contentForeground.r,
                                          root.contentForeground.g,
                                          root.contentForeground.b, 0.28),
                          label: "focus" }
                      ]

                      Row {
                        required property var modelData
                        spacing: Style.space(5)

                        Rectangle {
                          width: Style.space(8)
                          height: Style.space(8)
                          radius: Style.space(2)
                          color: modelData.swatch
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: modelData.label
                          color: root.contentForeground
                          opacity: 0.55
                          font.family: root.contentFontFamily
                          font.pixelSize: root.fontCaption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }
                  }

                }
              }

              PanelSeparator {
                width: parent.width
                foreground: root.contentForeground
              }

              Repeater {
                model: root.insightRows

                Column {
                  id: statEntry
                  required property var modelData
                  required property int index
                  width: parent.width
                  spacing: 0

                  // These live on the delegate root, not on the row Item
                  // below. QML resolves an unqualified name against the
                  // component root and then the file root -- intermediate
                  // objects are not in that chain -- so declaring them one
                  // level down let every `label` and `value` fall through
                  // to the Panel scope and render the wrong thing.
                  readonly property string label: String(modelData.label || "")
                  readonly property string value: String(modelData.value || "")
                  readonly property string kind: String(modelData.kind || "")
                  readonly property string statId: String(modelData.id || "")

                  // A section header appears on the first surviving row of
                  // each group, so dismissing a whole section takes its
                  // heading with it rather than leaving an empty title.
                  // No explicit height: a Column does not position or
                  // reserve space for an invisible child, so collapsing this
                  // by hand was redundant -- and `height: visible ?
                  // implicitHeight : 0` drove the item's own height from its
                  // own implicitHeight, which QML re-evaluates in a circle
                  // and reported as a binding loop on every panel open.
                  PanelSectionHeader {
                    visible: Model.startsGroup(root.insightRows, statEntry.index)
                    text: String(statEntry.modelData.group || "")
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    fontSize: root.fontCaption
                    // Keep the component's own glyph-overshoot reserve and
                    // add the gap that separates one section from the last.
                    topPadding: Math.ceil(root.fontCaption * 0.15)
                      + (statEntry.index === 0 ? 0 : Style.space(12))
                    bottomPadding: Style.space(5)
                  }

                Item {
                  id: statRow
                  width: parent.width
                  height: implicitHeight
                  implicitHeight: Math.max(iconText.implicitHeight, Math.max(labelText.implicitHeight, valueText.implicitHeight))

                  Text {
                    id: iconText
                    textFormat: Text.PlainText
                    text: root.insightIcon(kind, value)
                    color: root.insightIconColor(kind, value)
                    font.family: root.contentFontFamily
                    font.pixelSize: root.iconPx(iconText.text, root.fontBody)
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter

                    readonly property bool flashing: root.insightFlashes(kind)
                    // The pulse quickens as the day's slacking piles up:
                    // a gentle blink at first, an alarm by the second hour.
                    readonly property int flashMs:
                      Math.round(900 - 550 * Model.slackHeat(root.slackMs, root.dayTotal))
                  }

                  // Driven by target/property rather than `on opacity` so the
                  // icon keeps a plain opacity of 1 on every non-flashing row.
                  SequentialAnimation {
                    running: iconText.flashing
                    loops: Animation.Infinite
                    onStopped: iconText.opacity = 1.0

                    NumberAnimation {
                      target: iconText; property: "opacity"
                      from: 1.0; to: 0.15
                      duration: iconText.flashMs
                      easing.type: Easing.InOutQuad
                    }
                    NumberAnimation {
                      target: iconText; property: "opacity"
                      from: 0.15; to: 1.0
                      duration: iconText.flashMs
                      easing.type: Easing.InOutQuad
                    }
                  }

                  // Bounded on the right by the value, so a label that
                  // outgrows its half elides instead of running underneath
                  // it. Both were previously free to claim the same pixels:
                  // the label had no right edge and the value took a flat
                  // 55% whether it needed it or not, so a wide pair printed
                  // as one run of text with no gap.
                  Text {
                    id: labelText
                    textFormat: Text.PlainText
                    text: label
                    color: root.contentForeground
                    opacity: 0.78
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontBody
                    anchors.left: iconText.right
                    anchors.leftMargin: root.iconGap(iconText.text, root.fontBody,
                      Style.space(16), Style.space(7))
                    anchors.right: valueText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                  }

                  Text {
                    id: valueText
                    textFormat: Text.PlainText
                    text: value
                    color: root.insightValueColor(kind, value)
                    font.family: root.contentFontFamily
                    font.pixelSize: root.fontBody
                    anchors.right: dismissX.left
                    anchors.rightMargin: Style.space(2)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    // Only as wide as the value actually is, so the label
                    // keeps everything the value does not need -- capped, so
                    // a runaway value still cannot swallow the whole row.
                    width: Math.min(implicitWidth, parent.width * 0.55)
                    horizontalAlignment: Text.AlignRight
                  }

                  // Hover-only dismiss. The gutter is reserved whether or not
                  // the row is hovered, so values never shift sideways as the
                  // pointer travels down the list.
                  Text {
                    id: dismissX
                    textFormat: Text.PlainText
                    text: "\uf00d"
                    visible: statHover.containsMouse || dismissMouse.containsMouse
                    color: dismissMouse.containsMouse
                      ? Color.urgent : Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: root.iconPx(dismissX.text, root.fontBody)
                    width: Style.space(14)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // NoButton so the row still hovers without eating the
                  // dismiss click that sits on top of it.
                  MouseArea {
                    id: statHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }

                  MouseArea {
                    id: dismissMouse
                    anchors.fill: dismissX
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleStat(statEntry.statId)

                    PanelToolTip {
                      visible: dismissMouse.containsMouse
                      tipText: "Hide this stat · restore it in settings"
                    }
                  }
                }
                }
              }
            }
            }
          }
        }
      }
    }

  // Rotates the verdict phrasing. Only runs while the panel is on screen --
  // there is nobody to read it otherwise, and the timer would just burn
  // wakeups in a plugin that is meant to sit quietly in the background.
  Timer {
    // Short enough to actually fire during a normal look at the panel --
    // it dismisses on focus loss, so it is rarely open for long -- but slow
    // enough to finish reading the line before it changes.
    interval: 12000
    repeat: true
    running: root.opened
    onTriggered: root.verdictVariant++
  }

  // Reset to today's live data when the panel is dismissed.
  Connections {
    target: root.controller
    function onOpenChanged() {
      if (root.controller.open) {
        // A fresh line each time it is opened, rather than always greeting
        // you with whatever was showing when you closed it.
        root.verdictVariant++
      } else {
        root.selectedKey = ""
        root.openSettings(false)
        root.trendRange = "week"
      }
    }
  }
}
