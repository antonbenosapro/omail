.pragma library

// View models. Anything the panel decides — what the setup card should say,
// whether a message still belongs in the list after an action, what the badge
// reads — is decided here so the QML stays a description of the screen.
//
// What is *not* here is anything that differs between mail services. That is
// `Provider.js`, and this file is the half that is the same whichever one an
// account runs on.

// The mailboxes themselves live in `Provider.js`, because which ones exist and
// what selects them is a property of the mail service rather than of the view.
// They were here first, and a copy left behind would be a second definition to
// keep in step with the first — so the account hands its list down instead.

// ------------------------------------------------------------ setup state

// A setup page opened for a known provider must not change type while saving
// rebuilds the service's current account. During that one frame the service
// reports its compatibility fallback (Gmail), not a user choice.
function setupProvider(chosen, live) {
  var stable = String(chosen === undefined || chosen === null ? "" : chosen).trim()
  if (stable !== "") return stable
  return String(live === undefined || live === null ? "" : live).trim() || "gmail"
}

// One value the panel can switch on, in the order a new user meets them.
function setupState(status) {
  var value = status || {}
  if (!value.toolsPresent) return "tools_missing"
  if (!value.credentialsPresent) return "no_credentials"
  if (value.signingIn) return "signing_in"
  if (!value.signedIn) return "signed_out"
  return "ready"
}

// The setup card, in words that fit the service the account actually runs on.
// `provider` is the display name ("Gmail", "IMAP") and `authKind` is how it
// signs in — the two things that change every sentence below. Both default to
// Gmail's, because that is what an account with no provider recorded is.
function providerName(provider) {
  var name = String(provider === undefined || provider === null ? "" : provider).trim()
  return name === "" ? "Gmail" : name
}

function setupHeadline(state, provider, authKind) {
  var name = providerName(provider)
  if (state === "unavailable") return name + " integration is coming later"
  if (state === "tools_missing") return "Missing system tools"
  // Only one of these sends the user to a Cloud console. The other needs a
  // server and a password, which is a form rather than a project.
  if (state === "no_credentials")
    return authKind === "password" ? "Add this mailbox" : "Connect a Google Cloud project"
  if (state === "signing_in")
    return authKind === "password" ? "Checking the mailbox…" : "Waiting for Google…"
  if (state === "signed_out") return "Sign in to " + name
  return ""
}

// `unavailable` carries its reason from the provider rather than from here:
// only the provider knows why it cannot be reached, and a sentence written in
// this file would go stale the day that changes.
function setupDetail(state, missingTools, reason, provider, authKind) {
  var name = providerName(provider)
  if (state === "unavailable") return String(reason || "")
  if (state === "tools_missing") {
    var tools = Array.isArray(missingTools) ? missingTools.join(", ") : ""
    return "Omamail needs " + (tools || "a few base tools")
      + " on PATH before it can sign in."
  }
  if (state === "no_credentials")
    return authKind === "password"
      ? "Enter the server and the password for this mailbox. Most providers want an app password rather than the one you sign in to the website with."
      : "Gmail has no shared app to sign in through, so this plugin uses an OAuth client you own. It takes about two minutes to create."
  if (state === "signing_in")
    return authKind === "password"
      ? "Trying the server with those details."
      : "Finish the sign-in in your browser. This window updates by itself."
  if (state === "signed_out")
    return authKind === "password"
      ? "This mailbox is set up. Enter its password to let it read your mail."
      : "Your OAuth client is ready. Sign in to let it read this mailbox."
  return ""
}

function setupActionLabel(state, provider, authKind) {
  // Nothing to press: there is no form that would help and no browser to open.
  if (state === "unavailable") return ""
  if (state === "tools_missing") return "See what is missing..."
  if (state === "no_credentials")
    return authKind === "password" ? "Add the mailbox..." : "Set up the OAuth client..."
  if (state === "signing_in") return "Cancel"
  if (state === "signed_out") return "Sign in to " + providerName(provider) + "..."
  return ""
}

