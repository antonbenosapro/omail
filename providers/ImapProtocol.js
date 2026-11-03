.pragma library

// The IMAP protocol, and nothing else. No transport lives here — `ImapClient.qml`
// owns the process that speaks to the server — and no message format lives here
// either: an RFC 822 message is `Message.js`'s subject, and this file hands one
// over as the raw bytes it arrived as.
//
// What this file does own is every string sent to a server and every decision
// about what came back, which is what the node tests can reach without a
// compositor or a mailbox.
//
// ## Why the responses arrive as a byte string
//
// IMAP measures a literal in octets:
//
//     * 1 FETCH (UID 42 BODY[] {2048}
//     <2048 bytes>)
//
// Read as UTF-8 text, 2048 octets of a message with an accent in it is fewer
// than 2048 characters, and the parser walks off the end of the literal into
// the middle of the next response. So the transport base64-encodes the whole
// conversation, and `decodeResponse` turns it back into a string with one
// character per octet. Counting characters is then exactly counting octets,
// binary attachment data survives the pipe, and nothing in the response can
// contain the newline the pipe splits on.

// ------------------------------------------------------------------ servers

var DEFAULT_IMAP_PORT = 993
var DEFAULT_SMTP_PORT = 465
var STARTTLS_SMTP_PORT = 587

// Known services, so the common case is an address and a password rather than
// four hostnames. The key is the mail domain; `presetFor` also matches the
// aliases, which is what makes hotmail.com find the Outlook entry.
//
// TLS on connect (imaps/smtps) wherever a provider offers it: a client that
// negotiates upward can be stripped back down by whatever is between it and the
// server. iCloud and Outlook take mail submission on 587 only, which is
// STARTTLS — and there the transport requires the upgrade (`ssl-reqd`), so a
// stripped session fails instead of sending the password in clear.
var PRESETS = [
  {
    id: "gmail",
    name: "Gmail",
    domains: ["gmail.com", "googlemail.com"],
    imapHost: "imap.gmail.com", imapPort: 993,
    smtpHost: "smtp.gmail.com", smtpPort: 465,
    // Google turned off password sign-in for IMAP. An app password works only
    // with 2-Step Verification on, and that is the sentence users need to see
    // before they go looking for a setting that is not there.
    note: "Needs an app password, which Google only offers with 2-Step Verification on. "
      + "The Gmail provider signs in with Google directly and does not need one."
  },
  {
    id: "icloud",
    name: "iCloud",
    domains: ["icloud.com", "me.com", "mac.com"],
    imapHost: "imap.mail.me.com", imapPort: 993,
    smtpHost: "smtp.mail.me.com", smtpPort: 587,
    note: "Needs an app-specific password from appleid.apple.com."
  },
  {
    id: "fastmail",
    name: "Fastmail",
    domains: ["fastmail.com", "fastmail.fm", "messagingengine.com"],
    imapHost: "imap.fastmail.com", imapPort: 993,
    smtpHost: "smtp.fastmail.com", smtpPort: 465,
    note: "Needs an app password from Settings → Privacy & Security."
  },
  {
    id: "outlook",
    name: "Outlook",
    domains: ["outlook.com", "hotmail.com", "live.com", "msn.com"],
    imapHost: "outlook.office365.com", imapPort: 993,
    smtpHost: "smtp-mail.outlook.com", smtpPort: 587,
    note: "Microsoft has withdrawn password sign-in for personal accounts; "
      + "a work or school account may still allow it."
  },
  {
    id: "yahoo",
    name: "Yahoo",
    domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
    imapHost: "imap.mail.yahoo.com", imapPort: 993,
    smtpHost: "smtp.mail.yahoo.com", smtpPort: 465,
    note: "Needs an app password from Account Security."
  },
  {
    id: "zoho",
    name: "Zoho",
    domains: ["zoho.com", "zohomail.com"],
    imapHost: "imap.zoho.com", imapPort: 993,
    smtpHost: "smtp.zoho.com", smtpPort: 465
  },
  {
    id: "gmx",
    name: "GMX",
    domains: ["gmx.com", "gmx.net", "gmx.de"],
    imapHost: "imap.gmx.com", imapPort: 993,
    smtpHost: "mail.gmx.com", smtpPort: 465
  },
  {
    id: "proton",
    name: "Proton Mail",
    domains: ["proton.me", "protonmail.com", "pm.me"],
    // Proton speaks IMAP only through the Bridge, which listens on loopback
    // in clear text because it is a process on this machine.
    imapHost: "127.0.0.1", imapPort: 1143,
    smtpHost: "127.0.0.1", smtpPort: 1025,
    insecure: true,
    note: "Only reachable through Proton Mail Bridge, which must be running."
  }
]

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function domainOf(address) {
  var at = trimmed(address).lastIndexOf("@")
  return at < 0 ? "" : trimmed(address).substring(at + 1).toLowerCase()
}

function presetFor(address) {
  var domain = domainOf(address)
  if (!domain) return null
  for (var i = 0; i < PRESETS.length; i++) {
    for (var j = 0; j < PRESETS[i].domains.length; j++) {
      if (PRESETS[i].domains[j] === domain) return PRESETS[i]
    }
  }
  return null
}

// What to put in the form before the user types anything. A domain nobody has
// heard of still gets a guess, because `imap.<domain>` is right far more often
// than an empty field is useful — and a wrong guess is visible and editable,
// which a blank one is not.
function suggestedSettings(address) {
  var preset = presetFor(address)
  var domain = domainOf(address)
  if (preset) {
    return {
      imapHost: preset.imapHost,
      imapPort: preset.imapPort,
      smtpHost: preset.smtpHost,
      smtpPort: preset.smtpPort,
      username: trimmed(address),
      insecure: preset.insecure === true,
      preset: preset.id,
      note: String(preset.note || "")
    }
  }
  return {
    imapHost: domain ? "imap." + domain : "",
    imapPort: DEFAULT_IMAP_PORT,
    smtpHost: domain ? "smtp." + domain : "",
    smtpPort: DEFAULT_SMTP_PORT,
    username: trimmed(address),
    insecure: false,
    preset: "",
    note: ""
  }
}

