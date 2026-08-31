import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "lib/Model.js" as Model
import "lib/Messages.js" as Messages

// Omachron bar widget: today's total with a popup listing per-app usage
// and behaviour insights. The heavy lifting lives in Service.qml; this only
// reads its state and hosts the panel.
BarWidget {
  id: root
  moduleName: "dutchster.omachron"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("dutchster.omachron") : null
  readonly property string label: service ? service.barLabel : ""
  readonly property bool hasActivity: service ? service.hasActivity : false
  readonly property double slackMs: service ? service.slackTotal : 0
  readonly property string slackLabel: service && root.slackMs > 0
    ? " \u00b7 " + service.fmt(root.slackMs) + " slacking" : ""

  readonly property string glyph: ""

  // Vertical bar (left/right edge): the button's text label is hidden in
  // vertical mode, so the content is drawn as stacked OpticalGlyph lines —
  // icon first, then the duration split per token so each line fits the
  // icon slot. Same shape as omarchy.clock's vertical stack.
  readonly property var verticalLines: {
    if (!root.vertical) return []
    var lines = [root.glyph]
    if (!root.iconOnly && root.label) {
      var parts = String(root.label).split(" ")
      for (var i = 0; i < parts.length; i++) if (parts[i]) lines.push(parts[i])
    }
    return lines
  }

  // Icon-only mode: right-clicking shrinks the widget to just the glyph.
  // The state lives in the widget's shell.json entry ("iconOnly"), so it
  // survives restarts and follows the widget across bar slots.
  readonly property bool iconOnly: {
    var v = root.setting("iconOnly", false)
    return v === true || v === "true"
  }

  function toggleIconOnly() {
    var next = !root.iconOnly
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.iconOnly = next
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Go-outside nudges -------------------------------------------------
  // Hours of screen time between reminders; 0 turns them off. Lives in the
  // widget's shell.json entry alongside the other preferences, so it
  // survives restarts. This lives in the bar widget rather than the panel
  // because the panel is only constructed while it is open -- a reminder
  // that only fires when you are already looking at the panel is useless.
  readonly property int reminderHours: {
    var v = Number(root.setting("reminderHours", 4))
    return (isNaN(v) || v < 0) ? 4 : v
  }

  function setReminderHours(hours) {
    root.writeSetting("reminderHours", hours)
  }

  // Highest milestone already announced today. Reset when the total falls
  // (a new day rolled over, or history was cleared), so tomorrow starts
  // its count again rather than staying silent.
  property int lastNudgeLevel: 0
  // The shell restarts often (a theme change, a plugin edit, a crash), and
  // every restart rebuilds this widget with lastNudgeLevel at 0. Without
  // this, each restart would re-announce a milestone already passed hours
  // ago. The first tick after load records where the day already stands and
  // stays quiet; only a milestone crossed while running is worth a popup.
  property bool nudgeArmed: false

  // ---- Slacking budget ---------------------------------------------------
  // Minutes of slacking you mean to stay under today; 0 is no budget. This
  // is the one number in the plugin that looks forward rather than back.
  readonly property int slackBudgetMinutes: {
    var v = Number(root.setting("slackBudgetMinutes", 0))
    return (isNaN(v) || v < 0) ? 0 : v
  }

  function setSlackBudget(minutes) {
    root.writeSetting("slackBudgetMinutes", minutes)
  }

  // Day key the budget alert already fired for, and the Friday the recap
  // already went out on, so neither repeats. Both persist in the widget's
  // shell.json entry for the same reason nudgeArmed exists: held only in
  // memory they reset on every shell restart, and because the timer below
  // is triggeredOnStart, restarting while already over budget fired the
  // alert again straight away -- once per restart rather than once a day.
  property string budgetNotifiedKey: String(root.setting("budgetNotifiedKey", "") || "")
  property string recapSentKey: String(root.setting("recapSentKey", "") || "")

  Process { id: nudgeProc }

  // One timer, one notification per tick at most. Three timers racing each
  // other into the same Process would drop messages.
  Timer {
    interval: 60000
    repeat: true
    running: root.service !== null
    triggeredOnStart: true
    onTriggered: {
      var svc = root.service
      if (!svc) return
      var total = svc.todayTotal
      var todayKey = svc.todayKey || ""

      // 1. Budget crossed -- the most actionable, so it goes first.
      if (root.slackBudgetMinutes > 0 && root.budgetNotifiedKey !== todayKey) {
        var budget = Model.budgetState(svc.slackTotal, root.slackBudgetMinutes * 60000)
        if (budget.over) {
          root.budgetNotifiedKey = todayKey
          root.writeSetting("budgetNotifiedKey", todayKey)
          // Variant keyed to the date so the quip is stable for the day
          // but differs from the one you got yesterday.
          nudgeProc.command = ["notify-send", "-a", "Omachron", "-u", "critical",
            "Slacking budget spent",
            Messages.budgetBlownBody(budget.overMs, new Date().getDate())]
          nudgeProc.running = true
          return
        }
      }

      // 2. Friday recap, held until the evening so it lands on a week that
      //    is actually finished rather than one that just started.
      if (root.recapSentKey !== todayKey && Model.isRecapDay(todayKey)
          && new Date().getHours() >= 17) {
        var recap = Model.weeklyRecap(svc.historyDays, todayKey, svc.slack, svc.today, total)
        if (recap) {
          root.recapSentKey = todayKey
          root.writeSetting("recapSentKey", todayKey)
          nudgeProc.command = ["notify-send", "-a", "Omachron", recap.title, recap.body]
          nudgeProc.running = true
          return
        }
      }

      // 3. Go-outside nudge.
      if (root.reminderHours <= 0) return
      var level = Model.reminderLevel(total, root.reminderHours)
      if (!root.nudgeArmed) {
        root.lastNudgeLevel = level
        root.nudgeArmed = true
        return
      }
      // A total that has gone backwards means the day rolled over (or the
      // history was cleared), so the count starts again from there.
      if (level < root.lastNudgeLevel) root.lastNudgeLevel = level
      if (level <= root.lastNudgeLevel) return

      root.lastNudgeLevel = level
      nudgeProc.command = ["notify-send", "-a", "Omachron",
        Model.fmt(total) + " on screen today", Messages.outsideNudge(level)]
      nudgeProc.running = true
    }
  }

  // Changing the interval re-baselines rather than firing for every
  // milestone the new interval has already passed.
  onReminderHoursChanged: root.nudgeArmed = false

  // Insight rows the user has dismissed, as a list of stable ids. Stored
  // with the other preferences so a dismissed stat stays dismissed across
  // restarts.
  readonly property var hiddenStats: {
    var v = root.setting("hiddenStats", [])
    return Array.isArray(v) ? v : []
  }

  function setHiddenStats(list) {
    root.writeSetting("hiddenStats", Array.isArray(list) ? list : [])
  }

  // Back to shipped behaviour: show every stat, the default hide threshold,
  // the default nudge interval. Deliberately does NOT touch icon-only mode
  // (a bar layout choice, not a panel one) or the slacking overrides (those
  // are your data, not a preference).
  function resetSettings() {
    var entry = { id: root.moduleName }
    for (var key in root.settings) {
      if (key === "id") continue
      if (key === "hiddenStats" || key === "hideUnderMinutes"
          || key === "reminderHours" || key === "slackBudgetMinutes") continue
      entry[key] = root.settings[key]
    }
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // One writer for every preference, so they all persist identically.
  function writeSetting(name, value) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[name] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Persists the panel's "hide < N minutes" threshold the same way
  // icon-only mode is stored: in this widget's shell.json entry.
  function setHideUnderMinutes(minutes) {
    root.writeSetting("hideUnderMinutes", minutes)
  }

  // The bar's open-panel indicator (underline) tracks the painted label
  // width instead of a fraction of the slot, mirroring omarchy.clock. In
  // icon-only mode the glyph is painted through an OpticalGlyph so its ink
  // (not its advance box) is centred, and the mark takes that painted width
  // so it lines up with the visible glyph rather than drifting off it.
  readonly property real openPanelIndicatorWidth: {
    if (root.iconOnly && !root.vertical && iconGlyph)
      return Math.max(1, Math.round(iconGlyph.tightWidth))
    return button.labelWidth
  }
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // ---- Panel shape contract for shell.summon/hide/toggle routing ---------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "dutchster.omachron"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function status(): void {
      var p = panelLoader.item
      console.log("dutchster.omachron status: opened=" + (p ? p.opened : "no-panel")
        + " label=" + root.label + " hasActivity=" + root.hasActivity
        + " apps=" + (root.service ? root.service.appList().length : "none"))
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical
      ? ""
      : root.iconOnly
        ? root.glyph
        : root.glyph + " " + root.label + (root.label ? " today" : "")
    labelVisible: !root.vertical && !root.iconOnly
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.5
    tooltipText: root.hasActivity
      ? "Omachron \u00b7 " + root.label + " today" + root.slackLabel
      : "Omachron \u00b7 no activity yet"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleIconOnly()
      else root.togglePanel()
    }

    // Icon-only mode: the Text label is hidden (the slot still sizes off its
    // advance width) and the glyph is painted through an OpticalGlyph, which
    // shifts the Text so the glyph's ink is centred instead of sitting
    // somewhere inside its advance box.
    OpticalGlyph {
      id: iconGlyph
      visible: !root.vertical && root.iconOnly
      anchors.fill: parent
      text: root.glyph
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.foreground
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData === root.glyph
            ? Style.font.icon
            : (modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize)
          color: button.foreground
        }
      }
    }
  }
}
