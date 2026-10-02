.pragma library

.import "Message.js" as Mail

// A draft: what a compose window holds that has not been sent, and the rules
// about when it is kept, when it may be thrown away, and what it is rebuilt
// from when it is opened again.
//
// Sending and drafting build the same message. `Message.buildRawMessage` is the
// one place a message is written, and a draft is that message with one header
// of ours in front of it — so a saved draft cannot come to differ from what
// pressing Send on it would have sent.

// How long typing has to pause before the draft is saved. Long enough that a
// sentence is one save rather than one per word, short enough that a window
// closed by something other than Escape loses a few words at most.
var AUTOSAVE_MS = 3000

// The header that finds a draft's earlier copies on IMAP, where saving stores a
// new copy and the server's name for it is the one thing curl does not hand
// back. Gmail keeps a draft's id across updates and does not need it; it is
// written there too so the two providers store one message.
var HEADER = "X-Omail-Draft"

function text(value) {
  return String(value === undefined || value === null ? "" : value)
}

// Held to an alphabet that cannot end a quoted IMAP string or a header line,
// whatever arrived in a draft somebody else's client wrote.
function token(value) {
  return text(value).trim().replace(/[^A-Za-z0-9._-]/g, "").substring(0, 64)
}

// New for each compose window, and kept for as long as it stays open. Not a
// secret — it only has to be unlikely to collide with another draft in the
// same folder.
//
// Fixed width, because IMAP's HEADER search matches a substring: a token one
// digit shorter than another would find that other draft's copies too, and
// the save would remove them as stale. Two tokens of the same length are only
// ever substrings of each other by being equal.
var TOKEN_STAMP_DIGITS = 9
var TOKEN_NOISE_DIGITS = 7

function fixedBase36(value, digits) {
  var text = Math.abs(Math.floor(Number(value) || 0)).toString(36)
  while (text.length < digits) text = "0" + text
  return text.substring(text.length - digits)
}

function newToken(now, random) {
  var noise = Math.floor((Number(random) || 0) * 0x100000000)
  return "omail-" + fixedBase36(now, TOKEN_STAMP_DIGITS) + "-" + fixedBase36(noise, TOKEN_NOISE_DIGITS)
}

// What the window holds, as one comparable string. Whether a compose is dirty
// is whether this differs from the snapshot taken when it was filled in or
// last saved — not whether it is empty: a reply starts with a quote in it,
// and nobody has written anything yet.
function snapshot(fields) {
  var values = fields || {}
  return JSON.stringify([text(values.from), text(values.to), text(values.cc),
    text(values.subject), text(values.body)])
}

function isDirty(baseline, fields) {
  return snapshot(fields) !== text(baseline)
}

// --------------------------------------------------------------- leaving

// Escape, Back and anything else that leaves a compose without sending it.
//
//   ignore   a send is in flight; the window closes itself when it lands
//   wait     a save is in flight; close once it has landed, saving again
//            first if anything changed meanwhile
//   close    nothing was written, or nothing since the last save
//   save     keep it as a draft, then close
//   confirm  this mailbox cannot keep drafts, so leaving throws the message
//            away — which is asked about, in the window, first
function closePlan(state) {
  var value = state || {}
  if (value.sending === true) return "ignore"
  if (value.saving === true) return "wait"
  if (value.dirty !== true) return "close"
  if (value.canDraft === true) return "save"
  return "confirm"
}

// Discard throws the message away, and a draft on the server with it. Asked
// about whenever there is something to lose: words not yet saved, or a saved
// draft that discarding deletes. A compose nobody typed in just closes.
function discardPlan(state) {
  var value = state || {}
  if (value.sending === true) return "ignore"
  if (value.dirty === true || value.saved === true) return "confirm"
  return "close"
}

// ---------------------------------------------------------------- building

// The message a draft is stored as, in the payload shape both clients take:
// `raw` and `threadId` for Gmail, plus the token the IMAP client searches for.
function payload(fields, draftToken) {
  var values = fields || {}
  var stamp = token(draftToken)
  var raw = (stamp === "" ? "" : HEADER + ": " + stamp + "\r\n") + Mail.buildRawMessage(values)
  var out = { raw: Mail.encodeBase64Url(raw), token: stamp }
  if (values.threadId) out.threadId = text(values.threadId)
  return out
}

// ----------------------------------------------------------------- reading

function headerLine(message, name) {
  return Mail.decodedHeader(message, name).replace(/[\r\n]+/g, " ").trim()
}

// A stored draft, back as the fields a compose window is filled from. Read off
// the message resource both clients hand back, so a Gmail draft and an IMAP
// one open the same way.
//
// The threading headers come back exactly as they were stored, because the
// reply the draft becomes has to thread under the same message it was begun
// as an answer to.
function fieldsFromMessage(message) {
  var resource = message || {}
  var from = Mail.parseAddress(Mail.headerValue(resource, "From"))
  var body = Mail.extractBody(resource.payload)
  return {
    token: token(Mail.headerValue(resource, HEADER)),
    from: from.email,
    to: headerLine(resource, "To"),
    cc: headerLine(resource, "Cc"),
    subject: headerLine(resource, "Subject"),
    body: text(body.text),
    inReplyTo: Mail.referenceValue(Mail.headerValue(resource, "In-Reply-To")),
    references: Mail.headerSafe(Mail.headerValue(resource, "References")).trim(),
    threadId: text(resource.threadId)
  }
}
