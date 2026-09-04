const assert = require("assert")
const { load, deepEqual } = require("./load")

const model = load("account/Model.js")

// The mailboxes moved to Provider.js along with everything else that differs
// between mail services; tests/test_provider.js covers them there.

// ------------------------------------------------------------ setup state

assert.strictEqual(model.setupState({ toolsPresent: false }), "tools_missing")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: false }), "no_credentials")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signedIn: false }), "signed_out")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signingIn: true }), "signing_in")
assert.strictEqual(model.setupState({ toolsPresent: true, credentialsPresent: true, signedIn: true }), "ready")
assert.strictEqual(model.setupState(null), "tools_missing")

// Missing tools have to be named. "Something is missing" is not actionable.
assert.ok(model.setupDetail("tools_missing", ["socat", "secret-tool"]).indexOf("socat, secret-tool") > 0)
assert.strictEqual(model.setupHeadline("ready"), "")
assert.strictEqual(model.setupHeadline("signed_out"), "Sign in to Gmail",
  "an account with no provider recorded is a Gmail account")
assert.strictEqual(model.setupHeadline("signed_out", "IMAP"), "Sign in to IMAP")
assert.strictEqual(model.setupHeadline("no_credentials", "IMAP", "password"),
  "Add this mailbox", "only one of the two sends anyone to a Cloud console")
assert.strictEqual(model.setupHeadline("no_credentials", "Gmail", "oauth"),
  "Connect a Google Cloud project")
// The unavailable detail comes from the provider, because only it knows why.
assert.strictEqual(model.setupDetail("unavailable", [], "no API yet", "HEY"), "no API yet")
assert.strictEqual(model.setupActionLabel("unavailable", "HEY"), "",
  "there is no button that would help")
assert.strictEqual(model.setupActionLabel("ready"), "")
// The label opens a multi-step page, which is what the trailing ellipsis says.
assert.ok(model.setupActionLabel("no_credentials").endsWith("..."))
assert.strictEqual(model.setupActionLabel("signing_in"), "Cancel")
assert.ok(model.setupActionLabel("no_credentials", "IMAP", "password").endsWith("..."))

// Rebuilding an account briefly leaves the service with no current host. The
// edit page keeps the provider it opened for instead of following the
// service's temporary Gmail fallback.
assert.strictEqual(model.setupProvider("imap", "gmail"), "imap")
assert.strictEqual(model.setupProvider("", "imap"), "imap")
// An IMAP sign-in never opens a browser, so it must not say it will.
assert.ok(model.setupDetail("signing_in", [], "", "IMAP", "password").indexOf("browser") < 0)
assert.ok(model.setupDetail("signing_in", [], "", "Gmail", "oauth").indexOf("browser") > 0)

// ------------------------------------------------------- list consistency
//
// After an action a row either belongs in the current mailbox or it does not.
// Getting this wrong either strands a row that is gone from the server or
// hides one that is still there.

assert.strictEqual(model.survivesAction("inbox", "archive"), false)
assert.strictEqual(model.survivesAction("all", "archive"), true, "All mail still contains an archived message")
assert.strictEqual(model.survivesAction("starred", "archive"), true)
assert.strictEqual(model.survivesAction("unread", "markRead"), false)
assert.strictEqual(model.survivesAction("inbox", "markRead"), true)
assert.strictEqual(model.survivesAction("starred", "unstar"), false)
assert.strictEqual(model.survivesAction("inbox", "unstar"), true)
assert.strictEqual(model.survivesAction("inbox", "trash"), false)
assert.strictEqual(model.survivesAction("trash", "trash"), true)
assert.strictEqual(model.survivesAction("trash", "untrash"), false)

deepEqual(model.labelChangesFor("archive"), { add: [], remove: ["INBOX"] })
deepEqual(model.labelChangesFor("star"), { add: ["STARRED"], remove: [] })
assert.strictEqual(model.labelChangesFor("trash"), null, "trash is its own endpoint, not a label change")

// The optimistic update has to move the derived flags too, or a row shows a
// filled star with `starred: false` underneath it until the next refresh.
const row = { id: "a", labelIds: ["INBOX", "UNREAD"], unread: true, starred: false, inInbox: true }
const read = model.applyLabelChange(row, "markRead")
assert.strictEqual(read.unread, false)
deepEqual(read.labelIds, ["INBOX"])
assert.strictEqual(row.unread, true, "the original row is left alone")

const starred = model.applyLabelChange(row, "star")
assert.strictEqual(starred.starred, true)
deepEqual(starred.labelIds, ["INBOX", "UNREAD", "STARRED"])
// Starring twice must not add the label twice.
deepEqual(model.applyLabelChange(starred, "star").labelIds, ["INBOX", "UNREAD", "STARRED"])
assert.strictEqual(model.applyLabelChange(row, "archive").inInbox, false)
assert.strictEqual(model.applyLabelChange(null, "star"), null)

// ------------------------------------------------------------ list edits

assert.strictEqual(model.showInitialListSkeleton(true, 0), true,
  "an empty initial fetch uses rows shaped like the list")
assert.strictEqual(model.showInitialListSkeleton(true, 3), false,
  "pagination keeps the messages already on screen")
assert.strictEqual(model.showInitialListSkeleton(false, 0), false,
  "an empty result is not still loading")
assert.strictEqual(model.showListFooter(0), false,
  "an empty state must not compete with pagination controls")
assert.strictEqual(model.showListFooter(1), true,
  "loaded messages retain their result summary and pagination")

const list = [{ id: "a", unread: true }, { id: "b", unread: false }, { id: "c", unread: true }]
deepEqual(model.removeById(list, "b").map(entry => entry.id), ["a", "c"])
deepEqual(model.removeById(list, "zzz").map(entry => entry.id), ["a", "b", "c"])
deepEqual(model.replaceById(list, { id: "b", unread: true }).map(entry => entry.unread), [true, true, true])
assert.strictEqual(model.indexById(list, "c"), 2)
assert.strictEqual(model.indexById(list, "zzz"), -1)
assert.strictEqual(model.indexById(null, "a"), -1)
assert.strictEqual(model.unreadCount(list), 2)
assert.strictEqual(model.unreadCount([]), 0)

// ---------------------------------------------------------------- the bar

assert.strictEqual(model.badgeText(0), "")
assert.strictEqual(model.badgeText(7), "7")
assert.strictEqual(model.badgeText(99), "99")
assert.strictEqual(model.badgeText(100), "99+")
assert.strictEqual(model.badgeText(1500, 99), "99+")
assert.strictEqual(model.badgeText(-3), "")

assert.strictEqual(model.barTooltip("ready", "me@example.com", 0), "me@example.com · No unread mail")
assert.strictEqual(model.barTooltip("ready", "me@example.com", 1), "me@example.com · 1 unread message")
assert.strictEqual(model.barTooltip("ready", "me@example.com", 4), "me@example.com · 4 unread messages")
assert.strictEqual(model.barTooltip("ready", "", 2), "Gmail · 2 unread messages")
assert.strictEqual(model.barTooltip("signed_out", "me@example.com", 9), "Gmail · Sign in to Gmail")
assert.strictEqual(model.barTooltip("signed_out", "me@example.com", 9, "IMAP"),
  "IMAP · Sign in to IMAP")
assert.strictEqual(model.barTooltip("ready", "", 2, "IMAP"), "IMAP · 2 unread messages")

// --------------------------------------------------------------- new mail
//
// The first load after the shell starts must not fire a notification for every
// message already sitting in the inbox, so arrivals only count once the seen
// set has been primed by that first load.

const inbox = [
  { id: "a", unread: true, inInbox: true, subject: "one" },
  { id: "b", unread: false, inInbox: true, subject: "two" },
  { id: "c", unread: true, inInbox: true, subject: "three" },
  { id: "d", unread: true, inInbox: false, subject: "archived elsewhere" }
]

deepEqual(model.newArrivals(inbox, {}, false), [], "nothing fires before priming")
deepEqual(model.newArrivals(inbox, { a: true }, true).map(entry => entry.id), ["c"])
deepEqual(model.newArrivals(inbox, { a: true, c: true }, true), [])
deepEqual(model.newArrivals([], {}, true), [])