// --------------------------------------------------------- list behaviour

// After an action the message may no longer belong in the mailbox being
// viewed. Archiving from Inbox removes the row; archiving from All mail does
// not. Getting this wrong either strands a row that is gone or hides one that
// is still there.
function survivesAction(mailboxKey, action) {
  var key = String(mailboxKey || "inbox")
  var verb = String(action || "")
  if (verb === "trash") return key === "trash"
  if (verb === "untrash") return key !== "trash"
  if (verb === "archive") return key !== "inbox" && key !== "unread"
  if (verb === "markRead") return key !== "unread"
  if (verb === "unstar") return key !== "starred"
  return true
}

function labelChangesFor(action) {
  if (action === "markRead") return { add: [], remove: ["UNREAD"] }
  if (action === "markUnread") return { add: ["UNREAD"], remove: [] }
  if (action === "star") return { add: ["STARRED"], remove: [] }
  if (action === "unstar") return { add: [], remove: ["STARRED"] }
  if (action === "archive") return { add: [], remove: ["INBOX"] }
  if (action === "unarchive") return { add: ["INBOX"], remove: [] }
  if (action === "spam") return { add: ["SPAM"], remove: ["INBOX"] }
  return null
}

function applyLabelChange(summary, action) {
  if (!summary) return summary
  var change = labelChangesFor(action)
  if (!change) return summary
  var next = {}
  for (var key in summary) next[key] = summary[key]
  var labels = Array.isArray(summary.labelIds) ? summary.labelIds.slice() : []
  for (var i = 0; i < change.remove.length; i++) {
    var at = labels.indexOf(change.remove[i])
    if (at >= 0) labels.splice(at, 1)
  }
  for (var j = 0; j < change.add.length; j++) {
    if (labels.indexOf(change.add[j]) < 0) labels.push(change.add[j])
  }
  next.labelIds = labels
  next.unread = labels.indexOf("UNREAD") >= 0
  next.starred = labels.indexOf("STARRED") >= 0
  next.inInbox = labels.indexOf("INBOX") >= 0
  return next
}

// Skeleton rows replace only an empty list's first fetch. Loading another page
// leaves useful messages in place and reports its progress at the list foot.
// ------------------------------------------------------------- reading zoom
//
// The body's zoom is the one size in the window that belongs to the reader
// rather than to the theme: Omarchy sets the font scale the chrome follows,
// and this is somebody leaning in to one message. It is kept because it is not
// about one message — somebody who needed the text bigger needs it bigger for
// their mail.
//
// A twentieth per step, so Ctrl+scroll lands on values it can land on again
// and a saved one reads back as what was set. The bounds are where a message
// stops being a message: a smudge below, a poster above.
var ZOOM_MIN = 0.6
var ZOOM_MAX = 2.5
var ZOOM_STEPS_PER_UNIT = 20

// What a zoom read back off disk means. Anything that is not a number is a
// file that was hand-edited or never written, and the answer to both is the
// size it shipped at.
function clampZoom(value) {
  if (value === null || value === undefined || value === "") return 1
  var zoom = Number(value)
  if (!isFinite(zoom)) return 1
  return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX,
    Math.round(zoom * ZOOM_STEPS_PER_UNIT) / ZOOM_STEPS_PER_UNIT))
}

function zoomAfterStep(zoom, step) {
  var by = Number(step)
  return clampZoom(clampZoom(zoom) + (isFinite(by) ? by : 0))
}

function showInitialListSkeleton(loading, messageCount) {
  return !!loading && Math.max(0, Number(messageCount) || 0) === 0
}

function showListFooter(messageCount) {
  return Math.max(0, Number(messageCount) || 0) > 0
}

// Which mailboxes a merged list can show.
//
// Inbox and Unread are the two every provider maps the same way — "folder:INBOX"
// and "folder:INBOX UNSEEN" on IMAP, "in:inbox" and its unread form on Gmail.
// Sent, Archive and Trash resolve to a different folder per server and are
// missing on some, so a merged one of those would draw from fewer accounts
// than the rail implies without saying so.
var UNIFIED_MAILBOXES = ["inbox", "unread"]

