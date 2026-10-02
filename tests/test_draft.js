const assert = require("assert")
const { load, deepEqual } = require("./load")

const draft = load("message/Draft.js")
const mail = load("message/Message.js")

// ---------------------------------------------------------------- tokens
//
// The token is how IMAP finds a draft's earlier copies. It reaches a quoted
// SEARCH string and a header line, so whatever a stored draft carried in it
// is cut down to an alphabet that can end neither.

assert.strictEqual(draft.token("omail-abc-123"), "omail-abc-123")
assert.strictEqual(draft.token(' omail-a"b\\c\r\nBcc: x '), "omail-abcBccx",
  "quotes, backslashes and line breaks never survive")
assert.strictEqual(draft.token(null), "")
assert.strictEqual(draft.token("x".repeat(200)).length, 64)

const t1 = draft.newToken(1700000000000, 0.5)
assert.ok(/^omail-[a-z0-9]+-[a-z0-9]+$/.test(t1), t1)
assert.strictEqual(draft.token(t1), t1, "a new token is already a clean one")
assert.notStrictEqual(draft.newToken(1700000000000, 0.25), t1)

// IMAP's HEADER search matches substrings, so no token may be a prefix of
// another: every one is the same length, whatever the clock and the noise.
const widths = [draft.newToken(0, 0), draft.newToken(1, 0.000001), t1,
  draft.newToken(1700000000000, 0.999999), draft.newToken(99999999999999, 1)]
  .map(function(value) { return value.length })
assert.deepStrictEqual(widths, widths.map(function() { return t1.length }), "tokens are fixed width")
assert.ok(draft.newToken(1, 0.5).indexOf(draft.newToken(1, 0.03)) < 0,
  "a token with a short clock or noise does not find another inside it")

// ----------------------------------------------------------------- dirty
//
// Dirty means changed since the window was filled in or last saved — not
// non-empty. A reply opens with a quote nobody has written yet.

const reply = { from: "me@example.com", to: "jane@example.com", cc: "",
  subject: "Re: lunch", body: "\n\n> see you" }
const baseline = draft.snapshot(reply)
assert.strictEqual(draft.isDirty(baseline, reply), false, "an untouched reply is clean")
assert.strictEqual(draft.isDirty(baseline, Object.assign({}, reply, { body: "ok\n\n> see you" })), true)
assert.strictEqual(draft.isDirty(baseline, Object.assign({}, reply, { to: "bob@example.com" })), true)
assert.strictEqual(draft.isDirty(baseline, Object.assign({}, reply, { from: "alias@example.com" })), true,
  "choosing another From is a change worth keeping")
assert.strictEqual(draft.isDirty(draft.snapshot({}), { to: "", body: "" }), false,
  "missing fields and empty ones are the same compose")
assert.notStrictEqual(draft.snapshot({ to: "a,b", cc: "" }), draft.snapshot({ to: "a", cc: "b" }),
  "the fields cannot run into each other")

// --------------------------------------------------------------- leaving

// Escape and Back while a send is in flight do nothing: the window closes
// itself when the send lands, and closing it first is how a failed send lost
// the message it failed to send.
assert.strictEqual(draft.closePlan({ sending: true, dirty: true, canDraft: true }), "ignore")
assert.strictEqual(draft.closePlan({ saving: true, dirty: true, canDraft: true }), "wait",
  "a save in flight is waited for, not abandoned")
assert.strictEqual(draft.closePlan({ dirty: false, canDraft: true }), "close")
assert.strictEqual(draft.closePlan({ dirty: true, canDraft: true }), "save")
assert.strictEqual(draft.closePlan({ dirty: true, canDraft: false }), "confirm",
  "a mailbox that cannot keep a draft asks before throwing one away")
assert.strictEqual(draft.closePlan({}), "close")

assert.strictEqual(draft.discardPlan({ sending: true, dirty: true }), "ignore")
assert.strictEqual(draft.discardPlan({ dirty: true }), "confirm")
assert.strictEqual(draft.discardPlan({ saved: true }), "confirm",
  "discarding a saved draft deletes it, so it is asked about too")