// A hostname, not a URL and not a host:port pair. Everything here ends up in a
// URL handed to the transport, so a value carrying a slash, a space or an "@"
// could point the authenticated client somewhere else entirely.
function isValidHost(value) {
  var host = trimmed(value)
  if (host === "" || host.length > 253) return false
  if (/[\s/\\@:?#"'<>]/.test(host)) return false
  // An IP literal is legitimate — Proton Bridge is one.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return true
  return /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/.test(host)
}

function normalizedPort(value, fallback) {
  var port = Math.floor(Number(value))
  var backup = Math.floor(Number(fallback)) || DEFAULT_IMAP_PORT
  if (!isFinite(port) || port < 1 || port > 65535) return backup
  return port
}

function normalizeSettings(raw) {
  var values = raw || {}
  return {
    imapHost: trimmed(values.imapHost),
    imapPort: normalizedPort(values.imapPort, DEFAULT_IMAP_PORT),
    smtpHost: trimmed(values.smtpHost),
    smtpPort: normalizedPort(values.smtpPort, DEFAULT_SMTP_PORT),
    username: trimmed(values.username),
    // Loopback only. A plaintext session to anywhere else is a password on the
    // wire, and the one legitimate case — a local bridge — never leaves the
    // machine.
    insecure: values.insecure === true && isLoopback(values.imapHost)
  }
}

function isLoopback(host) {
  var name = trimmed(host).toLowerCase()
  return name === "127.0.0.1" || name === "::1" || name === "localhost"
}

// Reported one at a time and in the order the form reads, so the message names
// the first field the user has to go back to rather than all of them at once.
function validateSettings(raw) {
  var settings = normalizeSettings(raw)
  if (settings.username === "") return { ok: false, error: "Add the username for this mailbox" }
  if (settings.imapHost === "") return { ok: false, error: "Add the IMAP server address" }
  if (!isValidHost(settings.imapHost)) return { ok: false, error: "That is not a valid IMAP server address" }
  if (settings.smtpHost !== "" && !isValidHost(settings.smtpHost))
    return { ok: false, error: "That is not a valid SMTP server address" }
  return { ok: true, error: "", settings: settings }
}

// The URL the transport connects with. Built here rather than in the shell
// script so the host has been through `isValidHost` on the way, and so the
// tests can see what a given account would dial.
function imapUrl(settings, folder) {
  var values = normalizeSettings(settings)
  if (!isValidHost(values.imapHost)) return ""
  var scheme = values.insecure ? "imap" : "imaps"
  var url = scheme + "://" + values.imapHost + ":" + values.imapPort
  var box = trimmed(folder)
  // The mailbox is a path segment, so anything that could end the segment or
  // start a query has to be percent-encoded. Gmail's "[Gmail]/All Mail" is the
  // everyday case with characters in it.
  if (box !== "") url += "/" + encodeURIComponent(box)
  return url
}

function smtpUrl(settings) {
  var values = normalizeSettings(settings)
  if (!isValidHost(values.smtpHost)) return ""
  // `insecure` was judged against the IMAP host, and SMTP may be elsewhere: a
  // local IMAP bridge beside a remote SMTP server would otherwise send the
  // password to it in plain text.
  var plain = values.insecure && isLoopback(values.smtpHost)
  // 587 is submission with STARTTLS: smtps:// there expects TLS before the
  // greeting and the server is waiting for EHLO, so every send failed. smtp://
  // is the upgrade, and mail-transport.sh makes it mandatory.
  var scheme = plain || values.smtpPort === STARTTLS_SMTP_PORT ? "smtp" : "smtps"
  return scheme + "://" + values.smtpHost + ":" + values.smtpPort
}

// ------------------------------------------------------------- the query DSL
//
// `Provider.js` hands down strings like "folder:INBOX UNSEEN". They are opaque
// everywhere else — a cache key and nothing more — and this is the only reader.
//
// A folder may contain spaces ("[Gmail]/All Mail", "Sent Items"), so it is
// quoted when it does: folder:"Sent Items" UNSEEN.

function parseQuery(query) {
  var text = trimmed(query)
  var folder = "INBOX"
  var criteria = ""

  var match = text.match(/^folder:(?:"((?:[^"\\]|\\.)*)"|(\S*))\s*([\s\S]*)$/)
  if (match) {
    folder = match[1] !== undefined ? match[1].replace(/\\(.)/g, "$1") : match[2]
    criteria = trimmed(match[3])
  } else if (text !== "") {
    // Not addressed to a folder at all. Treating it as criteria against the
    // inbox is what a bare search term means, and is what the search box
    // produces before `Provider.searchQuery` has shaped it.
    criteria = text
  }

  return { folder: folder === "" ? "INBOX" : folder, criteria: criteria }
}

// A folder name from a query may be a SPECIAL-USE placeholder — "\Sent" rather
// than whatever this server calls its sent mail. `resolveFolder` swaps in the
// real name once a LIST has told us one.
function isSpecialUse(name) {
  return trimmed(name).charAt(0) === "\\"
}

// Falls back to the placeholder's bare word ("\Sent" → "Sent"), which is the
// right guess on a server that answered LIST without any SPECIAL-USE flags at
// all — most of them, still.
function resolveFolder(name, folders) {
  var wanted = trimmed(name)
  if (!isSpecialUse(wanted)) return wanted
  var map = folders || {}
  var attribute = wanted.toLowerCase()
  if (map[attribute]) return map[attribute]
  return wanted.substring(1)
}

// ------------------------------------------------------------- message ids
//
// Gmail's message id is unique across the whole mailbox. An IMAP UID is unique
// only within one folder, and is reissued by a server that has had its
// UIDVALIDITY reset — so "42" on its own names nothing, and two folders each
// holding a message 42 would collide in the body cache and in every list.
//
// The id therefore carries both. The UID is always digits, so splitting on the
// first colon is unambiguous however many colons a folder name contains.

function messageId(uid, folder) {
  var number = Math.floor(Number(uid))
  if (!isFinite(number) || number < 1) return ""
  return String(number) + ":" + trimmed(folder)
}

function parseMessageId(id) {
  var match = String(id === undefined || id === null ? "" : id).match(/^(\d+):([\s\S]*)$/)
  if (!match) return { uid: 0, folder: "" }
  return { uid: Math.floor(Number(match[1])), folder: match[2] }
}

// Grouped by folder, because every command this client sends operates on the
// folder the connection has selected: one round trip per folder rather than
// one per message, and a batch spanning two folders is two conversations.
function groupByFolder(ids) {
  var list = Array.isArray(ids) ? ids : []
  var order = []
  var groups = {}
  for (var i = 0; i < list.length; i++) {
    var parsed = parseMessageId(list[i])
    if (parsed.uid < 1) continue
    if (!groups[parsed.folder]) {
      groups[parsed.folder] = []
      order.push(parsed.folder)
    }
    groups[parsed.folder].push(parsed.uid)
  }
  var out = []
  for (var j = 0; j < order.length; j++) out.push({ folder: order[j], uids: groups[order[j]] })
  return out
}

// ----------------------------------------------------------------- quoting
//
// Every string that reaches a server goes through one of these. An unquoted
// folder name with a space in it is a syntax error; one with a quote in it is
// a way to end the argument early and append a command of somebody's choosing.

function quote(value) {
  return "\"" + String(value === undefined || value === null ? "" : value)
    // A backslash and a double quote are the only two characters IMAP escapes.
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
    // CR and LF end a command. There is no escape for them inside a quoted
    // string — the protocol's answer is a literal — so they are dropped: a
    // folder name or a search term containing one is not a thing worth
    // refusing to search over.
    .replace(/[\r\n]+/g, " ") + "\""
}

// A sequence set: "1,2,3" or "1:10". Built from numbers only, so nothing that
// arrived in a response can extend a command.
function sequenceSet(uids) {
  var list = Array.isArray(uids) ? uids : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var uid = Math.floor(Number(list[i]))
    if (!isFinite(uid) || uid < 1) continue
    out.push(String(uid))
  }
  return out.join(",")
}

