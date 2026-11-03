.pragma library

// A local copy of everything the window shows, so switching mailboxes paints
// immediately and the network only ever updates what is already on screen.
//
// One account is one JSON file rewritten atomically, which is the right shape
// for a few hundred kilobytes and the wrong shape for megabytes — hence the
// caps below. Accounts get separate files so switching between them keeps both
// caches, which is the entire reason a cache exists. Everything here is pure:
// CacheStore.qml owns the file.

var VERSION = 1
var MAX_QUERIES = 12
// Bodies are the one thing worth keeping deep: a message body never changes, so
// a hit is always correct and always saves a round trip. They live one file per
// message rather than in this store — measured against a real mailbox a body
// runs 5KB at the median and 35KB at the top, and a thousand of those inside
// the store would mean re-serialising megabytes on the GUI thread every time a
// list changed. As files they cost nothing to keep and nothing to save, and the
// ceiling is a plain file count.
var MAX_BODIES = 1000

function emptyStore() {
  return { version: VERSION, account: "", profile: null, labels: [], queries: {} }
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

// Anything unreadable becomes an empty cache. A cache is a convenience; a
// corrupt one must never stop the app from starting.
function load(text) {
  var raw = parseJson(text, null)
  if (!isObject(raw)) return emptyStore()
  if (Number(raw.version) !== VERSION) return emptyStore()
  var store = emptyStore()
  store.account = String(raw.account || "")
  store.profile = isObject(raw.profile) ? raw.profile : null
  store.labels = Array.isArray(raw.labels) ? raw.labels : []
  store.queries = isObject(raw.queries) ? raw.queries : {}
  return store
}

function serialize(store) {
  return JSON.stringify(store || emptyStore())
}

function queryKey(query, maxResults) {
  return String(query || "").replace(/^\s+|\s+$/g, "")
    + "|" + Math.max(1, Math.floor(Number(maxResults) || 25))
}

// ------------------------------------------------------------- hydration
//
// Dates do not survive JSON, so they cross as epoch milliseconds. Left as
// Date objects they come back as strings and every cached row renders
// "Invalid Date".

function dehydrate(summaries) {
  var list = Array.isArray(summaries) ? summaries : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = {}
    for (var key in list[i]) {
      if (key === "date") continue
      entry[key] = list[i][key]
    }
    var at = list[i].date ? list[i].date.getTime() : NaN
    entry.dateMs = isFinite(at) ? at : null
    out.push(entry)
  }
  return out
}

function hydrate(entries) {
  var list = Array.isArray(entries) ? entries : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var summary = {}
    for (var key in list[i]) {
      if (key === "dateMs") continue
      summary[key] = list[i][key]
    }
    var at = Number(list[i].dateMs)
    summary.date = isFinite(at) && at > 0 ? new Date(at) : null
    out.push(summary)
  }
  return out
}

// ---------------------------------------------------------------- queries

function copyStore(store) {
  var source = store || emptyStore()
  return {
    version: VERSION,
    account: source.account || "",
    profile: source.profile || null,
    labels: source.labels || [],
    queries: source.queries || {}
  }
}

function putQuery(store, key, page, nowMs) {
  var next = copyStore(store)
  var queries = {}
  for (var existing in next.queries) queries[existing] = next.queries[existing]
  queries[String(key)] = {
    summaries: dehydrate(page && page.summaries),
    estimate: Math.max(0, Math.floor(Number(page && page.estimate) || 0)),
    nextPageToken: String(page && page.nextPageToken ? page.nextPageToken : ""),
    at: Number(nowMs) || 0
  }
  next.queries = queries
  return next
}

function getQuery(store, key) {
  var source = store || emptyStore()
  var entry = source.queries ? source.queries[String(key)] : null
  return isObject(entry) ? entry : null
}





function putLabels(store, labels, nowMs) {
  var next = copyStore(store)
  next.labels = Array.isArray(labels) ? labels : []
  return next
}

function putProfile(store, profile, nowMs) {
  var next = copyStore(store)
  next.profile = isObject(profile) ? profile : null
  if (next.profile && next.profile.email) next.account = String(next.profile.email)
  return next
}

// ------------------------------------------------------------ file naming
//
// One file per account, named after the address so a store on disk can be
// matched to its mailbox by eye. The address is lower-cased first: mail
// addresses are compared case-insensitively in practice, and two files for one
// mailbox would silently halve the cache — which also keeps the name unique on
// a case-insensitive filesystem, where the two spellings could not coexist.
//
// Every character outside [a-z0-9.-] becomes "_" plus the lower-case hex of one
// UTF-8 byte. Nothing else can produce a "_", so the encoding is prefix-free
// and reversible, and two different addresses therefore cannot land on one
// name. Reversibility is also what makes the name safe: no "/", NUL, space, or
// newline survives it, so the result is always a single component that stays
// inside the cache directory.