function isUnifiedMailbox(key) {
  var wanted = String(key || "")
  for (var i = 0; i < UNIFIED_MAILBOXES.length; i++) {
    if (UNIFIED_MAILBOXES[i] === wanted) return true
  }
  return false
}

// Newest first, for a list merged from several mailboxes whose servers
// answered independently.
//
// The order is by when the message was *received* — `summarize` takes `date`
// from IMAP's INTERNALDATE and Gmail's internalDate, not from the sender's
// own Date header, which is sender-controlled and can be wrong by days.
//
// An undated row sorts after every dated one, and undated rows sort among
// themselves by arrival number and then by account. A page fetched while a
// server was throttling can arrive with content and no INTERNALDATE, and a
// comparator that called every such row equal collapsed half a list out of
// order — the numeric part of the id is the fallback, because an IMAP UID
// rises with arrival within a folder.
//
// One rule for undated rows, not two. The previous comparator had them placed
// by UID against a dated row of the same account and "dated leads" against a
// dated row of another, and those two rules cycle: with A dated uid 5, B
// undated uid 10 in the same account, and C dated in another account, B beats
// A, A ties-breaks against C, and C beats B — so the same three rows sorted
// from six permutations gave three different orders. A comparator that is not
// a total order is not merely untidy: Array.prototype.sort is free to produce
// anything at all from one, and the merged list reshuffled between relayouts
// with rows moving under the pointer.
//
// The cost of the single rule is that an undated row lands at the end rather
// than near where its UID says it belongs. That is the honest place for it:
// the list is ordered by when mail arrived, and a row with no arrival time has
// no position in that order to claim. It is also rare — a throttled page — and
// self-correcting, because the next load brings the date.
//
// Ties break on account and then id so the order is total. Two messages
// sharing a timestamp must not swap places between relayouts, or a row moves
// under the pointer for no reason the user can see.
function receivedRank(summary) {
  if (!summary) return 0
  var at = summary.date ? Number(summary.date) : 0
  if (isFinite(at) && at > 0) return at
  return 0
}

function arrivalRank(summary) {
  var match = String((summary && summary.id) || "").match(/^(\d+)/)
  return match ? Number(match[1]) : 0
}

function byReceivedDescending(a, b) {
  var left = receivedRank(a)
  var right = receivedRank(b)

  // Dated before undated, always. This is the one rule, and having only one is
  // what makes the order total.
  if ((left > 0) !== (right > 0)) return left > 0 ? -1 : 1

  // Both dated: newest first.
  if (left > 0 && left !== right) return right - left

  // Both undated: by arrival number, which within one account is the order the
  // dates would have given. Across accounts it compares nothing meaningful,
  // but it is consistent, and the account tie-break below settles the rest.
  if (left === 0) {
    var undated = arrivalRank(b) - arrivalRank(a)
    if (undated !== 0) return undated
  }

  var leftAccount = String((a && a.accountId) || "")
  var rightAccount = String((b && b.accountId) || "")
  if (leftAccount !== rightAccount) return leftAccount < rightAccount ? -1 : 1
  var leftId = String((a && a.id) || "")
  var rightId = String((b && b.id) || "")
  if (leftId === rightId) return 0
  return leftId < rightId ? -1 : 1
}

// ----------------------------------------------------------- spreading load
//
// Several mailboxes on one server open their connections in the same tick, and
// a server that rations concurrent connections refuses some of them outright.
// The unread poll already spreads itself this way; the window-open and startup
// loads did not, and they are the bigger burst: opening the window runs a
// profile read, a send-as read, a count and a list load per account, so five
// accounts is twenty processes at once, which is the shape the server was
// refusing.
//
// Derived from the account id so it is stable across restarts rather than
// random — the same mailbox waits the same fraction every time, which is
// debuggable — and bounded to a fraction of the interval so no mailbox is ever
// meaningfully later than any other.
function spreadHash(accountId) {
  var id = String(accountId || "")
  var hash = 0
  for (var i = 0; i < id.length; i++) hash = ((hash << 5) - hash + id.charCodeAt(i)) | 0
  return Math.abs(hash)
}

