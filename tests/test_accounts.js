const assert = require("assert")
const { load, deepEqual } = require("./load")

const accounts = load("account/Accounts.js")

function account(email, extra) {
  return Object.assign({ email: email, clientId: "cid", clientSecret: "secret", label: "" }, extra || {})
}

// A list is only ever handed around, never edited in place, so every check
// below that a mutator left its input alone compares against this snapshot.
function frozen(list) {
  return JSON.stringify(list)
}

// ------------------------------------------------------------------- shape

deepEqual(accounts.emptyList(),
  { version: accounts.VERSION, accounts: [], activeId: "", unified: false })
assert.strictEqual(accounts.VERSION, 1)
assert.strictEqual(accounts.count(accounts.emptyList()), 0)

// Signed-in state is not account existence. Adding while every saved account
// is signed out must append; only a list made entirely of pending placeholders
// may reuse one instead of creating another row.
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "saved@example.com", email: "saved@example.com" }
] }), true)
assert.strictEqual(accounts.hasSavedAccounts({ accounts: [
  { id: "", email: "" }
] }), false)
assert.strictEqual(accounts.active(accounts.emptyList()), null)
assert.strictEqual(accounts.find(accounts.emptyList(), "a@example.com"), null)

// Painting a mailbox. By position rather than by id, because a mailbox that
// has not signed in yet has no id and is still a row the user can paint.

let painters = accounts.add(accounts.add(accounts.emptyList(),
  account("ada@example.com")), account("bob@example.com"))
let onlySecond = accounts.setColorAt(painters, 1, "#4C9EDE")
assert.strictEqual(onlySecond.accounts[1].color, "#4c9ede")
assert.strictEqual(onlySecond.accounts[0].color, "", "the other mailbox is untouched")
assert.strictEqual(accounts.load(accounts.serialize(onlySecond)).accounts[1].color, "#4c9ede")

// The rest of the entry survives being painted. Rebuilding an account by
// naming the fields to keep is how an IMAP mailbox came back as a Gmail one.
let imapPainted = accounts.setColorAt(accounts.add(accounts.emptyList(),
  { email: "jon@example.org", provider: "imap",
    imap: { imapHost: "mail.example.org", username: "jon@example.org" } }), 0, "#57ab5a")
assert.strictEqual(imapPainted.accounts[0].provider, "imap")
assert.strictEqual(imapPainted.accounts[0].imap.imapHost, "mail.example.org")
assert.strictEqual(imapPainted.accounts[0].color, "#57ab5a")

assert.strictEqual(accounts.setColorAt(onlySecond, 1, "").accounts[1].color, "",
  "and it can be taken off again")
assert.strictEqual(accounts.setColorAt(onlySecond, 0, "nonsense").accounts[0].color, "",
  "an unparseable colour is not stored")
// An index nobody has is a no-op rather than a thrown error or a grown list.
assert.strictEqual(accounts.count(accounts.setColorAt(onlySecond, 9, "#fff")), 2)
assert.strictEqual(accounts.count(accounts.setColorAt(onlySecond, -1, "#fff")), 2)

// ----------------------------------------------------------------- unified
//
// Whether the window is showing every mailbox at once. Kept beside activeId
// rather than replacing it: turning the merged view off has to come back to
// the mailbox the user was last in.

let pair = accounts.add(accounts.add(accounts.emptyList(),
  account("ada@example.com")), account("bob@example.com"))
assert.strictEqual(accounts.isUnified(pair), false, "off unless asked for")

let merged = accounts.setUnified(pair, true)
assert.strictEqual(accounts.isUnified(merged), true)
assert.strictEqual(merged.activeId, pair.activeId, "the mailbox to return to is kept")
assert.strictEqual(accounts.isUnified(accounts.load(accounts.serialize(merged))), true,
  "and it survives the trip to disk")
assert.strictEqual(accounts.isUnified(accounts.setUnified(merged, false)), false)

// One mailbox is not several. A unified view over a single account is that
// account, and a row offering it would be describing nothing.
let alone = accounts.setUnified(accounts.add(accounts.emptyList(),
  account("ada@example.com")), true)
assert.strictEqual(accounts.isUnified(alone), false)
assert.strictEqual(accounts.isUnified(accounts.load(accounts.serialize(alone))), false,
  "and a hand-edited file cannot ask for it either")