assert.strictEqual(model.notificationBody({ subject: "Invoice", snippet: "Due Friday" }), "Invoice\nDue Friday")
assert.strictEqual(model.notificationBody({ subject: "Invoice", snippet: "" }), "Invoice")
assert.strictEqual(model.notificationBody(null), "")
assert.ok(model.notificationBody({ subject: "s", snippet: "x".repeat(400) }).length < 160)

// ------------------------------------------------------------- formatting

assert.strictEqual(model.resultSummary([], 0, false), "No messages")
assert.strictEqual(model.resultSummary([{}], 1, false), "1 message")
assert.strictEqual(model.resultSummary([{}, {}], 2, false), "2 messages")
assert.strictEqual(model.resultSummary([{}, {}], 87, true), "2 of about 87")
// Gmail's estimate can come back lower than the page it just returned.
assert.strictEqual(model.resultSummary([{}, {}, {}], 1, true), "3 of about 3")

assert.strictEqual(model.statusSummary("Checking for mail"), "Checking for mail")
assert.strictEqual(model.statusSummary("Synced just now"), "Synced just now")
assert.strictEqual(model.statusSummary(""), "")

assert.strictEqual(model.truncate("short", 20), "short")
assert.strictEqual(model.truncate("a much longer string", 10), "a much lo…")
assert.strictEqual(model.pluralize(1, "message"), "1 message")
assert.strictEqual(model.pluralize(0, "message"), "0 messages")

// A notification is markup to the daemons that draw it, and its two strings are
// arguments to notify-send. Neither is a place for a sender's angle brackets or
// for a display name that starts with a dash.
{
  const crafted = {
    subject: "<img src=\"http://tracker.example.com/p.gif\">",
    snippet: "a & b",
    from: { display: "-u critical" }
  }
  assert.ok(model.notificationBody(crafted).indexOf("<img") < 0)
  assert.ok(model.notificationBody(crafted).indexOf("&amp;") > 0)
  assert.strictEqual(model.notificationTitle(crafted), "u critical")
  assert.strictEqual(model.notificationTitle({ from: { display: "" } }), "New message")
  assert.strictEqual(model.notificationTitle(null), "New message")
}

// ------------------------------------------------------------- list cursor

// The cursor moves relative to itself. It used to be anchored to `selectedId`
// — the message the reader has open — which pinned it: nothing is open in list
// view, so every step resolved to row 0, and in the reader the anchor never
// advanced, so the cursor moved once and then stopped.
{
  const rows = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]

  assert.strictEqual(model.cursorAfterOffset(rows, "", 1), "a",
    "with no cursor yet, j starts at the top")
  assert.strictEqual(model.cursorAfterOffset(rows, "", -1), "d",
    "with no cursor yet, k starts at the bottom")

  // The regression this exists for: pressing j repeatedly keeps moving.
  assert.strictEqual(model.cursorAfterOffset(rows, "a", 1), "b")
  assert.strictEqual(model.cursorAfterOffset(rows, "b", 1), "c")
  assert.strictEqual(model.cursorAfterOffset(rows, "c", 1), "d")
  assert.strictEqual(model.cursorAfterOffset(rows, "d", 1), "d",
    "the last row is where moving down stops")

  assert.strictEqual(model.cursorAfterOffset(rows, "c", -1), "b")
  assert.strictEqual(model.cursorAfterOffset(rows, "a", -1), "a",
    "the first row is where moving up stops")

  assert.strictEqual(model.cursorAfterOffset([], "a", 1), "",
    "an empty list has nowhere to go")
  assert.strictEqual(model.cursorAfterOffset(rows, "gone", 1), "a",
    "a cursor whose message left the list starts over rather than sticking")
  assert.strictEqual(model.cursorAfterOffset(rows, "a", 0), "a",
    "a zero step is a no-op, not a jump to the top")
}

// --------------------------------------------------- keeping the cursor seen

// The list is a Column in a Flickable rather than a ListView — the panel
// already owns a scroller — so there is no positionViewAtIndex, and keyboard
// movement has to say where the scroller goes itself.
{
  // A 100-tall viewport over 500 of content, rows 20 tall, 4px of margin.
  const view = 100
  const content = 500
  const pad = 4

  assert.strictEqual(
    model.contentYToReveal(0, view, 40, 20, content, pad), 0,
    "a row already on screen does not move the list under the reader")

  assert.strictEqual(
    model.contentYToReveal(0, view, 90, 20, content, pad), 14,
    "a row off the bottom scrolls just far enough, plus the margin")

  assert.strictEqual(
    model.contentYToReveal(200, view, 180, 20, content, pad), 176,
    "a row off the top scrolls back to it, plus the margin")

  assert.strictEqual(
    model.contentYToReveal(10, view, 0, 20, content, pad), 0,
    "the top of the list is as far up as it goes: no negative offset")

  assert.strictEqual(
    model.contentYToReveal(380, view, 480, 20, content, pad), 400,
    "the bottom clamps to the last screenful rather than scrolling past it")

  assert.strictEqual(
    model.contentYToReveal(0, view, 40, 300, content, pad), 36,
    "a row taller than the viewport shows its top rather than its bottom")

  assert.strictEqual(
    model.contentYToReveal(0, 500, 40, 20, 400, pad), 0,
    "content shorter than the viewport never scrolls")
}


// ------------------------------------------- the cursor outliving its message

// Two ways a cursor stops pointing at anything: the row it is on is acted on
// and leaves, or the whole list is replaced under it by a mailbox switch, a
// search, or a refresh. Both used to leave the cursor on a message that is no
// longer there, and cursorAfterOffset restarts at the top from that — so one
// archive sent the next j back to the first row.
{
  const rows = [{ id: "a" }, { id: "b" }, { id: "c" }]

  // Acting on a row: the cursor takes the row's place, which is the one below.
  assert.strictEqual(model.cursorAfterRemoval(rows, "a"), "b")
  assert.strictEqual(model.cursorAfterRemoval(rows, "b"), "c")
  // Except at the end, where there is nothing below and the one above is where
  // the eye already is.
  assert.strictEqual(model.cursorAfterRemoval(rows, "c"), "b")
  assert.strictEqual(model.cursorAfterRemoval([{ id: "only" }], "only"), "",
    "emptying the list leaves no cursor to hold")
  assert.strictEqual(model.cursorAfterRemoval(rows, "gone"), "",
    "a cursor that is already adrift has no neighbour to inherit")
  assert.strictEqual(model.cursorAfterRemoval([], "a"), "")

  // A list replaced underneath: keep the cursor if its message survived the
  // reload, otherwise start at the top.
  assert.strictEqual(model.cursorAfterReload(rows, "b"), "b",
    "a refresh that kept the message keeps the cursor")
  assert.strictEqual(model.cursorAfterReload(rows, "gone"), "a",
    "a mailbox switch lands on the first row rather than nowhere")
  assert.strictEqual(model.cursorAfterReload(rows, ""), "a",
    "and so does a list arriving for the first time")
  assert.strictEqual(model.cursorAfterReload([], "b"), "",
    "an empty mailbox has no row to sit on")
}

// One numbered list over the rail: mailboxes first, then the labels the server
// reported, and no number at all past the tenth row.
{
  const boxes = [
    { key: "inbox", label: "Inbox" },
    { key: "unread", label: "Unread" },
    { key: "sent", label: "Sent" }
  ]
  const labels = [
    { id: "SYS", name: "Category", rawName: "Category", system: true },
    { id: "L1", name: "Work", rawName: "Work" },
    { id: "L2", name: "Bills", rawName: "Bills" }
  ]
  const slots = model.sidebarSlots(boxes, labels, 10)
  assert.strictEqual(slots.length, 5, "system labels are not rows and get no number")
  assert.strictEqual(slots[0].kind, "mailbox")
  assert.strictEqual(slots[0].key, "inbox")
  assert.strictEqual(slots[3].kind, "label")
  assert.strictEqual(slots[3].id, "L1")
  assert.strictEqual(slots[3].name, "Work", "the name a provider selects a label by")

  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "inbox"), 1)
  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "sent"), 3)
  assert.strictEqual(model.slotNumberOf(slots, "label", "L2"), 5)
  assert.strictEqual(model.slotNumberOf(slots, "label", "SYS"), 0)
  assert.strictEqual(model.slotNumberOf(slots, "mailbox", "L1"), 0,
    "a key and an id are not the same handle")
  assert.strictEqual(model.slotNumberOf([], "mailbox", "inbox"), 0)

  // The ceiling is where a row stops having a key, not where the rail stops.
  const many = []
  for (let i = 0; i < 14; i++) many.push({ id: "L" + i, name: "n" + i, rawName: "n" + i })
  assert.strictEqual(model.sidebarSlots(boxes, many, 10).length, 10)
  assert.strictEqual(model.slotNumberOf(model.sidebarSlots(boxes, many, 10), "label", "L7"), 0,
    "past the tenth row there is no digit left to offer")
  assert.strictEqual(model.sidebarSlots(null, null, 10).length, 0)
}