// The poll's own offset: a quarter of the refresh interval, which spreads four
// mailboxes on one host across the gap between polls.
function pollOffsetMs(accountId, refreshIntervalSec) {
  if (String(accountId || "") === "") return 0
  var spread = Math.max(1, Math.floor(Number(refreshIntervalSec) * 250))
  return spreadHash(accountId) % spread
}

// The offset before a window-open or startup load. Much shorter than the
// poll's, because this one is in front of somebody who has just opened the
// window: it has to spread the connections without the list visibly waiting
// for them. Under a second across any number of mailboxes.
var OPEN_SPREAD_MS = 900

function openOffsetMs(accountId) {
  if (String(accountId || "") === "") return 0
  return spreadHash(accountId) % OPEN_SPREAD_MS
}

// --------------------------------------------------------- rebuilding a list
//
// Whether a new page of summaries is worth assigning over the list that is on
// screen. `messages` is a plain JS array bound to a `Repeater`, so a new array
// identity destroys and recreates every delegate — and a `MessageRow` is about
// twenty-seven objects including three Canvas icons and three tooltip Popups.
// A poll that found nothing new was rebuilding the whole list anyway, several
// times per cycle and once per account in a merged view.
//
// Compared field by field, over what a row draws plus what decides where a row
// belongs. Comparing the objects by identity would answer "changed" every
// time, because each load builds fresh summaries out of fresh payloads.
//
// `subject`, `snippet`, `unread` and `starred` are drawn; `from` is drawn
// through its display name and address; `date` is what `time` is derived from
// and what the merged order sorts on; `id` and `accountId` are the row's
// identity; `labelIds` is what decides whether an action leaves the row in
// this mailbox. Nothing else in a summary reaches the list.
var ROW_FIELDS = ["id", "accountId", "subject", "snippet", "date",
  "unread", "starred"]

function sameRow(a, b) {
  if (!a || !b) return a === b
  for (var i = 0; i < ROW_FIELDS.length; i++) {
    var field = ROW_FIELDS[i]
    if (!sameField(a[field], b[field])) return false
  }
  if (!sameParty(a.from, b.from)) return false
  return sameLabels(a.labelIds, b.labelIds)
}

// `date` is a Date, and every load builds a fresh one out of a fresh payload —
// two Dates for one instant are never `===`. Comparing them by identity made
// every list differ from itself, which would have left the whole comparison
// inert while looking like it worked.
function sameField(left, right) {
  if (left === right) return true
  // Both absent counts as the same: a summary hydrated from an older cache
  // simply has fewer fields than one off the wire.
  var leftEmpty = left === undefined || left === null
  var rightEmpty = right === undefined || right === null
  if (leftEmpty || rightEmpty) return leftEmpty && rightEmpty
  // Duck-typed rather than `instanceof Date`, which is per-realm: the node
  // tests build their dates outside the vm context the module runs in, so
  // `instanceof` is false there and the comparison would be exercised by
  // nothing while looking correct in the shell.
  if (isDateLike(left) && isDateLike(right)) {
    var leftAt = Number(left)
    var rightAt = Number(right)
    // An invalid date is NaN, which is not equal to itself. Two of them are
    // the same absence of a date.
    if (!isFinite(leftAt) && !isFinite(rightAt)) return true
    return leftAt === rightAt
  }
  return false
}

function isDateLike(value) {
  return !!value && typeof value.getTime === "function"
}

function sameLabels(a, b) {
  var left = Array.isArray(a) ? a : []
  var right = Array.isArray(b) ? b : []
  if (left.length !== right.length) return false
  for (var i = 0; i < left.length; i++) {
    if (String(left[i]) !== String(right[i])) return false
  }
  return true
}