// Removing the second mailbox leaves nothing to merge.
let reduced = accounts.remove(merged, "bob@example.com")
assert.strictEqual(accounts.isUnified(reduced), false)

// ------------------------------------------------- which mailboxes merge
//
// The merged view draws from the mailboxes the user has left in it. Absent
// means in, so an accounts.json written before this field existed merges every
// mailbox exactly as it did, and an account added afterwards joins the merged
// list rather than quietly staying out of a view already on screen.

assert.strictEqual(accounts.isMerged({ email: "a@example.com" }), true,
  "an account that was never asked is in the merged view")
assert.strictEqual(accounts.isMerged({ merged: true }), true)
assert.strictEqual(accounts.isMerged({ merged: false }), false)
assert.strictEqual(accounts.isMerged(null), true)
// Only an explicit false takes a mailbox out. A hand-edited file with a string
// or a number in the field must not be read as "excluded" by accident.
assert.strictEqual(accounts.isMerged({ merged: 0 }), true)
assert.strictEqual(accounts.isMerged({ merged: "no" }), true)

assert.strictEqual(accounts.add(accounts.emptyList(), account("ada@example.com"))
  .accounts[0].merged, true, "a new account is included")

let mergeTrio = accounts.add(accounts.add(accounts.add(accounts.emptyList(),
  account("ada@example.com")), account("bob@example.com")), account("cy@example.com"))
assert.strictEqual(accounts.mergedCount(mergeTrio), 3)
assert.strictEqual(accounts.offersUnified(mergeTrio), true)

// Taking one out. By position, like the colour: a mailbox that has not signed
// in yet has no id and is still a row with a switch on it.
const beforeExclude = frozen(mergeTrio)
let bobLeftOut = accounts.setMergedAt(mergeTrio, 1, false)
assert.strictEqual(frozen(mergeTrio), beforeExclude, "setMergedAt leaves its input alone")
assert.strictEqual(bobLeftOut.accounts[1].merged, false)
assert.strictEqual(bobLeftOut.accounts[0].merged, true, "the others are untouched")
assert.strictEqual(bobLeftOut.accounts[2].merged, true)
assert.strictEqual(accounts.mergedCount(bobLeftOut), 2)
assert.strictEqual(accounts.count(bobLeftOut), 3,
  "an excluded mailbox is still an account")
// The ids, which is what the merging bindings in `Service.qml` name so they
// re-evaluate when a mailbox is taken out. Pending rows are not in it: they
// have no id and nothing to merge.
deepEqual(accounts.mergedIds(bobLeftOut), ["ada@example.com", "cy@example.com"])
deepEqual(accounts.mergedIds(mergeTrio),
  ["ada@example.com", "bob@example.com", "cy@example.com"])
deepEqual(accounts.mergedIds(accounts.emptyList()), [])
deepEqual(accounts.mergedIds(null), [])

assert.strictEqual(accounts.includesId(accounts.mergedIds(bobLeftOut), "bob@example.com"), false)
assert.strictEqual(accounts.includesId(accounts.mergedIds(bobLeftOut), "ada@example.com"), true)
assert.strictEqual(accounts.includesId(accounts.mergedIds(bobLeftOut), "nobody@example.com"),
  false, "an account that is not there is in no view")
// A pending host has no id, and an empty one must not match the empty entries
// a merged id list can never hold anyway.
assert.strictEqual(accounts.includesId(accounts.mergedIds(bobLeftOut), ""), false)
assert.strictEqual(accounts.includesId(null, "ada@example.com"), false)

// And it survives the trip to disk, which is the whole point: a mailbox left
// out has to still be out after a restart.
let mergedReloaded = accounts.load(accounts.serialize(bobLeftOut))
assert.strictEqual(mergedReloaded.accounts[1].merged, false)
assert.strictEqual(accounts.mergedCount(mergedReloaded), 2)
assert.strictEqual(accounts.count(mergedReloaded), 3)