// ---------------------------------------------------------------- commands
//
// Each returns the command *without* a tag: the transport is curl, which sends
// one custom command per request and tags it itself.

// What a list row needs, and no more. BODY.PEEK rather than BODY so reading
// the list does not mark everything in it as seen — the single most common way
// a hand-rolled IMAP client ruins a mailbox.
var LIST_HEADERS = "HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REPLY-TO LIST-UNSUBSCRIBE)"

function searchCommand(criteria) {
  var text = trimmed(criteria)
  // ALL rather than an empty criteria list, which is a syntax error.
  return "UID SEARCH " + (text === "" ? "ALL" : text)
}

// Find a message by the identity that survives being moved.
//
// A UID belongs to the folder that issued it, so moving a message to Trash
// gives it a new one — and the server reports that new UID in the tagged
// `OK [COPYUID ...]`, which curl removes before the transport ever sees it
// (see `splitResponse`). After a trash there is therefore no UID naming the
// message, and an undo that reused the old one would select a folder, match
// nothing, and report success having moved nothing.
//
// Message-ID is the one identifier that travels with the message: the sender
// set it, and a move rewrites nothing. `quote` is what keeps a header value
// from ending the argument and appending a command of its own.
function findByMessageIdCommand(messageId) {
  var value = trimmed(messageId)
  if (value === "") return ""
  return "UID SEARCH HEADER MESSAGE-ID " + quote(value)
}

function summaryFetchCommand(uids) {
  var set = sequenceSet(uids)
  if (set === "") return ""
  return "UID FETCH " + set + " (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[" + LIST_HEADERS + "])"
}

// Takes one UID or a list of them, because opening a message and refilling a
// page of bodies from the cache are the same request at different sizes.
//
// A partial fetch, cut one octet past the size cap. The cap is normally
// enforced before this is sent, from the RFC822.SIZE the list fetch reported
// (`refuseOversized`); this is for a message opened before its size was known.
// The server then sends at most the cap and one octet more, which is enough to
// see that the message is over it and never enough to put a 200 MB string on
// the GUI thread.
function fullFetchCommand(uids) {
  var set = sequenceSet(Array.isArray(uids) ? uids : [uids])
  if (set === "") return ""
  return "UID FETCH " + set + " (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[]<0."
    + (MAX_MESSAGE_OCTETS + 1) + ">)"
}

// ---------------------------------------------------------- the size cap
//
// Everything a message becomes on the way to the reader — the base64 response,
// the latin1 string, the MIME parse, the sanitiser — happens on the GUI thread
// of the shell that draws the whole desktop. A message of a few hundred
// megabytes froze it for as long as that took, or ran it out of memory. 25 MB
// is what the large providers accept for a message in the first place, so a
// message over it is one the user's webmail is the right place to open.

var MAX_MESSAGE_OCTETS = 25 * 1024 * 1024
var TOO_LARGE_MESSAGE = "This message is too large to open here (over 25 MB). Open it in your webmail."

function isTooLarge(octets) {
  var size = Number(octets)
  return isFinite(size) && size > MAX_MESSAGE_OCTETS
}

// Splits the ids a full fetch was asked for into those worth fetching and those
// already known to be over the cap. `sizes` maps a message id to the
// RFC822.SIZE an earlier fetch reported; an id it does not know is fetched,
// and `fullFetchCommand`'s partial fetch bounds what that can cost.
function refuseOversized(ids, sizes) {
  var list = Array.isArray(ids) ? ids : []
  var known = sizes || {}
  var out = { fetch: [], refused: [] }
  for (var i = 0; i < list.length; i++) {
    var id = String(list[i])
    if (known.hasOwnProperty(id) && isTooLarge(known[id])) out.refused.push(id)
    else out.fetch.push(id)
  }
  return out
}

// Whether a fetched entry is over the cap — by the size the server declared,
// or by what actually arrived, since the partial fetch stops one octet past
// the cap however large the message claimed to be. Checked before the entry
// is parsed, because the parse is the cost being avoided.
function entryTooLarge(entry) {
  if (!entry) return false
  return isTooLarge(entry.size) || String(entry.raw || "").length > MAX_MESSAGE_OCTETS
}

function storeCommand(uids, addFlags, removeFlags) {
  var set = sequenceSet(uids)
  if (set === "") return ""
  var add = Array.isArray(addFlags) ? addFlags : []
  var remove = Array.isArray(removeFlags) ? removeFlags : []
  // One command each way. IMAP has no "add these and remove those" STORE, and
  // the transport runs them in order on the same connection.
  var commands = []
  if (add.length > 0) commands.push("UID STORE " + set + " +FLAGS.SILENT (" + add.join(" ") + ")")
  if (remove.length > 0) commands.push("UID STORE " + set + " -FLAGS.SILENT (" + remove.join(" ") + ")")
  return commands
}