function sameParty(a, b) {
  var leftEmail = String((a && a.email) || "")
  var rightEmail = String((b && b.email) || "")
  if (leftEmail !== rightEmail) return false
  return String((a && a.displayName) || "") === String((b && b.displayName) || "")
}

function sameList(a, b) {
  var left = Array.isArray(a) ? a : []
  var right = Array.isArray(b) ? b : []
  if (left.length !== right.length) return false
  for (var i = 0; i < left.length; i++) {
    if (!sameRow(left[i], right[i])) return false
  }
  return true
}

// A page appended to the list it already holds, with the seam row dropped.
//
// IMAP has no page token: it re-runs the whole SEARCH and slices
// `[offset, offset + limit]`, so a message that arrives between two pages
// pushes the boundary down and the first row of the new page is the last row
// of the old one. Gmail's own token is stable, but a retried page is not.
// Nothing deduplicated, so the seam row appeared twice — and in a merged list
// there is one seam per account.
function appendPage(current, page) {
  var existing = Array.isArray(current) ? current : []
  var added = Array.isArray(page) ? page : []
  var out = existing.slice()
  for (var i = 0; i < added.length; i++) {
    var summary = added[i]
    if (!summary) continue
    if (indexById(out, summary.id, summary.accountId) >= 0) continue
    out.push(summary)
  }
  return out
}

// ------------------------------------------------------- opening a message
//
// What a select still has to ask the server for, once the body cache has
// answered. A body never changes after it is fetched — which is what makes the
// cache correct at all — so a hit leaves exactly one thing that can have moved
// since: whether the message is still unread. That is a summary fetch, not the
// whole message.
//
// Before this, a cached open did the full fetch every time and painted nothing
// early: the cache set the body properties but never `selectedMessage`, and
// every visible part of the reader is gated on that summary. So the cache
// bought one skipped sanitize parse and nothing the user could see, while the
// reader drew its skeleton until the network answered — on IMAP a whole new
// process, TLS handshake, LOGIN, SELECT and `UID FETCH BODY.PEEK[]` of the
// entire message.
//
// `painted` is whether the cache had the body *and* the list still holds the
// row it belongs to. Without the row there is no summary to show, so the fetch
// has to bring one.
function detailFetchPlan(cacheHit, rowKnown) {
  var painted = cacheHit === true && rowKnown === true
  return ({
    // Whether to ask for the whole message rather than its headers.
    whole: !painted,
    // Whether the reader can stop drawing its skeleton now.
    paintNow: painted,
    // Whether a failure from the server is worth telling the user about. A
    // message the cache already drew is on screen and correct; a notice over
    // the top of it would be about nothing they can see.
    reportFailure: !painted
  })
}

// ------------------------------------------------------------- row keys
//
// One string that names one row: the account it belongs to and the id inside
// that account. The keyboard cursor, the reader's selection, and every signal
// a row emits carry this rather than a bare id.
//
// The bare id is not an address. An IMAP UID is unique only inside its folder
// and a Gmail id only inside its account, so in a merged list two rows really
// do share one — the pair that prompted this had overlapping UID ranges. Every
// path that took a bare id resolved it to whichever account happened to hold
// it first: `j` could not walk past the duplicate, and archiving the second
// row archived the first one's message. Carrying the pair as two values was
// the alternative, and it means a second argument on every signal and a second
// property beside every `cursorId`, any one of which can be forgotten
// silently. One opaque key cannot be half-passed.
//
// The account leads because it is the half with a known shape: an account id
// is an address, or `imap:` and an address, and neither can hold the
// separator. A message id can hold anything a folder name can, so it goes
// second and the split is at the first separator only.
//
// A key with no separator is a bare id with no account, which `sameMessage`
// already reads as "any account" — that is the single-account list, where the
// id is unambiguous by construction.
var KEY_SEPARATOR = "\u001f"

function rowKey(summary) {
  if (!summary) return ""
  return messageKey(summary.id, summary.accountId)
}

