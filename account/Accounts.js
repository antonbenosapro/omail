.pragma library

// The list of Gmail accounts and which one the window is showing. One account
// was the original design; several is a list plus a selection, and every rule
// about what that selection may point at lives here so the QML only has to
// paint rows and call one of these functions.
//
// Everything is pure and every mutator returns a new list: the QML side owns
// the file and the keyring, and a list handed to a view must not change under
// it after it has been rendered.

var VERSION = 1

// Not RFC 5322 — that is unimplementable and the wrong question anyway. This
// only has to separate "an address Google could have given us" from a blank
// field or a typed-in fragment, so a domain with a dot in it is the test.
var EMAIL_PATTERN = /^[^\s@]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/

function emptyList() {
  return { version: VERSION, accounts: [], activeId: "", unified: false }
}

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function isValidEmail(value) {
  return EMAIL_PATTERN.test(trimmed(value))
}

// Addresses are case-insensitive in practice and a server echoes the address
// back in whatever case it was typed, so it is normalised once here and
// everything downstream compares ids rather than emails.
//
// One address can also legitimately be two mailboxes: a Gmail account reached
// through Google's API, and the same address reached over IMAP with an app
// password. Keyed on the address alone they would be one entry, each sign-in
// overwriting the other's.
//
// A Gmail account keeps the bare address as its id, so nothing already on disk
// — its cache directory, its keyring entry, the activeId in accounts.json —
// has to be migrated. Only the providers that did not exist before carry a
// prefix.
function accountId(email, provider) {
  if (!isValidEmail(email)) return ""
  var address = trimmed(email).toLowerCase()
  var kind = normalizeProvider(provider)
  return kind === DEFAULT_PROVIDER ? address : kind + ":" + address
}

// Which service this mailbox is. Anything unrecognised — and, importantly,
// anything written before providers existed — is Gmail: that is what every
// account in an upgraded install actually is, and defaulting to it is what
// stops an upgrade from presenting a working mailbox as unconfigured.
var PROVIDERS = ["gmail", "imap", "hey"]
var DEFAULT_PROVIDER = "gmail"

function normalizeProvider(value) {
  var name = trimmed(value).toLowerCase()
  for (var i = 0; i < PROVIDERS.length; i++) {
    if (PROVIDERS[i] === name) return name
  }
  return DEFAULT_PROVIDER
}

// The server settings an IMAP account needs. Kept on the account rather than
// in the credentials file because none of it is secret — the password is the
// secret, and that lives in the keyring. A host here is not trusted: `Imap.js`
// validates it again before it can reach a URL.
// A port out of range falls back to the default rather than being clamped into
// range. Clamping turns 999999 into 65535 — a port that is valid, reachable and
// not the one anybody meant, which fails as a connection nobody can explain.
// The same rule as `Imap.normalizedPort`, deliberately: two normalisers that
// disagree about the same field is a bug waiting for the one caller that uses
// the other one.
function portOr(value, fallback) {
  var port = Math.floor(Number(value))
  if (!isFinite(port) || port < 1 || port > 65535) return fallback
  return port
}

function makeImapSettings(raw) {
  var values = raw || {}
  return {
    imapHost: trimmed(values.imapHost),
    imapPort: portOr(values.imapPort, 993),
    smtpHost: trimmed(values.smtpHost),
    smtpPort: portOr(values.smtpPort, 465),
    username: trimmed(values.username),
    insecure: values.insecure === true
  }
}

// The address arrives with the first successful sign-in for Gmail, and is
// typed by hand for IMAP, so an account exists for a while with no id at all.
// Such an entry is kept — it holds the OAuth client or the server settings the
// sign-in needs — but it is not addressable, and the guard in indexOfId is what
// keeps it out of every lookup.
function makeAccount(account) {
  var raw = account || {}
  var email = trimmed(raw.email)
  var provider = normalizeProvider(raw.provider)
  return {
    id: accountId(email, provider),
    email: email,
    provider: provider,
    clientId: trimmed(raw.clientId),
    clientSecret: trimmed(raw.clientSecret),
    imap: makeImapSettings(raw.imap),
    label: trimmed(raw.label),
    color: normalizeColor(raw.color),
    // Whether this mailbox is one of the ones the merged view merges. Absent
    // means yes: every account written before this field existed was in the
    // merged list, and so is every account added afterwards, so an install
    // that never opens this setting behaves exactly as it did.
    merged: raw.merged !== false
  }
}