function copyCommand(uids, folder) {
  var set = sequenceSet(uids)
  if (set === "") return ""
  return "UID COPY " + set + " " + quote(folder)
}

// MOVE (RFC 6851) where the server has it, COPY + \Deleted + EXPUNGE where it
// does not. The caller decides which by asking `hasCapability`.
function moveCommand(uids, folder) {
  var set = sequenceSet(uids)
  if (set === "") return ""
  return "UID MOVE " + set + " " + quote(folder)
}

function expungeCommand(uids) {
  var set = sequenceSet(uids)
  // UID EXPUNGE (RFC 4315) removes only what was named. Plain EXPUNGE removes
  // every \Deleted message in the folder, including ones another client marked
  // — which is somebody else's mail disappearing because this one archived.
  return set === "" ? "" : "UID EXPUNGE " + set
}

function statusCommand(folder) {
  return "STATUS " + quote(folder) + " (MESSAGES UNSEEN)"
}

function listCommand() {
  return "LIST \"\" \"*\""
}

// Asked alongside the folder listing rather than on its own: it costs nothing
// extra on a connection that is already open, and the one answer acted on —
// whether the server has MOVE — decides between one command and three.
function capabilityCommand() {
  return "CAPABILITY"
}

// ------------------------------------------------------- search translation

// The criteria a mailbox query carries are already IMAP's own words (UNSEEN,
// FLAGGED). A typed search arrives as TEXT "..." from `Provider.searchQuery`,
// already JSON-quoted — which is the same escaping IMAP uses for a quoted
// string, with one exception this fixes: JSON escapes a newline as \n, and
// IMAP has no such escape.
function normalizeCriteria(criteria) {
  var text = trimmed(criteria)
  if (text === "") return ""
  return text.replace(/\\n|\\r|\\t/g, " ")
}

// ------------------------------------------------------------- the response
//
// A tokenizer rather than a set of patterns, for the same reason `Html.js` is
// one: where a literal ends is the one thing this cannot be wrong about, and no
// regular expression can count octets.

function decodeResponse(base64Text, base64ToBytes, bytesToLatin1) {
  if (typeof base64ToBytes !== "function" || typeof bytesToLatin1 !== "function") return ""
  return bytesToLatin1(base64ToBytes(String(base64Text || "")))
}

// One IMAP response line, with any literals folded into it. Returns a list of
// lines, each of which is a complete untagged or tagged response — so the
// callers below can look at "* 1 FETCH (...)" as a single string however many
// literals it ran through.
function splitResponse(text) {
  var input = String(text || "")
  var lines = []
  var current = ""
  var index = 0

  while (index < input.length) {
    var newline = input.indexOf("\r\n", index)
    var end = newline < 0 ? input.length : newline
    var line = input.substring(index, end)
    index = newline < 0 ? input.length : newline + 2

    // A line ending in a literal count continues into the next `count` octets,
    // whatever they contain — including CRLFs of their own.
    var literal = line.match(/\{(\d+)\+?\}$/)
    if (literal) {
      var size = Math.floor(Number(literal[1]))
      var payload = input.substr(index, size)
      index += size
      current += line + "\r\n" + payload
      // curl removes the tagged completion and closing syntax around a custom
      // IMAP request. With --next, another untagged FETCH can therefore begin
      // at the exact byte after the literal. The literal size is the boundary;
      // do not fold that next response into this one.
      if (input.substr(index, 2) === "* ") {
        lines.push(current)
        current = ""
      }
      continue
    }

    current += line
    lines.push(current)
    current = ""
  }

  if (current !== "") lines.push(current)
  return lines
}

// `* SEARCH 1 4 9` — and nothing else, because a server may answer with no
// SEARCH line at all when nothing matched.
function parseSearch(text) {
  var lines = splitResponse(text)
  var uids = []
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\*\s+(?:SEARCH|ESEARCH)\b([\s\S]*)$/i)
    if (!match) continue
    var numbers = match[1].match(/\d+/g) || []
    for (var j = 0; j < numbers.length; j++) {
      var uid = Math.floor(Number(numbers[j]))
      if (isFinite(uid) && uid > 0) uids.push(uid)
    }
  }
  return uids
}

