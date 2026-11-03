const assert = require("assert")
const { load, deepEqual } = require("./load")

const link = load("message/Link.js")

function action(href, texts) { return link.decide(href, texts).action }

// ------------------------------------------------------------- open at once

assert.strictEqual(action("https://example.com/a?b=c"), "open")
assert.strictEqual(action("http://news.example.org/"), "open")
assert.strictEqual(action("https://example.com/", ["Read the full story"]), "open",
  "words that name no host say nothing about where a link goes")
assert.strictEqual(action("https://example.com/", ["example.com"]), "open")
assert.strictEqual(action("https://mail.example.com/x", ["www.example.com"]), "open",
  "a subdomain of the host the text names is that host's")
assert.strictEqual(action("https://example.com/x", ["https://www.example.com/x"]), "open")
assert.strictEqual(action("https://example.com/", ["Unsubscribe from example.com"]), "open",
  "a bare name in prose is not read as a claim")
assert.strictEqual(link.decide("  https://example.com/a\n ").url, "https://example.com/a",
  "the URL opened is the one that was checked")

// ------------------------------------------------------------ confirm first

const local = link.decide("http://127.0.0.1:8080/admin")
assert.strictEqual(local.action, "confirm")
assert.strictEqual(local.url, "http://127.0.0.1:8080/admin")
assert.ok(local.reason.indexOf("127.0.0.1") >= 0)
for (const href of [
  "http://localhost/", "http://192.168.1.1/", "http://10.0.0.5/x", "http://169.254.169.254/latest",
  "http://printer/", "http://nas.local/", "http://[::1]/", "http://0x7f000001/", "http://2130706433/",
  "https://pаypal.com/", "https://%65vil.example/"
]) assert.strictEqual(action(href), "confirm", href)

const phish = link.decide("https://evil.example/login", ["paypal.com"])
assert.strictEqual(phish.action, "confirm")
assert.strictEqual(phish.reason, "The link says paypal.com, but it goes to evil.example")
assert.strictEqual(action("https://evil.example/", ["Sign in at https://www.paypal.com/signin"]), "confirm")
assert.strictEqual(action("https://evil.example/", ["Visit www.paypal.com today"]), "confirm")
assert.strictEqual(action("https://paypal.com.evil.example/", ["paypal.com"]), "confirm",
  "a host that merely starts with the one named is not that host")
assert.strictEqual(action("https://evil.example/", ["Read more", "paypal.com"]), "confirm",
  "any anchor on the same address that names another host is enough")

assert.strictEqual(action("https://paypal.com@evil.example/"), "confirm", "a user name hides the host")
assert.ok(link.decide("https://paypal.com@evil.example/").reason.indexOf("evil.example") >= 0)

// A backslash ends the authority to a browser. Read the other way, this is a
// link to paypal.com; the browser takes it to 127.0.0.1.
const backslash = link.decide("https://127.0.0.1\\@paypal.com/")
assert.strictEqual(backslash.action, "confirm")
assert.ok(backslash.reason.indexOf("127.0.0.1") >= 0)
assert.strictEqual(link.hint("https://127.0.0.1\\@paypal.com/"), "Opens 127.0.0.1")

// ------------------------------------------------------------------ refuse

for (const href of ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "omarchy-image:1",
  "", "https:evil.example", "//evil.example/"])
  assert.strictEqual(action(href), "refuse", href)

// ------------------------------------------------------------------ mailto

assert.strictEqual(link.decide("mailto:a@example.com?subject=Hi&attach=/etc/passwd&body=x").url,
  "mailto:a@example.com?subject=Hi&body=x")
assert.strictEqual(link.decide("mailto:a@example.com?attachment=~/.ssh/id_rsa").url, "mailto:a@example.com")
assert.strictEqual(link.decide("mailto:a@example.com?ATTACH=%2Fetc%2Fpasswd").url, "mailto:a@example.com")
assert.strictEqual(link.decide("mailto:a@example.com?%61ttach=/etc/passwd").url, "mailto:a@example.com",
  "a key is compared decoded")
assert.strictEqual(link.decide("mailto:a@example.com?subject=x;attach=/etc/passwd").url, "mailto:a@example.com",
  "nor can one hide behind a semicolon")
assert.strictEqual(link.decide("mailto:a@example.com?%E0=1&subject=ok").url, "mailto:a@example.com?subject=ok",
  "a key that does not decode cannot be checked, so it goes")
assert.strictEqual(link.decide("mailto:a@example.com").url, "mailto:a@example.com")
assert.strictEqual(action("mailto:a@example.com?attach=x"), "open")

// -------------------------------------------------------------------- hint

assert.strictEqual(link.hint("https://Example.COM:8443/a"), "Opens example.com")
assert.strictEqual(link.hint("https://paypal.com@evil.example/"), "Opens evil.example")
assert.strictEqual(link.hint("mailto:jane%40example.com?subject=x"), "Emails jane@example.com")
assert.strictEqual(link.hint("javascript:alert(1)"), "")
assert.strictEqual(link.hint("omarchy-image:3"), "")
assert.ok(link.hint("https://" + "a".repeat(300) + ".com/").length <= link.MAX_HINT_CHARS)

// ------------------------------------------------------------ anchor texts

const html = '<p><a href="https://evil.example/?a=1&amp;b=2">pay<b>pal</b>.com</a> and '
  + '<a href="https://other.example/">other</a> and <a href="https://evil.example/?a=1&amp;b=2">'
  + 'Read &amp; more</a></p>'
deepEqual(link.anchorTexts(html, "https://evil.example/?a=1&b=2"), ["paypal.com", "Read & more"],
  "the href Qt reports is decoded, as the comparison is")
deepEqual(link.anchorTexts(html, "https://nowhere.example/"), [])
deepEqual(link.anchorTexts("", "https://x.example/"), [])
deepEqual(link.anchorTexts(null, "https://x.example/"), [])

// The reader may hand over the parsed tree instead of the string.
const Html = load("message/Html.js")
const tree = Html.parse(html)
deepEqual(link.anchorTexts(tree, "https://other.example/"), ["other"])
assert.strictEqual(action("https://evil.example/?a=1&b=2", link.anchorTexts(tree, "https://evil.example/?a=1&b=2")),
  "confirm")

// As deep as the parse goes, the walk follows without recursion.
const deep = "<div>".repeat(120) + '<a href="https://x.example/">x.example</a>' + "</div>".repeat(120)
deepEqual(link.anchorTexts(deep, "https://x.example/"), ["x.example"])

// An international name is asked about as one, never called private.
{
  const verdict = link.decide("https://b\u00fccher.de/", [])
  assert.strictEqual(verdict.action, "confirm")
  assert.ok(/imitate/.test(verdict.reason) && !/public internet/.test(verdict.reason), verdict.reason)
  assert.strictEqual(link.decide("https://xn--bcher-kva.de/", []).action, "confirm")
  assert.strictEqual(link.decide("https://example.com/", []).action, "open")
}

console.log("test_link.js ok")