// The switcher's cursor wraps where the message list clamps: a menu of two or
// three rows that stopped at the bottom would make `j` do nothing on the row
// you use most.
assert.strictEqual(model.wrappedIndex(0, 1, 3), 1)
assert.strictEqual(model.wrappedIndex(2, 1, 3), 0, "past the last row comes back to the first")
assert.strictEqual(model.wrappedIndex(0, -1, 3), 2, "and backwards off the top wraps too")
assert.strictEqual(model.wrappedIndex(1, 0, 3), 1)
assert.strictEqual(model.wrappedIndex(0, 1, 1), 0, "one mailbox has nowhere to go")
assert.strictEqual(model.wrappedIndex(0, 1, 0), 0, "and no mailboxes must not divide by zero")
assert.strictEqual(model.wrappedIndex(-1, 1, 3), 0)


// ------------------------------------------------------------- reading zoom

// A step lands on a twentieth, so the same scroll back returns to where it was
// and a saved zoom reads back as the one that was set.
assert.strictEqual(model.zoomAfterStep(1, 0.1), 1.1)
assert.strictEqual(model.zoomAfterStep(1.1, -0.1), 1)
assert.strictEqual(model.zoomAfterStep(1.37, 0), 1.35)
// The bounds hold however hard the wheel is turned.
assert.strictEqual(model.zoomAfterStep(2.5, 0.1), 2.5)
assert.strictEqual(model.zoomAfterStep(0.6, -0.1), 0.6)
assert.strictEqual(model.zoomAfterStep(99, 0), 2.5)

// What comes back off disk is a file somebody could have edited by hand, and
// the answer to anything that is not a number is the size it shipped at.
assert.strictEqual(model.clampZoom(undefined), 1)
assert.strictEqual(model.clampZoom(null), 1)
assert.strictEqual(model.clampZoom("nonsense"), 1)
assert.strictEqual(model.clampZoom(0), 0.6, "but zero is a number, and clamps")
assert.strictEqual(model.clampZoom("1.5"), 1.5, "including one written as text")

// Every scaled piece of text asks for its size here rather than doing the
// arithmetic itself, so the floor is applied once instead of in eleven places.
assert.strictEqual(model.zoomedFontSize(12, 1), 12)
assert.strictEqual(model.zoomedFontSize(12, 2.5), 30)
assert.strictEqual(model.zoomedFontSize(13, 1.15), 15, "and it rounds")

// The floor is the reason this exists. At the bottom of the range a caption
// would round to 6px and stop being text, so nothing drawn goes below 7 —
// including the smallest token at the smallest zoom.
assert.strictEqual(model.zoomedFontSize(9, 0.6), 7)
assert.strictEqual(model.zoomedFontSize(1, 0.6), 7)

// A zoom that came off a hand-edited file is clamped on the way through, the
// same as anywhere else, and a size that is not a number draws at the floor
// rather than vanishing or throwing.
assert.strictEqual(model.zoomedFontSize(12, 99), 30, "the ceiling still holds")
assert.strictEqual(model.zoomedFontSize(12, "nonsense"), 12, "and 1.0 is the answer to nonsense")
assert.strictEqual(model.zoomedFontSize(undefined, 1), 7)
assert.strictEqual(model.zoomedFontSize(0, 1), 7)
assert.strictEqual(model.zoomedFontSize(-4, 1), 7)

// ------------------------------------------------- identity across accounts
//
// An IMAP UID is unique only within a folder and a Gmail id only within an
// account, so a unified list holding several accounts can hold the same id
// twice. The pair that prompted this were two mailboxes on one server with
// overlapping UID ranges — fetching one account's UID against the other
// answered with a protocol preamble instead of a message. Matching on the id
// alone would act on whichever row came first.

const collide = [
  { id: "12100:INBOX", accountId: "imap:a@example.org", subject: "theirs" },
  { id: "12100:INBOX", accountId: "imap:b@example.org", subject: "mine" }
]

assert.strictEqual(model.indexById(collide, "12100:INBOX", "imap:b@example.org"), 1,
  "the account decides which of two identical ids is meant")
assert.strictEqual(model.indexById(collide, "12100:INBOX", "imap:a@example.org"), 0)
assert.strictEqual(model.indexById(collide, "12100:INBOX", "imap:c@example.org"), -1,
  "an id that exists under another account is not a match")

// Removing one leaves the other alone. This is the archive-the-wrong-message
// case, and the one worth being certain about.
const left = model.removeById(collide, "12100:INBOX", "imap:a@example.org")
assert.strictEqual(left.length, 1)
assert.strictEqual(left[0].accountId, "imap:b@example.org")
assert.strictEqual(left[0].subject, "mine")

// Replacing one likewise.
const swapped = model.replaceById(collide,
  { id: "12100:INBOX", accountId: "imap:b@example.org", subject: "changed" })
assert.strictEqual(swapped[0].subject, "theirs", "the other account is untouched")
assert.strictEqual(swapped[1].subject, "changed")

// No account named means the single-account list, where the id is unambiguous
// by construction: it matches the first of that id, as it always did.
assert.strictEqual(model.indexById(collide, "12100:INBOX"), 0)
assert.strictEqual(model.indexById(collide, "12100:INBOX", ""), 0)

// A summary cached before the field existed answers to whatever account asks,
// so an upgrade keeps working from the cache it already has rather than
// showing a list nothing can act on.
const untagged = [{ id: "7:INBOX", subject: "old cache" }]
assert.strictEqual(model.indexById(untagged, "7:INBOX", "imap:a@example.org"), 0)
assert.strictEqual(model.removeById(untagged, "7:INBOX", "imap:a@example.org").length, 0)

// --------------------------------------------------------- spreading load
//
// Several mailboxes on one server open their connections in the same tick, and
// a server that rations them refuses some outright. The poll already spread
// itself; the window-open and startup loads did not, and they are the bigger
// burst — a profile read, a send-as read, a count and a list load per account.

const spreadIds = ["imap:a@example.org", "imap:b@example.org", "imap:c@example.org",
  "imap:d@example.org", "imap:e@example.org"]

// Stable across restarts, because it is derived from the id rather than drawn
// at random: the same mailbox waits the same fraction every time, which is
// what makes a refused connection reproducible.
for (const id of spreadIds) {
  assert.strictEqual(model.openOffsetMs(id), model.openOffsetMs(id))
  assert.strictEqual(model.pollOffsetMs(id, 120), model.pollOffsetMs(id, 120))
}

// Bounded. The poll's offset is a quarter of the interval, so no mailbox is
// polled meaningfully less often than any other.
for (const id of spreadIds) {
  const poll = model.pollOffsetMs(id, 120)
  assert.ok(poll >= 0 && poll < 120 * 250,
    "the poll offset stays inside a quarter of the interval")
  const open = model.openOffsetMs(id)
  assert.ok(open >= 0 && open < 1000,
    "the open offset stays under a second, because somebody is waiting on it")
}

// And they actually spread: five mailboxes on one host must not land together.
{
  const offsets = spreadIds.map(function(id) { return model.openOffsetMs(id) })
  const distinct = {}
  for (const value of offsets) distinct[value] = true
  assert.strictEqual(Object.keys(distinct).length, spreadIds.length,
    "five accounts get five different open offsets: " + offsets.join(", "))

  // Spread across the range rather than clustered in one corner of it.
  offsets.sort(function(a, b) { return a - b })
  assert.ok(offsets[offsets.length - 1] - offsets[0] > 200,
    "and they are spread across the window, not bunched: " + offsets.join(", "))
}

// An account with no id yet is a mailbox still being added. It has nothing to
// derive an offset from and nothing to collide with, so it waits for nothing.
assert.strictEqual(model.openOffsetMs(""), 0)
assert.strictEqual(model.pollOffsetMs("", 120), 0)
assert.strictEqual(model.openOffsetMs(null), 0)