// The data items of one FETCH response, read as IMAP lays them out: a
// parenthesised list of name/value pairs at the top level, where a value is an
// atom, a quoted string, a nested list or a literal.
//
// Read by walking the list rather than by searching the line, because the line
// carries the message. `splitResponse` folds every literal into the response
// that announced it, so a header fetch is the sender's text sitting in the
// middle of the server's — and a search for "UID" or "FLAGS (" finds the first
// one, which is whichever came first. A header reading
// `X-Evil: FLAGS (\Seen) UID 999` in a literal ahead of the real items gave the
// row another message's id, marked it read and redated it. A literal is skipped
// here by its octet count, which is the one boundary the sender cannot move.
//
// Returns a map from the upper-cased item name to `{ kind, value }`, where kind
// is "atom", "string", "list" or "literal" and value is the unquoted string,
// the list's inner text, or the literal's octets. The first of a repeated name
// is kept, so nothing later on the line can replace an item already read.
function fetchItems(line) {
  var text = String(line || "")
  var items = {}
  var head = text.match(/^\*[ \t]+\d+[ \t]+FETCH[ \t]+\(/i)
  if (!head) return items
  var index = head[0].length
  var length = text.length

  function isSpace(c) { return c === " " || c === "\t" || c === "\r" || c === "\n" }

  // A literal's announcement `{n}` or `{n+}`, the CRLF that ends its line, and
  // n octets. Returns where the literal starts and ends, or null when `at` is
  // not one.
  function literalAt(at) {
    if (text.charAt(at) !== "{") return null
    // Digits scanned by hand rather than by looking for the "}": a run of "{"
    // with no "}" after it would otherwise search to the end of the line once
    // per brace, and the line can be a whole message.
    var close = at + 1
    while (close < length && text.charAt(close) >= "0" && text.charAt(close) <= "9") close++
    var count = text.substring(at + 1, close)
    if (text.charAt(close) === "+") close++
    if (count === "" || text.charAt(close) !== "}") return null
    var begin = close + 1
    if (text.substr(begin, 2) === "\r\n") begin += 2
    var size = Math.floor(Number(count))
    return { begin: begin, end: Math.min(length, begin + size) }
  }

  // The end of a quoted string that opens at `at`, past its closing quote.
  function quotedEnd(at) {
    var i = at + 1
    while (i < length) {
      var c = text.charAt(i)
      if (c === "\\") { i += 2; continue }
      if (c === "\"") return i + 1
      i++
    }
    return length
  }

  while (index < length) {
    while (index < length && isSpace(text.charAt(index))) index++
    if (index >= length || text.charAt(index) === ")") break

    // The name: an atom, with a section in brackets and a partial origin in
    // angle brackets when it is a body. A section holds spaces and parentheses
    // of its own — BODY[HEADER.FIELDS (FROM TO)] — so it is read to its "]".
    var nameStart = index
    while (index < length) {
      var ch = text.charAt(index)
      if (ch === "[") {
        var bracket = text.indexOf("]", index)
        index = bracket < 0 ? length : bracket + 1
        continue
      }
      if (isSpace(ch) || ch === "(" || ch === ")" || ch === "{" || ch === "\"") break
      index++
    }
    var name = text.substring(nameStart, index).toUpperCase()
    if (name === "") {
      // Something that is not a name where one belongs. Nothing after it can
      // be placed with confidence, so the walk stops with what it has.
      break
    }
    while (index < length && (text.charAt(index) === " " || text.charAt(index) === "\t")) index++

    var item = null
    var c0 = text.charAt(index)
    var literal = literalAt(index)
    if (literal) {
      item = { kind: "literal", value: text.substring(literal.begin, literal.end) }
      index = literal.end
    } else if (c0 === "\"") {
      var stop = quotedEnd(index)
      item = { kind: "string", value: unquoteImap(text.substring(index, stop)) }
      index = stop
    } else if (c0 === "(") {
      // A nested list — FLAGS, or an ENVELOPE or BODYSTRUCTURE nobody asked
      // for — may hold quoted strings and literals of its own, and a ")" inside
      // either of those does not close it.
      var depth = 0
      var open = index
      while (index < length) {
        var cn = text.charAt(index)
        if (cn === "\"") { index = quotedEnd(index); continue }
        var inner = literalAt(index)
        if (inner) { index = inner.end; continue }
        index++
        if (cn === "(") depth++
        else if (cn === ")") {
          depth--
          if (depth === 0) break
        }
      }
      item = { kind: "list", value: text.substring(open + 1, Math.max(open + 1, index - 1)) }
    } else {
      var atomStart = index
      while (index < length && !isSpace(text.charAt(index)) && text.charAt(index) !== ")") index++
      item = { kind: "atom", value: text.substring(atomStart, index) }
    }
    if (!items.hasOwnProperty(name)) items[name] = item
  }
  return items
}

// The value of one top-level FETCH item, or "" when the response has none.
function fetchItem(line, name) {
  var item = fetchItems(line)[String(name || "").toUpperCase()]
  return item ? item.value : ""
}

function unquoteImap(value) {
  var text = String(value || "").trim()
  if (text.length >= 2 && text.charAt(0) === "\"" && text.charAt(text.length - 1) === "\"")
    return text.substring(1, text.length - 1).replace(/\\(.)/g, "$1")
  return text
}

function flagsOf(items) {
  var item = items.FLAGS
  if (!item || item.kind !== "list") return []
  var flags = item.value.split(/\s+/)
  var out = []
  for (var i = 0; i < flags.length; i++) {
    if (trimmed(flags[i]) !== "") out.push(trimmed(flags[i]))
  }
  return out
}

// The flag list of one FETCH response: FLAGS (\Seen \Flagged).
function parseFlags(line) {
  return flagsOf(fetchItems(line))
}

// The body of the BODY[...] item. Everything this client asks for — headers
// and whole messages — comes back as a literal, because servers send anything
// with a CRLF in it that way; a short one may arrive as a quoted string, and
// an absent one as NIL. A literal is cut to its declared size by
// `fetchItems`, which is what keeps the FETCH response's closing ")" out of
// the message — and is why the octet count had to survive the transport.
function bodyOf(items) {
  for (var name in items) {
    if (name.indexOf("BODY[") !== 0) continue
    var item = items[name]
    if (item.kind === "literal" || item.kind === "string") return item.value
    return ""
  }
  return ""
}

function parseLiteralBody(line) {
  return bodyOf(fetchItems(line))
}

var MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
  "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

// `INTERNALDATE " 2-Sep-2026 06:06:28 -0400"` as milliseconds since the epoch.
//
// Computed with Date.UTC rather than handed to `new Date(string)`. No engine
// is obliged to parse "Sep 2, 2026 06:06:28 -0400" and Qt's does not, so the
// value that every message received on a single-digit day carried — RFC 3501
// pads those with a space, which also missed the anchored pattern below —
// arrived in the panel as no date at all. It passed every test outside the
// shell, because Node parses the same string happily. Arithmetic is the only
// form that means the same thing in both.
function parseInternalDate(line) {
  return internalDateOf(fetchItems(line))
}

function internalDateOf(items) {
  var item = items.INTERNALDATE
  var value = item ? trimmed(item.value) : ""
  if (value === "") return 0

  var match = value.match(
    /^(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*([+-])?(\d{2})?(\d{2})?$/)
  if (!match) return 0

  var month = MONTHS.indexOf(match[2].toUpperCase())
  if (month < 0) return 0

  var at = Date.UTC(Number(match[3]), month, Number(match[1]),
    Number(match[4]), Number(match[5]), Number(match[6]))
  if (!isFinite(at)) return 0

  // The zone the server named, subtracted to reach UTC. Absent means UTC,
  // which is what RFC 3501 requires the field to carry anyway.
  if (match[7]) {
    var offset = (Number(match[8] || 0) * 60 + Number(match[9] || 0)) * 60000
    at += match[7] === "-" ? offset : -offset
  }
  return at
}

// One entry per message in a FETCH response, in the order the server sent
// them. The UID is what everything upstream calls an id: a sequence number
// changes when anything ahead of the message is expunged, so a client that
// keyed on one would act on whichever message had slid into that position.
function parseFetch(text) {
  var lines = splitResponse(text)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!/^\*\s+\d+\s+FETCH\s/i.test(line)) continue
    var items = fetchItems(line)
    var uid = items.UID && items.UID.kind === "atom" ? Math.floor(Number(items.UID.value)) : 0
    if (!isFinite(uid) || uid < 1) continue
    var size = items["RFC822.SIZE"] && items["RFC822.SIZE"].kind === "atom"
      ? Math.floor(Number(items["RFC822.SIZE"].value)) : 0
    out.push({
      uid: uid,
      flags: flagsOf(items),
      internalDate: internalDateOf(items),
      size: Math.max(0, size) || 0,
      raw: bodyOf(items)
    })
  }
  return out
}

