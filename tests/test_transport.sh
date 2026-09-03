#!/bin/sh
# What mail-transport.sh would actually hand to curl.
#
# curl is replaced by a stub that prints the config it was given, so these
# assert on the exact bytes that would have reached the server — which is the
# only way to check the escaping of a password without having a server to try
# it against.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/mail-transport.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/omamail-transport-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM HUP

mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
header_file=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--dump-header" ]; then
    header_file=$2
    shift 2
  else
    shift
  fi
done
# The capability probe is the invocation with no --dump-header: the real
# request always has one. It answers with whatever mechanisms the test set,
# so the choice the script makes can be asserted on.
if [ -z "$header_file" ]; then
  cat >/dev/null
  printf '%s' "${CURL_STUB_CAPABILITY:-}"
  exit "${CURL_STUB_PROBE_EXIT:-0}"
fi
if [ -n "${CURL_STUB_HEADER:-}" ] && [ -n "$header_file" ]; then
  printf '%s' "$CURL_STUB_HEADER" > "$header_file"
  cat >/dev/null
  printf '%s' "${CURL_STUB_BODY:-}"
else
  cat
fi
exit "${CURL_STUB_EXIT:-0}"
STUB
chmod +x "$work/bin/curl"

failures=0

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# The script answers with three lines: the exit code, base64 stdout, base64
# stderr. The stub echoes the config, so decoding line 2 is the config.
config_for() {
  printf '%s\n' "$1" \
    | XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" \
    | sed -n '2p' | base64 -d
}

check() {
  description=$1
  haystack=$2
  needle=$3
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s\n' "$description"
    printf '       expected to find: %s\n' "$needle"
    printf '       in:\n%s\n' "$haystack"
    failures=$(( failures + 1 ))
  fi
}

check_absent() {
  description=$1
  haystack=$2
  needle=$3
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  FAIL %s\n' "$description"
    printf '       did not expect: %s\n' "$needle"
    failures=$(( failures + 1 ))
  else
    printf '  ok   %s\n' "$description"
  fi
}

printf 'mail-transport.sh\n'

# ---------------------------------------------------------------- IMAP mode

request="imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane@example.org:hunter2') $(b64 'UID SEARCH UNSEEN')"
config=$(config_for "$request")
check "the URL reaches curl" "$config" 'url = "imaps://imap.example.org:993/INBOX"'
check "the credentials reach curl" "$config" 'user = "jane@example.org:hunter2"'
check "the command reaches curl" "$config" 'request = "UID SEARCH UNSEEN"'
check "mail transport bypasses desktop HTTP/SOCKS proxies" "$config" 'noproxy = "*"'