// Putting it back.
assert.strictEqual(accounts.mergedCount(accounts.setMergedAt(bobLeftOut, 1, true)), 3)
// Asking for the state it is already in changes nothing at all, so a binding
// that writes on every evaluation does not rewrite the file.
// The input list itself comes back, so the caller's `next === list` test is an
// honest "nothing to save" and a re-evaluated binding does not rewrite the
// file and restart every fetch.
assert.strictEqual(accounts.setMergedAt(bobLeftOut, 1, false), bobLeftOut)
assert.strictEqual(accounts.setMergedAt(mergeTrio, 0, true), mergeTrio)
// An index nobody has is a no-op rather than a thrown error or a grown list.
assert.strictEqual(accounts.setMergedAt(mergeTrio, 9, false), mergeTrio)
assert.strictEqual(accounts.setMergedAt(mergeTrio, -1, false), mergeTrio)
assert.strictEqual(accounts.count(accounts.setMergedAt(mergeTrio, 9, false)), 3)
// Nothing at all is still a list, not a null the QML side would bind to.
deepEqual(accounts.setMergedAt(null, 0, false), accounts.emptyList())

// The rest of the entry survives. Rebuilding an account by naming the fields
// to keep is how an IMAP mailbox came back as a Gmail one.
let imapExcluded = accounts.setMergedAt(accounts.add(accounts.emptyList(),
  { email: "jon@example.org", provider: "imap", color: "#57ab5a",
    imap: { imapHost: "mail.example.org", username: "jon@example.org" } }), 0, false)
assert.strictEqual(imapExcluded.accounts[0].provider, "imap")
assert.strictEqual(imapExcluded.accounts[0].imap.imapHost, "mail.example.org")
assert.strictEqual(imapExcluded.accounts[0].color, "#57ab5a")
assert.strictEqual(imapExcluded.accounts[0].merged, false)

// A row still being filled in has no id, so it has nothing to merge and is not
// one of the mailboxes that make a merged view mean something.
let oneAndADraft = accounts.add(accounts.add(accounts.emptyList(),
  account("ada@example.com")), { email: "", provider: "gmail" })
assert.strictEqual(accounts.count(oneAndADraft), 2)
assert.strictEqual(accounts.mergedCount(oneAndADraft), 1)
assert.strictEqual(accounts.offersUnified(oneAndADraft), false)

// Two included mailboxes is what a merged view needs. Excluding down to one
// turns it off on its own — the window falls back to the mailbox activeId
// still names — and the stored flag is kept, so putting a mailbox back
// restores the view rather than making the user ask for it again.
let mergedTrio = accounts.setUnified(mergeTrio, true)
assert.strictEqual(accounts.isUnified(mergedTrio), true)
let downToTwo = accounts.setMergedAt(mergedTrio, 2, false)
assert.strictEqual(accounts.isUnified(downToTwo), true, "two is still several")
let downToOne = accounts.setMergedAt(downToTwo, 1, false)
assert.strictEqual(accounts.isUnified(downToOne), false, "one mailbox is not a merged view")
assert.strictEqual(downToOne.unified, true, "but the choice is remembered")
assert.strictEqual(downToOne.activeId, mergeTrio.activeId,
  "and so is the mailbox to fall back to")
assert.strictEqual(accounts.isUnified(accounts.setMergedAt(downToOne, 1, true)), true,
  "putting one back brings the merged view back with it")

// Excluding every mailbox is allowed and is not an error: it leaves the window
// showing the one activeId names, which is what it shows with one mailbox
// included anyway. Nothing becomes unreachable — every mailbox is still a row.
let noneMerged = accounts.setMergedAt(accounts.setMergedAt(downToOne, 0, false), 2, false)
assert.strictEqual(accounts.mergedCount(noneMerged), 0)
assert.strictEqual(accounts.isUnified(noneMerged), false)
assert.strictEqual(accounts.count(noneMerged), 3, "and every mailbox is still there")
assert.strictEqual(accounts.active(noneMerged).id, "ada@example.com")
assert.strictEqual(accounts.isUnified(accounts.load(accounts.serialize(noneMerged))), false,
  "which is how it reads back too")

// Asking for the merged view with nothing to merge does not turn it on.
assert.strictEqual(accounts.setUnified(noneMerged, true).unified, false)

// A file that says unified with only one mailbox included reads back as not
// unified, the same way the UI would have left it.
assert.strictEqual(accounts.isUnified(accounts.load(JSON.stringify({
  version: accounts.VERSION,
  accounts: [
    { email: "ada@example.com" },
    { email: "bob@example.com", merged: false }
  ],
  activeId: "ada@example.com",
  unified: true
}))), false)