function copyList(list) {
  var source = list || emptyList()
  return {
    version: VERSION,
    accounts: Array.isArray(source.accounts) ? source.accounts.slice() : [],
    activeId: String(source.activeId || ""),
    // Whether the window is showing every mailbox at once. `activeId` is kept
    // either way: turning the unified view off has to come back to the mailbox
    // the user was last in, not to an arbitrary one.
    unified: source.unified === true
  }
}

// An empty id matches nothing, deliberately: it is what every pending account
// carries, and letting it match would make find, setActive and remove all act
// on an arbitrary one of them.
function indexOfId(accounts, id) {
  var key = trimmed(id)
  if (!key) return -1
  for (var i = 0; i < accounts.length; i++) {
    if (accounts[i] && accounts[i].id === key) return i
  }
  return -1
}

function find(list, id) {
  var source = copyList(list)
  var at = indexOfId(source.accounts, id)
  return at < 0 ? null : source.accounts[at]
}

function active(list) {
  return find(list, (list || {}).activeId)
}

function count(list) {
  var source = list || {}
  return Array.isArray(source.accounts) ? source.accounts.length : 0
}

// A pending row is implementation detail, not an account. In particular this
// must not be inferred from whether a host is signed in: sessions are restored
// asynchronously, and signed-out accounts still exist and must never be
// overwritten by Add account.
function hasSavedAccounts(list) {
  var source = list || {}
  var values = Array.isArray(source.accounts) ? source.accounts : []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i] || {}
    if (trimmed(entry.id) !== "" || trimmed(entry.email) !== "") return true
  }
  return false
}

// Shown in the switcher. A pending account has neither a label nor an address
// yet and still needs a name, or its row is an empty strip nobody can aim at.
function label(account) {
  var raw = account || {}
  var name = trimmed(raw.label)
  if (name) return name
  var local = trimmed(raw.email).split("@")[0]
  return local || "New account"
}

// The stripe down the left of every row this account owns, so a merged list
// says which mailbox a message arrived in without a second column of text.
//
// Chosen by the user rather than generated: a theme supplies one accent, and
// hues derived from it land arbitrarily close to each other and to the
// foreground on a theme that never anticipated several of them. An empty
// string is "no colour", which is what every account has until asked.
//
// Only `#rgb` and `#rrggbb` are accepted. QML would take a colour name too,
// but this value reaches a `color` property where a string it cannot parse is
// an error rather than a default, so anything unrecognised becomes "" here.
var COLOR_PATTERN = /^#([0-9a-f]{3}|[0-9a-f]{6})$/

function normalizeColor(value) {
  var text = trimmed(value).toLowerCase()
  return COLOR_PATTERN.test(text) ? text : ""
}

function colorFor(list, id) {
  var entry = find(list, id)
  return entry ? normalizeColor(entry.color) : ""
}

// ------------------------------------------------------------------ edits

// Re-adding an address is how a wrong client id or a new label gets corrected,
// so it replaces the entry where it already sits. Appending instead would show
// the same mailbox twice, and moving it to the end would lose the order the
// user put their accounts in.
function add(list, account) {
  var next = copyList(list)
  var entry = makeAccount(account)
  var at = indexOfId(next.accounts, entry.id)
  if (at >= 0) next.accounts[at] = entry
  else next.accounts.push(entry)
  // Nothing is on screen until the first account with a real address arrives;
  // once one has, adding another must not yank the view away from it.
  if (entry.id && indexOfId(next.accounts, next.activeId) < 0) next.activeId = entry.id
  return next
}

// The neighbour that slides into the removed row is the least surprising
// replacement, and the scan wraps so removing the last row falls back up the
// list. Pending accounts are skipped: the window cannot show one.
function nextActiveId(accounts, from) {
  for (var i = 0; i < accounts.length; i++) {
    var entry = accounts[(from + i) % accounts.length]
    if (entry && entry.id) return entry.id
  }
  return ""
}

function remove(list, id) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at < 0) return next
  var wasActive = next.accounts[at].id === next.activeId
  next.accounts.splice(at, 1)
  if (wasActive) next.activeId = nextActiveId(next.accounts, at)
  return next
}