# libcurl puts a custom multi-UID FETCH in its protocol-header callback rather
# than stdout. The transport returns that channel when present, or the client
# sees a successful request with an empty message list.
header_reply='* 1 FETCH (UID 7 FLAGS ())'
out=$(printf '%s\n' "$request" \
  | CURL_STUB_HEADER="$header_reply" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
decoded=$(printf '%s\n' "$out" | sed -n '2p' | base64 -d)
if [ "$decoded" = "$header_reply" ]; then
  printf '  ok   IMAP protocol headers are returned when curl puts FETCH there\n'
else
  printf '  FAIL IMAP protocol headers did not replace curl stdout\n'
  failures=$(( failures + 1 ))
fi

# A single BODY FETCH is recognised by libcurl: its complete RFC822 resource
# is stdout while the protocol-header callback holds only a partial preamble.
body_reply='* 1 FETCH (UID 7 BODY[] {4}
mail'
out=$(printf '%s\n' "$request" \
  | CURL_STUB_HEADER='partial protocol preamble' CURL_STUB_BODY="$body_reply" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
decoded=$(printf '%s\n' "$out" | sed -n '2p' | base64 -d)
if [ "$decoded" = "$body_reply" ]; then
  printf '  ok   IMAP stdout wins when curl returns a complete BODY FETCH there\n'
else
  printf '  FAIL IMAP stdout did not replace the partial protocol header\n'
  failures=$(( failures + 1 ))
fi

# Several commands share one connection, which is what makes a list load one
# TLS handshake rather than one per message.
multi="imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 'UID SEARCH UNSEEN') $(b64 'UID FETCH 1,2 (FLAGS)')"
config=$(config_for "$multi")
check "a second command is a --next section" "$config" 'next'
check "the second command is there" "$config" 'request = "UID FETCH 1,2 (FLAGS)"'
sections=$(printf '%s' "$config" | grep -c '^url = ' || true)
if [ "$sections" = "2" ]; then
  printf '  ok   each section repeats the URL, because --next resets it\n'
else
  printf '  FAIL expected 2 url lines, found %s\n' "$sections"
  failures=$(( failures + 1 ))
fi

# --------------------------------------------------------------- escaping
#
# The reason the fields cross as base64 and the config is escaped on the way
# out. A password is whatever the user's provider let them choose.

awkward='he said "hi" \ and left'
config=$(config_for "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 "jane:$awkward") $(b64 'NOOP')")
check "a quote in a password is escaped for curl's config parser" "$config" 'he said \"hi\"'
check "a backslash is escaped too" "$config" '\\ and left'
check_absent "the raw unescaped quote does not survive" "$config" 'said "hi" \ and'

# A folder with a space in it is the everyday case — Sent Items, All Mail.
config=$(config_for "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 'UID COPY 4 "Sent Items"')")
check "a quoted folder name survives into the command" "$config" 'UID COPY 4 \"Sent Items\"'

# ------------------------------------------------------------ scheme guard
#
# The second gate. Imap.js validated the host; this is what stops a
# hand-edited accounts.json from aiming an authenticated client somewhere else.

for bad in 'file:///etc/passwd' 'https://evil.example.com/' 'ftp://example.com/'; do
  if printf '%s\n' "imap $(b64 "$bad") $(b64 'jane:pw') $(b64 'NOOP')" \
    | XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" >/dev/null 2>&1; then
    printf '  FAIL %s was accepted\n' "$bad"
    failures=$(( failures + 1 ))
  else
    printf '  ok   %s is refused\n' "$bad"
  fi
done

for good in 'imaps://a.example.org/INBOX' 'imap://127.0.0.1:1143/INBOX' 'smtps://a.example.org'; do
  if printf '%s\n' "imap $(b64 "$good") $(b64 'jane:pw') $(b64 'NOOP')" \
    | XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" >/dev/null 2>&1; then
    printf '  ok   %s is accepted\n' "$good"
  else
    printf '  FAIL %s was refused\n' "$good"
    failures=$(( failures + 1 ))
  fi
done

# ---------------------------------------------------------------- SMTP mode

send="smtp $(b64 'smtps://smtp.example.org:465') $(b64 'jane:pw') $(b64 'jane@example.org') $(b64 'Subject: hi

body') $(b64 'friend@example.com') $(b64 'other@example.com')"
config=$(config_for "$send")
check "the sender is set" "$config" 'mail-from = "jane@example.org"'
check "the first recipient is set" "$config" 'mail-rcpt = "friend@example.com"'
check "every recipient is set" "$config" 'mail-rcpt = "other@example.com"'
check "the body is uploaded from a file, not passed as an argument" "$config" 'upload-file = "'
check_absent "SMTP does not emit --next sections" "$config" 'next'


# -------------------------------------------------- SASL mechanism selection
#
# curl ranks GSSAPI above every other mechanism and does not fall back when
# gss_init_sec_context() fails for want of a ticket — it exits 94 without ever
# sending the password. A server offering GSSAPI but no PLAIN (Axigen does
# exactly this) is therefore unreachable unless a mechanism is named.

axigen_imap='* CAPABILITY IMAP4rev1 IDLE STARTTLS AUTH=CRAM-MD5 AUTH=DIGEST-MD5 AUTH=GSSAPI ACL RIGHTS=texkbn'

# The capability answer is cached per host, so each case gets a cache of its
# own: without this the first probe's mechanisms decide every later assertion.
probe_config_for() {
  rm -rf "$work/cache"
  printf '%s\n' "$1" \
    | CURL_STUB_CAPABILITY="$2" XDG_CACHE_HOME="$work/cache" \
      PATH="$work/bin:$PATH" sh "$script" \
    | sed -n '2p' | base64 -d
}

imap_req="imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 'NOOP')"

config=$(probe_config_for "$imap_req" "$axigen_imap")
check "a shared secret is preferred over GSSAPI" "$config" 'login-options = "AUTH=CRAM-MD5"'
check_absent "GSSAPI is not chosen without a ticket" "$config" 'AUTH=GSSAPI'

# Every section repeats it, because `next` resets the option along with the URL.
count=$(printf '%s' "$config" | grep -c 'login-options' || true)
if [ "$count" = "1" ]; then
  printf '  ok   the mechanism is named once per section\n'
else
  printf '  FAIL expected 1 login-options line, found %s\n' "$count"
  failures=$(( failures + 1 ))
fi

multi_req="imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 'NOOP') $(b64 'NOOP')"
config=$(probe_config_for "$multi_req" "$axigen_imap")
count=$(printf '%s' "$config" | grep -c 'login-options' || true)
if [ "$count" = "2" ]; then
  printf '  ok   a --next section repeats the mechanism\n'
else
  printf '  FAIL expected 2 login-options lines, found %s\n' "$count"
  failures=$(( failures + 1 ))
fi

# A server that offers a password mechanism gets the strongest one, not the
# plain-text one, even though both would work.
config=$(probe_config_for "$imap_req" '* CAPABILITY IMAP4rev1 AUTH=PLAIN AUTH=LOGIN AUTH=CRAM-MD5')
check "CRAM-MD5 outranks PLAIN" "$config" 'login-options = "AUTH=CRAM-MD5"'

config=$(probe_config_for "$imap_req" '* CAPABILITY IMAP4rev1 AUTH=PLAIN')
check "PLAIN is named when it is all there is" "$config" 'login-options = "AUTH=PLAIN"'

# Silence is not a mechanism. A server that advertised nothing we recognise —
# or a probe that failed outright — must leave curl's own choice alone rather
# than force one, so an unfamiliar server behaves as it did before.
config=$(probe_config_for "$imap_req" '* CAPABILITY IMAP4rev1 IDLE UIDPLUS')
check_absent "no mechanism is forced when none is advertised" "$config" 'login-options'

config=$(probe_config_for "$imap_req" '')
check_absent "no mechanism is forced when the probe says nothing" "$config" 'login-options'

# `RIGHTS=texkbn` sits next to the AUTH= words in a real Axigen banner, and a
# looser parser reads its value as a mechanism.
config=$(probe_config_for "$imap_req" "$axigen_imap")
check_absent "a non-AUTH capability value is not read as a mechanism" "$config" 'AUTH=TEXKBN'

# A server offering GSSAPI and nothing else usable, to a machine with no
# ticket, is the case that has no answer — and the script still has to run the
# request. Under `set -e` a bare `have_kerberos_ticket && printf` as the last
# command in `choose_mechanism` makes the function exit 1, which makes the
# `mechanism=$(choose_mechanism)` assignment a failing command and kills the
# whole script before curl is ever reached. The transport then produces no
# output at all, so the caller sees an empty response rather than an error:
# in the panel, a message that opens to a blank reader with nothing logged.
config=$(probe_config_for "$imap_req" '* CAPABILITY IMAP4rev1 AUTH=GSSAPI')
check "a GSSAPI-only server still sends the request" "$config" 'request = "NOOP"'
check_absent "and names no mechanism it cannot complete" "$config" 'login-options'

lines=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY='* CAPABILITY IMAP4rev1 AUTH=GSSAPI' \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" | wc -l | tr -d ' ')
if [ "$lines" = "3" ]; then
  printf '  ok   a GSSAPI-only server still gets a three-line reply\n'
else
  printf '  FAIL expected 3 lines from a GSSAPI-only server, got %s\n' "$lines"
  failures=$(( failures + 1 ))
fi


# The capability answer is cached per host. Several accounts on one server open
# their connections together at startup, and a server that throttles concurrent
# ones answers some with nothing at all — which named no mechanism, put curl
# back on its own ranking and back onto GSSAPI, and produced the exit 94 this
# whole probe exists to prevent. The second connection therefore reads the
# first one's answer instead of asking again.
rm -rf "$work/cache"
printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" >/dev/null
cached=$(find "$work/cache/omamail/capabilities" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$cached" = "1" ]; then
  printf '  ok   a probe answer is cached for the next connection\n'
else
  printf '  FAIL expected 1 cached capability file, found %s\n' "$cached"
  failures=$(( failures + 1 ))
fi

# A throttled probe returns nothing, and caching that would make one bad
# moment permanent for as long as the cache lives.
rm -rf "$work/cache"
printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY='' XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" >/dev/null
empty=$(find "$work/cache/omamail/capabilities" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$empty" = "0" ]; then
  printf '  ok   an empty probe answer is not cached\n'
else
  printf '  FAIL an empty probe answer was cached\n'
  failures=$(( failures + 1 ))
fi

# The cached answer is the one that decides, so a second connection whose own
# probe would fail still names the mechanism the first one found.
config=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" | sed -n '2p' | base64 -d)
config=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY='' XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" | sed -n '2p' | base64 -d)
check "a throttled second connection reuses the cached mechanism" "$config" 'login-options = "AUTH=CRAM-MD5"'

# The bearer-token path names no mechanism: curl selects XOAUTH2 from the
# option carrying the token, and a password mechanism would be wrong.
oauth_req="imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'ya29.token') $(b64 'NOOP')"
config=$(probe_config_for "$oauth_req" '* CAPABILITY IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2')
check_absent "OAuth credentials are left to curl" "$config" 'login-options'

# SMTP advertises its mechanisms on a 250-AUTH line rather than a CAPABILITY
# one, and needs the same protection: the send path hits the same wall.
smtp_req="smtp $(b64 'smtps://smtp.example.org:465') $(b64 'jane:pw') $(b64 'jane@example.org') $(b64 'Subject: hi

body') $(b64 'friend@example.com')"
config=$(probe_config_for "$smtp_req" '250-AUTH PLAIN LOGIN CRAM-MD5 DIGEST-MD5 GSSAPI')
check "SMTP names a mechanism too" "$config" 'login-options = "AUTH=CRAM-MD5"'
check_absent "SMTP does not choose GSSAPI without a ticket" "$config" 'AUTH=GSSAPI'

# ------------------------------------------------------------- the framing

# The exit code is curl's own, so a transport failure is distinguishable from
# a server that answered with NO.
out=$(printf '%s\n' "imap $(b64 'imaps://a.example.org/INBOX') $(b64 'j:p') $(b64 'NOOP')" \
  | CURL_STUB_EXIT=7 XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
first=$(printf '%s' "$out" | sed -n '1p')
if [ "$first" = "7" ]; then
  printf "  ok   curl's exit code is the first line\n"
else
  printf '  FAIL expected exit code 7 on line 1, got "%s"\n' "$first"
  failures=$(( failures + 1 ))
fi

lines=$(printf '%s\n' "imap $(b64 'imaps://a.example.org/INBOX') $(b64 'j:p') $(b64 'NOOP')" \
  | XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" | wc -l | tr -d ' ')
if [ "$lines" = "3" ]; then
  printf '  ok   three lines out: code, stdout, stderr\n'
else
  printf '  FAIL expected 3 lines of output, got %s\n' "$lines"
  failures=$(( failures + 1 ))
fi

# A malformed request must fail rather than run curl with something guessed.
if printf 'not-base64-at-all\n' | XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" >/dev/null 2>&1; then
  printf '  FAIL a malformed request was accepted\n'
  failures=$(( failures + 1 ))
else
  printf '  ok   a malformed request is refused\n'
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'mail-transport.sh ok\n'