assert.strictEqual(draft.discardPlan({ dirty: false, saved: false }), "close")

// --------------------------------------------------------------- building

const fields = {
  from: "me@example.com",
  to: "jane@example.com",
  cc: "bob@example.com",
  subject: "Re: lunch",
  body: "Noon works.\n\n> see you",
  inReplyTo: "<parent@example.com>",
  references: "<root@example.com> <parent@example.com>",
  threadId: "thread-1"
}
const stored = draft.payload(fields, "omail-abc")
assert.strictEqual(stored.token, "omail-abc")
assert.strictEqual(stored.threadId, "thread-1")
const raw = mail.decodeBase64Url(stored.raw)
assert.ok(raw.indexOf("X-Omail-Draft: omail-abc\r\n") === 0, "the token is a header of the message")
assert.ok(raw.indexOf(mail.buildRawMessage(fields)) > 0,
  "a draft is exactly the message Send would build, behind one header")
assert.strictEqual(draft.payload(fields, "").token, "")
assert.ok(mail.decodeBase64Url(draft.payload(fields, "").raw).indexOf("X-Omail-Draft") < 0,
  "no token, no header")
assert.strictEqual(draft.payload(Object.assign({}, fields, { threadId: "" }), "t").threadId, undefined,
  "no thread is no threadId, which Gmail would otherwise try to resolve")
assert.ok(mail.decodeBase64Url(draft.payload(fields, 'a"\r\nBcc: evil@example.com').raw)
  .indexOf("\r\nBcc:") < 0, "a token cannot add a header")

// ----------------------------------------------------------------- reading
//
// A stored draft is read back off the message resource both clients hand
// over — round-tripped through the RFC 822 parser here, which is the IMAP
// path, and so what Gmail would have handed back too.

const message = {
  id: "9:Drafts",
  threadId: "thread-1",
  payload: mail.parseRfc822(raw)
}
const reopened = draft.fieldsFromMessage(message)
assert.strictEqual(reopened.token, "omail-abc", "the token comes back, so the next save finds this copy")
assert.strictEqual(reopened.from, "me@example.com")
assert.strictEqual(reopened.to, "jane@example.com")
assert.strictEqual(reopened.cc, "bob@example.com")
assert.strictEqual(reopened.subject, "Re: lunch")
assert.strictEqual(reopened.body, "Noon works.\n\n> see you")
assert.strictEqual(reopened.inReplyTo, "<parent@example.com>")
assert.strictEqual(reopened.references, "<root@example.com> <parent@example.com>")
assert.strictEqual(reopened.threadId, "thread-1")
assert.strictEqual(draft.isDirty(draft.snapshot(reopened), reopened), false,
  "a draft opened and left alone is not a change")

// Somebody else's client wrote this one: encoded words and no token.
const foreign = {
  id: "draft-msg",
  payload: {
    headers: [
      { name: "From", value: "=?UTF-8?B?Sm9zw6k=?= <jose@example.com>" },
      { name: "To", value: "=?UTF-8?B?Q2Fmw6k=?= <cafe@example.com>" },
      { name: "Subject", value: "=?UTF-8?B?Q2Fmw6kgY3LDqG1l?=" }
    ],
    mimeType: "text/plain",
    body: { data: mail.encodeBase64Url("Bonjour") }
  }
}
const opened = draft.fieldsFromMessage(foreign)
assert.strictEqual(opened.token, "", "no token is a draft the next save starts tracking")
assert.strictEqual(opened.from, "jose@example.com")
assert.strictEqual(opened.to, "Café <cafe@example.com>")
assert.strictEqual(opened.subject, "Café crème")
assert.strictEqual(opened.body, "Bonjour")
assert.strictEqual(opened.inReplyTo, "")

deepEqual(draft.fieldsFromMessage(null).to, "")

console.log("Draft.js ok")
