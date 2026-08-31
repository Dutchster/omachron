"use strict"

// Every user-facing joke lives in lib/Messages.js, so its tests live here.
// These assert structure and rotation, never the exact wording -- the point
// of that file is that the words can be edited freely.

const { test } = require("node:test")
const assert = require("node:assert/strict")
const Messages = require("../lib/Messages.js")

test("slackVerdict scales its wording with the share", () => {
  assert.equal(Messages.slackVerdict(0, 0, true), "Nothing tracked today")
  assert.equal(Messages.slackVerdict(0, 3600000, true), "Suspiciously productive today")
  assert.equal(Messages.slackVerdict(0, 3600000, false), "Suspiciously productive")
  assert.ok(Messages.slackVerdict(180000, 3600000, true).startsWith("Basically a monk today"))
  assert.ok(Messages.slackVerdict(900000, 3600000, true).startsWith("A few honest detours"))
  assert.ok(Messages.slackVerdict(1800000, 3600000, true).startsWith("A coin flip you lost"))
  assert.ok(Messages.slackVerdict(2700000, 3600000, true).startsWith("Calling it 'research'"))
  assert.ok(Messages.slackVerdict(3600000, 3600000, true).startsWith("Absolutely cooked"))
})

test("slackVerdict is the phrase alone; the panel states the time itself", () => {
  // The hero now labels total and slacking explicitly on the line above, so
  // repeating the duration here was just saying it twice.
  assert.equal(Messages.slackVerdict(5400000, 7200000, true),
    "Calling it 'research' today")
  assert.equal(Messages.slackVerdict(5400000, 7200000, false),
    "Calling it 'research'")
})

test("slackPhrase cycles within a tier and wraps", () => {
  const total = Messages.slackPhrases.most.length
  assert.ok(total > 1, "a tier needs several phrases to rotate through")
  assert.equal(Messages.slackPhrase("most", 0), Messages.slackPhrases.most[0])
  assert.equal(Messages.slackPhrase("most", total), Messages.slackPhrases.most[0])
  assert.equal(Messages.slackPhrase("most", total + 1), Messages.slackPhrases.most[1])
  // Negative and junk variants must still land on a real phrase.
  assert.equal(Messages.slackPhrase("most", -1), Messages.slackPhrases.most[total - 1])
  assert.equal(Messages.slackPhrase("most", undefined), Messages.slackPhrases.most[0])
  assert.equal(Messages.slackPhrase("nope", 0), "")
})

test("every verdict tier has usable phrases", () => {
  for (const [tier, list] of Object.entries(Messages.slackPhrases)) {
    assert.ok(Array.isArray(list) && list.length >= 2, `${tier} needs 2+ phrases`)
    assert.equal(new Set(list).size, list.length, `${tier} has a duplicate`)
    for (const phrase of list) {
      assert.ok(phrase && phrase.trim() === phrase, `${tier}: "${phrase}" is padded`)
      // Every phrase gets " today" appended, so none may end in punctuation.
      assert.ok(!/[.!?]$/.test(phrase), `${tier}: "${phrase}" ends in punctuation`)
    }
  }
})

test("slackVerdict rotates its wording but not its numbers", () => {
  const args = [70 * 60000, 100 * 60000, true]
  const a = Messages.slackVerdict(...args, 0)
  const b = Messages.slackVerdict(...args, 1)
  assert.notEqual(a, b, "a different variant should reword the line")
  for (const line of [a, b]) assert.ok(line.endsWith("today"))
  // Variant 0 is the stable default an omitted argument must fall back to.
  assert.equal(Messages.slackVerdict(...args), a)
})

test("verdict rotation still respects the tier boundaries", () => {
  // Whatever the variant, a 95% day must never read as a monastic one.
  for (let v = 0; v < 12; v++) {
    const line = Messages.slackVerdict(95 * 60000, 100 * 60000, true, v)
    assert.ok(Messages.slackPhrases.total.some(p => line.startsWith(p)),
      `variant ${v} escaped its tier: ${line}`)
  }
})

test("consecutive nudges in one day do not repeat", () => {
  const seen = new Set()
  for (let level = 1; level <= Messages.outsideNudges.length; level++) {
    const text = Messages.outsideNudge(level)
    assert.ok(text, `level ${level} produced no nudge`)
    assert.ok(!seen.has(text), `level ${level} repeated "${text}"`)
    seen.add(text)
  }
  // Past the end it wraps rather than running out.
  assert.equal(Messages.outsideNudge(Messages.outsideNudges.length + 1),
               Messages.outsideNudge(1))
})

test("nudge text is usable as a notification body", () => {
  assert.ok(Messages.outsideNudges.length >= 5)
  for (const n of Messages.outsideNudges) {
    assert.equal(n.trim(), n, `"${n}" is padded`)
    assert.ok(n.length > 0 && n.length < 120, `"${n}" is an awkward length`)
  }
  // Junk input still yields a real string rather than undefined.
  assert.ok(Messages.outsideNudge(undefined))
  assert.ok(Messages.outsideNudge(-4))
})

test("fmtOverBudget rounds down to a number worth reading", () => {
  assert.equal(Messages.fmtOverBudget(60 * 60000), "1+ hr")
  assert.equal(Messages.fmtOverBudget(141 * 60000), "2+ hrs")
  assert.equal(Messages.fmtOverBudget(45 * 60000), "45+ min")
  assert.equal(Messages.fmtOverBudget(59 * 60000), "55+ min")
  // Under five minutes there is no round number worth quoting.
  assert.equal(Messages.fmtOverBudget(4 * 60000), "a few minutes")
  assert.equal(Messages.fmtOverBudget(0), "a few minutes")
})

test("fmtOverBudget never overstates the overage", () => {
  // Rounding up would claim more time than actually elapsed, which is the
  // one thing a figure like this must not do.
  for (let m = 0; m <= 400; m++) {
    const out = Messages.fmtOverBudget(m * 60000)
    const n = parseInt(out, 10)
    if (isNaN(n)) continue
    const claimed = out.includes("hr") ? n * 60 : n
    assert.ok(claimed <= m, `${m}m reported as "${out}"`)
  }
})

test("fmtOverBudget tolerates junk", () => {
  for (const junk of [NaN, undefined, null, -500, Infinity])
    assert.equal(typeof Messages.fmtOverBudget(junk), "string", String(junk))
})

test("budgetBlownBody pairs one quip with one round number", () => {
  const body = Messages.budgetBlownBody(141 * 60000, 0)
  assert.equal(body, Messages.budgetQuips[0] + " \u00b7 2+ hrs over.")
  // The variant cycles and wraps rather than running out.
  assert.notEqual(Messages.budgetBlownBody(0, 0), Messages.budgetBlownBody(0, 1))
  assert.equal(Messages.budgetBlownBody(0, Messages.budgetQuips.length),
               Messages.budgetBlownBody(0, 0))
  assert.equal(Messages.budgetBlownBody(0, -1),
               Messages.budgetBlownBody(0, Messages.budgetQuips.length - 1))
})

test("budget quips are usable as a notification body", () => {
  assert.ok(Messages.budgetQuips.length >= 4)
  assert.equal(new Set(Messages.budgetQuips).size, Messages.budgetQuips.length)
  for (const q of Messages.budgetQuips) {
    assert.equal(q.trim(), q)
    // A quip is followed by " · <amount> over.", so it must not end in
    // punctuation of its own.
    assert.ok(!/[.!?]$/.test(q), q)
  }
})
