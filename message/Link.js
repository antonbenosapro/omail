.pragma library
.import "Html.js" as Html

// What clicking a link in a message does.
//
// A link is two things a sender wrote independently: the words on the page and
// the address behind them. Nothing makes them agree, and the gap between them
// is the whole of phishing — "paypal.com" in the text, somewhere else in the
// href. The reader therefore shows the real host while the pointer is over a
// link, and a click opens it at once only when there is nothing to doubt:
//
//   open     an http(s) address on the public internet whose text names no
//            other host, or a mailto: with its attachment requests removed
//   confirm  an address that is not on the public internet, one that hides its
//            host behind a user name, or one whose text names a different
//            host. The full target is shown and the reader decides.
//   refuse   anything else. The sanitiser already drops every other scheme, so
//            this is the second lock on the same door, not the first.
//
// Host classification is Html.js's, the same rule the image policy uses, so a
// link and an image cannot disagree about what "this machine's network" means.

// What the status line may carry for one link. Long enough for any real host.
var MAX_HINT_CHARS = 120
// How much of an anchor's text is read for a host. A sender can make one
// enormous; the host it names is at the start of any honest one.
var MAX_TEXT_CHARS = 2000
// How many anchors pointing at the same address are read.
var MAX_ANCHORS = 50

function schemeOf(url) {
  var match = String(url || "").match(/^([a-z][a-z0-9+.-]*):/i)
  return match ? match[1].toLowerCase() : ""
}