// An accounts.json written before the field existed merges every mailbox.
{
  const older = accounts.load(JSON.stringify({
    version: accounts.VERSION,
    accounts: [{ email: "ada@example.com" }, { email: "bob@example.com" }],
    activeId: "ada@example.com",
    unified: true
  }))
  assert.strictEqual(accounts.mergedCount(older), 2)
  assert.strictEqual(accounts.isUnified(older), true,
    "an upgrade sees exactly the merged view it had")
}

// Removing an excluded mailbox removes it, and does not disturb the rest.
{
  const gone = accounts.remove(bobLeftOut, "bob@example.com")
  assert.strictEqual(accounts.count(gone), 2)
  assert.strictEqual(accounts.mergedCount(gone), 2)
}

// ---------------------------------------------------------------- colours
//
// The stripe down a row in a unified list, so the mailbox a message arrived in
// is visible without a second column of text. Chosen rather than generated: a
// theme supplies one accent, and hues derived from it land arbitrarily close
// to each other and to the foreground on a theme that never expected several.

assert.strictEqual(accounts.normalizeColor("#abc"), "#abc")
assert.strictEqual(accounts.normalizeColor("#AABBCC"), "#aabbcc", "stored lower case")
assert.strictEqual(accounts.normalizeColor("  #ABC  "), "#abc", "trimmed")
// Only the two hex forms. This value reaches a QML `color`, where a string it
// cannot parse is an error rather than a default.
assert.strictEqual(accounts.normalizeColor("red"), "", "a colour name is not accepted")
assert.strictEqual(accounts.normalizeColor("#gg0000"), "")
assert.strictEqual(accounts.normalizeColor("#abcd"), "")
assert.strictEqual(accounts.normalizeColor(""), "")
assert.strictEqual(accounts.normalizeColor(null), "")
assert.strictEqual(accounts.normalizeColor(undefined), "")

// A colour survives the trip to disk and back.
let painted = accounts.add(accounts.emptyList(), account("ada@example.com", { color: "#FF0000" }))
assert.strictEqual(painted.accounts[0].color, "#ff0000")
assert.strictEqual(accounts.load(accounts.serialize(painted)).accounts[0].color, "#ff0000")

// A hand-edited file cannot put an unparseable colour in front of QML.
assert.strictEqual(
  accounts.load(JSON.stringify({
    version: accounts.VERSION,
    accounts: [{ email: "ada@example.com", color: "javascript:alert(1)" }],
    activeId: "ada@example.com"
  })).accounts[0].color, "")

assert.strictEqual(accounts.colorFor(painted, "ada@example.com"), "#ff0000")
assert.strictEqual(accounts.colorFor(painted, "nobody@example.com"), "",
  "an account that is not there has no colour")
assert.strictEqual(accounts.colorFor(accounts.emptyList(), ""), "")

// An account with no colour chosen is the ordinary case, and says so with an
// empty string rather than a default nobody picked.
let plain = accounts.add(accounts.emptyList(), account("bob@example.com"))
assert.strictEqual(plain.accounts[0].color, "")

// --------------------------------------------------------------- addresses

assert.strictEqual(accounts.isValidEmail("a@example.com"), true)
assert.strictEqual(accounts.isValidEmail("first.last+tag@mail.example.co.uk"), true)
assert.strictEqual(accounts.isValidEmail(""), false)
assert.strictEqual(accounts.isValidEmail("nobody"), false)
assert.strictEqual(accounts.isValidEmail("nobody@example"), false, "a bare host is not an address")
assert.strictEqual(accounts.isValidEmail("@example.com"), false)
assert.strictEqual(accounts.isValidEmail("two words@example.com"), false)
assert.strictEqual(accounts.isValidEmail(null), false)
assert.strictEqual(accounts.isValidEmail(undefined), false)

// The id is the address normalised once, because Google echoes the profile
// address back in whatever case the user typed it.
assert.strictEqual(accounts.accountId("  Ada@Example.COM "), "ada@example.com")
assert.strictEqual(accounts.accountId("nobody"), "")
assert.strictEqual(accounts.accountId(""), "")
assert.strictEqual(accounts.accountId(null), "")

// ------------------------------------------------------------------ labels