var SAFE_NAME_CHAR = /^[a-z0-9.\-]$/

// A file name has to fit in 255 bytes and an address may be four times its own
// length once escaped.
var MAX_NAME_CHARS = 120

function hexByte(code) {
  var text = code.toString(16)
  return text.length < 2 ? "0" + text : text
}

// encodeURIComponent is the only UTF-8 encoder the QML engine has. It leaves a
// handful of ASCII punctuation alone, which the code-point branch catches, and
// it throws on a surrogate that lost its partner — "_u" cannot begin a byte
// escape, so that fallback stays distinguishable from an encoded byte.
function escapeNameChar(text) {
  var code = text.charCodeAt(0)
  if (code < 128) return "_" + hexByte(code)
  try {
    return encodeURIComponent(text).replace(/%/g, "_").toLowerCase()
  } catch (e) {
    return "_u" + ("000" + code.toString(16)).slice(-4)
  }
}

function encodeAccountId(id) {
  var out = ""
  for (var i = 0; i < id.length; i++) {
    var ch = id.charAt(i)
    if (SAFE_NAME_CHAR.test(ch)) {
      out += ch
      continue
    }
    // A character above the basic plane is two code units, and half a pair is
    // not a character encodeURIComponent will accept.
    var code = ch.charCodeAt(0)
    var next = i + 1 < id.length ? id.charCodeAt(i + 1) : 0
    if (code >= 0xd800 && code <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
      out += escapeNameChar(id.substr(i, 2))
      i++
      continue
    }
    out += escapeNameChar(ch)
  }
  return out
}

// 32-bit FNV-1a. The multiply is written as shifts because a 32-bit product
// through a double loses its low bits, and Math.imul is younger than the
// engine this runs in.
function fnv1a(text) {
  var hash = 0x811c9dc5
  for (var i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash += (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24)
  }
  return (hash >>> 0).toString(16)
}

function fileName(accountId) {
  var encoded = encodeAccountId(String(accountId || "").toLowerCase())
  // A missing address still needs somewhere to put a store. The trailing "_"
  // is what keeps this name out of every real address's reach: the encoder
  // never leaves a "_" without hex behind it.
  if (encoded === "") return "account-none_.json"
  if (encoded.length > MAX_NAME_CHARS) {
    // Past this length the name stops being reversible, so it carries a hash
    // of the whole address to keep two long look-alikes apart. A truncated
    // name is longer than any untruncated one, so the two forms cannot meet.
    encoded = encoded.substr(0, MAX_NAME_CHARS) + "-" + fnv1a(encoded)
  }
  return "account-" + encoded + ".json"
}

// A cache belongs to one mailbox, and showing one account's mail under
// another's name would be the worst bug this file could have. Each account now
// has its own file, so a mismatch here is no longer an account switch — it
// means the wrong file was handed to the wrong mailbox, and the only safe
// answer is to show nothing until the network refills it. The other account's
// file is untouched either way.
//
// An empty address only means the profile has not loaded yet, and a store with
// no address yet was still read from this mailbox's own file, so its rows are
// this mailbox's rows.
function forAccount(store, email) {
  var address = String(email || "")
  if (address === "") return copyStore(store)
  var source = copyStore(store)
  if (source.account === "") {
    source.account = address
    return source
  }
  if (source.account.toLowerCase() === address.toLowerCase()) return source
  var fresh = emptyStore()
  fresh.account = address
  return fresh
}

function isStale(at, nowMs, ttlMs) {
  var stamp = Number(at)
  if (!isFinite(stamp) || stamp <= 0) return true
  var now = Number(nowMs) || 0
  var ttl = Math.max(0, Number(ttlMs) || 0)
  // A clock that went backwards makes `now - stamp` negative, which must read
  // as fresh rather than as immortal or expired.
  return now - stamp > ttl
}

// ---------------------------------------------------------------- pruning

function keepNewest(bucket, limit) {
  var keys = []
  for (var key in bucket) keys.push(key)
  if (keys.length <= limit) return bucket
  keys.sort(function(a, b) {
    return (Number(bucket[b].at) || 0) - (Number(bucket[a].at) || 0)
  })
  var kept = {}
  for (var i = 0; i < limit; i++) kept[keys[i]] = bucket[keys[i]]
  return kept
}