// `* STATUS "INBOX" (MESSAGES 42 UNSEEN 3)`
function parseStatus(text) {
  var lines = splitResponse(text)
  var result = { messages: 0, unseen: 0 }
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\*\s+STATUS\s+[^(]*\(([^)]*)\)/i)
    if (!match) continue
    var messages = match[1].match(/MESSAGES\s+(\d+)/i)
    var unseen = match[1].match(/UNSEEN\s+(\d+)/i)
    if (messages) result.messages = Math.floor(Number(messages[1])) || 0
    if (unseen) result.unseen = Math.floor(Number(unseen[1])) || 0
  }
  return result
}

// A mailbox name arrives quoted, as an atom, or — when it holds a character the
// server would rather not quote — as a literal, which `splitResponse` has
// already folded into the same string. All three have to end up as the name.
function folderName(value) {
  var text = trimmed(value)
  var literal = text.match(/^\{(\d+)\+?\}\r\n([\s\S]*)$/)
  if (literal) return literal[2].substring(0, Math.floor(Number(literal[1])))
  return unquoteImap(text)
}

// `* LIST (\HasNoChildren \Sent) "/" "Sent Items"`
function parseList(text) {
  var lines = splitResponse(text)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\*\s+(?:LIST|LSUB|XLIST)\s+\(([^)]*)\)\s+(NIL|"(?:[^"\\]|\\.)*"|\S+)\s+([\s\S]*)$/i)
    if (!match) continue
    var flags = []
    var rawFlags = match[1].split(/\s+/)
    for (var j = 0; j < rawFlags.length; j++) {
      if (trimmed(rawFlags[j]) !== "") flags.push(trimmed(rawFlags[j]))
    }
    var name = folderName(match[3])
    if (name === "") continue
    out.push({
      name: name,
      delimiter: match[2] === "NIL" ? "" : unquoteImap(match[2]),
      flags: flags,
      // \Noselect marks a container that holds folders but no mail — Gmail's
      // "[Gmail]" is one, and selecting it is an error.
      selectable: flags.join(" ").toLowerCase().indexOf("\\noselect") < 0
    })
  }
  return out
}

// The SPECIAL-USE attributes this plugin cares about, mapped to the folder the
// server named. A server that advertises none leaves the map empty and
// `resolveFolder` falls back to the plain word.
var SPECIAL_USE = ["\\sent", "\\drafts", "\\trash", "\\junk", "\\archive", "\\all", "\\flagged"]

// Whether a folder is one of the ones the mailbox row already offers. The
// sidebar lists the rest underneath, so getting this wrong either hides every
// folder the user made or shows Sent and Trash twice.
//
// Judged on SPECIAL-USE and the name, never on the structural flags: every
// server sends \HasNoChildren on almost everything, so treating any flag as
// "system" hides the whole folder tree.
function isSpecialFolder(folder, special) {
  var entry = folder || {}
  var name = trimmed(entry.name)
  if (name.toLowerCase() === "inbox") return true

  var flags = Array.isArray(entry.flags) ? entry.flags : []
  for (var i = 0; i < flags.length; i++) {
    if (SPECIAL_USE.indexOf(String(flags[i]).toLowerCase()) >= 0) return true
  }

  // A server with no SPECIAL-USE at all still had its folders matched by name
  // in `specialFolders`, and those are the same ones the mailbox row shows.
  var map = special || {}
  for (var key in map) {
    if (map[key] && map[key].toLowerCase() === name.toLowerCase()) return true
  }
  return false
}

function specialFolders(folders) {
  var list = Array.isArray(folders) ? folders : []
  var map = {}
  for (var i = 0; i < list.length; i++) {
    var flags = list[i].flags || []
    for (var j = 0; j < flags.length; j++) {
      var flag = String(flags[j]).toLowerCase()
      if (SPECIAL_USE.indexOf(flag) < 0) continue
      if (!map[flag]) map[flag] = list[i].name
    }
  }
  // Gmail's IMAP predates SPECIAL-USE on some accounts and answers with
  // "[Gmail]/Sent Mail" and friends under XLIST-style names instead. Matching
  // on the name is a guess, so it only fills gaps the flags left.
  for (var k = 0; k < list.length; k++) {
    var name = String(list[k].name || "")
    var leaf = name.split(/[\/.]/).pop().toLowerCase()
    if (!map["\\sent"] && /^sent( mail| items| messages)?$/.test(leaf)) map["\\sent"] = name
    if (!map["\\trash"] && /^(trash|deleted( items| messages)?)$/.test(leaf)) map["\\trash"] = name
    if (!map["\\drafts"] && /^drafts?$/.test(leaf)) map["\\drafts"] = name
    if (!map["\\junk"] && /^(junk|spam|bulk mail)$/.test(leaf)) map["\\junk"] = name
    if (!map["\\archive"] && /^(archive|all mail)$/.test(leaf)) map["\\archive"] = name
  }
  return map
}

// ------------------------------------------------------------ flags ↔ labels
//
// Everything above `MailAccount` reads a message through `Message.summarize`,
// which asks for Gmail label ids. Rather than teach every view a second
// vocabulary, an IMAP message is given the label ids its flags and its folder
// amount to — so a row, a star and an unread dot work unchanged.