// A refresh interval of zero must not divide by it or return NaN, which would
// be an interval Qt reads as "never".
assert.strictEqual(model.pollOffsetMs("imap:a@example.org", 0), 0)
assert.ok(isFinite(model.pollOffsetMs("imap:a@example.org", 0)))

// -------------------------------------------------------- rebuilding a list
//
// `messages` is a plain array bound to a Repeater, so a new array identity
// destroys and recreates every delegate — about twenty-seven objects a row,
// three of them Canvas icons and three tooltip Popups. A poll that found
// nothing new was rebuilding the whole list anyway, once per account per
// refresh, and in a merged view that is N times over.

function summaryRow(over) {
  const base = {
    id: "5:INBOX", accountId: "a", subject: "Hello", snippet: "there",
    date: new Date("2026-09-01T10:00:00Z"), unread: true, starred: false,
    from: { email: "sender@example.org", displayName: "Sender" },
    labelIds: ["INBOX", "UNREAD"]
  }
  const out = {}
  for (const key in base) out[key] = base[key]
  for (const key in (over || {})) out[key] = over[key]
  return out
}

// The everyday case: the same message fetched again, as a different object.
assert.strictEqual(model.sameList([summaryRow()], [summaryRow()]), true,
  "a re-fetched but unchanged list is not worth assigning")

// Anything a row draws, or anything that decides where it belongs.
assert.strictEqual(model.sameList([summaryRow()], [summaryRow({ unread: false })]), false)
assert.strictEqual(model.sameList([summaryRow()], [summaryRow({ starred: true })]), false)
assert.strictEqual(model.sameList([summaryRow()], [summaryRow({ subject: "Other" })]), false)
assert.strictEqual(model.sameList([summaryRow()], [summaryRow({ snippet: "else" })]), false)
assert.strictEqual(model.sameList([summaryRow()],
  [summaryRow({ date: new Date("2026-09-02T10:00:00Z") })]), false)
assert.strictEqual(model.sameList([summaryRow()], [summaryRow({ accountId: "b" })]), false)
assert.strictEqual(model.sameList([summaryRow()],
  [summaryRow({ from: { email: "other@example.org", displayName: "Sender" } })]), false,
  "a different sender is a different row even under the same name")
assert.strictEqual(model.sameList([summaryRow()],
  [summaryRow({ labelIds: ["INBOX"] })]), false,
  "the labels decide whether an action leaves the row in this mailbox")

// What a row does not draw does not count. `time` and `fullTime` are derived
// from `date`, and every load recomputes them against a fresh `now`.
assert.strictEqual(model.sameList([summaryRow({ time: "2h" })],
  [summaryRow({ time: "3h" })]), true)
assert.strictEqual(model.sameList([summaryRow({ sizeEstimate: 100 })],
  [summaryRow({ sizeEstimate: 200 })]), true)

// Length and order both count.
assert.strictEqual(model.sameList([summaryRow()], []), false)
assert.strictEqual(model.sameList(
  [summaryRow({ id: "1:INBOX" }), summaryRow({ id: "2:INBOX" })],
  [summaryRow({ id: "2:INBOX" }), summaryRow({ id: "1:INBOX" })]), false)
assert.strictEqual(model.sameList([], []), true)
assert.strictEqual(model.sameList(null, undefined), true)

// The date is a Date, and every load builds a fresh one out of a fresh
// payload, so two of them are never `===`. This is the assertion that keeps
// the comparison from being inert: an `instanceof Date` check would be false
// here — the vm context these tests run the module in has its own Date — and
// would report every list as changed while looking correct.
assert.strictEqual(model.sameRow(
  summaryRow({ date: new Date("2026-09-01T10:00:00Z") }),
  summaryRow({ date: new Date("2026-09-01T10:00:00Z") })), true,
  "two Dates for one instant are the same date")
assert.strictEqual(model.sameRow(
  summaryRow({ date: new Date("bad") }),
  summaryRow({ date: new Date("also bad") })), true,
  "and two invalid dates are the same absence of one")
assert.strictEqual(model.sameRow(
  summaryRow({ date: new Date("2026-09-01T10:00:00Z") }),
  summaryRow({ date: null })), false)

// A hydrated cache row has fewer fields than one off the wire. Absent on both
// sides is the same, so a cache-painted list is not rebuilt by the live answer
// purely for having been hydrated.
assert.strictEqual(model.sameRow({ id: "1", accountId: "a" },
  { id: "1", accountId: "a", starred: undefined }), true)

// -------------------------------------------------------------- the seam
//
// IMAP has no page token: it re-runs the whole SEARCH and slices
// `[offset, offset + limit]`. A message arriving between two pages pushes the
// boundary down, so the first row of the new page is the last row of the old
// one — and nothing deduplicated it. In a merged list there is one seam per
// account.
{
  const loaded = [summaryRow({ id: "9:INBOX" }), summaryRow({ id: "8:INBOX" })]
  const page = [summaryRow({ id: "8:INBOX" }), summaryRow({ id: "7:INBOX" })]
  deepEqual(model.appendPage(loaded, page).map(function(m) { return m.id }),
    ["9:INBOX", "8:INBOX", "7:INBOX"], "the seam row appears once")

  // Deduplicated on the pair, not the id: the same UID under another account
  // is a different message and belongs in the list.
  const mixed = model.appendPage(
    [summaryRow({ id: "5:INBOX", accountId: "a" })],
    [summaryRow({ id: "5:INBOX", accountId: "b" })])
  assert.strictEqual(mixed.length, 2,
    "one id under two accounts is two messages")

  // A page that repeats itself entirely adds nothing.
  const same = [summaryRow({ id: "9:INBOX" })]
  assert.strictEqual(model.appendPage(same, same).length, 1)
  deepEqual(model.appendPage([], page).map(function(m) { return m.id }),
    ["8:INBOX", "7:INBOX"])
  assert.strictEqual(model.appendPage(null, null).length, 0)
}

// ------------------------------------------------------- opening a message
//
// A cached open used to do the whole fetch anyway and paint nothing early:
// the cache set the body properties but never the summary the reader gates
// every visible part on, so the reader drew its skeleton until the network
// answered — one IMAP process, TLS handshake, LOGIN, SELECT and a
// `BODY.PEEK[]` of the entire message, to arrive at what was already on disk.

{
  const painted = model.detailFetchPlan(true, true)
  assert.strictEqual(painted.paintNow, true,
    "a hit whose row is still listed paints at once")
  assert.strictEqual(painted.whole, false,
    "and asks only for what can have changed: the read flag")
  assert.strictEqual(painted.reportFailure, false,
    "a failure over a message already drawn is a notice about nothing visible")

  // A hit with no row is a message the list no longer holds, so there is no
  // summary to draw and the fetch has to bring one.
  const orphan = model.detailFetchPlan(true, false)
  assert.strictEqual(orphan.paintNow, false)
  assert.strictEqual(orphan.whole, true)
  assert.strictEqual(orphan.reportFailure, true)

  const miss = model.detailFetchPlan(false, true)
  assert.strictEqual(miss.paintNow, false)
  assert.strictEqual(miss.whole, true, "a miss fetches everything, as it always did")
  assert.strictEqual(miss.reportFailure, true)

  assert.strictEqual(model.detailFetchPlan(false, false).whole, true)
  // Anything that is not a true is a miss: the cache answers null on a file
  // that was never written, and undefined is what a caller with no answer yet
  // has.
  assert.strictEqual(model.detailFetchPlan(undefined, undefined).whole, true)
}

// ---------------------------------------------------------------- row keys
//
// The address a view holds. The bug this replaces: `hostForMessage(id)` and
// every cursor function took a bare id, so two IMAP accounts each holding
// `5:INBOX` gave the first one every open, every action and the cursor itself
// — and `j` could not walk past the duplicate, because moving from A's row
// answered with an id whose first match was still A's row.

const A = "imap:a@example.org"
const B = "imap:b@example.org"

function collidingRow(accountId, uid, date) {
  return { id: uid + ":INBOX", accountId: accountId, date: date,
    subject: accountId.slice(5, 6).toUpperCase() + "#" + uid }
}