assert.strictEqual(accounts.label({ email: "ada@example.com", label: "Work" }), "Work")
assert.strictEqual(accounts.label({ email: "ada@example.com", label: "" }), "ada")
assert.strictEqual(accounts.label({ email: "", label: "" }), "New account")
assert.strictEqual(accounts.label({ email: "  ", label: "  " }), "New account")
assert.strictEqual(accounts.label(null), "New account")
assert.strictEqual(accounts.label({ email: "ada@example.com", label: "工作邮箱" }), "工作邮箱")

// --------------------------------------------------------------------- add

let one = accounts.add(accounts.emptyList(), account("Ada@Example.com"))
assert.strictEqual(accounts.count(one), 1)
assert.strictEqual(one.accounts[0].id, "ada@example.com")
assert.strictEqual(one.activeId, "ada@example.com", "the first account is the one on screen")
assert.strictEqual(accounts.active(one).id, "ada@example.com")
assert.strictEqual(accounts.find(one, "ada@example.com").clientId, "cid")
assert.strictEqual(accounts.find(one, "ADA@example.com"), null, "ids are looked up as stored")

const beforeAdd = frozen(one)
let two = accounts.add(one, account("bob@example.com", { label: "Personal" }))
assert.notStrictEqual(two, one)
assert.strictEqual(frozen(one), beforeAdd, "add leaves its input alone")
assert.strictEqual(accounts.count(two), 2)
assert.strictEqual(two.activeId, "ada@example.com", "a second account does not steal the selection")

// Re-adding an address is how a wrong client id gets corrected, so it must
// update the entry where it already sits rather than append a twin.
let corrected = accounts.add(two, account("ADA@example.com", { clientId: "cid2", label: "Work" }))
assert.strictEqual(accounts.count(corrected), 2)
assert.strictEqual(corrected.accounts[0].id, "ada@example.com", "the corrected account keeps its place")
assert.strictEqual(corrected.accounts[0].clientId, "cid2")
assert.strictEqual(corrected.accounts[0].label, "Work")
assert.strictEqual(corrected.accounts[1].id, "bob@example.com")
assert.strictEqual(corrected.activeId, "ada@example.com")

// ----------------------------------------------------------------- pending
//
// An account is created before the sign-in that reveals its address, so it
// has to exist with no id — and something with no id is not something the
// window can switch to.

let pending = accounts.add(accounts.emptyList(), account("", { clientId: "cid3" }))
assert.strictEqual(accounts.count(pending), 1)
assert.strictEqual(pending.accounts[0].id, "")
assert.strictEqual(pending.accounts[0].clientId, "cid3")
assert.strictEqual(pending.activeId, "", "a pending account cannot be active")
assert.strictEqual(accounts.active(pending), null)
assert.strictEqual(accounts.find(pending, ""), null, "an empty id names nothing")

// An unusable address is stored as typed and still has no id.
let typo = accounts.add(accounts.emptyList(), account("not-an-address"))
assert.strictEqual(typo.accounts[0].id, "")
assert.strictEqual(typo.accounts[0].email, "not-an-address")
assert.strictEqual(typo.activeId, "")

// Two pending accounts are two accounts: with no id there is nothing to
// de-duplicate them by.
let bothPending = accounts.add(pending, account("", { clientId: "cid4" }))
assert.strictEqual(accounts.count(bothPending), 2)
assert.strictEqual(bothPending.activeId, "")

// The first account with a real address takes the selection even though it is
// not the first in the list.
let settled = accounts.add(bothPending, account("ada@example.com"))
assert.strictEqual(settled.activeId, "ada@example.com")
assert.strictEqual(accounts.count(settled), 3)

// ------------------------------------------------------------------ remove

let three = accounts.add(corrected, account("cid@example.com"))
assert.strictEqual(accounts.count(three), 3)
const beforeRemove = frozen(three)

// Removing an account is destructive and happens in two steps. The first
// step only describes the target; it never mutates the list. A stale target
// is rejected when the confirmation is finally accepted.
const removal = accounts.removalRequest(three, 0)
deepEqual(removal, {
  id: "ada@example.com",
  email: "ADA@example.com",
  index: 0
})
assert.strictEqual(frozen(three), beforeRemove)
assert.strictEqual(accounts.removalRequest(three, -1), null)
assert.strictEqual(accounts.removalRequest(three, 99), null)
assert.strictEqual(accounts.removalRequest(one, 0), null,
  "the only account cannot be removed")
