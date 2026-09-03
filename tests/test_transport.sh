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
[ -z "${CURL_STUB_ARGV:-}" ] || printf '%s\n' "$@" > "$CURL_STUB_ARGV"
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
# Fails the first request and succeeds after, so the retry can be asserted on.
if [ -n "${CURL_STUB_FAIL_ONCE:-}" ]; then
  if [ ! -f "$CURL_STUB_FAIL_ONCE" ]; then
    : > "$CURL_STUB_FAIL_ONCE"
    cat >/dev/null
    printf 'curl: (56) response reading failed\n' >&2
    exit 56
  fi
fi
# Fails a set number of times before succeeding, so a throttle that outlasts a
# single retry can be told apart from one that does not.
if [ -n "${CURL_STUB_FAIL_TIMES:-}" ]; then
  count=0
  [ ! -f "$CURL_STUB_FAIL_COUNTER" ] || count=$(cat "$CURL_STUB_FAIL_COUNTER")
  if [ "$count" -lt "$CURL_STUB_FAIL_TIMES" ]; then
    printf '%s' "$(( count + 1 ))" > "$CURL_STUB_FAIL_COUNTER"
    cat >/dev/null
    printf 'curl: (56) response reading failed\n' >&2
    exit 56
  fi
fi
if [ -n "${CURL_STUB_HEADER:-}" ] && [ -n "$header_file" ]; then
  printf '%s' "$CURL_STUB_HEADER" > "$header_file"
  cat >/dev/null
  printf '%s' "${CURL_STUB_BODY:-}"
else
  # The config names the SMTP body's file, which the script's trap removes as
  # soon as it exits. Copying it aside from in here is the only moment the
  # bytes curl would have uploaded can be read.
  if [ -n "${CURL_STUB_UPLOAD:-}" ]; then
    config=$(cat)
    upload=$(printf '%s' "$config" | sed -n 's/^upload-file = "\(.*\)"$/\1/p' | head -1)
    [ -z "$upload" ] || cp "$upload" "$CURL_STUB_UPLOAD" 2>/dev/null || true
    printf '%s' "$config"
  else
    cat
  fi
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