// Five each, with overlapping UIDs 1..5 and interleaved arrival times, which
// is the shape the two mailboxes on one server actually had.
const hostA = [collidingRow(A, 5, 1000), collidingRow(A, 4, 800), collidingRow(A, 3, 600),
  collidingRow(A, 2, 400), collidingRow(A, 1, 200)]
const hostB = [collidingRow(B, 5, 900), collidingRow(B, 4, 700), collidingRow(B, 3, 500),
  collidingRow(B, 2, 300), collidingRow(B, 1, 100)]
const both = hostA.concat(hostB).slice().sort(model.byReceivedDescending)

assert.strictEqual(both.map(m => m.subject).join(" "),
  "A#5 B#5 A#4 B#4 A#3 B#3 A#2 B#2 A#1 B#1",
  "the merged order interleaves the two accounts")

// A key round-trips, and a key with no account is a bare id — which is what a
// single-account list produces and what `sameMessage` already reads as "any".
assert.strictEqual(model.keyId(model.rowKey(hostB[0])), "5:INBOX")
assert.strictEqual(model.keyAccountId(model.rowKey(hostB[0])), B)
assert.strictEqual(model.messageKey("5:INBOX", ""), "5:INBOX")
assert.strictEqual(model.keyAccountId("5:INBOX"), "")
assert.strictEqual(model.keyId("5:INBOX"), "5:INBOX")

// A folder name may hold anything, so the split is at the first separator only
// and the id keeps whatever it had.
const odd = model.messageKey("9:Archive/2024", A)
assert.strictEqual(model.keyId(odd), "9:Archive/2024")
assert.strictEqual(model.keyAccountId(odd), A)

// The one comparison a row makes. Both halves have to agree, or both rows of a
// colliding pair draw as the cursor.
assert.strictEqual(model.keyMatches(model.rowKey(hostB[0]), hostB[0]), true)
assert.strictEqual(model.keyMatches(model.rowKey(hostB[0]), hostA[0]), false,
  "the same id under another account is a different row")
assert.strictEqual(model.keyMatches("", hostA[0]), false)

// j walks every row. This is the report: the cursor stuck at the first
// duplicated id and no row below it could be reached.
{
  let cursor = ""
  const walked = []
  for (let i = 0; i < both.length; i++) {
    cursor = model.cursorAfterOffset(both, cursor, 1)
    walked.push(model.indexByKey(both, cursor))
  }
  assert.deepStrictEqual(walked, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    "j reaches every row of a merged list holding duplicated ids")
  assert.strictEqual(model.cursorAfterOffset(both, cursor, 1),
    model.rowKey(both[both.length - 1]), "and clamps at the last row")
}