assert.strictEqual(accounts.removalRequest(bothPending, 1), null,
  "a draft has no stable identity and is canceled rather than removed")
assert.strictEqual(accounts.confirmRemoval(three, { id: "gone@example.com", index: 0 }), -1,
  "confirmation must not remove whichever account later occupies a stale row")
assert.strictEqual(accounts.confirmRemoval(three, removal), 0)

let withoutBob = accounts.remove(three, "bob@example.com")
assert.strictEqual(frozen(three), beforeRemove, "remove leaves its input alone")
assert.strictEqual(accounts.count(withoutBob), 2)
assert.strictEqual(accounts.find(withoutBob, "bob@example.com"), null)
assert.strictEqual(withoutBob.activeId, "ada@example.com", "removing another account keeps the selection")

// Removing what is on screen has to land somewhere, or the window has nothing
// to show.
let withoutAda = accounts.remove(three, "ada@example.com")
assert.strictEqual(accounts.count(withoutAda), 2)
assert.strictEqual(accounts.find(withoutAda, withoutAda.activeId) !== null, true)
assert.strictEqual(withoutAda.activeId, "bob@example.com")

// The last account leaves nothing to fall back to.
let lastGone = accounts.remove(accounts.remove(withoutAda, "bob@example.com"), "cid@example.com")
assert.strictEqual(accounts.count(lastGone), 0)
assert.strictEqual(lastGone.activeId, "")
assert.strictEqual(accounts.active(lastGone), null)

// The selection never lands on a pending account.
let realAndPending = accounts.add(accounts.add(accounts.emptyList(), account("ada@example.com")), account(""))
assert.strictEqual(accounts.remove(realAndPending, "ada@example.com").activeId, "")
assert.strictEqual(accounts.count(accounts.remove(realAndPending, "ada@example.com")), 1)

// An id nobody has, and the empty id a pending row would hand over, must not
// take anything out with them.
deepEqual(accounts.remove(three, "nobody@example.com"), three)
deepEqual(accounts.remove(realAndPending, ""), realAndPending, "an empty id must not sweep out every pending row")
assert.notStrictEqual(accounts.remove(three, "nobody@example.com"), three)

// --------------------------------------------------------------- setActive

const beforeSet = frozen(three)
let switched = accounts.setActive(three, "cid@example.com")
assert.strictEqual(frozen(three), beforeSet, "setActive leaves its input alone")
assert.strictEqual(switched.activeId, "cid@example.com")
assert.strictEqual(accounts.active(switched).id, "cid@example.com")
assert.strictEqual(accounts.count(switched), 3)

// A stale id means the caller is acting on a list that has moved on. Showing
// no mailbox at all is worse than still showing the previous one.
deepEqual(accounts.setActive(three, "nobody@example.com"), three)
deepEqual(accounts.setActive(three, ""), three)
deepEqual(accounts.setActive(realAndPending, ""), realAndPending)

// ------------------------------------------------------------------- load

deepEqual(accounts.load(""), accounts.emptyList())
deepEqual(accounts.load("{not json"), accounts.emptyList())
deepEqual(accounts.load("[]"), accounts.emptyList(), "an array is not a list of accounts")
deepEqual(accounts.load("null"), accounts.emptyList())
deepEqual(accounts.load(null), accounts.emptyList())
deepEqual(accounts.load(JSON.stringify({ accounts: [] })), accounts.emptyList(), "no version at all")
deepEqual(accounts.load(JSON.stringify({
  version: accounts.VERSION + 99,
  accounts: [{ id: "ada@example.com", email: "ada@example.com" }],
  activeId: "ada@example.com"
})), accounts.emptyList(), "a newer format is discarded rather than half-read")
deepEqual(accounts.load(JSON.stringify({ version: accounts.VERSION, accounts: "nope", activeId: "x" })),
  accounts.emptyList(), "accounts that is not an array")

// A selection naming an account that is not in the file — hand-edited, or
// removed while the window was closed — must not leave the window blank.
const repaired = accounts.load(JSON.stringify({
  version: accounts.VERSION,
  accounts: [{ email: "ada@example.com" }, { email: "bob@example.com" }],
  activeId: "gone@example.com"
}))
assert.strictEqual(repaired.activeId, "ada@example.com")
assert.strictEqual(repaired.accounts[0].id, "ada@example.com", "the id is recomputed from the address")