function prune(store) {
  var next = copyStore(store)
  next.queries = keepNewest(next.queries, MAX_QUERIES)
  return next
}

// ------------------------------------------------------------- body files
//
// One file per message, under one directory per account. The name is built with
// the same prefix-free escape the account file uses, so a message id can never
// climb out of the directory it belongs to however strange it is.

// The body cache's names are hashes. They reach body-cache.sh, and from it
// mv, chmod, touch and rm, as arguments — and every local account can read a
// process's arguments in /proc. Named after the message id, a file said which
// folder a message sat in ("17:Clients/Acme"), and the directory said whose
// mailbox it was. A hash says neither, and cannot contain a separator.
function bodyDirName(accountId) {
  var key = String(accountId || "").trim()
  return "account-" + sha256Hex(key).substring(0, 32)
}

function bodyFileName(id) {
  var key = String(id || "").trim()
  if (!key) return ""
  return sha256Hex(key).substring(0, 32) + ".json"
}

// SHA-256, because Qt's own hashing is not reachable from a plain JS library
// and a name that two messages could share would show one the other's body.
// Each file also records its id and a read checks it (`parseBody`), so even a
// collision is a cache miss rather than the wrong message.
var SHA256_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

function utf8Of(text) {
  var bytes = []
  var source = unescape(encodeURIComponent(String(text)))
  for (var i = 0; i < source.length; i++) bytes.push(source.charCodeAt(i))
  return bytes
}

function sha256Hex(text) {
  var bytes = utf8Of(text)
  var bitLength = bytes.length * 8
  bytes.push(0x80)
  while (bytes.length % 64 !== 56) bytes.push(0)
  // The length as a 64-bit big-endian count; nothing here is near 2^32 bits.
  for (var shift = 56; shift >= 0; shift -= 8)
    bytes.push(shift >= 32 ? Math.floor(bitLength / Math.pow(2, shift)) & 0xff : (bitLength >>> shift) & 0xff)

  var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  var w = new Array(64)
  for (var block = 0; block < bytes.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      var at = block + t * 4
      w[t] = ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) | 0
    }
    for (t = 16; t < 64; t++) {
      var x = w[t - 15]
      var y = w[t - 2]
      var s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3)
      var s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7]
    for (t = 0; t < 64; t++) {
      var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))
      var ch = (e & f) ^ (~e & g)
      var temp1 = (k + S1 + ch + SHA256_K[t] + w[t]) | 0
      var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))
      var maj = (a & b) ^ (a & c) ^ (b & c)
      var temp2 = (S0 + maj) | 0
      k = g; g = f; f = e; e = (d + temp1) | 0
      d = c; c = b; b = a; a = (temp1 + temp2) | 0
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0
    h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + k) | 0
  }
  var out = ""
  for (var i = 0; i < 8; i++) out += ("00000000" + (h[i] >>> 0).toString(16)).slice(-8)
  return out
}

// The invitation and the unsubscribe offer are read out of the same fetch as
// the body and are as unchanging as it is, so they are kept beside it: a
// message opened a second time draws its card from the file rather than
// waiting for the network to say the same thing again. Both are plain values —
// no Date in either — which is what lets them go through JSON untouched.
function serializeBody(body, id) {
  var source = isObject(body) ? body : {}
  return JSON.stringify({
    id: String(id || ""),
    text: String(source.text || ""),
    source: String(source.source || ""),
    html: String(source.html || ""),
    attachments: Array.isArray(source.attachments) ? source.attachments : [],
    images: Array.isArray(source.images) ? source.images : [],
    invite: isObject(source.invite) ? source.invite : null,
    unsubscribe: isObject(source.unsubscribe) ? source.unsubscribe : null
  })
}

// `id`, when given, is the message the file was opened for. A file recording a
// different one is a miss: the name is a hash, and a hash is not the id.
function parseBody(text, id) {
  var parsed = parseJson(String(text || "").trim(), null)
  if (!isObject(parsed)) return null
  if (id !== undefined && String(parsed.id || "") !== String(id)) return null
  return {
    text: String(parsed.text || ""),
    source: String(parsed.source || ""),
    html: String(parsed.html || ""),
    attachments: Array.isArray(parsed.attachments) ? parsed.attachments : [],
    images: Array.isArray(parsed.images) ? parsed.images : [],
    // Absent from every file written before these existed, which is a hit with
    // no card rather than a miss: the live fetch fills both in a moment later.
    invite: isObject(parsed.invite) ? parsed.invite : null,
    unsubscribe: isObject(parsed.unsubscribe) ? parsed.unsubscribe : null
  }
}