// k walks back the same way.
{
  let cursor = ""
  const walked = []
  for (let i = 0; i < both.length; i++) {
    cursor = model.cursorAfterOffset(both, cursor, -1)
    walked.push(model.indexByKey(both, cursor))
  }
  assert.deepStrictEqual(walked, [9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
}

// Archiving the second row of a colliding pair resolves to the second account.
// `hostForMessage` in Service.qml reads the key's account half; this is the
// decision it makes, with the hosts as they are.
{
  const hosts = [{ accountId: A, messages: hostA }, { accountId: B, messages: hostB }]
  function hostForMessage(key) {
    const owner = model.keyAccountId(key)
    for (const host of hosts) {
      if (owner !== "") {
        if (host.accountId === owner) return host
        continue
      }
      if (model.indexById(host.messages, model.keyId(key), host.accountId) >= 0) return host
    }
    return null
  }

  const second = both[1]
  assert.strictEqual(second.subject, "B#5", "row 1 is the second of the pair")
  const key = model.rowKey(second)
  assert.strictEqual(hostForMessage(key).accountId, B,
    "archive on the second row resolves to the second account")
  assert.strictEqual(hostForMessage(model.rowKey(both[0])).accountId, A)

  // And it removes only that account's row.
  const after = model.removeById(hostB, model.keyId(key), B)
  assert.strictEqual(after.length, 4)
  assert.strictEqual(hostA.length, 5, "the other account's list is untouched")
}

// The cursor after a removal is the row below, addressed by key — not an id
// that would resolve back to the row above it in the other account.
{
  const key = model.rowKey(both[1])
  const next = model.cursorAfterRemoval(both, key)
  assert.strictEqual(model.indexByKey(both, next), 2)
  assert.strictEqual(model.keyAccountId(next), A, "row 2 is A#4")
}

// A reload re-derives the key from the row it matched. A cursor that arrived
// as a bare id — from an older session, or a single-account list that has just
// become merged — comes back addressed.
{
  assert.strictEqual(model.cursorAfterReload(both, model.rowKey(both[3])),
    model.rowKey(both[3]))
  assert.strictEqual(model.cursorAfterReload(both, "5:INBOX"), model.rowKey(both[0]),
    "a bare id resolves to the first row holding it, and is returned addressed")
  assert.strictEqual(model.cursorAfterReload(both, model.messageKey("9:INBOX", A)),
    model.rowKey(both[0]), "a cursor whose row is gone starts at the top")
  assert.strictEqual(model.cursorAfterReload([], model.rowKey(both[0])), "")
}

// ----------------------------------------------------------- the selection
//
// A third thing beside the cursor and the open message, and the reason it is a
// third thing rather than a widening of either: walking with `j` must not act
// on anything, and opening a message must not enlist it in a bulk trash.
//
// It holds row keys for the same reason everything else here does. `both` is
// the merged list of two mailboxes with overlapping UIDs, so a set of bare ids
// would mark A#5 and B#5 together and send one server's UIDs to the other.

{
  const a5 = model.rowKey(both[0])   // A#5
  const b5 = model.rowKey(both[1])   // B#5

  assert.strictEqual(model.isMarked([], a5), false)
  assert.strictEqual(model.isMarked([a5], a5), true)
  assert.strictEqual(model.isMarked([a5], b5), false,
    "two rows sharing a UID are two different rows in the set as well")
  assert.strictEqual(model.isMarked([a5], ""), false)
  assert.strictEqual(model.isMarked(null, a5), false)

  // A new array every time, so a QML property assignment is seen as a change.
  // Mutating in place left the count and the row markers on the old value.
  const one = model.toggleMark([], a5)
  deepEqual(one, [a5])
  const two = model.toggleMark(one, b5)
  deepEqual(two, [a5, b5])
  deepEqual(one, [a5], "toggling did not touch the array it was given")
  deepEqual(model.toggleMark(two, a5), [b5], "toggling again takes it out")
  deepEqual(model.toggleMark([], ""), [], "an empty key marks nothing")

  deepEqual(model.addMark([a5], b5), [a5, b5])
  deepEqual(model.addMark([a5], a5), [a5], "adding twice is once")
  deepEqual(model.addMark([a5], ""), [a5])
}

// The set belongs to one mailbox. A key from another replaces it rather than
// joining it: a selection spanning three merged accounts is three separate
// batch requests with three ways to half-fail. Replacing rather than refusing,
// because a refused key looks like a broken keyboard — `x` on a row that then
// draws no marker and says nothing about why.
{
  const a5 = model.rowKey(both[0])   // A#5
  const a4 = model.rowKey(both[2])   // A#4
  const b5 = model.rowKey(both[1])   // B#5

  deepEqual(model.marksAfterToggle([], a5, A, ""), [a5],
    "the first mark sets the owner")
  deepEqual(model.marksAfterToggle([a5], a4, A, A), [a5, a4],
    "another row of the same mailbox joins it")
  deepEqual(model.marksAfterToggle([a5, a4], b5, B, A), [b5],
    "a row of another mailbox starts a new set where the user is standing")
  // Un-marking is exempt: a key already in the set is in the set's own mailbox
  // by construction, so taking it out is never a mailbox change.
  deepEqual(model.marksAfterToggle([a5, a4], a5, A, A), [a4])
  deepEqual(model.marksAfterToggle([a5], a5, A, A), [],
    "and the last one out empties it")
  deepEqual(model.marksAfterToggle([a5], "", A, A), [a5])
  // A single-account list names no owner anywhere, and the question of
  // crossing mailboxes never arises there.
  deepEqual(model.marksAfterToggle([a5], a4, "", ""), [a5, a4])
}

// Select all is what is loaded, not what the mailbox holds. A mailbox-wide
// select all would promise an action over messages never fetched, and could
// draw no marker beside them.
{
  const all = model.marksForAll(both)
  assert.strictEqual(all.length, both.length)
  assert.strictEqual(all[0], model.rowKey(both[0]))
  assert.strictEqual(new Set(all).size, both.length,
    "ten rows, ten distinct keys, even where two share a UID")
  deepEqual(model.marksForAll([]), [])
  deepEqual(model.marksForAll(null), [])
  deepEqual(model.marksForAll([{ id: "", accountId: A }]), [],
    "a row with no id is no row")
}

// The set is filtered against the list whenever the list is replaced, the same
// job cursorAfterReload does for the cursor: a key naming a row the list no
// longer holds cannot be acted on, and counting it is a lie about how many
// messages are about to move.
{
  const set = [model.rowKey(both[0]), model.rowKey(both[4]),
    model.messageKey("9:INBOX", A)]
  deepEqual(model.marksAfterReload(both, set),
    [model.rowKey(both[0]), model.rowKey(both[4])],
    "the row that left the list leaves the set with it")
  deepEqual(model.marksAfterReload([], set), [])
  deepEqual(model.marksAfterReload(both, []), [])
  // Re-derived from the row rather than kept as it came in, so a key that
  // named no account stops being ambiguous the moment the row is found.
  deepEqual(model.marksAfterReload(both, ["5:INBOX"]), [model.rowKey(both[0])],
    "a bare id comes back addressed to the first row holding it")
}

// The marked rows in the order the list draws them, which is the order an
// action applies them in. The set itself is in the order things were marked,
// which is nobody's order.
{
  const set = [model.rowKey(both[4]), model.rowKey(both[1]), model.rowKey(both[0])]
  deepEqual(model.selectedRows(both, set).map(m => m.subject),
    ["A#5", "B#5", "A#3"],
    "read back off the list, not out of the set")
  deepEqual(model.selectedRows(both, []), [])
  deepEqual(model.selectedRows([], set), [])
}

// The account half of a key is dropped here and nowhere earlier: this is the
// provider boundary, and a client's batch path takes ids. Filtered by owner
// rather than trusted, because a set that had somehow spanned two accounts
// would otherwise send one mailbox's UIDs to the other's server — the exact
// failure the key discipline exists to prevent.
{
  const spanning = [model.rowKey(both[0]), model.rowKey(both[1]),
    model.rowKey(both[2])]                       // A#5, B#5, A#4
  deepEqual(model.markedIdsFor(both, spanning, A), ["5:INBOX", "4:INBOX"],
    "B's row is refused, and A's two come out as bare ids")
  deepEqual(model.markedIdsFor(both, spanning, B), ["5:INBOX"])
  deepEqual(model.markedIdsFor(both, spanning, ""), ["5:INBOX", "5:INBOX", "4:INBOX"],
    "no owner named is the single-account list, where every row is the owner's")
  deepEqual(model.markedIdsFor(both, [], A), [])
}

// Extending marks both ends of the step. Marking only the destination leaves
// the row the extension started from out of its own selection; marking only
// the origin means the first Shift+J marks a row the cursor has left.
{
  const from = model.rowKey(both[0])
  const to = model.rowKey(both[1])
  deepEqual(model.marksAfterExtend(both, [], from, 1), [from, to])
  // It only ever adds. Coming back the other way does not un-mark, because
  // un-marking needs an anchor and a direction — a range rather than an
  // extension — and the two disagree the moment the cursor moves by anything
  // else in between. `x` is what un-marks one row.
  deepEqual(model.marksAfterExtend(both, [from, to], to, -1), [from, to],
    "Shift+K back over a marked row leaves it marked")
  // Clamped at the ends by cursorAfterOffset, so extending past the bottom
  // marks the bottom row rather than nothing.
  const last = model.rowKey(both[both.length - 1])
  deepEqual(model.marksAfterExtend(both, [], last, 1), [last])
  deepEqual(model.marksAfterExtend([], [], from, 1), [from])
}

// Where the cursor goes when a whole set leaves. cursorAfterRemoval hands back
// the row below, which in a set of consecutive rows is another one that is also
// going — so this walks past every marked row before it settles anywhere.
{
  const keyAt = i => model.rowKey(both[i])
  // Rows 2, 3 and 4 marked, cursor on row 2: the first unmarked row below.
  deepEqual(model.cursorAfterMarkedRemoval(both, keyAt(2),
    [keyAt(2), keyAt(3), keyAt(4)]), keyAt(5))
  // The set runs to the bottom, so the walk turns round and goes up.
  const tail = [keyAt(7), keyAt(8), keyAt(9)]
  deepEqual(model.cursorAfterMarkedRemoval(both, keyAt(8), tail), keyAt(6))
  // Everything selected leaves nowhere for the cursor to be, and it says so
  // rather than naming a row that is going.
  deepEqual(model.cursorAfterMarkedRemoval(both, keyAt(0), model.marksForAll(both)), "")
  // A cursor that is not in this list starts the walk at the top; the whole
  // set going does not empty the list.
  deepEqual(model.cursorAfterMarkedRemoval(both, "nowhere", [keyAt(0)]), keyAt(1))
  deepEqual(model.cursorAfterMarkedRemoval([], keyAt(0), [keyAt(0)]), "")
  // Nothing marked at all: the cursor stays where it stands.
  deepEqual(model.cursorAfterMarkedRemoval(both, keyAt(4), []), keyAt(4))
}

// The count is never a bare number: "3" beside a list of messages could be a
// count of anything, and the word is what makes the state readable rather than
// merely visible.
assert.strictEqual(model.selectionLabel(0), "", "nothing selected says nothing")
assert.strictEqual(model.selectionLabel(1), "1 selected")
assert.strictEqual(model.selectionLabel(12), "12 selected")
assert.strictEqual(model.selectionLabel(-3), "")
assert.strictEqual(model.selectionLabel(null), "")

// What a bulk action reports. Honest about a partial result, because
// `--fail-early` stops a folded IMAP sequence at its first failure and Gmail
// has no batch trash — so a set can genuinely land on some of its messages and
// not the rest, and "Moved to trash" over twelve of which nine moved is a
// claim the program cannot support.
assert.strictEqual(model.bulkResultLabel("trash", 9, 12), "9 of 12 moved to trash")
assert.strictEqual(model.bulkResultLabel("trash", 12, 12), "12 messages moved to trash")
assert.strictEqual(model.bulkResultLabel("archive", 1, 1), "1 message archived",
  "one message, singular, even coming out of the bulk path")
assert.strictEqual(model.bulkResultLabel("archive", 0, 12), "Nothing was archived",
  "zero moved is not a success with a count of none")
assert.strictEqual(model.bulkResultLabel("markRead", 3, 3), "3 messages marked read")
assert.strictEqual(model.bulkResultLabel("markUnread", 2, 5), "2 of 5 marked unread")
assert.strictEqual(model.bulkResultLabel("star", 4, 4), "4 messages starred")
assert.strictEqual(model.bulkResultLabel("untrash", 2, 2), "2 messages restored")
assert.strictEqual(model.bulkResultLabel("archive", 0, 0), "",
  "an empty set has nothing to report")
// More reported done than were asked for is a client that miscounted, not a
// reason to print "13 of 12".
assert.strictEqual(model.bulkResultLabel("archive", 13, 12), "13 messages archived")

// One action for the whole set rather than a toggle per row: a mixed selection
// toggled row by row comes out exactly as mixed as it went in, which is the
// one outcome nobody pressed `s` for.
{
  const starred = { id: "1", starred: true }
  const plain = { id: "2", starred: false }
  assert.strictEqual(model.bulkStarAction([starred, plain]), "star",
    "anything unstarred means the set gets starred")
  assert.strictEqual(model.bulkStarAction([starred, starred]), "unstar")
  assert.strictEqual(model.bulkStarAction([]), "unstar")

  const unread = { id: "1", unread: true }
  const read = { id: "2", unread: false }
  assert.strictEqual(model.bulkReadAction([unread, read]), "markRead")
  assert.strictEqual(model.bulkReadAction([read, read]), "markUnread")
}

// --------------------------------------------------- merged list ordering
//
// Newest first, by when the message was received. A merged list is several
// servers' pages interleaved, so the order has to come from the summaries
// rather than from the order they arrived in.

const dated = [
  { id: "5:INBOX", accountId: "a", date: new Date("2026-09-01T09:00:00Z") },
  { id: "9:INBOX", accountId: "b", date: new Date("2026-09-03T09:00:00Z") },
  { id: "7:INBOX", accountId: "a", date: new Date("2026-09-02T09:00:00Z") }
]
const ordered = dated.slice().sort(model.byReceivedDescending)
deepEqual(ordered.map(function(m) { return m.id }), ["9:INBOX", "7:INBOX", "5:INBOX"])

// The order is total: two messages sharing a timestamp must not swap places
// between relayouts, or a row moves under the pointer.
const same = new Date("2026-09-02T09:00:00Z")
const tied = [
  { id: "2:INBOX", accountId: "b", date: same },
  { id: "1:INBOX", accountId: "a", date: same },
  { id: "3:INBOX", accountId: "a", date: same }
]
const first = tied.slice().sort(model.byReceivedDescending).map(function(m) { return m.id })
const again = tied.slice().reverse().sort(model.byReceivedDescending).map(function(m) { return m.id })
deepEqual(first, again, "the same rows sort the same way whatever order they arrive in")

// A page fetched while the server was throttling can arrive with content and
// no INTERNALDATE. One rule for those rows: after every dated one, then by
// arrival number, then by account.
//
// The rule they used to follow was two rules — placed by UID against a dated
// row of the same account, and "dated leads" against a dated row of another —
// and those cycle. The list is ordered by when mail arrived, and a row with no
// arrival time has no position in that order to claim, so it goes last. It is
// rare and self-correcting: the next load brings the date.
const patchy = [
  { id: "11994:INBOX", accountId: "a", date: null },
  { id: "11995:INBOX", accountId: "a", date: new Date("2026-09-02T15:01:57Z") },
  { id: "12000:INBOX", accountId: "a", date: null }
]
deepEqual(patchy.slice().sort(model.byReceivedDescending).map(function(m) { return m.id }),
  ["11995:INBOX", "12000:INBOX", "11994:INBOX"],
  "dated rows lead, and undated ones follow by arrival number")

// The same across mailboxes, by the same rule rather than a second one.
const across = [
  { id: "12000:INBOX", accountId: "a", date: null },
  { id: "50:INBOX", accountId: "b", date: new Date("2026-09-03T09:00:00Z") }
]
assert.strictEqual(across.slice().sort(model.byReceivedDescending)[0].id, "50:INBOX")

// Undated rows from one mailbox still order among themselves.
const blind = [
  { id: "7:INBOX", accountId: "a", date: null },
  { id: "9:INBOX", accountId: "a", date: null },
  { id: "8:INBOX", accountId: "a", date: null }
]
deepEqual(blind.slice().sort(model.byReceivedDescending).map(function(m) { return m.id }),
  ["9:INBOX", "8:INBOX", "7:INBOX"])

// Undated rows from two mailboxes break their tie on the account, so the order
// is total rather than merely consistent within one.
const blindAcross = [
  { id: "9:INBOX", accountId: "b", date: null },
  { id: "9:INBOX", accountId: "a", date: null }
]
deepEqual(blindAcross.slice().sort(model.byReceivedDescending)
  .map(function(m) { return m.accountId }), ["a", "b"])

// ------------------------------------------------------- a total order
//
// The comparator has to be a total order, not nearly one. Array.prototype.sort
// is free to produce anything at all from an inconsistent comparator, and the
// merged list reshuffled between relayouts with rows moving under the pointer.
//
// The case that broke it: A dated uid 5 and B undated uid 10 in one account,
// C dated in another. B beat A by arrival, A tie-broke against C by date, and
// C beat B because "the dated one leads" — a cycle. Sorting those three from
// all six permutations gave three different orders.

function permutations(list) {
  if (list.length <= 1) return [list.slice()]
  const out = []
  for (let i = 0; i < list.length; i++) {
    const rest = list.slice(0, i).concat(list.slice(i + 1))
    const inner = permutations(rest)
    for (let j = 0; j < inner.length; j++) out.push([list[i]].concat(inner[j]))
  }
  return out
}

function assertTotalOrder(rows, label) {
  const compare = model.byReceivedDescending

  // Antisymmetric, and reflexive on a row against itself.
  for (let i = 0; i < rows.length; i++) {
    assert.strictEqual(compare(rows[i], rows[i]), 0,
      label + ": a row compared with itself is equal")
    for (let j = 0; j < rows.length; j++) {
      const forward = compare(rows[i], rows[j])
      const back = compare(rows[j], rows[i])
      assert.ok((forward < 0 && back > 0) || (forward > 0 && back < 0)
        || (forward === 0 && back === 0),
        label + ": " + rows[i].id + "/" + rows[i].accountId + " against "
          + rows[j].id + "/" + rows[j].accountId + " disagrees when reversed")
    }
  }

  // Transitive: a before b and b before c means a before c, for every triple.
  for (let i = 0; i < rows.length; i++) {
    for (let j = 0; j < rows.length; j++) {
      for (let k = 0; k < rows.length; k++) {
        if (compare(rows[i], rows[j]) <= 0 && compare(rows[j], rows[k]) <= 0) {
          assert.ok(compare(rows[i], rows[k]) <= 0,
            label + ": " + rows[i].id + " <= " + rows[j].id + " <= " + rows[k].id
              + " but not " + rows[i].id + " <= " + rows[k].id)
        }
      }
    }
  }

  // And the observable consequence: every permutation sorts to one answer.
  const orders = {}
  const all = permutations(rows)
  for (let i = 0; i < all.length; i++) {
    const key = all[i].slice().sort(compare)
      .map(function(m) { return m.accountId + "/" + m.id }).join(",")
    orders[key] = true
  }
  assert.strictEqual(Object.keys(orders).length, 1,
    label + ": " + all.length + " permutations gave "
      + Object.keys(orders).length + " different orders")
}

// The three rows from the report, verbatim.
assertTotalOrder([
  { id: "5:INBOX", accountId: "a", date: new Date("2026-09-01T10:00:00Z") },
  { id: "10:INBOX", accountId: "a", date: null },
  { id: "3:INBOX", accountId: "b", date: new Date("2026-09-02T10:00:00Z") }
], "the reported cycle")

// Every shape that reaches the comparator at once: dated and undated, two
// accounts, a shared timestamp, a shared id across accounts, an id with no
// leading number, and a row with no account at all.
assertTotalOrder([
  { id: "5:INBOX", accountId: "a", date: new Date("2026-09-01T10:00:00Z") },
  { id: "5:INBOX", accountId: "b", date: new Date("2026-09-01T10:00:00Z") },
  { id: "10:INBOX", accountId: "a", date: null },
  { id: "10:INBOX", accountId: "b", date: null },
  { id: "3:INBOX", accountId: "b", date: new Date("2026-09-02T10:00:00Z") },
  { id: "18f2c:", accountId: "c", date: null },
  { id: "7:INBOX", accountId: "", date: null },
  { id: "7:INBOX", accountId: "a", date: new Date("2026-09-01T10:00:00Z") }
], "every shape at once")

// Only Inbox and Unread are merged: they are the two every provider maps the
// same way.
assert.strictEqual(model.isUnifiedMailbox("inbox"), true)
assert.strictEqual(model.isUnifiedMailbox("unread"), true)
assert.strictEqual(model.isUnifiedMailbox("sent"), false)
assert.strictEqual(model.isUnifiedMailbox("archive"), false)
assert.strictEqual(model.isUnifiedMailbox("trash"), false)
assert.strictEqual(model.isUnifiedMailbox("all"), false)
// ------------------------------------------------------------------- undo

// Only trash is offered back. A verb with no reverse gets no record at all,
// rather than a record whose Undo button would do nothing.
assert.strictEqual(model.reverseAction("trash"), "untrash")
assert.strictEqual(model.reverseAction("archive"), "")
assert.strictEqual(model.reverseAction("markRead"), "")
assert.strictEqual(model.reverseAction("star"), "")
assert.strictEqual(model.reverseAction(""), "")
assert.strictEqual(model.reverseAction(null), "")

// The folder is read off the id, because that is the only place it is written
// down. Gmail's ids name no folder and must not be made to look as if they do.
assert.strictEqual(model.undoSourceFolder("5:INBOX"), "INBOX")
assert.strictEqual(model.undoSourceFolder("12:Archive"), "Archive")
assert.strictEqual(model.undoSourceFolder("7:[Gmail]/All Mail"), "[Gmail]/All Mail",
  "a folder name with a bracket and a slash in it is still one folder name")
assert.strictEqual(model.undoSourceFolder("3:"), "",
  "a message in no folder names none")
assert.strictEqual(model.undoSourceFolder("18f2c9a1b"), "",
  "a Gmail id is not a uid:folder pair")
assert.strictEqual(model.undoSourceFolder(""), "")
assert.strictEqual(model.undoSourceFolder(null), "")

const imapRow = { id: "5:Archive", accountId: "imap:me@host", subject: "Hello" }
const gmailRow = { id: "18f2c9a1b", accountId: "me@gmail.com", subject: "Hi" }

{
  const entry = model.undoEntry(imapRow, 3)
  assert.strictEqual(entry.id, "5:Archive")
  assert.strictEqual(entry.index, 3)
  assert.strictEqual(entry.folder, "Archive",
    "where it came from, recorded before the trash destroyed the fact")
  assert.strictEqual(entry.row, imapRow, "the row itself, to put back")
}
assert.strictEqual(model.undoEntry(gmailRow, 0).folder, "",
  "Gmail restores its own labels and is handed no folder")
assert.strictEqual(model.undoEntry(null, 0), null)
assert.strictEqual(model.undoEntry({ id: "" }, 0), null,
  "a row that cannot be addressed cannot be put back")
assert.strictEqual(model.undoEntry(imapRow, -4).index, 0)

// The record, or nothing. Null rather than an empty record, so no caller can
// end up drawing an Undo button for an action that has no reverse.
{
  const record = model.undoRecordFor("trash", [model.undoEntry(imapRow, 2)], "inbox")
  assert.strictEqual(record.reverse, "untrash")
  assert.strictEqual(record.mailboxKey, "inbox")
  assert.strictEqual(record.entries.length, 1)
  assert.strictEqual(model.isUndoable(record), true)
  assert.strictEqual(model.undoNoticeText(record), "Moved to trash")
  assert.strictEqual(model.undoActionLabel(record), "Undo")
  assert.strictEqual(model.undoCursorKey(record), model.rowKey(imapRow),
    "the cursor goes back onto the row that came back")
}
assert.strictEqual(model.undoRecordFor("archive", [model.undoEntry(imapRow, 0)], "inbox"), null,
  "archive has no reverse here, so it offers nothing")
assert.strictEqual(model.undoRecordFor("trash", [], "inbox"), null,
  "nothing was trashed, so there is nothing to take back")
assert.strictEqual(model.undoRecordFor("trash", [null], "inbox"), null)
assert.strictEqual(model.undoRecordFor("trash", null, "inbox"), null)

// A menu opened on a marked row acts on the set; one opened on an unmarked row
// acts on that row alone, the way a right-click names its own target in every
// file manager. Without this the menu was the one path that could not see a
// selection the user was looking at.
{
  const acct = "imap:me@host"
  const rows = [1, 2, 3].map(function (n) {
    return { id: n + ":INBOX", accountId: acct }
  })
  const marks = [model.rowKey(rows[0]), model.rowKey(rows[1])]
  assert.strictEqual(model.menuActsOnSet(marks, model.rowKey(rows[0])), true,
    "the row is in the set, so the set is what the menu acts on")
  assert.strictEqual(model.menuActsOnSet(marks, model.rowKey(rows[2])), false,
    "an unmarked row names itself")
  assert.strictEqual(model.menuActsOnSet([], model.rowKey(rows[0])), false,
    "no selection means no set to act on")
}

// The label cannot claim a size the action does not have: "Archive" over twelve
// selected messages is a promise about one that twelve are about to break.
assert.strictEqual(model.menuActionLabel("Archive", 1), "Archive")
assert.strictEqual(model.menuActionLabel("Archive", 12), "Archive 12")
assert.strictEqual(model.menuActionLabel("Move to trash", 3), "Move to trash 3")
assert.strictEqual(model.menuActionLabel("Archive", 0), "Archive",
  "nothing selected still reads as the single-message action")

// The entry carries the identity that survives the move. The id names a UID
// the folder issued, and Trash reissues it; the Message-ID is what finds the
// message again.
{
  const row = { id: "5:Archive", accountId: "imap:me@host",
    messageId: "<kept@example.com>" }
  const entry = model.undoEntry(row, 3)
  assert.strictEqual(entry.messageId, "<kept@example.com>")
  assert.strictEqual(entry.folder, "Archive",
    "and where it goes back to, which the move also destroys")
  assert.strictEqual(model.undoEntry({ id: "5:Archive" }, 0).messageId, "",
    "a row with no Message-ID says so rather than carrying undefined")
}

// A bulk action offers its undo only when the whole set moved. After a partial
// the record still names every row the action started with, and restoring those
// would move mail that was never trashed — so the offer is withheld and the
// count stands alone.
assert.strictEqual(model.offersUndoAfterBulk(12, 12), true)
assert.strictEqual(model.offersUndoAfterBulk(9, 12), false,
  "three never left, so Undo would move mail nobody trashed")
assert.strictEqual(model.offersUndoAfterBulk(0, 12), false)
assert.strictEqual(model.offersUndoAfterBulk(0, 0), false,
  "an empty set has nothing to take back")
assert.strictEqual(model.offersUndoAfterBulk(1, 1), true)

// Nothing to offer reads as nothing everywhere, rather than as a button with
// no words on it.
assert.strictEqual(model.isUndoable(null), false)
assert.strictEqual(model.undoNoticeText(null), "")
assert.strictEqual(model.undoActionLabel(null), "")
assert.strictEqual(model.undoCursorKey(null), "")
assert.strictEqual(model.isUndoable({ reverse: "untrash", entries: [] }), false)

// A set is the same record with more rows in it: a bulk trash records every row
// it moved, so one Undo takes the whole block back.
{
  const second = { id: "9:Archive", accountId: "imap:me@host", subject: "Also" }
  const record = model.undoRecordFor("trash",
    [model.undoEntry(imapRow, 1), model.undoEntry(second, 4)], "inbox")
  assert.strictEqual(record.entries.length, 2)
  assert.strictEqual(model.undoNoticeText(record), "2 messages moved to trash",
    "the count is in the sentence, because Undo would restore all of them")
  assert.strictEqual(model.undoCursorKey(record), model.rowKey(imapRow),
    "the top of the block is where the eye was")
}

// ------------------------------------------------------ putting rows back

{
  const a = { id: "1:INBOX", accountId: "imap:me@host" }
  const b = { id: "2:INBOX", accountId: "imap:me@host" }
  const c = { id: "3:INBOX", accountId: "imap:me@host" }
  const list = [a, c]
  const back = model.restoreEntries(list, [model.undoEntry(b, 1)])
  deepEqual(back.map(function (row) { return row.id }), ["1:INBOX", "2:INBOX", "3:INBOX"],
    "the row goes back where it left from, not onto the end")
  deepEqual(list.map(function (row) { return row.id }), ["1:INBOX", "3:INBOX"],
    "and the list it came from is not modified in place")
}

// Lowest index first, so an earlier insertion does not push a later one past
// its own place.
{
  const rows = ["a", "b", "c", "d"].map(function (name, i) {
    return { id: (i + 1) + ":INBOX", accountId: "x", subject: name }
  })
  const remaining = [rows[1], rows[3]]
  const back = model.restoreEntries(remaining,
    [model.undoEntry(rows[2], 2), model.undoEntry(rows[0], 0)])
  deepEqual(back.map(function (row) { return row.subject }), ["a", "b", "c", "d"])
}

// A refresh between the trash and the undo can bring the row back on its own.
// Putting it back again would list it twice.
{
  const row = { id: "5:INBOX", accountId: "imap:me@host" }
  const back = model.restoreEntries([row], [model.undoEntry(row, 0)])
  assert.strictEqual(back.length, 1, "a row already listed is left alone")
}

// An index past the end of a list that has since shrunk lands at the end
// rather than leaving a hole.
{
  const row = { id: "9:INBOX", accountId: "x" }
  const back = model.restoreEntries([], [model.undoEntry(row, 40)])
  deepEqual(back.map(function (r) { return r.id }), ["9:INBOX"])
}
deepEqual(model.restoreEntries(null, null), [])
deepEqual(model.restoreEntries([], [null]), [])

console.log("test_model.js ok")