// A file listing only pending accounts has nothing to select.
const pendingFile = accounts.load(JSON.stringify({
  version: accounts.VERSION, accounts: [{ email: "" }], activeId: "ada@example.com"
}))
assert.strictEqual(accounts.count(pendingFile), 1)
assert.strictEqual(pendingFile.activeId, "")

// Junk among the entries is skipped rather than stored as an account nobody
// can click.
const messy = accounts.load(JSON.stringify({
  version: accounts.VERSION,
  accounts: [null, "ada@example.com", { email: "bob@example.com" }, 7],
  activeId: "bob@example.com"
}))
assert.strictEqual(accounts.count(messy), 1)
assert.strictEqual(messy.activeId, "bob@example.com")

// -------------------------------------------------------------- round trip

let saved = accounts.emptyList()
saved = accounts.add(saved, account("ada@example.com", { label: "工作邮箱" }))
saved = accounts.add(saved, account("bob@example.com", { label: "Personal" }))
saved = accounts.add(saved, account("", { clientId: "cid5" }))
saved = accounts.setActive(saved, "bob@example.com")

const text = accounts.serialize(saved)
// The file crosses a line-oriented pipe on its way to disk, so a newline
// anywhere in it truncates the list.
assert.strictEqual(text.indexOf("\n"), -1, "serialize must produce a single line")
assert.strictEqual(accounts.serialize(accounts.emptyList()).indexOf("\n"), -1)

const reloaded = accounts.load(text)
deepEqual(reloaded, saved, "order, ids and the selection all survive")
assert.strictEqual(reloaded.activeId, "bob@example.com")
assert.strictEqual(accounts.label(reloaded.accounts[0]), "工作邮箱", "non-ASCII labels survive")
assert.strictEqual(accounts.count(reloaded), 3)

// A label with a newline in it is still one line on disk.
const multiline = accounts.serialize(accounts.add(accounts.emptyList(), account("ada@example.com", { label: "a\nb" })))
assert.strictEqual(multiline.indexOf("\n"), -1)
assert.strictEqual(accounts.load(multiline).accounts[0].label, "a\nb")

// ------------------------------------------------------- removing by index
//
// A pending account has no id, so nothing can name it — and a sign-in that
// failed half way leaves exactly that. Position is the only handle the window
// has on one.

let pendingList = accounts.emptyList()
pendingList = accounts.add(pendingList, { email: "one@example.com", clientId: "c1" })
pendingList = accounts.add(pendingList, { email: "", clientId: "c2" })
pendingList = accounts.add(pendingList, { email: "two@example.com", clientId: "c3" })
assert.strictEqual(accounts.count(pendingList), 3)

const withoutPending = accounts.removeAt(pendingList, 1)
assert.strictEqual(accounts.count(withoutPending), 2)
assert.strictEqual(withoutPending.accounts[1].email, "two@example.com")
assert.strictEqual(accounts.count(pendingList), 3, "the input is left alone")

// Removing the active account by index hands the selection on, exactly as
// removing it by id does.
const activeGone = accounts.removeAt(withoutPending, 0)
assert.strictEqual(accounts.count(activeGone), 1)
assert.strictEqual(activeGone.activeId, "two@example.com")

// Out of range is inert rather than destructive.
assert.strictEqual(accounts.count(accounts.removeAt(pendingList, 99)), 3)
assert.strictEqual(accounts.count(accounts.removeAt(pendingList, -1)), 3)
assert.strictEqual(accounts.count(accounts.removeAt(pendingList, "nonsense")), 3)

// Cancelling Add removes only the unnamed draft. Once an address has been
// saved, Back is navigation and must not delete the account.
assert.strictEqual(accounts.count(accounts.discardDraftAt(pendingList, 1)), 2)
assert.strictEqual(accounts.count(accounts.discardDraftAt(pendingList, 0)), 3)

// ---------------------------------------------------------------- providers
//
// A mailbox is Gmail, IMAP, or HEY. The rules that matter are what an upgrade
// does to accounts written before providers existed, and what happens when one
// address is reached two different ways.