function messageKey(id, accountId) {
  var wanted = String(id || "")
  if (wanted === "") return ""
  var owner = String(accountId || "")
  if (owner === "") return wanted
  return owner + KEY_SEPARATOR + wanted
}

function keyId(key) {
  var text = String(key || "")
  var at = text.indexOf(KEY_SEPARATOR)
  return at < 0 ? text : text.slice(at + KEY_SEPARATOR.length)
}

function keyAccountId(key) {
  var text = String(key || "")
  var at = text.indexOf(KEY_SEPARATOR)
  return at < 0 ? "" : text.slice(0, at)
}

// Whether a row is the one a key names. The one comparison every view makes,
// so no view has to remember to check the account as well as the id.
function keyMatches(key, summary) {
  if (!summary) return false
  var text = String(key || "")
  if (text === "") return false
  return sameMessage(summary, keyId(text), keyAccountId(text))
}

// A message is addressed by its id *and* the mailbox it came from.
//
// An IMAP UID is unique only inside one folder and a Gmail id only inside one
// account, so neither is unique across the several accounts a unified list
// merges. Two mailboxes on one server really do collide: the pair that
// prompted this had overlapping UID ranges, and fetching one account's UID
// against the other answered with a bare protocol preamble rather than a
// message. Matching on the id alone would archive or trash whichever of the
// two happened to be first in the list.
//
// A summary carries `accountId` from `applySummaries`. Where the caller has no
// account in mind it passes "", which matches any — that is the single-account
// list, where the id is unambiguous by construction and every summary agrees.
function sameMessage(summary, id, accountId) {
  if (!summary || summary.id !== id) return false
  var wanted = String(accountId || "")
  if (wanted === "") return true
  var owner = String(summary.accountId || "")
  // A summary from before the account was tagged answers to any account, so a
  // cache written by an older version stays usable rather than going inert.
  return owner === "" || owner === wanted
}

function removeById(list, id, accountId) {
  var source = Array.isArray(list) ? list : []
  var out = []
  for (var i = 0; i < source.length; i++) {
    if (sameMessage(source[i], id, accountId)) continue
    out.push(source[i])
  }
  return out
}

function replaceById(list, summary) {
  var source = Array.isArray(list) ? list : []
  if (!summary) return source.slice()
  var out = []
  for (var i = 0; i < source.length; i++) {
    out.push(sameMessage(source[i], summary.id, summary.accountId)
      ? summary : source[i])
  }
  return out
}

function indexById(list, id, accountId) {
  var source = Array.isArray(list) ? list : []
  for (var i = 0; i < source.length; i++) {
    if (sameMessage(source[i], id, accountId)) return i
  }
  return -1
}

// The same lookup for a row key, which is what the view layer holds.
function indexByKey(list, key) {
  var text = String(key || "")
  if (text === "") return -1
  return indexById(list, keyId(text), keyAccountId(text))
}

// The rail as one numbered list, in the order it is drawn: the provider's
// mailboxes first, then the labels or folders the server reported. Both the
// sidebar's badges and the keys that jump read this, so the number beside a row
// and the row a number opens cannot disagree — describing the order twice is
// how they would.
//
// Ten because the keys are digits. Past that a row simply has no number: a
// mailbox nobody can reach by keyboard is honest, and renumbering the rail
// every time the server reports a label would not be.
function sidebarSlots(mailboxes, labels, limit) {
  var max = Math.max(0, Math.floor(Number(limit) || 0))
  var out = []
  var boxes = Array.isArray(mailboxes) ? mailboxes : []
  for (var i = 0; i < boxes.length && out.length < max; i++) {
    if (!boxes[i] || !boxes[i].key) continue
    out.push({ kind: "mailbox", key: String(boxes[i].key), name: String(boxes[i].label || "") })
  }
  var all = Array.isArray(labels) ? labels : []
  for (var j = 0; j < all.length && out.length < max; j++) {
    if (!all[j] || all[j].system) continue
    out.push({ kind: "label", id: String(all[j].id || ""),
      name: String(all[j].rawName || all[j].name || "") })
  }
  return out
}