function labelIdsFor(flags, folder, special) {
  var list = Array.isArray(flags) ? flags : []
  var lowered = []
  for (var i = 0; i < list.length; i++) lowered.push(String(list[i]).toLowerCase())

  var ids = []
  // Unread is the *absence* of \Seen, which is the one inversion in the whole
  // mapping and the easiest thing to get backwards.
  if (lowered.indexOf("\\seen") < 0) ids.push("UNREAD")
  if (lowered.indexOf("\\flagged") >= 0) ids.push("STARRED")
  if (lowered.indexOf("\\draft") >= 0) ids.push("DRAFT")
  if (lowered.indexOf("\\deleted") >= 0) ids.push("TRASH")

  var map = special || {}
  var name = trimmed(folder)
  var key = name.toLowerCase()
  if (key === "inbox") ids.push("INBOX")
  if (map["\\sent"] && map["\\sent"].toLowerCase() === key) ids.push("SENT")
  if (map["\\trash"] && map["\\trash"].toLowerCase() === key && ids.indexOf("TRASH") < 0) ids.push("TRASH")
  if (map["\\drafts"] && map["\\drafts"].toLowerCase() === key && ids.indexOf("DRAFT") < 0) ids.push("DRAFT")
  if (map["\\junk"] && map["\\junk"].toLowerCase() === key) ids.push("SPAM")
  return ids
}

// The other direction: what an action asks the server to change. Returns the
// flags to add and remove, plus a folder to move to where the action is a move
// rather than a flag — which is the whole difference between IMAP and Gmail.
function actionPlan(action, special) {
  var map = special || {}
  var verb = String(action || "")

  if (verb === "markRead") return { add: ["\\Seen"], remove: [], move: "" }
  if (verb === "markUnread") return { add: [], remove: ["\\Seen"], move: "" }
  if (verb === "star") return { add: ["\\Flagged"], remove: [], move: "" }
  if (verb === "unstar") return { add: [], remove: ["\\Flagged"], move: "" }
  // Archive is a move on IMAP. Without an archive folder there is nowhere for
  // the message to go, and the caller turns the button off rather than
  // silently deleting it.
  if (verb === "archive") return { add: [], remove: [], move: map["\\archive"] || "" }
  if (verb === "unarchive") return { add: [], remove: [], move: "INBOX" }
  if (verb === "trash") return { add: [], remove: [], move: map["\\trash"] || "" }
  if (verb === "untrash") return { add: [], remove: ["\\Deleted"], move: "INBOX" }
  return null
}

// `MailAccount` does not know which provider it is driving: it asks for a
// label change, in Gmail's vocabulary, because that is the vocabulary every
// view already speaks. This is where that request becomes IMAP.
//
// Two of the mappings are not flags at all. Gmail archives by removing the
// INBOX label — one message, many labels — while IMAP has one folder per
// message, so the same request is a move.
function flagPlanForLabels(addLabelIds, removeLabelIds, special) {
  var added = Array.isArray(addLabelIds) ? addLabelIds : []
  var removed = Array.isArray(removeLabelIds) ? removeLabelIds : []
  var map = special || {}
  var plan = { add: [], remove: [], move: "" }

  function has(list, id) {
    for (var i = 0; i < list.length; i++) {
      if (String(list[i]).toUpperCase() === id) return true
    }
    return false
  }

  // The inversion again: Gmail's UNREAD is a label you add, IMAP's \Seen is a
  // flag you remove. Getting this backwards marks read what the user just
  // marked unread.
  if (has(added, "UNREAD")) plan.remove.push("\\Seen")
  if (has(removed, "UNREAD")) plan.add.push("\\Seen")
  if (has(added, "STARRED")) plan.add.push("\\Flagged")
  if (has(removed, "STARRED")) plan.remove.push("\\Flagged")

  if (has(removed, "INBOX")) plan.move = map["\\archive"] || ""
  if (has(added, "INBOX")) plan.move = "INBOX"
  if (has(added, "TRASH")) plan.move = map["\\trash"] || ""
  if (has(added, "SPAM")) plan.move = map["\\junk"] || ""
  return plan
}

// -------------------------------------------------------------- the errors
//
// A server's own text is written for whoever reads its logs. These are the
// four sentences a user can act on.