{
  // Anything unrecognised — an empty field, a newer build's name, a hand edit —
  // is Gmail, because that is what every account in an upgraded install is.
  assert.strictEqual(accounts.makeAccount({ email: "jane@gmail.com" }).provider, "gmail")
  assert.strictEqual(accounts.makeAccount({ email: "j@x.com", provider: "" }).provider, "gmail")
  assert.strictEqual(accounts.makeAccount({ email: "j@x.com", provider: "pigeon" }).provider, "gmail")
  assert.strictEqual(accounts.makeAccount({ email: "j@x.com", provider: "IMAP" }).provider, "imap")
  assert.strictEqual(accounts.makeAccount({ email: "j@x.com", provider: " hey " }).provider, "hey")

  // A Gmail account keeps the bare address as its id, so nothing already on
  // disk — its cache directory, its keyring entry, the activeId in the file —
  // needs migrating when this build first runs.
  assert.strictEqual(accounts.makeAccount({ email: "Jane@Gmail.com" }).id, "jane@gmail.com")
  assert.strictEqual(
    accounts.makeAccount({ email: "jane@fastmail.com", provider: "imap" }).id,
    "imap:jane@fastmail.com")

  // The same address reached two ways is two mailboxes, not one overwriting
  // the other.
  let list = accounts.emptyList()
  list = accounts.add(list, { email: "jane@gmail.com", provider: "gmail" })
  list = accounts.add(list, { email: "jane@gmail.com", provider: "imap" })
  assert.strictEqual(accounts.count(list), 2,
    "one address over two providers is two accounts")
  assert.strictEqual(accounts.find(list, "jane@gmail.com").provider, "gmail")
  assert.strictEqual(accounts.find(list, "imap:jane@gmail.com").provider, "imap")

  // Re-adding the same one still replaces in place rather than appending.
  list = accounts.add(list, { email: "jane@gmail.com", provider: "imap", label: "Work" })
  assert.strictEqual(accounts.count(list), 2)
  assert.strictEqual(accounts.find(list, "imap:jane@gmail.com").label, "Work")

  // Removing one leaves the other.
  list = accounts.remove(list, "imap:jane@gmail.com")
  assert.strictEqual(accounts.count(list), 1)
  assert.strictEqual(accounts.find(list, "jane@gmail.com").provider, "gmail")
}

// ------------------------------------------------------------ IMAP settings
//
// Not secret — the password is, and that lives in the keyring — so these ride
// on the account and survive the round trip through the file.

{
  const saved = accounts.serialize(accounts.add(accounts.emptyList(), {
    email: "jane@fastmail.com",
    provider: "imap",
    imap: {
      imapHost: "imap.fastmail.com", imapPort: 993,
      smtpHost: "smtp.fastmail.com", smtpPort: 465,
      username: "jane@fastmail.com"
    }
  }))
  const reloaded = accounts.find(accounts.load(saved), "imap:jane@fastmail.com")
  assert.strictEqual(reloaded.provider, "imap")
  assert.strictEqual(reloaded.imap.imapHost, "imap.fastmail.com")
  assert.strictEqual(reloaded.imap.smtpPort, 465)
  assert.strictEqual(reloaded.imap.username, "jane@fastmail.com")
  assert.strictEqual(reloaded.imap.insecure, false)

  // Ports out of range fall back rather than reaching a URL.
  const clamped = accounts.makeAccount({
    email: "j@x.com", provider: "imap",
    imap: { imapPort: 0, smtpPort: 999999 }
  })
  assert.strictEqual(clamped.imap.imapPort, 993)
  assert.strictEqual(clamped.imap.smtpPort, 465)

  // A Gmail account still serialises without IMAP settings meaning anything.
  const gmail = accounts.makeAccount({ email: "j@gmail.com", clientId: "abc" })
  assert.strictEqual(gmail.imap.imapHost, "")
  assert.strictEqual(gmail.clientId, "abc")

  // An accounts.json written by the previous build has no provider field at
  // all, and every account in it must come back as a working Gmail account.
  const legacy = accounts.load(JSON.stringify({
    version: 1,
    accounts: [{ id: "jane@gmail.com", email: "jane@gmail.com", clientId: "abc" }],
    activeId: "jane@gmail.com"
  }))
  assert.strictEqual(accounts.count(legacy), 1)
  assert.strictEqual(legacy.activeId, "jane@gmail.com",
    "the active account is still the one the user was looking at")
  assert.strictEqual(accounts.active(legacy).provider, "gmail")
  assert.strictEqual(accounts.active(legacy).clientId, "abc")
}

console.log("test_accounts.js ok")