// What a row's badge says, and 0 for a row past the tenth. One-based, because
// the badge is read by a person rather than indexed by anything.
function slotNumberOf(slots, kind, handle) {
  var list = Array.isArray(slots) ? slots : []
  for (var i = 0; i < list.length; i++) {
    if (list[i].kind !== kind) continue
    if (String(kind === "mailbox" ? list[i].key : list[i].id) !== String(handle)) continue
    return i + 1
  }
  return 0
}

// Where the switcher's cursor lands after a step. It wraps where the message
// list clamps, and the difference is the shape of the two things: a mailbox
// list is long and scrolls, so running off the end has to feel like an end,
// while a menu of two or three accounts that stopped at the bottom would make
// `j` do nothing on the row you use most.
function wrappedIndex(index, delta, count) {
  var total = Math.max(0, Math.floor(Number(count) || 0))
  if (total === 0) return 0
  var from = Math.floor(Number(index) || 0)
  var step = Math.floor(Number(delta) || 0)
  return ((from + step) % total + total) % total
}

// Where the list cursor lands after a step. Anchored on the cursor itself,
// because the cursor and the open message are two different things: nothing is
// open while the list is being walked, and walking must not move the reader.
// Anchoring this on the open message pinned it — every step in the list
// resolved to row 0, and in the reader the anchor never advanced.
function cursorAfterOffset(list, cursorKey, delta) {
  var source = Array.isArray(list) ? list : []
  if (source.length === 0) return ""
  var step = Math.floor(Number(delta) || 0)
  var index = indexByKey(source, cursorKey)
  // No cursor, or one whose message has left the list: start from the end the
  // move is coming from, so j opens at the top and k opens at the bottom.
  if (index < 0) return rowKey(step < 0 ? source[source.length - 1] : source[0])
  var next = index + step
  if (next < 0) next = 0
  if (next > source.length - 1) next = source.length - 1
  return rowKey(source[next])
}

// Where the cursor goes when the row it is on is about to leave the list.
// Called with the list as it still is, so the departing row still has
// neighbours: the one below takes its place, or the one above at the end.
//
// Leaving the cursor on a row that has gone is not harmless. cursorAfterOffset
// cannot find it, so it restarts at the top — which is how archiving one
// message sent the next j back to the first row.
function cursorAfterRemoval(list, cursorKey) {
  var source = Array.isArray(list) ? list : []
  var index = indexByKey(source, cursorKey)
  if (index < 0) return ""
  if (index + 1 < source.length) return rowKey(source[index + 1])
  if (index > 0) return rowKey(source[index - 1])
  return ""
}

// Where the cursor goes when the whole list is replaced under it — a mailbox
// switch, a search, a refresh that dropped things. The message it was on keeps
// it if it survived; otherwise the top, which is where the eye goes anyway.
function cursorAfterReload(list, cursorKey) {
  var source = Array.isArray(list) ? list : []
  if (source.length === 0) return ""
  var index = indexByKey(source, cursorKey)
  // Re-derived from the row rather than returned as it came in: a key that
  // named no account matched the row by id alone, and handing it back would
  // leave the cursor ambiguous for as long as it sat there.
  if (index >= 0) return rowKey(source[index])
  return rowKey(source[0])
}

// Where the scroller has to sit for a row to be on screen. The list is a Column
// in a Flickable rather than a ListView — the panel already owns a scroller and
// nesting a second one gives every wheel event two plausible targets — so there
// is no positionViewAtIndex, and keyboard movement has to say this itself.
//
// Unchanged while the row is already visible. Recentring on every press would
// drag the list under someone who is only stepping one row down it.
function contentYToReveal(contentY, viewportHeight, itemY, itemHeight,
                          contentHeight, margin) {
  var top = Number(contentY) || 0
  var view = Number(viewportHeight) || 0
  var y = Number(itemY) || 0
  var height = Number(itemHeight) || 0
  var pad = Number(margin) || 0
  var furthest = Math.max(0, (Number(contentHeight) || 0) - view)
  var next = top
  // A row that cannot fit shows its beginning. Aligning its bottom, which is
  // what the off-the-bottom rule would do, pushes the part being read away.
  if (height + pad + pad > view) next = y - pad
  else if (y - pad < top) next = y - pad
  else if (y + height + pad > top + view) next = y + height + pad - view
  if (next < 0) next = 0
  if (next > furthest) next = furthest
  return next
}