# Injection is about lines, not substrings. A stripped newline leaves its tail
# folded into the value it came from — inert, quoted and escaped — where a
# surviving one would start a config line of its own. So the assertion is that
# no line of the config *begins* with the smuggled directive.
check_no_directive() {
  description=$1
  haystack=$2
  directive=$3
  if printf '%s' "$haystack" | grep -q "^$directive"; then
    printf '  FAIL %s\n' "$description"
    printf '       a config line begins with: %s\n' "$directive"
    printf '       in:\n%s\n' "$haystack"
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

# ------------------------------------------------- config-directive injection
#
# curl's config parser is line-oriented, and quoting does not span a line
# break: a CR or an LF inside a value ends the directive it sits in and the
# rest of the value is read as another directive. A password holding a newline
# would therefore be able to add `upload-file` or `output` to the request that
# carries it — a config-injection primitive on the one process that holds the
# credential.
#
# Every caller strips or encodes CR/LF before the field is base64-encoded, so
# nothing today can reach this. That is exactly the assumption the transport
# must not make on its own behalf: it is the last thing between a value and
# curl.

injected='pw
upload-file = "/etc/passwd"'
config=$(config_for "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 "jane:$injected") $(b64 'NOOP')")
check_no_directive "an LF in a password cannot add a config directive" "$config" 'upload-file'
check "the credential line survives, with the newline removed" "$config" 'user = "jane:pwupload-file'
lines=$(printf '%s' "$config" | grep -c '^user = ' || true)
if [ "$lines" = "1" ]; then
  printf '  ok   an injected password is still one config line\n'
else
  printf '  FAIL an injected password produced %s user lines\n' "$lines"
  failures=$(( failures + 1 ))
fi

# A CR alone splits a line for the same parser, and is the one a header-style
# injection reaches for.
injected_cr=$(printf 'pw\routput = "/tmp/stolen"')
config=$(config_for "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 "jane:$injected_cr") $(b64 'NOOP')")
# grep sees a CR as an ordinary character, so a line-anchored match would miss
# a value that carries one. The assertion is on the raw bytes: no CR reaches
# the config at all.
if printf '%s' "$config" | od -An -c | grep -q '\\r'; then
  printf '  FAIL a CR in a password reached the config\n'
  printf '       in:\n%s\n' "$(printf '%s' "$config" | od -c)"
  failures=$(( failures + 1 ))
else
  printf '  ok   a CR in a password cannot add a config directive\n'
fi
check "the credential is still one value, CR removed" "$config" 'user = "jane:pwoutput'

# An IMAP command is composed by Imap.js, but the transport does not get to
# assume that: a folder name arrives from the server's own LIST reply.
injected_cmd='NOOP
request = "UID EXPUNGE 1:*"'
config=$(config_for "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 "$injected_cmd")")
check_no_directive "an LF in a command cannot add a second request" "$config" 'request = "UID EXPUNGE'
requests=$(printf '%s' "$config" | grep -c '^request = ' || true)
if [ "$requests" = "1" ]; then
  printf '  ok   an injected command is still one request\n'
else
  printf '  FAIL an injected command produced %s request lines\n' "$requests"
  failures=$(( failures + 1 ))
fi

# The URL passes the scheme guard and then goes into the config like anything
# else, so it gets the same treatment.
injected_url=$(printf 'imaps://imap.example.org/INBOX\nnoproxy = ""')
config=$(config_for "imap $(b64 "$injected_url") $(b64 'jane:pw') $(b64 'NOOP')")
check "and the proxy bypass is still the one the script wrote" "$config" 'noproxy = "*"'
# One `url` line, one `noproxy` line: an injected LF would have made the URL
# span two and put a second option among them.
url_lines=$(printf '%s' "$config" | grep -c '^url = ' || true)
proxy_lines=$(printf '%s' "$config" | grep -c '^noproxy = ' || true)
if [ "$url_lines" = "1" ] && [ "$proxy_lines" = "1" ]; then
  printf '  ok   an LF in the URL cannot rewrite another option\n'
else
  printf '  FAIL an injected URL produced %s url and %s noproxy lines\n' "$url_lines" "$proxy_lines"
  printf '       in:\n%s\n' "$config"
  failures=$(( failures + 1 ))
fi

# The sender and every recipient are addresses from a draft, and reach the
# config the same way.
injected_send="smtp $(b64 'smtps://smtp.example.org:465') $(b64 'jane:pw') $(b64 'jane@example.org
upload-file = "/etc/shadow"') $(b64 'Subject: hi

body') $(b64 'friend@example.com
mail-rcpt = "attacker@example.com"')"
config=$(config_for "$injected_send")
# SMTP writes one `upload-file` of its own, for the message. The injected one
# must not become a second: a directive curl reads later wins over an earlier
# one, so an added `upload-file` would replace the message being sent.
uploads=$(printf '%s' "$config" | grep -c '^upload-file = ' || true)
if [ "$uploads" = "1" ]; then
  printf '  ok   an LF in the sender cannot add a second upload-file\n'
else
  printf '  FAIL an injected sender produced %s upload-file lines\n' "$uploads"
  failures=$(( failures + 1 ))
fi
froms=$(printf '%s' "$config" | grep -c '^mail-from = ' || true)
if [ "$froms" = "1" ]; then
  printf '  ok   an injected sender is still one mail-from\n'
else
  printf '  FAIL an injected sender produced %s mail-from lines\n' "$froms"
  failures=$(( failures + 1 ))
fi
check_absent "an LF in a recipient cannot add another recipient" "$config" 'mail-rcpt = "attacker@example.com"'
rcpts=$(printf '%s' "$config" | grep -c '^mail-rcpt = ' || true)
if [ "$rcpts" = "1" ]; then
  printf '  ok   an injected recipient is still one recipient\n'
else
  printf '  FAIL an injected recipient produced %s mail-rcpt lines\n' "$rcpts"
  failures=$(( failures + 1 ))
fi

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

# The message itself is legitimately multi-line — a header block, a blank line,
# then a body — and it is the one value that does not go through the config at
# all. It is written to a file and named by `upload-file`, so the CR/LF strip
# that guards every config directive must not reach it. This asserts on the
# bytes curl would have uploaded rather than on the config.
uploaded="$work/uploaded"
rm -f "$uploaded"
crlf_message=$(printf 'Subject: hi\r\nFrom: jane@example.org\r\n\r\nfirst line\r\nsecond line\r\n')
send_multiline="smtp $(b64 'smtps://smtp.example.org:465') $(b64 'jane:pw') $(b64 'jane@example.org') $(b64 "$crlf_message") $(b64 'friend@example.com')"
printf '%s\n' "$send_multiline" \
  | CURL_STUB_UPLOAD="$uploaded" XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" >/dev/null
if [ "$(cat "$uploaded" 2>/dev/null)" = "$crlf_message" ]; then
  printf '  ok   a CRLF message body is uploaded byte for byte\n'
else
  printf '  FAIL the outbound message was altered on its way to the file\n'
  printf '       expected:\n%s\n' "$crlf_message" | od -c | tail -5
  printf '       got:\n%s\n' "$(cat "$uploaded" 2>/dev/null)" | od -c | tail -5
  failures=$(( failures + 1 ))
fi
# Four CRLF-terminated lines: two headers, the blank separator, and two body
# lines. A strip applied to the message would collapse them into one.
body_lines=$(wc -l < "$uploaded" | tr -d ' ')
if [ "$body_lines" = "4" ]; then
  printf '  ok   and keeps every one of its lines\n'
else
  printf '  FAIL the uploaded message has %s lines, not 4\n' "$body_lines"
  failures=$(( failures + 1 ))
fi
carriage=$(od -An -c < "$uploaded" | grep -c '\\r' || true)
if [ "$carriage" != "0" ]; then
  printf '  ok   and its CRs, which SMTP requires\n'
else
  printf '  FAIL the CRs were stripped out of the outbound message\n'
  failures=$(( failures + 1 ))
fi


# `login-options` is the one config directive that does not pass through
# `escape()`, and it carries a value derived from what the *server* said. It is
# safe for a different reason: `choose_mechanism` only ever emits one of five
# hardcoded literals, so a hostile CAPABILITY line cannot reach the config
# through it. That is a property of the function rather than of the escaping,
# so it is asserted here — an edit that made the mechanism pass-through would
# otherwise reintroduce the injection this file just closed.
rm -rf "$work/cache"
hostile='* CAPABILITY IMAP4rev1 AUTH=CRAM-MD5"
upload-file = "/etc/passwd'
config=$(printf '%s\n' "imap $(b64 'imaps://imap.example.org:993/INBOX') $(b64 'jane:pw') $(b64 'NOOP')" \
  | CURL_STUB_CAPABILITY="$hostile" XDG_CACHE_HOME="$work/cache" \
    PATH="$work/bin:$PATH" sh "$script" | sed -n '2p' | base64 -d)
check_absent "a server cannot smuggle a directive through the mechanism" "$config" '/etc/passwd'
uploads=$(printf '%s' "$config" | grep -c '^upload-file' || true)
if [ "$uploads" = "0" ]; then
  printf '  ok   and no upload-file line appears in an IMAP config\n'
else
  printf '  FAIL a hostile CAPABILITY line added %s upload-file line(s)\n' "$uploads"
  failures=$(( failures + 1 ))
fi

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


# A server that limits concurrent connections drops some of a burst outright.
# curl reports those as a transport failure, and the same command succeeds a
# moment later — so a dropped list load must be retried rather than delivered
# as a page with messages missing from it, which reads as mail that is not
# there.
rm -rf "$work/cache"
marker="$work/failed-once"
out=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_FAIL_ONCE="$marker" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
if [ "$(printf '%s' "$out" | sed -n '1p')" = "0" ]; then
  printf '  ok   a dropped connection is retried\n'
else
  printf '  FAIL a dropped connection was reported instead of retried\n'
  failures=$(( failures + 1 ))
fi

# The host this exists for refuses every connection for several seconds once
# several accounts open theirs together — a dozen attempts a second apart were
# all refused while a longer wait was answered. So one retry is not enough: the
# gap has to grow, and a throttle lasting past the first retry must still come
# back with the mail rather than an empty page.
rm -rf "$work/cache"
counter="$work/fail-count"
rm -f "$counter"
out=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_FAIL_TIMES=3 \
    CURL_STUB_FAIL_COUNTER="$counter" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
if [ "$(printf '%s' "$out" | sed -n '1p')" = "0" ]; then
  printf '  ok   a throttle outlasting one retry still succeeds\n'
else
  printf '  FAIL a throttled request gave up too early\n'
  failures=$(( failures + 1 ))
fi

# Bounded, though: a transport that never gives up is a panel that never says
# anything, so a host that is genuinely gone still has to report.
rm -rf "$work/cache"
rm -f "$counter"
out=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_FAIL_TIMES=99 \
    CURL_STUB_FAIL_COUNTER="$counter" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
if [ "$(printf '%s' "$out" | sed -n '1p')" = "56" ]; then
  printf '  ok   a host that never answers is reported rather than retried forever\n'
else
  printf '  FAIL a dead host did not surface its failure\n'
  failures=$(( failures + 1 ))
fi
if [ "$(cat "$counter" 2>/dev/null)" = "4" ]; then
  printf '  ok   and it stops after four attempts\n'
else
  printf '  FAIL the retry count was %s, not 4\n' "$(cat "$counter" 2>/dev/null)"
  failures=$(( failures + 1 ))
fi

# ----------------------------------------------- a partly failed sequence
#
# A sequence reaches curl as `--next` sections on one connection, and an
# archive on a server without MOVE is three of them: COPY, STORE +\Deleted,
# UID EXPUNGE. Without --fail-early curl runs the remaining sections after one
# fails and exits with the code of the last transfer — so a COPY answered
# `NO [TRYCREATE]` was followed by the delete, curl exited 0, and the message
# was gone without ever having been copied.
rm -rf "$work/cache"
argv="$work/argv"
rm -f "$argv"
printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_ARGV="$argv" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" >/dev/null
if grep -qx -- '--fail-early' "$argv" 2>/dev/null; then
  printf '  ok   curl is told to abort the sequence at the first failure\n'
else
  printf '  FAIL --fail-early did not reach curl\n'
  failures=$(( failures + 1 ))
fi

# Exit 3 is a malformed URL. It is the same answer the next time and the time
# after, so retrying it spends seven seconds of blank panel to arrive back
# where it started.
rm -rf "$work/cache"
rm -f "$counter"
out=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_EXIT=3 \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
if [ "$(printf '%s' "$out" | sed -n '1p')" = "3" ]; then
  printf '  ok   a malformed URL is reported\n'
else
  printf '  FAIL exit 3 did not survive to the caller\n'
  failures=$(( failures + 1 ))
fi
rm -f "$argv"
start=$(date +%s)
printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_EXIT=3 CURL_STUB_ARGV="$argv" \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script" >/dev/null
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -lt 3 ]; then
  printf '  ok   and is not retried\n'
else
  printf '  FAIL exit 3 was retried: the request took %ss\n' "$elapsed"
  failures=$(( failures + 1 ))
fi

# A server that answered NO answered. Asking again is asking a question that
# is already settled, so only the transport is retried.
rm -rf "$work/cache"
out=$(printf '%s\n' "$imap_req" \
  | CURL_STUB_CAPABILITY="$axigen_imap" CURL_STUB_EXIT=67 \
    XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" sh "$script")
if [ "$(printf '%s' "$out" | sed -n '1p')" = "67" ]; then
  printf '  ok   a refusal is reported rather than retried\n'
else
  printf '  FAIL a refusal did not survive to the caller\n'
  failures=$(( failures + 1 ))
fi

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