function responseError(status, detail, fallback) {
  var text = trimmed(detail)
  var code = Math.floor(Number(status)) || 0

  // curl's own exit codes, which is what a transport failure arrives as.
  if (code === 6) return "Could not find that mail server. Check the server address"
  if (code === 7) return "Could not reach the mail server. Check the address, the port, and the network"
  if (code === 28) return "The mail server did not answer in time"
  if (code === 35) return "A secure connection to the mail server could not be established"
  if (code === 60 || code === 51)
    return "The mail server's security certificate could not be verified"
  // 63 is curl's "maximum file size exceeded", and mail-transport.sh answers
  // with it too when a response is larger than the panel will take.
  if (code === 63) return TOO_LARGE_MESSAGE
  if (code === 67 || /AUTHENTICATIONFAILED|invalid credentials|login failed/i.test(text))
    return "The server rejected that username or password"
  if (/\[ALERT\]/i.test(text)) {
    var alert = text.replace(/^[\s\S]*\[ALERT\]\s*/i, "").split(/[\r\n]/)[0]
    if (alert) return alert
  }
  if (/\[TRYCREATE\]/i.test(text)) return "That folder does not exist on the server"
  if (/\[OVERQUOTA\]/i.test(text)) return "The mailbox is over its storage quota"
  if (/\[INUSE\]/i.test(text)) return "The mailbox is busy. Try again shortly"
  if (/NONEXISTENT|Unknown Mailbox|Mailbox doesn't exist/i.test(text))
    return "That folder is no longer on the server"
  if (text !== "") return redact(text)
  return fallback || "The mail server could not complete this request"
}

// ----------------------------------------------------------- the envelope
//
// SMTP takes the sender and each recipient as a command argument of its own —
// `RCPT TO:<address>` — and curl writes the value between the brackets as it
// was given. So an address carrying a ">" ends the argument early and whatever
// follows is a parameter: `a@b.com> NOTIFY=NEVER`. One carrying a CR or an LF
// is a second command. The addresses are read off the message's own headers,
// and a reply copies those from mail a stranger wrote, where an encoded word
// can decode to anything at all.
//
// So every envelope address must be one plain address and nothing else, and a
// message with any that is not is refused whole. Dropping the bad one and
// sending to the rest would deliver a message to fewer people than its To line
// says, which nobody would find out about until somebody asked.

// The same shape `Calendar.js` accepts for an organiser: a local part, an "@",
// and a domain with a dot in it, none of them holding anything SMTP or an
// address list would read as syntax. The length is checked first, which is the
// SMTP limit for a path and also what keeps the pattern's backtracking over a
// domain of dots from costing anything.
var SINGLE_ADDRESS = /^[^\s@,;<>"]+@[^\s@,;<>"]+\.[^\s@,;<>"]+$/
var MAX_ADDRESS_LENGTH = 254

function isEnvelopeAddress(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text === "" || text.length > MAX_ADDRESS_LENGTH) return false
  // Control characters are not whitespace to `\s`, and NUL ends a C string
  // inside curl.
  if (/[\x00-\x1f\x7f]/.test(text)) return false
  return SINGLE_ADDRESS.test(text)
}

// The sender is the username the account signs in with, which a server may
// accept without an "@" in it. So it is held to what the command needs — no
// whitespace, no brackets, no separators, no control characters — rather than
// to the shape of an address.
function isEnvelopeSender(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text === "" || text.length > MAX_ADDRESS_LENGTH) return false
  return !/[\s<>,;"\x00-\x1f\x7f]/.test(text)
}

// What the user sees about an address that was refused. It is the address
// they or a sender typed, so it is shown — it is the thing to correct — but
// with its control characters gone and its length bounded, because it is
// about to be a label.
function shownAddress(value) {
  var text = String(value === undefined || value === null ? "" : value)
    .replace(/[\x00-\x1f\x7f]+/g, " ").trim()
  return text.length > 80 ? text.substring(0, 80) + "…" : text
}

// The envelope for a message, or the reason there is none. `recipients` is the
// list of addresses read off To, Cc and Bcc.
function envelopeFor(sender, recipients) {
  var list = Array.isArray(recipients) ? recipients : []
  if (!isEnvelopeSender(sender))
    return { ok: false, error: "This mailbox's username cannot be used as a sender address, so nothing was sent", from: "", recipients: [] }
  var out = []
  for (var i = 0; i < list.length; i++) {
    var address = String(list[i] === undefined || list[i] === null ? "" : list[i])
    if (!isEnvelopeAddress(address)) {
      return {
        ok: false,
        error: "Nothing was sent: \u201c" + shownAddress(address) + "\u201d is not a single plain email address",
        from: "",
        recipients: []
      }
    }
    if (out.indexOf(address) < 0) out.push(address)
  }
  if (out.length === 0) return { ok: false, error: "Add a recipient first", from: "", recipients: [] }
  return { ok: true, error: "", from: String(sender), recipients: out }
}

// A password can end up in a curl error line, in a server's echo of a failed
// LOGIN, or in a URL. Nothing that could carry one reaches a label without
// passing through here — the same gate `OAuth.redact` is for Google.
function redact(text) {
  return String(text === undefined || text === null ? "" : text)
    // "LOGIN user pass" and "AUTHENTICATE PLAIN <base64>", whichever the
    // server chose to quote back.
    .replace(/\b(LOGIN)\s+\S+\s+\S+/gi, "$1 [redacted]")
    .replace(/\b(AUTHENTICATE)\s+\w+\s+\S+/gi, "$1 [redacted]")
    // A password inside a URL's userinfo, which is how curl prints one. The
    // whole userinfo goes, colon or not: matching "user:pass" as two runs
    // either side of a colon let the engine try every colon in a long run of
    // them as the split, and a server line of 60,000 colons held the shell's
    // GUI thread for over a second. One run up to the "@" is linear, and a
    // username on its own is not worth that.
    .replace(/(imaps?|smtps?):\/\/[^\s\/@]*@/gi, "$1://[redacted]@")
    .replace(/(password|pass|pwd)\s*[=:]\s*\S+/gi, "$1=[redacted]")
}

// Whether the tagged completion said OK. curl hides the tag from us for a
// custom request, so this reads what it does surface.
//
// The tag is matched as a tag rather than as "any non-space run", because a
// FETCH carries the whole message and the message has its own lines. `\S+`
// matched a header — "X-Postal-Spam: no" is a non-space run, whitespace, and
// the word "no" — so a message whose spam filter had cleared it was read as a
// server refusal, and the reader stayed empty with the header quoted at the
// user as the reason. RFC 3501 says a tag is alphanumerics and a few symbols,
// and in particular contains no colon, which is what every header line has.
//
// `NO`/`BAD` are also matched case-sensitively: the protocol writes them in
// capitals, and the header that started this says "no" in lower case.
//
// And it is matched only where a response begins. A FETCH carries the message
// as a literal, and a line inside it is the sender's: "A1 NO [ALERT] <img ...>"
// in a body was read as the server refusing, and its text went to the account's
// error line as the server's own words. `splitResponse` folds every literal
// into the response that announced it, by its octet count, so the start of each
// line it returns is the server speaking and never the message.
var TAGGED_FAILURE = /^[A-Za-z0-9][A-Za-z0-9.\-_]*[ \t]+(?:NO|BAD)[ \t]/

function taggedFailureLine(text) {
  var lines = splitResponse(text)
  for (var i = 0; i < lines.length; i++) {
    if (TAGGED_FAILURE.test(lines[i])) return lines[i]
  }
  return ""
}

function isFailure(text) {
  return taggedFailureLine(text) !== ""
}

function failureDetail(text) {
  var match = taggedFailureLine(text)
    .match(/^[A-Za-z0-9][A-Za-z0-9.\-_]*[ \t]+(?:NO|BAD)[ \t]+([^\r\n]*)/)
  return match ? trimmed(match[1]) : ""
}

// ------------------------------------------------------------- capabilities

// `* CAPABILITY IMAP4rev1 MOVE UIDPLUS ...`, which decides whether an archive
// is one round trip or three.
function parseCapabilities(text) {
  // Bounded to the line. `[\s\S]*` with the multiline flag is greedy across
  // newlines, which swallowed the tagged completion that follows and reported
  // "A1" and "OK" as capabilities.
  var match = String(text || "").match(/^\*\s+CAPABILITY\s+([^\r\n]*)/im)
  if (!match) return []
  var words = match[1].split(/\s+/)
  var out = []
  for (var i = 0; i < words.length; i++) {
    var word = trimmed(words[i]).toUpperCase()
    if (word !== "") out.push(word)
  }
  return out
}

function hasCapability(capabilities, name) {
  var list = Array.isArray(capabilities) ? capabilities : []
  return list.indexOf(String(name || "").toUpperCase()) >= 0
}