function unreadCount(list) {
  var source = Array.isArray(list) ? list : []
  var count = 0
  for (var i = 0; i < source.length; i++) {
    if (source[i] && source[i].unread) count++
  }
  return count
}

// The bar has room for a number, not for a number of digits. Past 99 the exact
// value has stopped being information anyone acts on.
function badgeText(count, cap) {
  var value = Math.max(0, Math.floor(Number(count) || 0))
  var limit = Math.max(1, Math.floor(Number(cap) || 99))
  if (value === 0) return ""
  return value > limit ? limit + "+" : String(value)
}

function barTooltip(state, email, unread, provider, authKind) {
  var name = providerName(provider)
  if (state !== "ready")
    return name + " · " + (setupHeadline(state, name, authKind) || "Not connected")
  var address = String(email || "").trim()
  var count = Math.max(0, Math.floor(Number(unread) || 0))
  var suffix = count === 0 ? "No unread mail"
    : (count === 1 ? "1 unread message" : count + " unread messages")
  return address ? address + " · " + suffix : name + " · " + suffix
}

// ------------------------------------------------------------ new mail

// Only messages the panel has not seen before, and only ones that are actually
// new rather than merely newly fetched: the first load after start must not
// fire a notification for every message already sitting in the inbox.
function newArrivals(summaries, seenIds, primed) {
  if (!primed) return []
  var list = Array.isArray(summaries) ? summaries : []
  var seen = seenIds || {}
  var arrivals = []
  for (var i = 0; i < list.length; i++) {
    var summary = list[i]
    if (!summary || !summary.unread || !summary.inInbox) continue
    if (seen[summary.id]) continue
    arrivals.push(summary)
  }
  return arrivals
}

// The desktop notification spec says a body may carry a small markup subset,
// and the daemons that implement it read one out of whatever they are handed.
// A subject is a stranger's sentence, so its angle brackets are its own — and
// an <img> left in one is a fetch made by the notification rather than by the
// reader, which is the same beacon by a different door.
//
// A leading "-" is stripped for a different reason: these values become
// arguments to notify-send, and one that starts with a dash is read as an
// option there.
function notificationText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/^[-\s]+/, "")
}

function notificationTitle(summary) {
  var title = summary && summary.from ? notificationText(summary.from.display) : ""
  return title === "" ? "New message" : title
}

function notificationBody(summary) {
  if (!summary) return ""
  var subject = notificationText(String(summary.subject || "").trim())
  var snippet = notificationText(String(summary.snippet || "").trim())
  if (!snippet) return subject
  return subject + "\n" + (snippet.length > 140 ? snippet.substring(0, 139) + "…" : snippet)
}

// ------------------------------------------------------------- formatting

function pluralize(count, singular, plural) {
  var value = Math.max(0, Math.floor(Number(count) || 0))
  return value + " " + (value === 1 ? singular : (plural || singular + "s"))
}

function resultSummary(list, estimate, hasMore) {
  var shown = Array.isArray(list) ? list.length : 0
  if (shown === 0) return "No messages"
  if (!hasMore) return pluralize(shown, "message")
  var total = Math.max(shown, Math.floor(Number(estimate) || 0))
  return shown + " of about " + total
}

function statusSummary(syncLabel) {
  return String(syncLabel || "")
}

function truncate(text, limit) {
  var value = String(text || "")
  var max = Math.max(4, Math.floor(Number(limit) || 80))
  return value.length <= max ? value : value.substring(0, max - 1) + "…"
}