// An id that is not in the list means the caller is acting on a list that has
// moved on. Leaving the previous account on screen is better than blanking the
// window, so an unknown id — "" included — changes nothing.
// An account that never finished signing in has no id, so nothing can name it
// — and a failed sign-in leaves exactly that. Removing by position is the only
// handle the window has on one.
function removeAt(list, index) {
  var source = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= source.accounts.length) return source
  var removed = source.accounts[at]
  source.accounts.splice(at, 1)
  if (removed.id !== "" && source.activeId === removed.id)
    source.activeId = nextActiveId(source.accounts, at)
  return source
}

// The request is an immutable description of the row the user saw. Keeping
// both its id and position lets confirmation reject a stale request instead of
// deleting whichever account later moved into the same row.
function removalRequest(list, index) {
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  if (values.length <= 1) return null
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= values.length) return null
  var entry = values[at] || {}
  if (!entry.id) return null
  return { id: String(entry.id || ""), email: String(entry.email || ""), index: at }
}

function confirmRemoval(list, request) {
  if (!request) return -1
  var values = Array.isArray((list || {}).accounts) ? list.accounts : []
  var at = Math.floor(Number(request.index))
  if (!isFinite(at) || at < 0 || at >= values.length) return -1
  var entry = values[at] || {}
  var id = String(request.id || "")
  return id !== "" && String(entry.id || "") === id ? at : -1
}

function discardDraftAt(list, index) {
  var source = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= source.accounts.length) return source
  if (source.accounts[at].id !== "") return source
  return removeAt(source, at)
}

// ------------------------------------------------------- what gets merged
//
// Which mailboxes the merged view draws from. An account is in it unless the
// user took it out, so an install that never opens this setting sees exactly
// what it saw before the setting existed, and an account added later joins the
// merged list rather than silently staying out of a view the user is looking at.
//
// This is only about the merged view. An excluded mailbox is untouched
// everywhere else: it still polls, still counts toward the bar's badge, and is
// still one row in the switcher that shows its own mail when chosen.

function isMerged(account) {
  var entry = account || {}
  return entry.merged !== false
}

// Only accounts that could appear in a list at all. A row still being filled
// in has no id, so it has nothing to merge and cannot be counted as one of the
// two mailboxes that make a merged view mean something.
function mergedAccounts(list) {
  var source = list || {}
  var values = Array.isArray(source.accounts) ? source.accounts : []
  var out = []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i] || {}
    if (trimmed(entry.id) === "") continue
    if (isMerged(entry)) out.push(entry)
  }
  return out
}

function mergedCount(list) {
  return mergedAccounts(list).length
}

// The ids the merged view draws from. A QML binding cannot depend on what a
// function reads, so the merging bindings in `Service.qml` name this value and
// then re-evaluate when it changes — which is what makes taking a mailbox out
// of the merged view redraw the list rather than leaving mail in it that the
// view no longer merges.
function mergedIds(list) {
  var values = mergedAccounts(list)
  var out = []
  for (var i = 0; i < values.length; i++) out.push(String(values[i].id))
  return out
}

// Membership in that list, kept here beside what builds it: a caller that
// compared with `indexOf` would be one place that could disagree about how an
// id is normalised.
function includesId(ids, id) {
  var values = Array.isArray(ids) ? ids : []
  var key = trimmed(id)
  if (!key) return false
  for (var i = 0; i < values.length; i++) {
    if (String(values[i]) === key) return true
  }
  return false
}

// Taking a mailbox in or out. By position rather than by id, for the same
// reason colours are: a mailbox that has not signed in yet has no id, and it
// is still a row with a switch on it.
//
// Nothing here turns the merged view off. Deselecting down to one mailbox
// makes `isUnified` false on its own — the view falls back to the single
// mailbox `activeId` still names — and the stored `unified` flag is kept, so
// putting a second mailbox back restores the merged view the user chose.
//
// The input list is handed straight back when nothing would change, so the
// caller's `next === list` test is an honest "nothing to save": a binding that
// re-evaluates does not rewrite accounts.json and restart every fetch.
function setMergedAt(list, index, on) {
  if (!isObject(list)) return copyList(list)
  var at = Math.floor(Number(index))
  var values = Array.isArray(list.accounts) ? list.accounts : []
  if (!isFinite(at) || at < 0 || at >= values.length) return list
  if (isMerged(values[at]) === (on === true)) return list

  var next = copyList(list)
  var entry = next.accounts[at]
  var wanted = on === true
  // Rebuilt through makeAccount rather than edited, so an entry cannot end up
  // with a shape the rest of this file does not expect.
  var replacement = {}
  for (var key in entry) replacement[key] = entry[key]
  replacement.merged = wanted
  next.accounts = next.accounts.slice()
  next.accounts[at] = makeAccount(replacement)
  return next
}