// The authority of an http(s) URL as written, userinfo and port included, or
// "" when there is none.
function authorityOf(url) {
  var text = String(url || "").replace(/^https?:/i, "")
  if (text.indexOf("//") !== 0) return ""
  var authority = text.substring(2)
  var end = authority.search(/[\/?#\\]/)
  return end >= 0 ? authority.substring(0, end) : authority
}

// The host a browser will connect to. Read off the authority as a browser
// bounds it — a backslash ends it as a "/" does — and then by Html.hostOf, so
// "https://evil.net\@paypal.com/" is evil.net here as it is in the browser,
// not paypal.com as a reading that stopped only at "/" would have it.
function linkHost(url) {
  return Html.hostOf("//" + authorityOf(url))
}

function safeDecode(text) {
  try {
    return decodeURIComponent(String(text))
  } catch (e) {
    return null
  }
}

// A mailto: link may ask the mail client to attach a file — `attach=` and
// `attachment=` are honoured by several — and the file it names is on this
// machine. Every query part whose key decodes to one of them goes, and so does
// one whose key does not decode at all, since what it would have meant cannot
// be checked.
function withoutAttachments(url) {
  var text = String(url || "")
  var query = text.indexOf("?")
  if (query < 0) return text
  var parts = text.substring(query + 1).split("&")
  var kept = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    var decoded = safeDecode(parts[i].split("=")[0])
    if (decoded === null) continue
    // A ";" is a separator to some clients, so a key hidden after one counts.
    if (/(^|;)\s*attach(ment)?\s*$/i.test(decoded)) continue
    if (/(^|;)\s*attach(ment)?\s*=/i.test(safeDecode(parts[i]) || "attach=")) continue
    kept.push(parts[i])
  }
  return text.substring(0, query) + (kept.length > 0 ? "?" + kept.join("&") : "")
}

function mailtoAddress(url) {
  var text = String(url || "").replace(/^mailto:/i, "")
  var query = text.indexOf("?")
  if (query >= 0) text = text.substring(0, query)
  var decoded = safeDecode(text)
  return decoded === null ? text : decoded
}

function clip(text, limit) {
  var value = String(text)
  return value.length > limit ? value.substring(0, limit - 1) + "…" : value
}

// The line the status bar shows while the pointer is over a link: where it
// really goes, which is the host and not the words. Empty for what a click
// would refuse, and for the reader's own image markers.
function hint(href) {
  var url = Html.normalizedUrl(href)
  var scheme = schemeOf(url)
  if (scheme === "http" || scheme === "https") {
    var host = linkHost(url)
    return host === "" ? "" : clip("Opens " + host, MAX_HINT_CHARS)
  }
  if (scheme === "mailto") {
    var address = mailtoAddress(url).replace(/[\u0000-\u001f\u007f]/g, "")
    return address === "" ? "" : clip("Emails " + address, MAX_HINT_CHARS)
  }
  return ""
}

function comparableHost(host) {
  return String(host || "").toLowerCase().replace(/\.$/, "").replace(/^www\./, "")
}

// Whether text naming `shown` is honest about a link to `actual`. The same
// host, or one inside the other: "example.com" over a link to
// mail.example.com says where it goes. "example.com.evil.net" over a link to
// evil.net does too, if unhelpfully — the host named is evil.net's.
function sameSite(shown, actual) {
  var a = comparableHost(shown)
  var b = comparableHost(actual)
  if (a === "" || b === "") return true
  if (a === b) return true
  return endsWith(b, "." + a) || endsWith(a, "." + b)
}

function endsWith(text, suffix) {
  return text.length >= suffix.length
    && text.substring(text.length - suffix.length) === suffix
}

var URL_IN_TEXT = /\bhttps?:\/\/[^\s<>"']+/gi
var WWW_IN_TEXT = /(^|[^a-z0-9.-])(www\.[^\s<>"']+)/gi
var BARE_HOST = /^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(:\d+)?([\/?#][^\s]*)?$/i

// The hosts a link's visible text names. A scheme or a leading www. names one
// wherever it appears; a bare "example.com" counts only when it is the whole
// of the text, because prose is full of things with a dot in them.
function textHosts(text) {
  var value = String(text || "").substring(0, MAX_TEXT_CHARS)
  var hosts = []
  var match
  URL_IN_TEXT.lastIndex = 0
  while ((match = URL_IN_TEXT.exec(value)) !== null) addHost(hosts, Html.hostOf(match[0]))
  WWW_IN_TEXT.lastIndex = 0
  while ((match = WWW_IN_TEXT.exec(value)) !== null) addHost(hosts, Html.hostOf("//" + match[2]))
  var whole = value.replace(/^\s+/, "").replace(/[\s.,;:!?)\]]+$/, "")
  if (hosts.length === 0 && BARE_HOST.test(whole)) addHost(hosts, Html.hostOf("//" + whole))
  return hosts
}

function addHost(hosts, host) {
  var name = String(host || "").replace(/[.,;:!?)\]]+$/, "")
  if (name !== "" && hosts.indexOf(name) < 0) hosts.push(name)
}

function textOf(node, out) {
  var stack = [node]
  while (stack.length > 0 && out.length < MAX_TEXT_CHARS) {
    var current = stack.pop()
    if (current.type === "text") {
      out.push(current.raw ? current.text : Html.decodeReferences(current.text))
      continue
    }
    var children = current.children || []
    for (var i = children.length - 1; i >= 0; i--) stack.push(children[i])
  }
  return out
}

// The visible text of every anchor in a document that points at `href`. Read
// when a link is clicked rather than when the message opens, so a message
// nobody clicks in costs nothing: the TextEdit hands back the address of the
// link, never its words. `document` is the parsed tree when the reader has it,
// or the HTML it drew.
function anchorTexts(document, href) {
  if (!document) return []
  var root = typeof document === "string" ? Html.parse(document) : document
  var wanted = Html.normalizedUrl(href)
  var texts = []
  var stack = [root]
  while (stack.length > 0 && texts.length < MAX_ANCHORS) {
    var node = stack.pop()
    if (node.type === "text") continue
    if (node.type === "element" && node.name === "a"
      && Html.normalizedUrl(Html.attributeValue(node, "href")) === wanted) {
      var text = textOf(node, []).join("").replace(/\s+/g, " ")
      texts.push(text.replace(/^ | $/g, "").substring(0, MAX_TEXT_CHARS))
      continue
    }
    var children = node.children || []
    for (var i = children.length - 1; i >= 0; i--) stack.push(children[i])
  }
  return texts
}

// What a click on `href` does, given the visible text of the anchors that
// point at it (empty when the text is not known).
function decide(href, texts) {
  var url = Html.normalizedUrl(href)
  var scheme = schemeOf(url)

  if (scheme === "mailto") return { action: "open", url: withoutAttachments(url), reason: "" }
  if (scheme !== "http" && scheme !== "https") return { action: "refuse", url: url, reason: "" }

  if (authorityOf(url) === "") return { action: "refuse", url: url, reason: "" }
  var host = linkHost(url)
  if (host === "") return { action: "refuse", url: url, reason: "" }

  // A name in another script is real and common, and it is also how a
  // look-alike of a familiar one is spelt — "pаypal.com" with a Cyrillic "а".
  // Nothing here can tell those apart, so it says which it is rather than
  // calling it private, which it is not. The same name written as punycode
  // ("xn--") is the same question.
  if (/[^\x00-\x7f]/.test(host) || /(^|\.)xn--/.test(host)) {
    return {
      action: "confirm", url: url,
      reason: "This link goes to " + host + ", which uses letters that can imitate another address"
    }
  }
  if (!Html.isPublicHost(host)) {
    return {
      action: "confirm", url: url,
      reason: "This link goes to " + host + ", which is not on the public internet"
    }
  }
  // "https://paypal.com@evil.net/" reads as PayPal and is a request to
  // evil.net. No ordinary link carries a user name.
  if (authorityOf(url).indexOf("@") >= 0) {
    return {
      action: "confirm", url: url,
      reason: "This link hides its destination, " + host + ", behind a user name"
    }
  }
  var list = texts || []
  for (var i = 0; i < list.length; i++) {
    var shown = textHosts(list[i])
    for (var j = 0; j < shown.length; j++) {
      if (!sameSite(shown[j], host)) {
        return {
          action: "confirm", url: url,
          reason: "The link says " + shown[j] + ", but it goes to " + host
        }
      }
    }
  }
  return { action: "open", url: url, reason: "" }
}
