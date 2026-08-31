// Every user-facing joke in the plugin, in one place.
//
// This is the file to edit when you want to change what Omachron says: the
// verdict on your day, the go-outside reminders, and the line that lands
// when a slacking budget is blown. Nothing here reads any state -- each
// function takes what it needs and returns a string.
//
// Unlike the JSON data files, this needs no inlined copy: QML imports a .js
// file directly, so Panel.qml and BarWidget.qml pull it in alongside
// Model.js and there is only ever one copy of these words.
//
//   import "lib/Messages.js" as Messages
//   Messages.slackVerdict(slackMs, totalMs, isToday, variant)
//
// Every message rotates through a `variant` the caller supplies rather than
// picking at random: these run inside QML bindings that re-evaluate as the
// clock ticks, and a random pick would reshuffle mid-sentence.

// Verdict phrasing, tiered by how much of the day went to slacking. Several
// per tier so the panel can rotate through them instead of repeating one
// line forever. Index 0 is the default, so a caller that passes no variant
// always gets the same phrase -- rotation is opt-in, never ambient
// randomness: this runs inside a QML binding that re-evaluates as the clock
// ticks, so a random pick here would reshuffle every few seconds.
var SLACK_PHRASES = {
  // Nothing recorded at all.
  none: [
    "Nothing tracked",
    "A clean slate",
    "No data, no evidence",
    "Nothing to report",
    "Nothing on the record"
  ],
  // Tracked, but not one minute of it counted as slacking.
  clean: [
    "Suspiciously productive",
    "Not one wasted minute",
    "Allegedly flawless",
    "Zero detours logged",
    "Unnervingly focused"
  ],
  trace: [                      // under 15%
    "Basically a monk",
    "Practically monastic",
    "A rounding error of slack",
    "Almost suspiciously good",
    "Barely a scroll"
  ],
  some: [                       // under 35%
    "A few honest detours",
    "Some scenic routes taken",
    "Nothing HR would flag",
    "Perfectly excusable",
    "Nothing to be ashamed of"
  ],
  half: [                       // under 60%
    "A coin flip you lost",
    "Committed to neither",
    "The tabs are winning",
    "Aggressively neutral",
    "Nailed roughly half of it"
  ],
  most: [                       // under 85%
    "Calling it 'research'",
    "Technically still working",
    "The tabs won",
    "Productivity was optional",
    "Mostly vibes"
  ],
  total: [                      // 85% and up
    "Absolutely cooked",
    "Total collapse",
    "The algorithm won",
    "You failed",
    "No notes, just scrolling"
  ]
}

// Phrase for a tier. `variant` cycles within the tier and wraps, so a caller
// can just keep incrementing a counter and never mind the list length.
function slackPhrase(tier, variant) {
  var list = SLACK_PHRASES[tier]
  if (!list || !list.length) return ""
  var n = Math.floor(Number(variant) || 0) % list.length
  if (n < 0) n += list.length
  return list[n]
}

// The verdict line under the day total, worded like fmtWords so both read
// in the same voice. `variant` rotates the phrasing within its tier.
function slackVerdict(slackMs, totalMs, isToday, variant) {
  var when = isToday ? " today" : ""
  var ms = Math.max(0, Math.round(Number(slackMs) || 0))
  var total = Math.max(0, Math.round(Number(totalMs) || 0))
  if (total <= 0) return slackPhrase("none", variant) + when
  if (ms <= 0) return slackPhrase("clean", variant) + when
  var pct = 100 * ms / total
  var tier
  if (pct < 15) tier = "trace"
  else if (pct < 35) tier = "some"
  else if (pct < 60) tier = "half"
  else if (pct < 85) tier = "most"
  else tier = "total"
  return slackPhrase(tier, variant) + when
}

// ---- Go-outside nudges ---------------------------------------------------

// Fired as a desktop notification once a day's screen time crosses each
// multiple of the user's chosen interval. Kept here rather than in QML so
// the wording is testable and the phrasing lives with the rest of the
// panel's voice.
var OUTSIDE_NUDGES = [
  "The sun is still out there. Allegedly.",
  "This is your screen asking for a break. Awkward, but here we are.",
  "Somewhere, a chair is not being sat in.",
  "Go look at something more than two feet away.",
  "Your eyes have a maximum focal length. Use it.",
  "Touch grass. Any grass. Grass of your choosing.",
  "The outside is rendering at an incredible frame rate right now.",
  "Stand up. Yes, actually. It'll take nine seconds.",
  "Consider: a window. Or even a door.",
  "You have been staring at this for a while. Just saying."
]

// Nudge text for a given milestone. `level` is the reminderLevel that
// triggered it, so consecutive nudges in one day never repeat.
function outsideNudge(level) {
  var n = Math.floor(Number(level) || 0)
  if (n < 0) n = -n
  return OUTSIDE_NUDGES[n % OUTSIDE_NUDGES.length]
}

// Overage at notification precision, not stopwatch precision. "2h 21m
// over" invites arithmetic nobody wants at that moment; "2+ hrs over" is
// the same news. Always rounds DOWN, so the figure never overstates what
// actually happened.
function fmtOverBudget(ms) {
  var mins = Math.floor(Math.max(0, Number(ms) || 0) / 60000)
  if (!isFinite(mins) || mins < 5) return "a few minutes"
  if (mins < 60) return (Math.floor(mins / 5) * 5) + "+ min"
  var hours = Math.floor(mins / 60)
  return hours + "+ hr" + (hours === 1 ? "" : "s")
}

var BUDGET_QUIPS = [
  "Not even close",
  "Bold strategy",
  "The budget never stood a chance",
  "We do not talk about the budget",
  "Ambitious, in the wrong direction",
  "That went well",
  "The budget has left the chat",
  "Setting records today"
]

// Body for the blown-budget notification: one quip, one round number.
function budgetBlownBody(overMs, variant) {
  var list = BUDGET_QUIPS
  var n = Math.floor(Number(variant) || 0) % list.length
  if (n < 0) n += list.length
  return list[n] + " \u00b7 " + fmtOverBudget(overMs) + " over."
}

// QML's JS engine never defines `module`, so this guard is inert there.
if (typeof module !== "undefined" && module && module.exports) {
  module.exports = {
    slackPhrases: SLACK_PHRASES,
    slackPhrase: slackPhrase,
    slackVerdict: slackVerdict,
    outsideNudges: OUTSIDE_NUDGES,
    outsideNudge: outsideNudge,
    budgetQuips: BUDGET_QUIPS,
    fmtOverBudget: fmtOverBudget,
    budgetBlownBody: budgetBlownBody
  }
}