// Turning the unified view on and off. `activeId` is untouched, so the view
// remembers which mailbox to come back to.
function setUnified(list, on) {
  var next = copyList(list)
  next.unified = on === true && mergedCount(next) > 1
  return next
}

// One mailbox is not several, and that is true whether the second one was
// never added or was taken out of the merged view. Below two included
// mailboxes there is nothing to merge, so the window shows the single mailbox
// `activeId` names instead of a "merged" list with one account in it.
function isUnified(list) {
  var source = list || {}
  return source.unified === true && mergedCount(source) > 1
}

// Whether the merged view is worth offering at all: the switcher's row and the
// settings switches are drawn from this rather than from the raw account
// count, so a row never promises a view that would show one mailbox.
function offersUnified(list) {
  var source = list || {}
  var values = Array.isArray(source.accounts) ? source.accounts : []
  var named = 0
  for (var i = 0; i < values.length; i++) {
    if (trimmed((values[i] || {}).id) !== "") named++
  }
  return named > 1
}

// The colour a mailbox's rows are striped with. Addressed by position rather
// than by id, because a mailbox that has not signed in yet has no id and is
// still a row the user can paint.
function setColorAt(list, index, color) {
  var next = copyList(list)
  var at = Math.floor(Number(index))
  if (!isFinite(at) || at < 0 || at >= next.accounts.length) return next
  var entry = next.accounts[at]
  var wanted = normalizeColor(color)
  if (String(entry.color || "") === wanted) return next
  // Rebuilt through makeAccount rather than edited, so an entry cannot end up
  // with a shape the rest of this file does not expect.
  var replacement = {}
  for (var key in entry) replacement[key] = entry[key]
  replacement.color = wanted
  next.accounts = next.accounts.slice()
  next.accounts[at] = makeAccount(replacement)
  return next
}

function setActive(list, id) {
  var next = copyList(list)
  var at = indexOfId(next.accounts, id)
  if (at >= 0) next.activeId = next.accounts[at].id
  return next
}

// ------------------------------------------------------------ persistence

// Anything unreadable becomes an empty list rather than an error. A user with
// a corrupt file has to be able to add an account again from the UI; a startup
// failure leaves them with nothing to do it from.
function load(text) {
  var raw = parseJson(text, null)
  if (!isObject(raw)) return emptyList()
  if (Number(raw.version) !== VERSION) return emptyList()

  var next = emptyList()
  var entries = Array.isArray(raw.accounts) ? raw.accounts : []
  for (var i = 0; i < entries.length; i++) {
    if (!isObject(entries[i])) continue
    var entry = makeAccount(entries[i])
    // The id is recomputed rather than trusted, so a hand-edited file cannot
    // introduce two entries the rest of the code believes are different
    // accounts while Gmail treats them as one.
    if (entry.id && indexOfId(next.accounts, entry.id) >= 0) continue
    next.accounts.push(entry)
  }

  var wanted = trimmed(raw.activeId).toLowerCase()
  next.activeId = indexOfId(next.accounts, wanted) >= 0 ? wanted : nextActiveId(next.accounts, 0)
  // One mailbox is not several, so a unified view over a single included
  // account is just that account — and saying so here keeps every caller from
  // having to. A hand-edited file that excludes everything reads back the same
  // way the UI would have left it: not unified, and still showing `activeId`.
  next.unified = raw.unified === true && mergedCount(next) > 1
  return next
}

// Compact rather than indented: this crosses a line-oriented pipe on the way
// to disk, so a newline in the middle of it truncates the account list. JSON
// escapes the newlines a label could contain, which is the other half of that.
function serialize(list) {
  return JSON.stringify(copyList(list))
}
